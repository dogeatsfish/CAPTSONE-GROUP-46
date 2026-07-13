//==============================================================================
// Pre-Trade Risk Gateway  (Section 3.1.5)
//
// Static boundary between the (user-replaceable) Alpha Engine and the network.
// Evaluates six risk conditions IN PARALLEL and suppresses any trade that fails
// one. Protects the system from flawed user logic.
//
// Fixed 2-cycle latency: fast combinational checks are pipelined one stage to
// align with the DSP/BRAM checks, then all six flags are OR-reduced.
//
// Also forwards the 16-bit timestamp UNCHANGED toward the TX Generator; without
// it, FS-12 cannot be computed.
//
// FS-11 (risk gateway), FS-4 (integrity endpoint), FS-10 (kill switch)
//==============================================================================
`include "interfaces.svh"

module pre_trade_risk_gateway
  import ct_pkg::*;
#(
  parameter int MAX_QTY        = 32'd10_000,      // max shares per order
  parameter int MAX_ORDER_VAL  = 32'd1_000_000,   // max price*qty
  parameter int RATE_TOKENS    = 8,               // token bucket depth
  parameter int RATE_PERIOD    = 250_000          // 1 ms @ 250 MHz
)
(
  input  logic                 clk_250mhz,
  input  logic                 rst_n,

  // --- AXI4-Stream slave from Alpha Engine ----------------------------------
  input  logic [TRADE_W-1:0]   s_axis_order_tdata,   // trade_t, 144 bits
  input  logic                 s_axis_order_tuser,   // 1 = Buy, 0 = Sell
  input  logic                 s_axis_order_tvalid,

  // --- Kill inputs ----------------------------------------------------------
  input  logic                 rx_error,         // from RX MAC CRC checker
  input  logic                 hw_kill_switch,   // physical IO / SW register

  // --- AXI4-Stream master to Outbound TX Generator --------------------------
  output logic [TRADE_W-1:0]   m_axis_tx_tdata,  // trade_t, forwarded unchanged
  output logic                 m_axis_tx_tuser,
  output logic                 m_axis_tx_tvalid  // high 2 cycles after input,
                                                 // iff all checks pass
);

  //--------------------------------------------------------------------------
  // Input unpacking
  //--------------------------------------------------------------------------
  trade_t trade_in;
  assign trade_in = trade_t'(s_axis_order_tdata);

  //--------------------------------------------------------------------------
  // Six parallel risk checks.
  // Convention: each flag is asserted HIGH ON VIOLATION.
  //--------------------------------------------------------------------------
  logic viol_max_qty;      // combinational: quantity > MAX_QTY
  logic viol_max_value;    // 1 cycle (DSP):  price * quantity > MAX_ORDER_VAL
  logic viol_blacklist;    // 1 cycle (BRAM): ticker is restricted
  logic viol_rate_limit;   // combinational: token bucket empty
  logic viol_kill_switch;  // combinational: hw_kill_switch asserted
  logic viol_crc;          // combinational: rx_error asserted

  // TODO: Max Quantity   -- comparator on trade_in.quantity.
  // TODO: Max Order Val  -- route price and quantity into a DSP48 multiplier,
  //                         compare the product against MAX_ORDER_VAL.
  // TODO: Blacklist      -- hash trade_in.ticker into a BRAM address; the BRAM
  //                         is preloaded at bitstream generation from a .coe.
  // TODO: Rate limiter   -- token bucket: increments every RATE_PERIOD cycles,
  //                         decrements on each accepted order.
  // TODO: Kill switch    -- direct read of hw_kill_switch.
  // TODO: CRC drop       -- direct read of rx_error. This is what makes the
  //                         parser's optimistic cut-through forwarding SAFE:
  //                         a trade derived from a corrupt packet dies here.

  //--------------------------------------------------------------------------
  // Pipeline synchronisation (2 cycles, latency-insensitive)
  //
  //   cycle 0: data enters, all checks begin. Fast (combinational) checks are
  //            registered once so they arrive with the slow ones.
  //   cycle 1: DSP and BRAM results land; all six flags now aligned. Trade data
  //            and tvalid are pipelined alongside.
  //   cycle 2: OR-reduce the six flags. If any is set, m_axis_tx_tvalid is
  //            suppressed and the trade never leaves the chip.
  //--------------------------------------------------------------------------
  trade_t trade_p1, trade_p2;
  logic   tuser_p1, tuser_p2;
  logic   tvalid_p1, tvalid_p2;

  // TODO: implement the 2-stage shift-register pipeline.
  // TODO: m_axis_tx_tvalid = tvalid_p2 & ~(|{six violation flags});
  //
  // IMPORTANT: the timestamp in trade_t must be forwarded BIT-FOR-BIT. The TX
  //            Generator subtracts it from timestamp_now to produce the FS-12
  //            telemetry; corrupting it here silently breaks the latency metric.

endmodule
