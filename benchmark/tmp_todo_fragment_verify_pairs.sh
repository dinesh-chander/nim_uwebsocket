#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-/Users/dinesh.chander/projects/nim/nim_uwebsocket/nim_express/bin/todo_sqlite_mvc_app}"
PORT="${PORT:-3440}"
DB="${DB:-/tmp/todo_fragment_verify_${PORT}.db}"
LOG="${LOG:-/tmp/todo_fragment_verify_${PORT}.log}"
SEED="${SEED:-200}"
BODY="${BODY:-/tmp/todo_fragment_verify_${PORT}.html}"
if [[ $# -ge 1 ]]; then
  SEED="$1"
fi

rm -f "$DB" "$DB-shm" "$DB-wal" "$LOG" "$BODY"
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

curl -fsS "http://127.0.0.1:${PORT}/todos/fragment" -o "$BODY"

perl -ne '
  while (/todo-(\d+).*?seed-(\d+)/g) {
    $pairs++;
    if ($1 != $2) {
      $bad++;
      print "mismatch: todo-$1 vs seed-$2\n";
      if ($bad >= 20) { exit 2; }
    }
  }
  END {
    $bad = 0 unless defined $bad;
    print "pairs=$pairs bad=$bad\n";
    exit($bad > 0 ? 1 : 0);
  }
' "$BODY"
