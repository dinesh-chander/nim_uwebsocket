#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
source "${ROOT_DIR}/benchmark/build_helpers.sh"

BENCH_BIN="${BENCH_BIN:-${ROOT_DIR}/benchmark/bench_nim_express}"
TARGET_URL="${TARGET_URL:-http://127.0.0.1:3002/plaintext}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-256}"
DURATION="${DURATION:-15s}"
WARMUP="${WARMUP:-3s}"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/profiles/wrk_quick_${STAMP}"
mkdir -p "${OUT_DIR}"
bench_init_cold_build "${ROOT_DIR}" "${OUT_DIR}"

SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      if ! kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
      kill -9 "${SERVER_PID}" >/dev/null 2>&1 || true
    fi
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

bench_rebuild_usockets "${OUT_DIR}/build_usockets.log"
bench_make bench_nim_express bench >"${OUT_DIR}/build.log" 2>&1
"${BENCH_BIN}" >/tmp/nim_express_wrk_quick.log 2>&1 &
SERVER_PID=$!
sleep 2

wrk -t"${THREADS}" -c"${CONNS}" -d"${WARMUP}" "${TARGET_URL}" >/dev/null 2>&1 || true
wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${TARGET_URL}"
