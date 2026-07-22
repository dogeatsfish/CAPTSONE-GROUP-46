//==============================================================================
// Outbound TX Generator  (Section 3.1.6)
//
// Mirror of the Cut-through Stream Parser: where the parser turns bytes into
// fields, this turns fields into bytes. Encodes an approved trade into an
// OUCH 5.0 inbound message, wraps it in IP/UDP, appends the latency telemetry,
// and serialises the whole packet one byte per cycle to the TX CDC FIFO.
//
// Latency (FS-12) = timestamp_now - trade.timestamp, where trade.timestamp was
// sampled by the parser and carried inline through the whole datapath. Both
// endpoints read the SAME free-running counter, so they share a time origin.
//
// Architecture: the packet is NOT assembled into a buffer. The fields are
// latched on accept, and a combinational byte-select multiplexer indexed by a
// running byte counter emits the correct byte each cycle (streaming as encoded,
// per the report's design choice). Only the OUCH-message TABLE would differ to
// support Cancel/Modify; the datapath is shared.
//
// SCOPE: the datapath in front of this block (Alpha Engine -> Risk Gateway)
// carries a trade_t plus a 1-bit direction and NO OUCH message type. The Alpha
// Engine emits new orders, so the only reachable encoding is Enter Order
// (Type 'O'). The Cancel (X) / Modify (M) layouts are documented below and the
// serialiser is structured for them, but they are deferred: reaching them needs
// an upstream message-type field (and, for fill correlation, inbound OUCH ack
// processing) that is out of the current scope.
//
// FS-5 (timing), FS-12 (telemetry), FS-13 (protocol encapsulation)
//==============================================================================

module outbound_tx_generator
  import ct_pkg::*;
(
  input  logic                   core_clk,     // 250 MHz
  input  logic                   core_rst_n,

  // --- AXI4-Stream slave from Pre-Trade Risk Gateway ------------------------
  input  logic [TRADE_W-1:0]     s_axis_trade_tdata,   // trade_t, 144 bits
  input  logic                   s_axis_trade_tuser,   // 1 = Buy, 0 = Sell
  input  logic                   s_axis_trade_tvalid,
  output logic                   s_axis_trade_tready,  // low while serialising OR
                                                       // while the TX FIFO is too
                                                       // full to hold a frame

  // --- TX CDC FIFO write-room (from axis_cdc_fifo s_axis_almost_full) --------
  // High when the FIFO can absorb a whole outbound frame. The serialiser has no
  // per-byte back-pressure (it streams 77 bytes unconditionally once started),
  // so a frame is only STARTED when the whole frame is guaranteed to fit. This
  // is what keeps the crossing lossless -- see the drop note in commontrader_top.
  input  logic                   fifo_has_room,

  // --- Shared free-running timestamp counter (top level) --------------------
  input  logic [TIMESTAMP_W-1:0] timestamp_now,

  // --- AXI4-Stream master to TX CDC FIFO ------------------------------------
  output logic [7:0]             m_axis_tdata,
  output logic                   m_axis_tvalid,
  output logic                   m_axis_tlast
);

  //--------------------------------------------------------------------------
  // Input unpacking
  //--------------------------------------------------------------------------
  trade_t trade;
  assign trade = trade_t'(s_axis_trade_tdata);

  //--------------------------------------------------------------------------
  // OUCH 5.0 message layouts (offsets from the spec, relative to OUCH start)
  //
  //   Type O (Enter Order)  -- 47 bytes
  //     0  Type 'O' | 1  UserRefNum(4) | 5  Side(1) | 6  Quantity(4)
  //     10 Symbol(8) | 18 Price(8)     | 26 TimeInForce | 27 Display
  //     28 Capacity | 29 ISO | 30 CrossType | 31 ClOrdID(14) | 45 AppLen(2)
  //
  //   Type X (Cancel)       -- 11 bytes   [deferred]
  //     0  Type 'X' | 1  UserRefNum(4) | 5  Quantity(4) | 9  AppLen(2)
  //
  //   Type M (Modify)       -- 12 bytes   [deferred]
  //     0  Type 'M' | 1  UserRefNum(4) | 5  Side(1) | 6  Quantity(4) | 10 AppLen(2)
  //
  // Encoding rules (OUCH 5.0):
  //   - All numeric fields are BIG-ENDIAN. Emit MSB first.
  //   - Alpha fields are left-justified, SPACE-padded (0x20), not zero-padded.
  //   - Price is an 8-byte field with 4 implied decimal places. The internal
  //     32-bit price is ZERO-EXTENDED into the upper 4 bytes. (If price is
  //     later widened to 64 bits, only the zero-extend step is removed.)
  //--------------------------------------------------------------------------
  localparam int OUCH_LEN_O = 47;

  localparam int IP_HDR_LEN  = 20;
  localparam int UDP_HDR_LEN = 8;
  localparam int TELEM_LEN   = TIMESTAMP_W / 8;                 // 2 bytes
  localparam int PKT_LEN     = IP_HDR_LEN + UDP_HDR_LEN
                             + OUCH_LEN_O + TELEM_LEN;          // 77 bytes

  // Byte-counter milestones.
  localparam logic [7:0] HDR_LAST_IDX = 8'(IP_HDR_LEN + UDP_HDR_LEN - 1); // 27
  localparam logic [7:0] LAST_IDX     = 8'(PKT_LEN - 1);                  // 76

  //--------------------------------------------------------------------------
  // Network / protocol constants (placeholders for the teaching platform;
  // promote to module parameters if per-instance addressing is ever needed).
  //--------------------------------------------------------------------------
  localparam logic [31:0] SRC_IP   = 32'hC0A8_0001;   // 192.168.0.1
  localparam logic [31:0] DST_IP   = 32'hC0A8_0002;   // 192.168.0.2
  localparam logic [15:0] SRC_PORT = 16'd50000;
  localparam logic [15:0] DST_PORT = 16'd50001;
  localparam logic [7:0]  IP_TTL   = 8'd64;
  localparam logic [7:0]  IP_PROTO = 8'd17;           // UDP

  // OUCH Enter Order control-field defaults (placeholders, documented).
  localparam logic [7:0]  DEF_TIF       = 8'h00;
  localparam logic [7:0]  DEF_DISPLAY   = 8'h00;
  localparam logic [7:0]  DEF_CAPACITY  = 8'h00;
  localparam logic [7:0]  DEF_ISE       = 8'h00;
  localparam logic [7:0]  DEF_CROSSTYPE = 8'h00;
  localparam logic [7:0]  OUCH_SPACE    = 8'h20;       // ASCII space pad
  localparam logic [7:0]  OUCH_TYPE_O   = 8'h4F;       // 'O'
  localparam logic [7:0]  SIDE_BUY      = 8'h42;       // 'B'
  localparam logic [7:0]  SIDE_SELL     = 8'h53;       // 'S'

  //--------------------------------------------------------------------------
  // Free-running allocators
  //   UserRefNum : unsigned, day-unique, strictly increasing, starting at 1.
  //                Mandatory in the OUCH wire format; the current scope does
  //                not process inbound acks, so it is not used for fills.
  //   Identification : IPv4 header field, incremented per packet.
  //--------------------------------------------------------------------------
  logic [USERREF_W-1:0]   user_ref_num;
  logic [15:0]            ip_ident;

  //--------------------------------------------------------------------------
  // Latched-on-accept fields (held for the whole serialisation)
  //--------------------------------------------------------------------------
  logic [7:0]  r_side;
  logic [31:0] r_qty;
  logic [63:0] r_symbol;
  logic [31:0] r_price;
  logic [15:0] r_latency;
  logic [31:0] r_userref;
  logic [15:0] r_ident;
  logic [15:0] r_ip_len;      // IPv4 total length
  logic [15:0] r_udp_len;     // UDP length
  logic [15:0] r_ip_csum;     // IPv4 header checksum

  //--------------------------------------------------------------------------
  // IPv4 header checksum: one's-complement sum of the ten 16-bit header words
  // with the checksum field taken as zero. Most words are constant, so this
  // folds to (constant + total_length + identification) after synthesis.
  //--------------------------------------------------------------------------
  function automatic logic [15:0] ip_checksum(input logic [15:0] tot_len,
                                              input logic [15:0] id16);
    logic [31:0] s;
    s = 32'h0;
    s = s + 32'h0000_4500;                 // Version/IHL, DSCP/ECN
    s = s + {16'h0, tot_len};              // Total Length
    s = s + {16'h0, id16};                 // Identification
    s = s + 32'h0000_4000;                 // Flags/Fragment (Don't Fragment)
    s = s + {16'h0, IP_TTL, IP_PROTO};     // TTL, Protocol   (0x4011)
    // checksum field == 0 (skipped)
    s = s + {16'h0, SRC_IP[31:16]};
    s = s + {16'h0, SRC_IP[15:0]};
    s = s + {16'h0, DST_IP[31:16]};
    s = s + {16'h0, DST_IP[15:0]};
    s = (s & 32'h0000_FFFF) + (s >> 16);   // fold carries
    s = (s & 32'h0000_FFFF) + (s >> 16);
    return ~s[15:0];
  endfunction

  //--------------------------------------------------------------------------
  // Serialiser FSM
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE,           // latch trade, sample timestamp, compute latency, alloc ref
    BUILD_HEADER,   // stream IP + UDP headers; length inserted; UDP checksum = 0
    STREAM_PAYLOAD, // byte-select mux over the latched OUCH fields + telemetry
    FINALIZE        // assert tlast on the final byte, return to IDLE
  } tx_state_e;

  tx_state_e  state;
  logic [7:0] byte_idx;

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      state        <= IDLE;
      byte_idx     <= 8'd0;
      user_ref_num <= 32'd1;   // OUCH UserRefNum begins at 1
      ip_ident     <= 16'd0;
      r_side       <= 8'd0;
      r_qty        <= 32'd0;
      r_symbol     <= 64'd0;
      r_price      <= 32'd0;
      r_latency    <= 16'd0;
      r_userref    <= 32'd0;
      r_ident      <= 16'd0;
      r_ip_len     <= 16'd0;
      r_udp_len    <= 16'd0;
      r_ip_csum    <= 16'd0;
    end else begin
      unique case (state)

        //--------------------------------------------------------------------
        // Accept a trade. Sample the shared counter NOW so the latency delta
        // is measured at the moment the order reaches the generator.
        //--------------------------------------------------------------------
        IDLE: begin
          // Only accept (and start streaming) when the FIFO can hold the whole
          // frame. Otherwise the trade is not taken this cycle; if it is still
          // asserted it will be accepted once room appears, and any trade that
          // the (tready-less) Risk Gateway presents meanwhile is dropped and
          // counted at the top level -- a clean drop, not a mid-frame overrun.
          if (s_axis_trade_tvalid && fifo_has_room) begin
            r_side    <= s_axis_trade_tuser ? SIDE_BUY : SIDE_SELL;
            r_qty     <= trade.quantity;
            r_symbol  <= trade.ticker;
            r_price   <= trade.price;
            r_latency <= timestamp_now - trade.timestamp;   // FS-12, 16-bit wrap
            r_userref <= user_ref_num;
            r_ident   <= ip_ident;
            r_ip_len  <= 16'(PKT_LEN);
            r_udp_len <= 16'(PKT_LEN - IP_HDR_LEN);
            r_ip_csum <= ip_checksum(16'(PKT_LEN), ip_ident);

            user_ref_num <= user_ref_num + 32'd1;
            ip_ident     <= ip_ident + 16'd1;

            byte_idx <= 8'd0;
            state    <= BUILD_HEADER;
          end
        end

        //--------------------------------------------------------------------
        // IP + UDP header bytes (indices 0..27).
        //--------------------------------------------------------------------
        BUILD_HEADER: begin
          byte_idx <= byte_idx + 8'd1;
          if (byte_idx == HDR_LAST_IDX) state <= STREAM_PAYLOAD;
        end

        //--------------------------------------------------------------------
        // OUCH payload + latency telemetry (indices 28..LAST_IDX-1).
        //--------------------------------------------------------------------
        STREAM_PAYLOAD: begin
          byte_idx <= byte_idx + 8'd1;
          if (byte_idx == LAST_IDX - 8'd1) state <= FINALIZE;
        end

        //--------------------------------------------------------------------
        // Final byte (index LAST_IDX) rides out with tlast asserted.
        //--------------------------------------------------------------------
        FINALIZE: begin
          state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // Byte-select multiplexer: maps the current byte index onto the right field.
  // Bytes not listed default to 0x00 (padding, DSCP/ECN, zeroed UDP checksum,
  // price zero-extend, appendage length). ClOrdID (59..72) is space-padded.
  //--------------------------------------------------------------------------
  always_comb begin
    m_axis_tdata = 8'h00;

    case (byte_idx)
      // ---- IPv4 header ----
      8'd0:  m_axis_tdata = 8'h45;              // Version 4, IHL 5
      8'd2:  m_axis_tdata = r_ip_len[15:8];     // Total Length (hi)
      8'd3:  m_axis_tdata = r_ip_len[7:0];      // Total Length (lo)
      8'd4:  m_axis_tdata = r_ident[15:8];      // Identification (hi)
      8'd5:  m_axis_tdata = r_ident[7:0];       // Identification (lo)
      8'd6:  m_axis_tdata = 8'h40;              // Flags: Don't Fragment
      8'd8:  m_axis_tdata = IP_TTL;
      8'd9:  m_axis_tdata = IP_PROTO;
      8'd10: m_axis_tdata = r_ip_csum[15:8];    // Header Checksum (hi)
      8'd11: m_axis_tdata = r_ip_csum[7:0];     // Header Checksum (lo)
      8'd12: m_axis_tdata = SRC_IP[31:24];
      8'd13: m_axis_tdata = SRC_IP[23:16];
      8'd14: m_axis_tdata = SRC_IP[15:8];
      8'd15: m_axis_tdata = SRC_IP[7:0];
      8'd16: m_axis_tdata = DST_IP[31:24];
      8'd17: m_axis_tdata = DST_IP[23:16];
      8'd18: m_axis_tdata = DST_IP[15:8];
      8'd19: m_axis_tdata = DST_IP[7:0];

      // ---- UDP header ----
      8'd20: m_axis_tdata = SRC_PORT[15:8];
      8'd21: m_axis_tdata = SRC_PORT[7:0];
      8'd22: m_axis_tdata = DST_PORT[15:8];
      8'd23: m_axis_tdata = DST_PORT[7:0];
      8'd24: m_axis_tdata = r_udp_len[15:8];    // UDP Length (hi)
      8'd25: m_axis_tdata = r_udp_len[7:0];     // UDP Length (lo)
      // 26,27: UDP checksum = 0 (default) -- legal in IPv4, required for
      //        cut-through since the full packet is not buffered up front.

      // ---- OUCH 5.0 Enter Order ('O') ----
      8'd28: m_axis_tdata = OUCH_TYPE_O;
      8'd29: m_axis_tdata = r_userref[31:24];
      8'd30: m_axis_tdata = r_userref[23:16];
      8'd31: m_axis_tdata = r_userref[15:8];
      8'd32: m_axis_tdata = r_userref[7:0];
      8'd33: m_axis_tdata = r_side;
      8'd34: m_axis_tdata = r_qty[31:24];
      8'd35: m_axis_tdata = r_qty[23:16];
      8'd36: m_axis_tdata = r_qty[15:8];
      8'd37: m_axis_tdata = r_qty[7:0];
      8'd38: m_axis_tdata = r_symbol[63:56];    // Symbol, MSB char first
      8'd39: m_axis_tdata = r_symbol[55:48];
      8'd40: m_axis_tdata = r_symbol[47:40];
      8'd41: m_axis_tdata = r_symbol[39:32];
      8'd42: m_axis_tdata = r_symbol[31:24];
      8'd43: m_axis_tdata = r_symbol[23:16];
      8'd44: m_axis_tdata = r_symbol[15:8];
      8'd45: m_axis_tdata = r_symbol[7:0];
      // 46..49: Price upper 4 bytes = 0 (zero-extend, default)
      8'd50: m_axis_tdata = r_price[31:24];
      8'd51: m_axis_tdata = r_price[23:16];
      8'd52: m_axis_tdata = r_price[15:8];
      8'd53: m_axis_tdata = r_price[7:0];
      8'd54: m_axis_tdata = DEF_TIF;
      8'd55: m_axis_tdata = DEF_DISPLAY;
      8'd56: m_axis_tdata = DEF_CAPACITY;
      8'd57: m_axis_tdata = DEF_ISE;
      8'd58: m_axis_tdata = DEF_CROSSTYPE;
      // 59..72: ClOrdID = 14 spaces (handled by override below)
      // 73,74: Appendage Length = 0 (default)

      // ---- Latency telemetry ----
      8'd75: m_axis_tdata = r_latency[15:8];
      8'd76: m_axis_tdata = r_latency[7:0];

      default: m_axis_tdata = 8'h00;
    endcase

    // ClOrdID space padding (left-justified alpha field).
    if (byte_idx >= 8'd59 && byte_idx <= 8'd72) m_axis_tdata = OUCH_SPACE;
  end

  //--------------------------------------------------------------------------
  // Stream handshake / framing
  //--------------------------------------------------------------------------
  assign s_axis_trade_tready = (state == IDLE) && fifo_has_room;
  assign m_axis_tvalid       = (state == BUILD_HEADER)
                            || (state == STREAM_PAYLOAD)
                            || (state == FINALIZE);
  assign m_axis_tlast        = (state == FINALIZE);

endmodule
