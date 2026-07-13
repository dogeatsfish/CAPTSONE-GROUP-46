//==============================================================================
// CommonTrader Top Level
//
// Wires the hardware acceleration engine together:
//
//   PHY -> RX MAC -> [RX CDC FIFO] -> Parser -> Order Book -> Alpha Engine
//                                                                   |
//                    PHY <- TX MAC <- [TX CDC FIFO] <- TX Gen <- Risk Gateway
//
// Blocks in [brackets] are vendor IP (ND). Everything else is ours (D).
//
// This module also owns the SINGLE free-running timestamp counter shared by the
// parser and the TX Generator. Both must sample the SAME counter, or the
// latency subtraction has no common time origin and FS-12 is meaningless.
//==============================================================================

module commontrader_top
  import ct_pkg::*;
(
  // --- Board clocks / reset -------------------------------------------------
  input  logic       sys_clk,          // board oscillator
  input  logic       sys_rst_n,

  // --- RGMII to/from the onboard PHY ----------------------------------------
  input  logic       rgmii_rx_clk,
  input  logic [3:0] rgmii_rxd,
  input  logic       rgmii_rx_ctl,
  output logic       rgmii_tx_clk,
  output logic [3:0] rgmii_txd,
  output logic       rgmii_tx_ctl,

  // --- Physical kill switch (FS-10) -----------------------------------------
  input  logic       hw_kill_switch
);

  //--------------------------------------------------------------------------
  // Clocking
  //--------------------------------------------------------------------------
  logic core_clk;     // 250 MHz, from MMCM
  logic core_rst_n;

  // TODO: instantiate MMCM (Clocking Wizard) to generate the 250 MHz core clock
  //       from the 125 MHz RGMII reference. Confirm which pin supplies the
  //       reference on the AX7A200B.

  //--------------------------------------------------------------------------
  // Shared free-running timestamp counter
  //
  // ONE counter, read by BOTH the parser (packet in) and the TX Generator
  // (order out). If these were separate counters, their difference would be
  // meaningless. 16 bits @ 4 ns = 262 us range; cannot wrap in a measurement
  // window.
  //--------------------------------------------------------------------------
  logic [TIMESTAMP_W-1:0] timestamp_now;

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) timestamp_now <= '0;
    else             timestamp_now <= timestamp_now + 1'b1;
  end

  //--------------------------------------------------------------------------
  // RX path
  //--------------------------------------------------------------------------
  logic [7:0] mac_tdata;
  logic       mac_tvalid, mac_tlast;
  logic       rx_error;

  rx_mac_core u_rx_mac (
    .rgmii_rx_clk  (rgmii_rx_clk),
    .rgmii_rst_n   (sys_rst_n),
    .rgmii_rxd     (rgmii_rxd),
    .rgmii_rx_ctl  (rgmii_rx_ctl),
    .m_axis_tdata  (mac_tdata),
    .m_axis_tvalid (mac_tvalid),
    .m_axis_tlast  (mac_tlast),
    .rx_error      (rx_error)
  );

  // --- RX CDC FIFO (ND): 125 MHz -> 250 MHz ---------------------------------
  logic [7:0] rx_fifo_tdata;
  logic       rx_fifo_tvalid, rx_fifo_tlast, rx_fifo_tready;

  // TODO: instantiate the vendor async FIFO IP here.

  //--------------------------------------------------------------------------
  // Parser
  //--------------------------------------------------------------------------
  logic [BOOK_UPDATE_W-1:0] upd_tdata;
  logic                     upd_tvalid, upd_tready;
  logic                     r_valid;

  cut_through_parser u_parser (
    .core_clk      (core_clk),
    .core_rst_n    (core_rst_n),
    .s_axis_tdata  (rx_fifo_tdata),
    .s_axis_tvalid (rx_fifo_tvalid),
    .s_axis_tlast  (rx_fifo_tlast),
    .s_axis_tready (rx_fifo_tready),
    .timestamp_now (timestamp_now),
    .m_axis_tdata  (upd_tdata),
    .m_axis_tvalid (upd_tvalid),
    .r_valid       (r_valid)
  );

  //--------------------------------------------------------------------------
  // Order Book Array
  //--------------------------------------------------------------------------
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

  order_book_array u_order_book (
    .core_clk      (core_clk),
    .core_rst_n    (core_rst_n),
    .s_axis_tdata  (upd_tdata),
    .s_axis_tvalid (upd_tvalid),
    .s_axis_tready (upd_tready),
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
  // Alpha Engine  (user sandbox region, FS-8/FS-9)
  //--------------------------------------------------------------------------
  logic [TRADE_W-1:0] order_tdata;
  logic               order_tuser, order_tvalid;

  alpha_engine_core u_alpha (
    .core_clk           (core_clk),
    .core_rst_n         (core_rst_n),
    .tob_bid_price      (tob_bid_price),
    .tob_bid_qty        (tob_bid_qty),
    .tob_ask_price      (tob_ask_price),
    .tob_ask_qty        (tob_ask_qty),
    .tob_timestamp      (tob_timestamp),
    .tob_updated        (tob_updated),
    .book_busy          (book_busy),
    .depth_rd_addr      (depth_rd_addr),
    .depth_rd_en        (depth_rd_en),
    .depth_rd_data      (depth_rd_data),
    .m_axis_order_tdata (order_tdata),
    .m_axis_order_tuser (order_tuser),
    .m_axis_order_tvalid(order_tvalid)
  );

  //--------------------------------------------------------------------------
  // Pre-Trade Risk Gateway
  //--------------------------------------------------------------------------
  logic [TRADE_W-1:0] tx_tdata;
  logic               tx_tuser, tx_tvalid;

  pre_trade_risk_gateway u_risk (
    .clk_250mhz          (core_clk),
    .rst_n               (core_rst_n),
    .s_axis_order_tdata  (order_tdata),
    .s_axis_order_tuser  (order_tuser),
    .s_axis_order_tvalid (order_tvalid),
    .rx_error            (rx_error),
    .hw_kill_switch      (hw_kill_switch),
    .m_axis_tx_tdata     (tx_tdata),
    .m_axis_tx_tuser     (tx_tuser),
    .m_axis_tx_tvalid    (tx_tvalid)
  );

  //--------------------------------------------------------------------------
  // Outbound TX Generator
  //--------------------------------------------------------------------------
  logic [7:0] tx_byte_tdata;
  logic       tx_byte_tvalid, tx_byte_tlast;
  logic       trade_tready;

  outbound_tx_generator u_tx_gen (
    .core_clk            (core_clk),
    .core_rst_n          (core_rst_n),
    .s_axis_trade_tdata  (tx_tdata),
    .s_axis_trade_tuser  (tx_tuser),
    .s_axis_trade_tvalid (tx_tvalid),
    .s_axis_trade_tready (trade_tready),
    .timestamp_now       (timestamp_now),
    .m_axis_tdata        (tx_byte_tdata),
    .m_axis_tvalid       (tx_byte_tvalid),
    .m_axis_tlast        (tx_byte_tlast)
  );

  //--------------------------------------------------------------------------
  // TX CDC FIFO (ND) + TX MAC Core (ND): 250 MHz -> 125 MHz -> RGMII
  //--------------------------------------------------------------------------
  // TODO: instantiate the vendor TX FIFO and TX MAC.

endmodule
