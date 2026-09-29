#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-/Users/dinesh.chander/projects/nim/nim_uwebsocket/nim_express/bin/todo_sqlite_mvc_app}"
PORT="${PORT:-3416}"
DB="${DB:-/tmp/todo_fragment_wrk_${PORT}.db}"
LOG="${LOG:-/tmp/todo_fragment_wrk_${PORT}.log}"
SEED="${SEED:-1000}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-200}"
DURATION="${DURATION:-30s}"
URL="${URL:-http://127.0.0.1:${PORT}/todos/fragment}"

rm -f "$DB" "$DB-shm" "$DB-wal" "$LOG"
TODO_DB_PATH="$DB" PORT="$PORT" TODO_LOG=0 "$APP" >"$LOG" 2>&1 &
PID=$!
cleanup() {
  kill "$PID" >/dev/null 2>&1 || true
  wait "$PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 80); do
  if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

seq 1 "$SEED" | xargs -P8 -I{} sh -c \
  'curl -fsS -o /dev/null -X POST -H "content-type: application/json" --data "{\"title\":\"seed-{}\"}" "http://127.0.0.1:'"$PORT"'/todos"'

echo "[todo-frag] url=$URL seed=$SEED t=$THREADS c=$CONNS d=$DURATION"
wrk -t"$THREADS" -c"$CONNS" -d"$DURATION" --latency "$URL"
