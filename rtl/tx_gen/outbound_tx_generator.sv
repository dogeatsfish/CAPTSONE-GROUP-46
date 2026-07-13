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
  output logic                   s_axis_trade_tready,  // low while serialising

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
  // Latency telemetry (FS-12)
  //--------------------------------------------------------------------------
  logic [TIMESTAMP_W-1:0] latency;
  // TODO: latency <= timestamp_now - trade.timestamp;
  //       16-bit subtraction. At 4 ns/tick, 16 bits spans 262 us -- three
  //       orders of magnitude beyond any achievable latency, so it cannot wrap
  //       within a measurement window.

  //--------------------------------------------------------------------------
  // OUCH 5.0 message layouts (offsets from the spec)
  //
  //   Type O (Enter Order)  -- 47 bytes
  //     0  Type 'O' | 1  UserRefNum(4) | 5  Side(1) | 6  Quantity(4)
  //     10 Symbol(8) | 18 Price(8)     | 26 TimeInForce | 27 Display
  //     28 Capacity | 29 ISO | 30 CrossType | 31 ClOrdID(14) | 45 AppLen(2)
  //
  //   Type X (Cancel)       -- 11 bytes
  //     0  Type 'X' | 1  UserRefNum(4) | 5  Quantity(4) | 9  AppLen(2)
  //
  //   Type M (Modify)       -- 12 bytes
  //     0  Type 'M' | 1  UserRefNum(4) | 5  Side(1) | 6  Quantity(4)
  //     10 AppLen(2)
  //
  // Encoding rules (OUCH 5.0):
  //   - All numeric fields are BIG-ENDIAN. Emit MSB first.
  //   - Alpha fields are left-justified, SPACE-padded (0x20), not zero-padded.
  //   - Price is an 8-byte field with 4 implied decimal places. The internal
  //     32-bit price is ZERO-EXTENDED into the upper 4 bytes. (If price is
  //     later widened to 64 bits, only the zero-extend step is removed.)
  //--------------------------------------------------------------------------
  localparam int OUCH_LEN_O = 47;
  localparam int OUCH_LEN_X = 11;
  localparam int OUCH_LEN_M = 12;

  localparam int IP_HDR_LEN   = 20;
  localparam int UDP_HDR_LEN  = 8;
  localparam int TELEM_LEN    = TIMESTAMP_W / 8;   // 2 bytes

  //--------------------------------------------------------------------------
  // UserRefNum: unsigned, day-unique, strictly increasing, starting at 1.
  // Mandatory in the OUCH wire format, so it is encoded in full. The current
  // scope does not process inbound acknowledgements, so it is not used for fill
  // correlation. Cancel/Modify reference the ORIGINAL order's UserRefNum.
  //--------------------------------------------------------------------------
  logic [USERREF_W-1:0] user_ref_num;

  // TODO: free-running counter, starts at 1, increments per Enter Order.

  //--------------------------------------------------------------------------
  // Serialiser FSM
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE,           // latch trade, sample timestamp, compute latency, alloc ref
    BUILD_HEADER,   // stream IP + UDP headers; insert length; UDP checksum = 0
    STREAM_PAYLOAD, // byte-select mux over the latched fields, per-type offsets
    FINALIZE        // assert tlast on the final byte, return to IDLE
  } tx_state_e;

  tx_state_e  state, next_state;
  ouch_type_e msg_type;
  logic [7:0] byte_idx;
  logic [7:0] total_len;

  // TODO: FSM state register + next-state logic.
  // TODO: total_len = IP_HDR_LEN + UDP_HDR_LEN + <OUCH len for msg_type>
  //                   + TELEM_LEN.
  // TODO: BUILD_HEADER -- headers are mostly constants; only the length field
  //       varies, so the IP header checksum reduces to a constant plus the
  //       length term (a small adder, not a full checksum unit).
  //       The UDP checksum is set to ZERO. This is legal under IPv4 (RFC 768)
  //       and is required: computing it would need the whole packet up front,
  //       which breaks cut-through.
  // TODO: STREAM_PAYLOAD -- one byte-select multiplexer driven by a per-type
  //       offset table indexed by {msg_type, byte_idx}. Only the TABLE differs
  //       between O/X/M; the datapath is shared. Emit multi-byte fields MSB
  //       first.
  //
  // Back-pressure: a packet takes up to 77 cycles to serialise, so tready must
  // de-assert while busy. (The Risk Gateway's rate limiter makes an actual
  // stall unreachable in steady state, but the handshake is honoured.)

endmodule
