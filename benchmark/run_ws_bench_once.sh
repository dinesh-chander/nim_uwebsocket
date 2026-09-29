#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${1:-ws://127.0.0.1:3400}"
CLIENTS="${2:-220}"
DURATION="${3:-8}"
PAYLOAD="${4:-64}"
MAX_INFLIGHT="${5:-16}"
PROFILE="${NIM_EXPRESS_PROFILE:-linux-throughput}"
PORT="${PORT:-3400}"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT}/benchmark/reports/ws_once_${STAMP}"
mkdir -p "${OUT_DIR}"

NIM_EXPRESS_PROFILE="${PROFILE}" PORT="${PORT}" "${ROOT}/benchmark/ws_echo_bench" >"${OUT_DIR}/server.log" 2>&1 &
SERVER_PID=$!
cleanup() {
  if kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

wait_for_health() {
  local tries=60
  while (( tries > 0 )); do
    if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries-1))
    sleep 0.1
  done
  return 1
}

if ! wait_for_health; then
  echo "ws server failed to start" >&2
  exit 1
fi

if ! (cd "${ROOT}/benchmark" && node -e "require('ws')" >/dev/null 2>&1); then
  echo "missing node module: ws (install with: npm i ws)" >&2
  exit 2
fi

curl -fsS "http://127.0.0.1:${PORT}/metrics" >"${OUT_DIR}/metrics_before.json"
node "${ROOT}/benchmark/ws_bench.js" "${URL}" "${CLIENTS}" "${DURATION}" "${PAYLOAD}" "${MAX_INFLIGHT}" >"${OUT_DIR}/bench.json"
if ! kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
  echo "ws server exited during benchmark" >&2
  exit 1
fi
curl -fsS "http://127.0.0.1:${PORT}/metrics" >"${OUT_DIR}/metrics_after.json"

node - <<'NODE' "${OUT_DIR}/bench.json" "${OUT_DIR}/metrics_before.json" "${OUT_DIR}/metrics_after.json" "${OUT_DIR}/report.md"
const fs = require("fs");
const bench = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const before = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const after = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const out = process.argv[5];
const delta = (k) => (Number(after[k] || 0) - Number(before[k] || 0));
const requiredMetrics = [
  "parser_errors",
  "overload_rejects",
  "backpressure_drops",
  "backpressure_high_water_events"
];
const failures = [];
for (const key of requiredMetrics) {
  if (!(key in before) || !(key in after)) failures.push(`missing metric ${key}`);
}
if (bench.opened !== bench.clients) failures.push(`opened ${bench.opened}/${bench.clients}`);
if (bench.errors !== 0) failures.push(`client errors ${bench.errors}`);
if (bench.recv === 0) failures.push("no echoed messages received");
if (bench.inFlight !== 0) failures.push(`inFlight ${bench.inFlight}`);
if (bench.recv < bench.sent) failures.push(`recv ${bench.recv} < sent ${bench.sent}`);
if (delta("parser_errors") !== 0) failures.push(`parser_errors delta ${delta("parser_errors")}`);
if (delta("overload_rejects") !== 0) failures.push(`overload_rejects delta ${delta("overload_rejects")}`);
if (delta("backpressure_drops") !== 0) failures.push(`backpressure_drops delta ${delta("backpressure_drops")}`);
const md = [
  "# WS Bench Report",
  "",
  "## Throughput",
  `- clients opened: ${bench.opened}/${bench.clients}`,
  `- clients closed: ${bench.closed}`,
  `- sent: ${bench.sent}`,
  `- received: ${bench.recv}`,
  `- errors: ${bench.errors}`,
  `- in flight: ${bench.inFlight}`,
  `- messages/sec: ${bench.rttMsgPerSec}`,
  `- avg latency ms: ${bench.avgLatencyMs}`,
  `- p50 latency ms: ${bench.p50LatencyMs}`,
  `- p95 latency ms: ${bench.p95LatencyMs}`,
  `- p99 latency ms: ${bench.p99LatencyMs}`,
  `- max latency ms: ${bench.maxLatencyMs}`,
  "",
  "## Counters Delta",
  `- parser_errors: ${delta("parser_errors")}`,
  `- overload_rejects: ${delta("overload_rejects")}`,
  `- write_retries: ${delta("write_retries")}`,
  `- backpressure_drops: ${delta("backpressure_drops")}`,
  `- backpressure_high_water_events: ${delta("backpressure_high_water_events")}`,
  "",
  "## Gate",
  failures.length === 0 ? "- status: PASS" : `- status: FAIL (${failures.join("; ")})`,
  ""
].join("\n");
fs.writeFileSync(out, md);
if (failures.length !== 0) {
  console.error(failures.join("; "));
  process.exit(1);
}
NODE

echo "[ws-bench] profile=${PROFILE}"
echo "[ws-bench] out_dir=${OUT_DIR}"
cat "${OUT_DIR}/report.md"
