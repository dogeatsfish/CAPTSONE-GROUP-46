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
// PIPELINE (FS-7 budget = 4 cycles, this uses all 4 -- TIMING, see
// docs/timing_closure.md):
//   cycle 0 : tob_updated[i] pulses. A priority selector picks one asset.
//   cycle 1 : S0 -- selected operands and accumulator snapshots REGISTERED
//             (pure mux, no arithmetic).
//   cycle 2 : S1 -- mid computed and EMA delta formed (the only stage with two
//             chained adders); spread pre-terms computed in parallel.
//   cycle 3 : S2 -- EMA accumulator write-back, spread deltas, signal select.
//   cycle 4 : S3 -- threshold compare, trade packed, tvalid asserted; spread
//             accumulator write-back.
//
// The original 2-cycle version evaluated select + mux + THREE chained 34-bit
// adders in a single 4 ns cycle (17 logic levels, -4.7 ns slack at 250 MHz).
// Every stage now holds at most two chained adders fed from local registers.
// Accumulator read (S0) and write-back (S2/S3) are 2-3 cycles apart, which is
// hazard-free because tob_updated strobes for the same book are >= 7 cycles
// apart (one book transaction is at minimum that long).
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
  // S0 (cycle 1): capture the selection and every operand the arithmetic will
  // need -- pure muxing into registers, no adders. This removes the priority
  // encode + 5:1 asset muxes (and their high-fanout select nets) from the
  // arithmetic cone, which is what made the original single-cycle version the
  // chip's critical path.
  //--------------------------------------------------------------------------
  logic                    s0_valid;
  logic [ASSET_IDX_W-1:0]  s0_sel;                       // updated asset
  logic [ASSET_IDX_W-1:0]  s0_asset;                     // order target (tgt_idx)
  logic                    s0_leg_a, s0_leg_b;           // sel is PAIR_A / PAIR_B
  logic signed [MW-1:0]    s0_mid_bid, s0_mid_ask;       // mid operands (sel_idx)
  logic [PRICE_W-1:0]      s0_bid_price, s0_ask_price;   // order quote (tgt_idx)
  logic [QTY_W-1:0]        s0_bid_qty,   s0_ask_qty;
  logic [TIMESTAMP_W-1:0]  s0_ts;
  logic signed [MW-1:0]    s0_ema_avg;                   // accumulator snapshots
  logic                    s0_ema_primed;
  logic signed [MW-1:0]    s0_mid_a, s0_mid_b;
  logic signed [MW-1:0]    s0_spread_avg;
  logic                    s0_spread_primed;

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      s0_valid      <= 1'b0;      s0_sel        <= '0;   s0_asset  <= '0;
      s0_leg_a      <= 1'b0;      s0_leg_b      <= 1'b0;
      s0_mid_bid    <= '0;        s0_mid_ask    <= '0;
      s0_bid_price  <= '0;        s0_ask_price  <= '0;
      s0_bid_qty    <= '0;        s0_ask_qty    <= '0;   s0_ts     <= '0;
      s0_ema_avg    <= '0;        s0_ema_primed <= 1'b0;
      s0_mid_a      <= '0;        s0_mid_b      <= '0;
      s0_spread_avg <= '0;        s0_spread_primed <= 1'b0;
    end else begin
      s0_valid <= sel_valid;
      if (sel_valid) begin
        s0_sel        <= sel_idx;
        s0_asset      <= tgt_idx;
        s0_leg_a      <= (sel_idx == ASSET_IDX_W'(PAIR_A));
        s0_leg_b      <= (sel_idx == ASSET_IDX_W'(PAIR_B));
        s0_mid_bid    <= signed'(MW'(tob_bid_price[sel_idx]));
        s0_mid_ask    <= signed'(MW'(tob_ask_price[sel_idx]));
        s0_bid_price  <= tob_bid_price[tgt_idx];
        s0_ask_price  <= tob_ask_price[tgt_idx];
        s0_bid_qty    <= tob_bid_qty  [tgt_idx];
        s0_ask_qty    <= tob_ask_qty  [tgt_idx];
        // Forwarded UNCHANGED: this is the parser's ingress stamp and is what
        // the TX Generator subtracts to produce the FS-12 latency telemetry.
        s0_ts         <= tob_timestamp[tgt_idx];
        s0_ema_avg    <= ema_avg[sel_idx];
        s0_ema_primed <= ema_primed[sel_idx];
        s0_mid_a      <= mid_reg[PAIR_A];
        s0_mid_b      <= mid_reg[PAIR_B];
        s0_spread_avg <= spread_avg;
        s0_spread_primed <= spread_primed;
      end
    end
  end

  //--------------------------------------------------------------------------
  // S1 (cycle 2): mid and EMA delta -- the ONLY stage with two chained adders.
  //
  //   mid       = (bid + ask) / 2
  //   ema_delta = mid - avg
  //
  // The shift-based EMA needs no multiplier or divider (zero DSP48 usage).
  // The spread pre-terms fold spread_avg into the non-moving leg so S2's
  // spread delta is a SINGLE subtract from registered operands:
  //   A moved: delta = (mid - mid_b) - avg = mid - (mid_b + avg) = mid - pre_b
  //   B moved: delta = (mid_a - mid) - avg = (mid_a - avg) - mid = pre_a - mid
  // (exact under two's-complement modular arithmetic -- no shifts involved).
  //--------------------------------------------------------------------------
  logic                    s1_valid;
  logic [ASSET_IDX_W-1:0]  s1_sel, s1_asset;
  logic                    s1_leg_a, s1_leg_b;
  logic signed [MW-1:0]    s1_mid_c;
  logic signed [MW-1:0]    s1_ema_delta_raw;
  logic signed [MW-1:0]    s1_ema_avg;
  logic                    s1_ema_primed;
  logic signed [MW-1:0]    s1_pre_a, s1_pre_b;           // spread pre-terms
  logic signed [MW-1:0]    s1_mid_a, s1_mid_b;
  logic                    s1_spread_primed;
  logic [PRICE_W-1:0]      s1_bid_price, s1_ask_price;
  logic [QTY_W-1:0]        s1_bid_qty,   s1_ask_qty;
  logic [TIMESTAMP_W-1:0]  s1_ts;

  // px_sum is carried at the full working width so every operand of the add
  // and the shift already matches (older Verilator flags the implicit widen).
  logic [MW-1:0]        px_sum_c;
  logic signed [MW-1:0] mid_c;

  assign px_sum_c = unsigned'(s0_mid_bid) + unsigned'(s0_mid_ask);
  assign mid_c    = signed'(px_sum_c >> 1);

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      s1_valid    <= 1'b0;   s1_sel      <= '0;   s1_asset <= '0;
      s1_leg_a    <= 1'b0;   s1_leg_b    <= 1'b0;
      s1_mid_c    <= '0;     s1_ema_delta_raw <= '0;
      s1_ema_avg  <= '0;     s1_ema_primed    <= 1'b0;
      s1_pre_a    <= '0;     s1_pre_b    <= '0;
      s1_mid_a    <= '0;     s1_mid_b    <= '0;
      s1_spread_primed <= 1'b0;
      s1_bid_price <= '0;    s1_ask_price <= '0;
      s1_bid_qty   <= '0;    s1_ask_qty   <= '0;  s1_ts <= '0;
      for (int i = 0; i < NUM_ASSETS; i++) mid_reg[i] <= '0;
    end else begin
      s1_valid <= s0_valid;
      if (s0_valid) begin
        s1_mid_c         <= mid_c;
        s1_ema_delta_raw <= mid_c - s0_ema_avg;           // 2nd chained adder
        s1_pre_a         <= s0_mid_a - s0_spread_avg;     // parallel single adds
        s1_pre_b         <= s0_mid_b + s0_spread_avg;
        mid_reg[s0_sel]  <= mid_c;

        s1_sel     <= s0_sel;      s1_asset   <= s0_asset;
        s1_leg_a   <= s0_leg_a;    s1_leg_b   <= s0_leg_b;
        s1_ema_avg <= s0_ema_avg;  s1_ema_primed    <= s0_ema_primed;
        s1_mid_a   <= s0_mid_a;    s1_mid_b   <= s0_mid_b;
        s1_spread_primed <= s0_spread_primed;
        s1_bid_price <= s0_bid_price;  s1_ask_price <= s0_ask_price;
        s1_bid_qty   <= s0_bid_qty;    s1_ask_qty   <= s0_ask_qty;
        s1_ts        <= s0_ts;
      end
    end
  end

  //--------------------------------------------------------------------------
  // S2 (cycle 3): EMA accumulator write-back, spread deltas, signal select.
  //
  // Each accumulator is PRIMED on its first observation (avg := mid) so the
  // cold-start transient cannot masquerade as a huge mean-reversion signal.
  // Write-back lands 2 cycles after the S0 snapshot -- hazard-free, since the
  // next strobe for the same book is >= 7 cycles away.
  //--------------------------------------------------------------------------
  logic                    s2_valid;
  logic [ASSET_IDX_W-1:0]  s2_asset;
  logic signed [MW-1:0]    s2_sig;                        // strategy-selected signal
  logic signed [MW-1:0]    s2_spread_delta, s2_spread_c;
  logic                    s2_is_leg, s2_spread_primed;
  logic [PRICE_W-1:0]      s2_bid_price, s2_ask_price;
  logic [QTY_W-1:0]        s2_bid_qty,   s2_ask_qty;
  logic [TIMESTAMP_W-1:0]  s2_ts;

  logic signed [MW-1:0] sp_delta_c, sp_c_c;

  // Single subtracts from registered operands, then a 2:1 select.
  assign sp_delta_c = s1_leg_a ? (s1_mid_c - s1_pre_b) : (s1_pre_a - s1_mid_c);
  assign sp_c_c     = s1_leg_a ? (s1_mid_c - s1_mid_b) : (s1_mid_a - s1_mid_c);

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      s2_valid <= 1'b0;  s2_asset <= '0;  s2_sig <= '0;
      s2_spread_delta <= '0;  s2_spread_c <= '0;
      s2_is_leg <= 1'b0;      s2_spread_primed <= 1'b0;
      s2_bid_price <= '0;  s2_ask_price <= '0;
      s2_bid_qty   <= '0;  s2_ask_qty   <= '0;  s2_ts <= '0;
      for (int i = 0; i < NUM_ASSETS; i++) begin
        ema_avg[i]    <= '0;
        ema_primed[i] <= 1'b0;
      end
    end else begin
      s2_valid <= s1_valid;
      if (s1_valid) begin
        //-- Strategy 0 write-back (single add: both operands registered) -----
        if (!s1_ema_primed) begin
          ema_avg[s1_sel]    <= s1_mid_c;
          ema_primed[s1_sel] <= 1'b1;
        end else begin
          ema_avg[s1_sel] <= s1_ema_avg + (s1_ema_delta_raw >>> EMA_SHIFT);
        end

        //-- Signal select (no signal on a priming sample) --------------------
        if (STRATEGY_SEL == 0) begin
          s2_sig <= s1_ema_primed ? s1_ema_delta_raw : '0;
        end else begin
          s2_sig <= ((s1_leg_a || s1_leg_b) && s1_spread_primed) ? sp_delta_c
                                                                 : '0;
        end

        //-- Spread state toward S3 write-back --------------------------------
        s2_spread_delta  <= sp_delta_c;
        s2_spread_c      <= sp_c_c;
        s2_is_leg        <= s1_leg_a || s1_leg_b;
        s2_spread_primed <= s1_spread_primed;

        s2_asset     <= s1_asset;
        s2_bid_price <= s1_bid_price;  s2_ask_price <= s1_ask_price;
        s2_bid_qty   <= s1_bid_qty;    s2_ask_qty   <= s1_ask_qty;
        s2_ts        <= s1_ts;
      end
    end
  end

  //--------------------------------------------------------------------------
  // S3 (cycle 4): threshold compare and order packing; spread write-back.
  //
  //   mid - avg < -X  -> BUY  at the best ask
  //   mid - avg >  X  -> SELL at the best bid
  //
  // Size is capped at the displayed top-of-book quantity so the engine never
  // quotes for more than the book is showing; a zero-liquidity side is
  // suppressed outright rather than emitting a zero-quantity order.
  //--------------------------------------------------------------------------
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      trade               <= '0;
      m_axis_order_tuser  <= 1'b0;
      m_axis_order_tvalid <= 1'b0;
      spread_avg          <= '0;
      spread_primed       <= 1'b0;
    end else begin
      m_axis_order_tvalid <= 1'b0;          // single-cycle strobe

      if (s2_valid) begin
        automatic logic        do_buy, do_sell;
        automatic logic [QTY_W-1:0] avail, qty;

        //-- Strategy 1 accumulator write-back (single add, registered ops) ---
        if (s2_is_leg) begin
          if (!s2_spread_primed) begin
            spread_avg    <= s2_spread_c;
            spread_primed <= 1'b1;
          end else begin
            spread_avg <= spread_avg + (s2_spread_delta >>> EMA_SHIFT);
          end
        end

        do_buy  = (s2_sig < -THR);
        do_sell = (s2_sig >  THR);

        avail = do_buy ? s2_ask_qty : s2_bid_qty;
        qty   = (avail < QTY_W'(LOT_SIZE)) ? avail : QTY_W'(LOT_SIZE);

        if ((do_buy || do_sell) && qty != '0) begin
          trade.price     <= do_buy ? s2_ask_price : s2_bid_price;
          trade.quantity  <= qty;
          trade.ticker    <= ticker_of(s2_asset);
          trade.timestamp <= s2_ts;
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
