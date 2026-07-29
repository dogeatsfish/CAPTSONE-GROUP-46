#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'risk_gateway' bench.
#
#   ./sim/run_risk_gateway_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/risk_gateway.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh risk_gateway
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" risk_gateway "$@"
