#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'order_book_crv' bench.
#
#   ./sim/run_order_book_crv_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/order_book_crv.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh order_book_crv
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" order_book_crv "$@"
