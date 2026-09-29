#!/usr/bin/env bash
## 400k idle WebSocket connections = two ``websocketload`` × 200k (single-process hottest-thread limit blocks one ×400k).
## Second loader starts after ``LOADER_GAP_SEC`` (default 60) while the first is still soaking so both can hold ~200k
## at once for most of the run (raise ``DURATION``, tune gap). Two loaders spawned together often overload the accept path.
##
## From repo root:
##   bash nim_websocketcli/scripts/run_400k_ws_load.sh
##   LOADER_GAP_SEC=120 DURATION=120 bash nim_websocketcli/scripts/run_400k_ws_load.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ulimit -n 1048576 2>/dev/null || true
bash nim_websocketcli/scripts/ws_preflight_500k.sh

BIN="${WEBSOCKETLOAD:-$ROOT/nim_websocketcli/websocketload}"
[[ -x "$BIN" ]] || { echo "Build websocketload first (make websocketload)"; exit 1; }

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3400}"
PATH_WS="${PATH_WS:-/}"
BINDLB="${BINDLB:-253}"
DURATION="${DURATION:-300}"
LOADER_GAP_SEC="${LOADER_GAP_SEC:-60}"

SRV_THREADS="${SRV_THREADS:-24}"

WSLOAD_EXTRA=(--open-msgs 0 --no-reply-on-recv -t 24)
[[ -n "${WSLOAD_RAMP_SEC:-}" ]] || WSLOAD_RAMP_SEC=20
[[ -n "${WSLOAD_CONNECT_RETRIES:-}" ]] || WSLOAD_CONNECT_RETRIES=15
[[ -n "${WSLOAD_RETRY_DELAY_MS:-}" ]] || WSLOAD_RETRY_DELAY_MS=1000
WSLOAD_EXTRA+=(--ramp-sec "$WSLOAD_RAMP_SEC" --connect-retries "$WSLOAD_CONNECT_RETRIES" --retry-delay-ms "$WSLOAD_RETRY_DELAY_MS")

pkill -f '/benchmark/ws_echo_bench' 2>/dev/null || true
sleep 1

THREADS="$SRV_THREADS" PORT="$PORT" ./benchmark/ws_echo_bench > benchmark/run400k_srv.log 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 120); do
  curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && break
  sleep 0.25
done
curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null

LOG1=/tmp/ws_parallel_1.log
LOG2=/tmp/ws_parallel_2.log

echo "[400k] loader A 200000 → $LOG1"
"$BIN" -h "$HOST" -p "$PORT" --path "$PATH_WS" -c 200000 -d "$DURATION" \
  --bind-loopbacks "$BINDLB" "${WSLOAD_EXTRA[@]}" >"$LOG1" 2>&1 &
P1=$!

echo "[400k] sleep ${LOADER_GAP_SEC}s before loader B"
sleep "$LOADER_GAP_SEC"

echo "[400k] loader B 200000 → $LOG2"
"$BIN" -h "$HOST" -p "$PORT" --path "$PATH_WS" -c 200000 -d "$DURATION" \
  --bind-loopbacks "$BINDLB" "${WSLOAD_EXTRA[@]}" >"$LOG2" 2>&1 &
P2=$!

failed=0
wait "$P1" || failed=1
wait "$P2" || failed=1

{
  echo "--- worker A ---"; tail -14 "$LOG1"
  echo ""; echo "--- worker B ---"; tail -14 "$LOG2"
} | tee benchmark/run400k_master.log

exit "$failed"
