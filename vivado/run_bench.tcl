#==============================================================================
# run_bench -- launch a Vivado project-flow simulation the way you actually
# want it: run to $finish (not the 1000 ns default) and with plusargs applied.
#
#   Source once per Vivado session (project already open):
#     source {c:/Users/victo/OneDrive/Desktop/UW Programming/ECE_498/CAPTSONE-GROUP-46/vivado/run_bench.tcl}
#
#   Then:
#     run_bench sim_integration                          ;# run to $finish
#     run_bench sim_order_book_crv {SEED=42 NTXN=50000}  ;# with plusargs
#     run_bench sim_order_book_crv {SEED=7} 20us         ;# bounded 20 us run
#
# WHY THIS EXISTS -- two Vivado-2025.2 project-flow gotchas it works around:
#
#   * The generated run script ends in `run 1000ns` (the xsim.simulate.runtime
#     property, default 1000ns), so every bench is chopped off at 1 us. We set
#     that property to -all so it becomes `run -all` and runs to $finish. This
#     persists on the simset, so the GUI "Run Behavioral Simulation" button
#     honours it too after the first call.
#
#   * Plusargs go through the xsim.simulate.xsim.more_options property as
#     -testplusarg NAME=value. Note: the STANDALONE xsim.exe crashes on the '='
#     in that value, but launch_simulation runs xsim IN-PROCESS (a Tcl command,
#     not the exe), and that path handles -testplusarg NAME=value correctly --
#     verified seed=42 actually takes effect. (Do NOT try to route these through
#     a `-f` response file here: the in-process xsim command has no -f option
#     and errors "Unknown option '-f'".)
#
# On seeds: these benches read the seed via $value$plusargs("SEED=%d") and call
# srandom(), so they need the SEED *plusarg*. `-sv_seed` seeds SystemVerilog
# constraint randomization only and will NOT change these benches' seed -- pass
# SEED=<n> as a plusarg, not -sv_seed.
#
# On the replay bench: commontrader_replay_tb reads sim/replay_*.hex by a
# repo-relative path, but the project flow runs xsim from the deep run dir
# (<proj>.sim/<simset>/behav/xsim), so that default can't resolve. run_bench
# auto-supplies +FRAMES/+LENS/+TOB pointing back up to the repo's sim/ dir (a
# spaceless relative path -- absolute paths would break on the space in the
# ".../UW Programming/..." project location). Generate the fixtures first with
#   python sim/csv_to_itch.py --events 400 --out sim/replay
#==============================================================================

proc run_bench {simset {plusargs {}} {runtime -all}} {
  set fs [get_filesets -quiet $simset]
  if {[llength $fs] == 0} {
    error "No simulation set '$simset'. Run create_sim_sets.tcl first, or check the name.\n       Available: [join [lsort [get_filesets -quiet sim_*]] {, }]"
  }

  # replay reads data files relative to cwd; from the run dir the repo is five
  # levels up (xsim/behav/<simset>/<proj>.sim/vivado -> repo), fixtures in sim/.
  if {[get_property top $fs] eq "commontrader_replay_tb"} {
    set has 0
    foreach pa $plusargs { if {[regexp {^\+?(FRAMES|LENS|TOB)=} $pa]} { set has 1 } }
    if {!$has} {
      set repo [file normalize "[get_property DIRECTORY [current_project]]/.."]
      if {![file exists "$repo/sim/replay_frames.hex"]} {
        puts "WARNING: $repo/sim/replay_frames.hex not found -- generate it first with:"
        puts "         python sim/csv_to_itch.py --events 400 --out sim/replay"
      }
      lappend plusargs FRAMES=../../../../../sim/replay_frames.hex \
                       LENS=../../../../../sim/replay_lens.hex \
                       TOB=../../../../../sim/replay_tob.hex
    }
  }

  # 1) Run length. -all -> `run -all` (to $finish); or e.g. 20us for a bounded run.
  set_property -name {xsim.simulate.runtime} -value $runtime -objects $fs

  # 2) Plusargs -> -testplusarg NAME=value ... straight into more_options.
  set opts {}
  foreach pa $plusargs {
    lappend opts -testplusarg [string trimleft $pa +]   ;# accept SEED=42 or +SEED=42
  }
  # Always set it (empty when no plusargs) so a previous parameterized run's
  # plusargs can't silently leak into this one.
  set_property -name {xsim.simulate.xsim.more_options} -value $opts -objects $fs

  if {[llength $plusargs] > 0} {
    puts "plusargs:"
    foreach pa $plusargs { puts "    +[string trimleft $pa +]" }
  }
  puts "launching $simset  (runtime = $runtime)"
  current_fileset -simset $fs
  launch_simulation -simset $fs
}

#------------------------------------------------------------------------------
# run_all_bench ?plusargs? -- the project-flow equivalent of run_all_tb.sh:
# run every sim_<bench> set to $finish, then print a pass/fail table keyed off
# each bench's "<N> checks, <M> failures" line (parsed from its simulate.log).
#
#   run_all_bench                 ;# run the whole regression
#   run_all_bench {SEED=42}       ;# forward a plusarg to every bench (benches
#                                  # that don't read it just ignore it)
#
# NOTE: this drives the full Project Manager flow (compile+elaborate+simulate)
# for all 12 benches sequentially in the GUI -- correct, but slow and it churns
# the simulation window. For a fast headless regression, ./sim/run_all_tb.sh
# --sim xsim is the better tool; it exercises the same xsim on the same sources.
#------------------------------------------------------------------------------
proc run_all_bench {{plusargs {}}} {
  # Unit-first / integration-last, matching sim/benches.sh BENCH_ORDER.
  set order {cdc_fifo rx_mac tx_mac parser order_book order_book_crv \
             alpha_engine risk_gateway tx_gen integration replay integration_crv}
  # Append any other sim_* sets that exist but aren't listed, so none are missed.
  foreach fs [lsort [get_filesets -quiet sim_*]] {
    set b [string range $fs 4 end]
    if {[lsearch -exact $order $b] < 0} { lappend order $b }
  }

  set projdir [get_property DIRECTORY [current_project]]
  set proj    [get_property NAME [current_project]]
  set rows {} ; set tot_checks 0 ; set tot_fails 0 ; set failed {}

  foreach b $order {
    set ss "sim_$b"
    if {[llength [get_filesets -quiet $ss]] == 0} { continue }
    puts "\n########## $ss ##########"
    if {[catch {run_bench $ss $plusargs} err]} {
      puts "  launch error: $err"
      lappend rows [list $b - - "BUILD/RUN ERROR"] ; lappend failed $b
      catch {close_sim -quiet} ; continue
    }
    set log [file join $projdir "$proj.sim" $ss behav xsim simulate.log]
    set c "?" ; set f "?"
    if {[file exists $log]} {
      set fh [open $log r] ; set txt [read $fh] ; close $fh
      foreach line [split $txt \n] {
        if {[regexp {([0-9]+) checks, ([0-9]+) failures} $line -> cc ff]} { set c $cc ; set f $ff }
      }
    }
    catch {close_sim -quiet}
    if {$c eq "?"} {
      lappend rows [list $b ? ? "NO SUMMARY"] ; lappend failed $b
    } else {
      incr tot_checks $c ; incr tot_fails $f
      lappend rows [list $b $c $f [expr {$f == 0 ? "PASS" : "FAIL"}]]
      if {$f != 0} { lappend failed $b }
    }
  }

  puts "\n==================================================================="
  puts [format "%-22s %10s %8s   %s" BENCH CHECKS FAILS STATUS]
  puts "-------------------------------------------------------------------"
  foreach r $rows { puts [format "%-22s %10s %8s   %s" {*}$r] }
  puts "-------------------------------------------------------------------"
  puts [format "%-22s %10s %8s" TOTAL $tot_checks $tot_fails]
  if {[llength $failed] == 0} {
    puts "\nREGRESSION PASSED  ($tot_checks checks across [llength $rows] benches, XSim project flow)"
  } else {
    puts "\nREGRESSION FAILED  -> [join $failed { }]"
  }
}
