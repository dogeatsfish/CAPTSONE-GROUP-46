//==============================================================================
// axis_cdc_fifo  -  AXI4-Stream clock domain crossing FIFO
//
// Thin AXI4-Stream shell around cdc_fifo. ONE module serves both crossings in
// the design; only the clock hookup differs:
//
//   RX CDC FIFO :  s_axis_aclk = 125 MHz (RGMII)   m_axis_aclk = 250 MHz (core)
//   TX CDC FIFO :  s_axis_aclk = 250 MHz (core)    m_axis_aclk = 125 MHz (RGMII)
//
// tlast rides through the FIFO alongside tdata so packet framing survives the
// crossing -- losing it would leave the parser and TX MAC unable to find a
// packet boundary.
//
// NOTE on the RX side: the RX MAC has no tready (the PHY cannot be
// back-pressured), so s_axis_tready must never actually go low there. Size the
// depth so it cannot: the read side runs at 2x the write rate, so the FIFO only
// needs to absorb reset/startup skew, not sustained rate mismatch.
//==============================================================================

module axis_cdc_fifo #(
  parameter int DATA_W = 8,             // tdata width
  parameter int ADDR_W = 5,             // depth = 2**ADDR_W entries
  parameter int ALMOST_FULL_THRESH = 0  // s_axis_almost_full when < THRESH free
)(
  // --- write side (slave) ---------------------------------------------------
  input  logic              s_axis_aclk,
  input  logic              s_axis_aresetn,
  input  logic [DATA_W-1:0] s_axis_tdata,
  input  logic              s_axis_tvalid,
  input  logic              s_axis_tlast,
  output logic              s_axis_tready,
  output logic              s_axis_almost_full,   // write-domain: cannot fit a
                                                  // further THRESH beats (0=off)

  // --- read side (master) ---------------------------------------------------
  input  logic              m_axis_aclk,
  input  logic              m_axis_aresetn,
  output logic [DATA_W-1:0] m_axis_tdata,
  output logic              m_axis_tvalid,
  output logic              m_axis_tlast,
  input  logic              m_axis_tready
);

  logic              full, empty;
  logic [DATA_W:0]   wr_word, rd_word;

  assign wr_word       = {s_axis_tlast, s_axis_tdata};
  assign s_axis_tready = ~full;
  assign m_axis_tvalid = ~empty;

  assign {m_axis_tlast, m_axis_tdata} = rd_word;

  cdc_fifo #(
    .DATA_W (DATA_W + 1),        // +1 carries tlast
    .ADDR_W (ADDR_W),
    .ALMOST_FULL_THRESH (ALMOST_FULL_THRESH)
  ) u_fifo (
    .wr_clk         (s_axis_aclk),
    .wr_rst_n       (s_axis_aresetn),
    .wr_en          (s_axis_tvalid & ~full),
    .wr_data        (wr_word),
    .wr_full        (full),
    .wr_almost_full (s_axis_almost_full),

    .rd_clk   (m_axis_aclk),
    .rd_rst_n (m_axis_aresetn),
    .rd_en    (m_axis_tready & ~empty),
    .rd_data  (rd_word),
    .rd_empty (empty)
  );

endmodule
