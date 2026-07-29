#==============================================================================
# commontrader_timing.xdc  --  clock + CDC constraints for commontrader_top
#
# BOARD-INDEPENDENT. These derive from the RTL, not the Alinx board, and are what
# synthesis needs to be meaningful and what makes the two-clock-domain crossing
# safe. Pin LOCs, I/O standards and RGMII I/O timing are board-specific and live
# in commontrader_pins.xdc (needed for implementation, not for synthesis).
#
# Clock domains (rtl/common/clk_rst_gen.sv):
#   rgmii_rx_clk  125 MHz  input from the PHY; clocks RX MAC, TX MAC, FIFO PHY sides
#   core_clk      250 MHz  MMCM output (x2); clocks parser/book/alpha/risk/tx_gen
# The two CDC FIFOs (rtl/ip/cdc_fifo) and the rx_error/kill_switch 2-flop
# synchronisers (commontrader_top) are the ONLY legal crossings; everything below
# exists to constrain them.
#==============================================================================

#------------------------------------------------------------------------------
# 1. Primary clock: 125 MHz RGMII receive clock from the PHY.
#    (The pin LOC / IOSTANDARD for rgmii_rx_clk is set in commontrader_pins.xdc.)
#------------------------------------------------------------------------------
create_clock -name rgmii_rx_clk -period 8.000 [get_ports rgmii_rx_clk]

# core_clk (250 MHz) is produced by the MMCM (CLKFBOUT_MULT_F=8, CLKOUT0_DIVIDE_F=4)
# and is AUTO-DERIVED by Vivado from rgmii_rx_clk -- do NOT declare it by hand.
# After synthesis, confirm BOTH clocks exist with:  report_clocks

#------------------------------------------------------------------------------
# 2. Clock-domain crossing: treat 125 MHz and 250 MHz as ASYNCHRONOUS.
#
#    core_clk is derived from rgmii_rx_clk through the MMCM, but the RX/TX MACs run
#    on the raw PHY clock while the core runs on the MMCM output, and the design
#    crosses between them ONLY through gray-code CDC FIFOs and 2-flop synchronisers.
#    So tell the tool not to time between them; the CDC hardware guarantees safety.
#    The core clock is referenced by the BUFG output pin, so this does not depend
#    on the auto-generated clock's name.
#
#    NOTE: if the second -group returns empty (get_pins found nothing), run
#    report_clocks, read the generated core-clock name, and replace the second
#    -group with:  -group [get_clocks <core_clk_name>]
#------------------------------------------------------------------------------
set_clock_groups -name async_phy_core -asynchronous \
  -group [get_clocks -of_objects [get_ports rgmii_rx_clk]] \
  -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *u_bufg_core/O}]]

#------------------------------------------------------------------------------
# 3. ASYNC_REG on every synchroniser flop: keeps the two stages of each 2-flop
#    synchroniser in the same slice (best metastability MTBF) and stops the tools
#    optimising or retiming through them.
#
#    - RX/TX FIFO gray-pointer syncs: wq1/wq2_rgray (read ptr -> write domain),
#      rq1/rq2_wgray (write ptr -> read domain), inside each cdc_fifo.
#    - Control syncs: rx_error_meta/sync, kill_meta/sync (commontrader_top).
#    - Reset syncs: core_rst_meta, phy_rst_meta (clk_rst_gen).
#
#    (Best practice is to also mark these with (* ASYNC_REG = "TRUE" *) in the RTL;
#    doing it here keeps the source untouched. If any get_cells below matches
#    nothing after synthesis, check the name with: report_cdc / get_cells -hier.)
#------------------------------------------------------------------------------
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *wq1_rgray_reg*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *wq2_rgray_reg*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *rq1_wgray_reg*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *rq2_wgray_reg*}]
# -quiet: these two flops are PRUNED by synthesis today -- the Risk Gateway's
# viol_crc check is stubbed (docs/known_limitations.md L3), so the rx_error
# synchroniser drives nothing and is optimised away. Without -quiet the empty
# get_cells makes set_property a Critical Warning (Common 17-55). The constraint
# must STAY so it re-arms automatically the day viol_crc is wired up.
set_property -quiet ASYNC_REG TRUE [get_cells -quiet -hierarchical -filter {NAME =~ *rx_error_meta_reg*}]
set_property -quiet ASYNC_REG TRUE [get_cells -quiet -hierarchical -filter {NAME =~ *rx_error_sync_reg*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *kill_meta_reg*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *kill_sync_reg*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *core_rst_meta_reg*}]
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *phy_rst_meta_reg*}]

#------------------------------------------------------------------------------
# 4. Asynchronous control inputs. hw_kill_switch has no clock; sys_rst_n is an
#    async board reset. Both are synchronised internally, so there is no launch
#    edge to time against -- cut them so they do not create bogus I/O paths.
#    (Do NOT add the RGMII data inputs here -- those get real set_input_delay in
#    commontrader_pins.xdc.)
#------------------------------------------------------------------------------
set_false_path -from [get_ports hw_kill_switch_n]
set_false_path -from [get_ports sys_rst_n]

#------------------------------------------------------------------------------
# 5. (Optional, more rigorous alternative to the async clock group in section 2)
#    Instead of cutting the crossing entirely, you can BOUND it: keep the group
#    but add a datapath-only max delay + bus skew on the gray pointers so the
#    tools still check that the multi-bit gray bus arrives coherently. Not needed
#    to get a working bitstream; enable if a reviewer wants belt-and-braces CDC.
#
# set_max_delay -datapath_only 4.000 \
#   -from [get_cells -hier -filter {NAME =~ *wgray_reg*}] \
#   -to   [get_cells -hier -filter {NAME =~ *rq1_wgray_reg*}]
# set_bus_skew 2.000 \
#   -from [get_cells -hier -filter {NAME =~ *wgray_reg*}] \
#   -to   [get_cells -hier -filter {NAME =~ *rq1_wgray_reg*}]
#------------------------------------------------------------------------------
