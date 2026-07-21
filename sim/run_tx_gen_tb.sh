#!/usr/bin/env bash
#==============================================================================
# Build and run the Outbound TX Generator unit testbench under Verilator.
#
#   ./sim/run_tx_gen_tb.sh
#
# Requires Verilator 5.x (uses --binary --timing).
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OBJ_DIR="sim/obj_tx_gen_tb"

verilator \
  --binary \
  --timing \
  --trace \
  -Irtl/common \
  --top-module outbound_tx_generator_tb \
  --Mdir "$OBJ_DIR" \
  -Wno-fatal \
  -Wno-TIMESCALEMOD \
  rtl/common/ct_pkg.sv \
  rtl/tx_gen/outbound_tx_generator.sv \
  tb/tx_gen/outbound_tx_generator_tb.sv

"./$OBJ_DIR/Voutbound_tx_generator_tb"
