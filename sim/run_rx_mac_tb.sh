#!/usr/bin/env bash
#==============================================================================
# Build and run the RX MAC Core unit testbench under Verilator.
#
#   ./sim/run_rx_mac_tb.sh
#
# SYNTHESIS is deliberately NOT defined, so rx_mac_core's IDDR stage falls back
# to its behavioural equivalent. Vendor primitives are only elaborated by Vivado.
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OBJ_DIR="sim/obj_rx_mac_tb"

verilator \
  --binary \
  --timing \
  --trace \
  -Irtl/common \
  --top-module tb_rx_mac_core \
  --Mdir "$OBJ_DIR" \
  -Wno-fatal \
  -Wno-TIMESCALEMOD \
  rtl/common/ct_pkg.sv \
  rtl/rx_mac/crc.sv \
  rtl/rx_mac/rx_mac_core.sv \
  tb/rx_mac/rx_mac_tb.sv

"./$OBJ_DIR/Vtb_rx_mac_core"
