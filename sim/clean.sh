#!/usr/bin/env bash
#==============================================================================
# Remove simulation build artifacts.
#
#   ./sim/clean.sh          build dirs, logs, waveforms
#   ./sim/clean.sh --all    the above plus generated replay stimulus
#
# Nothing here is source. Everything removed is reproducible by re-running the
# benches (and, for --all, sim/csv_to_itch.py).
#
# You do NOT need this to pick up source edits: Verilator emits -MMD dependency
# files, so make already rebuilds exactly what changed. A warm regression is
# ~0.7 s; a cold one is ~78 s. Clean for disk space or before archiving, not out
# of habit.
#==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

before=$(du -sm sim 2>/dev/null | cut -f1)

rm -rf sim/obj_*          # Verilator build dirs (generated C++, .o, binaries)
rm -rf sim/xsim_*         # xsim work libraries and snapshots
rm -rf sim/logs           # regression logs
rm -rf xsim.dir           # xelab snapshot dir, if xsim ran from the repo root
rm -f  sim/*.vcd sim/*.fst sim/*.wdb sim/waveform*
rm -f  *.jou *.pb xvlog.log xelab.log xsim.log

if [[ "${1:-}" == "--all" ]]; then
  rm -f sim/replay_*.hex sim/replay_*.txt
  echo "also removed generated replay stimulus (regenerate: sim/csv_to_itch.py)"
fi

after=$(du -sm sim 2>/dev/null | cut -f1)
echo "sim/ : ${before} MB -> ${after} MB"
