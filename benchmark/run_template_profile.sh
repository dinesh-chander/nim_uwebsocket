#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
source "${ROOT_DIR}/benchmark/build_helpers.sh"

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/reports/template_profile_${STAMP}"
mkdir -p "${OUT_DIR}"
bench_init_cold_build "${ROOT_DIR}" "${OUT_DIR}"
bench_set_common_paths "${ROOT_DIR}"

THREADS="${THREADS:-4}"
CONNS="${CONNS:-500}"
WARMUP="${WARMUP:-5s}"
DURATION="${DURATION:-60s}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-60}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-1}"
TARGET_URL="${TARGET_URL:-http://127.0.0.1:3000/}"
TEMPLATE_RENDER_MODE="${TEMPLATE_RENDER_MODE:-pairs}"

STACKCOLLAPSE="${STACKCOLLAPSE:-/opt/homebrew/opt/flamegraph/bin/stackcollapse-sample.awk}"
FLAMEGRAPH="${FLAMEGRAPH:-/opt/homebrew/opt/flamegraph/bin/flamegraph.pl}"

BASIC_BIN="${BASIC_BIN:-${ROOT_DIR}/examples/bin/basic_app_template_profile}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for cmd in wrk awk curl nim make pkill; do
  require "$cmd"
done

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
  echo "[template-profile] sample/flamegraph capture skipped on non-macOS host"
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
  pkill -f '/examples/bin/basic_app_template_profile' 2>/dev/null || true
  pkill -f '/examples/bin/basic_app_fresh' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait_ready() {
  local url="$1"
  for _ in $(seq 1 120); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

echo "[template-profile] Rebuilding uSockets..."
bench_rebuild_usockets "${OUT_DIR}/build_usockets.log"
USOCKETS_LINK_FLAGS="$(bench_platform_link_flags "${ROOT_DIR}/nim_usockets/usockets/uSockets.a")"

echo "[template-profile] Building basic_app..."
bench_nim basic_app_template_profile c \
  --skipProjCfg:on --skipParentCfg:on \
  -d:release -d:danger --opt:speed --mm:arc --hints:off \
  "${BENCH_COMMON_PATHS[@]}" \
  --passL:"${USOCKETS_LINK_FLAGS}" \
  -o:examples/bin/basic_app_template_profile \
  examples/basic_app.nim \
  >"${OUT_DIR}/build_basic_app.log" 2>&1

pkill -f '/examples/bin/basic_app_template_profile' 2>/dev/null || true
pkill -f '/examples/bin/basic_app_fresh' 2>/dev/null || true

echo "[template-profile] Starting server..."
NIM_EXPRESS_TEMPLATE_RENDER_MODE="${TEMPLATE_RENDER_MODE}" \
  "${BASIC_BIN}" >"${OUT_DIR}/server.log" 2>&1 &
SERVER_PID=$!

wait_ready "${TARGET_URL}" || {
  echo "basic_app_template_profile failed to start" >&2
  exit 1
}

echo "[template-profile] Warmup..."
wrk -t"${THREADS}" -c"${CONNS}" -d"${WARMUP}" "${TARGET_URL}" \
  >"${OUT_DIR}/warmup.wrk.txt" 2>&1 || true

echo "[template-profile] Running load..."
wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${TARGET_URL}" \
  >"${OUT_DIR}/load.wrk.txt" 2>&1 &
LOAD_PID=$!

if [[ "${CAPTURE_SAMPLE}" == "1" ]]; then
  echo "[template-profile] Capturing macOS sample..."
  sample "${SERVER_PID}" "${SAMPLE_SECONDS}" "${SAMPLE_INTERVAL_MS}" \
    -file "${OUT_DIR}/profile.sample.txt" >/dev/null 2>&1 || true
fi

wait "${LOAD_PID}" || true
LOAD_PID=""

if [[ "${CAPTURE_SAMPLE}" == "1" && -s "${OUT_DIR}/profile.sample.txt" ]]; then
  echo "[template-profile] Collapsing stack samples..."
  awk -f "${STACKCOLLAPSE}" "${OUT_DIR}/profile.sample.txt" > "${OUT_DIR}/profile.folded"

  echo "[template-profile] Rendering flamegraph..."
  perl "${FLAMEGRAPH}" --title "template profile ${STAMP}" "${OUT_DIR}/profile.folded" \
    > "${OUT_DIR}/profile.svg"
fi

{
  echo "target=${TARGET_URL}"
  echo "threads=${THREADS}"
  echo "connections=${CONNS}"
  echo "duration=${DURATION}"
  echo "sample_seconds=${SAMPLE_SECONDS}"
  echo "sample_interval_ms=${SAMPLE_INTERVAL_MS}"
  echo "template_render_mode=${TEMPLATE_RENDER_MODE}"
  echo "wrk_rps=$(awk '/Requests\/sec:/ {print $2}' "${OUT_DIR}/load.wrk.txt" | tail -1)"
  echo "wrk_latency=$(awk '/Latency[[:space:]]+/ {print $2, $3; exit}' "${OUT_DIR}/load.wrk.txt")"
} > "${OUT_DIR}/summary.txt"

echo "[template-profile] summary: ${OUT_DIR}/summary.txt"
if [[ "${CAPTURE_SAMPLE}" == "1" ]]; then
  echo "[template-profile] folded:  ${OUT_DIR}/profile.folded"
  echo "[template-profile] svg:     ${OUT_DIR}/profile.svg"
fi
