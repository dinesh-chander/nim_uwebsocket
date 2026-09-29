#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP:-${ROOT_DIR}/nim_express/bin/todo_sqlite_mvc_app}"
PORT="${PORT:-3432}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-200}"
DURATION="${DURATION:-10s}"
SEED="${SEED:-1000}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-3}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/benchmark/profiles/perf_full_$(date +%Y%m%d_%H%M%S)}"
URL="${URL:-http://127.0.0.1:${PORT}/todos/fragment?mode=full}"
DB="${DB:-/tmp/todo_full_${PORT}.db}"
STACKCOLLAPSE="${STACKCOLLAPSE:-/opt/homebrew/opt/flamegraph/bin/stackcollapse-sample.awk}"

mkdir -p "${OUT_DIR}"

APP_LOG="${OUT_DIR}/app.log"
WRK_OUT="${OUT_DIR}/wrk.txt"
SAMPLE_OUT="${OUT_DIR}/sample.txt"
FOLDED_OUT="${OUT_DIR}/sample.folded"
TOP_FLAT_OUT="${OUT_DIR}/top_flat.txt"

APP_PID=""

cleanup() {
  if [[ -n "${APP_PID}" ]]; then
    kill -9 "${APP_PID}" >/dev/null 2>&1 || true
    wait "${APP_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

rm -f "${DB}" "${DB}-shm" "${DB}-wal"
TODO_DB_PATH="${DB}" PORT="${PORT}" TODO_LOG=0 "${APP}" >"${APP_LOG}" 2>&1 &
APP_PID="$!"

for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

sqlite3 "${DB}" <<SQL
WITH RECURSIVE cnt(x) AS (
  SELECT 1
  UNION ALL
  SELECT x + 1 FROM cnt WHERE x < ${SEED}
)
INSERT INTO todos(title, completed, created_at)
SELECT 'seed-' || x, 0, datetime('now') FROM cnt;
SQL

if command -v sample >/dev/null 2>&1; then
  (
    sleep 1
    sample "${APP_PID}" "${SAMPLE_SECONDS}" 1 -mayDie -file "${SAMPLE_OUT}" >/dev/null 2>&1 || true
  ) &
fi

wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${URL}" >"${WRK_OUT}" 2>&1

if [[ -s "${SAMPLE_OUT}" && -x "${STACKCOLLAPSE}" ]]; then
  awk -f "${STACKCOLLAPSE}" "${SAMPLE_OUT}" > "${FOLDED_OUT}"
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
      for (k in flat) {
        pct = (total > 0 ? (100.0 * flat[k] / total) : 0)
        printf "%.2f%%\t%s\n", pct, k
      }
    }
  ' "${FOLDED_OUT}" | sort -nr | head -n 25 > "${TOP_FLAT_OUT}"
fi

echo "[perf-full] out_dir=${OUT_DIR}"
echo "[perf-full] wrk_rps=$(awk '/Requests\/sec:/ {print $2}' "${WRK_OUT}" | tail -1)"
if [[ -s "${TOP_FLAT_OUT}" ]]; then
  echo "[perf-full] top_flat:"
  sed -n '1,15p' "${TOP_FLAT_OUT}"
fi
