#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-/Users/dinesh.chander/projects/nim/nim_uwebsocket/nim_express/bin/todo_sqlite_mvc_app}"
PORT="${PORT:-3422}"
DB="${DB:-/tmp/todo_fragment_inspect_${PORT}.db}"
LOG="${LOG:-/tmp/todo_fragment_inspect_${PORT}.log}"
SEED="${SEED:-1000}"
URL="http://127.0.0.1:${PORT}/todos/fragment"
OUT_BODY="${OUT_BODY:-/tmp/todo_fragment_inspect_${PORT}.body.html}"
OUT_HDR="${OUT_HDR:-/tmp/todo_fragment_inspect_${PORT}.headers.txt}"

rm -f "$DB" "$DB-shm" "$DB-wal" "$LOG" "$OUT_BODY" "$OUT_HDR"
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

sqlite3 "$DB" "
WITH RECURSIVE cnt(x) AS (
  SELECT 1
  UNION ALL
  SELECT x + 1 FROM cnt WHERE x < $SEED
)
INSERT INTO todos(title, completed, created_at)
SELECT 'seed-' || x, 0, datetime('now') FROM cnt;
"

echo "[inspect] curl headers/body from ${URL}"
curl -sS --http1.1 -D "$OUT_HDR" "$URL" -o "$OUT_BODY"
sed -n '1,120p' "$OUT_HDR"
echo "[inspect] body bytes: $(wc -c < "$OUT_BODY")"
echo "[inspect] body preview:"
sed -n '1,20p' "$OUT_BODY"
echo "[inspect] wrk quick check"
wrk -t4 -c80 -d10s --latency "$URL"
