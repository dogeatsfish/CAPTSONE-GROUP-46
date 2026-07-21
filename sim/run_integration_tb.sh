#!/usr/bin/env bash
#==============================================================================
# Build and run the full-chip integration testbench under Verilator.
#
#   ./sim/run_integration_tb.sh
#
# Drives RGMII nibbles into commontrader_top and decodes RGMII nibbles back out.
# No block is stubbed. Requires Verilator 5.x (uses --binary --timing).
#
# NOTE: SYNTHESIS is deliberately NOT defined, so rx_mac_core's IDDR stage and
# tx_mac_core's ODDR stage both fall back to their behavioural equivalents and
# clk_rst_gen replaces the MMCM with a behavioural clock source. Vendor
# primitives are only elaborated by Vivado.
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OBJ_DIR="sim/obj_integration_tb"

verilator \
  --binary \
  --timing \
  --trace \
  -Irtl/common \
  --top-module commontrader_top_tb \
  --Mdir "$OBJ_DIR" \
  -Wno-fatal \
  -Wno-TIMESCALEMOD \
  -Wno-WIDTHEXPAND \
  -Wno-WIDTHTRUNC \
  rtl/common/ct_pkg.sv \
  rtl/common/timestamp_counter.sv \
  rtl/common/clk_rst_gen.sv \
  rtl/rx_mac/crc.sv \
  rtl/rx_mac/rx_mac_core.sv \
  rtl/ip/cdc_fifo/cdc_fifo.sv \
  rtl/ip/cdc_fifo/axis_cdc_fifo.sv \
  rtl/parser/cut_through_parser.sv \
  rtl/order_book/order_book_array.sv \
  rtl/alpha_engine/alpha_engine_core.sv \
  rtl/risk_gateway/pre_trade_risk_gateway.sv \
  rtl/tx_gen/outbound_tx_generator.sv \
  rtl/ip/tx_mac/tx_mac_core.sv \
  rtl/top/commontrader_top.sv \
  tb/top/commontrader_top_tb.sv

"./$OBJ_DIR/Vcommontrader_top_tb"
