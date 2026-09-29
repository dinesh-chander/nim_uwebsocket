#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/reports/todo_vs_dotnet_${STAMP}"
mkdir -p "${OUT_DIR}"

NIM_APP="${ROOT_DIR}/nim_express/bin/todo_sqlite_mvc_app"
DOTNET_APP="${ROOT_DIR}/benchmark/dotnet_todo/dotnet_todo/out-bench/dotnet_todo"

THREADS="${1:-8}"
CONNS="${2:-200}"
DURATION="${3:-20s}"
SEED="${4:-1000}"
ITERATIONS="${5:-5}"
WARMUP="${6:-5s}"

NIM_PORT=3460
DOTNET_PORT=3470
NIM_DB="/tmp/nim_todo_vs_dotnet_${STAMP}.db"
DOTNET_DB="/tmp/dotnet_todo_vs_dotnet_${STAMP}.db"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd wrk
need_cmd curl
need_cmd sqlite3

if [[ ! -x "${NIM_APP}" ]]; then
  echo "nim app not found: ${NIM_APP}" >&2
  exit 1
fi
if [[ ! -x "${DOTNET_APP}" ]]; then
  echo "dotnet app not found: ${DOTNET_APP}" >&2
  exit 1
fi

wait_ready() {
  local port="$1"
  local path="${2:-/}"
  for _ in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

seed_db_sqlite() {
  local db="$1"
  sqlite3 "$db" <<SQL
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS todos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  completed INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
DELETE FROM todos;
WITH RECURSIVE cnt(x) AS (
  VALUES(1)
  UNION ALL
  SELECT x + 1 FROM cnt WHERE x < ${SEED}
)
INSERT INTO todos(title, completed, created_at)
SELECT 'seed-' || x, 0, datetime('now') FROM cnt;
SQL
}

run_wrk() {
  local url="$1"
  local out="$2"
  wrk -t"${THREADS}" -c"${CONNS}" -d"${WARMUP}" "${url}" >"${out}.warmup.txt" 2>&1 || true
  wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${url}" >"${out}.txt" 2>&1 || true
}

parse_rps() {
  awk '/Requests\/sec:/ {print $2}' "$1" | tail -1
}

parse_pct() {
  local pct="$1"
  awk -v p="${pct}%" '$1 == p {print $2}' "$2" | tail -1
}

parse_avg_latency() {
  awk '/Latency[[:space:]]+/ {print $2}' "$1" | head -1
}

sum_file() {
  awk '{s += $1} END {printf "%.2f", s}' "$1"
}

avg_file() {
  awk '{s += $1; n += 1} END {if (n == 0) print "0.00"; else printf "%.2f", s/n}' "$1"
}

NIM_RPS_LIST="${OUT_DIR}/nim_rps.txt"
DOTNET_RPS_LIST="${OUT_DIR}/dotnet_rps.txt"
NIM_P99_LIST="${OUT_DIR}/nim_p99.txt"
DOTNET_P99_LIST="${OUT_DIR}/dotnet_p99.txt"
rm -f "$NIM_RPS_LIST" "$DOTNET_RPS_LIST" "$NIM_P99_LIST" "$DOTNET_P99_LIST"

cleanup_server() {
  local pid="${1:-}"
  if [[ -n "$pid" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        wait "$pid" >/dev/null 2>&1 || true
        return
      fi
      sleep 0.1
    done
    kill -9 "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

for iter in $(seq 1 "$ITERATIONS"); do
  echo "[todo-vs-dotnet] iteration=${iter}/${ITERATIONS}"

  rm -f "$NIM_DB" "$NIM_DB-shm" "$NIM_DB-wal"
  seed_db_sqlite "$NIM_DB"
  TODO_DB_PATH="$NIM_DB" PORT="$NIM_PORT" TODO_LOG=0 NIM_EXPRESS_PROFILE="${NIM_EXPRESS_PROFILE:-linux-throughput}" "$NIM_APP" >"${OUT_DIR}/nim_server_${iter}.log" 2>&1 &
  NIM_PID=$!
  if ! wait_ready "$NIM_PORT" "/todos/fragment?mode=full"; then
    cleanup_server "$NIM_PID"
    echo "nim app failed to start on port ${NIM_PORT}" >&2
    exit 1
  fi
  run_wrk "http://127.0.0.1:${NIM_PORT}/todos/fragment?mode=full" "${OUT_DIR}/nim_${iter}"
  NIM_RPS="$(parse_rps "${OUT_DIR}/nim_${iter}.txt")"
  NIM_P99="$(parse_pct 99 "${OUT_DIR}/nim_${iter}.txt")"
  [[ -z "$NIM_RPS" ]] && NIM_RPS="0"
  [[ -z "$NIM_P99" ]] && NIM_P99="n/a"
  echo "$NIM_RPS" >>"$NIM_RPS_LIST"
  echo "$NIM_P99" >>"$NIM_P99_LIST"
  cleanup_server "$NIM_PID"

  rm -f "$DOTNET_DB" "$DOTNET_DB-shm" "$DOTNET_DB-wal"
  seed_db_sqlite "$DOTNET_DB"
  DOTNET_TODO_DB="$DOTNET_DB" PORT="$DOTNET_PORT" TODO_LOG=0 "$DOTNET_APP" >"${OUT_DIR}/dotnet_server_${iter}.log" 2>&1 &
  DOTNET_PID=$!
  if ! wait_ready "$DOTNET_PORT" "/todos/fragment?mode=full"; then
    cleanup_server "$DOTNET_PID"
    echo "dotnet app failed to start on port ${DOTNET_PORT}" >&2
    exit 1
  fi
  run_wrk "http://127.0.0.1:${DOTNET_PORT}/todos/fragment?mode=full" "${OUT_DIR}/dotnet_${iter}"
  DOTNET_RPS="$(parse_rps "${OUT_DIR}/dotnet_${iter}.txt")"
  DOTNET_P99="$(parse_pct 99 "${OUT_DIR}/dotnet_${iter}.txt")"
  [[ -z "$DOTNET_RPS" ]] && DOTNET_RPS="0"
  [[ -z "$DOTNET_P99" ]] && DOTNET_P99="n/a"
  echo "$DOTNET_RPS" >>"$DOTNET_RPS_LIST"
  echo "$DOTNET_P99" >>"$DOTNET_P99_LIST"
  cleanup_server "$DOTNET_PID"
done

NIM_SUM="$(sum_file "$NIM_RPS_LIST")"
DOTNET_SUM="$(sum_file "$DOTNET_RPS_LIST")"
NIM_AVG="$(avg_file "$NIM_RPS_LIST")"
DOTNET_AVG="$(avg_file "$DOTNET_RPS_LIST")"
SPEEDUP="$(awk -v n="$NIM_AVG" -v d="$DOTNET_AVG" 'BEGIN {if (d == 0) print "0.00"; else printf "%.2f", n / d}')"

cat >"${OUT_DIR}/summary.md" <<EOF2
# Todo Fragment Full-Mode Benchmark: Nim vs Dotnet

- timestamp: ${STAMP}
- threads: ${THREADS}
- connections: ${CONNS}
- duration: ${DURATION}
- warmup: ${WARMUP}
- seed: ${SEED}
- iterations: ${ITERATIONS}
- endpoint: /todos/fragment?mode=full

## Results

- Nim avg rps: ${NIM_AVG} (sum ${NIM_SUM})
- Dotnet avg rps: ${DOTNET_AVG} (sum ${DOTNET_SUM})
- Nim vs Dotnet speedup: ${SPEEDUP}x

## Per-run RPS

Nim:
$(nl -ba "${NIM_RPS_LIST}")

Dotnet:
$(nl -ba "${DOTNET_RPS_LIST}")

## Per-run p99

Nim:
$(nl -ba "${NIM_P99_LIST}")

Dotnet:
$(nl -ba "${DOTNET_P99_LIST}")
EOF2

LATEST_LINK="${ROOT_DIR}/benchmark/reports/latest_todo_vs_dotnet"
rm -f "${LATEST_LINK}"
ln -s "${OUT_DIR}" "${LATEST_LINK}"

echo "[todo-vs-dotnet] out_dir=${OUT_DIR}"
echo "[todo-vs-dotnet] nim_avg_rps=${NIM_AVG}"
echo "[todo-vs-dotnet] dotnet_avg_rps=${DOTNET_AVG}"
echo "[todo-vs-dotnet] speedup=${SPEEDUP}x"
