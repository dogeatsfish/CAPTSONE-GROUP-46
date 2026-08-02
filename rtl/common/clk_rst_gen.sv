//==============================================================================
// clk_rst_gen  -  core clock synthesis and per-domain reset sequencing
//
// The design has two clock domains:
//   rgmii_rx_clk  125 MHz   RX MAC (recovered from the PHY)
//   core_clk      250 MHz   everything between the CDC FIFOs
//   gmii_tx_clk   125 MHz   TX MAC (see note below)
//
// core_clk is synthesised from the 125 MHz RGMII reference by an MMCM
// (VCO 1000 MHz = 125 x 8, output divide 4). Under simulation the MMCM is
// replaced by a behavioural clock source so the whole chip elaborates without
// vendor libraries -- the same `ifdef SYNTHESIS` pattern tx_mac_core already
// uses for its ODDR stage.
//
// RESET DISCIPLINE
//   Both domain resets are ASYNCHRONOUSLY ASSERTED and SYNCHRONOUSLY RELEASED.
//   Asserting synchronously is unsafe (no clock, no reset); releasing
//   asynchronously is unsafe (flops on either side of the domain can leave reset
//   on different cycles and the FIFO pointers desynchronise). The 2-flop
//   synchroniser below is the standard fix for both.
//
//   core_rst_n is additionally gated by MMCM lock: releasing the core domain
//   before the clock is stable would clock garbage into the parser and the book.
//
// TX CLOCK NOTE
//   gmii_tx_clk is driven from rgmii_rx_clk here. That is correct ONLY because
//   the PHY is the clock master for both directions in this design. If the board
//   is ever strapped so TX runs from an independent 125 MHz source, this becomes
//   a third domain and the TX CDC FIFO's read side must follow it instead.
//==============================================================================

module clk_rst_gen #(
  // Simulation-only: half period of the behavioural core clock, in ps.
  // 2222 ps -> 4.444 ns period -> 225 MHz, matching ct_pkg::CORE_PERIOD_NS.
  parameter int CORE_HALF_PERIOD_PS = 2222
)(
  input  logic board_clk,       // 200 MHz free-running system clock
  input  logic sys_rst_n,       // board reset, active low, bouncy
  input  logic rgmii_rx_clk,    // 125 MHz from PHY

  output logic core_clk,        // 250 MHz
  output logic core_rst_n,      // synchronous to core_clk
  output logic phy_rst_n,       // synchronous to rgmii_rx_clk
  output logic eth_phy_rst_n    // to PHY hardware reset pin
);

  // Module-scoped, so it cannot leak into other files the way a `timescale
  // directive does. This is the only RTL module that contains a delay (the
  // behavioural clock source below) and xsim will not elaborate a delay in a
  // module with no time unit.
  timeunit      1ns;
  timeprecision 1ps;

  logic mmcm_locked;

  //--------------------------------------------------------------------------
  // 1. Debounce sys_rst_n using the free-running board_clk
  //--------------------------------------------------------------------------
  logic [19:0] debounce_cnt = '0;
  logic rst_debounced_n = 1'b0;
  logic sys_rst_sync_1, sys_rst_sync_2;

  always_ff @(posedge board_clk) begin
    sys_rst_sync_1 <= sys_rst_n;
    sys_rst_sync_2 <= sys_rst_sync_1;
    
    if (sys_rst_sync_2 == rst_debounced_n) begin
      debounce_cnt <= '0;
    end else begin
      debounce_cnt <= debounce_cnt + 1;
      if (debounce_cnt == 20'd1_000_000) begin // 5ms debounce @ 200MHz
        rst_debounced_n <= sys_rst_sync_2;
        debounce_cnt <= '0;
      end
    end
  end

  //--------------------------------------------------------------------------
  // 2. Generate a clean 10ms eth_phy_rst_n pulse
  //--------------------------------------------------------------------------
  logic [20:0] phy_rst_timer = '0;
  always_ff @(posedge board_clk) begin
    if (!rst_debounced_n) begin
      phy_rst_timer <= '0;
      eth_phy_rst_n <= 1'b0;
    end else begin
      if (phy_rst_timer < 21'd2_000_000) begin // 10ms @ 200MHz
        phy_rst_timer <= phy_rst_timer + 1;
        eth_phy_rst_n <= 1'b0;
      end else begin
        eth_phy_rst_n <= 1'b1;
      end
    end
  end

  //--------------------------------------------------------------------------
  // Core clock
  //--------------------------------------------------------------------------
`ifdef SYNTHESIS
  logic clk_fb, clkout0, core_clk_unbuf;
  logic [19:0] phy_clk_ready_cnt = '0;
  logic mmcm_rst_sync;

  always_ff @(posedge rgmii_rx_clk or negedge eth_phy_rst_n) begin
    if (!eth_phy_rst_n) begin
      phy_clk_ready_cnt <= '0;
      mmcm_rst_sync     <= 1'b1;
    end else begin
      if (phy_clk_ready_cnt < 20'd125_000) begin
        phy_clk_ready_cnt <= phy_clk_ready_cnt + 1;
        mmcm_rst_sync     <= 1'b1;
      end else begin
        mmcm_rst_sync     <= 1'b0;
      end
    end
  end

  MMCME2_BASE #(
    .CLKIN1_PERIOD    (8.0),    // 125 MHz
    .DIVCLK_DIVIDE    (1),
    .CLKFBOUT_MULT_F  (9.0),    // VCO = 1125 MHz (inside the Artix-7 range, exact multiple of 0.125)
    .CLKOUT0_DIVIDE_F (5.0),    // 1125 / 5 = 225 MHz
    .STARTUP_WAIT     ("FALSE")
  ) u_mmcm (
    .CLKIN1   (rgmii_rx_clk),
    .CLKFBIN  (clk_fb),
    .CLKFBOUT (clk_fb),
    .CLKOUT0  (core_clk_unbuf),
    .LOCKED   (mmcm_locked),
    .PWRDWN   (1'b0),
    .RST      (~eth_phy_rst_n | mmcm_rst_sync)
  );

  BUFG u_bufg_core (.I(core_clk_unbuf), .O(core_clk));

`else
  //--------------------------------------------------------------------------
  // Behavioural equivalent. Free-running: it does NOT stop under reset, because
  // the reset synchronisers below need a clock in order to release.
  //--------------------------------------------------------------------------
  initial core_clk = 1'b0;
  always #(CORE_HALF_PERIOD_PS * 1ps) core_clk = ~core_clk;

  // Model the lock delay so the reset sequencing is actually exercised in sim
  // rather than being trivially satisfied at time zero.
  localparam int LOCK_CYCLES = 16;
  int unsigned lock_cnt;

  always_ff @(posedge core_clk or negedge eth_phy_rst_n) begin
    if (!eth_phy_rst_n) begin
      lock_cnt    <= '0;
      mmcm_locked <= 1'b0;
    end else if (lock_cnt < LOCK_CYCLES) begin
      lock_cnt    <= lock_cnt + 1;
      mmcm_locked <= 1'b0;
    end else begin
      mmcm_locked <= 1'b1;
    end
  end
`endif

  //--------------------------------------------------------------------------
  // Reset synchronisers: async assert, sync release.
  //--------------------------------------------------------------------------
  logic core_rst_meta, phy_rst_meta;
  logic core_rst_src;

  (* max_fanout = 256 *) logic core_rst_n_q;
  (* max_fanout = 256 *) logic phy_rst_n_q;

  assign core_rst_src = rst_debounced_n & mmcm_locked;

  assign core_rst_n = core_rst_n_q;
  assign phy_rst_n  = phy_rst_n_q;

  always_ff @(posedge core_clk or negedge core_rst_src) begin
    if (!core_rst_src) begin
      core_rst_meta <= 1'b0;
      core_rst_n_q  <= 1'b0;
    end else begin
      core_rst_meta <= 1'b1;
      core_rst_n_q  <= core_rst_meta;
    end
  end

  always_ff @(posedge rgmii_rx_clk or negedge eth_phy_rst_n) begin
    if (!eth_phy_rst_n) begin
      phy_rst_meta <= 1'b0;
      phy_rst_n_q  <= 1'b0;
    end else begin
      phy_rst_meta <= 1'b1;
      phy_rst_n_q  <= phy_rst_meta;
    end
  end

endmodule
