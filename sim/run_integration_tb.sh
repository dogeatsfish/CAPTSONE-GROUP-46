#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'integration' bench.
#
#   ./sim/run_integration_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/integration.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh integration
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" integration "$@"
