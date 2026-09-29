#!/usr/bin/env zsh
set -euo pipefail

PORT="${1:-3407}"
DB="/tmp/ra_todo01_${PORT}.db"
LOG="/tmp/ra_todo01_server_${PORT}.log"
POST_R="/tmp/ra_todo01_post_${PORT}.txt"
GET_R="/tmp/ra_todo01_get_${PORT}.txt"
PROBE="/tmp/ra_todo01_probe_${PORT}.txt"
POST_BODY="/tmp/ra_todo01_body_${PORT}.txt"
APP="/Users/dinesh.chander/projects/nim/nim_uwebsocket/nim_express/bin/todo_sqlite_mvc_app"

rm -f "$DB" "$DB-shm" "$DB-wal" "$LOG" "$POST_R" "$GET_R" "$PROBE" "$POST_BODY"
printf "title=loadtest" > "$POST_BODY"

TODO_DB_PATH="$DB" PORT="$PORT" TODO_LOG=0 "$APP" >"$LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..100}; do
  if ab -n 1 -c 1 "http://127.0.0.1:${PORT}/todos/fragment" >"$PROBE" 2>&1; then
    break
  fi
  sleep 0.1
done

ab -k -n 200 -c 20 -p "$POST_BODY" -T application/x-www-form-urlencoded \
  "http://127.0.0.1:${PORT}/todos" >/dev/null 2>&1 || true

ab -k -n 12000 -c 120 "http://127.0.0.1:${PORT}/todos/fragment" >"$GET_R" 2>&1 &
GET_PID=$!
ab -k -n 24000 -c 140 -p "$POST_BODY" -T application/x-www-form-urlencoded \
  "http://127.0.0.1:${PORT}/todos" >"$POST_R" 2>&1 || true
wait "$GET_PID" || true

echo "===GET==="
rg -n "Complete requests|Failed requests|Non-2xx responses|Write errors|Length:|Exceptions|apr_socket_recv|Connection reset|Broken pipe|Requests per second|Time per request" "$GET_R" || true
echo "===POST==="
rg -n "Complete requests|Failed requests|Non-2xx responses|Write errors|Length:|Exceptions|apr_socket_recv|Connection reset|Broken pipe|Requests per second|Time per request" "$POST_R" || true
echo "===SERVER==="
rg -n "error|Error|exception|Exception|SIG|trace|failed" "$LOG" | sed -n "1,120p" || true
echo "ARTIFACTS $LOG $GET_R $POST_R $DB"
