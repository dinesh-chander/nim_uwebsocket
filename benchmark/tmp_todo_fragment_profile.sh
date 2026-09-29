#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP:-${ROOT_DIR}/nim_express/bin/todo_sqlite_mvc_app}"
PORT="${PORT:-3432}"
DB="${DB:-/tmp/todo_fragment_profile_${PORT}.db}"
LOG="${LOG:-/tmp/todo_fragment_profile_${PORT}.log}"
SEED="${SEED:-1000}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-200}"
DURATION="${DURATION:-15s}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-8}"
STACKCOLLAPSE="${STACKCOLLAPSE:-/opt/homebrew/opt/flamegraph/bin/stackcollapse-sample.awk}"

OUT_DIR="${OUT_DIR:-${ROOT_DIR}/benchmark/profiles/todo_frag_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "${OUT_DIR}"
WRK_OUT="${OUT_DIR}/wrk.txt"
SAMPLE_OUT="${OUT_DIR}/sample.txt"
FOLDED_OUT="${OUT_DIR}/sample.folded"
TOP_FLAT_OUT="${OUT_DIR}/top_flat.txt"
URL="${URL:-http://127.0.0.1:${PORT}/todos/fragment}"

rm -f "$DB" "$DB-shm" "$DB-wal" "$LOG"
TODO_DB_PATH="$DB" PORT="$PORT" TODO_LOG=0 "$APP" >"$LOG" 2>&1 &
APP_PID=$!
cleanup() {
  kill "$APP_PID" >/dev/null 2>&1 || true
  wait "$APP_PID" >/dev/null 2>&1 || true
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

wrk -t"$THREADS" -c"$CONNS" -d"$DURATION" --latency "$URL" >"$WRK_OUT" 2>&1 &
WRK_PID=$!
sleep 1
if command -v sample >/dev/null 2>&1; then
  sample "$APP_PID" "$SAMPLE_SECONDS" 1 -mayDie -file "$SAMPLE_OUT" >/dev/null 2>&1 || true
fi
wait "$WRK_PID"

if [[ -s "$SAMPLE_OUT" && -x "$STACKCOLLAPSE" ]]; then
  awk -f "$STACKCOLLAPSE" "$SAMPLE_OUT" > "$FOLDED_OUT"
  awk '
    {
      cnt = $NF + 0
      $NF = ""
      sub(/[[:space:]]+$/, "", $0)
      n = split($0, parts, ";")
      leaf = parts[n]
      flat[leaf] += cnt
      total += cnt
    }
    END {
      if (total <= 0) exit 0
      for (k in flat) {
        printf "%.2f%%\t%s\n", (flat[k] * 100.0) / total, k
      }
    }
  ' "$FOLDED_OUT" | sort -nr | head -n 25 > "$TOP_FLAT_OUT"
fi

echo "[todo-profile] out_dir=${OUT_DIR}"
echo "[todo-profile] wrk_rps=$(awk '/Requests\/sec:/ {print $2}' "$WRK_OUT" | tail -1)"
if [[ -s "$TOP_FLAT_OUT" ]]; then
  echo "[todo-profile] top_flat:"
  sed -n '1,25p' "$TOP_FLAT_OUT"
fi
