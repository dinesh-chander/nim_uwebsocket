#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/reports/${STAMP}"
mkdir -p "${OUT_DIR}"

TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
TARGET_PORT="${TARGET_PORT:-3000}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-200}"
DURATION="${DURATION:-15s}"
WINDOW_RANGE="${WINDOW_RANGE:-items=0-127}"

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required for run_todo_fragment_windowing.sh" >&2
  exit 1
fi

BASE_URL="http://${TARGET_HOST}:${TARGET_PORT}/todos/fragment"
WINDOW_URL="${BASE_URL}?mode=window"

echo "[todo-window] target=${TARGET_HOST}:${TARGET_PORT}"
echo "[todo-window] wrk -t${THREADS} -c${CONNS} -d${DURATION}"
echo "[todo-window] range=${WINDOW_RANGE}"

run_case() {
  local name="$1"
  local url="$2"
  local out_file="${OUT_DIR}/${name}.txt"
  shift 2
  echo "[todo-window] ${name}: ${url}"
  wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" "$@" "${url}" | tee "${out_file}" >/dev/null
}

run_case full_fragment "${BASE_URL}"
run_case window_fragment "${WINDOW_URL}" -H "Range: ${WINDOW_RANGE}"

cat > "${OUT_DIR}/summary.md" <<SUMMARY
# Todo Fragment Windowing Benchmark (${STAMP})

- target: ${TARGET_HOST}:${TARGET_PORT}
- threads: ${THREADS}
- connections: ${CONNS}
- duration: ${DURATION}
- window_range: ${WINDOW_RANGE}

## Commands

\`\`\`bash
wrk -t${THREADS} -c${CONNS} -d${DURATION} ${BASE_URL}
wrk -t${THREADS} -c${CONNS} -d${DURATION} -H "Range: ${WINDOW_RANGE}" ${WINDOW_URL}
\`\`\`
SUMMARY

LATEST_LINK="${ROOT_DIR}/benchmark/reports/latest_todo_windowing"
rm -f "${LATEST_LINK}"
ln -s "${OUT_DIR}" "${LATEST_LINK}"

echo "[todo-window] report: ${OUT_DIR}/summary.md"
