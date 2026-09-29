#!/usr/bin/env zsh
set -euo pipefail

PORT="${1:-3408}"
POST_WORKERS="${2:-12}"
POST_ITERS="${3:-2200}"
GET_WORKERS="${4:-4}"
GET_ITERS="${5:-3200}"

DB="/tmp/ra_todo01_curl_${PORT}.db"
LOG="/tmp/ra_todo01_curl_server_${PORT}.log"
APP="/Users/dinesh.chander/projects/nim/nim_uwebsocket/nim_express/bin/todo_sqlite_mvc_app"

GET_ERR="/tmp/ra_todo01_curl_get_err_${PORT}.log"
GET_CODES="/tmp/ra_todo01_curl_get_codes_${PORT}.log"
GET_STATUS="/tmp/ra_todo01_curl_get_status_${PORT}.log"
POST_ERR="/tmp/ra_todo01_curl_post_err_${PORT}.log"
POST_CODES="/tmp/ra_todo01_curl_post_codes_${PORT}.log"
POST_STATUS="/tmp/ra_todo01_curl_post_status_${PORT}.log"

rm -f "$DB" "$DB-shm" "$DB-wal" "$LOG" "$GET_ERR" "$GET_CODES" "$GET_STATUS" "$POST_ERR" "$POST_CODES" "$POST_STATUS"

TODO_DB_PATH="$DB" PORT="$PORT" TODO_LOG=0 "$APP" >"$LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..120}; do
  if curl -sS --max-time 2 "http://127.0.0.1:${PORT}/todos/fragment" >/dev/null; then
    break
  fi
  sleep 0.1
done

run_post_worker() {
  local wid="$1"
  local i=1
  while [ "$i" -le "$POST_ITERS" ]; do
    local code
    code=$(curl -sS --max-time 4 -o /dev/null -w "%{http_code}" \
      -X POST -H "Content-Type: application/x-www-form-urlencoded" \
      --data "title=w${wid}_i${i}" \
      "http://127.0.0.1:${PORT}/todos" 2>>"$POST_ERR") || {
        echo "$?" >> "$POST_CODES"
        i=$((i + 1))
        continue
      }
    if [ "$code" != "200" ] && [ "$code" != "201" ]; then
      echo "$code" >> "$POST_STATUS"
    fi
    i=$((i + 1))
  done
}

run_get_worker() {
  local wid="$1"
  local i=1
  while [ "$i" -le "$GET_ITERS" ]; do
    local code
    code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "http://127.0.0.1:${PORT}/todos/fragment" 2>>"$GET_ERR") || {
        echo "$?" >> "$GET_CODES"
        i=$((i + 1))
        continue
      }
    if [ "$code" != "200" ]; then
      echo "$code" >> "$GET_STATUS"
    fi
    i=$((i + 1))
  done
}

typeset -a PIDS

for w in $(seq 1 "$GET_WORKERS"); do
  run_get_worker "$w" &
  PIDS+=("$!")
done

for w in $(seq 1 "$POST_WORKERS"); do
  run_post_worker "$w" &
  PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done

echo "===COUNTS==="
echo "post_workers=$POST_WORKERS post_iters=$POST_ITERS get_workers=$GET_WORKERS get_iters=$GET_ITERS"
echo "post_total=$((POST_WORKERS * POST_ITERS)) get_total=$((GET_WORKERS * GET_ITERS))"
echo "post_transport_errors=$(wc -l < \"$POST_CODES\" 2>/dev/null || echo 0)"
echo "post_non_2xx=$(wc -l < \"$POST_STATUS\" 2>/dev/null || echo 0)"
echo "get_transport_errors=$(wc -l < \"$GET_CODES\" 2>/dev/null || echo 0)"
echo "get_non_200=$(wc -l < \"$GET_STATUS\" 2>/dev/null || echo 0)"
echo "===GET ERR SAMPLE==="
sed -n '1,80p' "$GET_ERR" || true
echo "===POST ERR SAMPLE==="
sed -n '1,80p' "$POST_ERR" || true
echo "===SERVER ERR SAMPLE==="
rg -n "error|Error|exception|Exception|SIG|trace|failed" "$LOG" | sed -n '1,120p' || true
echo "ARTIFACTS $LOG $GET_ERR $POST_ERR $GET_CODES $POST_CODES $GET_STATUS $POST_STATUS $DB"
