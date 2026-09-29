#!/usr/bin/env bash
## Single-process ~500k idle WebSockets (requires ``MaxConnectionsPerWorkerThread`` large enough:
## ``worstThread0Load(500000,24)=20841``). Use a gentle ramp and retries.
##
##   bash nim_websocketcli/scripts/run_500k_ws_load.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "run_500k_ws_load.sh must run on Linux."
  exit 1
fi

ulimit -n 1048576 2>/dev/null || true
bash nim_websocketcli/scripts/ws_preflight_500k.sh

BIN="${WEBSOCKETLOAD:-$ROOT/nim_websocketcli/websocketload}"
[[ -x "$BIN" ]] || { echo "Build: make websocketload USOCKETS_BACKEND=io_uring"; exit 1; }
SERVER_BIN="${WS_ECHO_BENCH:-$ROOT/benchmark/ws_echo_bench}"
[[ -x "$SERVER_BIN" ]] || { echo "Build: make ws-echo-bench USOCKETS_BACKEND=io_uring"; exit 1; }

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3400}"
PATH_WS="${PATH_WS:-/}"
BINDLB="${BINDLB:-253}"
CONCURRENCY="${CONCURRENCY:-500000}"
CLIENT_THREADS="${CLIENT_THREADS:-24}"
DURATION="${DURATION:-180}"
RAMP_SEC="${RAMP_SEC:-120}"
SRV_THREADS="${SRV_THREADS:-24}"

pkill -f '/benchmark/ws_echo_bench' 2>/dev/null || true
sleep 1

THREADS="$SRV_THREADS" PORT="$PORT" "$SERVER_BIN" > benchmark/run500k_srv.log 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 120); do
  curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && break
  sleep 0.25
done
curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null

echo "[500k] websocketload -c $CONCURRENCY -t $CLIENT_THREADS ramp=${RAMP_SEC}s d=${DURATION}s → benchmark/run500k_client.log"
/usr/bin/time -f $'\nwebsocketload_wall_sec=%e\n' timeout 14400 "$BIN" \
  -h "$HOST" -p "$PORT" --path "$PATH_WS" \
  -c "$CONCURRENCY" -t "$CLIENT_THREADS" -d "$DURATION" \
  --bind-loopbacks "$BINDLB" \
  --open-msgs 0 --no-reply-on-recv \
  --ramp-sec "$RAMP_SEC" --connect-retries 15 --retry-delay-ms 1000 \
  | tee benchmark/run500k_client.log
