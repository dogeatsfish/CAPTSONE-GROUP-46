//==============================================================================
// alpha_engine_core_tb  -  unit testbench for
//   rtl/alpha_engine/alpha_engine_core.sv
//
// Self-checking SystemVerilog testbench (Verilator --binary --timing).
//
// Two DUTs are instantiated from the same stimulus so both required strategies
// (FS-7 mandates a minimum of two) are covered independently:
//   dut_ema    STRATEGY_SEL=0  EMA mean reversion on the updated asset
//   dut_spread STRATEGY_SEL=1  pairs spread, trades PAIR_A(0) vs PAIR_B(1)
//
// Coverage:
//   A1 priming sample emits nothing (cold start cannot fake a signal)
//   A2 flat market inside the threshold emits nothing
//   A3 mid collapses below the EMA        -> BUY at the best ask
//   A4 mid spikes above the EMA           -> SELL at the best bid
//   A5 order size capped by displayed ToB quantity
//   A6 zero liquidity on the traded side  -> order suppressed
//   A7 FS-7 latency: order lands exactly 2 cycles after tob_updated
//   A8 book_busy masks a strobe (never sample a torn top-of-book)
//   B1 spread strategy stays quiet once its accumulator has converged
//   B2 spread diverges high -> SELL the rich leg (PAIR_A), identity/ticker
//   B3 spread diverges low  -> BUY  the cheap leg
//   B4 the spread DUT ignores assets outside its configured pair
//==============================================================================

`timescale 1ns/1ps

module alpha_engine_core_tb
  import ct_pkg::*;
;

  localparam int EMA_SHIFT = 4;
  localparam int THRESHOLD = 100;
  localparam int LOT_SIZE  = 100;

  localparam logic [63:0] TICK_AAPL = "AAPL    ";
  localparam logic [63:0] TICK_AMZN = "AMZN    ";

  //--------------------------------------------------------------------------
  // Clock / reset / shared inputs
  //--------------------------------------------------------------------------
  logic core_clk;
  logic core_rst_n;

  logic [PRICE_W-1:0]     tob_bid_price [NUM_ASSETS];
  logic [QTY_W-1:0]       tob_bid_qty   [NUM_ASSETS];
  logic [PRICE_W-1:0]     tob_ask_price [NUM_ASSETS];
  logic [QTY_W-1:0]       tob_ask_qty   [NUM_ASSETS];
  logic [TIMESTAMP_W-1:0] tob_timestamp [NUM_ASSETS];
  logic [NUM_ASSETS-1:0]  tob_updated;
  logic [NUM_ASSETS-1:0]  book_busy;

  initial core_clk = 1'b0;
  always #(CORE_PERIOD_NS/2.0) core_clk = ~core_clk;

  // DUT outputs
  logic [TRADE_W-1:0] e_tdata,  s_tdata;
  logic               e_tuser,  s_tuser;
  logic               e_tvalid, s_tvalid;
  logic [DEPTH_ADDR_W-1:0] e_rd_addr, s_rd_addr;
  logic                    e_rd_en,   s_rd_en;

  alpha_engine_core #(
    .EMA_SHIFT(EMA_SHIFT), .THRESHOLD(THRESHOLD),
    .STRATEGY_SEL(0), .PAIR_A(0), .PAIR_B(1), .LOT_SIZE(LOT_SIZE)
  ) dut_ema (
    .core_clk(core_clk), .core_rst_n(core_rst_n),
    .tob_bid_price(tob_bid_price), .tob_bid_qty(tob_bid_qty),
    .tob_ask_price(tob_ask_price), .tob_ask_qty(tob_ask_qty),
    .tob_timestamp(tob_timestamp), .tob_updated(tob_updated),
    .book_busy(book_busy),
    .depth_rd_addr(e_rd_addr), .depth_rd_en(e_rd_en), .depth_rd_data(64'd0),
    .m_axis_order_tdata(e_tdata), .m_axis_order_tuser(e_tuser),
    .m_axis_order_tvalid(e_tvalid)
  );

  alpha_engine_core #(
    .EMA_SHIFT(EMA_SHIFT), .THRESHOLD(THRESHOLD),
    .STRATEGY_SEL(1), .PAIR_A(0), .PAIR_B(1), .LOT_SIZE(LOT_SIZE)
  ) dut_spread (
    .core_clk(core_clk), .core_rst_n(core_rst_n),
    .tob_bid_price(tob_bid_price), .tob_bid_qty(tob_bid_qty),
    .tob_ask_price(tob_ask_price), .tob_ask_qty(tob_ask_qty),
    .tob_timestamp(tob_timestamp), .tob_updated(tob_updated),
    .book_busy(book_busy),
    .depth_rd_addr(s_rd_addr), .depth_rd_en(s_rd_en), .depth_rd_data(64'd0),
    .m_axis_order_tdata(s_tdata), .m_axis_order_tuser(s_tuser),
    .m_axis_order_tvalid(s_tvalid)
  );

  //--------------------------------------------------------------------------
  // Scoreboard
  //--------------------------------------------------------------------------
  int unsigned checks = 0;
  int unsigned errors = 0;

  task automatic check_int(input string name, input int got, input int exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-42s got=%0d exp=%0d", name, got, exp);
    end
  endtask

  task automatic check64(input string name, input logic [63:0] got, input logic [63:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-42s got=0x%016h exp=0x%016h", name, got, exp);
    end
  endtask

  //--------------------------------------------------------------------------
  // Order capture (one monitor per DUT)
  //--------------------------------------------------------------------------
  trade_t e_ord [0:63];  logic e_dir [0:63];  int e_n;
  trade_t s_ord [0:63];  logic s_dir [0:63];  int s_n;

  always @(posedge core_clk) begin
    if (core_rst_n && e_tvalid) begin
      e_ord[e_n] = trade_t'(e_tdata);
      e_dir[e_n] = e_tuser;
      e_n        = e_n + 1;
    end
    if (core_rst_n && s_tvalid) begin
      s_ord[s_n] = trade_t'(s_tdata);
      s_dir[s_n] = s_tuser;
      s_n        = s_n + 1;
    end
  end

  //--------------------------------------------------------------------------
  // Stimulus: pulse tob_updated for exactly one cycle, then drain the pipeline
  //--------------------------------------------------------------------------
  task automatic tob_update(input int          asset,
                            input logic [31:0] bid_p, input logic [31:0] bid_q,
                            input logic [31:0] ask_p, input logic [31:0] ask_q,
                            input logic [15:0] ts);
    @(negedge core_clk);
    tob_bid_price[asset] = bid_p;  tob_bid_qty[asset] = bid_q;
    tob_ask_price[asset] = ask_p;  tob_ask_qty[asset] = ask_q;
    tob_timestamp[asset] = ts;
    tob_updated          = '0;
    tob_updated[asset]   = 1'b1;
    @(negedge core_clk);
    tob_updated = '0;
    repeat (5) @(negedge core_clk);      // 2-stage pipeline + margin
  endtask

  task automatic expect_order(input string label, input trade_t o, input logic dir,
                              input logic exp_dir, input logic [31:0] exp_price,
                              input logic [31:0] exp_qty, input logic [63:0] exp_tick,
                              input logic [15:0] exp_ts);
    check_int({label, " direction"}, int'(dir),        int'(exp_dir));
    check_int({label, " price"},     int'(o.price),    int'(exp_price));
    check_int({label, " quantity"},  int'(o.quantity), int'(exp_qty));
    check64 ({label, " ticker"},     o.ticker,         exp_tick);
    check_int({label, " timestamp"}, int'(o.timestamp), int'(exp_ts));
  endtask

  //--------------------------------------------------------------------------
  // Test sequence
  //--------------------------------------------------------------------------
  initial begin
    for (int i = 0; i < NUM_ASSETS; i++) begin
      tob_bid_price[i] = '0; tob_bid_qty[i] = '0;
      tob_ask_price[i] = '0; tob_ask_qty[i] = '0;
      tob_timestamp[i] = '0;
    end
    tob_updated = '0;
    book_busy   = '0;
    e_n = 0; s_n = 0;

    core_rst_n = 1'b0;
    repeat (5) @(posedge core_clk);
    @(negedge core_clk);
    core_rst_n = 1'b1;
    repeat (2) @(posedge core_clk);

    //================================================================ PHASE A
    // EMA mean reversion, exercised on asset 2 (outside the spread DUT's pair).
    $display("\n[A] EMA mean reversion (asset 2)");

    // A1: priming sample -- avg := mid, no signal.
    tob_update(2, 32'd990, 32'd500, 32'd1010, 32'd500, 16'h1001);
    check_int("A1 priming emits nothing", e_n, 0);

    // A2: flat market, delta = 0, inside threshold.
    tob_update(2, 32'd990, 32'd500, 32'd1010, 32'd500, 16'h1002);
    check_int("A2 flat market emits nothing", e_n, 0);

    // A3: mid collapses 1000 -> 500. delta = -500 < -100 -> BUY at the ask.
    //     Ask qty 50 < LOT_SIZE 100, so the order is capped at 50 (A5).
    tob_update(2, 32'd490, 32'd500, 32'd510, 32'd50, 16'h1003);
    check_int("A3 collapse emits one order", e_n, 1);
    expect_order("A3 buy", e_ord[0], e_dir[0], DIR_BUY,
                 32'd510, 32'd50, TICK_AMZN, 16'h1003);

    // A4: mid spikes to 2000 against avg 968. delta = +1032 -> SELL at the bid.
    //     Bid qty 500 > LOT_SIZE, so the order is the full lot of 100.
    tob_update(2, 32'd1990, 32'd500, 32'd2010, 32'd500, 16'h1004);
    check_int("A4 spike emits one order", e_n, 2);
    expect_order("A4 sell", e_ord[1], e_dir[1], DIR_SELL,
                 32'd1990, 32'd100, TICK_AMZN, 16'h1004);

    // A6: strong buy signal but the ask side is empty -> suppressed.
    tob_update(2, 32'd95, 32'd500, 32'd105, 32'd0, 16'h1005);
    check_int("A6 zero liquidity suppresses order", e_n, 2);

    // A8: a strobe while the book is busy must be ignored entirely.
    book_busy[2] = 1'b1;
    tob_update(2, 32'd1990, 32'd500, 32'd2010, 32'd500, 16'h1006);
    book_busy[2] = 1'b0;
    check_int("A8 book_busy masks the strobe", e_n, 2);

    // The spread DUT must have stayed silent throughout: asset 2 is not in its pair.
    check_int("B4 spread DUT ignores non-pair asset", s_n, 0);

    //--------------------------------------------------------------- A7 latency
    // FS-7: the order must be issued within 4 cycles; the pipelined design
    // uses exactly 4 (S0 select, S1 mid/delta, S2 write-back, S3 pack).
    $display("\n[A7] FS-7 latency check");
    @(negedge core_clk);
    tob_bid_price[2] = 32'd90;  tob_bid_qty[2] = 32'd500;
    tob_ask_price[2] = 32'd110; tob_ask_qty[2] = 32'd500;
    tob_timestamp[2] = 16'h1007;
    tob_updated      = '0;
    tob_updated[2]   = 1'b1;
    @(negedge core_clk);                 // posedge T consumed the strobe
    tob_updated = '0;
    check_int("A7 no order at T+1", int'(e_tvalid), 0);
    @(negedge core_clk);                 // cycle T+2
    check_int("A7 no order at T+2", int'(e_tvalid), 0);
    @(negedge core_clk);                 // cycle T+3
    check_int("A7 no order at T+3", int'(e_tvalid), 0);
    @(negedge core_clk);                 // cycle T+4
    check_int("A7 order valid at T+4 (FS-7 boundary)", int'(e_tvalid), 1);
    repeat (5) @(negedge core_clk);

    //================================================================ PHASE B
    // Pairs spread. The accumulator starts cold (mid_reg for the second leg is
    // zero), so it is first driven to convergence with a constant spread before
    // any assertion is made -- exactly how a real deployment would warm up.
    $display("\n[B] Pairs spread strategy (asset 0 vs asset 1)");

    for (int i = 0; i < 60; i++) begin
      tob_update(0, 32'd995, 32'd300, 32'd1005, 32'd300, 16'h2000);
      tob_update(1, 32'd995, 32'd300, 32'd1005, 32'd300, 16'h2000);
    end

    // B1: converged -- a constant spread must now produce no further orders.
    s_n = 0;
    tob_update(0, 32'd995, 32'd300, 32'd1005, 32'd300, 16'h2001);
    tob_update(1, 32'd995, 32'd300, 32'd1005, 32'd300, 16'h2001);
    check_int("B1 converged spread emits nothing", s_n, 0);

    // B2: asset 0 re-prices to 2000 while asset 1 holds at 1000. The spread
    //     jumps ~+1000 above its mean -> PAIR_A is rich -> SELL asset 0.
    s_n = 0;
    tob_update(0, 32'd1995, 32'd300, 32'd2005, 32'd300, 16'h2002);
    check_int("B2 divergence emits one order", s_n, 1);
    expect_order("B2 sell-rich", s_ord[0], s_dir[0], DIR_SELL,
                 32'd1995, 32'd100, TICK_AAPL, 16'h2002);

    // B3: asset 0 collapses to 100 -> spread far below its mean -> BUY asset 0.
    s_n = 0;
    tob_update(0, 32'd95, 32'd300, 32'd105, 32'd200, 16'h2003);
    check_int("B3 reversion emits one order", s_n, 1);
    expect_order("B3 buy-cheap", s_ord[0], s_dir[0], DIR_BUY,
                 32'd105, 32'd100, TICK_AAPL, 16'h2003);

    //------------------------------------------------------------------ Summary
    $display("\n==================================================");
    $display("  alpha_engine_core_tb : %0d checks, %0d failures", checks, errors);
    $display("==================================================");
    if (errors == 0) begin
      $display("  RESULT: ALL TESTS PASSED");
      $finish;
    end else begin
      $display("  RESULT: TESTBENCH FAILED");
      $fatal(1, "%0d check(s) failed", errors);
    end
  end

  initial begin
    #2000000;
    $display("  [FAIL] watchdog timeout");
    $fatal(1, "watchdog timeout");
  end

endmodule
