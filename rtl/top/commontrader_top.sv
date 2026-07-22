//==============================================================================
// CommonTrader Top Level
//
// Wires the hardware acceleration engine together:
//
//   PHY -> RX MAC -> [RX CDC FIFO] -> Parser -> Order Book -> Alpha Engine
//                                                                   |
//                    PHY <- TX MAC <- [TX CDC FIFO] <- TX Gen <- Risk Gateway
//
// CLOCK DOMAINS
//   rgmii_rx_clk  125 MHz   RX MAC, TX MAC, both FIFO PHY-side ports
//   core_clk      250 MHz   parser, book, alpha, risk, TX gen
//
// The two CDC FIFOs are the ONLY legal crossings for stream data. The few
// single-bit control signals that also cross (rx_error, hw_kill_switch) go
// through the explicit 2-flop synchronisers below -- never straight into logic.
//
// This module owns the SINGLE timestamp_counter instance shared by the parser
// and the TX Generator. Both must read the SAME counter, or the latency
// subtraction has no common time origin and FS-12 is meaningless.
//==============================================================================

module commontrader_top
  import ct_pkg::*;
(
  // --- Board clocks / reset -------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  // The core clock is synthesised from the RGMII reference (the PHY is clock
  // master), so the board oscillator is not currently a datapath source. Kept
  // on the port list for the MMCM reference option and for board bring-up.
  input  logic       sys_clk,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic       sys_rst_n,

  // --- RGMII to/from the onboard PHY ----------------------------------------
  input  logic       rgmii_rx_clk,
  input  logic [3:0] rgmii_rxd,
  input  logic       rgmii_rx_ctl,
  output logic       rgmii_tx_clk,
  output logic [3:0] rgmii_txd,
  output logic       rgmii_tx_ctl,

  // --- Physical kill switch (FS-10) -----------------------------------------
  input  logic       hw_kill_switch,

  // --- Telemetry / status (ILA or status register; not board pins) ----------
  output logic [15:0] order_drop_count,   // orders lost to a busy TX Generator
  output logic        tx_fifo_overflow,   // sticky: TX CDC FIFO overran
  output logic        ts_wrapped          // sticky: timestamp counter rolled over
);

  //--------------------------------------------------------------------------
  // Clocking and reset
  //--------------------------------------------------------------------------
  logic core_clk;
  logic core_rst_n;
  logic phy_rst_n;

  clk_rst_gen u_clk_rst (
    .sys_rst_n    (sys_rst_n),
    .rgmii_rx_clk (rgmii_rx_clk),
    .core_clk     (core_clk),
    .core_rst_n   (core_rst_n),
    .phy_rst_n    (phy_rst_n)
  );

  //--------------------------------------------------------------------------
  // Shared free-running timestamp counter (FS-12)
  //--------------------------------------------------------------------------
  logic [TIMESTAMP_W-1:0] timestamp_now;

  timestamp_counter #(
    .WIDTH (TIMESTAMP_W)
  ) u_timestamp (
    .clk           (core_clk),
    .rst_n         (core_rst_n),
    .timestamp_now (timestamp_now),
    .wrapped       (ts_wrapped)
  );

  //--------------------------------------------------------------------------
  // Control-signal clock domain crossings
  //
  // rx_error is generated in the 125 MHz PHY domain and consumed in the 250 MHz
  // core domain. Slow-to-fast, so a plain 2-flop level synchroniser captures any
  // pulse at least one source cycle wide.
  //
  // hw_kill_switch is a physical input with no clock at all and MUST be
  // synchronised before it reaches logic.
  //--------------------------------------------------------------------------
  logic rx_error;                       // PHY domain, from RX MAC
  logic rx_error_meta, rx_error_sync;   // core domain
  logic kill_meta,     kill_sync;

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      rx_error_meta <= 1'b0;
      rx_error_sync <= 1'b0;
      kill_meta     <= 1'b0;
      kill_sync     <= 1'b0;
    end else begin
      rx_error_meta <= rx_error;
      rx_error_sync <= rx_error_meta;
      kill_meta     <= hw_kill_switch;
      kill_sync     <= kill_meta;
    end
  end

  //--------------------------------------------------------------------------
  // RX MAC (125 MHz PHY domain)
  //--------------------------------------------------------------------------
  logic [7:0] mac_tdata;
  logic       mac_tvalid, mac_tlast;

  rx_mac_core u_rx_mac (
    .rgmii_rx_clk  (rgmii_rx_clk),
    .rgmii_rst_n   (phy_rst_n),
    .rgmii_rxd     (rgmii_rxd),
    .rgmii_rx_ctl  (rgmii_rx_ctl),
    .m_axis_tdata  (mac_tdata),
    .m_axis_tvalid (mac_tvalid),
    .m_axis_tlast  (mac_tlast),
    .rx_error      (rx_error)
  );

  //--------------------------------------------------------------------------
  // RX CDC FIFO: 125 MHz -> 250 MHz
  //
  // The read side drains at twice the write rate, so this only has to absorb
  // reset/startup skew, not a sustained rate mismatch. 32 entries is ample.
  // The RX MAC has no tready (the PHY cannot be back-pressured), so
  // s_axis_tready is deliberately left unconsumed -- it must never go low, and
  // the integration testbench asserts exactly that.
  //--------------------------------------------------------------------------
  logic [7:0] rx_fifo_tdata;
  logic       rx_fifo_tvalid, rx_fifo_tlast, rx_fifo_tready;
  /* verilator lint_off UNUSEDSIGNAL */
  logic       rx_fifo_wr_ready;
  /* verilator lint_on UNUSEDSIGNAL */

  axis_cdc_fifo #(
    .DATA_W (8),
    .ADDR_W (5)               // 32 entries
  ) u_rx_fifo (
    .s_axis_aclk    (rgmii_rx_clk),
    .s_axis_aresetn (phy_rst_n),
    .s_axis_tdata   (mac_tdata),
    .s_axis_tvalid  (mac_tvalid),
    .s_axis_tlast   (mac_tlast),
    .s_axis_tready  (rx_fifo_wr_ready),

    .m_axis_aclk    (core_clk),
    .m_axis_aresetn (core_rst_n),
    .m_axis_tdata   (rx_fifo_tdata),
    .m_axis_tvalid  (rx_fifo_tvalid),
    .m_axis_tlast   (rx_fifo_tlast),
    .m_axis_tready  (rx_fifo_tready)
  );

  //--------------------------------------------------------------------------
  // Cut-through Stream Parser
  //--------------------------------------------------------------------------
  logic [BOOK_UPDATE_W-1:0] upd_tdata;
  logic                     upd_tvalid;
  /* verilator lint_off UNUSEDSIGNAL */
  // The Order Book ties tready high and the parser has no back-pressure input,
  // so this is monitoring only. The integration testbench asserts it stays high.
  logic                     upd_tready;
  // Parser checksum result. DELIBERATELY UNCONNECTED: the Risk Gateway's
  // viol_crc check is stubbed out (see the note at the Risk Gateway below), so
  // there is nothing to drive yet. Wire this to viol_crc when that lands.
  logic                     r_valid;
  /* verilator lint_on UNUSEDSIGNAL */

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
  // Alpha Engine (user sandbox region, FS-8/FS-9)
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
  //
  // NOTE: rx_error_sync is connected, but the gateway's viol_crc check is
  // currently stubbed (the violations vector hardwires that bit to 0), so this
  // input has no effect yet. The synchroniser is in place so that enabling the
  // check is a one-line change inside the gateway rather than a CDC redesign.
  // Same for the blacklist check. 4 of the 6 required checks are live.
  //--------------------------------------------------------------------------
  logic [TRADE_W-1:0] tx_tdata;
  logic               tx_tuser, tx_tvalid;

  pre_trade_risk_gateway u_risk (
    .clk_250mhz          (core_clk),
    .rst_n               (core_rst_n),
    .s_axis_order_tdata  (order_tdata),
    .s_axis_order_tuser  (order_tuser),
    .s_axis_order_tvalid (order_tvalid),
    .rx_error            (rx_error_sync),
    .hw_kill_switch      (kill_sync),
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
  logic       tx_fifo_almost_full;    // from the TX CDC FIFO write side

  outbound_tx_generator u_tx_gen (
    .core_clk            (core_clk),
    .core_rst_n          (core_rst_n),
    .s_axis_trade_tdata  (tx_tdata),
    .s_axis_trade_tuser  (tx_tuser),
    .s_axis_trade_tvalid (tx_tvalid),
    .s_axis_trade_tready (trade_tready),
    .fifo_has_room       (~tx_fifo_almost_full),
    .timestamp_now       (timestamp_now),
    .m_axis_tdata        (tx_byte_tdata),
    .m_axis_tvalid       (tx_byte_tvalid),
    .m_axis_tlast        (tx_byte_tlast)
  );

  //--------------------------------------------------------------------------
  // Dropped-order telemetry
  //
  // The Risk Gateway has no tready input, so an approved trade arriving while
  // trade_tready is low is LOST. trade_tready is low while the TX Generator is
  // serialising a frame AND while the TX CDC FIFO cannot hold another frame, so
  // under sustained load the generator paces itself to the wire and the excess
  // is dropped HERE -- cleanly, and counted -- rather than overrunning the FIFO
  // mid-frame. This is a real ceiling, not a bug to paper over: a full Ethernet
  // frame occupies the wire for 920 ns, so sustained order rates above ~1.09 M/s
  // cannot physically be carried. Counting the losses makes it observable.
  //--------------------------------------------------------------------------
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n)                        order_drop_count <= 16'd0;
    else if (tx_tvalid && !trade_tready &&
             order_drop_count != 16'hFFFF)  order_drop_count <= order_drop_count + 16'd1;
  end

  //--------------------------------------------------------------------------
  // TX CDC FIFO: 250 MHz -> 125 MHz
  //
  // The TX Generator produces bytes ~3x faster than the wire can carry them and
  // has no per-byte back-pressure, so this crossing is kept LOSSLESS by a START
  // GATE rather than by depth alone. s_axis_almost_full asserts once the FIFO can
  // no longer hold a whole outbound frame; the generator will not START a frame
  // while it is high (u_tx_gen.fifo_has_room). Excess orders are then dropped
  // cleanly at the gateway boundary (order_drop_count) instead of being truncated
  // mid-frame on the wire. (Previously the depth alone was load-bearing and a
  // second order 308-920 ns behind the first overran the FIFO -- L1.)
  //
  // DEPTH must be >= one frame: the generator starts only with >= TX_FRAME_BYTES
  // free and then writes up to TX_FRAME_BYTES, so peak occupancy is bounded by
  // the depth. 128 (ADDR_W=7) is the smallest power of two >= 77.
  //--------------------------------------------------------------------------
  localparam int TX_FRAME_BYTES = 77;   // = outbound_tx_generator PKT_LEN

  logic tx_fifo_wr_ready;

  logic [7:0] tx_mac_tdata;
  logic       tx_mac_tvalid, tx_mac_tlast, tx_mac_tready;

  axis_cdc_fifo #(
    .DATA_W             (8),
    .ADDR_W             (7),              // 128 entries -- see note above
    .ALMOST_FULL_THRESH (TX_FRAME_BYTES)  // hold off a frame that would not fit
  ) u_tx_fifo (
    .s_axis_aclk        (core_clk),
    .s_axis_aresetn     (core_rst_n),
    .s_axis_tdata       (tx_byte_tdata),
    .s_axis_tvalid      (tx_byte_tvalid),
    .s_axis_tlast       (tx_byte_tlast),
    .s_axis_tready      (tx_fifo_wr_ready),
    .s_axis_almost_full (tx_fifo_almost_full),

    .m_axis_aclk        (rgmii_rx_clk),
    .m_axis_aresetn     (phy_rst_n),
    .m_axis_tdata       (tx_mac_tdata),
    .m_axis_tvalid      (tx_mac_tvalid),
    .m_axis_tlast       (tx_mac_tlast),
    .m_axis_tready      (tx_mac_tready)
  );

  // Sticky overflow flag: with the almost-full start gate above, this must never
  // assert. If it ever does, the gate or the threshold is wrong and frames are
  // going out corrupted -- pinned as a hard invariant (integration_crv C1).
  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n)                            tx_fifo_overflow <= 1'b0;
    else if (tx_byte_tvalid && !tx_fifo_wr_ready) tx_fifo_overflow <= 1'b1;
  end

  //--------------------------------------------------------------------------
  // TX MAC (125 MHz PHY domain)
  //
  // gmii_tx_clk is the RGMII receive clock: the PHY is clock master for both
  // directions on this board. See the note in clk_rst_gen if that ever changes.
  //--------------------------------------------------------------------------
  tx_mac_core u_tx_mac (
    .gmii_tx_clk   (rgmii_rx_clk),
    .rst_n         (phy_rst_n),
    .s_axis_tdata  (tx_mac_tdata),
    .s_axis_tvalid (tx_mac_tvalid),
    .s_axis_tlast  (tx_mac_tlast),
    .s_axis_tready (tx_mac_tready),
    .rgmii_txc     (rgmii_tx_clk),
    .rgmii_txd     (rgmii_txd),
    .rgmii_tx_ctl  (rgmii_tx_ctl)
  );

endmodule
