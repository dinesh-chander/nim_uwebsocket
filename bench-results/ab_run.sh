#!/usr/bin/env bash
# A/B benchmark protocol: alternating runs, best-of-N.
# Usage: ab_run.sh <server-bin> <label> [extra-server-args...]
# Serves on port 3002, runs wrk for /json /plaintext /static, kills server.
set -u
BIN="$1"; LABEL="$2"; shift 2
OUT=bench-results/${LABEL}.txt
PORT=3002
THREADS=8; CONN=256; DUR=5s; PASS=3

start() { "$BIN" "$@" > /tmp/ab_server.log 2>&1 & echo $! > /tmp/ab_server.pid; }
stop()  { kill -INT $(cat /tmp/ab_server.pid) 2>/dev/null; sleep 1; kill -9 $(cat /tmp/ab_server.pid) 2>/dev/null; }
waitup() { for i in $(seq 1 50); do curl -s -o /dev/null http://localhost:$PORT/plaintext && return 0; sleep 0.2; done; echo "SERVER DID NOT START"; cat /tmp/ab_server.log; exit 1; }

one() { # one <path> -> prints "req/s p99ms"
  local r
  r=$(wrk -t$THREADS -c$CONN -d$DUR --latency http://localhost:$PORT$1 2>/dev/null)
  local tps p99
  tps=$(echo "$r" | awk '/Requests\/sec/ {print $2}')
  p99=$(echo "$r" | awk '/99%/ {print $2}')
  echo "$tps $p99"
}

start "$@"
waitup
{
  echo "label=$LABEL bin=$BIN args=$* date=$(date -Is)"
  for ep in /json /plaintext /static; do
    best=""; bestp=""
    for p in $(seq 1 $PASS); do
      read tps p99 < <(one "$ep")
      # track best tps; keep matching p99
      if [ -z "$best" ] || python3 -c "exit(0 if $tps > $best else 1)"; then best=$tps; bestp=$p99; fi
      echo "  pass$p $ep tps=$tps p99=$p99"
    done
    echo "BEST $ep tps=$best p99=$bestp"
  done
} | tee "$OUT"
stop
echo "done: $OUT"
