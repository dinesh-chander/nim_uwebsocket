#!/usr/bin/env bash
## 200k idle WebSocket connections: multithread echo + single websocketload process.
## Requires: ws_preflight_500k tuning (loopback aliases, ulimit, port range).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ulimit -n 1048576 2>/dev/null || true
bash nim_websocketcli/scripts/ws_preflight_500k.sh

PORT="${PORT:-3400}"
SRV_THREADS="${SRV_THREADS:-16}"
CLIENT_THREADS="${CLIENT_THREADS:-24}"
DURATION="${DURATION:-120}"

pkill -f '/benchmark/ws_echo_bench' 2>/dev/null || true
sleep 1

THREADS="$SRV_THREADS" PORT="$PORT" ./benchmark/ws_echo_bench > benchmark/run200k_srv.log 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 120); do
  curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && break
  sleep 0.25
done
curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null

/usr/bin/time -f $'\nwebsocketload_wall_sec=%e\n' timeout 7200 ./nim_websocketcli/websocketload \
  -h 127.0.0.1 -p "$PORT" --path / -c 200000 -t "$CLIENT_THREADS" -d "$DURATION" \
  --open-msgs 0 --no-reply-on-recv --bind-loopbacks 253 \
  --ramp-sec 20 --connect-retries 15 --retry-delay-ms 1000 \
  | tee benchmark/run200k_client.log
