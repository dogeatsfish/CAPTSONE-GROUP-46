#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'alpha_engine' bench.
#
#   ./sim/run_alpha_engine_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/alpha_engine.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh alpha_engine
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" alpha_engine "$@"
