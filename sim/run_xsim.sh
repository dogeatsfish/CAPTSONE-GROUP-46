#!/usr/bin/env bash
#==============================================================================
# Generic Vivado xsim runner.
#
#   ./sim/run_xsim.sh <bench> [+PLUSARG=value ...]
#   ./sim/run_xsim.sh order_book_crv +SEED=42 +NTXN=50000
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
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source sim/benches.sh

BENCH="${1:-}"
if [[ -z "$BENCH" || -z "${BENCH_TOP[$BENCH]:-}" ]]; then
  echo "usage: $0 <bench> [+PLUSARG=value ...]" >&2
  echo "benches: ${BENCH_ORDER[*]}" >&2
  exit 2
fi
shift

for tool in xvlog xelab xsim; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: '$tool' not on PATH. Source Vivado's settings64.sh first." >&2
    exit 127
  }
done

TOP="${BENCH_TOP[$BENCH]}"
FLIST="sim/filelists/${BENCH}.f"
WORK_DIR="sim/xsim_${BENCH}"
SNAP="${TOP}_snap"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

XVLOG_ARGS=(-sv -work "work=${WORK_DIR}/work" -i rtl/common -f "$FLIST")
XELAB_ARGS=(-work "work=${WORK_DIR}/work" --timescale 1ns/1ps -s "$SNAP" -top "$TOP")

# Elaborate against the real vendor primitives instead of the behavioural
# fallbacks. Only useful for checking the DDR/MMCM stages before bring-up.
if [[ "${SYNTH:-0}" == "1" ]]; then
  XVLOG_ARGS+=(-d SYNTHESIS)
  XELAB_ARGS+=(-L unisims_ver -L unimacro_ver -L secureip)
fi

# Forward +PLUSARGs to the simulation.
XSIM_ARGS=(-runall)
for arg in "$@"; do
  XSIM_ARGS+=(-testplusarg "${arg#+}")
done

echo "--- xvlog ---"
xvlog "${XVLOG_ARGS[@]}" -log "${WORK_DIR}/xvlog.log"
echo "--- xelab ---"
xelab "${XELAB_ARGS[@]}" -log "${WORK_DIR}/xelab.log"
echo "--- xsim ---"
xsim "$SNAP" "${XSIM_ARGS[@]}" -log "${WORK_DIR}/xsim.log"
