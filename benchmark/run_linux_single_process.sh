#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$BENCH_DIR/.." && pwd)"
USOCKETS_DIR="$ROOT_DIR/nim_usockets/usockets"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/reports/linux_single_process_${STAMP}"
mkdir -p "${OUT_DIR}"
source "${ROOT_DIR}/benchmark/build_helpers.sh"
bench_set_common_paths "${ROOT_DIR}"
NATIVE_CFLAGS="$(bench_native_cflags)"
PLATFORM_CFLAGS="$(bench_platform_cflags)"
BACKEND_NIM_FLAGS="$(bench_backend_nim_flags)"
LINK_FLAGS="$(bench_platform_link_flags "../nim_usockets/usockets/uSockets.a")"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must run on Linux."
  exit 1
fi

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required (apt install wrk)."
  exit 1
fi

NPROC="$(nproc 2>/dev/null || echo 4)"

make -C "$ROOT_DIR" usockets USOCKETS_BACKEND="${USOCKETS_BACKEND:-epoll}"

pushd "$BENCH_DIR" >/dev/null
nim c -f --cc:clang --nimcache:"${OUT_DIR}/nimcache/bench_nim_express_linux" -d:release -d:danger --opt:speed --hints:off \
  ${BACKEND_NIM_FLAGS} \
  "${BENCH_COMMON_PATHS[@]}" \
  --passC:"-Ofast -flto ${PLATFORM_CFLAGS} ${NATIVE_CFLAGS}" \
  --passL:"${LINK_FLAGS} -flto" \
  -o:bench_nim_express_linux bench_nim_express.nim

./bench_nim_express_linux >/tmp/bench_nim_express_linux.log 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
sleep 1.5

echo "=== Linux single-process /json ==="
wrk -t4 -c100 -d20s --latency http://127.0.0.1:3002/json

echo
echo "=== Linux single-process /plaintext ==="
wrk -t4 -c100 -d20s --latency http://127.0.0.1:3002/plaintext

kill "$PID" 2>/dev/null || true
trap - EXIT
popd >/dev/null
