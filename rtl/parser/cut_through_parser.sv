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
  // Order Reference Table
  // Direct-indexed by the low bits of the Order Reference Number. This is only
  // possible because the Market Simulation is in-house and issues bounded,
  // non-colliding refs. An external ITCH feed would require a hash or CAM.
  //--------------------------------------------------------------------------
  ref_entry_t  ref_table [NUM_LIVE_ORDERS];   // TODO: infer as BRAM
  logic [REF_ADDR_W-1:0] ref_addr;
  ref_entry_t            ref_rdata;
  ref_entry_t            ref_wdata;
  logic                  ref_we;

  //--------------------------------------------------------------------------
  // ITCH message types (subset)
  //--------------------------------------------------------------------------
  localparam logic [7:0] ITCH_ADD_ORDER = "A";
  localparam logic [7:0] ITCH_EXECUTED  = "E";
  localparam logic [7:0] ITCH_CANCEL    = "X";
  localparam logic [7:0] ITCH_DELETE    = "D";
  localparam logic [7:0] ITCH_REPLACE   = "U";

  //--------------------------------------------------------------------------
  // Control FSM
  //--------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,           // wait for start of packet
    STRIP,          // discard UDP header; read MoldUDP64 message count
    MSG_TYPE,       // read the 1-byte ITCH message type
    FIELD_EXTRACT,  // stream message bytes into field registers (big-endian)
    REF_RESOLVE,    // BRAM read: recover price/side/symbol (skipped for Add)
    EMIT            // write back ref entry, sample timestamp, assert tvalid
  } parse_state_e;

  parse_state_e state, next_state;

  logic [15:0] msg_count;    // ITCH messages remaining in this UDP packet
  logic [7:0]  byte_idx;     // byte offset within the current ITCH message
  logic [7:0]  msg_type;
  logic [63:0] order_ref;    // 8-byte ITCH order reference number

  // Extracted field registers
  logic [SYMBOL_W-1:0] f_symbol;
  logic [PRICE_W-1:0]  f_price;
  logic [QTY_W-1:0]    f_shares;
  logic                f_side;

  // TODO: FSM state register + next-state logic.
  // TODO: per-message-type offset table driving FIELD_EXTRACT byte steering.
  //       Multi-byte fields assemble MSB-first (ITCH is big-endian).
  // TODO: REF_RESOLVE reads ref_table[order_ref[REF_ADDR_W-1:0]].
  //       Add    -> write new entry, emit an add at the order's price
  //       Exec   -> read entry, decrement shares, emit a decrement
  //       Cancel -> as Exec, using the cancelled share count
  //       Delete -> read entry, emit removal of remaining shares, invalidate
  //       Replace-> two updates: remove at old price, add at new price.
  //                 Side and symbol are INHERITED from the original entry
  //                 (ITCH does not repeat them on a replace).
  // TODO: EMIT samples timestamp_now into upd.timestamp.

  //--------------------------------------------------------------------------
  // Parallel checksum
  //--------------------------------------------------------------------------
  // TODO: compute the UDP/packet checksum in parallel with parsing, in the same
  //       manner as the RX MAC's CRC. Assert r_valid at end-of-packet.
  //
  // NOTE: r_valid must NOT gate m_axis_tvalid. Updates are forwarded
  //       optimistically; the Risk Gateway suppresses any trade derived from a
  //       corrupted packet. Buffering to check the checksum first would cost
  //       ~5.89 us and violate FS-1.

endmodule
