#==============================================================================
# commontrader_pins.xdc  --  board pin + I/O timing for commontrader_top
#                            Alinx AX7A200B (xc7a200tfbg484-2)
#
# Pin LOCs are from the AX7A200B User Manual (REV 1.0), section 3.2 "Gigabit
# Ethernet Interface" (JL2121 PHY, RGMII), the Keys (3.13) and LED (3.14)
# sections. All RGMII signals are in BANK14 (VCCO = 3.3 V per the manual's power
# table), so IOSTANDARD LVCMOS33.
#
#   Design port          <- board net (manual)      FPGA pin
#   rgmii_rx_clk         <- ETH_RXCK                 V18
#   rgmii_rxd[3:0]       <- ETH_RXD3..0              P17 U17 U18 P19
#   rgmii_rx_ctl         <- ETH_RXCTL                R19
#   rgmii_tx_clk         <- ETH_TXCK                 P15
#   rgmii_txd[3:0]       <- ETH_TXD3..0              R16 R17 P16 N14
#   rgmii_tx_ctl         <- ETH_TXCTL                N17
#
# IMPORTANT -- the RTL is missing three PHY signals (see notes at the bottom):
#   ETH_RESET (R14)  ETH_MDC (N13)  ETH_MDIO (P14)
#==============================================================================

#------------------------------------------------------------------------------
# Clock and reset
#------------------------------------------------------------------------------
# 125 MHz RGMII receive clock from the PHY (create_clock is in the timing xdc).
# NOTE: verify V18 is a clock-capable (MRCC/SRCC) pin -- the RX clock drives both
# the RX MAC IDDR and the MMCM, so it must reach a BUFG. Alinx route it to a CC
# pin; confirm in the pin report if the MMCM refuses to place.
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports rgmii_rx_clk]

# sys_rst_n -> the carrier-board RESET key (active-low, idle high).
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]

# eth_phy_rst_n -> JL2121 PHY hardware reset (ETH_RESET), active-low.
# Driven from sys_rst_n in RTL; the PHY must leave reset for the RX clock to run.
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports eth_phy_rst_n]

# sys_clk is UNUSED by the datapath (it will be trimmed). The board's system
# clock is a 200 MHz DIFFERENTIAL pair (SYS_CLK_P R4 / SYS_CLK_N T4), which does
# not map to a single-ended port -- leave sys_clk unconstrained/removed.

#------------------------------------------------------------------------------
# RGMII receive (input, DDR) -- BANK14, 3.3 V
#------------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports {rgmii_rxd[0]}]   ;# ETH_RXD0
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {rgmii_rxd[1]}]   ;# ETH_RXD1
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {rgmii_rxd[2]}]   ;# ETH_RXD2
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports {rgmii_rxd[3]}]   ;# ETH_RXD3
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports rgmii_rx_ctl]     ;# ETH_RXCTL

#------------------------------------------------------------------------------
# RGMII transmit (output, DDR) -- BANK14, 3.3 V. rgmii_tx_clk is FORWARDED.
#------------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports rgmii_tx_clk]     ;# ETH_TXCK
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {rgmii_txd[0]}]   ;# ETH_TXD0
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports {rgmii_txd[1]}]   ;# ETH_TXD1
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {rgmii_txd[2]}]   ;# ETH_TXD2
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {rgmii_txd[3]}]   ;# ETH_TXD3
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports rgmii_tx_ctl]     ;# ETH_TXCTL

#------------------------------------------------------------------------------
# hw_kill_switch_n -> user key KEY1 (L19). ACTIVE-LOW (key idles high, pressed =
# low); the RTL inverts it, so pressing the key asserts the kill.
#------------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} [get_ports hw_kill_switch_n]

#------------------------------------------------------------------------------
# Telemetry -> carrier-board user LEDs (LED1..LED4 = L13 M13 K14 K13).
# LEDs are ACTIVE-LOW (0 = lit, per manual 3.14). tx_fifo_overflow / ts_wrapped
# are active-HIGH, so as wired the LED lights on the GOOD state -- invert if you
# want "lit == asserted", or just read the level. order_drop_count is 16 bits;
# route it to an ILA rather than pins (recommended for bring-up).
#------------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN L13 IOSTANDARD LVCMOS33} [get_ports tx_fifo_overflow] ;# LED1
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVCMOS33} [get_ports ts_wrapped]       ;# LED2
# order_drop_count[15:0] -> ILA (add the Integrated Logic Analyzer and mark the net
# for debug). If you must use pins, only 2 LEDs remain (K14, K13).

#==============================================================================
# RGMII I/O TIMING  --  the PHY is in RGMII-ID mode (Table 3-2-1: TXDLY + RXDLY,
# 2 ns internal delay BOTH ways). That makes the FPGA side simple:
#
#   RX: the PHY delays RXC so it arrives CENTER-ALIGNED in the RXD eye. Capture
#       rgmii_rxd/rx_ctl with an IDDR clocked by rgmii_rx_clk directly -- NO IDELAY
#       needed on the FPGA. (rx_mac_core's IDDR path already assumes this.)
#   TX: forward rgmii_tx_clk EDGE-ALIGNED to txd with an ODDR; the PHY adds the
#       2 ns TXDLY to center it -- NO ODELAY needed on the FPGA.
#
# The delay VALUES below are RGMII v2.0 typical starting points; refine them from
# the JL2121 datasheet (its RXC->RXD output skew and TXC setup/hold), then close
# timing. Uncomment once the ODDR source pin path is filled in.
#------------------------------------------------------------------------------
# --- RX (input): data valid window around the center-aligned received clock ---
# set_input_delay -clock rgmii_rx_clk -max  1.2 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
# set_input_delay -clock rgmii_rx_clk -min  0.8 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
# set_input_delay -clock rgmii_rx_clk -max  1.2 -clock_fall -add_delay [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
# set_input_delay -clock rgmii_rx_clk -min  0.8 -clock_fall -add_delay [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
#
# --- TX (output): forwarded clock + data constrained against it ---------------
# Replace <ODDR_txclk>/C with the clock-forwarding ODDR instance in tx_mac_core.
# create_generated_clock -name rgmii_tx_clk_out -multiply_by 1 \
#   -source [get_pins <ODDR_txclk>/C] [get_ports rgmii_tx_clk]
# set_output_delay -clock rgmii_tx_clk_out -max  1.0 [get_ports {rgmii_txd[*] rgmii_tx_ctl}]
# set_output_delay -clock rgmii_tx_clk_out -min -0.8 [get_ports {rgmii_txd[*] rgmii_tx_ctl}]
# set_output_delay -clock rgmii_tx_clk_out -max  1.0 -clock_fall -add_delay [get_ports {rgmii_txd[*] rgmii_tx_ctl}]
# set_output_delay -clock rgmii_tx_clk_out -min -0.8 -clock_fall -add_delay [get_ports {rgmii_txd[*] rgmii_tx_ctl}]

#==============================================================================
# ETH_RESET (R14) is now wired -- see eth_phy_rst_n above.
#
# STILL not wired (optional; the PHY self-configures via pin-strapping,
# Table 3-2-1, so these are not needed for basic bring-up):
#   ETH_MDC  (N13)   -- MDIO management clock
#   ETH_MDIO (P14)   -- MDIO management data.  Add ports later for register
#                       access / link-status polling.
#==============================================================================
