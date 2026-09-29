#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/reports/bun_endpoint_bench_${STAMP}"
mkdir -p "${OUT_DIR}"

THREADS="${THREADS:-4}"
CONNS="${CONNS:-500}"
DURATION="${DURATION:-60s}"
WARMUP="${WARMUP:-5s}"
PREWARM_DURATION="${PREWARM_DURATION:-5s}"
TODO_SEED="${TODO_SEED:-1000}"

PORT="${PORT:-3004}"
TODO_DB="${TODO_DB:-/tmp/bun_uwebsocket_endpoint_bench_${STAMP}.db}"
BUN_APP="${BUN_APP:-${ROOT_DIR}/benchmark/bun_bench/server.ts}"
BUN_BIN="${BUN_BIN:-bun}"
LATEST_LINK="${ROOT_DIR}/benchmark/reports/latest_bun_endpoint_bench"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

for cmd in wrk curl bun; do
  need_cmd "$cmd"
done

if [[ ! -f "${BUN_APP}" ]]; then
  echo "bun app not found: ${BUN_APP}" >&2
  exit 1
fi

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

SERVER_PID=""

cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  pkill -f "${BUN_APP}" 2>/dev/null || true
}
trap cleanup EXIT

pkill -f "${BUN_APP}" 2>/dev/null || true
rm -f "${TODO_DB}" "${TODO_DB}-shm" "${TODO_DB}-wal"

BUN_TODO_DB_PATH="${TODO_DB}" BUN_TODO_SEED="${TODO_SEED}" BUN_PORT="${PORT}" "${BUN_BIN}" "${BUN_APP}" >"${OUT_DIR}/server.log" 2>&1 &
SERVER_PID="$!"

wait_ready "http://127.0.0.1:${PORT}/plaintext" || {
  echo "bun benchmark server failed to start" >&2
  exit 1
}

prewarm_case() {
  local name="$1"
  local url="$2"
  local out="${OUT_DIR}/${name}.prewarm.txt"

  echo "[prewarm] ${name} -> ${url}"
  wrk -t"${THREADS}" -c"${CONNS}" -d"${PREWARM_DURATION}" "${url}" >"${out}" 2>&1 || true
}

prewarm_case "plaintext" "http://127.0.0.1:${PORT}/plaintext"
prewarm_case "json" "http://127.0.0.1:${PORT}/json"
prewarm_case "get" "http://127.0.0.1:${PORT}/get"
prewarm_case "getasync" "http://127.0.0.1:${PORT}/getasync"
prewarm_case "template" "http://127.0.0.1:${PORT}/"
prewarm_case "todo_fragment" "http://127.0.0.1:${PORT}/todos/fragment?mode=full"

CSV_FILE="${OUT_DIR}/results.csv"
echo "endpoint,url,req_per_sec,lat_avg,p50,p75,p90,p99,transfer_per_sec" >"${CSV_FILE}"

run_wrk_case() {
  local name="$1"
  local url="$2"
  local out="${OUT_DIR}/${name}.wrk.txt"

  echo "[bench] ${name} -> ${url}"
  wrk -t"${THREADS}" -c"${CONNS}" -d"${WARMUP}" "${url}" >"${OUT_DIR}/${name}.warmup.txt" 2>&1 || true
  wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${url}" | tee "${out}"

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

run_wrk_case "plaintext" "http://127.0.0.1:${PORT}/plaintext"
run_wrk_case "json" "http://127.0.0.1:${PORT}/json"
run_wrk_case "get" "http://127.0.0.1:${PORT}/get"
run_wrk_case "getasync" "http://127.0.0.1:${PORT}/getasync"
run_wrk_case "template" "http://127.0.0.1:${PORT}/"
run_wrk_case "todo_fragment" "http://127.0.0.1:${PORT}/todos/fragment?mode=full"

cat >"${OUT_DIR}/summary.md" <<EOF
# Bun Endpoint Benchmark

- timestamp: ${STAMP}
- wrk threads: ${THREADS}
- wrk connections: ${CONNS}
- wrk duration: ${DURATION}
- prewarm duration: ${PREWARM_DURATION}
- warmup: ${WARMUP}
- todo seed rows: ${TODO_SEED}
- bun port: ${PORT}

## Results

| Endpoint | URL | Req/sec | Avg | P50 | P75 | P90 | P99 | Transfer/sec |
|---|---|---:|---:|---:|---:|---:|---:|---:|
$(tail -n +2 "${CSV_FILE}" | awk -F',' '{printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8, $9}')

## Notes

- template uses the Bun home route /.
- todo_fragment uses /todos/fragment?mode=full.
- raw wrk outputs are saved alongside this summary.
EOF

rm -f "${LATEST_LINK}"
ln -s "${OUT_DIR}" "${LATEST_LINK}"

echo
echo "[bun-endpoint-bench] out_dir=${OUT_DIR}"
echo "[bun-endpoint-bench] summary=${OUT_DIR}/summary.md"
