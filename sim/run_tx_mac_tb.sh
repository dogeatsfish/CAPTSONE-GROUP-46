#!/usr/bin/env bash
#==============================================================================
# Build and run the TX MAC Core unit testbench under Verilator.
#==============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
OBJ_DIR="sim/obj_tx_mac_tb"
verilator --binary --timing --trace \
  --top-module tx_mac_core_tb --Mdir "$OBJ_DIR" \
  -Wno-fatal -Wno-TIMESCALEMOD -Wno-EOFNEWLINE \
  rtl/rx_mac/crc.sv \
  rtl/ip/tx_mac/tx_mac_core.sv \
  tb/ip/tx_mac/tx_mac_core_tb.sv
"./$OBJ_DIR/Vtx_mac_core_tb"
