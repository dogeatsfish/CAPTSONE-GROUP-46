//==============================================================================
// order_book_array_tb  -  unit testbench for rtl/order_book/order_book_array.sv
//
// Self-checking SystemVerilog testbench, intended to run under Verilator
// (--binary --timing). No external stimulus files.
//
// Coverage:
//   T1  reset state (all ToB zero, tready high)
//   T2  add first bid            -> ToB set, single tob_updated strobe
//   T3  add better (higher) bid  -> ToB replaced, old level pushed to depth L1
//   T4  add worse (lower) bid    -> ToB unchanged, NO strobe, lands at depth L2
//   T5  modify existing level    -> qty changes at depth, ToB unchanged, no strobe
//   T6  add at existing top price -> quantity aggregates, strobe fires
//   T7  delete top bid           -> next level promoted, depth shifts up, strobe
//   T8  ask side ordering        -> ascending, ToB tracks the lowest ask
//   T9  per-asset isolation      -> updates on one book never touch another
//   T10 full-book top insertion  -> 19-cycle worst case, book_busy width bound
//   T11 depth read latency       -> data valid exactly one cycle after enable
//
// The DUT never back-pressures (s_axis_tready is tied high), so the bench issues
// one transaction at a time and lets the FSM return to IDLE before the next.
//==============================================================================

`timescale 1ns/1ps

module order_book_array_tb
  import ct_pkg::*;
;

  //--------------------------------------------------------------------------
  // Clock / reset
  //--------------------------------------------------------------------------
  logic core_clk;
  logic core_rst_n;

  initial core_clk = 1'b0;
  always #(CORE_PERIOD_NS/2.0) core_clk = ~core_clk;   // 250 MHz, 4 ns period

  //--------------------------------------------------------------------------
  // DUT ports
  //--------------------------------------------------------------------------
  logic [BOOK_UPDATE_W-1:0] s_axis_tdata;
  logic                     s_axis_tvalid;
  logic                     s_axis_tready;

  logic [PRICE_W-1:0]     tob_bid_price [NUM_ASSETS];
  logic [QTY_W-1:0]       tob_bid_qty   [NUM_ASSETS];
  logic [PRICE_W-1:0]     tob_ask_price [NUM_ASSETS];
  logic [QTY_W-1:0]       tob_ask_qty   [NUM_ASSETS];
  logic [TIMESTAMP_W-1:0] tob_timestamp [NUM_ASSETS];

  logic [NUM_ASSETS-1:0]  tob_updated;
  logic [NUM_ASSETS-1:0]  book_busy;

  logic [DEPTH_ADDR_W-1:0] depth_rd_addr;
  logic                    depth_rd_en;
  logic [LEVEL_W-1:0]      depth_rd_data;

  //--------------------------------------------------------------------------
  // DUT
  //--------------------------------------------------------------------------
  order_book_array dut (
    .core_clk      (core_clk),
    .core_rst_n    (core_rst_n),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),
    .tob_bid_price (tob_bid_price),
    .tob_bid_qty   (tob_bid_qty),
    .tob_ask_price (tob_ask_price),
    .tob_ask_qty   (tob_ask_qty),
    .tob_timestamp (tob_timestamp),
    .tob_updated   (tob_updated),
    .book_busy     (book_busy),
    .depth_rd_addr (depth_rd_addr),
    .depth_rd_en   (depth_rd_en),
    .depth_rd_data (depth_rd_data)
  );

  //--------------------------------------------------------------------------
  // Scoreboard bookkeeping
  //--------------------------------------------------------------------------
  int unsigned checks  = 0;
  int unsigned errors  = 0;

  // Cumulative tob_updated strobe count per asset (lets a test assert the exact
  // number of strobes a transaction produced).
  int unsigned tob_upd_count [NUM_ASSETS];

  // Guards that the strobe is genuinely a single-cycle pulse, and that
  // book_busy never exceeds the documented 19-cycle worst case.
  logic [NUM_ASSETS-1:0] prev_upd;
  int unsigned           busy_run;
  int unsigned           busy_max;

  always @(posedge core_clk) begin
    for (int unsigned a = 0; a < NUM_ASSETS; a++) begin
      if (tob_updated[a]) tob_upd_count[a] <= tob_upd_count[a] + 1;
    end

    // A strobe held two cycles in a row is illegal.
    if (|(tob_updated & prev_upd)) begin
      errors <= errors + 1;
      $display("  [FAIL] tob_updated held high for >1 cycle (0x%0h)", tob_updated);
    end
    prev_upd <= tob_updated;

    // Track the longest book_busy run (only one txn is ever in flight).
    if (|book_busy) begin
      busy_run <= busy_run + 1;
    end else begin
      if (busy_run > busy_max) busy_max <= busy_run;
      busy_run <= 0;
    end
  end

  //--------------------------------------------------------------------------
  // Checkers
  //--------------------------------------------------------------------------
  task automatic check64(input string name, input logic [63:0] got, input logic [63:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-38s got=0x%016h exp=0x%016h", name, got, exp);
    end else begin
      $display("  [ OK ] %-38s = 0x%016h", name, got);
    end
  endtask

  task automatic check_int(input string name, input int got, input int exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-38s got=%0d exp=%0d", name, got, exp);
    end else begin
      $display("  [ OK ] %-38s = %0d", name, got);
    end
  endtask

  //--------------------------------------------------------------------------
  // Stimulus helpers
  //--------------------------------------------------------------------------

  // Drive one price-level update and wait for the FSM to fully retire it.
  task automatic send(input int          asset,
                      input logic        side,
                      input logic [31:0] price,
                      input logic [31:0] qty,
                      input msg_type_e   mtype,
                      input logic [15:0] ts);
    book_update_t u;
    u.symbol_id = SYMBOL_W'(asset);
    u.price     = price;
    u.quantity  = qty;
    u.side      = side;
    u.msg_type  = mtype;
    u.timestamp = ts;

    @(negedge core_clk);
    s_axis_tdata  = u;
    s_axis_tvalid = 1'b1;
    @(negedge core_clk);          // one full cycle high -> accepted once in IDLE
    s_axis_tvalid = 1'b0;
    s_axis_tdata  = '0;

    // Worst case IDLE->...->IDLE is ~20 cycles (see header). 30 is safe slack.
    repeat (30) @(posedge core_clk);
  endtask

  // Synchronous depth read: assert enable for one cycle, sample the registered
  // data the cycle after (BRAM port-B behaviour).
  task automatic read_depth(input  int          asset,
                            input  logic         side,
                            input  int           level,
                            output logic [LEVEL_W-1:0] data);
    @(negedge core_clk);
    depth_rd_addr = { ASSET_IDX_W'(asset), side, LEVEL_IDX_W'(level) };
    depth_rd_en   = 1'b1;
    @(posedge core_clk);          // depth_rd_data captured on this edge
    @(negedge core_clk);
    depth_rd_en   = 1'b0;
    data = depth_rd_data;
  endtask

  // Expectation wrappers ----------------------------------------------------
  function automatic logic [LEVEL_W-1:0] mk_level(input logic [31:0] price,
                                                  input logic [31:0] qty);
    level_t l;
    l.price    = price;
    l.quantity = qty;
    return l;
  endfunction

  task automatic expect_tob_bid(input int asset, input logic [31:0] price, input logic [31:0] qty);
    check64($sformatf("asset%0d tob_bid {price,qty}", asset),
            {tob_bid_price[asset], tob_bid_qty[asset]}, {price, qty});
  endtask

  task automatic expect_tob_ask(input int asset, input logic [31:0] price, input logic [31:0] qty);
    check64($sformatf("asset%0d tob_ask {price,qty}", asset),
            {tob_ask_price[asset], tob_ask_qty[asset]}, {price, qty});
  endtask

  task automatic expect_depth(input int asset, input logic side, input int level,
                              input logic [31:0] price, input logic [31:0] qty);
    logic [LEVEL_W-1:0] d;
    read_depth(asset, side, level, d);
    check64($sformatf("asset%0d %s depth[%0d]", asset, side==SIDE_BID ? "bid" : "ask", level),
            d, mk_level(price, qty));
  endtask

  //--------------------------------------------------------------------------
  // Test sequence
  //--------------------------------------------------------------------------
  int unsigned c0;   // snapshot of a strobe counter

  initial begin
    // Init
    s_axis_tdata  = '0;
    s_axis_tvalid = 1'b0;
    depth_rd_addr = '0;
    depth_rd_en   = 1'b0;
    prev_upd      = '0;
    busy_run      = 0;
    busy_max      = 0;
    for (int unsigned a = 0; a < NUM_ASSETS; a++) tob_upd_count[a] = 0;

    // Reset
    core_rst_n = 1'b0;
    repeat (5) @(posedge core_clk);
    @(negedge core_clk);
    core_rst_n = 1'b1;
    repeat (2) @(posedge core_clk);

    //------------------------------------------------------------------ T1
    $display("\n[T1] Reset state");
    check_int("s_axis_tready tied high", s_axis_tready, 1);
    for (int unsigned a = 0; a < NUM_ASSETS; a++) begin
      expect_tob_bid(a, 32'd0, 32'd0);
      expect_tob_ask(a, 32'd0, 32'd0);
    end
    check_int("book_busy idle", int'(book_busy), 0);

    //------------------------------------------------------------------ T2
    $display("\n[T2] Add first bid on asset0 (100 x 10)");
    c0 = tob_upd_count[0];
    send(0, SIDE_BID, 32'd100, 32'd10, MSG_ADD, 16'hAA01);
    expect_tob_bid(0, 32'd100, 32'd10);
    check_int("asset0 bid tob_timestamp", int'(tob_timestamp[0]), 16'hAA01);
    check_int("asset0 strobe count +1", tob_upd_count[0] - c0, 1);

    //------------------------------------------------------------------ T3
    $display("\n[T3] Add better bid on asset0 (101 x 5) -> new top, 100 -> L1");
    c0 = tob_upd_count[0];
    send(0, SIDE_BID, 32'd101, 32'd5, MSG_ADD, 16'hAA02);
    expect_tob_bid(0, 32'd101, 32'd5);
    expect_depth(0, SIDE_BID, 1, 32'd100, 32'd10);
    check_int("asset0 strobe count +1", tob_upd_count[0] - c0, 1);

    //------------------------------------------------------------------ T4
    $display("\n[T4] Add worse bid on asset0 (99 x 7) -> depth L2, ToB unchanged");
    c0 = tob_upd_count[0];
    send(0, SIDE_BID, 32'd99, 32'd7, MSG_ADD, 16'hAA03);
    expect_tob_bid(0, 32'd101, 32'd5);                 // unchanged
    expect_depth(0, SIDE_BID, 2, 32'd99, 32'd7);
    check_int("asset0 NO strobe (deep update)", tob_upd_count[0] - c0, 0);

    //------------------------------------------------------------------ T5
    $display("\n[T5] Modify L1 on asset0 (price 100 -> qty 20)");
    c0 = tob_upd_count[0];
    send(0, SIDE_BID, 32'd100, 32'd20, MSG_MODIFY, 16'hAA04);
    expect_depth(0, SIDE_BID, 1, 32'd100, 32'd20);
    expect_tob_bid(0, 32'd101, 32'd5);                 // top untouched
    check_int("asset0 NO strobe (modify below top)", tob_upd_count[0] - c0, 0);

    //------------------------------------------------------------------ T6
    $display("\n[T6] Add at existing top price on asset0 (101 x 3) -> aggregate to 8");
    c0 = tob_upd_count[0];
    send(0, SIDE_BID, 32'd101, 32'd3, MSG_ADD, 16'hAA05);
    expect_tob_bid(0, 32'd101, 32'd8);                 // 5 + 3
    check_int("asset0 strobe count +1", tob_upd_count[0] - c0, 1);

    //------------------------------------------------------------------ T7
    $display("\n[T7] Delete top bid on asset0 (101) -> 100 promoted, depth shifts up");
    c0 = tob_upd_count[0];
    send(0, SIDE_BID, 32'd101, 32'd0, MSG_DELETE, 16'hAA06);
    expect_tob_bid(0, 32'd100, 32'd20);                // old L1 promoted
    expect_depth(0, SIDE_BID, 0, 32'd100, 32'd20);
    expect_depth(0, SIDE_BID, 1, 32'd99,  32'd7);
    check_int("asset0 strobe count +1", tob_upd_count[0] - c0, 1);

    //------------------------------------------------------------------ T8
    $display("\n[T8] Ask-side ordering on asset1 (ascending, ToB = lowest ask)");
    send(1, SIDE_ASK, 32'd200, 32'd4, MSG_ADD, 16'hBB01);
    expect_tob_ask(1, 32'd200, 32'd4);
    send(1, SIDE_ASK, 32'd199, 32'd6, MSG_ADD, 16'hBB02);  // better (lower)
    expect_tob_ask(1, 32'd199, 32'd6);
    expect_depth(1, SIDE_ASK, 1, 32'd200, 32'd4);
    send(1, SIDE_ASK, 32'd201, 32'd2, MSG_ADD, 16'hBB03);  // worse (higher)
    expect_tob_ask(1, 32'd199, 32'd6);                     // unchanged
    expect_depth(1, SIDE_ASK, 2, 32'd201, 32'd2);
    expect_tob_bid(1, 32'd0, 32'd0);                       // bid side untouched

    //------------------------------------------------------------------ T9
    $display("\n[T9] Per-asset isolation");
    send(2, SIDE_BID, 32'd50, 32'd9, MSG_ADD, 16'hCC01);
    expect_tob_bid(2, 32'd50, 32'd9);
    expect_tob_bid(0, 32'd100, 32'd20);                    // asset0 unchanged from T7
    expect_tob_ask(1, 32'd199, 32'd6);                     // asset1 unchanged from T8

    //------------------------------------------------------------------ T10
    $display("\n[T10] Fill asset3 bid book (16 levels) then insert new top (full-book shift)");
    for (int unsigned p = 1; p <= NUM_LEVELS; p++) begin
      // Ascending prices -> each add becomes the new best bid, pushing down.
      send(3, SIDE_BID, 32'(p), 32'd100, MSG_ADD, 16'hD000 + 16'(p));
    end
    expect_tob_bid(3, 32'(NUM_LEVELS), 32'd100);           // highest so far = 16
    send(3, SIDE_BID, 32'd17, 32'd100, MSG_ADD, 16'hD0FF); // insert into FULL book
    expect_tob_bid(3, 32'd17, 32'd100);
    expect_depth(3, SIDE_BID, 1, 32'd16, 32'd100);         // previous top demoted
    // Documented worst case: 1 decode + 1 search + NUM_LEVELS shift + 1 commit.
    check_int("book_busy worst-case <= 19 cyc", (busy_max <= (NUM_LEVELS + 3)) ? 1 : 0, 1);
    $display("       observed max book_busy run = %0d cycles", busy_max);

    //------------------------------------------------------------------ T11
    $display("\n[T11] Depth read is registered (valid exactly 1 cycle after enable)");
    begin
      logic [LEVEL_W-1:0] d_before, d_after;
      // Preceding depth reads left depth_rd_data = asset3 bid L1 = {16,100}.
      // Drive a fresh address (asset0 bid L0 = {100,20}) and prove the output
      // does NOT update combinationally, only after the next clock edge.
      @(negedge core_clk);
      depth_rd_addr = { ASSET_IDX_W'(0), SIDE_BID, LEVEL_IDX_W'(0) };
      depth_rd_en   = 1'b1;
      d_before      = depth_rd_data;   // same cycle, pre-edge: must still be stale
      @(posedge core_clk);             // capture edge
      @(negedge core_clk);             // safely past the edge (no race)
      depth_rd_en   = 1'b0;
      d_after       = depth_rd_data;   // now valid
      check64("depth held stale pre-edge (registered)", d_before, mk_level(32'd16,  32'd100));
      check64("depth valid 1 cycle after enable",       d_after,  mk_level(32'd100, 32'd20));
    end

    //------------------------------------------------------------------ Summary
    $display("\n==================================================");
    $display("  order_book_array_tb : %0d checks, %0d failures", checks, errors);
    $display("==================================================");
    if (errors == 0) begin
      $display("  RESULT: ALL TESTS PASSED");
      $finish;
    end else begin
      $display("  RESULT: TESTBENCH FAILED");
      $fatal(1, "%0d check(s) failed", errors);
    end
  end

  // Global watchdog: something hung if we run far past the expected length.
  initial begin
    #100000;
    $display("  [FAIL] watchdog timeout");
    $fatal(1, "watchdog timeout");
  end

endmodule
