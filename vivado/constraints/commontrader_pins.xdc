#==============================================================================
# commontrader_pins.xdc  --  board pin + I/O timing for commontrader_top
#                            Alinx AX7A200B (xc7a200tfbg484-2)
#
# Pin LOCs are from the AX7A035B/AX7A200B User Manual, section 3.2 "Gigabit
# Ethernet Interface" (RGMII PHY), the Keys (3.13) and LED (3.14) sections.
#
#   Design port          <- board net (manual)      FPGA pin   bank
#   rgmii_rx_clk         <- ETH_RXCK                 V18        14
#   rgmii_rxd[3:0]       <- ETH_RXD3..0              P17 U17 U18 P19
#   rgmii_rx_ctl         <- ETH_RXCTL                R19        14
#   rgmii_tx_clk         <- ETH_TXCK                 P15        14
#   rgmii_txd[3:0]       <- ETH_TXD3..0              R16 R17 P16 N14
#   rgmii_tx_ctl         <- ETH_TXCTL                N17        14
#   sys_rst_n            <- RESET key                F15        16
#   hw_kill_switch_n     <- KEY1                     L19        15
#   eth_phy_rst_n        <- ETH_RESET                R14        14
#
# I/O STANDARD -- verified against the core board power table (manual 2.10):
#   +3.3V  -> VCCIO of BANK0, BANK13, BANK14 (+ QSPI flash, clock crystal)
#   VCCIO  -> BANK15, BANK16, from a 3.3 V LDO (SPX3819M5-3-3)
#   +1.5V  -> DDR3, BANK34 and BANK35
# Every pin constrained in this file is in bank 14, 15 or 16 -- all 3.3 V -- so
# LVCMOS33 is correct throughout. Do NOT put an LVCMOS33 port in bank 34/35.
#
# Not wired in RTL (optional; the PHY self-configures by pin-strapping):
#   ETH_MDC (N13)  ETH_MDIO (P14)   -- see the note at the bottom.
#==============================================================================

#------------------------------------------------------------------------------
# Device configuration (DRC CFGBVS-1)
# Bank 0 (configuration) on the AX7A200B is a 3.3 V rail, so config-bank voltage
# select follows VCCO. Without these two properties write_bitstream errors on
# CFGBVS-1. Verify 3.3 V against the board manual's power table before taping out.
#------------------------------------------------------------------------------
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

#------------------------------------------------------------------------------
# Clock and reset
#------------------------------------------------------------------------------
# 125 MHz RGMII receive clock from the PHY (create_clock is in the timing xdc).
# VERIFIED clock-capable: V18 = IO_L14P_T2_SRCC_14 (IS_CLK_CAPABLE = 1), so it
# reaches a BUFG and can drive the MMCM. All the RX data pins sit in the same
# bank/clock region as V18, so a BUFIO/BUFR capture scheme stays available too.
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports rgmii_rx_clk]

# sys_rst_n -> the carrier-board RESET key (active-low, idle high).
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]

# eth_phy_rst_n -> JL2121 PHY hardware reset (ETH_RESET), active-low.
# Driven from sys_rst_n in RTL; the PHY must leave reset for the RX clock to run.
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports eth_phy_rst_n]

# The board's system clock is a 200 MHz DIFFERENTIAL pair (SYS_CLK_P R4 /
# SYS_CLK_N T4, MRCC in BANK34). BANK34 is the 1.5 V DDR3 bank.
# It is used by the reset tree sequencer as a free-running clock.
set_property -dict {PACKAGE_PIN R4 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN T4 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_n]

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
#
# SLEW FAST is REQUIRED here, not cosmetic. Vivado's default for an LVCMOS33
# output is DRIVE 12 / SLEW SLOW (see impl_1/commontrader_top_io_placed.rpt), and
# a slow-slew 3.3 V edge is far too soft for RGMII's 4 ns unit interval (125 MHz
# DDR) -- it eats most of the eye the PHY has to sample. DRIVE 12 is the right
# strength for the PHY's CMOS load; stated explicitly so it is a decision, not a
# default.
#------------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports rgmii_tx_clk]   ;# ETH_TXCK
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {rgmii_txd[0]}] ;# ETH_TXD0
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {rgmii_txd[1]}] ;# ETH_TXD1
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {rgmii_txd[2]}] ;# ETH_TXD2
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {rgmii_txd[3]}] ;# ETH_TXD3
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports rgmii_tx_ctl]   ;# ETH_TXCTL

#------------------------------------------------------------------------------
# hw_kill_switch_n -> user key KEY1 (L19). ACTIVE-LOW (key idles high, pressed =
# low); the RTL inverts it, so pressing the key asserts the kill.
#------------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} [get_ports hw_kill_switch_n]

#------------------------------------------------------------------------------
# Telemetry -- NO PIN CONSTRAINTS ON PURPOSE.
#
# order_drop_count / tx_fifo_overflow / ts_wrapped were removed from the
# commontrader_top PORT LIST (they are internal signals now, observed through an
# ILA). Constraining them here was leaving three CRITICAL WARNINGs per run:
#   WARNING  [Vivado 12-584] No ports matched '<name>'
#   CRITICAL [Common 17-55]  'set_property' expects at least one object
# If they ever come back as ports, the carrier-board user LEDs are:
#   LED1 L13   LED2 M13   LED3 K14   LED4 K13    (BANK15, 3.3 V)
# all ACTIVE-LOW (0 = lit, manual 3.14) while the status signals are active-HIGH,
# so invert at the assignment if you want "lit == asserted".
#------------------------------------------------------------------------------

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
#------------------------------------------------------------------------------
# --- Pin I/O Primitives into IOB ---------------------------------------------
# Ensures per-bit routing skew is strictly controlled.
#------------------------------------------------------------------------------
set_property IOB TRUE [get_ports {rgmii_rxd[*] rgmii_rx_ctl rgmii_txd[*] rgmii_tx_ctl}]

#==============================================================================
# ETH_RESET (R14) is wired -- see eth_phy_rst_n above.
#
# STILL not wired (optional; the PHY self-configures via pin-strapping,
# Table 3-2-1, so these are not needed for basic bring-up):
#   ETH_MDC  (N13)   -- MDIO management clock
#   ETH_MDIO (P14)   -- MDIO management data.  Add ports later for register
#                       access / link-status polling.
#==============================================================================
