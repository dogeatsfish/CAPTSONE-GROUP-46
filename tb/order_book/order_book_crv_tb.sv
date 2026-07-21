//==============================================================================
// order_book_crv_tb  -  constrained-random torture bench for order_book_array
//
// The directed bench (order_book_array_tb) proves specific transactions work.
// This one explores the state space: thousands of randomised updates against a
// behavioural reference book, checking the FULL 16-level array after every
// single transaction, not just the top of book.
//
// WHY THIS BLOCK: it is the most stateful in the design. Three different
// mutation paths (aggregate-in-place, insert + shift down, remove + shift up)
// all have to preserve one invariant -- each side stays price-ordered with no
// gaps -- across 5 assets x 2 sides x 16 levels. That is not something directed
// tests can cover, and it is exactly what a reference model checks cheaply.
//
//------------------------------------------------------------------------------
// ON THE RANDOMISATION STYLE
//   Stimulus is generated with $urandom_range plus explicit constraint logic
//   rather than SystemVerilog `rand` / `constraint` classes. This is deliberate:
//   class randomisation under this simulator is implemented by shelling out to
//   the z3 SAT solver, which is not installed and would become a hard dependency
//   for every person cloning this repo and for CI. $urandom_range needs nothing,
//   behaves identically under Vivado xsim, and is fully reproducible from a seed.
//
//   If this bench is ever run only under xsim, the constraint blocks in the
//   header comment of each generator below translate directly to `constraint`.
//
//   Reproduce a failure with:  ./sim/run_order_book_crv_tb.sh +SEED=12345
//
//------------------------------------------------------------------------------
// STIMULUS CONSTRAINTS
//   asset     : 90% legal [0, NUM_ASSETS-1], 10% illegal [NUM_ASSETS, 7]
//               (the illegal ones must be discarded -- see the range guard in
//                order_book_array.sv)
//   msg_type  : ADD 60%, MODIFY 20%, DELETE 20%
//   price     : one of 24 discrete ticks, against a 16-level book. Deliberately
//               MORE distinct prices than levels, so the book fills up and the
//               worst level must be evicted -- the case a wider price range
//               would almost never reach.
//   MODIFY / DELETE always target a price that is CURRENTLY LIVE on that book.
//               This reflects the real upstream contract: the parser only ever
//               emits MODIFY/DELETE after resolving an existing order reference,
//               so a modify against a non-existent price is unreachable in the
//               system. (It is also genuinely destructive in the RTL -- the
//               search returns an insertion point and the write clobbers a live
//               level -- which is worth knowing but is not this bench's target.)
//
// CHECKS after every transaction:
//   C1  full 16-level array matches the reference model, both sides
//   C2  top-of-book outputs match reference level 0
//   C3  price ordering invariant holds on the DUT (absolute property, checked
//       independently of the reference so a bug in the model cannot mask it)
//   C4  tob_updated pulsed if and only if the top of book actually changed
//==============================================================================

`timescale 1ns/1ps

module order_book_crv_tb
  import ct_pkg::*;
;

  //--------------------------------------------------------------------------
  // Knobs (override from the command line)
  //--------------------------------------------------------------------------
  int unsigned SEED  = 32'hC0FFEE01;
  int unsigned NTXN  = 2000;

  localparam int PRICE_TICKS = 24;      // distinct prices per side (> NUM_LEVELS)
  localparam int PRICE_BASE  = 10_000;
  localparam int PRICE_STEP  = 10;

  //--------------------------------------------------------------------------
  // Clock / reset
  //--------------------------------------------------------------------------
  logic core_clk;
  logic core_rst_n;

  initial core_clk = 1'b0;
  always #(CORE_PERIOD_NS/2.0) core_clk = ~core_clk;

  //--------------------------------------------------------------------------
  // DUT
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
  // Scoreboard
  //--------------------------------------------------------------------------
  int unsigned checks = 0;
  int unsigned errors = 0;
  int unsigned txn_id = 0;

  // Per-outcome tallies, so a "pass" that never reached the interesting paths
  // is visible rather than reassuring.
  int unsigned n_add_new = 0, n_add_agg = 0, n_modify = 0, n_delete = 0;
  int unsigned n_dropped_range = 0, n_dropped_full = 0, n_evicted = 0;
  int unsigned n_strobe = 0;

  task automatic fail(input string msg);
    errors++;
    $display("  [FAIL] txn %0d: %s", txn_id, msg);
  endtask

  //--------------------------------------------------------------------------
  // Reference model
  //--------------------------------------------------------------------------
  logic [PRICE_W-1:0] ref_px  [NUM_ASSETS][2][NUM_LEVELS];
  logic [QTY_W-1:0]   ref_qty [NUM_ASSETS][2][NUM_LEVELS];

  // Is price a for a BETTER position than price b on this side?
  function automatic bit better(input logic side,
                                input logic [PRICE_W-1:0] a,
                                input logic [PRICE_W-1:0] b);
    return (side == SIDE_BID) ? (a > b) : (a < b);
  endfunction

  // Mirrors the DUT's parallel comparator: first exact match on an occupied
  // level, otherwise first empty slot or first level we out-rank.
  task automatic ref_search(input int a, input int s,
                            input logic [PRICE_W-1:0] price,
                            output int  idx,
                            output bit  exact,
                            output bit  found);
    idx = 0; exact = 1'b0; found = 1'b0;
    for (int l = 0; l < NUM_LEVELS; l++) begin
      if (!found && ref_qty[a][s][l] != 0 && ref_px[a][s][l] == price) begin
        idx = l; exact = 1'b1; found = 1'b1;
      end else if (!found && (ref_qty[a][s][l] == 0 ||
                              better(logic'(s), price, ref_px[a][s][l]))) begin
        idx = l; exact = 1'b0; found = 1'b1;
      end
    end
  endtask

  task automatic ref_apply(input int a, input int s,
                           input logic [PRICE_W-1:0] price,
                           input logic [QTY_W-1:0]   qty,
                           input msg_type_e          mt);
    int idx; bit exact, found;
    ref_search(a, s, price, idx, exact, found);

    if (!found) begin
      n_dropped_full++;
      return;
    end

    case (mt)
      MSG_ADD: begin
        if (exact) begin
          ref_qty[a][s][idx] = ref_qty[a][s][idx] + qty;
          n_add_agg++;
        end else begin
          // Evicting a live level at the tail is a real outcome, not an error:
          // the book only tracks NUM_LEVELS deep.
          if (ref_qty[a][s][NUM_LEVELS-1] != 0) n_evicted++;
          for (int l = NUM_LEVELS-1; l > idx; l--) begin
            ref_px [a][s][l] = ref_px [a][s][l-1];
            ref_qty[a][s][l] = ref_qty[a][s][l-1];
          end
          ref_px [a][s][idx] = price;
          ref_qty[a][s][idx] = qty;
          n_add_new++;
        end
      end

      MSG_MODIFY: begin
        ref_px [a][s][idx] = price;
        ref_qty[a][s][idx] = qty;
        n_modify++;
      end

      MSG_DELETE: begin
        for (int l = idx; l < NUM_LEVELS-1; l++) begin
          ref_px [a][s][l] = ref_px [a][s][l+1];
          ref_qty[a][s][l] = ref_qty[a][s][l+1];
        end
        ref_px [a][s][NUM_LEVELS-1] = '0;
        ref_qty[a][s][NUM_LEVELS-1] = '0;
        n_delete++;
      end

      default: ;
    endcase
  endtask

  // Pick a currently-live price on this book (see the MODIFY/DELETE note above).
  task automatic pick_live(input int a, input int s,
                           output logic [PRICE_W-1:0] price,
                           output bit ok);
    int live_idx [NUM_LEVELS];
    int n;
    n  = 0;
    ok = 1'b0;
    price = '0;
    for (int l = 0; l < NUM_LEVELS; l++)
      if (ref_qty[a][s][l] != 0) begin live_idx[n] = l; n++; end
    if (n > 0) begin
      price = ref_px[a][s][live_idx[$urandom_range(n-1, 0)]];
      ok    = 1'b1;
    end
  endtask

  //--------------------------------------------------------------------------
  // tob_updated is a single-cycle pulse; latch it for the transaction window.
  //--------------------------------------------------------------------------
  logic [NUM_ASSETS-1:0] strobe_latch;
  logic                  strobe_clear;

  always_ff @(posedge core_clk) begin
    if (strobe_clear) strobe_latch <= '0;
    else              strobe_latch <= strobe_latch | tob_updated;
  end

  //--------------------------------------------------------------------------
  // Checkers
  //--------------------------------------------------------------------------
  task automatic check_book(input int a);
    for (int s = 0; s < 2; s++) begin
      for (int l = 0; l < NUM_LEVELS; l++) begin
        checks++;
        if (dut.book[a][s][l].price   !== ref_px [a][s][l] ||
            dut.book[a][s][l].quantity!== ref_qty[a][s][l]) begin
          fail($sformatf(
            "book[%0d][%0d][%0d] = {px %0d, qty %0d}, expected {px %0d, qty %0d}",
            a, s, l, dut.book[a][s][l].price, dut.book[a][s][l].quantity,
            ref_px[a][s][l], ref_qty[a][s][l]));
        end
      end
    end
  endtask

  task automatic check_tob(input int a);
    checks++;
    if (tob_bid_price[a] !== ref_px[a][SIDE_BID][0] ||
        tob_bid_qty  [a] !== ref_qty[a][SIDE_BID][0])
      fail($sformatf("ToB bid asset %0d = {%0d, %0d}, expected {%0d, %0d}", a,
                     tob_bid_price[a], tob_bid_qty[a],
                     ref_px[a][SIDE_BID][0], ref_qty[a][SIDE_BID][0]));
    checks++;
    if (tob_ask_price[a] !== ref_px[a][SIDE_ASK][0] ||
        tob_ask_qty  [a] !== ref_qty[a][SIDE_ASK][0])
      fail($sformatf("ToB ask asset %0d = {%0d, %0d}, expected {%0d, %0d}", a,
                     tob_ask_price[a], tob_ask_qty[a],
                     ref_px[a][SIDE_ASK][0], ref_qty[a][SIDE_ASK][0]));
  endtask

  // Absolute invariant, independent of the reference model: each side is
  // price-ordered, strictly, with every empty level below every occupied one.
  task automatic check_ordering(input int a);
    for (int s = 0; s < 2; s++) begin
      // Declared and assigned separately: a declaration initialiser inside a
      // procedural block has different static/automatic semantics between
      // simulators, and this has to behave identically under xsim.
      bit seen_empty;
      seen_empty = 1'b0;
      for (int l = 0; l < NUM_LEVELS; l++) begin
        if (dut.book[a][s][l].quantity == 0) begin
          seen_empty = 1'b1;
        end else begin
          checks++;
          if (seen_empty)
            fail($sformatf("book[%0d][%0d]: occupied level %0d below an empty one",
                           a, s, l));
          if (l > 0 && dut.book[a][s][l-1].quantity != 0) begin
            checks++;
            if (!better(logic'(s), dut.book[a][s][l-1].price,
                                   dut.book[a][s][l].price))
              fail($sformatf("book[%0d][%0d]: level %0d px %0d not better than level %0d px %0d",
                             a, s, l-1, dut.book[a][s][l-1].price,
                             l, dut.book[a][s][l].price));
          end
        end
      end
    end
  endtask

  //--------------------------------------------------------------------------
  // Drive one transaction and check everything that follows from it.
  //--------------------------------------------------------------------------
  task automatic do_txn(input logic [SYMBOL_W-1:0] sym,
                        input logic                side,
                        input logic [PRICE_W-1:0]  price,
                        input logic [QTY_W-1:0]    qty,
                        input msg_type_e           mt);
    book_update_t u;
    bit           legal;
    int           a;
    logic [PRICE_W-1:0] tob_px_before [2];
    logic [QTY_W-1:0]   tob_qty_before[2];
    bit           tob_changed;

    a     = int'(sym);
    legal = (sym < SYMBOL_W'(NUM_ASSETS));

    if (legal) begin
      tob_px_before [SIDE_BID] = ref_px [a][SIDE_BID][0];
      tob_qty_before[SIDE_BID] = ref_qty[a][SIDE_BID][0];
      tob_px_before [SIDE_ASK] = ref_px [a][SIDE_ASK][0];
      tob_qty_before[SIDE_ASK] = ref_qty[a][SIDE_ASK][0];
    end

    u.symbol_id = sym;
    u.price     = price;
    u.quantity  = qty;
    u.side      = side;
    u.msg_type  = mt;
    u.timestamp = TIMESTAMP_W'(txn_id);

    // Clear the strobe latch, then present the update for exactly one cycle.
    @(negedge core_clk);
    strobe_clear  = 1'b1;
    @(negedge core_clk);
    strobe_clear  = 1'b0;
    s_axis_tdata  = u;
    s_axis_tvalid = 1'b1;
    @(negedge core_clk);
    s_axis_tvalid = 1'b0;
    s_axis_tdata  = '0;

    // Worst case is decode + search + 16 shifts + commit = 20 cycles.
    repeat (30) @(negedge core_clk);

    if (!legal) begin
      n_dropped_range++;
      // An out-of-range symbol must be discarded with no side effects at all.
      checks++;
      if (strobe_latch != '0)
        fail($sformatf("out-of-range symbol %0d produced a tob_updated strobe", sym));
      for (int aa = 0; aa < NUM_ASSETS; aa++) check_book(aa);
      return;
    end

    ref_apply(a, int'(side), price, qty, mt);

    tob_changed = (ref_px [a][SIDE_BID][0] !== tob_px_before [SIDE_BID]) ||
                  (ref_qty[a][SIDE_BID][0] !== tob_qty_before[SIDE_BID]) ||
                  (ref_px [a][SIDE_ASK][0] !== tob_px_before [SIDE_ASK]) ||
                  (ref_qty[a][SIDE_ASK][0] !== tob_qty_before[SIDE_ASK]);

    if (tob_changed) n_strobe++;

    check_book(a);
    check_tob(a);
    check_ordering(a);

    checks++;
    if (strobe_latch[a] !== tob_changed)
      fail($sformatf("asset %0d tob_updated = %0b, top of book %s",
                     a, strobe_latch[a],
                     tob_changed ? "DID change" : "did NOT change"));
  endtask

  //--------------------------------------------------------------------------
  // Main
  //--------------------------------------------------------------------------
  initial begin
    logic [SYMBOL_W-1:0] sym;
    logic                side;
    logic [PRICE_W-1:0]  price;
    logic [QTY_W-1:0]    qty;
    msg_type_e           mt;
    int                  roll;
    bit                  ok;

    void'($value$plusargs("SEED=%d", SEED));
    void'($value$plusargs("NTXN=%d", NTXN));
    void'($urandom(SEED));

    $display("\n==============================================================");
    $display(" Order Book constrained-random torture bench");
    $display("   seed = %0d, transactions = %0d", SEED, NTXN);
    $display("==============================================================");

    s_axis_tdata  = '0;
    s_axis_tvalid = 1'b0;
    depth_rd_addr = '0;
    depth_rd_en   = 1'b0;
    strobe_clear  = 1'b0;
    core_rst_n    = 1'b0;

    for (int a = 0; a < NUM_ASSETS; a++)
      for (int s = 0; s < 2; s++)
        for (int l = 0; l < NUM_LEVELS; l++) begin
          ref_px [a][s][l] = '0;
          ref_qty[a][s][l] = '0;
        end

    repeat (8) @(negedge core_clk);
    core_rst_n = 1'b1;
    repeat (4) @(negedge core_clk);

    for (txn_id = 1; txn_id <= NTXN; txn_id++) begin
      // --- asset: 90% legal, 10% out of range -----------------------------
      if ($urandom_range(99, 0) < 90) sym = SYMBOL_W'($urandom_range(NUM_ASSETS-1, 0));
      else                            sym = SYMBOL_W'($urandom_range(7, NUM_ASSETS));

      side = logic'($urandom_range(1, 0));
      qty  = QTY_W'($urandom_range(5000, 1));

      // --- message type: ADD 60 / MODIFY 20 / DELETE 20 --------------------
      roll = $urandom_range(99, 0);
      if      (roll < 60) mt = MSG_ADD;
      else if (roll < 80) mt = MSG_MODIFY;
      else                mt = MSG_DELETE;

      // --- price ------------------------------------------------------------
      if (mt == MSG_ADD || sym >= SYMBOL_W'(NUM_ASSETS)) begin
        price = PRICE_W'(PRICE_BASE + PRICE_STEP * $urandom_range(PRICE_TICKS-1, 0));
      end else begin
        // MODIFY / DELETE must target a live price -- see the header note.
        pick_live(int'(sym), int'(side), price, ok);
        if (!ok) begin
          mt    = MSG_ADD;      // nothing live on this book yet
          price = PRICE_W'(PRICE_BASE + PRICE_STEP * $urandom_range(PRICE_TICKS-1, 0));
        end
      end

      do_txn(sym, side, price, qty, mt);
    end

    $display("\n  stimulus reached:");
    $display("    ADD (new level)      %0d", n_add_new);
    $display("    ADD (aggregated)     %0d", n_add_agg);
    $display("    MODIFY               %0d", n_modify);
    $display("    DELETE               %0d", n_delete);
    $display("    tail evictions       %0d", n_evicted);
    $display("    dropped (full book)  %0d", n_dropped_full);
    $display("    dropped (bad symbol) %0d", n_dropped_range);
    $display("    ToB changes          %0d", n_strobe);

    $display("\n==============================================================");
    $display("  order_book_crv_tb : %0d checks, %0d failures", checks, errors);
    if (errors == 0) $display("  RESULT: ALL TESTS PASSED");
    else             $display("  RESULT: %0d FAILURE(S)  (reproduce with +SEED=%0d)",
                              errors, SEED);
    $display("==============================================================\n");
    $finish;
  end

  initial begin
    #50_000_000;
    $display("  [FAIL] watchdog timeout");
    $display("  order_book_crv_tb : %0d checks, %0d failures", checks, errors + 1);
    $display("  RESULT: TIMEOUT");
    $finish;
  end

endmodule
