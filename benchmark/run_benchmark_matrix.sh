#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_ROOT="${ROOT_DIR}/benchmark/reports"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${REPORT_ROOT}/${STAMP}"
mkdir -p "${OUT_DIR}"

TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
TARGET_PORT="${TARGET_PORT:-3002}"
DURATION="${DURATION:-15s}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-256}"

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required for run_benchmark_matrix.sh" >&2
  exit 1
fi

run_case() {
  local name="$1"
  local url="$2"
  local out="${OUT_DIR}/${name}.txt"
  echo "[matrix] ${name} -> ${url}"
  wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" "${url}" | tee "${out}" >/dev/null
}

extract_rps() {
  local file="$1"
  awk '/Requests\/sec:/ {print $2}' "${file}" | tail -1
}

extract_latency() {
  local file="$1"
  awk '/Latency/ {print $2" "$3}' "${file}" | head -1
}

run_case plaintext "http://${TARGET_HOST}:${TARGET_PORT}/plaintext"
run_case json "http://${TARGET_HOST}:${TARGET_PORT}/json"

cat > "${OUT_DIR}/summary.md" <<SUMMARY
# Benchmark Matrix (${STAMP})

- target: ${TARGET_HOST}:${TARGET_PORT}
- threads: ${THREADS}
- connections: ${CONNS}
- duration: ${DURATION}

| case | req/s | avg latency |
|---|---:|---:|
| plaintext | $(extract_rps "${OUT_DIR}/plaintext.txt") | $(extract_latency "${OUT_DIR}/plaintext.txt") |
| json | $(extract_rps "${OUT_DIR}/json.txt") | $(extract_latency "${OUT_DIR}/json.txt") |
SUMMARY

LATEST_LINK="${REPORT_ROOT}/latest"
rm -f "${LATEST_LINK}"
ln -s "${OUT_DIR}" "${LATEST_LINK}"

echo "[matrix] report: ${OUT_DIR}/summary.md"
