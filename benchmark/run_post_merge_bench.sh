#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
source "${ROOT_DIR}/benchmark/build_helpers.sh"

BRANCH="${1:-benchmark/post-merge-perf-20260305-140600}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3002}"

THREADS="${THREADS:-8}"
CONNS="${CONNS:-256}"
DURATION="${DURATION:-15s}"

AB_CONNS="${AB_CONNS:-200}"
AB_N_PLAINTEXT="${AB_N_PLAINTEXT:-200000}"
AB_N_JSON="${AB_N_JSON:-100000}"

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT_DIR}/benchmark/reports/post_merge_${STAMP}"
mkdir -p "${OUT_DIR}"
bench_init_cold_build "${ROOT_DIR}" "${OUT_DIR}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for cmd in git make wrk ab awk sed grep; do
  require_cmd "$cmd"
done

SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[1/5] Updating branch '${BRANCH}' from main..."
git checkout "${BRANCH}" | tee "${OUT_DIR}/git_checkout.log"
git merge --ff-only main | tee "${OUT_DIR}/git_merge.log"

echo "[2/5] Building benchmark server..."
bench_rebuild_usockets "${OUT_DIR}/build_usockets.log"
bench_make bench_nim_express bench | tee "${OUT_DIR}/build.log"

echo "[3/5] Starting benchmark server..."
"${ROOT_DIR}/benchmark/bench_nim_express" >"${OUT_DIR}/server.log" 2>&1 &
SERVER_PID=$!
sleep 2

BASE_URL="http://${HOST}:${PORT}"

echo "[4/5] Running wrk benchmarks..."
wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${BASE_URL}/plaintext" \
  | tee "${OUT_DIR}/wrk_plaintext.txt"
wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${BASE_URL}/json" \
  | tee "${OUT_DIR}/wrk_json.txt"

echo "[5/5] Running ab benchmarks..."
ab -n "${AB_N_PLAINTEXT}" -c "${AB_CONNS}" "${BASE_URL}/plaintext" \
  | tee "${OUT_DIR}/ab_plaintext.txt"
# /json payload may vary when app metadata changes; allow variable length.
ab -l -n "${AB_N_JSON}" -c "${AB_CONNS}" "${BASE_URL}/json" \
  | tee "${OUT_DIR}/ab_json.txt"

wrk_rps() {
  awk '/Requests\/sec:/ {print $2}' "$1" | tail -1
}

wrk_lat() {
  awk '/Latency/ {print $2 " " $3}' "$1" | head -1
}

ab_rps() {
  awk -F': *' '/Requests per second/ {print $2}' "$1" | sed 's/ *\[.*//'
}

cat > "${OUT_DIR}/summary.md" <<EOF
# Post-Merge Benchmark Summary (${STAMP})

- branch: ${BRANCH}
- target: ${BASE_URL}
- wrk: threads=${THREADS}, connections=${CONNS}, duration=${DURATION}
- ab: concurrency=${AB_CONNS}

## wrk
- /plaintext: $(wrk_rps "${OUT_DIR}/wrk_plaintext.txt") req/s, avg latency $(wrk_lat "${OUT_DIR}/wrk_plaintext.txt")
- /json: $(wrk_rps "${OUT_DIR}/wrk_json.txt") req/s, avg latency $(wrk_lat "${OUT_DIR}/wrk_json.txt")

## ab
- /plaintext: $(ab_rps "${OUT_DIR}/ab_plaintext.txt")
- /json: $(ab_rps "${OUT_DIR}/ab_json.txt")
EOF

echo
echo "Benchmark complete."
echo "Reports:"
echo "  ${OUT_DIR}/summary.md"
