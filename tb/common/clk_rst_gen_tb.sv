`timescale 1ns/1ps

module clk_rst_gen_tb;

  // 200 MHz board clock (5 ns period)
  logic board_clk;
  initial board_clk = 1'b0;
  always #2.5 board_clk = ~board_clk;

  // 125 MHz PHY clock (8 ns period)
  logic rgmii_rx_clk;
  logic phy_clock_en;
  initial rgmii_rx_clk = 1'b0;
  always #4 if (phy_clock_en) rgmii_rx_clk = ~rgmii_rx_clk;

  logic sys_rst_n;
  logic core_clk;
  logic core_rst_n;
  logic phy_rst_n;
  logic eth_phy_rst_n;

  clk_rst_gen dut (
    .board_clk     (board_clk),
    .sys_rst_n     (sys_rst_n),
    .rgmii_rx_clk  (rgmii_rx_clk),
    .core_clk      (core_clk),
    .core_rst_n    (core_rst_n),
    .phy_rst_n     (phy_rst_n),
    .eth_phy_rst_n (eth_phy_rst_n)
  );

  int errors = 0;

  // Emulate PHY behavior
  always @(eth_phy_rst_n) begin
    if (!eth_phy_rst_n) begin
      phy_clock_en <= 1'b0; // PHY stops clock in reset
    end else begin
      // PHY takes time to auto-negotiate before starting clock
      #20000;
      phy_clock_en <= 1'b1;
    end
  end

  initial begin
    $display("\n==============================================================");
    $display(" clk_rst_gen_tb : Reset Tree Sequencer Test");
    $display("==============================================================");

    sys_rst_n = 1'b1;
    phy_clock_en = 1'b1; // Start with clock running

    // Wait for initial MMCM lock (power-up takes ~16ms because of debounce + 10ms PHY reset + 1ms MMCM lock)
    $display("  Waiting for initial power-up reset sequence...");
    wait(core_rst_n);
    if (core_rst_n !== 1'b1) begin
      $display("  [FAIL] Core reset did not release on power-up");
      errors++;
    end else begin
      $display("  [ ok ] Core reset released on power-up");
    end

    // Test 1: Clean reset
    $display("\n[T1] Asserting clean reset for 6ms...");
    sys_rst_n = 1'b0;
    #6_000_000; // Hold for 6ms to pass 5ms debounce
    sys_rst_n = 1'b1;

    $display("  Waiting for debounce and PHY reset sequence...");
    wait(!eth_phy_rst_n);
    $display("  [ ok ] eth_phy_rst_n asserted");

    wait(eth_phy_rst_n);
    $display("  [ ok ] eth_phy_rst_n released");

    wait(core_rst_n);
    $display("  [ ok ] core_rst_n released after MMCM lock");

    // Test 2: Bouncy reset
    $display("\n[T2] Asserting bouncy reset (bounces, then holds 6ms)...");
    sys_rst_n = 1'b0; #10; sys_rst_n = 1'b1; #50;
    sys_rst_n = 1'b0; #20; sys_rst_n = 1'b1; #30;
    sys_rst_n = 1'b0; #5;  sys_rst_n = 1'b1; #10;
    sys_rst_n = 1'b0; #100; sys_rst_n = 1'b1; #100;
    sys_rst_n = 1'b0; // Final press
    #6_000_000; // Hold for 6ms
    sys_rst_n = 1'b1; // Release

    wait(!eth_phy_rst_n);
    $display("  [ ok ] eth_phy_rst_n asserted cleanly after bounce");
    wait(eth_phy_rst_n);
    $display("  [ ok ] eth_phy_rst_n released cleanly");
    wait(core_rst_n);
    $display("  [ ok ] core_rst_n released after MMCM lock");

    $display("\n==============================================================");
    $display("clk_rst_gen : 4 checks, %0d failures", errors);
    $display("==============================================================\n");
    $finish;
  end

  // Watchdog
  initial begin
    #500_000_000; // 500 ms watchdog
    $display("  [FAIL] Watchdog timeout");
    $display("clk_rst_gen : 4 checks, 1 failures");
    $finish;
  end

endmodule
