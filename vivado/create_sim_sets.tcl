#==============================================================================
# Create one Vivado simulation fileset per bench, matching sim/benches.sh.
#
#   Vivado's Project Manager runs ONE "top module" per simulation set --
#   that's why sim_1 (with all 12 testbenches dumped into it) only ever
#   elaborates whichever one its top happens to point at. This script gives
#   every bench its own set (sim_<bench>), each with just its own testbench
#   file and its own top, so you switch between them with the dropdown at the
#   top of the Sources panel instead of hand-editing "Set as Top" each time.
#
#   Run from Vivado's Tcl Console (Window > Tcl Console) with the CAPSTONE
#   project already open:
#
#     source {vivado/create_sim_sets.tcl}
#
#   Reads sim/benches.sh and sim/filelists/*.f directly instead of hardcoding
#   the bench -> top -> tb-file mapping a second time, so it can't drift from
#   what the shell runners (run_xsim.sh / run_verilator.sh) already use.
#
#   Non-destructive: only CREATES new filesets, named sim_<bench>. Does not
#   touch the existing sim_1 or anything already configured. Safe to re-run --
#   any sim_<bench> that already exists is skipped.
#
#   Design sources (rtl/) are NOT duplicated per set -- every simset pairs
#   with sources_1 by default (set explicitly below), which already has the
#   full rtl/ hierarchy, so Vivado pulls in whatever the chosen top needs.
#==============================================================================

set repo_root [file normalize "[get_property DIRECTORY [current_project]]/.."]

proc read_lines {path} {
  set fh [open $path r]
  set out {}
  while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line ne "" && [string index $line 0] ne "#"} {
      lappend out $line
    }
  }
  close $fh
  return $out
}

# Pull [bench]="top_module" pairs straight out of the BENCH_TOP array in
# benches.sh -- the same associative array the bash runners source.
set benches_sh [open [file join $repo_root sim benches.sh] r]
set benches_text [read $benches_sh]
close $benches_sh

# A fileset cannot be deleted while it is the active simset, so make sure the
# default sim_1 is active before the loop -- that guarantees none of the
# sim_<bench> sets we recreate below are the active one.
if {[llength [get_filesets -quiet sim_1]] > 0} {
  catch {current_fileset -simset [get_filesets sim_1]}
}

set created 0

foreach {whole bench top} [regexp -all -inline {\[(\w+)\]="([^"]+)"} $benches_text] {
  set setname "sim_$bench"

  # The testbench file is always the last source line in the bench's
  # filelist -- same convention run_xsim.sh / run_verilator.sh rely on.
  set flist [file join $repo_root sim filelists ${bench}.f]
  if {![file exists $flist]} {
    puts "WARNING: no filelist for bench '$bench' at $flist -- skipping"
    continue
  }
  set srcs [read_lines $flist]
  set tbfile [file join $repo_root [lindex $srcs end]]

  # Recreate from scratch each run so a half-built set from an interrupted run
  # can't linger -- these sim_<bench> sets are entirely script-managed, so a
  # delete+recreate yields the identical result and is safely idempotent.
  if {[llength [get_filesets -quiet $setname]] > 0} {
    delete_fileset $setname
  }

  create_fileset -simset $setname
  set_property SOURCE_SET sources_1 [get_filesets $setname]
  # [list $tbfile] keeps a path containing spaces (".../UW Programming/...") as
  # a SINGLE list element -- add_files list-splits a bare string on whitespace.
  add_files -fileset $setname -norecurse [list $tbfile]
  set_property top $top [get_filesets $setname]
  set_property top_lib xil_defaultlib [get_filesets $setname]

  puts "created $setname -> top $top ($tbfile)"
  incr created
}

puts ""
puts "Done: $created simulation sets created/refreshed."
puts ""
puts "Switch benches via the dropdown at the top of the Sources panel, or from"
puts "the Tcl console:"
puts "  current_fileset -simset sim_order_book_crv"
puts "  launch_simulation"
