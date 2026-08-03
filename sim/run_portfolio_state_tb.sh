#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'portfolio_state' bench.
#
#   ./sim/run_portfolio_state_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/portfolio_state.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh portfolio_state
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_xsim.sh" portfolio_state "$@"
