#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIM="${NIM:-nim}"
NIMCACHE_ROOT="${NIMCACHE_ROOT:-/tmp/nim_uwebsocket_linux_smoke}"
HTTP_WS_PORT="${HTTP_WS_PORT:-9001}"
CLUSTER_PORT="${CLUSTER_PORT:-19080}"
THREADED_PORT="${THREADED_PORT:-19081}"
USOCKETS_BACKEND="${USOCKETS_BACKEND:-epoll}"
LINK_FLAGS="${ROOT_DIR}/nim_usockets/usockets/uSockets.a -lpthread -ldl"
NIM_BACKEND_FLAGS=()

case "$USOCKETS_BACKEND" in
  epoll)
    ;;
  io_uring)
    LINK_FLAGS="${LINK_FLAGS} -luring"
    NIM_BACKEND_FLAGS=(-d:LIBUS_USE_IO_URING)
    ;;
  *)
    echo "linux_smoke: unsupported USOCKETS_BACKEND=$USOCKETS_BACKEND (use epoll or io_uring)" >&2
    exit 1
    ;;
esac

if [ "$(uname -s)" != "Linux" ]; then
  echo "linux_smoke: skipped on non-Linux host"
  exit 0
fi

if [ "${LINUX_SMOKE_IN_PLACE:-0}" != "1" ] && [ -f "/.dockerenv" ]; then
  COPY_ROOT="$(mktemp -d /tmp/nim_uwebsocket_linux_smoke_src.XXXXXX)"
  tar -C "$ROOT_DIR" \
    --exclude='.git' \
    --exclude='bin' \
    --exclude='docs/api' \
    --exclude='nimcache' \
    --exclude='.nimcache' \
    --exclude='nim_usockets/usockets/*.a' \
    --exclude='nim_usockets/usockets/*.o' \
    --exclude='nim_utils/src/nim_utils/nim_fastjson/simdjson/build' \
    -cf - . | tar -C "$COPY_ROOT" -xf -
  set +e
  LINUX_SMOKE_IN_PLACE=1 \
    NIM="$NIM" \
    NIMCACHE_ROOT="$NIMCACHE_ROOT" \
    HTTP_WS_PORT="$HTTP_WS_PORT" \
    CLUSTER_PORT="$CLUSTER_PORT" \
    THREADED_PORT="$THREADED_PORT" \
    USOCKETS_BACKEND="$USOCKETS_BACKEND" \
    bash "$COPY_ROOT/scripts/linux_smoke.sh"
  status=$?
  rm -rf "$COPY_ROOT"
  exit "$status"
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

cleanup() {
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
    for child in $(ps -o pid= --ppid "$pid" 2>/dev/null || true); do
      kill -KILL "$child" >/dev/null 2>&1 || true
    done
    kill -KILL "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  }
  terminate_pid "${WS_PID:-}"
  terminate_pid "${CLUSTER_PID:-}"
  terminate_pid "${THREADED_PID:-}"
}
trap cleanup EXIT INT TERM

cd "$ROOT_DIR"
mkdir -p "$NIMCACHE_ROOT" "$ROOT_DIR/bin"

make usockets USOCKETS_BACKEND="$USOCKETS_BACKEND" NATIVE_OPT=0

"$NIM" c --skipProjCfg --nimcache:"$NIMCACHE_ROOT/ws_live" \
  "${COMMON_PATHS[@]}" "${NIM_BACKEND_FLAGS[@]}" -d:nimUwebsocketsTest \
  --passC:"-D_GNU_SOURCE -ftls-model=local-exec" \
  --passL:"$LINK_FLAGS" \
  -o:"$ROOT_DIR/bin/linux_ws_live_server" \
  "$ROOT_DIR/nim_usockets/tests/test_ws_live_server.nim"

HTTP_WS_PORT="$HTTP_WS_PORT" "$ROOT_DIR/bin/linux_ws_live_server" >"$NIMCACHE_ROOT/ws_live.log" 2>&1 &
WS_PID=$!

wait_http "http://127.0.0.1:${HTTP_WS_PORT}/" || {
  echo "linux_smoke: WebSocket live server did not become ready" >&2
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

"$NIM" c --skipProjCfg --threads:on --nimcache:"$NIMCACHE_ROOT/linux_multiprocess" \
  "${COMMON_PATHS[@]}" "${NIM_BACKEND_FLAGS[@]}" -d:release --opt:speed --mm:arc \
  --passC:"-D_GNU_SOURCE -ftls-model=local-exec" \
  --passL:"$LINK_FLAGS" \
  -o:"$ROOT_DIR/bin/linux_multiprocess_smoke" \
  "$ROOT_DIR/examples/linux_multiprocess.nim"

PORT="$CLUSTER_PORT" WORKERS=2 "$ROOT_DIR/bin/linux_multiprocess_smoke" >"$NIMCACHE_ROOT/cluster.log" 2>&1 &
CLUSTER_PID=$!

wait_http "http://127.0.0.1:${CLUSTER_PORT}/health" || {
  echo "linux_smoke: runCluster smoke server did not become ready" >&2
  cat "$NIMCACHE_ROOT/cluster.log" >&2 || true
  exit 1
}

if grep -Eq 'failed to start|cluster_worker_exit' "$NIMCACHE_ROOT/cluster.log"; then
  echo "linux_smoke: cluster log contains worker startup or supervision failure" >&2
  cat "$NIMCACHE_ROOT/cluster.log" >&2 || true
  exit 1
fi
WORKER_STARTS="$(grep -Ec 'Worker [0-9]+ .* started on port' "$NIMCACHE_ROOT/cluster.log" || true)"
if [ "$WORKER_STARTS" -lt 2 ]; then
  echo "linux_smoke: expected at least 2 worker start lines, got $WORKER_STARTS" >&2
  cat "$NIMCACHE_ROOT/cluster.log" >&2 || true
  exit 1
fi

if ! curl -fsS --max-time 2 "http://127.0.0.1:${CLUSTER_PORT}/health" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
  echo "linux_smoke: health response was not valid JSON status ok" >&2
  exit 1
fi
if ! curl -fsS --max-time 2 "http://127.0.0.1:${CLUSTER_PORT}/api/echo?msg=linux" | grep -Eq '"echo"[[:space:]]*:[[:space:]]*"linux"'; then
  echo "linux_smoke: echo response did not round-trip plain text" >&2
  exit 1
fi
if ! curl -fsS --max-time 2 "http://127.0.0.1:${CLUSTER_PORT}/api/quote" | grep -Eq '"echo"[[:space:]]*:[[:space:]]*"a\\\"b"'; then
  echo "linux_smoke: echo response did not JSON-escape quotes" >&2
  exit 1
fi
LARGE_BYTES="$(curl -fsS --max-time 2 "http://127.0.0.1:${CLUSTER_PORT}/api/large" | wc -c | tr -d ' ')"
if [ "$LARGE_BYTES" -lt 32000 ]; then
  echo "linux_smoke: large response was truncated ($LARGE_BYTES bytes)" >&2
  exit 1
fi

"$NIM" c --skipProjCfg --threads:on --nimcache:"$NIMCACHE_ROOT/linux_multithreaded" \
  "${COMMON_PATHS[@]}" "${NIM_BACKEND_FLAGS[@]}" -d:release --opt:speed --mm:arc \
  --passC:"-D_GNU_SOURCE -ftls-model=local-exec" \
  --passL:"$LINK_FLAGS" \
  -o:"$ROOT_DIR/bin/linux_multithreaded_smoke" \
  "$ROOT_DIR/examples/linux_multithreaded.nim"

PORT="$THREADED_PORT" THREADS=2 "$ROOT_DIR/bin/linux_multithreaded_smoke" >"$NIMCACHE_ROOT/threaded.log" 2>&1 &
THREADED_PID=$!

wait_http "http://127.0.0.1:${THREADED_PORT}/health" || {
  echo "linux_smoke: runThreaded smoke server did not become ready" >&2
  cat "$NIMCACHE_ROOT/threaded.log" >&2 || true
  exit 1
}

if grep -Eqi 'failed to start|thread.*exit|segmentation fault|panic' "$NIMCACHE_ROOT/threaded.log"; then
  echo "linux_smoke: threaded log contains startup/runtime failure" >&2
  cat "$NIMCACHE_ROOT/threaded.log" >&2 || true
  exit 1
fi
if ! curl -fsS --max-time 2 "http://127.0.0.1:${THREADED_PORT}/health" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
  echo "linux_smoke: threaded health response was not valid JSON status ok" >&2
  exit 1
fi
if ! curl -fsS --max-time 2 "http://127.0.0.1:${THREADED_PORT}/api/echo?msg=threaded" | grep -Eq '"echo"[[:space:]]*:[[:space:]]*"threaded"'; then
  echo "linux_smoke: threaded echo response did not round-trip plain text" >&2
  exit 1
fi
THREAD_WS_HEADERS="$(
  curl -sS -i --max-time 2 \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  "http://127.0.0.1:${THREADED_PORT}/" 2>/dev/null || true
)"
grep -q "101 Switching Protocols" <<<"$THREAD_WS_HEADERS"
grep -qi "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" <<<"$THREAD_WS_HEADERS"

echo "linux_smoke: PASS"
cleanup
trap - EXIT INT TERM
exit 0
