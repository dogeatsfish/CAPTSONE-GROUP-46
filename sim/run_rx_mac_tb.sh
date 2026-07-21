#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'rx_mac' bench.
#
#   ./sim/run_rx_mac_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/rx_mac.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh rx_mac
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" rx_mac "$@"
