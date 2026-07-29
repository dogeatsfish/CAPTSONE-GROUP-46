#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'tx_gen' bench.
#
#   ./sim/run_tx_gen_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/tx_gen.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh tx_gen
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" tx_gen "$@"
