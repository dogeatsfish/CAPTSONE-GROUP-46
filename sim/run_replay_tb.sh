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

if [[ "${1:-}" == "--events" ]]; then
  python3 sim/csv_to_itch.py --events "$2" --out sim/replay
  shift 2
elif [[ ! -f sim/replay_frames.hex ]]; then
  echo "stimulus missing, generating..."
  python3 sim/csv_to_itch.py --events 400 --out sim/replay
fi

exec ./sim/run_verilator.sh replay "$@"
