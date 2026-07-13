//==============================================================================
// Alpha Engine Core  (Section 3.1.4)
//
// Execution logic. Reads market state from the Order Book Array and issues
// trade requests to the Pre-Trade Risk Gateway within 4 clock cycles of a
// tob_updated strobe (FS-7).
//
// This block is the USER SANDBOX (FS-8): the port list below is the fixed
// interface contract. Any user-written strategy conforming to it drops in
// without altering surrounding logic. The prototype implements a mean-reversion
// strategy over an EMA of the mid-price.
//
// NOTE: the prototype strategy reads ONLY the zero-latency ToB registers and
// never touches BRAM, so it spends none of its 4-cycle budget on memory access.
// The depth read port exists for user algorithms that want deeper levels.
//
// FS-7 (alpha engine), FS-8 (sandbox interface)
//==============================================================================

module alpha_engine_core
  import ct_pkg::*;
#(
  parameter int EMA_SHIFT = 4,          // k: smoothing factor, avg += (mid-avg) >> k
  parameter int THRESHOLD = 32'd100     // X: mean-reversion trigger threshold
)
(
  input  logic                    core_clk,     // 250 MHz
  input  logic                    core_rst_n,

  // --- Top-of-book from Order Book Array (zero-wait, no handshake) ----------
  input  logic [PRICE_W-1:0]      tob_bid_price [NUM_ASSETS],
  input  logic [QTY_W-1:0]        tob_bid_qty   [NUM_ASSETS],
  input  logic [PRICE_W-1:0]      tob_ask_price [NUM_ASSETS],
  input  logic [QTY_W-1:0]        tob_ask_qty   [NUM_ASSETS],
  input  logic [TIMESTAMP_W-1:0]  tob_timestamp [NUM_ASSETS],
  input  logic [NUM_ASSETS-1:0]   tob_updated,   // starts the FS-7 window
  input  logic [NUM_ASSETS-1:0]   book_busy,

  // --- Depth read port (Order Book BRAM port B) -----------------------------
  // Driven BY the Alpha Engine; data returns 1 cycle later.
  output logic [DEPTH_ADDR_W-1:0] depth_rd_addr,
  output logic                    depth_rd_en,
  input  logic [LEVEL_W-1:0]      depth_rd_data,

  // --- AXI4-Stream master to Pre-Trade Risk Gateway -------------------------
  output logic [TRADE_W-1:0]      m_axis_order_tdata,   // trade_t, 144 bits
  output logic                    m_axis_order_tuser,   // 1 = Buy, 0 = Sell
  output logic                    m_axis_order_tvalid
);

  //--------------------------------------------------------------------------
  // Output packing
  //--------------------------------------------------------------------------
  trade_t trade;
  assign m_axis_order_tdata = trade;

  //--------------------------------------------------------------------------
  // Strategy 1: mean reversion over an EMA of the mid-price
  //
  //   mid[i] = (tob_bid_price[i] + tob_ask_price[i]) / 2
  //   avg[i] = avg[i] + ((mid[i] - avg[i]) >>> EMA_SHIFT)
  //
  // The shift-based EMA needs no multiplier or divider: one adder, one shift,
  // one subtract. Zero DSP48 usage.
  //
  //   mid - avg < -THRESHOLD  -> BUY  at the best ask
  //   mid - avg >  THRESHOLD  -> SELL at the best bid
  //--------------------------------------------------------------------------
  logic signed [PRICE_W-1:0] mid [NUM_ASSETS];
  logic signed [PRICE_W-1:0] avg [NUM_ASSETS];

  // TODO: on tob_updated[i], compute mid[i] and update avg[i].
  // TODO: compare (mid - avg) against +/- THRESHOLD and issue a trade.
  // TODO: pack the trade: price = best ask (buy) or best bid (sell),
  //       quantity = fixed lot size, ticker = symbol_id -> ASCII lookup,
  //       timestamp = tob_timestamp[i] (forwarded UNCHANGED for FS-12).
  //       Set m_axis_order_tuser = DIR_BUY / DIR_SELL.

  //--------------------------------------------------------------------------
  // Strategy 2  (FS-7 requires a MINIMUM OF TWO predefined strategies)
  //--------------------------------------------------------------------------
  // TODO: second strategy still to be defined. A two-asset spread / pairs
  //       comparison is the natural candidate: it exercises multi-book reads
  //       and would justify the depth read port. FS-7 is not met until this
  //       exists.

  //--------------------------------------------------------------------------
  // symbol_id -> ASCII ticker lookup
  //--------------------------------------------------------------------------
  // The internal datapath uses a small integer symbol_id (you cannot index a
  // BRAM with an ASCII string). The outbound OUCH message needs the 8-char
  // ticker, so it is re-attached here, at the egress boundary.
  //
  // TODO: NUM_ASSETS-entry constant table, symbol_id -> 64-bit space-padded
  //       ASCII. Confirm ownership of this conversion with the Risk Gateway
  //       and TX Generator owners.

  //--------------------------------------------------------------------------
  // Scope note
  //--------------------------------------------------------------------------
  // The current scope does NOT process inbound OUCH acknowledgements, so there
  // is no fill/position tracking here. If FS-18's PnL requires real fills, an
  // acknowledgement path and a position tracker must be added -- raise with the
  // group before assuming PnL is derivable on-chip.

endmodule
