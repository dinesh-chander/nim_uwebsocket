#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-/Users/dinesh.chander/projects/nim/nim_uwebsocket/nim_express/bin/todo_sqlite_mvc_app}"
PORT="${PORT:-3100}"
DB="${DB:-/tmp/todo_ra_todo01.db}"
LOG="${LOG:-/tmp/todo_ra_todo01.log}"
CODES="${CODES:-/tmp/todo_ra_todo01.codes}"
SEED_COUNT="${SEED_COUNT:-400}"
MUTATE_COUNT="${MUTATE_COUNT:-1800}"
MUTATE_PAR="${MUTATE_PAR:-12}"
FRAG_COUNT="${FRAG_COUNT:-2000}"

if [[ $# -ge 1 ]]; then
  MUTATE_COUNT="$1"
fi
if [[ $# -ge 2 ]]; then
  FRAG_COUNT="$2"
fi
if [[ $# -ge 3 ]]; then
  SEED_COUNT="$3"
fi

rm -f "$DB" "$LOG" "$CODES"
TODO_DB_PATH="$DB" PORT="$PORT" "$APP" >"$LOG" 2>&1 &
PID=$!
cleanup() {
  if kill "$PID" >/dev/null 2>&1; then
    wait "$PID" >/dev/null 2>&1 || true
  else
    if wait "$PID"; then
      echo "server_exit=0"
    else
      echo "server_exit=$?"
    fi
  fi
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

seq 1 "$SEED_COUNT" | xargs -P8 -I{} sh -c \
  'curl -fsS -o /dev/null -X POST -H "content-type: application/json" --data "{\"title\":\"seed-{}\"}" "http://127.0.0.1:'"$PORT"'/todos"'

MPID=
if [[ "$MUTATE_COUNT" -gt 0 ]]; then
  (
    seq 1 "$MUTATE_COUNT" | xargs -P"$MUTATE_PAR" -I{} sh -c \
      'curl -fsS -o /dev/null -X POST -H "content-type: application/json" --data "{\"title\":\"mut-{}\"}" "http://127.0.0.1:'"$PORT"'/todos" || exit 11'
  ) &
  MPID=$!
fi

ok=0
bad=0
for _ in $(seq 1 "$FRAG_COUNT"); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/todos/fragment" || echo ERR)
  echo "$code" >>"$CODES"
  if [[ "$code" == "200" || "$code" == "206" ]]; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1))
  fi
done
if [[ -n "${MPID:-}" ]]; then
  wait "$MPID" || true
fi

echo "ok=$ok bad=$bad"
echo "--- status histogram ---"
sort "$CODES" | uniq -c | sort -nr
if [[ "$bad" -gt 0 ]]; then
  echo "--- recent server log ---"
  tail -n 80 "$LOG"
fi
