#!/usr/bin/env bash
#==============================================================================
# Generic Vivado xsim runner.
#
#   ./sim/run_xsim.sh <bench> [+PLUSARG=value ...]
#   ./sim/run_xsim.sh order_book_crv +SEED=42 +NTXN=50000
#   ./sim/run_xsim.sh order_book --gui        interactive waveform viewer,
#                                              paused at time 0 -- add signals
#                                              in the Scope/Objects panes, then
#                                              click Run All yourself. Skips
#                                              Vivado's Project Manager /
#                                              simulation-set machinery
#                                              entirely; this IS the same
#                                              build your regression uses.
#
# Reads the SAME sim/filelists/<bench>.f and the SAME sim/benches.sh manifest as
# the Verilator runner, so the two flows cannot drift apart.
#
# Requires the Vivado toolchain on PATH (xvlog / xelab / xsim). Source Xilinx's
# settings64.sh first if they are not already there.
#
# NOTES FOR THE MIGRATION
#   -sv            : the sources are SystemVerilog, xvlog needs telling
#   --timescale    : the RTL carries no `timescale directives on purpose (they
#                    leak across files in compilation order). xelab supplies one
#                    globally instead, matching ct_pkg's 4 ns core period.
#   -L unisims_ver : only needed when SYNTHESIS is defined and the real IDDR /
#                    ODDR / MMCME2_BASE primitives are elaborated. Pass
#                    SYNTH=1 to do that.
#
#   FOUR xsim gotchas this script works around (verified on Vivado 2025.2):
#     * `xsim ... -testplusarg NAME=value` (a value containing "=") makes
#       xsim's CLI parser choke ("Expected a switch but found 9" -- it seems
#       to re-split the value on "=" and then trip over what's left) no matter
#       how the flag or value is spelled or quoted. +SEED=42 / +FRAMES=path
#       are exactly this shape, so this would otherwise break every plusarg
#       this project actually uses. Passing the SAME args via a `-f` response
#       file (one token per line) sidesteps it entirely and is otherwise
#       identical, so that's what this script does.
#     * `-work name=<dir>` is NOT honoured -- xvlog maps the library to the
#       default ./xsim.dir/<name> and then tries to COMPILE the <dir> half as a
#       source file ("Can not find file: <dir>"). Only the name-only `-work
#       work` form works, and the library always lands in ./xsim.dir in the
#       CURRENT directory (there is no flag to relocate it). So we cd INTO the
#       per-bench scratch dir and run the whole flow there -- that keeps every
#       bench isolated and the repo root free of xsim.dir / *.pb / *.jou litter.
#     * xelab takes the top as a POSITIONAL [lib.]unit argument -- there is no
#       -top flag (passing one just prints xelab's help and builds nothing).
#     * `xsim --xsimdir <dir>` (for running the snapshot from a directory other
#       than the one it was built in) is ALSO not honoured -- it accepts the
#       flag and echoes it back but still fails with "Could not open .dbg
#       file". Since xsim must therefore run from WORK_DIR too, any testbench
#       that opens a repo-root-relative default path (e.g. commontrader_replay_tb
#       defaulting to "sim/replay_frames.hex") would silently miss -- WORK_DIR
#       IS sim/xsim_<bench>, so "sim/..." from there means sim/xsim_<bench>/sim/...
#       We fix that generically (no per-bench knowledge needed) by linking
#       WORK_DIR/sim back to the real sim/ -- see below.
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source sim/benches.sh

BENCH="${1:-}"
if [[ -z "$BENCH" || -z "${BENCH_TOP[$BENCH]:-}" ]]; then
  echo "usage: $0 <bench> [+PLUSARG=value ...] [--gui]" >&2
  echo "benches: ${BENCH_ORDER[*]}" >&2
  exit 2
fi
shift

GUI=0
FORWARD_ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--gui" ]]; then
    GUI=1
  else
    FORWARD_ARGS+=("$arg")
  fi
done

for tool in xvlog xelab xsim; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: '$tool' not on PATH. Source Vivado's settings64.sh first." >&2
    exit 127
  }
done

TOP="${BENCH_TOP[$BENCH]}"
FLIST="sim/filelists/${BENCH}.f"
WORK_DIR="sim/xsim_${BENCH}"
REL_ROOT="../.."            # path from inside WORK_DIR (sim/xsim_<bench>) back
                           # to the repo root -- always exactly two levels up.
SNAP="${TOP}_snap"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Make repo-root-relative paths inside testbenches (e.g. a default
# +FRAMES="sim/replay_frames.hex") resolve correctly even though xsim's cwd is
# WORK_DIR, not REPO_ROOT: link WORK_DIR/sim back to the real sim/. `rm -rf`
# above (and on the next run) does not recurse through this -- a symlink /
# NTFS junction is a reparse point, not a real subdirectory, to `rm`.
if command -v powershell.exe >/dev/null 2>&1; then
  # git-bash's `ln -s` needs Developer Mode / elevation on Windows and most
  # machines don't have it -- rather than fail outright it can silently leave
  # a plain empty directory instead of a link, so on Windows use a native NTFS
  # junction (no special privilege required) via PowerShell instead.
  WIN_LINK="$(cygpath -w "${REPO_ROOT}/${WORK_DIR}/sim")"
  WIN_TARGET="$(cygpath -w "${REPO_ROOT}/sim")"
  powershell.exe -NoProfile -Command \
    "New-Item -ItemType Junction -Path '${WIN_LINK}' -Target '${WIN_TARGET}' | Out-Null"
else
  ln -s .. "$WORK_DIR/sim"
fi

# Filelist paths are repo-root-relative, but we compile from inside WORK_DIR, so
# rewrite each source line to be relative to WORK_DIR (prefix REL_ROOT). Keeping
# the paths relative also dodges the space in ".../UW Programming/..." -- an
# absolute-path filelist would split on it, whereas a relative one has no space.
# (Blank lines and #-comments are passed through untouched.)
LOCAL_FLIST="${WORK_DIR}/files.f"
sed -E "s#^([^[:space:]#/].*)#${REL_ROOT}/\1#" "$FLIST" > "$LOCAL_FLIST"

XVLOG_ARGS=(-sv -work work -i "${REL_ROOT}/rtl/common" -f files.f)
XELAB_ARGS=(--timescale 1ns/1ps -s "$SNAP" "work.${TOP}")

# Elaborate against the real vendor primitives instead of the behavioural
# fallbacks. Only useful for checking the DDR/MMCM stages before bring-up.
if [[ "${SYNTH:-0}" == "1" ]]; then
  XVLOG_ARGS+=(-d SYNTHESIS)
  XELAB_ARGS+=(-L unisims_ver -L unimacro_ver -L secureip)
fi

# --gui needs internal signals visible to probe in the waveform viewer --
# "typical" (line + wave + drivers) is what Vivado's own GUI flow elaborates
# with by default. Skipped for headless regression runs: it's extra compile
# time for debug visibility nothing there ever looks at.
if [[ "$GUI" == "1" ]]; then
  XELAB_ARGS+=(--debug typical)
fi

# Forward +PLUSARGs to the simulation.
XSIM_ARGS=()
for arg in ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}; do
  XSIM_ARGS+=(-testplusarg "${arg#+}")
done

if [[ "$GUI" == "1" ]]; then
  # Open paused at time 0 so signals can be added before running; --onfinish
  # stop keeps the window open across $finish instead of closing it.
  XSIM_ARGS+=(--gui --onfinish stop)
else
  XSIM_ARGS+=(-runall)
fi

# Run the whole flow from inside the scratch dir so xsim.dir / *.pb / *.log all
# stay contained there (see header notes).
cd "$WORK_DIR"

echo "--- xvlog ---"
xvlog "${XVLOG_ARGS[@]}" -log xvlog.log
echo "--- xelab ---"
xelab "${XELAB_ARGS[@]}" -log xelab.log
echo "--- xsim ---"
# One token per line -- see the -testplusarg gotcha above for why this isn't
# just "${XSIM_ARGS[@]}" on the command line.
printf '%s\n' "${XSIM_ARGS[@]}" > xsim_args.f
xsim "$SNAP" -f xsim_args.f -log xsim.log
