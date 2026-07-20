#!/usr/bin/env bash
#==============================================================================
# Build and run the Order Book Array unit testbench under Verilator.
#
#   ./sim/run_order_book_tb.sh
#
# Requires Verilator 5.x (uses --binary --timing). Run from anywhere; paths are
# resolved relative to the repo root.
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OBJ_DIR="sim/obj_order_book_tb"

verilator \
  --binary \
  --timing \
  --trace \
  -Irtl/common \
  --top-module order_book_array_tb \
  --Mdir "$OBJ_DIR" \
  -Wno-fatal \
  rtl/common/ct_pkg.sv \
  rtl/order_book/order_book_array.sv \
  tb/order_book/order_book_array_tb.sv

"./$OBJ_DIR/Vorder_book_array_tb"
