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
//------------------------------------------------------------------------------
// PIPELINE (FS-7 budget = 4 cycles, this uses 2):
//   cycle 0 : tob_updated[i] pulses. A priority selector picks one asset.
//   cycle 1 : mid computed, both strategy accumulators updated, signal latched.
//   cycle 2 : threshold compare, trade packed, m_axis_order_tvalid asserted.
//
// BOTH strategies are instantiated and evaluated concurrently (FS-7 requires a
// minimum of two). STRATEGY_SEL chooses which one drives the single outbound
// order port; the unused comparison folds away at synthesis. Arbitrating both
// onto the port at once would need a priority/round-robin scheme and a defined
// policy for conflicting signals -- deliberately left out of the prototype.
//==============================================================================

module alpha_engine_core
  import ct_pkg::*;
#(
  parameter int EMA_SHIFT    = 4,          // k: smoothing factor, avg += (mid-avg) >> k
  parameter int THRESHOLD    = 32'd100,    // X: mean-reversion trigger threshold
  parameter int STRATEGY_SEL = 0,          // 0 = EMA mean reversion, 1 = pairs spread
  parameter int PAIR_A       = 0,          // strategy 1: traded leg
  parameter int PAIR_B       = 1,          // strategy 1: reference leg
  parameter int LOT_SIZE     = 32'd100     // order size cap (also capped by ToB qty)
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
  /* verilator lint_off UNUSEDSIGNAL */
  // The prototype is ToB-only (see note above). The port is part of the FS-8
  // sandbox contract and exists for user strategies that read deeper levels.
  input  logic [LEVEL_W-1:0]      depth_rd_data,
  /* verilator lint_on UNUSEDSIGNAL */

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

  // Prototype never reads depth; tie the port off cleanly.
  assign depth_rd_addr = '0;
  assign depth_rd_en   = 1'b0;

  //--------------------------------------------------------------------------
  // Signed working width. Prices are unsigned 32-bit, but (mid - avg) and the
  // A-B spread are signed and can exceed 32 bits, so all accumulator maths runs
  // two bits wider to leave headroom for the sign and the sum carry.
  //--------------------------------------------------------------------------
  localparam int MW = PRICE_W + 2;

  localparam logic signed [MW-1:0] THR = MW'(THRESHOLD);

  logic signed [MW-1:0] mid_reg    [NUM_ASSETS];  // last mid per asset
  logic signed [MW-1:0] ema_avg    [NUM_ASSETS];  // strategy 0 accumulator
  logic                 ema_primed [NUM_ASSETS];
  logic signed [MW-1:0] spread_avg;               // strategy 1 accumulator
  logic                 spread_primed;

  //--------------------------------------------------------------------------
  // symbol_id -> ASCII ticker lookup
  //
  // The internal datapath uses a small integer symbol_id (you cannot index a
  // BRAM with an ASCII string). The outbound OUCH message needs the 8-char
  // ticker, so it is re-attached here, at the egress boundary.
  //
  // OUCH alpha fields are left-justified and SPACE padded (0x20).
  //--------------------------------------------------------------------------
  function automatic logic [TICKER_W-1:0] ticker_of(input logic [ASSET_IDX_W-1:0] a);
    case (a)
      3'd0:    return "AAPL    ";
      3'd1:    return "MSFT    ";
      3'd2:    return "AMZN    ";
      3'd3:    return "GOOG    ";
      3'd4:    return "TSLA    ";
      default: return "        ";
    endcase
  endfunction

  //--------------------------------------------------------------------------
  // Cycle 0: pick one updated asset.
  //
  // tob_updated is documented as one-hot, but the selector is a proper priority
  // encoder (lowest index wins) so simultaneous strobes degrade gracefully
  // instead of corrupting the datapath. book_busy gates out any book that is
  // still mid-update, so the engine never samples a torn top-of-book.
  //--------------------------------------------------------------------------
  logic                       sel_valid;
  logic [ASSET_IDX_W-1:0]     sel_idx;

  always_comb begin
    sel_valid = 1'b0;
    sel_idx   = '0;
    for (int i = NUM_ASSETS - 1; i >= 0; i--) begin
      if (tob_updated[i] && !book_busy[i]) begin
        sel_valid = 1'b1;
        sel_idx   = ASSET_IDX_W'(i);
      end
    end
  end

  // The order always targets sel_idx under strategy 0; under the pairs strategy
  // it targets the traded leg (PAIR_A) regardless of which leg moved.
  logic [ASSET_IDX_W-1:0] tgt_idx;
  assign tgt_idx = (STRATEGY_SEL == 0) ? sel_idx : ASSET_IDX_W'(PAIR_A);

  //--------------------------------------------------------------------------
  // Stage 1 registers
  //--------------------------------------------------------------------------
  logic                    s1_valid;
  logic [ASSET_IDX_W-1:0]  s1_asset;
  logic signed [MW-1:0]    s1_ema_delta;
  logic signed [MW-1:0]    s1_spread_delta;
  logic [PRICE_W-1:0]      s1_bid_price, s1_ask_price;
  logic [QTY_W-1:0]        s1_bid_qty,   s1_ask_qty;
  logic [TIMESTAMP_W-1:0]  s1_ts;

  //--------------------------------------------------------------------------
  // Cycle 1: mid, both accumulators, signal capture.
  //
  //   mid[i]  = (bid + ask) / 2
  //   avg[i] += (mid[i] - avg[i]) >>> EMA_SHIFT
  //
  // The shift-based EMA needs no multiplier or divider: one adder, one shift,
  // one subtract. Zero DSP48 usage.
  //
  // Each accumulator is PRIMED on its first observation (avg := mid) so the
  // cold-start transient cannot masquerade as a huge mean-reversion signal.
  //--------------------------------------------------------------------------
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      s1_valid        <= 1'b0;
      s1_asset        <= '0;
      s1_ema_delta    <= '0;
      s1_spread_delta <= '0;
      s1_bid_price    <= '0;
      s1_ask_price    <= '0;
      s1_bid_qty      <= '0;
      s1_ask_qty      <= '0;
      s1_ts           <= '0;
      spread_avg      <= '0;
      spread_primed   <= 1'b0;
      for (int i = 0; i < NUM_ASSETS; i++) begin
        mid_reg[i]    <= '0;
        ema_avg[i]    <= '0;
        ema_primed[i] <= 1'b0;
      end
    end else begin
      s1_valid <= 1'b0;

      if (sel_valid) begin
        automatic logic [PRICE_W:0]   px_sum;
        automatic logic signed [MW-1:0] mid_c;
        automatic logic signed [MW-1:0] ema_delta_c;
        automatic logic signed [MW-1:0] mid_a, mid_b, spread_c, spread_delta_c;

        px_sum = {1'b0, tob_bid_price[sel_idx]} + {1'b0, tob_ask_price[sel_idx]};
        mid_c  = signed'(MW'(px_sum >> 1));

        mid_reg[sel_idx] <= mid_c;

        //-- Strategy 0: EMA mean reversion on the updated asset --------------
        ema_delta_c = mid_c - ema_avg[sel_idx];
        if (!ema_primed[sel_idx]) begin
          ema_avg[sel_idx]    <= mid_c;
          ema_primed[sel_idx] <= 1'b1;
          s1_ema_delta        <= '0;          // no signal on the priming sample
        end else begin
          ema_avg[sel_idx] <= ema_avg[sel_idx] + (ema_delta_c >>> EMA_SHIFT);
          s1_ema_delta     <= ema_delta_c;
        end

        //-- Strategy 1: pairs spread (A - B) mean reversion ------------------
        // Use the freshly computed mid for whichever leg just moved.
        mid_a          = (sel_idx == ASSET_IDX_W'(PAIR_A)) ? mid_c : mid_reg[PAIR_A];
        mid_b          = (sel_idx == ASSET_IDX_W'(PAIR_B)) ? mid_c : mid_reg[PAIR_B];
        spread_c       = mid_a - mid_b;
        spread_delta_c = spread_c - spread_avg;

        if (sel_idx == ASSET_IDX_W'(PAIR_A) || sel_idx == ASSET_IDX_W'(PAIR_B)) begin
          if (!spread_primed) begin
            spread_avg      <= spread_c;
            spread_primed   <= 1'b1;
            s1_spread_delta <= '0;
          end else begin
            spread_avg      <= spread_avg + (spread_delta_c >>> EMA_SHIFT);
            s1_spread_delta <= spread_delta_c;
          end
        end else begin
          s1_spread_delta <= '0;              // neither leg moved: no signal
        end

        //-- Latch the market state the order will quote against --------------
        s1_valid     <= 1'b1;
        s1_asset     <= tgt_idx;
        s1_bid_price <= tob_bid_price[tgt_idx];
        s1_ask_price <= tob_ask_price[tgt_idx];
        s1_bid_qty   <= tob_bid_qty  [tgt_idx];
        s1_ask_qty   <= tob_ask_qty  [tgt_idx];
        // Forwarded UNCHANGED: this is the parser's ingress stamp and is what
        // the TX Generator subtracts to produce the FS-12 latency telemetry.
        s1_ts        <= tob_timestamp[tgt_idx];
      end
    end
  end

  //--------------------------------------------------------------------------
  // Cycle 2: threshold compare and order packing.
  //
  //   mid - avg < -X  -> BUY  at the best ask
  //   mid - avg >  X  -> SELL at the best bid
  //
  // Size is capped at the displayed top-of-book quantity so the engine never
  // quotes for more than the book is showing; a zero-liquidity side is
  // suppressed outright rather than emitting a zero-quantity order.
  //--------------------------------------------------------------------------
  logic signed [MW-1:0] sig_delta;
  assign sig_delta = (STRATEGY_SEL == 0) ? s1_ema_delta : s1_spread_delta;

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      trade               <= '0;
      m_axis_order_tuser  <= 1'b0;
      m_axis_order_tvalid <= 1'b0;
    end else begin
      m_axis_order_tvalid <= 1'b0;          // single-cycle strobe

      if (s1_valid) begin
        automatic logic        do_buy, do_sell;
        automatic logic [QTY_W-1:0] avail, qty;

        do_buy  = (sig_delta < -THR);
        do_sell = (sig_delta >  THR);

        avail = do_buy ? s1_ask_qty : s1_bid_qty;
        qty   = (avail < QTY_W'(LOT_SIZE)) ? avail : QTY_W'(LOT_SIZE);

        if ((do_buy || do_sell) && qty != '0) begin
          trade.price     <= do_buy ? s1_ask_price : s1_bid_price;
          trade.quantity  <= qty;
          trade.ticker    <= ticker_of(s1_asset);
          trade.timestamp <= s1_ts;
          m_axis_order_tuser  <= do_buy ? DIR_BUY : DIR_SELL;
          m_axis_order_tvalid <= 1'b1;
        end
      end
    end
  end

  //--------------------------------------------------------------------------
  // Scope note
  //--------------------------------------------------------------------------
  // The current scope does NOT process inbound OUCH acknowledgements, so there
  // is no fill/position tracking here. If FS-18's PnL requires real fills, an
  // acknowledgement path and a position tracker must be added -- raise with the
  // group before assuming PnL is derivable on-chip.

endmodule
