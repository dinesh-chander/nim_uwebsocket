#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
source "${ROOT_DIR}/benchmark/build_helpers.sh"

BENCH_BIN="${BENCH_BIN:-${ROOT_DIR}/benchmark/bench_nim_express}"
TARGET_URL="${TARGET_URL:-http://127.0.0.1:3002/plaintext}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-256}"
WARMUP="${WARMUP:-3s}"
DURATION="${DURATION:-15s}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-15}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-1}"

STACKCOLLAPSE="${STACKCOLLAPSE:-/opt/homebrew/opt/flamegraph/bin/stackcollapse-sample.awk}"
FLAMEGRAPH="${FLAMEGRAPH:-/opt/homebrew/opt/flamegraph/bin/flamegraph.pl}"

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/profiles/flame_${STAMP}"
mkdir -p "${OUT_DIR}"
bench_init_cold_build "${ROOT_DIR}" "${OUT_DIR}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require wrk
require awk
require make

CAPTURE_SAMPLE=0
if [[ "$(uname -s)" == "Darwin" ]]; then
  require sample
  require perl
  if [[ ! -x "${STACKCOLLAPSE}" ]]; then
    echo "Missing stackcollapse script: ${STACKCOLLAPSE}" >&2
    exit 1
  fi
  if [[ ! -x "${FLAMEGRAPH}" ]]; then
    echo "Missing flamegraph.pl: ${FLAMEGRAPH}" >&2
    exit 1
  fi
  CAPTURE_SAMPLE=1
else
  echo "[flame] sample/flamegraph capture skipped on non-macOS host"
fi

SERVER_PID=""
LOAD_PID=""
cleanup() {
  if [[ -n "${LOAD_PID}" ]] && kill -0 "${LOAD_PID}" >/dev/null 2>&1; then
    kill "${LOAD_PID}" >/dev/null 2>&1 || true
    wait "${LOAD_PID}" 2>/dev/null || true
  fi
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "[flame] Building benchmark server..."
bench_rebuild_usockets "${OUT_DIR}/build_usockets.log"
bench_make bench_nim_express bench >"${OUT_DIR}/build.log" 2>&1

echo "[flame] Starting benchmark server..."
"${BENCH_BIN}" >"${OUT_DIR}/server.log" 2>&1 &
SERVER_PID=$!
sleep 2

echo "[flame] Warmup..."
wrk -t"${THREADS}" -c"${CONNS}" -d"${WARMUP}" "${TARGET_URL}" \
  >"${OUT_DIR}/warmup.wrk.txt" 2>&1 || true

echo "[flame] Running load..."
wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${TARGET_URL}" \
  >"${OUT_DIR}/load.wrk.txt" 2>&1 &
LOAD_PID=$!

if [[ "${CAPTURE_SAMPLE}" == "1" ]]; then
  echo "[flame] Capturing macOS sample..."
  sample "${SERVER_PID}" "${SAMPLE_SECONDS}" "${SAMPLE_INTERVAL_MS}" \
    -file "${OUT_DIR}/profile.sample.txt" >/dev/null 2>&1 || true
fi

wait "${LOAD_PID}" || true
LOAD_PID=""

if [[ "${CAPTURE_SAMPLE}" == "1" && -s "${OUT_DIR}/profile.sample.txt" ]]; then
  echo "[flame] Collapsing stack samples..."
  awk -f "${STACKCOLLAPSE}" "${OUT_DIR}/profile.sample.txt" > "${OUT_DIR}/profile.folded"

  echo "[flame] Rendering SVG flamegraph..."
  perl "${FLAMEGRAPH}" --title "nim_express bench ${STAMP}" "${OUT_DIR}/profile.folded" \
    > "${OUT_DIR}/profile.svg"
fi

{
  echo "target=${TARGET_URL}"
  echo "threads=${THREADS}"
  echo "connections=${CONNS}"
  echo "duration=${DURATION}"
  echo "sample_seconds=${SAMPLE_SECONDS}"
  echo "sample_interval_ms=${SAMPLE_INTERVAL_MS}"
  echo "wrk_rps=$(awk '/Requests\/sec:/ {print $2}' "${OUT_DIR}/load.wrk.txt" | tail -1)"
  echo "wrk_latency=$(awk '/Latency/ {print $2, $3; exit}' "${OUT_DIR}/load.wrk.txt")"
} > "${OUT_DIR}/summary.txt"

echo "[flame] Done."
if [[ "${CAPTURE_SAMPLE}" == "1" ]]; then
  echo "[flame] sample:  ${OUT_DIR}/profile.sample.txt"
  echo "[flame] folded:  ${OUT_DIR}/profile.folded"
  echo "[flame] svg:     ${OUT_DIR}/profile.svg"
fi
echo "[flame] summary: ${OUT_DIR}/summary.txt"
