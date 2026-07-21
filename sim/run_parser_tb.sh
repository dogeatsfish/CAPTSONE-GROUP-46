#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'parser' bench.
#
#   ./sim/run_parser_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/parser.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh parser
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_verilator.sh" parser "$@"
