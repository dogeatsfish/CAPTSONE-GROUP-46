#!/usr/bin/env bash
#==============================================================================
# Replay recorded market data through the whole chip.
#
#   ./sim/run_replay_tb.sh                 use the checked-in stimulus
#   ./sim/run_replay_tb.sh --events 2000   regenerate stimulus first, then run
#
# Stimulus is produced by sim/csv_to_itch.py from the software team's MBO
# stream. Regenerated automatically if it is missing.
#==============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

EVENTS="5000"
SIM="verilator"
ARGS=()

while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--events" ]]; then
    EVENTS="$2"
    shift 2
  elif [[ "$1" == "--sim" ]]; then
    SIM="$2"
    shift 2
  else
    ARGS+=("$1")
    shift
  fi
done

echo "generating $EVENTS events..."
python3 sim/csv_to_itch.py --events "$EVENTS" --out sim/replay

if [[ "$SIM" == "xsim" ]]; then
  RUNNER="./sim/run_xsim.sh"
elif [[ "$SIM" == "verilator" ]]; then
  RUNNER="./sim/run_verilator.sh"
else
  echo "unknown simulator '$SIM' (expected verilator or xsim)" >&2
  exit 2
fi

exec "$RUNNER" replay ${ARGS[@]+"${ARGS[@]}"}
