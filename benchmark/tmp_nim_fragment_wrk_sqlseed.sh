#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-/Users/dinesh.chander/projects/nim/nim_uwebsocket/nim_express/bin/todo_sqlite_mvc_app}"
PORT="${PORT:-3416}"
DB="${DB:-/tmp/nim_todo_fragment_wrk_${PORT}.db}"
LOG="${LOG:-/tmp/nim_todo_fragment_wrk_${PORT}.log}"
SEED="${SEED:-1000}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-200}"
DURATION="${DURATION:-30s}"
URL="${URL:-http://127.0.0.1:${PORT}/todos/fragment?mode=full}"

if [[ ! -x "$APP" ]]; then
  echo "nim app not found/executable: $APP" >&2
  exit 1
fi

rm -f "$DB" "$DB-shm" "$DB-wal" "$LOG"

sqlite3 "$DB" <<SQL
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA temp_store=MEMORY;
PRAGMA cache_size=-64000;
PRAGMA mmap_size=268435456;
PRAGMA journal_size_limit=67108864;
PRAGMA wal_autocheckpoint=1000;
PRAGMA busy_timeout=2000;
CREATE TABLE IF NOT EXISTS todos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  completed INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_todos_completed ON todos(completed);
DELETE FROM todos;
WITH RECURSIVE cnt(x) AS (
  VALUES(1)
  UNION ALL
  SELECT x + 1 FROM cnt WHERE x < ${SEED}
)
INSERT INTO todos(title, completed, created_at)
SELECT 'seed-' || x, 0, datetime('now') FROM cnt;
SQL

TODO_DB_PATH="$DB" PORT="$PORT" TODO_LOG=0 "$APP" >"$LOG" 2>&1 &
PID=$!
cleanup() {
  kill "$PID" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    if ! kill -0 "$PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  kill -9 "$PID" >/dev/null 2>&1 || true
  wait "$PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${PORT}/todos/fragment?mode=full" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

echo "[nim-frag] url=$URL seed=$SEED t=$THREADS c=$CONNS d=$DURATION"
wrk -t"$THREADS" -c"$CONNS" -d"$DURATION" --latency "$URL"
