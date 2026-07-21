#!/usr/bin/env bash
#==============================================================================
# Full regression: every unit testbench plus the full-chip integration bench.
#
#   ./sim/run_all_tb.sh                    all benches under Verilator
#   ./sim/run_all_tb.sh --sim xsim         same benches under Vivado xsim
#   ./sim/run_all_tb.sh -q                 summary only, no failure excerpts
#
# Bench list, top modules and source lists all come from sim/benches.sh and
# sim/filelists/, shared with both runners -- so "it passes in Verilator but not
# xsim" can only ever be a real RTL/TB portability issue, never a difference in
# what got compiled.
#
# Exits non-zero if any bench fails or fails to build, so this is safe to gate
# a merge on.
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
source sim/benches.sh

SIM="verilator"
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) SIM="${2:-}"; shift 2 ;;
    -q)    QUIET=1; shift ;;
    *)     echo "usage: $0 [--sim verilator|xsim] [-q]" >&2; exit 2 ;;
  esac
done

case "$SIM" in
  verilator) RUNNER="sim/run_verilator.sh" ;;
  xsim)      RUNNER="sim/run_xsim.sh" ;;
  *)         echo "unknown simulator '$SIM' (expected verilator or xsim)" >&2; exit 2 ;;
esac

LOG_DIR="sim/logs/$SIM"
mkdir -p "$LOG_DIR"

total_checks=0
total_fails=0
failed_benches=()

echo "simulator: $SIM"
echo
printf '%-28s %10s %8s   %s\n' "BENCH" "CHECKS" "FAILS" "STATUS"
printf '%s\n' "-----------------------------------------------------------------"

for name in "${BENCH_ORDER[@]}"; do
  log="$LOG_DIR/${name}.log"

  if ! bash "$RUNNER" "$name" >"$log" 2>&1; then
    printf '%-28s %10s %8s   %s\n' "$name" "-" "-" "BUILD/RUN ERROR"
    failed_benches+=("$name")
    total_fails=$((total_fails + 1))
    [[ $QUIET -eq 0 ]] && tail -15 "$log" | sed 's/^/    /'
    continue
  fi

  # "<name> : N checks, M failures"
  summary=$(grep -oE '[0-9]+ checks, [0-9]+ failures' "$log" | tail -1)
  if [[ -z "$summary" ]]; then
    printf '%-28s %10s %8s   %s\n' "$name" "?" "?" "NO SUMMARY LINE"
    failed_benches+=("$name")
    total_fails=$((total_fails + 1))
    continue
  fi

  c=$(awk '{print $1}' <<<"$summary")
  f=$(awk '{print $3}' <<<"$summary")
  total_checks=$((total_checks + c))
  total_fails=$((total_fails + f))

  if [[ "$f" -eq 0 ]]; then
    printf '%-28s %10s %8s   %s\n' "$name" "$c" "$f" "PASS"
  else
    printf '%-28s %10s %8s   %s\n' "$name" "$c" "$f" "FAIL"
    failed_benches+=("$name")
    [[ $QUIET -eq 0 ]] && grep -E '\[FAIL\]' "$log" | head -20 | sed 's/^/    /'
  fi
done

printf '%s\n' "-----------------------------------------------------------------"
printf '%-28s %10s %8s\n' "TOTAL" "$total_checks" "$total_fails"

if [[ ${#failed_benches[@]} -eq 0 ]]; then
  echo
  echo "REGRESSION PASSED  ($total_checks checks across ${#BENCH_ORDER[@]} benches, $SIM)"
  echo "Logs in $LOG_DIR/"
  exit 0
else
  echo
  echo "REGRESSION FAILED  -> ${failed_benches[*]}"
  echo "Logs in $LOG_DIR/"
  exit 1
fi
