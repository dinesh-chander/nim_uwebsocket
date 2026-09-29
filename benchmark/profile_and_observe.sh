#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES_DIR="${ROOT_DIR}/benchmark/profiles/iter_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${PROFILES_DIR}"

APP_CMD="${APP_CMD:-${ROOT_DIR}/benchmark/bench_nim_express}"
TARGET_URL="${TARGET_URL:-http://127.0.0.1:3002/plaintext}"
ITERATIONS="${ITERATIONS:-5}"
DURATION="${DURATION:-15s}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-256}"
WARMUP="${WARMUP:-3s}"

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required" >&2
  exit 1
fi

"${APP_CMD}" >/tmp/nim_profile_app.log 2>&1 &
APP_PID=$!
cleanup() {
  kill ${APP_PID} >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

sleep 1
wrk -t"${THREADS}" -c"${CONNS}" -d"${WARMUP}" "${TARGET_URL}" >/dev/null || true

for ((i=1; i<=ITERATIONS; i++)); do
  OUT_FILE="${PROFILES_DIR}/iter_${i}.wrk.txt"
  wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" "${TARGET_URL}" | tee "${OUT_FILE}" >/dev/null

  if [[ "$(uname -s)" == "Darwin" ]] && command -v sample >/dev/null 2>&1; then
    sample ${APP_PID} 2 1 -file "${PROFILES_DIR}/iter_${i}.sample.txt" >/dev/null 2>&1 || true
  elif [[ "$(uname -s)" == "Linux" ]] && command -v perf >/dev/null 2>&1; then
    perf record -F 99 -p ${APP_PID} -g -- sleep 2 >/dev/null 2>&1 || true
    perf script > "${PROFILES_DIR}/iter_${i}.perf.txt" 2>/dev/null || true
  fi

done

{
  echo "# Profiling Iterations"
  echo
  echo "- app_cmd: ${APP_CMD}"
  echo "- target_url: ${TARGET_URL}"
  echo "- iterations: ${ITERATIONS}"
  echo "- duration: ${DURATION}"
  echo
  echo "## Throughput"
  for f in "${PROFILES_DIR}"/*.wrk.txt; do
    rps=$(awk '/Requests\/sec:/ {print $2}' "$f" | tail -1)
    lat=$(awk '/Latency/ {print $2" "$3}' "$f" | head -1)
    echo "- $(basename "$f"): req/s=${rps}, latency=${lat}"
  done
} > "${PROFILES_DIR}/report.md"

echo "[profile] artifacts: ${PROFILES_DIR}"
