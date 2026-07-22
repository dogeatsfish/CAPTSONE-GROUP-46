//==============================================================================
// tx_mac_core  -  Ethernet transmit MAC (RGMII), 125 MHz
//
// Replaces the vendor TX MAC IP. Mirror image of the RX MAC: where the RX MAC
// strips preamble/SFD and the 14-byte L2 header, this PREPENDS them.
//
// The Outbound TX Generator emits IPv4 + UDP + payload only (its first byte is
// IPv4 byte 0), exactly matching what the RX MAC hands upstream. The Ethernet
// framing therefore has to be re-attached here:
//
//   [7x 0x55 preamble][0xD5 SFD][dst MAC 6][src MAC 6][ethertype 2]
//   [payload from FIFO][zero pad to 60 B][FCS 4] then 12 bytes of IFG
//
// Minimum frame: Ethernet requires 64 bytes on the wire including FCS, so the
// header+payload region is zero-padded up to 60 bytes before the FCS.
//
//------------------------------------------------------------------------------
// SYMMETRY WITH rx_mac_core
//   rx_mac_core : RGMII in  -> IDDR inline -> FSM -> AXI-Stream out
//   tx_mac_core : AXI-Stream in -> FSM -> ODDR inline -> RGMII out
//
//   Both share the SAME crc module (rtl/rx_mac/crc.sv, crcgen-generated, public
//   domain) driven from a private CRC register. Using one implementation for
//   both directions is deliberate: if the transmit FCS and the receive check
//   ever disagreed, every frame we send would be silently dropped by the peer.
//   The shared module makes divergence impossible rather than merely unlikely.
//
//   NOTE: the copy of crc.sv on this branch is byte-identical to the one on
//   goldenow/rx_mac and lives at the same path, so the two merge as a no-op.
//   Once both land on main, hoist it to a shared location (rtl/common/).
//
// CRC-32 is IEEE 802.3 in its REFLECTED (LSB-first) form: poly 0xEDB88320,
// init 0xFFFF_FFFF, final XOR 0xFFFF_FFFF, transmitted least-significant byte
// first. It covers the L2 header + payload + padding -- not the preamble/SFD,
// and not itself. A receiver running the same CRC across body+FCS lands on the
// residue 0xDEBB20E3, which is exactly what rx_mac_core checks.
//   (The design report's 0xC704DD7B is the non-reflected residue and does not
//    apply to either block as built.)
//
// The ODDR instantiation is `ifdef`-guarded with a behavioural equivalent so
// the whole TX MAC still elaborates under Verilator (rx_mac_core relies on
// Vivado xsim's unisims and cannot). Everything above the DDR stage is plain
// RTL and is what the unit testbench exercises.
//==============================================================================

module tx_mac_core #(
  parameter logic [47:0] DST_MAC   = 48'hAA_BB_CC_DD_EE_FF,
  parameter logic [47:0] SRC_MAC   = 48'h00_0A_35_01_02_03,  // Xilinx OUI
  parameter logic [15:0] ETHERTYPE = 16'h0800                // IPv4
)(
  input  logic       gmii_tx_clk,     // 125 MHz
  input  logic       rst_n,

  // --- AXI4-Stream slave from the TX CDC FIFO -------------------------------
  input  logic [7:0] s_axis_tdata,
  input  logic       s_axis_tvalid,
  input  logic       s_axis_tlast,
  output logic       s_axis_tready,

  // --- RGMII to PHY (125 MHz domain) ----------------------------------------
  output logic       rgmii_txc,       // forwarded transmit clock
  output logic [3:0] rgmii_txd,       // DDR data bus
  output logic       rgmii_tx_ctl     // DDR control: TX_EN rising, TX_EN^TX_ER falling
);

  // Internal GMII stage. All MAC logic drives these; the DDR block at the
  // bottom is a pure output converter.
  logic [7:0] gmii_txd;
  logic       gmii_tx_en;
  logic       gmii_tx_er;

  //--------------------------------------------------------------------------
  // Frame geometry
  //--------------------------------------------------------------------------
  localparam int PREAMBLE_LEN = 8;    // 7x 0x55 + SFD
  localparam int L2_HDR_LEN   = 14;   // dst(6) + src(6) + ethertype(2)
  localparam int MIN_FRAME    = 60;   // pre-FCS minimum (64 on the wire)
  localparam int FCS_LEN      = 4;
  localparam int IFG_LEN      = 12;   // inter-frame gap

  localparam logic [7:0] PREAMBLE_BYTE = 8'h55;
  localparam logic [7:0] SFD_BYTE      = 8'hD5;

  //--------------------------------------------------------------------------
  // FSM
  //--------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    PREAMBLE,     // 7x 0x55 then SFD
    L2_HEADER,    // dst / src / ethertype
    PAYLOAD,      // bytes from the FIFO
    PAD,          // zero-fill to the 60-byte minimum
    SEND_FCS,     // 4 CRC bytes, LSB first
    IFG           // 12 idle byte times
  } tx_state_e;

  tx_state_e   state;
  logic [3:0]  pre_cnt;      // 0..7  preamble
  logic [3:0]  hdr_cnt;      // 0..13 L2 header
  logic [15:0] frame_cnt;    // bytes emitted since the start of the L2 header
  logic [1:0]  fcs_cnt;
  logic [3:0]  ifg_cnt;

  //--------------------------------------------------------------------------
  // Parallel CRC-32, shared with the RX MAC.
  //
  // crc_data / crc_en select the byte being transmitted this cycle, so the CRC
  // always tracks exactly what goes out on gmii_txd.
  //--------------------------------------------------------------------------
  logic [31:0] crc_reg, crc_next;
  logic [7:0]  crc_data;
  logic        crc_en;
  logic [31:0] fcs;
  logic [7:0]  hdr_byte;      // L2 header byte select, computed below

  assign fcs = ~crc_reg;      // final XOR

  crc u_crc (
    .crcIn  (crc_reg),
    .data   (crc_data),
    .crcOut (crc_next)
  );

  always_comb begin
    crc_data = 8'h00;
    crc_en   = 1'b0;
    case (state)
      L2_HEADER: begin crc_data = hdr_byte;                            crc_en = 1'b1; end
      PAYLOAD:   begin crc_data = s_axis_tvalid ? s_axis_tdata : 8'h00; crc_en = 1'b1; end
      PAD:       begin crc_data = 8'h00;                                crc_en = 1'b1; end
      default: ;   // preamble/SFD and the FCS itself are not covered
    endcase
  end

  always_ff @(posedge gmii_tx_clk or negedge rst_n) begin
    if (!rst_n)              crc_reg <= 32'hFFFF_FFFF;
    else if (state == IDLE)  crc_reg <= 32'hFFFF_FFFF;
    else if (crc_en)         crc_reg <= crc_next;
  end

  //--------------------------------------------------------------------------
  // Byte selects
  //--------------------------------------------------------------------------
  always_comb begin
    case (hdr_cnt)
      4'd0:    hdr_byte = DST_MAC[47:40];
      4'd1:    hdr_byte = DST_MAC[39:32];
      4'd2:    hdr_byte = DST_MAC[31:24];
      4'd3:    hdr_byte = DST_MAC[23:16];
      4'd4:    hdr_byte = DST_MAC[15:8];
      4'd5:    hdr_byte = DST_MAC[7:0];
      4'd6:    hdr_byte = SRC_MAC[47:40];
      4'd7:    hdr_byte = SRC_MAC[39:32];
      4'd8:    hdr_byte = SRC_MAC[31:24];
      4'd9:    hdr_byte = SRC_MAC[23:16];
      4'd10:   hdr_byte = SRC_MAC[15:8];
      4'd11:   hdr_byte = SRC_MAC[7:0];
      4'd12:   hdr_byte = ETHERTYPE[15:8];
      default: hdr_byte = ETHERTYPE[7:0];
    endcase
  end

  // FCS byte select (least-significant byte first)
  logic [7:0] fcs_byte;
  always_comb begin
    case (fcs_cnt)
      2'd0:    fcs_byte = fcs[7:0];
      2'd1:    fcs_byte = fcs[15:8];
      2'd2:    fcs_byte = fcs[23:16];
      default: fcs_byte = fcs[31:24];
    endcase
  end

  // Only accept FIFO bytes while actually streaming the payload.
  assign s_axis_tready = (state == PAYLOAD);

  //--------------------------------------------------------------------------
  // Transmit FSM
  //--------------------------------------------------------------------------
  always_ff @(posedge gmii_tx_clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= IDLE;
      pre_cnt    <= '0;
      hdr_cnt    <= '0;
      frame_cnt  <= '0;
      fcs_cnt    <= '0;
      ifg_cnt    <= '0;
      gmii_txd   <= 8'h00;
      gmii_tx_en <= 1'b0;
      gmii_tx_er <= 1'b0;
    end else begin
      gmii_tx_en <= 1'b0;
      gmii_tx_er <= 1'b0;
      gmii_txd   <= 8'h00;

      case (state)

        //--------------------------------------------------------------------
        IDLE: begin
          frame_cnt <= '0;
          hdr_cnt   <= '0;
          fcs_cnt   <= '0;
          if (s_axis_tvalid) begin      // a packet is waiting in the FIFO
            gmii_txd   <= PREAMBLE_BYTE;
            gmii_tx_en <= 1'b1;
            pre_cnt    <= 4'd1;
            state      <= PREAMBLE;
          end
        end

        //--------------------------------------------------------------------
        // 7 preamble bytes then the SFD. Not covered by the CRC.
        //--------------------------------------------------------------------
        PREAMBLE: begin
          gmii_tx_en <= 1'b1;
          gmii_txd   <= (pre_cnt == 4'(PREAMBLE_LEN - 1)) ? SFD_BYTE
                                                          : PREAMBLE_BYTE;
          if (pre_cnt == 4'(PREAMBLE_LEN - 1)) state <= L2_HEADER;
          pre_cnt <= pre_cnt + 4'd1;
        end

        //--------------------------------------------------------------------
        // dst MAC / src MAC / ethertype. CRC starts here.
        //--------------------------------------------------------------------
        L2_HEADER: begin
          gmii_tx_en <= 1'b1;
          gmii_txd   <= hdr_byte;
          frame_cnt  <= frame_cnt + 16'd1;
          if (hdr_cnt == 4'(L2_HDR_LEN - 1)) state <= PAYLOAD;
          hdr_cnt <= hdr_cnt + 4'd1;
        end

        //--------------------------------------------------------------------
        // Payload straight from the FIFO.
        //
        // The FIFO is written at 250 MHz and drained here at 125 MHz, so it
        // fills faster than it empties and cannot underrun once a frame has
        // started. If it ever does (a bug upstream), tx_er is asserted so the
        // peer discards the frame instead of silently accepting a short one.
        //--------------------------------------------------------------------
        PAYLOAD: begin
          gmii_tx_en <= 1'b1;
          frame_cnt  <= frame_cnt + 16'd1;
          if (s_axis_tvalid) begin
            gmii_txd <= s_axis_tdata;
            if (s_axis_tlast)
              state <= (frame_cnt + 16'd1 < 16'(MIN_FRAME)) ? PAD : SEND_FCS;
          end else begin
            gmii_txd   <= 8'h00;        // underrun: corrupt deliberately
            gmii_tx_er <= 1'b1;
          end
        end

        //--------------------------------------------------------------------
        // Zero-pad up to the 60-byte pre-FCS minimum. Padding IS covered by
        // the CRC.
        //--------------------------------------------------------------------
        PAD: begin
          gmii_tx_en <= 1'b1;
          gmii_txd   <= 8'h00;
          frame_cnt  <= frame_cnt + 16'd1;
          if (frame_cnt + 16'd1 >= 16'(MIN_FRAME)) state <= SEND_FCS;
        end

        //--------------------------------------------------------------------
        // 4 FCS bytes, least-significant first. Not fed back into the CRC.
        //--------------------------------------------------------------------
        SEND_FCS: begin
          gmii_tx_en <= 1'b1;
          gmii_txd   <= fcs_byte;
          if (fcs_cnt == 2'(FCS_LEN - 1)) begin
            ifg_cnt <= '0;
            state   <= IFG;
          end
          fcs_cnt <= fcs_cnt + 2'd1;
        end

        //--------------------------------------------------------------------
        // Inter-frame gap: 12 idle byte times with tx_en low.
        //--------------------------------------------------------------------
        IFG: begin
          if (ifg_cnt == 4'(IFG_LEN - 1)) state <= IDLE;
          ifg_cnt <= ifg_cnt + 4'd1;
        end

        default: state <= IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // GMII -> RGMII DDR output stage (mirror of the IDDR block in rx_mac_core)
  //
  // Low nibble on the rising edge, high nibble on the falling edge. The control
  // line carries TX_EN on the rising edge and TX_EN ^ TX_ER on the falling --
  // the same encoding rx_mac_core decodes on ingress, in reverse.
  //
  // TIMING: RGMII wants the clock CENTRE-aligned to the data. This forwards an
  // edge-aligned clock, so the ~2 ns shift must come from the PHY's internal TX
  // delay (RTL8211 strap / MDIO) or an ODELAY. Getting this wrong is the classic
  // "link comes up but every frame is dropped" failure -- confirm on bring-up.
  //--------------------------------------------------------------------------
`ifdef SYNTHESIS
  genvar i;
  generate
    for (i = 0; i < 4; i++) begin : g_oddr_data
      ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
      ) u_oddr (
        .Q  (rgmii_txd[i]),
        .C  (gmii_tx_clk),
        .CE (1'b1),
        .D1 (gmii_txd[i]),        // rising edge  -> low nibble
        .D2 (gmii_txd[i+4]),      // falling edge -> high nibble
        .R  (~rst_n),
        .S  (1'b0)
      );
    end
  endgenerate

  ODDR #(
    .DDR_CLK_EDGE ("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")
  ) u_oddr_ctl (
    .Q  (rgmii_tx_ctl),
    .C  (gmii_tx_clk),
    .CE (1'b1),
    .D1 (gmii_tx_en),                 // rising  -> TX_EN
    .D2 (gmii_tx_en ^ gmii_tx_er),    // falling -> TX_EN ^ TX_ER
    .R  (~rst_n),
    .S  (1'b0)
  );

  ODDR #(
    .DDR_CLK_EDGE ("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")
  ) u_oddr_clk (
    .Q(rgmii_txc), .C(gmii_tx_clk), .CE(1'b1),
    .D1(1'b1), .D2(1'b0), .R(~rst_n), .S(1'b0)
  );

`else
  // Behavioural DDR so the block still simulates without vendor libraries.
  logic [3:0] nib_rise, nib_fall;
  logic       ctl_rise, ctl_fall;

  always_ff @(posedge gmii_tx_clk or negedge rst_n) begin
    if (!rst_n) begin
      nib_rise <= 4'h0;
      nib_fall <= 4'h0;
      ctl_rise <= 1'b0;
      ctl_fall <= 1'b0;
    end else begin
      nib_rise <= gmii_txd[3:0];
      nib_fall <= gmii_txd[7:4];
      ctl_rise <= gmii_tx_en;
      ctl_fall <= gmii_tx_en ^ gmii_tx_er;
    end
  end

  assign rgmii_txd    = gmii_tx_clk ? nib_rise : nib_fall;
  assign rgmii_tx_ctl = gmii_tx_clk ? ctl_rise : ctl_fall;
  assign rgmii_txc    = gmii_tx_clk;
`endif

endmodule
