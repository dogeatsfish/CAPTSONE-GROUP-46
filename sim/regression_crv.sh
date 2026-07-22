#!/usr/bin/env bash
#==============================================================================
# CRV seed regression -- run BOTH constrained-random benches across many seeds
# under Vivado xsim, never stopping on a failure, then report which seeds failed.
#
#   ./sim/regression_crv.sh                    seeds 1..20 (default)
#   ./sim/regression_crv.sh --seeds 1 100      seeds 1..100
#   ./sim/regression_crv.sh +NPKT_C=400        forward extra plusargs to every run
#   ./sim/regression_crv.sh --seeds 1 50 +NTXN=20000
#
# The two CRV benches (order_book_crv, integration_crv) are the only ones that
# read +SEED, so this is the targeted version of `run_all_tb.sh +SEED=$s`.
#
# Unlike a rebuild-per-seed loop, each bench is ELABORATED ONCE and the snapshot
# is re-run per seed (seeds only change runtime plusargs, not the design), so a
# 20-seed sweep is ~2 builds + 40 fast sims instead of 40 full builds.
#
# xsim-only: uses the same xvlog/xelab/xsim incantation as sim/run_xsim.sh
# (name-only -work, ../.. relative filelist, plusargs via a -f response file to
# dodge the xsim '=' CLI bug). Requires the Vivado toolchain on PATH.
#==============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source sim/benches.sh

LO=1
HI=20
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seeds) LO="${2:?}"; HI="${3:?}"; shift 3 ;;
    +*)      EXTRA+=("$1"); shift ;;
    -h|--help)
      echo "usage: $0 [--seeds LO HI] [+PLUSARG=v ...]" >&2; exit 0 ;;
    *) echo "usage: $0 [--seeds LO HI] [+PLUSARG=v ...]" >&2; exit 2 ;;
  esac
done

for tool in xvlog xelab xsim; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: '$tool' not on PATH. Source Vivado's settings64.sh first." >&2
    exit 127
  }
done

BENCHES=(order_book_crv integration_crv)

FAILS=()          # human-readable "seed N  bench  detail" lines
runs=0

echo "CRV regression: seeds ${LO}..${HI}, benches: ${BENCHES[*]}"
[[ ${#EXTRA[@]} -gt 0 ]] && echo "extra plusargs: ${EXTRA[*]}"
echo

for b in "${BENCHES[@]}"; do
  TOP="${BENCH_TOP[$b]}"
  SNAP="${TOP}_snap"
  WD="sim/xsim_regression_${b}"    # sim/xsim_* is gitignored

  rm -rf "$WD"; mkdir -p "$WD"
  sed -E 's#^([^# ].*)#../../\1#' "sim/filelists/${b}.f" > "$WD/files.f"

  echo ">>> building $b ($TOP) ..."
  if ! ( cd "$WD" \
         && xvlog -sv -work work -i ../../rtl/common -f files.f -log xvlog.log >/dev/null 2>&1 \
         && xelab --timescale 1ns/1ps -s "$SNAP" "work.${TOP}" -log xelab.log >/dev/null 2>&1 ); then
    echo "    BUILD FAILED -- see $WD/xvlog.log and $WD/xelab.log"
    for s in $(seq "$LO" "$HI"); do FAILS+=("seed $s  $b  BUILD-ERROR"); done
    continue
  fi

  for s in $(seq "$LO" "$HI"); do
    runs=$((runs + 1))
    # Response file: one token per line; dodges the xsim '=' plusarg CLI bug.
    { printf -- '-testplusarg\nSEED=%s\n' "$s"
      for e in ${EXTRA[@]+"${EXTRA[@]}"}; do printf -- '-testplusarg\n%s\n' "${e#+}"; done
      printf -- '-runall\n'
    } > "$WD/seed.f"

    ( cd "$WD" && xsim "$SNAP" -f seed.f -log "run_seed${s}.log" >/dev/null 2>&1 )

    summary=$(grep -oE '[0-9]+ checks, [0-9]+ failures' "$WD/run_seed${s}.log" | tail -1)
    if [[ -z "$summary" ]]; then
      printf '  seed %-4s %-17s NO SUMMARY (crash/timeout? see %s)\n' "$s" "$b" "$WD/run_seed${s}.log"
      FAILS+=("seed $s  $b  NO-SUMMARY")
    else
      f=$(awk '{print $3}' <<<"$summary")
      if [[ "$f" -ne 0 ]]; then
        printf '  seed %-4s %-17s FAIL  (%s)\n' "$s" "$b" "$summary"
        FAILS+=("seed $s  $b  ($summary)")
      else
        printf '  seed %-4s %-17s ok    (%s)\n' "$s" "$b" "$summary"
      fi
    fi
  done
done

echo
echo "================= CRV REGRESSION SUMMARY ================="
echo "seeds ${LO}..${HI}  benches: ${BENCHES[*]}  ($runs runs, xsim)"
if [[ ${#FAILS[@]} -eq 0 ]]; then
  echo "ALL PASSED"
  echo "logs in sim/xsim_regression_<bench>/run_seed<N>.log"
  exit 0
else
  echo "FAILURES (${#FAILS[@]}):"
  printf '  %s\n' "${FAILS[@]}"
  echo
  echo "failing seeds: $(printf '%s\n' "${FAILS[@]}" | awk '{print $2}' | sort -un | tr '\n' ' ')"
  echo "logs in sim/xsim_regression_<bench>/run_seed<N>.log"
  exit 1
fi
