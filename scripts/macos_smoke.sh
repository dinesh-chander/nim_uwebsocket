#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIM="${NIM:-nim}"
NIMCACHE_ROOT="${NIMCACHE_ROOT:-/tmp/nim_uwebsocket_macos_smoke}"
HTTP_WS_PORT="${HTTP_WS_PORT:-19090}"
BENCH_PORT="${BENCH_PORT:-19091}"
LINK_FLAGS="${ROOT_DIR}/nim_usockets/usockets/uSockets.a -framework CoreFoundation"
NIM_BACKEND_FLAGS=(-d:LIBUS_USE_GCD)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "macos_smoke: skipped on non-macOS host"
  exit 0
fi

COMMON_PATHS=(
  --path:"$ROOT_DIR/nim_utils/src"
  --path:"$ROOT_DIR/nim_usockets/src"
  --path:"$ROOT_DIR/nim_fasthttpclient/src"
  --path:"$ROOT_DIR/nim_express/src"
  --path:"$ROOT_DIR/vendor/zippy/src"
  --path:"$ROOT_DIR/vendor/brotli/src"
  --path:"$ROOT_DIR/vendor/nim_zstd"
  --path:"$ROOT_DIR/vendor/nim_libdeflate_gzip/src"
  --path:"$ROOT_DIR/vendor/malebolgia/src"
  --path:"$ROOT_DIR/vendor/jsony/src"
  --path:"$ROOT_DIR/vendor/checksums"
)

wait_http() {
  local url="$1"
  for _ in $(seq 1 80); do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

terminate_pid() {
  local pid="$1"
  if [ -z "$pid" ] || ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi
  kill "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  terminate_pid "${WS_PID:-}"
  terminate_pid "${BENCH_PID:-}"
}
trap cleanup EXIT INT TERM

cd "$ROOT_DIR"
mkdir -p "$NIMCACHE_ROOT" "$ROOT_DIR/bin"

make usockets USOCKETS_BACKEND=gcd NATIVE_OPT=0

"$NIM" c --skipProjCfg --nimcache:"$NIMCACHE_ROOT/ws_live" \
  "${COMMON_PATHS[@]}" "${NIM_BACKEND_FLAGS[@]}" -d:nimUwebsocketsTest \
  --passL:"$LINK_FLAGS" \
  -o:"$ROOT_DIR/bin/macos_ws_live_server" \
  "$ROOT_DIR/nim_usockets/tests/test_ws_live_server.nim"

HTTP_WS_PORT="$HTTP_WS_PORT" "$ROOT_DIR/bin/macos_ws_live_server" >"$NIMCACHE_ROOT/ws_live.log" 2>&1 &
WS_PID=$!

wait_http "http://127.0.0.1:${HTTP_WS_PORT}/" || {
  echo "macos_smoke: WebSocket live server did not become ready" >&2
  cat "$NIMCACHE_ROOT/ws_live.log" >&2 || true
  exit 1
}

curl -fsS --max-time 2 "http://127.0.0.1:${HTTP_WS_PORT}/" | grep -q "websocket echo server"
WS_UPGRADE_HEADERS="$(
  curl -sS -i --max-time 2 \
    -H "Upgrade: websocket" \
    -H "Connection: Upgrade" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Version: 13" \
    "http://127.0.0.1:${HTTP_WS_PORT}/" 2>/dev/null || true
)"
grep -q "101 Switching Protocols" <<<"$WS_UPGRADE_HEADERS"
grep -qi "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" <<<"$WS_UPGRADE_HEADERS"

make bench USOCKETS_BACKEND=gcd NATIVE_OPT=0 USE_PGO=0 BENCH_BIN="$ROOT_DIR/bin/macos_bench_smoke"

PORT="$BENCH_PORT" NIM_EXPRESS_SCALE_MODE=single "$ROOT_DIR/bin/macos_bench_smoke" >"$NIMCACHE_ROOT/bench.log" 2>&1 &
BENCH_PID=$!

wait_http "http://127.0.0.1:${BENCH_PORT}/plaintext" || {
  echo "macos_smoke: benchmark server did not become ready" >&2
  cat "$NIMCACHE_ROOT/bench.log" >&2 || true
  exit 1
}

curl -fsS --max-time 2 "http://127.0.0.1:${BENCH_PORT}/plaintext" | grep -q "Hello, World!"
curl -fsS --max-time 2 "http://127.0.0.1:${BENCH_PORT}/json" | grep -q '"message":"Hello, World!"'

echo "macos_smoke: PASS"
cleanup
trap - EXIT INT TERM
exit 0
