#!/bin/bash
set -e

PROFILE="${1:-balanced}"
SERVER_BIN="$(dirname "$0")/ws_echo_server"
PORT=3100
DURATION=20
CONNECTIONS=200
RATE=5000
LOGFILE="/tmp/ws_prof_${PROFILE}.log"

pkill -f ws_echo_server 2>/dev/null || true
sleep 2

echo "=== Profile: $PROFILE ==="

NIM_EXPRESS_PROFILE=$PROFILE $SERVER_BIN &
SERVER_PID=$!
sleep 3

if ! kill -0 $SERVER_PID 2>/dev/null; then
  echo "ERROR: Server failed to start"
  exit 1
fi
echo "Server PID: $SERVER_PID"

rm -f "$LOGFILE"

(
  while kill -0 $SERVER_PID 2>/dev/null; do
    ps -o %cpu=,rss= -p $SERVER_PID 2>/dev/null >> "$LOGFILE"
    sleep 1
  done
) &
MON_PID=$!

sleep 2

tcpkali --ws -c $CONNECTIONS --connect-rate 5000 -T ${DURATION}s -e -r $RATE \
  -m 'XLATX hello world padding 1234567890abcdef' \
  --latency-marker "XLATX" --latency-percentiles 50,90,95,99,99.5 \
  127.0.0.1:$PORT 2>&1

sleep 2

CPU_AVG=$(awk 'NF>=2{sum+=$1; n++} END {if(n>0) printf "%.1f", sum/n; else print "N/A"}' "$LOGFILE")
CPU_MAX=$(awk 'NF>=2{if($1+0>max+0) max=$1} END {printf "%.1f", max+0}' "$LOGFILE")
MEM_MAX=$(awk 'NF>=2{if($2+0>max+0) max=$2} END {printf "%d", max+0}' "$LOGFILE")
SAMPLES=$(wc -l < "$LOGFILE" | tr -d ' ')

echo ""
echo "[$PROFILE] CPU avg: ${CPU_AVG}%, max: ${CPU_MAX}%, Peak mem: ${MEM_MAX} KB, Samples: $SAMPLES"

kill $MON_PID 2>/dev/null || true
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
wait $MON_PID 2>/dev/null || true
sleep 1
