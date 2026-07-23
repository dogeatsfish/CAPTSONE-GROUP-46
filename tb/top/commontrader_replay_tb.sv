//==============================================================================
// commontrader_replay_tb  -  real market data replayed through the whole chip
//
// Streams recorded TAQ-derived market data into the RGMII pins as wire-format
// ITCH/MoldUDP64/UDP/IPv4 Ethernet frames, and checks the hardware order book
// against a software reference model after every frame.
//
// The frames and the reference top-of-book are produced by sim/csv_to_itch.py
// from sw/data_pipeline/data/synthetic_mbo_stream.csv. That script owns every
// HW/SW mapping decision (symbol assignment, C -> ITCH Delete, price scaling);
// they are documented in docs/hw_sw_interface.md.
//
// WHAT THIS COVERS THAT THE OTHER BENCHES DO NOT
//   The directed integration bench proves one hand-built packet produces one
//   correct OUCH order. The CRV bench proves the book's sorted-array logic under
//   randomised pressure. Neither uses real data. This bench replays an actual
//   recorded feed -- hundreds of interleaved adds and deletes across five books,
//   with the natural price distribution and the erroneous ticks that real TAQ
//   data contains -- and cross-checks against an independent model.
//
// WHAT IT DELIBERATELY DOES NOT COVER
//   The software feed keeps at most ONE live order per side (its L1-to-MBO
//   converter cancels before it adds), so it can only ever populate level 0.
//   Book depth is the CRV bench's job. See interface doc item 4.
//
// Checks:
//   R1  every frame is accepted -- no RX FIFO back-pressure, no parser stall
//   R2  top of book matches the reference model after every frame, all assets
//   R3  no TX FIFO overflow across the whole replay
//   R4  the timestamp counter's wrap flag agrees with elapsed time
//==============================================================================

`timescale 1ns/1ps

module commontrader_replay_tb
  import ct_pkg::*;
;

  //--------------------------------------------------------------------------
  // Stimulus files (override with +FRAMES=... etc.)
  //--------------------------------------------------------------------------
  localparam int MAX_BYTES  = 262144;
  localparam int MAX_FRAMES = 4096;

  string f_frames = "sim/replay_frames.hex";
  string f_lens   = "sim/replay_lens.hex";
  string f_tob    = "sim/replay_tob.hex";

  logic [7:0]   fr_bytes [0:MAX_BYTES-1];
  logic [15:0]  fr_lens  [0:MAX_FRAMES-1];
  logic [127:0] exp_tob  [0:MAX_FRAMES*NUM_ASSETS-1];

  int n_frames;

  //--------------------------------------------------------------------------
  // Clocks / reset
  //--------------------------------------------------------------------------
  logic sys_clk;
  logic sys_rst_n;
  logic rgmii_rx_clk;

  initial sys_clk = 1'b0;
  always #5 sys_clk = ~sys_clk;

  initial rgmii_rx_clk = 1'b0;
  always #4 rgmii_rx_clk = ~rgmii_rx_clk;      // 125 MHz

  //--------------------------------------------------------------------------
  // DUT
  //--------------------------------------------------------------------------
  logic [3:0]  rgmii_rxd;
  logic        rgmii_rx_ctl;
  logic        rgmii_tx_clk;
  logic [3:0]  rgmii_txd;
  logic        rgmii_tx_ctl;
  logic        hw_kill_switch_n;   // active-low (board key idles high)
  logic [15:0] order_drop_count;
  logic        tx_fifo_overflow;
  logic        ts_wrapped;

  commontrader_top dut (
    .sys_clk          (sys_clk),
    .sys_rst_n        (sys_rst_n),
    .rgmii_rx_clk     (rgmii_rx_clk),
    .rgmii_rxd        (rgmii_rxd),
    .rgmii_rx_ctl     (rgmii_rx_ctl),
    .rgmii_tx_clk     (rgmii_tx_clk),
    .rgmii_txd        (rgmii_txd),
    .rgmii_tx_ctl     (rgmii_tx_ctl),
    .hw_kill_switch_n (hw_kill_switch_n),
    .order_drop_count (order_drop_count),
    .tx_fifo_overflow (tx_fifo_overflow),
    .ts_wrapped       (ts_wrapped)
  );

  //--------------------------------------------------------------------------
  // Scoreboard
  //--------------------------------------------------------------------------
  int unsigned checks = 0;
  int unsigned errors = 0;
  int unsigned tob_mismatch_frames = 0;
  int unsigned orders_out = 0;

  task automatic check_int(input string name, input int got, input int exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  [FAIL] %-46s got %0d, expected %0d", name, got, exp);
    end else begin
      $display("  [ ok ] %-46s %0d", name, got);
    end
  endtask

  //--------------------------------------------------------------------------
  // Flow-control monitors. Counters, not sticky flags -- a `logic` flag written
  // by a monitor and read by the test process can optimise to a stale copy and
  // pass vacuously.
  //--------------------------------------------------------------------------
  int rx_fifo_stall_n;
  int book_stall_n;

  initial begin
    rx_fifo_stall_n = 0;
    book_stall_n    = 0;
  end

  always @(negedge rgmii_rx_clk)
    if (sys_rst_n && dut.mac_tvalid && !dut.rx_fifo_wr_ready) rx_fifo_stall_n++;

  always @(negedge dut.core_clk)
    if (dut.core_rst_n && dut.upd_tvalid && !dut.upd_tready) book_stall_n++;

  // Count outbound OUCH orders by watching for end-of-frame on the TX pins.
  logic tx_active;
  initial begin
    tx_active   = 1'b0;
    orders_out  = 0;
  end
  always @(negedge rgmii_rx_clk) begin
    if (rgmii_tx_ctl)      tx_active = 1'b1;
    else if (tx_active) begin
      tx_active  = 1'b0;
      orders_out++;
    end
  end

  //--------------------------------------------------------------------------
  // RGMII ingress driver. Nibbles change mid-phase, never on the clock edge --
  // driving on the edge races the DUT's capture flops and the two simulators
  // resolve that race differently.
  //--------------------------------------------------------------------------
  task automatic send_byte(input logic [7:0] data);
    @(negedge rgmii_rx_clk);
    #2;
    rgmii_rxd    = data[3:0];
    rgmii_rx_ctl = 1'b1;
    @(posedge rgmii_rx_clk);
    #2;
    rgmii_rxd    = data[7:4];
    rgmii_rx_ctl = 1'b1;
  endtask

  // One pre-built frame straight from the hex file, preamble prepended here.
  task automatic send_frame(input int offset, input int len);
    for (int i = 0; i < 7; i++) send_byte(8'h55);
    send_byte(8'hD5);
    for (int i = 0; i < len; i++) send_byte(fr_bytes[offset + i]);
    @(negedge rgmii_rx_clk);
    #2;
    rgmii_rx_ctl = 1'b0;
    rgmii_rxd    = 4'h0;
    repeat (12) @(posedge rgmii_rx_clk);        // inter-frame gap
  endtask

  //--------------------------------------------------------------------------
  // Compare every asset's top of book against the reference for this frame.
  //--------------------------------------------------------------------------
  task automatic check_tob(input int frame_idx);
    logic [127:0] e;
    bit           bad;
    bad = 1'b0;
    for (int a = 0; a < NUM_ASSETS; a++) begin
      e = exp_tob[frame_idx * NUM_ASSETS + a];
      if (dut.tob_bid_price[a] !== e[127:96] ||
          dut.tob_bid_qty  [a] !== e[95:64]  ||
          dut.tob_ask_price[a] !== e[63:32]  ||
          dut.tob_ask_qty  [a] !== e[31:0]) begin
        if (!bad) begin
          errors++;
          bad = 1'b1;
        end
        $display("  [FAIL] frame %0d asset %0d ToB: got {%0d,%0d / %0d,%0d} expected {%0d,%0d / %0d,%0d}",
                 frame_idx, a,
                 dut.tob_bid_price[a], dut.tob_bid_qty[a],
                 dut.tob_ask_price[a], dut.tob_ask_qty[a],
                 e[127:96], e[95:64], e[63:32], e[31:0]);
      end
    end
    checks++;
    if (bad) tob_mismatch_frames++;
  endtask

  //--------------------------------------------------------------------------
  // Main
  //--------------------------------------------------------------------------
  initial begin
    int offset;
    int exp_wrap;

    void'($value$plusargs("FRAMES=%s", f_frames));
    void'($value$plusargs("LENS=%s",   f_lens));
    void'($value$plusargs("TOB=%s",    f_tob));

    for (int i = 0; i < MAX_FRAMES; i++) fr_lens[i] = 16'd0;

    $readmemh(f_frames, fr_bytes);
    $readmemh(f_lens,   fr_lens);
    $readmemh(f_tob,    exp_tob);

    n_frames = 0;
    for (int i = 0; i < MAX_FRAMES; i++)
      if (fr_lens[i] != 16'd0) n_frames++;
      else break;

    $display("\n==============================================================");
    $display(" CommonTrader market-data replay");
    $display("   frames = %0d, source = %s", n_frames, f_frames);
    $display("==============================================================");

    if (n_frames == 0) begin
      $display("  [FAIL] no frames loaded -- run sim/csv_to_itch.py first");
      $display("  commontrader_replay_tb : 1 checks, 1 failures");
      $display("  RESULT: 1 FAILURE(S)");
      $finish;
    end

    sys_rst_n      = 1'b0;
    rgmii_rxd      = 4'h0;
    rgmii_rx_ctl   = 1'b0;
    hw_kill_switch_n = 1'b1;   // active-low: idle high = kill NOT asserted

    repeat (20) @(posedge rgmii_rx_clk);
    sys_rst_n = 1'b1;
    repeat (40) @(posedge rgmii_rx_clk);

    offset = 0;
    for (int f = 0; f < n_frames; f++) begin
      send_frame(offset, int'(fr_lens[f]));
      offset += int'(fr_lens[f]);

      // Let the last message of the frame finish resolving and committing:
      // parser resolve/emit is ~4 cycles and the book's worst case is 19, both
      // in the 250 MHz domain, so 40 RGMII cycles is comfortably clear.
      repeat (40) @(posedge rgmii_rx_clk);
      check_tob(f);
    end

    repeat (400) @(posedge rgmii_rx_clk);       // drain any in-flight order

    $display("\n  replayed %0d frames, %0d bytes", n_frames, offset);
    $display("  outbound OUCH orders generated: %0d", orders_out);

    check_int("R1 RX CDC FIFO never back-pressured", rx_fifo_stall_n,        0);
    check_int("R1 Order Book never stalled parser",  book_stall_n,           0);
    check_int("R2 frames with a ToB mismatch",       tob_mismatch_frames,    0);
    check_int("R3 TX CDC FIFO never overflowed",     int'(tx_fifo_overflow), 0);
    // The 16-bit counter spans 65536 ticks x 4 ns = 262 us. A replay longer
    // than that MUST wrap -- that is the counter working, not a fault. What
    // would actually invalidate FS-12 telemetry is a single measurement
    // exceeding the range, which cannot happen while end-to-end latency is
    // ~108 ns. So assert the flag agrees with elapsed time rather than
    // asserting it never sets, which would just be wrong on long runs.
    exp_wrap = ($realtime > 262144.0) ? 1 : 0;
    $display("  elapsed %0.1f us, counter range 262.1 us", $realtime / 1000.0);
    check_int("R4 timestamp wrap flag matches elapsed time",
              int'(ts_wrapped), exp_wrap);

    $display("\n==============================================================");
    $display("  commontrader_replay_tb : %0d checks, %0d failures", checks, errors);
    if (errors == 0) $display("  RESULT: ALL TESTS PASSED");
    else             $display("  RESULT: %0d FAILURE(S)", errors);
    $display("==============================================================\n");
    $finish;
  end

  initial begin
    #500_000_000;
    $display("  [FAIL] watchdog timeout");
    $display("  commontrader_replay_tb : %0d checks, %0d failures", checks, errors + 1);
    $display("  RESULT: TIMEOUT");
    $finish;
  end

endmodule
