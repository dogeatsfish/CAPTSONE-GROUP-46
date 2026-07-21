//==============================================================================
// Cut-through Stream Parser  (Section 3.1.2)
//
// Strips UDP / MoldUDP64 encapsulation, decodes ITCH messages, and resolves
// them into price-level updates the Order Book Array can apply directly.
//
// ITCH is order-by-order: only Add Order (A) carries price/side/symbol.
// Executed (E), Cancel (X), Delete (D) and Replace (U) identify the order only
// by its Order Reference Number, so the parser maintains an Order Reference
// Table (direct-indexed BRAM) mapping ref -> {symbol, side, price, shares}.
//
// Emits one update per ITCH message as it completes -- never buffers the packet.
// The checksum is computed in PARALLEL and does not gate forwarding.
//
// FS-1 (cut-through), FS-2 (field tracking), FS-4 (integrity), FS-5 (timing)
//------------------------------------------------------------------------------
// EXPECTED INGRESS BYTE FORMAT (the RX MAC has already stripped the 14-byte
// Ethernet L2 header, so the first byte here is IPv4 byte 0):
//
//   IPv4 header (20 B, IHL=5 assumed)
//   UDP  header ( 8 B)
//   MoldUDP64 header (20 B): Session(10) SeqNum(8) MessageCount(2)
//   repeated MessageCount times:  MsgLen(2 B, big-endian) | ITCH message
//
// ITCH 5.0 message layouts implemented (offsets relative to the type byte):
//   'A' Add Order      36 B: 1 Locate(2) Track(2) Time(6) Ref(8) Side(1)
//                            Shares(4) Stock(8) Price(4)
//   'E' Order Executed 31 B: 1 Locate(2) Track(2) Time(6) Ref(8) ExecShares(4)
//                            MatchNum(8)
//   'X' Order Cancel   23 B: 1 Locate(2) Track(2) Time(6) Ref(8) CancShares(4)
//   'D' Order Delete   19 B: 1 Locate(2) Track(2) Time(6) Ref(8)
//   'U' Order Replace  35 B: 1 Locate(2) Track(2) Time(6) OrigRef(8) NewRef(8)
//                            Shares(4) Price(4)
//
// STRUCTURAL NOTE (deviation from the stub's single sequential FSM):
//   s_axis_tready is tied high and MoldUDP64 packs messages back-to-back, so
//   the byte stream CANNOT be stalled. A single FSM that walked
//   FIELD_EXTRACT -> REF_RESOLVE -> EMIT would drop the bytes arriving during
//   the resolve/emit cycles. This design therefore splits into:
//     (1) an INGEST FSM that consumes exactly one byte per cycle, never stalls,
//         and pulses msg_done when a message's final byte lands, and
//     (2) a RESOLVE/EMIT pipeline that runs concurrently with ingest.
//   The shortest ITCH message (Delete, 19 B) plus its 2-byte MoldUDP length
//   gives 21 cycles between msg_done pulses; the pipeline needs at most 4, so
//   it always retires before the next message completes.
//
// SYMBOL MAPPING:
//   book_update_t.symbol_id is 8 bits, but ITCH carries an 8-byte ASCII Stock
//   field. The 2-byte Stock Locate field is the exchange's own integer handle
//   for the security, so the low byte of Stock Locate is used as symbol_id.
//   This avoids an 8-byte ASCII CAM and is valid because the in-house Market
//   Simulation assigns locates 0..NUM_ASSETS-1.
//
// LEVEL SEMANTICS:
//   The Order Book applies ADD as an aggregate (+qty), MODIFY as an absolute
//   quantity, DELETE as a level removal. Executed/Cancel therefore emit MODIFY
//   carrying the order's REMAINING shares (or DELETE when it reaches zero).
//   This assumes the in-house simulator keeps one live order per price level
//   per asset, which holds for the generated feed.
//==============================================================================

module cut_through_parser
  import ct_pkg::*;
(
  input  logic                     core_clk,     // 250 MHz (post CDC FIFO)
  input  logic                     core_rst_n,

  // --- AXI4-Stream slave from RX CDC FIFO -----------------------------------
  input  logic [7:0]               s_axis_tdata,
  input  logic                     s_axis_tvalid,
  input  logic                     s_axis_tlast,
  output logic                     s_axis_tready,  // held high; see QTA

  // --- Shared free-running timestamp counter (top level) --------------------
  input  logic [TIMESTAMP_W-1:0]   timestamp_now,

  // --- AXI4-Stream master to Order Book Array -------------------------------
  output logic [BOOK_UPDATE_W-1:0] m_axis_tdata,   // book_update_t, 91 bits
  output logic                     m_axis_tvalid,

  // --- Integrity flag to Pre-Trade Risk Gateway -----------------------------
  output logic                     r_valid
);

  //--------------------------------------------------------------------------
  // Output packing
  //--------------------------------------------------------------------------
  book_update_t upd;
  assign m_axis_tdata = upd;

  // The parser never back-pressures: ingest capacity (1 B/cycle @ 250 MHz =
  // 2 Gbps) exceeds the 1 Gbps line rate by 2x.
  assign s_axis_tready = 1'b1;

  //--------------------------------------------------------------------------
  // ITCH message types (subset)
  //--------------------------------------------------------------------------
  localparam logic [7:0] ITCH_ADD_ORDER = "A";
  localparam logic [7:0] ITCH_EXECUTED  = "E";
  localparam logic [7:0] ITCH_CANCEL    = "X";
  localparam logic [7:0] ITCH_DELETE    = "D";
  localparam logic [7:0] ITCH_REPLACE   = "U";

  // Encapsulation geometry
  localparam int IP_HDR_LEN   = 20;
  localparam int UDP_HDR_LEN  = 8;
  localparam int MOLD_HDR_LEN = 20;
  localparam int ENCAP_LEN    = IP_HDR_LEN + UDP_HDR_LEN + MOLD_HDR_LEN;  // 48

  // ITCH field offsets shared by every supported message
  localparam int OFF_LOCATE_HI = 1;
  localparam int OFF_LOCATE_LO = 2;
  localparam int OFF_REF_FIRST = 11;
  localparam int OFF_REF_LAST  = 18;

  //--------------------------------------------------------------------------
  // Order Reference Table
  // Direct-indexed by the low bits of the Order Reference Number. This is only
  // possible because the Market Simulation is in-house and issues bounded,
  // non-colliding refs. An external ITCH feed would require a hash or CAM.
  //--------------------------------------------------------------------------
  ref_entry_t  ref_table [NUM_LIVE_ORDERS];   // inferred as BRAM
  logic [REF_ADDR_W-1:0] ref_raddr;
  logic [REF_ADDR_W-1:0] ref_waddr;
  ref_entry_t            ref_rdata;
  ref_entry_t            ref_wdata;
  logic                  ref_we;

  always_ff @(posedge core_clk) begin
    if (ref_we) ref_table[ref_waddr] <= ref_wdata;
    ref_rdata <= ref_table[ref_raddr];        // synchronous read, 1-cycle
  end

  //--------------------------------------------------------------------------
  // Ingest state
  //--------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,           // wait for start of packet
    STRIP,          // discard IP/UDP header; read MoldUDP64 message count
    MSG_LEN,        // 2-byte MoldUDP64 per-message length
    MSG_TYPE,       // read the 1-byte ITCH message type
    FIELD_EXTRACT,  // stream message bytes into field registers (big-endian)
    DRAIN           // all messages consumed; swallow padding until tlast
  } parse_state_e;

  parse_state_e state;

  logic [15:0] pkt_idx;      // byte offset within the packet (checksum + strip)
  logic [15:0] msg_count;    // ITCH messages remaining in this UDP packet
  logic [15:0] wire_msg_len; // MoldUDP64 length of the current message
  logic        mlen_phase;   // 0 = high length byte, 1 = low length byte
  logic [7:0]  msg_off;      // byte offset within the current ITCH message
  logic [7:0]  msg_type;
  logic [63:0] order_ref;    // 8-byte ITCH order reference number
  logic [63:0] new_ref;      // Replace: new order reference number

  // Full field widths are required to shift in the big-endian bytes, but only
  // the low byte of the locate (symbol_id) is consumed downstream.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] stock_locate;
  /* verilator lint_on UNUSEDSIGNAL */

  // Extracted field registers
  logic [PRICE_W-1:0]  f_price;
  logic [QTY_W-1:0]    f_shares;
  logic                f_side;

  // symbol_id is the low byte of Stock Locate (see header note).
  logic [SYMBOL_W-1:0] f_symbol;
  assign f_symbol = stock_locate[SYMBOL_W-1:0];

  // Header fields needed for the UDP checksum pseudo-header
  logic [31:0] src_ip, dst_ip;
  logic [15:0] udp_len, udp_csum_field;

  logic msg_done;            // pulses on the final byte of an ITCH message

  //--------------------------------------------------------------------------
  // Parallel UDP checksum (does NOT gate forwarding -- see note at bottom)
  //--------------------------------------------------------------------------
  logic [31:0] csum_acc;
  logic [7:0]  csum_hold;
  logic        csum_odd;     // a high byte is held, waiting for its low byte

  function automatic logic [15:0] fold16(input logic [31:0] s);
    logic [31:0] t;
    t = (s & 32'h0000_FFFF) + (s >> 16);
    t = (t & 32'h0000_FFFF) + (t >> 16);
    return t[15:0];
  endfunction

  //--------------------------------------------------------------------------
  // Checksum finalisation, evaluated combinationally on the tlast cycle.
  // csum_acc holds every complete 16-bit word BEFORE the current byte, so the
  // final byte is folded in here, then the IPv4 pseudo-header, then the carry.
  // A zero checksum field means "no checksum" and is accepted (RFC 768).
  //--------------------------------------------------------------------------
  logic [31:0] csum_final;
  logic        csum_ok;

  always_comb begin
    // pair up (or zero-pad) the last byte of the datagram
    if (csum_odd) csum_final = csum_acc + {16'h0, csum_hold, s_axis_tdata};
    else          csum_final = csum_acc + {16'h0, s_axis_tdata, 8'h00};

    // IPv4 pseudo-header: src, dst, zero||protocol(17), UDP length
    csum_final = csum_final + {16'h0, src_ip[31:16]} + {16'h0, src_ip[15:0]}
                            + {16'h0, dst_ip[31:16]} + {16'h0, dst_ip[15:0]}
                            + 32'h0000_0011          + {16'h0, udp_len};

    csum_ok = (udp_csum_field == 16'h0000) ? 1'b1
                                           : (fold16(csum_final) == 16'hFFFF);
  end

  //--------------------------------------------------------------------------
  // Ingest FSM -- consumes exactly one byte per cycle, never stalls.
  //--------------------------------------------------------------------------
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      state          <= IDLE;
      pkt_idx        <= 16'd0;
      msg_count      <= 16'd0;
      wire_msg_len   <= 16'd0;
      mlen_phase     <= 1'b0;
      msg_off        <= 8'd0;
      msg_type       <= 8'd0;
      order_ref      <= 64'd0;
      new_ref        <= 64'd0;
      stock_locate   <= 16'd0;
      f_price        <= '0;
      f_shares       <= '0;
      f_side         <= 1'b0;
      src_ip         <= 32'd0;
      dst_ip         <= 32'd0;
      udp_len        <= 16'd0;
      udp_csum_field <= 16'd0;
      csum_acc       <= 32'd0;
      csum_hold      <= 8'd0;
      csum_odd       <= 1'b0;
      msg_done       <= 1'b0;
      r_valid        <= 1'b1;
    end else begin
      msg_done <= 1'b0;

      if (s_axis_tvalid) begin

        //--------------------------------------------------------------------
        // Parallel checksum over the UDP datagram (from the UDP header onward),
        // accumulated as 16-bit big-endian words.
        //--------------------------------------------------------------------
        if (pkt_idx >= 16'(IP_HDR_LEN)) begin
          if (!csum_odd) begin
            csum_hold <= s_axis_tdata;
            csum_odd  <= 1'b1;
          end else begin
            csum_acc <= csum_acc + {16'h0, csum_hold, s_axis_tdata};
            csum_odd <= 1'b0;
          end
        end

        pkt_idx <= pkt_idx + 16'd1;

        //--------------------------------------------------------------------
        case (state)

          //------------------------------------------------------------------
          // First byte of a new packet: IPv4 byte 0. Reset per-packet state.
          //------------------------------------------------------------------
          IDLE: begin
            pkt_idx   <= 16'd1;
            csum_acc  <= 32'd0;
            csum_odd  <= 1'b0;
            csum_hold <= 8'd0;
            state     <= STRIP;
          end

          //------------------------------------------------------------------
          // IP(20) + UDP(8) + MoldUDP64(20). Capture only what is needed.
          //------------------------------------------------------------------
          STRIP: begin
            case (pkt_idx)
              16'd12, 16'd13, 16'd14, 16'd15: src_ip <= {src_ip[23:0], s_axis_tdata};
              16'd16, 16'd17, 16'd18, 16'd19: dst_ip <= {dst_ip[23:0], s_axis_tdata};
              16'd24, 16'd25: udp_len        <= {udp_len[7:0],        s_axis_tdata};
              16'd26, 16'd27: udp_csum_field <= {udp_csum_field[7:0], s_axis_tdata};
              16'd46, 16'd47: msg_count      <= {msg_count[7:0],      s_axis_tdata};
              default: ;
            endcase

            if (pkt_idx == 16'(ENCAP_LEN - 1)) begin
              wire_msg_len <= 16'd0;
              mlen_phase   <= 1'b0;
              state        <= MSG_LEN;
            end
          end

          //------------------------------------------------------------------
          // MoldUDP64 per-message length (2 bytes, big-endian).
          //------------------------------------------------------------------
          MSG_LEN: begin
            wire_msg_len <= {wire_msg_len[7:0], s_axis_tdata};
            mlen_phase   <= ~mlen_phase;
            if (mlen_phase) state <= MSG_TYPE;   // low byte just consumed
          end

          //------------------------------------------------------------------
          // ITCH message type byte (offset 0 of the message).
          //------------------------------------------------------------------
          MSG_TYPE: begin
            msg_type     <= s_axis_tdata;
            msg_off      <= 8'd1;
            order_ref    <= 64'd0;
            new_ref      <= 64'd0;
            stock_locate <= 16'd0;
            f_price      <= '0;
            f_shares     <= '0;
            f_side       <= 1'b0;

            if (wire_msg_len <= 16'd1) begin
              // Degenerate 1-byte message: complete immediately.
              msg_done   <= 1'b1;
              msg_count  <= msg_count - 16'd1;
              mlen_phase <= 1'b0;
              state      <= (msg_count > 16'd1) ? MSG_LEN : DRAIN;
            end else begin
              state <= FIELD_EXTRACT;
            end
          end

          //------------------------------------------------------------------
          // Steer each byte into its field register. Multi-byte fields are
          // assembled MSB-first (ITCH is big-endian) by shift-in.
          //------------------------------------------------------------------
          FIELD_EXTRACT: begin
            msg_off <= msg_off + 8'd1;

            // Fields common to every supported message
            if (msg_off == 8'(OFF_LOCATE_HI) || msg_off == 8'(OFF_LOCATE_LO))
              stock_locate <= {stock_locate[7:0], s_axis_tdata};
            else if (msg_off >= 8'(OFF_REF_FIRST) && msg_off <= 8'(OFF_REF_LAST))
              order_ref <= {order_ref[55:0], s_axis_tdata};

            // Type-specific fields
            case (msg_type)
              ITCH_ADD_ORDER: begin
                if (msg_off == 8'd19)
                  f_side <= (s_axis_tdata == "B") ? SIDE_BID : SIDE_ASK;
                else if (msg_off >= 8'd20 && msg_off <= 8'd23)
                  f_shares <= {f_shares[23:0], s_axis_tdata};
                else if (msg_off >= 8'd32 && msg_off <= 8'd35)
                  f_price <= {f_price[23:0], s_axis_tdata};
                // 24..31 Stock ASCII: unused, symbol comes from Stock Locate
              end

              ITCH_EXECUTED, ITCH_CANCEL: begin
                if (msg_off >= 8'd19 && msg_off <= 8'd22)
                  f_shares <= {f_shares[23:0], s_axis_tdata};
              end

              ITCH_REPLACE: begin
                if (msg_off >= 8'd19 && msg_off <= 8'd26)
                  new_ref <= {new_ref[55:0], s_axis_tdata};
                else if (msg_off >= 8'd27 && msg_off <= 8'd30)
                  f_shares <= {f_shares[23:0], s_axis_tdata};
                else if (msg_off >= 8'd31 && msg_off <= 8'd34)
                  f_price <= {f_price[23:0], s_axis_tdata};
              end

              default: ;   // Delete carries nothing past the order reference
            endcase

            // Final byte of this ITCH message?
            if ({8'h0, msg_off} == (wire_msg_len - 16'd1)) begin
              msg_done     <= 1'b1;
              msg_count    <= msg_count - 16'd1;
              wire_msg_len <= 16'd0;
              mlen_phase   <= 1'b0;
              state        <= (msg_count > 16'd1) ? MSG_LEN : DRAIN;
            end
          end

          // All messages consumed; swallow any trailing padding.
          DRAIN: ;

          default: state <= IDLE;
        endcase

        //--------------------------------------------------------------------
        // End of packet: finalise the checksum and publish integrity.
        //--------------------------------------------------------------------
        if (s_axis_tlast) begin
          state   <= IDLE;
          pkt_idx <= 16'd0;
          r_valid <= csum_ok;
        end
      end
    end
  end

  //--------------------------------------------------------------------------
  // Resolve / Emit pipeline (runs concurrently with ingest)
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] { R_IDLE, R_WAIT, R_EMIT1, R_EMIT2 } res_state_e;
  res_state_e res_state;

  // Snapshot of the completed message
  logic [7:0]          p_type;
  logic [SYMBOL_W-1:0] p_symbol;
  logic [PRICE_W-1:0]  p_price;
  logic [QTY_W-1:0]    p_shares;
  logic                p_side;

  // ITCH order references are 8 bytes; only the low REF_ADDR_W bits index the
  // direct-mapped table (see the Order Reference Table note above).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0]         p_ref, p_new_ref;
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      res_state     <= R_IDLE;
      m_axis_tvalid <= 1'b0;
      upd           <= '0;
      ref_we        <= 1'b0;
      ref_waddr     <= '0;
      ref_wdata     <= '0;
      ref_raddr     <= '0;
      p_type        <= 8'd0;
      p_symbol      <= '0;
      p_price       <= '0;
      p_shares      <= '0;
      p_side        <= 1'b0;
      p_ref         <= 64'd0;
      p_new_ref     <= 64'd0;
    end else begin
      m_axis_tvalid <= 1'b0;      // single-cycle strobe
      ref_we        <= 1'b0;

      case (res_state)

        R_IDLE: begin
          if (msg_done) begin
            p_type    <= msg_type;
            p_symbol  <= f_symbol;
            p_price   <= f_price;
            p_shares  <= f_shares;
            p_side    <= f_side;
            p_ref     <= order_ref;
            p_new_ref <= new_ref;
            ref_raddr <= order_ref[REF_ADDR_W-1:0];
            res_state <= R_WAIT;
          end
        end

        // BRAM read in flight; ref_rdata is valid in the next state.
        R_WAIT: res_state <= R_EMIT1;

        //--------------------------------------------------------------------
        R_EMIT1: begin
          automatic logic [QTY_W-1:0] rem =
              (ref_rdata.shares > p_shares) ? (ref_rdata.shares - p_shares) : '0;

          res_state <= R_IDLE;

          case (p_type)

            //---- Add: brand new order, all fields present -------------------
            ITCH_ADD_ORDER: begin
              upd.symbol_id <= p_symbol;
              upd.price     <= p_price;
              upd.quantity  <= p_shares;
              upd.side      <= p_side;
              upd.msg_type  <= MSG_ADD;
              upd.timestamp <= timestamp_now;
              m_axis_tvalid <= 1'b1;

              ref_we    <= 1'b1;
              ref_waddr <= p_ref[REF_ADDR_W-1:0];
              ref_wdata <= '{valid: 1'b1, symbol_id: p_symbol, side: p_side,
                             price: p_price, shares: p_shares};
            end

            //---- Executed / Cancel: reduce the order's remaining shares -----
            ITCH_EXECUTED, ITCH_CANCEL: begin
              if (ref_rdata.valid) begin
                upd.symbol_id <= ref_rdata.symbol_id;
                upd.price     <= ref_rdata.price;
                upd.side      <= ref_rdata.side;
                upd.quantity  <= rem;
                upd.msg_type  <= (rem == '0) ? MSG_DELETE : MSG_MODIFY;
                upd.timestamp <= timestamp_now;
                m_axis_tvalid <= 1'b1;

                ref_we    <= 1'b1;
                ref_waddr <= p_ref[REF_ADDR_W-1:0];
                ref_wdata <= '{valid: (rem != '0), symbol_id: ref_rdata.symbol_id,
                               side: ref_rdata.side, price: ref_rdata.price,
                               shares: rem};
              end
            end

            //---- Delete: remove the whole order ----------------------------
            ITCH_DELETE: begin
              if (ref_rdata.valid) begin
                upd.symbol_id <= ref_rdata.symbol_id;
                upd.price     <= ref_rdata.price;
                upd.side      <= ref_rdata.side;
                upd.quantity  <= ref_rdata.shares;
                upd.msg_type  <= MSG_DELETE;
                upd.timestamp <= timestamp_now;
                m_axis_tvalid <= 1'b1;

                ref_we    <= 1'b1;
                ref_waddr <= p_ref[REF_ADDR_W-1:0];
                ref_wdata <= '{valid: 1'b0, symbol_id: ref_rdata.symbol_id,
                               side: ref_rdata.side, price: ref_rdata.price,
                               shares: '0};
              end
            end

            //---- Replace: beat 1 removes the old price level ---------------
            // Side and symbol are INHERITED from the original entry; ITCH does
            // not repeat them on a replace.
            ITCH_REPLACE: begin
              if (ref_rdata.valid) begin
                upd.symbol_id <= ref_rdata.symbol_id;
                upd.price     <= ref_rdata.price;
                upd.side      <= ref_rdata.side;
                upd.quantity  <= ref_rdata.shares;
                upd.msg_type  <= MSG_DELETE;
                upd.timestamp <= timestamp_now;
                m_axis_tvalid <= 1'b1;

                // retire the original reference
                ref_we    <= 1'b1;
                ref_waddr <= p_ref[REF_ADDR_W-1:0];
                ref_wdata <= '{valid: 1'b0, symbol_id: ref_rdata.symbol_id,
                               side: ref_rdata.side, price: ref_rdata.price,
                               shares: '0};

                // inherit identity for beat 2
                p_symbol  <= ref_rdata.symbol_id;
                p_side    <= ref_rdata.side;
                res_state <= R_EMIT2;
              end
            end

            default: ;   // unsupported type: silently skipped
          endcase
        end

        //--------------------------------------------------------------------
        // Replace beat 2: add the new price level under the new reference.
        //--------------------------------------------------------------------
        R_EMIT2: begin
          upd.symbol_id <= p_symbol;
          upd.price     <= p_price;
          upd.quantity  <= p_shares;
          upd.side      <= p_side;
          upd.msg_type  <= MSG_ADD;
          upd.timestamp <= timestamp_now;
          m_axis_tvalid <= 1'b1;

          ref_we    <= 1'b1;
          ref_waddr <= p_new_ref[REF_ADDR_W-1:0];
          ref_wdata <= '{valid: 1'b1, symbol_id: p_symbol, side: p_side,
                         price: p_price, shares: p_shares};

          res_state <= R_IDLE;
        end

        default: res_state <= R_IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // NOTE: r_valid must NOT gate m_axis_tvalid. Updates are forwarded
  //       optimistically; the Risk Gateway suppresses any trade derived from a
  //       corrupted packet. Buffering to check the checksum first would cost
  //       ~5.89 us and violate FS-1.
  //--------------------------------------------------------------------------

endmodule
