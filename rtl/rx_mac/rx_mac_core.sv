//==============================================================================
// RX MAC Core  (Section 3.1.1)
//
// Ingress point for market data. Converts RGMII DDR to SDR, strips the Ethernet
// preamble/SFD and the 14-byte L2 header, and streams payload bytes downstream
// in cut-through mode. CRC-32 is computed in parallel; rx_error is asserted on
// the final cycle of the packet and routed directly to the Risk Gateway.
//
// Runs in the 125 MHz PHY clock domain.
//
//==============================================================================

module rx_mac_core
  import ct_pkg::*;
(
  // --- RGMII from PHY (125 MHz domain) --------------------------------------
  input  logic       rgmii_rx_clk,   // 125 MHz receive clock from PHY
  input  logic       rgmii_rst_n,
  input  logic [3:0] rgmii_rxd,      // DDR data bus
  input  logic       rgmii_rx_ctl,   // DDR control: RXDV on rising, RXDV^RXER on falling

  // --- AXI4-Stream master to RX CDC FIFO ------------------------------------
  // tready is intentionally omitted: the PHY runs at line rate and cannot be
  // back-pressured.
  output logic [7:0] m_axis_tdata,
  output logic       m_axis_tvalid,
  output logic       m_axis_tlast,

  // --- Parallel error flag, routed directly to Pre-Trade Risk Gateway -------
  output logic       rx_error
);

  //--------------------------------------------------------------------------
  // Stage 1: DDR to SDR conversion (IDDR primitives)
  //--------------------------------------------------------------------------
  logic [7:0] sdr_data;
  logic       sdr_data_valid;
  logic       sdr_error;
  logic       phy_error;

  /* verilator lint_save */
  genvar i; 
  generate
    // Input Data IDDR
    for (i = 0; i < 4; i = i + 1) begin: RGMII_RX_DATA
      IDDR #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
        .SRTYPE("ASYNC")
      ) IDDR_inst (
        // Output
        .Q1(sdr_data[i]),
        .Q2(sdr_data[i+4]),
        // Input
        .C(rgmii_rx_clk),
        .CE(1),
        .D(rgmii_rxd[i]),
        .R(~rgmii_rst_n),
        .S(0)
      );
    end
    // Control Signal IDDR
    IDDR #(
      .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
      .SRTYPE("ASYNC")
    ) IDDR_CTRL (
      // Output
      .Q1(sdr_data_valid),
      .Q2(sdr_error),
      // Input
      .C(rgmii_rx_clk),
      .CE(1),
      .D(rgmii_rx_ctl),
      .R(~rgmii_rst_n),
      .S(0)
    );
  endgenerate 

  /* verilator lint_restore */
  assign phy_error = sdr_data_valid ^ sdr_error; 

  //--------------------------------------------------------------------------
  // Stage 2: Cut-through FSM
  //--------------------------------------------------------------------------

  enum {IDLE, PREAMBLE_SYNC, STRIP_HEADER, STREAM_PAYLOAD, DROP_FCS} state, next; 
  logic [4:0][7:0] shift_reg; // Sliding Window Shift reg to drop last 4 bytes
  logic [4:0] hdr_cnt;   // counts the 14 header bytes + 5 cycle shift register

  always_ff @ (posedge rgmii_rx_clk or negedge rgmii_rst_n) begin : State_Transitions
    if (rgmii_rst_n == 0) begin
      state <= IDLE; 
      hdr_cnt <= 0; 
    end else begin
      state <= next; 
      if (state == STRIP_HEADER) begin
        hdr_cnt <= hdr_cnt + 1; 
      end else begin
        hdr_cnt <= 0; 
      end
    end
  end

  always_comb begin : State_Decoder
    case (state)

      IDLE: begin
        if (sdr_data == 8'h55) begin
          next = PREAMBLE_SYNC;
        end else begin
          next = IDLE; 
        end
      end

      PREAMBLE_SYNC: begin
        if (sdr_data == 8'hD5) begin
          next = STRIP_HEADER;
        end else if (sdr_data == 8'h55) begin
          next = PREAMBLE_SYNC;
        end else begin
          next = IDLE; 
        end
      end

      STRIP_HEADER: begin
        if (hdr_cnt < 18) begin // Count 19 cycles to strip Ethernet header (14 bytes) and 5 cycle shift register
          next = STRIP_HEADER;
        end else begin
          next = STREAM_PAYLOAD;
        end 
        // hdr_cnt is incremented in State_Transitions
      end

      STREAM_PAYLOAD: begin
        if (sdr_data_valid == 0) begin
          next = DROP_FCS;
        end else begin
          next = STREAM_PAYLOAD;
        end
      end

      DROP_FCS: begin
        next = IDLE; 
      end
    endcase
  end

  always_comb begin: Output_Decoder

    case (state)
      STREAM_PAYLOAD: begin
        // Handle Handshake flags
        m_axis_tvalid = 1; 
        if (sdr_data_valid == 1) begin
          m_axis_tlast = 0; 
        end else begin
          m_axis_tlast = 1; 
        end
        // Stream Data into window
        m_axis_tdata = shift_reg[4]; 
      end
      default: begin
        m_axis_tvalid = 0; 
        m_axis_tlast = 0; 
        m_axis_tdata = 8'h00; 
      end
    endcase

  end

  always_ff @ (posedge rgmii_rx_clk or negedge rgmii_rst_n) begin: Shift_Register
    if (~rgmii_rst_n) begin
      shift_reg <= '0; 
    end else if (sdr_data_valid) begin
      shift_reg <= {shift_reg[3:0], sdr_data}; 
    end
  end

  //--------------------------------------------------------------------------
  // Stage 3: Parallel CRC-32 (IEEE 802.3 polynomial)
  //--------------------------------------------------------------------------
  logic [31:0] crc_reg, crc_next;

  crc crc_inst (
    .crcIn (crc_reg),
    .data  (sdr_data),
    .crcOut(crc_next)
  );

  always_ff @(posedge rgmii_rx_clk or negedge rgmii_rst_n) begin
    if (~rgmii_rst_n) begin
      crc_reg <= 32'hFFFFFFFF;
    end else if (state == IDLE || state == PREAMBLE_SYNC) begin
      crc_reg <= 32'hFFFFFFFF;
    end else if (sdr_data_valid) begin
      crc_reg <= crc_next; 
    end
  end
  
  // Differs from design doc since using LSB-first CRC-32 (doc "used" MSB-first which is standard)
  assign rx_error = (!sdr_data_valid && (state == STREAM_PAYLOAD) && (crc_reg != 32'hDEBB20E3)) || phy_error; 

endmodule