#!/usr/bin/env bash
#==============================================================================
# Convenience wrapper: run the 'clk_rst_gen' bench.
#
#   ./sim/run_clk_rst_gen_tb.sh [+PLUSARG=value ...]
#
# Sources live in sim/filelists/clk_rst_gen.f and the top module in sim/benches.sh,
# both shared with the xsim flow. To run the same bench under Vivado:
#
#   ./sim/run_xsim.sh clk_rst_gen
#==============================================================================
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/run_xsim.sh" clk_rst_gen "$@"
