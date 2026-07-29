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
  // 2000 ps -> 4 ns period -> 250 MHz, matching ct_pkg::CORE_PERIOD_NS.
  parameter int CORE_HALF_PERIOD_PS = 2000
)(
  input  logic sys_rst_n,       // board reset, active low, asynchronous
  input  logic rgmii_rx_clk,    // 125 MHz from PHY

  output logic core_clk,        // 250 MHz
  output logic core_rst_n,      // synchronous to core_clk
  output logic phy_rst_n        // synchronous to rgmii_rx_clk
);

  // Module-scoped, so it cannot leak into other files the way a `timescale
  // directive does. This is the only RTL module that contains a delay (the
  // behavioural clock source below) and xsim will not elaborate a delay in a
  // module with no time unit.
  timeunit      1ns;
  timeprecision 1ps;

  logic mmcm_locked;

  //--------------------------------------------------------------------------
  // Core clock
  //--------------------------------------------------------------------------
`ifdef SYNTHESIS
  logic clk_fb, clkout0, core_clk_unbuf;

  MMCME2_BASE #(
    .CLKIN1_PERIOD    (8.0),    // 125 MHz
    .DIVCLK_DIVIDE    (1),
    .CLKFBOUT_MULT_F  (8.0),    // VCO = 1000 MHz (inside the Artix-7 range)
    .CLKOUT0_DIVIDE_F (4.0),    // 1000 / 4 = 250 MHz
    .STARTUP_WAIT     ("FALSE")
  ) u_mmcm (
    .CLKIN1   (rgmii_rx_clk),
    .CLKFBIN  (clk_fb),
    .CLKFBOUT (clk_fb),
    .CLKOUT0  (core_clk_unbuf),
    .LOCKED   (mmcm_locked),
    .PWRDWN   (1'b0),
    .RST      (~sys_rst_n)
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

  always_ff @(posedge core_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
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
  //
  // TIMING: the final flop of each synchroniser drives the async clear/preset
  // pin of every flop in its domain (core_rst_n reached ~13,600 loads), and the
  // synchronous RELEASE of that net is timed (recovery). One flop driving the
  // whole die failed recovery by -3.1 ns on route delay alone. MAX_FANOUT tells
  // synthesis to replicate the final flop (replicas keep the async-assert pin),
  // turning one die-spanning net into ~50 short regional ones.
  //--------------------------------------------------------------------------
  logic core_rst_meta, phy_rst_meta;
  logic core_rst_src;

  (* max_fanout = 256 *) logic core_rst_n_q;
  (* max_fanout = 256 *) logic phy_rst_n_q;

  assign core_rst_src = sys_rst_n & mmcm_locked;

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

  always_ff @(posedge rgmii_rx_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      phy_rst_meta <= 1'b0;
      phy_rst_n_q  <= 1'b0;
    end else begin
      phy_rst_meta <= 1'b1;
      phy_rst_n_q  <= phy_rst_meta;
    end
  end

endmodule
