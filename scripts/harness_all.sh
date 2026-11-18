#!/usr/bin/env bash
#
# scripts/harness_all.sh — run every harness unit gate in one shot.
#
# Discovers the package gates (harness/<package>/run.sh) and the middleware
# gates (harness/middleware/<name>/run.sh), runs them, and exits nonzero if any
# unit is not green. This is the entry point CI uses; a unit's own run.sh stays
# the definition of done for that unit.
#
# Usage:
#   bash scripts/harness_all.sh
#
# Environment:
#   HARNESS_JOBS     units to run in parallel (default: 1)
#   HARNESS_ALL_LOGS directory for per-unit logs
#                    (default: ${TMPDIR:-/tmp}/harness_all_logs)
#   NIM              nim binary, forwarded to every gate via harness/common.sh
#
# Each unit's full output is kept in a log; the console only shows one line per
# unit plus the summary, so a red CI run stays readable.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${HARNESS_JOBS:-1}"
LOGS="${HARNESS_ALL_LOGS:-${TMPDIR:-/tmp}/harness_all_logs}"
RESULTS="$LOGS/results.txt"

rm -rf "$LOGS"
mkdir -p "$LOGS"

units=()
for d in "$ROOT_DIR"/harness/*/ "$ROOT_DIR"/harness/middleware/*/; do
  [ -f "${d}run.sh" ] || continue
  case "$(basename "$d")" in
    middleware) continue ;;
  esac
  if [ "$(basename "$(dirname "$d")")" = "middleware" ]; then
    units+=("middleware/$(basename "$d")|${d}run.sh")
  else
    units+=("$(basename "$d")|${d}run.sh")
  fi
done

if [ "${#units[@]}" -eq 0 ]; then
  echo "harness_all: no unit gates found under $ROOT_DIR/harness" >&2
  exit 2
fi

run_one() {
  local spec="$1" label="${1%%|*}" script="${1#*|}"
  local log="$LOGS/$(echo "$label" | tr '/' '_').log"
  if bash "$script" >"$log" 2>&1; then
    echo "PASS $label"
    printf 'PASS\t%s\n' "$label" >>"$RESULTS"
  else
    local rc=$?
    echo "FAIL $label (rc=$rc, log: $log)"
    printf 'FAIL\t%s\n' "$label" >>"$RESULTS"
  fi
}
export -f run_one
export LOGS RESULTS

: >"$RESULTS"
echo "harness_all: ${#units[@]} unit gates, HARNESS_JOBS=$JOBS, logs: $LOGS"
printf '%s\n' "${units[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}

TOTAL=$(wc -l <"$RESULTS" | tr -d ' ')
FAILED=$(grep -c '^FAIL' "$RESULTS" || true)

echo "harness_all: $TOTAL units, $((TOTAL - FAILED)) passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "harness_all: failing units:"
  grep '^FAIL' "$RESULTS" | cut -f2 | sed 's/^/  - /'
  exit 1
fi
echo "harness_all: all unit gates green"
