#!/usr/bin/env bash
#==============================================================================
# Build and run the Alpha Engine Core unit testbench under Verilator.
#
#   ./sim/run_alpha_engine_tb.sh
#
# Requires Verilator 5.x (uses --binary --timing).
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OBJ_DIR="sim/obj_alpha_engine_tb"

verilator \
  --binary \
  --timing \
  --trace \
  -Irtl/common \
  --top-module alpha_engine_core_tb \
  --Mdir "$OBJ_DIR" \
  -Wno-fatal \
  -Wno-TIMESCALEMOD \
  rtl/common/ct_pkg.sv \
  rtl/alpha_engine/alpha_engine_core.sv \
  tb/alpha_engine/alpha_engine_core_tb.sv

"./$OBJ_DIR/Valpha_engine_core_tb"
