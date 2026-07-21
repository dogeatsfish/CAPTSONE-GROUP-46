#!/usr/bin/env bash
#==============================================================================
# Build and run the AXI-Stream CDC FIFO unit testbench under Verilator.
#==============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
OBJ_DIR="sim/obj_cdc_fifo_tb"
verilator --binary --timing --trace \
  --top-module axis_cdc_fifo_tb --Mdir "$OBJ_DIR" \
  -Wno-fatal -Wno-TIMESCALEMOD \
  rtl/ip/cdc_fifo/cdc_fifo.sv \
  rtl/ip/cdc_fifo/axis_cdc_fifo.sv \
  tb/ip/cdc_fifo/axis_cdc_fifo_tb.sv
"./$OBJ_DIR/Vaxis_cdc_fifo_tb"
