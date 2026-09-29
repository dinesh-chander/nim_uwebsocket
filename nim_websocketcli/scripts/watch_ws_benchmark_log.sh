#!/usr/bin/env bash
## Poll a websocketload/benchmark log every POLL_SEC until "Results" appears or timeout.
## Example:
##   bash nim_websocketcli/scripts/watch_ws_benchmark_log.sh benchmark/run500k_console.out &

set -euo pipefail

LOG="${1:-benchmark/run500k_console.out}"
POLL_SEC="${POLL_SEC:-600}"
MAX_POLLS="${MAX_POLLS:-18}"

[[ -n "${LOG}" ]] || { echo "usage: $0 <logfile>"; exit 1; }

for ((i = 1; i <= MAX_POLLS; i++)); do
  if [[ -f "${LOG}" ]] && grep -q 'Results' "${LOG}" 2>/dev/null; then
    echo "$(date -Is) watch_ws_benchmark_log: done (found Results in ${LOG})"
    tail -40 "${LOG}"
    exit 0
  fi
  echo "$(date -Is) watch_ws_benchmark_log: poll ${i}/${MAX_POLLS} (${POLL_SEC}s) — tail ${LOG}"
  if [[ -f "${LOG}" ]]; then
    tail -12 "${LOG}"
  else
    echo "  (log not created yet)"
  fi
  sleep "${POLL_SEC}"
done

echo "$(date -Is) watch_ws_benchmark_log: timeout after ${MAX_POLLS} polls" >&2
exit 1
