#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'tx_mac' bench.
#
#   ./sim/run_tx_mac_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/tx_mac.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh tx_mac
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" tx_mac "$@"
