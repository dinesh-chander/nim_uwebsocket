#!/bin/bash
set -e

PORT="${1:-3100}"
CONNS_PER_PROC=25000
RATE=3000
HOLD_SEC=60
SERVER_BIN="./benchmark/ws_broadcast_server"

echo "=== 100k WebSocket Connection Test ==="
echo "Port: $PORT, 4x${CONNS_PER_PROC} connections = 100,000 total"
case "$(uname -s)" in
  Linux)
    PORT_RANGE="$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | awk '{print $1 "-" $2}')"
    ;;
  Darwin)
    PORT_RANGE="$(sysctl -n net.inet.ip.portrange.first 2>/dev/null)-65535"
    ;;
  *)
    PORT_RANGE="unknown"
    ;;
esac
echo "Port range: $PORT_RANGE"
echo "ulimit -n: $(ulimit -n)"
echo ""

pkill -f ws_broadcast 2>/dev/null || true
pkill -f ws_100k_client 2>/dev/null || true
sleep 2

PORT="$PORT" "$SERVER_BIN" &
SERVER_PID=$!
sleep 2

if ! curl -s http://127.0.0.1:$PORT/stats > /dev/null 2>&1; then
  echo "FATAL: Server failed to start"
  exit 1
fi
echo "Server started (PID=$SERVER_PID)"
echo ""

PIDS=()
SRCS=("127.0.0.1" "127.0.0.2" "127.0.0.3" "127.0.0.4")
DSTS=("127.0.0.1" "127.0.0.2" "127.0.0.3" "127.0.0.4")

for i in 0 1 2 3; do
  SRC=${SRCS[$i]}
  DST=${DSTS[$i]}
  echo "Launching client $((i+1)): src=$SRC -> dst=$DST, ${CONNS_PER_PROC} conns"
  node benchmark/ws_100k_client.js "$DST" "$PORT" "$CONNS_PER_PROC" "$RATE" "$SRC" > "/tmp/ws_100k_${i}.log" 2>&1 &
  PIDS+=($!)

  WAIT_SECS=$((CONNS_PER_PROC / RATE + 5))
  echo "  Waiting ${WAIT_SECS}s for ramp-up..."
  sleep $WAIT_SECS

  STATS=$(curl -s "http://127.0.0.1:$PORT/stats" 2>/dev/null || echo "stats unavailable")
  echo "  Server: $STATS"
  tail -1 "/tmp/ws_100k_${i}.log" 2>/dev/null || true
  echo ""
done

echo "=== All clients launched, holding for ${HOLD_SEC}s ==="
echo ""

for sec in 10 20 30 40 50 60; do
  sleep 10
  STATS=$(curl -s --connect-timeout 3 "http://127.0.0.1:$PORT/stats" 2>/dev/null || echo "stats unavailable")
  echo "t=${sec}s Server: $STATS"

  TOTAL_CLIENT_CONN=0
  TOTAL_CLIENT_ERR=0
  TOTAL_CLIENT_MSG=0
  for i in 0 1 2 3; do
    LINE=$(tail -1 "/tmp/ws_100k_${i}.log" 2>/dev/null)
    C=$(echo "$LINE" | grep -oP 'connected=\K[-0-9]+' 2>/dev/null || echo "0")
    E=$(echo "$LINE" | grep -oP 'errors=\K[0-9]+' 2>/dev/null || echo "0")
    M=$(echo "$LINE" | grep -oP 'msgs=\K[0-9]+' 2>/dev/null || echo "0")
    TOTAL_CLIENT_CONN=$((TOTAL_CLIENT_CONN + C))
    TOTAL_CLIENT_ERR=$((TOTAL_CLIENT_ERR + E))
    TOTAL_CLIENT_MSG=$((TOTAL_CLIENT_MSG + M))
  done
  echo "  Clients: connected=$TOTAL_CLIENT_CONN errors=$TOTAL_CLIENT_ERR msgs=$TOTAL_CLIENT_MSG"
  echo ""

  if [ $sec -ge $HOLD_SEC ]; then break; fi
done

echo "=== Capturing memory/CPU ==="
ps -o pid,rss,%cpu,%mem -p $SERVER_PID 2>/dev/null || true
echo ""

echo "=== Final Results ==="
STATS=$(curl -s --connect-timeout 3 "http://127.0.0.1:$PORT/stats" 2>/dev/null || echo "stats unavailable")
echo "Server: $STATS"
echo ""

echo "=== Per-client final stats ==="
for i in 0 1 2 3; do
  echo "Client $((i+1)) (${SRCS[$i]} -> ${DSTS[$i]}):"
  tail -1 "/tmp/ws_100k_${i}.log" 2>/dev/null || echo "  no output"
done

echo ""
echo "=== Cleaning up ==="
for pid in "${PIDS[@]}"; do
  kill $pid 2>/dev/null || true
done
kill $SERVER_PID 2>/dev/null || true
echo "Done."
