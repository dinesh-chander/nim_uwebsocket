#!/usr/bin/env bash
#
# scripts/coverage_gate.sh — enforce the project coverage floor.
#
# Parses coverage/summary.md (produced by scripts/coverage.sh), checks the
# full-suite line coverage against ci/coverage-baseline.json, and fails when:
#   1. any test failed or any build failed during the coverage run, or
#   2. measured coverage dropped more than COVERAGE_TOLERANCE_PP (default
#      0.25 points) below the baseline.
#
# When coverage exceeds the baseline by more than the tolerance the gate
# passes but prints how to raise the baseline.
#
# Usage:
#   scripts/coverage_gate.sh --baseline ci/coverage-baseline.json --out coverage
#
# Environment:
#   COVERAGE_TOLERANCE_PP  allowed drop in percentage points (default 0.25)

set -euo pipefail

BASELINE=""
OUT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) BASELINE="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "coverage_gate: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BASELINE" ] || { echo "coverage_gate: --baseline is required" >&2; exit 2; }
[ -n "$OUT_DIR" ] || { echo "coverage_gate: --out is required" >&2; exit 2; }
[ -f "$BASELINE" ] || { echo "coverage_gate: baseline file not found: $BASELINE" >&2; exit 2; }
[ -f "$OUT_DIR/summary.md" ] || { echo "coverage_gate: missing $OUT_DIR/summary.md (run scripts/coverage.sh first)" >&2; exit 2; }

TOLERANCE="${COVERAGE_TOLERANCE_PP:-0.25}"

# Hard failures first: failed tests/builds make the number meaningless.
FAILED_TESTS=0
FAILED_BUILDS=0
if [ -s "$OUT_DIR/failed_tests.txt" ]; then
  FAILED_TESTS=$(wc -l <"$OUT_DIR/failed_tests.txt" | tr -d ' ')
fi
if [ -s "$OUT_DIR/build_failures.txt" ]; then
  FAILED_BUILDS=$(wc -l <"$OUT_DIR/build_failures.txt" | tr -d ' ')
fi

# Per-package table from summary.md. Prefer the explicit **Total** row;
# fall back to summing package rows for summaries generated without one.
MEASURED_ROW=$(awk -f /dev/stdin "$OUT_DIR/summary.md" <<'AWK'
BEGIN { FS = "|" }
/^## Line coverage per package/ { insec=1; next }
/^## / { insec=0 }
insec && /Total/ {
  gsub(/[ %]/, "", $3); gsub(/[ %]/, "", $4); gsub(/[^0-9.]/, "", $5)
  printf "%d %d %s\n", $3+0, $4+0, $5; found=1; exit
}
insec && NF >= 5 && $2 !~ /^[- ]+$/ &&  $2 !~ /Package/ {
  l=$3+0; m=$4+0; tl+=l; tm+=m
}
END { if (!found) printf "%d %d %.2f\n", tl, tm, (tl>0 ? (tl-tm)*100/tl : 0) }
AWK
)
read -r LINES MISSED MEASURED <<EOF
$MEASURED_ROW
EOF
if [ "${LINES:-0}" -le 0 ]; then
  echo "coverage_gate: could not parse a coverage table from $OUT_DIR/summary.md" >&2
  exit 2
fi

MEASURED=$(awk -v v="$MEASURED" 'BEGIN { printf "%.2f", v }')
BASELINE_PCT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["coverage_pct"])' "$BASELINE")

# Job summary (GitHub Actions).
SUMMARY="${GITHUB_STEP_SUMMARY:-}"
summary() { [ -n "$SUMMARY" ] && printf '%s\n' "$@" >>"$SUMMARY" || printf '%s\n' "$@"; }

summary "## Coverage gate"
summary
summary "| | Lines | Missed | Coverage |"
summary "|---|---:|---:|---:|"
awk -F'|' '
  /^## Line coverage per package/ { insec=1; next }
  /^## / { insec=0 }
  insec && NF >= 5 && $2 !~ /^[- ]+$/ &&  $2 !~ /Package/ && $2 !~ /Total/ {
    printf "| %s | %d | %d | %s |\n", $2, $3, $4, $5
  }
' "$OUT_DIR/summary.md" | while IFS= read -r line; do summary "$line"; done
summary
summary "- **Total: ${MEASURED}%** (lines $LINES, missed $MISSED)"
summary "- Baseline: ${BASELINE_PCT}% (${BASELINE})"
summary "- Tolerance: ${TOLERANCE} pp"
summary

if [ "$FAILED_TESTS" -gt 0 ] || [ "$FAILED_BUILDS" -gt 0 ]; then
  summary
  summary "**FAIL: coverage suite was not green** — failed tests: $FAILED_TESTS, failed builds: $FAILED_BUILDS"
  echo "coverage_gate: FAIL — $FAILED_TESTS failed tests, $FAILED_BUILDS failed builds; coverage numbers are not trustworthy" >&2
  exit 1
fi

VERDICT=$(awk -v m="$MEASURED" -v b="$BASELINE_PCT" -v t="$TOLERANCE" \
  'BEGIN {
    delta = m - b
    if (delta < -t) print "drop"
    else if (delta > t) print "gain"
    else print "flat"
  }')

case "$VERDICT" in
  drop)
    summary
    summary "**FAIL: coverage dropped to ${MEASURED}% (baseline ${BASELINE_PCT}%, tolerance ${TOLERANCE} pp).**"
    summary
    summary "Fix the regression, or if the drop is justified (removed dead code counted by old tests,
refactor moved logic to uncovered C helpers), re-measure locally with
`bash scripts/coverage.sh && python3 scripts/update_coverage_baseline.py coverage/summary.md`
and commit the updated $BASELINE."
    echo "coverage_gate: FAIL — coverage ${MEASURED}% < baseline ${BASELINE_PCT}% - ${TOLERANCE} pp" >&2
    exit 1
    ;;
  gain)
    summary
    summary "**PASS with gain:** coverage is ${MEASURED}% (baseline ${BASELINE_PCT}%). Consider raising the"
    summary "baseline: \`python3 scripts/update_coverage_baseline.py coverage/summary.md\` (local re-measure
recommended) and committing $BASELINE."
    echo "coverage_gate: PASS — coverage ${MEASURED}% (baseline ${BASELINE_PCT}%, gain)"
    ;;
  *)
    summary
    summary "**PASS:** coverage ${MEASURED}% is within ${TOLERANCE} pp of baseline ${BASELINE_PCT}%."
    echo "coverage_gate: PASS — coverage ${MEASURED}% (baseline ${BASELINE_PCT}%)"
    ;;
esac
