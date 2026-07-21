#!/usr/bin/env bash
#==============================================================================
# Full regression: every unit testbench plus the full-chip integration bench.
#
#   ./sim/run_all_tb.sh            run everything
#   ./sim/run_all_tb.sh -q         summary only, no per-bench output
#
# Exits non-zero if any bench reports a failure or fails to build, so this is
# safe to gate a merge on.
#
# Every bench prints a line of the form
#   <name> : <N> checks, <M> failures
# and this script keys off that. A bench that builds and runs but prints no
# summary line is treated as a FAILURE, not a pass -- otherwise a silently
# broken bench would look green.
#==============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

QUIET=0
[[ "${1:-}" == "-q" ]] && QUIET=1

# Unit benches first, integration last: if a block is broken, its own bench
# should be what tells you, not the full-chip run.
BENCHES=(
  run_cdc_fifo_tb.sh
  run_rx_mac_tb.sh
  run_tx_mac_tb.sh
  run_parser_tb.sh
  run_order_book_tb.sh
  run_alpha_engine_tb.sh
  run_risk_gateway_tb.sh
  run_tx_gen_tb.sh
  run_integration_tb.sh
)

LOG_DIR="sim/logs"
mkdir -p "$LOG_DIR"

total_checks=0
total_fails=0
failed_benches=()

printf '%-28s %8s %8s   %s\n' "BENCH" "CHECKS" "FAILS" "STATUS"
printf '%s\n' "---------------------------------------------------------------"

for b in "${BENCHES[@]}"; do
  name="${b%.sh}"; name="${name#run_}"
  log="$LOG_DIR/${name}.log"

  if ! bash "sim/$b" >"$log" 2>&1; then
    printf '%-28s %8s %8s   %s\n' "$name" "-" "-" "BUILD/RUN ERROR"
    failed_benches+=("$name")
    total_fails=$((total_fails + 1))
    [[ $QUIET -eq 0 ]] && tail -15 "$log" | sed 's/^/    /'
    continue
  fi

  # "<name> : N checks, M failures"
  summary=$(grep -oE '[0-9]+ checks, [0-9]+ failures' "$log" | tail -1)
  if [[ -z "$summary" ]]; then
    printf '%-28s %8s %8s   %s\n' "$name" "?" "?" "NO SUMMARY LINE"
    failed_benches+=("$name")
    total_fails=$((total_fails + 1))
    continue
  fi

  c=$(awk '{print $1}' <<<"$summary")
  f=$(awk '{print $3}' <<<"$summary")
  total_checks=$((total_checks + c))
  total_fails=$((total_fails + f))

  if [[ "$f" -eq 0 ]]; then
    printf '%-28s %8s %8s   %s\n' "$name" "$c" "$f" "PASS"
  else
    printf '%-28s %8s %8s   %s\n' "$name" "$c" "$f" "FAIL"
    failed_benches+=("$name")
    [[ $QUIET -eq 0 ]] && grep -E '\[FAIL\]' "$log" | head -20 | sed 's/^/    /'
  fi
done

printf '%s\n' "---------------------------------------------------------------"
printf '%-28s %8s %8s\n' "TOTAL" "$total_checks" "$total_fails"

if [[ ${#failed_benches[@]} -eq 0 ]]; then
  echo
  echo "REGRESSION PASSED  ($total_checks checks across ${#BENCHES[@]} benches)"
  echo "Logs in $LOG_DIR/"
  exit 0
else
  echo
  echo "REGRESSION FAILED  -> ${failed_benches[*]}"
  echo "Logs in $LOG_DIR/"
  exit 1
fi
