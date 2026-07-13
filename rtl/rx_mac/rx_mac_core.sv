//==============================================================================
// RX MAC Core  (Section 3.1.1)
//
// Ingress point for market data. Converts RGMII DDR to SDR, strips the Ethernet
// preamble/SFD and the 14-byte L2 header, and streams payload bytes downstream
// in cut-through mode. CRC-32 is computed in parallel; rx_error is asserted on
// the final cycle of the packet and routed directly to the Risk Gateway.
//
// Runs in the 125 MHz PHY clock domain. Downstream crossing to 250 MHz is
// handled by the RX CDC FIFO (vendor IP, not designed here).
//
// FS-3 (line rate), FS-4 (integrity monitoring)
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

  // TODO: instantiate IDDR primitives on rgmii_rxd[3:0] and rgmii_rx_ctl.
  //       Recover the 8-bit SDR bus, RXDV, and RXER (from the XOR on the
  //       falling edge). See AMD UG471 (7 Series SelectIO) for IDDR usage.

  //--------------------------------------------------------------------------
  // Stage 2: Cut-through FSM
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE,           // watch for preamble (0x55)
    PREAMBLE_SYNC,  // hold on 0x55 until SFD (0xD5)
    STRIP_HEADER,   // discard 14-byte L2 header (dst MAC, src MAC, ethertype)
    STREAM_PAYLOAD  // assert tvalid, stream IP/UDP/payload downstream
  } rx_state_e;

  rx_state_e state, next_state;
  logic [3:0] hdr_cnt;   // counts the 14 header bytes

  // TODO: implement FSM state register and next-state logic.
  // TODO: drive m_axis_tdata / tvalid / tlast from STREAM_PAYLOAD.

  //--------------------------------------------------------------------------
  // Stage 3: Parallel CRC-32 (IEEE 802.3 polynomial)
  //--------------------------------------------------------------------------
  logic [31:0] crc_reg;

  // TODO: unrolled 8-bit XOR tree (one byte per cycle), GF(2) arithmetic.
  //       Equations generated with crcgen. Residual for a valid frame is
  //       0xC704DD7B. Assert rx_error on the cycle sdr_data_valid de-asserts
  //       if the residual does not match.
  //
  // NOTE: This runs in parallel with the FSM and is NOT on the critical path.
  //       Do not gate m_axis_tvalid on the CRC result.

endmodule
