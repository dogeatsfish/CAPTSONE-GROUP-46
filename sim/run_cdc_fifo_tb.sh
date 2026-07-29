#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'cdc_fifo' bench.
#
#   ./sim/run_cdc_fifo_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/cdc_fifo.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh cdc_fifo
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" cdc_fifo "$@"
