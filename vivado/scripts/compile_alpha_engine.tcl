#==============================================================================
# compile_alpha_engine.tcl
#
# Out-of-context (OOC) synthesis check for a user-submitted Alpha Engine Core
# module (FS-8/FS-16). Reports utilization + a synthesis-stage timing estimate
# back to the caller via a machine-readable result.json.
#
# This is NOT the full DFX/board-flash flow described in the design doc's
# Compiler Subsystem section -- that depends on rtl/top/commontrader_top.sv's
# outstanding TODOs (MMCM, CDC FIFOs, TX MAC) and committed board XDC
# constraints, neither of which exist yet. This script only answers: "does the
# user's module synthesize, and how big/fast is it?"
#
# Usage (non-interactive batch mode):
#   vivado -mode batch -source compile_alpha_engine.tcl \
#       -tclargs <job_dir> <user_sv_path>
#
# Outputs (written into <job_dir>):
#   util.rpt      - post-synthesis utilization report (only on success)
#   timing.rpt    - post-synthesis timing summary, unconstrained placement
#                   (only on success; informational estimate, not a real
#                   NF-4 WNS/WHS signoff -- that needs full implementation)
#   result.json   - {"status": "passed"|"failed", "synth_time_s": <float>,
#                     "error": <string|null>}
#==============================================================================

# --- Target part --------------------------------------------------------
# Placeholder pinned to the design doc's block-diagram value. Nothing in the
# repo confirms the exact Alinx AX7A200B SKU (speed grade / package) -- if
# this turns out wrong, this is the only line that needs to change.
set PART_NUM "xc7a200t-2fbg484"

# --- Argument parsing -----------------------------------------------------
if { $argc != 2 } {
    puts "ERROR: expected 2 arguments, got $argc"
    puts "Usage: vivado -mode batch -source compile_alpha_engine.tcl -tclargs <job_dir> <user_sv_path>"
    exit 1
}
set JOB_DIR    [lindex $argv 0]
set USER_FILE  [lindex $argv 1]

file mkdir $JOB_DIR

# --- Shared package path ---------------------------------------------------
# This script lives at vivado/scripts/; rtl/ is a sibling of vivado/ at the
# repo root.
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set CT_PKG     [file join $REPO_ROOT "rtl" "common" "ct_pkg.sv"]

# --- Small JSON helper (no external Tcl JSON package assumed) --------------
proc write_result { job_dir status synth_time_s error_msg } {
    set fp [open [file join $job_dir "result.json"] w]
    if { $error_msg eq "" } {
        set error_json "null"
    } else {
        # Escape backslashes and double quotes; strip newlines so the JSON
        # stays on one line.
        set escaped [string map {"\\" "\\\\" "\"" "\\\"" "\n" " " "\r" ""} $error_msg]
        set error_json "\"$escaped\""
    }
    puts $fp "{\"status\": \"$status\", \"synth_time_s\": $synth_time_s, \"error\": $error_json}"
    close $fp
}

# --- Run synthesis, catching any failure cleanly ---------------------------
set start_time [clock seconds]
set synth_err ""

set rc [catch {
    read_verilog -sv $CT_PKG
    read_verilog -sv $USER_FILE

    synth_design -top alpha_engine_core -part $PART_NUM -mode out_of_context

    # create_clock needs an open (elaborated/synthesized) design, so the
    # timing constraint is applied post-synthesis, purely for the timing
    # estimate below -- see the scoping note at the top of this file.
    create_clock -period 4.000 -name core_clk [get_ports core_clk]
} synth_err]

set elapsed [expr { [clock seconds] - $start_time }]

if { $rc != 0 } {
    puts "COMPILE FAILED: $synth_err"
    write_result $JOB_DIR "failed" $elapsed $synth_err
    exit 1
}

# --- Success: dump reports ---------------------------------------------------
set report_err ""
set rc2 [catch {
    report_utilization -file [file join $JOB_DIR "util.rpt"]
    report_timing_summary -file [file join $JOB_DIR "timing.rpt"]
} report_err]

if { $rc2 != 0 } {
    puts "REPORT GENERATION FAILED: $report_err"
    write_result $JOB_DIR "failed" $elapsed $report_err
    exit 1
}

puts "COMPILE PASSED in ${elapsed}s"
write_result $JOB_DIR "passed" $elapsed ""
exit 0
