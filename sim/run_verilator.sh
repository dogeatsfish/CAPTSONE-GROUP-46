#!/usr/bin/env bash
#==============================================================================
# Generic Verilator runner.
#
#   ./sim/run_verilator.sh <bench> [+PLUSARG=value ...]
#   ./sim/run_verilator.sh order_book_crv +SEED=42 +NTXN=50000
#
# Bench names and top modules come from sim/benches.sh; sources come from
# sim/filelists/<bench>.f -- the same filelist sim/run_xsim.sh uses.
#
# SYNTHESIS is deliberately NOT defined, so the IDDR/ODDR stages and the MMCM
# fall back to their behavioural equivalents. Vendor primitives are only
# elaborated by Vivado.
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

TOP="${BENCH_TOP[$BENCH]}"
FLIST="sim/filelists/${BENCH}.f"
OBJ_DIR="sim/obj_${BENCH}_tb"

verilator \
  --binary \
  --timing \
  -Irtl/common \
  --top-module "$TOP" \
  --Mdir "$OBJ_DIR" \
  -Wno-fatal \
  -Wno-TIMESCALEMOD \
  -Wno-WIDTHEXPAND \
  -Wno-WIDTHTRUNC \
  -f "$FLIST"

"./$OBJ_DIR/V$TOP" "$@"
