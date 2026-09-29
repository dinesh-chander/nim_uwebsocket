#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
source "${ROOT_DIR}/benchmark/build_helpers.sh"

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/reports/nim_express_endpoint_bench_${STAMP}"
mkdir -p "${OUT_DIR}"
bench_init_cold_build "${ROOT_DIR}" "${OUT_DIR}"

THREADS="${THREADS:-4}"
CONNS="${CONNS:-500}"
DURATION="${DURATION:-60s}"
WARMUP="${WARMUP:-5s}"
TODO_SEED="${TODO_SEED:-1000}"
TEMPLATE_RENDER_MODE="${TEMPLATE_RENDER_MODE:-pairs}"

BENCH_PORT="${BENCH_PORT:-3002}"
ROUTE_PORT="${ROUTE_PORT:-3003}"
TEMPLATE_PORT="${TEMPLATE_PORT:-3000}"
TODO_PORT="${TODO_PORT:-3010}"
TODO_DB="${TODO_DB:-/tmp/nim_uwebsocket_endpoint_bench_${STAMP}.db}"

BENCH_BIN="${BENCH_BIN:-${ROOT_DIR}/benchmark/bench_nim_express}"
ROUTE_BIN="${ROUTE_BIN:-${ROOT_DIR}/benchmark/bench_route_modes}"
BASIC_BIN="${BASIC_BIN:-${ROOT_DIR}/examples/bin/basic_app_fresh}"
TODO_BIN="${TODO_BIN:-${ROOT_DIR}/examples/bin/todo_sqlite_mvc_app_fresh}"

LATEST_LINK="${ROOT_DIR}/benchmark/reports/latest_nim_express_endpoint_bench"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

for cmd in wrk curl sqlite3 nim make awk sed grep ln pkill cc; do
  require_cmd "$cmd"
done

if ! printf '#include <sqlite3.h>\n' | cc -E -x c - >/dev/null 2>&1; then
  echo "missing sqlite3 development headers: install libsqlite3-dev (Linux) or sqlite development headers" >&2
  exit 1
fi

bench_rebuild_usockets "${OUT_DIR}/build_usockets.log"
USOCKETS_LINK_FLAGS="$(bench_platform_link_flags "${ROOT_DIR}/nim_usockets/usockets/uSockets.a")"
BENCH_COMMON_PATHS_SHELL="$(bench_common_paths_shell "${ROOT_DIR}")"
BENCH_PLATFORM_CFLAGS="$(bench_platform_cflags)"
BENCH_NATIVE_CFLAGS="$(bench_native_cflags)"
BENCH_PASS_CFLAGS="${BENCH_PLATFORM_CFLAGS} ${BENCH_NATIVE_CFLAGS}"
BENCH_BACKEND_NIM_FLAGS="$(bench_backend_nim_flags)"

rebuild_binary() {
  local bin="$1"
  local cmd="$2"
  echo "[build] ${bin}"
  eval "${cmd}"
}

rebuild_binary "${BENCH_BIN}" \
  "bench_make bench_nim_express bench BENCH_SRC=benchmark/bench_nim_express.nim BENCH_BIN=benchmark/bench_nim_express >'${OUT_DIR}/build_bench_nim_express.log' 2>&1"

rebuild_binary "${ROUTE_BIN}" \
  "bench_nim bench_route_modes c ${BENCH_BACKEND_NIM_FLAGS} -d:release -d:danger --opt:speed --mm:arc --hints:off ${BENCH_COMMON_PATHS_SHELL} --passC:'${BENCH_PASS_CFLAGS}' --passL:'${USOCKETS_LINK_FLAGS}' -o:benchmark/bench_route_modes benchmark/bench_route_modes.nim >'${OUT_DIR}/build_bench_route_modes.log' 2>&1"

rebuild_binary "${BASIC_BIN}" \
  "bench_nim basic_app_fresh c ${BENCH_BACKEND_NIM_FLAGS} --skipProjCfg:on --skipParentCfg:on -d:release -d:danger --opt:speed --mm:arc --hints:off ${BENCH_COMMON_PATHS_SHELL} --passC:'${BENCH_PASS_CFLAGS}' --passL:'${USOCKETS_LINK_FLAGS}' -o:examples/bin/basic_app_fresh examples/basic_app.nim >'${OUT_DIR}/build_basic_app.log' 2>&1"

rebuild_binary "${TODO_BIN}" \
  "bench_nim todo_sqlite_mvc_app_fresh c ${BENCH_BACKEND_NIM_FLAGS} --skipProjCfg:on --skipParentCfg:on -d:release -d:danger --opt:speed --mm:arc --hints:off ${BENCH_COMMON_PATHS_SHELL} --passC:'${BENCH_PASS_CFLAGS}' --passL:'${USOCKETS_LINK_FLAGS} -lsqlite3' -o:examples/bin/todo_sqlite_mvc_app_fresh examples/todo_sqlite_mvc_app.nim >'${OUT_DIR}/build_todo_app.log' 2>&1"

for bin in "${BENCH_BIN}" "${ROUTE_BIN}" "${BASIC_BIN}" "${TODO_BIN}"; do
  if [[ ! -x "${bin}" ]]; then
    echo "required binary missing or not executable: ${bin}" >&2
    exit 1
  fi
done

seed_todo_db() {
  rm -f "${TODO_DB}" "${TODO_DB}-shm" "${TODO_DB}-wal"
  sqlite3 "${TODO_DB}" >/dev/null <<SQL
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
  SELECT x + 1 FROM cnt WHERE x < ${TODO_SEED}
)
INSERT INTO todos(title, completed, created_at)
SELECT 'seed-' || x, 0, datetime('now') FROM cnt;
SQL
}

wait_ready() {
  local url="$1"
  for _ in $(seq 1 120); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

assert_wrk_clean() {
  local name="$1"
  local out="$2"
  if ! grep -q 'Requests/sec:' "${out}"; then
    echo "wrk output for ${name} is missing Requests/sec" >&2
    return 1
  fi
  if grep -Eq 'Non-2xx or 3xx responses:[[:space:]]*[1-9][0-9]*' "${out}"; then
    echo "wrk output for ${name} contains non-2xx/3xx responses" >&2
    return 1
  fi
  if awk '
    /Socket errors:/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "connect" || $i == "read" || $i == "write" || $i == "timeout") {
          v = $(i + 1); gsub(",", "", v)
          if ((v + 0) > 0) bad = 1
        }
      }
    }
    END { exit bad ? 1 : 0 }
  ' "${out}"; then
    return 0
  fi
  echo "wrk output for ${name} contains socket errors" >&2
  return 1
}

SERVER_PIDS=()

cleanup() {
  if ((${#SERVER_PIDS[@]} > 0)); then
    for pid in "${SERVER_PIDS[@]}"; do
      kill "${pid}" >/dev/null 2>&1 || true
    done
    for pid in "${SERVER_PIDS[@]}"; do
      wait "${pid}" >/dev/null 2>&1 || true
    done
  fi
  pkill -f '/benchmark/bench_nim_express' 2>/dev/null || true
  pkill -f '/benchmark/bench_route_modes' 2>/dev/null || true
  pkill -f '/examples/bin/basic_app_fresh' 2>/dev/null || true
  pkill -f '/examples/bin/todo_sqlite_mvc_app_fresh' 2>/dev/null || true
}
trap cleanup EXIT

pkill -f '/benchmark/bench_nim_express' 2>/dev/null || true
pkill -f '/benchmark/bench_route_modes' 2>/dev/null || true
pkill -f '/examples/bin/basic_app_fresh' 2>/dev/null || true
pkill -f '/examples/bin/todo_sqlite_mvc_app_fresh' 2>/dev/null || true

seed_todo_db

"${BENCH_BIN}" >"${OUT_DIR}/server_bench_nim_express.log" 2>&1 &
SERVER_PIDS+=("$!")
"${ROUTE_BIN}" >"${OUT_DIR}/server_route_modes.log" 2>&1 &
SERVER_PIDS+=("$!")
NIM_EXPRESS_TEMPLATE_RENDER_MODE="${TEMPLATE_RENDER_MODE}" \
  "${BASIC_BIN}" >"${OUT_DIR}/server_basic_app.log" 2>&1 &
SERVER_PIDS+=("$!")
TODO_DB_PATH="${TODO_DB}" PORT="${TODO_PORT}" TODO_LOG=0 "${TODO_BIN}" >"${OUT_DIR}/server_todo_app.log" 2>&1 &
SERVER_PIDS+=("$!")

wait_ready "http://127.0.0.1:${BENCH_PORT}/plaintext" || { echo "bench_nim_express failed to start" >&2; exit 1; }
wait_ready "http://127.0.0.1:${ROUTE_PORT}/get" || { echo "bench_route_modes failed to start" >&2; exit 1; }
wait_ready "http://127.0.0.1:${TEMPLATE_PORT}/" || { echo "basic_app_fresh failed to start" >&2; exit 1; }
wait_ready "http://127.0.0.1:${TODO_PORT}/todos/fragment?mode=full" || { echo "todo_sqlite_mvc_app_fresh failed to start" >&2; exit 1; }

CSV_FILE="${OUT_DIR}/results.csv"
echo "endpoint,url,req_per_sec,lat_avg,p50,p75,p90,p99,transfer_per_sec" >"${CSV_FILE}"

run_wrk_case() {
  local name="$1"
  local url="$2"
  local out="${OUT_DIR}/${name}.wrk.txt"

  echo "[bench] ${name} -> ${url}"
  wrk -t"${THREADS}" -c"${CONNS}" -d"${WARMUP}" "${url}" >"${OUT_DIR}/${name}.warmup.txt" 2>&1 || true
  wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${url}" | tee "${out}"
  assert_wrk_clean "${name}" "${out}"
  for pid in "${SERVER_PIDS[@]}"; do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      echo "server process exited during ${name}: pid=${pid}" >&2
      return 1
    fi
  done

  local req lat p50 p75 p90 p99 tx
  req="$(awk '/Requests\/sec:/ {print $2}' "${out}" | tail -1)"
  lat="$(awk '/Latency[[:space:]]+/ {print $2; exit}' "${out}")"
  p50="$(awk '$1 == "50%" {print $2; exit}' "${out}")"
  p75="$(awk '$1 == "75%" {print $2; exit}' "${out}")"
  p90="$(awk '$1 == "90%" {print $2; exit}' "${out}")"
  p99="$(awk '$1 == "99%" {print $2; exit}' "${out}")"
  tx="$(awk '/Transfer\/sec:/ {print $2 " " $3}' "${out}" | tail -1)"

  echo "${name},${url},${req},${lat},${p50},${p75},${p90},${p99},${tx}" >>"${CSV_FILE}"
}

run_wrk_case "plaintext" "http://127.0.0.1:${BENCH_PORT}/plaintext"
run_wrk_case "json" "http://127.0.0.1:${BENCH_PORT}/json"
run_wrk_case "get" "http://127.0.0.1:${ROUTE_PORT}/get"
run_wrk_case "getasync" "http://127.0.0.1:${ROUTE_PORT}/getasync"
run_wrk_case "template" "http://127.0.0.1:${TEMPLATE_PORT}/"
run_wrk_case "todo_fragment" "http://127.0.0.1:${TODO_PORT}/todos/fragment?mode=full"

cat >"${OUT_DIR}/summary.md" <<EOF
# nim_express Endpoint Benchmark

- timestamp: ${STAMP}
- wrk threads: ${THREADS}
- wrk connections: ${CONNS}
- wrk duration: ${DURATION}
- warmup: ${WARMUP}
- todo seed rows: ${TODO_SEED}

## Results

| Endpoint | URL | Req/sec | Avg | P50 | P75 | P90 | P99 | Transfer/sec |
|---|---|---:|---:|---:|---:|---:|---:|---:|
$(tail -n +2 "${CSV_FILE}" | awk -F',' '{printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8, $9}')

## Notes

- template uses examples/basic_app.nim route /.
- todo_fragment uses examples/todo_sqlite_mvc_app.nim route /todos/fragment?mode=full.
- Raw wrk outputs are saved alongside this summary.
EOF

rm -f "${LATEST_LINK}"
ln -s "${OUT_DIR}" "${LATEST_LINK}"

echo
echo "[nim-express-endpoint-bench] out_dir=${OUT_DIR}"
echo "[nim-express-endpoint-bench] summary=${OUT_DIR}/summary.md"
