#!/usr/bin/env bash
#==============================================================================
# Build and run the Cut-through Stream Parser unit testbench under Verilator.
#
#   ./sim/run_parser_tb.sh
#
# Requires Verilator 5.x (uses --binary --timing).
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OBJ_DIR="sim/obj_parser_tb"

verilator \
  --binary \
  --timing \
  --trace \
  -Irtl/common \
  --top-module cut_through_parser_tb \
  --Mdir "$OBJ_DIR" \
  -Wno-fatal \
  -Wno-TIMESCALEMOD \
  rtl/common/ct_pkg.sv \
  rtl/parser/cut_through_parser.sv \
  tb/parser/cut_through_parser_tb.sv

"./$OBJ_DIR/Vcut_through_parser_tb"
