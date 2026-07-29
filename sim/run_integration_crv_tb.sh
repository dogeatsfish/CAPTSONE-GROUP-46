#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'integration_crv' bench.
#
#   ./sim/run_integration_crv_tb.sh                       default seed
#   ./sim/run_integration_crv_tb.sh +SEED=1234            reproduce a failure
#   ./sim/run_integration_crv_tb.sh +NPKT_A=200           longer soak
#
# To run the same bench under Vivado:  ./sim/run_xsim.sh integration_crv
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" integration_crv "$@"
