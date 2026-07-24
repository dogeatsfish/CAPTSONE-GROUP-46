#==============================================================================
# bitstream_drc_waivers.xdc  --  DRC severity waivers for write_bitstream
#
# These downgrade *bitstream-blocking* DRCs to warnings for signals that are
# intentionally not routed to board pins. Keep this file SEPARATE from the pin
# constraints so the waiver is obvious and easy to remove. See docs/DRC_fix.md.
#
# Add to the implementation run's constraint set (constrs_1), or attach as a
# write_bitstream pre-hook (Vivado GUI: impl run > write_bitstream > tcl.pre).
#==============================================================================

# UCIO-1: order_drop_count[15:0] is a 16-bit ILA/status-register telemetry bus
# with no board pins (only 2 LEDs are free -- see commontrader_pins.xdc). It has
# an IOSTANDARD (so NSTD-1 is satisfied) but no LOC. Waiving UCIO-1 lets the
# tool auto-place these debug outputs so write_bitstream can complete.
#
# PERMANENT fix (preferred): observe order_drop_count through an ILA/debug hub
# (mark_debug) instead of a top-level port, OR assign real expansion-header LOCs
# from the AX7A200B manual. Until then this waiver is the interim.
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
