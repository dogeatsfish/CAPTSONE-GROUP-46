#!/usr/bin/env bash
#==============================================================================
# Build and run the Pre-Trade Risk Gateway unit testbench under Verilator.
#
#   ./sim/run_risk_gateway_tb.sh
#
# Requires Verilator 5.x (uses --binary --timing).
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OBJ_DIR="sim/obj_risk_gateway_tb"

verilator \
  --binary \
  --timing \
  --trace \
  -Irtl/common \
  --top-module tb_pre_trade_risk_gateway \
  --Mdir "$OBJ_DIR" \
  -Wno-fatal \
  -Wno-TIMESCALEMOD \
  -Wno-WIDTHEXPAND \
  -Wno-WIDTHTRUNC \
  rtl/common/ct_pkg.sv \
  rtl/risk_gateway/pre_trade_risk_gateway.sv \
  tb/risk_gateway/risk_gateway_tb.sv

"./$OBJ_DIR/Vtb_pre_trade_risk_gateway"
