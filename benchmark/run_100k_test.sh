#!/bin/bash
set -e

PORT=${1:-3200}
TOTAL=${2:-100000}
PER_PROC=$((TOTAL / 4))
RATE=2000
HOLD_SECS=${3:-60}

DIR="$(dirname "$0")"
CLIENT="$DIR/ws_100k_client.js"

echo "=== 100k WebSocket connection test ==="
echo "Port: $PORT  Total: $TOTAL  Per-process: $PER_PROC  Hold: ${HOLD_SECS}s"

PIDS=()

echo "Launching client 1: src=127.0.0.1 → dst=127.0.0.3:$PORT"
node "$CLIENT" 127.0.0.3 "$PORT" "$PER_PROC" "$RATE" 127.0.0.1 &
PIDS+=($!)

echo "Launching client 2: src=127.0.0.2 → dst=127.0.0.4:$PORT"
node "$CLIENT" 127.0.0.4 "$PORT" "$PER_PROC" "$RATE" 127.0.0.2 &
PIDS+=($!)

echo "Launching client 3: src=127.0.0.3 → dst=127.0.0.5:$PORT"
node "$CLIENT" 127.0.0.5 "$PORT" "$PER_PROC" "$RATE" 127.0.0.3 &
PIDS+=($!)

echo "Launching client 4: src=127.0.0.4 → dst=127.0.0.1:$PORT"
node "$CLIENT" 127.0.0.1 "$PORT" "$PER_PROC" "$RATE" 127.0.0.4 &
PIDS+=($!)

echo "Waiting for connections to ramp..."
sleep $((PER_PROC / RATE + 10))

echo "=== Checking server stats ==="
curl -s "http://127.0.0.1:$PORT/stats" && echo ""

echo "Holding for ${HOLD_SECS}s..."
sleep "$HOLD_SECS"

echo "=== Final server stats ==="
curl -s "http://127.0.0.1:$PORT/stats" && echo ""

echo "Killing clients..."
for p in "${PIDS[@]}"; do
  kill "$p" 2>/dev/null || true
done
wait 2>/dev/null

echo "Done."
