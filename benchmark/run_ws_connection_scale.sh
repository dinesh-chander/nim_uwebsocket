#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/benchmark/build_helpers.sh"
export NODE_PATH="${ROOT}/benchmark/node_modules${NODE_PATH:+:${NODE_PATH}}"

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${ROOT}/benchmark/reports/ws_connection_scale_${STAMP}"
mkdir -p "${OUT_DIR}"

SERVER_PORTS="${SERVER_PORTS:-3412,3413,3414,3415,3416,3417,3418,3419}"
DURATION_SEC="${DURATION_SEC:-20}"
OPEN_TIMEOUT_SEC="${OPEN_TIMEOUT_SEC:-180}"
CONNECT_BATCH="${CONNECT_BATCH:-2000}"
CONNECT_TICK_MS="${CONNECT_TICK_MS:-10}"
LOCAL_ADDRS="${LOCAL_ADDRS:-127.0.0.1}"
SETUP_LOOPBACK="${SETUP_LOOPBACK:-0}"

IFS=',' read -r -a PORT_LIST_PREVIEW <<< "${SERVER_PORTS}"
NUM_PORTS="${#PORT_LIST_PREVIEW[@]}"

if [[ "$(uname -s)" == "Darwin" ]]; then
  FD_LIMIT="$(ulimit -n 2>/dev/null || echo 256)"
  PER_PROCESS_MAX="$(sysctl -n kern.maxfilesperproc 2>/dev/null || echo 10240)"
  SAFE_PER_PROCESS=$((PER_PROCESS_MAX - 256))
  SAFE_CLIENT_MAX=$((SAFE_PER_PROCESS))
  SAFE_SERVER_MAX=$((SAFE_PER_PROCESS * NUM_PORTS))
  MACOS_MAX=$((SAFE_CLIENT_MAX < SAFE_SERVER_MAX ? SAFE_CLIENT_MAX : SAFE_SERVER_MAX))
  START_CONNECTIONS="${START_CONNECTIONS:-2000}"
  STEP_CONNECTIONS="${STEP_CONNECTIONS:-2000}"
  MAX_CONNECTIONS="${MAX_CONNECTIONS:-${MACOS_MAX}}"
  echo "[ws-connection-scale] macOS detected: FD_LIMIT=${FD_LIMIT} PER_PROCESS_MAX=${PER_PROCESS_MAX}"
  echo "[ws-connection-scale] effective ceiling: client=${SAFE_CLIENT_MAX} servers=${SAFE_SERVER_MAX} MAX=${MAX_CONNECTIONS}"
else
  START_CONNECTIONS="${START_CONNECTIONS:-10000}"
  STEP_CONNECTIONS="${STEP_CONNECTIONS:-10000}"
  MAX_CONNECTIONS="${MAX_CONNECTIONS:-500000}"
fi
CLIENT_WORKERS="${CLIENT_WORKERS:-4}"
PROFILE="${NIM_EXPRESS_PROFILE:-linux-throughput}"
SERVER_BIN="${OUT_DIR}/build/ws_random_object_bench"
RESULTS_CSV="${OUT_DIR}/results.csv"
SUMMARY_MD="${OUT_DIR}/summary.md"
IFS=',' read -r -a PORT_LIST <<< "${SERVER_PORTS}"
URLS="${URLS:-}"

ensure_ws_module() {
  if node -e "require('ws')" >/dev/null 2>&1; then
    return 0
  fi

  local meta_json="${OUT_DIR}/ws_latest.json"
  local tarball_url
  mkdir -p "${ROOT}/benchmark/node_modules/ws"
  curl -fsSL "https://registry.npmjs.org/ws/latest" >"${meta_json}"
  tarball_url="$(node -e 'const fs = require("fs"); const meta = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); console.log(meta.dist.tarball);' "${meta_json}")"
  curl -fsSL "${tarball_url}" | tar -xz -C "${ROOT}/benchmark/node_modules/ws" --strip-components=1
  node -e "require('ws')" >/dev/null 2>&1
}

bench_init_cold_build "${ROOT}" "${OUT_DIR}"
bench_rebuild_usockets "${OUT_DIR}/build/build_usockets.log"
bench_make "ws_random_object_bench" ws-random-object-bench WS_RANDOM_OBJECT_BENCH_BIN="${SERVER_BIN}" >"${OUT_DIR}/build/build_ws_random_object_bench.log" 2>&1

ulimit -n 1048576 2>/dev/null || ulimit -n 524288 2>/dev/null || ulimit -n 65536 2>/dev/null || true
echo "[ws-connection-scale] ulimit -n = $(ulimit -n)"

if [[ "$(uname -s)" == "Darwin" ]]; then
  cur_somaxconn="$(sysctl -n kern.ipc.somaxconn 2>/dev/null || echo 128)"
  if (( cur_somaxconn < 8192 )); then
    echo "[ws-connection-scale] kern.ipc.somaxconn=${cur_somaxconn} (needs 8192+)"
    echo "[ws-connection-scale] Run: sudo sysctl -w kern.ipc.somaxconn=8192"
    sudo sysctl -w kern.ipc.somaxconn=8192 2>/dev/null || echo "[ws-connection-scale] WARNING: could not raise somaxconn (run with sudo if needed)"
  fi
  cur_maxsockbuf="$(sysctl -n kern.ipc.maxsockbuf 2>/dev/null || echo 0)"
  if (( cur_maxsockbuf < 8388608 )); then
    sudo sysctl -w kern.ipc.maxsockbuf=8388608 2>/dev/null || true
  fi
  cur_maxfilesperproc="$(sysctl -n kern.maxfilesperproc 2>/dev/null || echo 10240)"
  echo "[ws-connection-scale] kern.maxfilesperproc=${cur_maxfilesperproc}"
elif [[ "$(uname -s)" == "Linux" ]]; then
  cur_somaxconn="$(sysctl -n net.core.somaxconn 2>/dev/null || echo 128)"
  if (( cur_somaxconn < 65535 )); then
    echo "[ws-connection-scale] net.core.somaxconn=${cur_somaxconn}, raising to 65535"
    sudo sysctl -w net.core.somaxconn=65535 2>/dev/null || true
  fi
  echo 1 | sudo tee /proc/sys/net/ipv4/tcp_tw_reuse >/dev/null 2>&1 || true
  echo "2000 65000" | sudo tee /proc/sys/net/ipv4/ip_local_port_range >/dev/null 2>&1 || true
fi

if [[ "$(uname -s)" == "Darwin" && "${SETUP_LOOPBACK}" == "1" ]]; then
  echo "[ws-connection-scale] setting up loopback aliases 127.0.0.2-32..."
  for i in $(seq 2 32); do
    sudo ifconfig lo0 alias "127.0.0.$i" up 2>/dev/null || true
  done
  if [[ "${LOCAL_ADDRS}" == "127.0.0.1" ]]; then
    LOCAL_ADDRS="127.0.0.1"
    for i in $(seq 2 32); do
      LOCAL_ADDRS+=",127.0.0.$i"
    done
  fi
fi

ensure_ws_module

if [[ -z "${URLS}" ]]; then
  for port in "${PORT_LIST[@]}"; do
    if [[ -n "${URLS}" ]]; then
      URLS+=","
    fi
    URLS+="ws://127.0.0.1:${port}"
  done
fi

SERVER_PIDS=()
for port in "${PORT_LIST[@]}"; do
  NIM_EXPRESS_PROFILE="${PROFILE}" PORT="${port}" "${SERVER_BIN}" >"${OUT_DIR}/server_${port}.log" 2>&1 &
  SERVER_PIDS+=("$!")
done

cleanup() {
  for pid in "${SERVER_PIDS[@]}"; do
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

wait_for_health() {
  local port="$1"
  local tries=100
  while (( tries > 0 )); do
    if curl --max-time 2 -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

for port in "${PORT_LIST[@]}"; do
  if ! wait_for_health "${port}"; then
    echo "websocket scale server failed to start on port ${port}" >&2
    exit 1
  fi
done

echo "clients,opened,open_ratio,messages_per_sec_total,messages_per_sec_per_open_conn,errors,backpressure_drops,backpressure_high_water_events,bottleneck" >"${RESULTS_CSV}"

BOTTLENECK_CLIENTS=""
BOTTLENECK_REASON=""
LAST_SUCCESS_CLIENTS="0"

fetch_metric_value() {
  local file="$1"
  local key="$2"
  node -e 'const fs = require("fs"); const file = process.argv[1]; const key = process.argv[2]; const data = JSON.parse(fs.readFileSync(file, "utf8")); console.log(Number(data[key] || 0));' "$file" "$key"
}

fetch_metric_sum() {
  local key="$1"
  local total=0
  local tmp_file
  local value
  for port in "${PORT_LIST[@]}"; do
    tmp_file="${OUT_DIR}/metric_${key}_${port}.json"
    curl --max-time 2 -fsS "http://127.0.0.1:${port}/metrics" >"${tmp_file}" 2>/dev/null || echo "{}" >"${tmp_file}"
    value="$(fetch_metric_value "${tmp_file}" "${key}")"
    total="$(node -e 'console.log(Number(process.argv[1]) + Number(process.argv[2]));' "${total}" "${value}")"
  done
  echo "${total}"
}

for (( clients = START_CONNECTIONS; clients <= MAX_CONNECTIONS; clients += STEP_CONNECTIONS )); do
  RUN_PREFIX="${OUT_DIR}/run_${clients}"
  BACKPRESSURE_DROPS_BEFORE="$(fetch_metric_sum "backpressure_drops")"
  HIGH_WATER_BEFORE="$(fetch_metric_sum "backpressure_high_water_events")"

  node "${ROOT}/benchmark/ws_connection_scale_bench.js" \
    "${URLS}" \
    "${clients}" \
    "${DURATION_SEC}" \
    "${OPEN_TIMEOUT_SEC}" \
    "${LOCAL_ADDRS}" \
    "${CONNECT_BATCH}" \
    "${CONNECT_TICK_MS}" \
    "${CLIENT_WORKERS}" >"${RUN_PREFIX}_bench.json"

  BACKPRESSURE_DROPS_AFTER="$(fetch_metric_sum "backpressure_drops")"
  HIGH_WATER_AFTER="$(fetch_metric_sum "backpressure_high_water_events")"

  ANALYSIS_JSON="$(node - <<'NODE' "${RUN_PREFIX}_bench.json" "${BACKPRESSURE_DROPS_BEFORE}" "${BACKPRESSURE_DROPS_AFTER}" "${HIGH_WATER_BEFORE}" "${HIGH_WATER_AFTER}"
const fs = require("fs");
const bench = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const backpressureDrops = Number(process.argv[4]) - Number(process.argv[3]);
const highWater = Number(process.argv[6]) - Number(process.argv[5]);
let bottleneck = "";
if (bench.openedAtMeasurementStart < bench.clientsRequested) {
  bottleneck = "open_shortfall";
} else if (bench.errors > 0) {
  bottleneck = "client_errors";
} else if (backpressureDrops > 0) {
  bottleneck = "server_backpressure_drops";
} else if (highWater > 0) {
  bottleneck = "server_backpressure_high_water";
} else if (bench.messagesPerSecPerOpenConnection < 0.10) {
  bottleneck = "message_rate_drop";
}
console.log(JSON.stringify({
  clients: bench.clientsRequested,
  opened: bench.openedAtMeasurementStart,
  openRatio: bench.openRatio,
  messagesPerSecTotal: bench.messagesPerSecTotal,
  messagesPerSecPerOpenConnection: bench.messagesPerSecPerOpenConnection,
  errors: bench.errors,
  backpressureDrops,
  highWater,
  bottleneck,
  measurementReason: bench.measurementReason,
  sampleErrors: bench.sampleErrors || []
}));
NODE
)"

  node - <<'NODE' "${RESULTS_CSV}" "${ANALYSIS_JSON}"
const fs = require("fs");
const csv = process.argv[2];
const row = JSON.parse(process.argv[3]);
fs.appendFileSync(
  csv,
  `${row.clients},${row.opened},${row.openRatio},${row.messagesPerSecTotal},${row.messagesPerSecPerOpenConnection},${row.errors},${row.backpressureDrops},${row.highWater},${row.bottleneck}\n`
);
NODE

  CURRENT_BOTTLENECK="$(node -e 'const row = JSON.parse(process.argv[1]); console.log(row.bottleneck || "");' "${ANALYSIS_JSON}")"
  if [[ -n "${CURRENT_BOTTLENECK}" ]]; then
    BOTTLENECK_CLIENTS="${clients}"
    BOTTLENECK_REASON="${CURRENT_BOTTLENECK}"
    break
  fi
  LAST_SUCCESS_CLIENTS="${clients}"
  sleep 2

done

node - <<'NODE' "${RESULTS_CSV}" "${SUMMARY_MD}" "${START_CONNECTIONS}" "${STEP_CONNECTIONS}" "${MAX_CONNECTIONS}" "${DURATION_SEC}" "${OPEN_TIMEOUT_SEC}" "${LOCAL_ADDRS}" "${BOTTLENECK_CLIENTS}" "${BOTTLENECK_REASON}" "${LAST_SUCCESS_CLIENTS}" "${URLS}"
const fs = require("fs");
const csvPath = process.argv[2];
const summaryPath = process.argv[3];
const startClients = process.argv[4];
const stepClients = process.argv[5];
const maxClients = process.argv[6];
const durationSec = process.argv[7];
const openTimeoutSec = process.argv[8];
const localAddrs = process.argv[9];
const bottleneckClients = process.argv[10];
const bottleneckReason = process.argv[11];
const lastSuccessClients = process.argv[12];
const urls = process.argv[13];
const csv = fs.readFileSync(csvPath, "utf8").trim().split("\n");
const rows = csv.slice(1).map((line) => {
  const [clients, opened, openRatio, total, perConn, errors, backpressureDrops, highWater, bottleneck] = line.split(",");
  return { clients, opened, openRatio, total, perConn, errors, backpressureDrops, highWater, bottleneck };
});
const md = [];
md.push("# WebSocket Connection Scale Benchmark");
md.push("");
md.push("## Config");
md.push(`- start connections: ${startClients}`);
md.push(`- step connections: ${stepClients}`);
md.push(`- max connections: ${maxClients}`);
md.push(`- steady measurement seconds: ${durationSec}`);
md.push(`- open timeout seconds: ${openTimeoutSec}`);
md.push(`- local source addresses: ${localAddrs}`);
md.push(`- server urls: ${urls}`);
md.push("");
md.push("## Results");
md.push("");
md.push("| Clients | Opened | Open Ratio | Msg/s Total | Msg/s per Open Conn | Errors | Backpressure Drops | High Water Events | Bottleneck |");
md.push("|---|---:|---:|---:|---:|---:|---:|---:|---|");
for (const row of rows) {
  md.push(`| ${row.clients} | ${row.opened} | ${row.openRatio} | ${row.total} | ${row.perConn} | ${row.errors} | ${row.backpressureDrops} | ${row.highWater} | ${row.bottleneck || ""} |`);
}
md.push("");
md.push("## Outcome");
if (bottleneckClients) {
  md.push(`- first bottleneck: ${bottleneckClients} connections`);
  md.push(`- bottleneck reason: ${bottleneckReason}`);
  md.push(`- last fully successful step: ${lastSuccessClients} connections`);
} else {
  md.push(`- no bottleneck found up to ${maxClients} connections`);
}
fs.writeFileSync(summaryPath, md.join("\n"));
NODE

echo "[ws-connection-scale] out_dir=${OUT_DIR}"
echo "[ws-connection-scale] summary=${SUMMARY_MD}"
cat "${SUMMARY_MD}"
