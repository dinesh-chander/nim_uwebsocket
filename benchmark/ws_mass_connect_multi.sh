#!/bin/bash
URL="${1:-ws://127.0.0.1:3100}"
TOTAL="${2:-50000}"
PER_PROCESS="${3:-10000}"
HOLD="${4:-30}"
BATCH_SIZE="${5:-2000}"

NUM_PROCS=$(( (TOTAL + PER_PROCESS - 1) / PER_PROCESS ))

echo "Starting $NUM_PROCS Node processes, $PER_PROCESS connections each, $TOTAL total"
echo "Hold time: ${HOLD}s, batch size: $BATCH_SIZE"

PIDS=()
for i in $(seq 1 $NUM_PROCS); do
  CONNS=$PER_PROCESS
  if [ $i -eq $NUM_PROCS ]; then
    REMAINING=$(( TOTAL - (NUM_PROCS - 1) * PER_PROCESS ))
    if [ $REMAINING -gt 0 ]; then
      CONNS=$REMAINING
    fi
  fi
  echo "Starting process $i: $CONNS connections"
  node benchmark/ws_mass_connect.js "$URL" "$CONNS" "$BATCH_SIZE" 500 "$HOLD" > "/tmp/ws_mass_$i.log" 2>&1 &
  PIDS+=($!)
  sleep 2
done

echo "All processes started. Waiting for completion..."
for pid in "${PIDS[@]}"; do
  wait $pid
done

echo ""
echo "=== Results from each process ==="
TOTAL_CONNECTED=0
TOTAL_FAILED=0
TOTAL_MSGS=0
TOTAL_BYTES=0
for i in $(seq 1 $NUM_PROCS); do
  DONE_LINE=$(grep '"phase":"done"' "/tmp/ws_mass_$i.log" | tail -1)
  if [ -n "$DONE_LINE" ]; then
    echo "Process $i: $DONE_LINE"
    C=$(echo "$DONE_LINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('connected',0))" 2>/dev/null)
    F=$(echo "$DONE_LINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('failed',0))" 2>/dev/null)
    M=$(echo "$DONE_LINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('totalMessagesReceived',0))" 2>/dev/null)
    B=$(echo "$DONE_LINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('totalBytesReceived',0))" 2>/dev/null)
    TOTAL_CONNECTED=$((TOTAL_CONNECTED + C))
    TOTAL_FAILED=$((TOTAL_FAILED + F))
    TOTAL_MSGS=$((TOTAL_MSGS + M))
    TOTAL_BYTES=$((TOTAL_BYTES + B))
  else
    echo "Process $i: no done output"
    cat "/tmp/ws_mass_$i.log" | tail -3
  fi
done

echo ""
echo "=== Aggregate ==="
echo "Total connected at end: $TOTAL_CONNECTED"
echo "Total failed: $TOTAL_FAILED"
echo "Total messages received: $TOTAL_MSGS"
echo "Total bytes received: $TOTAL_BYTES"
echo "Avg msg/sec: $((TOTAL_MSGS / HOLD))"
