#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/benchmark/profiles/ws_flame_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${OUT}"
source "${ROOT}/benchmark/build_helpers.sh"
bench_init_cold_build "${ROOT}" "${OUT}"
bench_set_common_paths "${ROOT}"

DURATION="${1:-60}"
CONNS="${2:-220}"
PAYLOAD="${3:-64}"
SKIP_BUILD="${4:-0}"
ENABLE_PROFILE="${5:-1}"

if [ "${SKIP_BUILD}" != "1" ]; then
  bench_rebuild_usockets "${OUT}/build_usockets.log"
  USOCKETS_LINK_FLAGS="$(bench_platform_link_flags "${ROOT}/nim_usockets/usockets/uSockets.a")"
  if [ "$(uname -s)" = "Darwin" ] && [ -d /opt/homebrew/lib ]; then
    USOCKETS_LINK_FLAGS="${USOCKETS_LINK_FLAGS} -L/opt/homebrew/lib -ljemalloc"
  fi
  bench_nim ws_echo_bench c -d:release -d:danger --opt:speed --mm:arc --stackTrace:on \
    "${BENCH_COMMON_PATHS[@]}" \
    --passL:"${USOCKETS_LINK_FLAGS}" \
    -o:"${ROOT}/benchmark/ws_echo_bench" "${ROOT}/benchmark/ws_echo_bench.nim" \
    >"${OUT}/build.log" 2>&1
fi

"${ROOT}/benchmark/ws_echo_bench" >"${OUT}/server.log" 2>&1 &
SERVER_PID=$!
cleanup() {
  if kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sleep 2

SAMPLE_PID=""
if [ "${ENABLE_PROFILE}" = "1" ] && [ "$(uname -s)" = "Darwin" ] && command -v sample >/dev/null 2>&1; then
  sample "${SERVER_PID}" "${DURATION}" -mayDie -file "${OUT}/profile.sample.txt" >/dev/null 2>&1 &
  SAMPLE_PID=$!
elif [ "${ENABLE_PROFILE}" = "1" ]; then
  echo "[ws-flamegraph] sample capture skipped on non-macOS host or missing sample"
  ENABLE_PROFILE=0
fi

node "${ROOT}/benchmark/ws_roundtrip_bench.js" "ws://127.0.0.1:3400" "${CONNS}" "${DURATION}" "${PAYLOAD}" > "${OUT}/ws_result.json"

if [ -n "${SAMPLE_PID}" ]; then
  wait "${SAMPLE_PID}" || true
fi

STACKCOLLAPSE="${STACKCOLLAPSE:-/opt/homebrew/opt/flamegraph/bin/stackcollapse-sample.awk}"
FLAMEGRAPH="${FLAMEGRAPH:-/opt/homebrew/opt/flamegraph/bin/flamegraph.pl}"
if [ "${ENABLE_PROFILE}" = "1" ] && [ -s "${OUT}/profile.sample.txt" ]; then
  awk -f "${STACKCOLLAPSE}" "${OUT}/profile.sample.txt" > "${OUT}/profile.folded"
  perl "${FLAMEGRAPH}" --title "nim ws echo ${DURATION}s" "${OUT}/profile.folded" > "${OUT}/profile.svg"
fi

echo "${OUT}"
