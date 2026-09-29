#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/benchmark/reports/ws_docker_scale_matrix_${STAMP}}"
BACKENDS="${BACKENDS:-epoll}"
CLIENTS_LIST="${CLIENTS_LIST:-1000}"
REPETITIONS="${REPETITIONS:-1}"
PORT_BASE="${PORT_BASE:-3450}"
SERVER_THREADS="${SERVER_THREADS:-4}"
CLIENT_THREADS="${CLIENT_THREADS:-8}"
DURATION="${DURATION:-60}"
WS_DRAIN_SEC="${WS_DRAIN_SEC:-0}"
RAMP_SEC="${RAMP_SEC:-20}"
MSG_LEN="${MSG_LEN:-64}"
OUT_MPS="${OUT_MPS:-1}"
TICK_MS="${TICK_MS:-10}"
OPCODE="${OPCODE:-text}"
BIND_LOOPBACKS="${BIND_LOOPBACKS:-0}"
OPEN_MSGS="${OPEN_MSGS:-0}"
REPLY_ON_RECV="${REPLY_ON_RECV:-0}"
NATIVE_OPT="${NATIVE_OPT:-0}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "run_ws_docker_scale_matrix.sh must run inside a Linux container/host." >&2
  exit 1
fi

case "${REPETITIONS}" in
  ''|*[!0-9]*)
    echo "REPETITIONS must be a positive integer" >&2
    exit 1
    ;;
esac
if [[ "${REPETITIONS}" -le 0 ]]; then
  echo "REPETITIONS must be a positive integer" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

one_line() {
  "$@" 2>/dev/null | head -1 | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
}

file_one_line() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    head -1 "${path}" | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
  else
    echo "n/a"
  fi
}

write_metadata() {
  local run_dir="$1"
  local backend="$2"
  local clients="$3"
  local rep="$4"
  {
    echo "date=$(date -Is)"
    echo "backend=${backend}"
    echo "clients=${clients}"
    echo "repetition=${rep}"
    echo "server_threads=${SERVER_THREADS}"
    echo "client_threads=${CLIENT_THREADS}"
    echo "duration=${DURATION}"
    echo "ws_drain_sec=${WS_DRAIN_SEC}"
    echo "ramp_sec=${RAMP_SEC}"
    echo "message_len=${MSG_LEN}"
    echo "out_mps=${OUT_MPS}"
    echo "tick_ms=${TICK_MS}"
    echo "opcode=${OPCODE}"
    echo "bind_loopbacks=${BIND_LOOPBACKS}"
    echo "open_msgs=${OPEN_MSGS}"
    echo "reply_on_recv=${REPLY_ON_RECV}"
    echo "ulimit_n=$(ulimit -n)"
    echo "kernel=$(uname -a)"
    echo "machine=$(uname -m)"
    echo "cpu_model=$(awk -F: '/model name|Hardware|Processor/ {gsub(/^[ \t]+/, \"\", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo n/a)"
    echo "cgroup_cpu_max=$(file_one_line /sys/fs/cgroup/cpu.max)"
    echo "cgroup_memory_max=$(file_one_line /sys/fs/cgroup/memory.max)"
    echo "seccomp=$(awk '/Seccomp:/ {print $2}' /proc/self/status 2>/dev/null || echo n/a)"
    echo "seccomp_filters=$(awk '/Seccomp_filters:/ {print $2}' /proc/self/status 2>/dev/null || echo n/a)"
    echo "nim_version=$(one_line nim --version)"
    echo "cc_version=$(one_line cc --version)"
    echo "git_sha=$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo n/a)"
    echo "git_dirty=$(git -C "${ROOT_DIR}" status --short 2>/dev/null | wc -l | awk '{print $1}')"
  } >"${run_dir}/metadata.txt"
}

run_case() {
  local backend="$1"
  local clients="$2"
  local rep="$3"
  local port="$4"
  local run_dir="${OUT_DIR}/${backend}_${clients}_${rep}"
  mkdir -p "${run_dir}"

  echo "[ws-matrix] backend=${backend} clients=${clients} rep=${rep}"
  NATIVE_OPT="${NATIVE_OPT}" USOCKETS_BACKEND="${backend}" make -C "${ROOT_DIR}" ws-echo-bench websocketload >"${run_dir}/build.log" 2>&1
  write_metadata "${run_dir}" "${backend}" "${clients}" "${rep}"

  THREADS="${SERVER_THREADS}" PORT="${port}" "${ROOT_DIR}/benchmark/ws_echo_bench" >"${run_dir}/server.log" 2>&1 &
  local server_pid=$!
  cleanup_server() {
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  }
  trap cleanup_server RETURN

  for _ in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  curl -fsS "http://127.0.0.1:${port}/health" >"${run_dir}/health.txt"

  local client_args=(
    -h 127.0.0.1
    -p "${port}"
    --path /
    -c "${clients}"
    -d "${DURATION}"
    --drain-sec "${WS_DRAIN_SEC}"
    -t "${CLIENT_THREADS}"
    -s "${MSG_LEN}"
    --open-msgs "${OPEN_MSGS}"
    --out-mps "${OUT_MPS}"
    --tick-ms "${TICK_MS}"
    --opcode "${OPCODE}"
    --ramp-sec "${RAMP_SEC}"
  )
  if [[ "${REPLY_ON_RECV}" == "0" ]]; then
    client_args+=(--no-reply-on-recv)
  fi
  if [[ "${BIND_LOOPBACKS}" != "0" ]]; then
    client_args+=(--bind-loopbacks "${BIND_LOOPBACKS}")
  fi

  set +e
  time -p "${ROOT_DIR}/nim_websocketcli/websocketload" "${client_args[@]}" >"${run_dir}/client.log" 2>"${run_dir}/client.err"
  local status=$?
  set -e

  curl -fsS "http://127.0.0.1:${port}/metrics" >"${run_dir}/metrics.txt" 2>/dev/null || true
  if kill -0 "${server_pid}" >/dev/null 2>&1; then
    echo "SERVER_ALIVE" >"${run_dir}/status.txt"
  else
    echo "SERVER_EXITED" >"${run_dir}/status.txt"
  fi
  cleanup_server
  trap - RETURN

  local connected opened disconnected connect_errors errors sent recv still_open server_status
  connected="$(awk -F: '/Connected:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  opened="$(awk -F: '/Opened slots:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  disconnected="$(awk -F: '/Disconnected:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  connect_errors="$(awk -F: '/Connect Errors:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  errors="$(awk -F: '/Errors:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  sent="$(awk -F: '/Messages sent:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  recv="$(awk -F: '/Messages recv:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  still_open="$(awk -F: '/Still open:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  server_status="$(cat "${run_dir}/status.txt")"

  {
    echo "status=${status}"
    echo "backend=${backend}"
    echo "clients=${clients}"
    echo "connected=${connected:-n/a}"
    echo "opened_slots=${opened:-n/a}"
    echo "disconnected=${disconnected:-n/a}"
    echo "still_open=${still_open:-n/a}"
    echo "connect_errors=${connect_errors:-n/a}"
    echo "errors=${errors:-n/a}"
    echo "messages_sent=${sent:-n/a}"
    echo "messages_recv=${recv:-n/a}"
    echo "server_status=${server_status}"
    echo "report=${run_dir}"
  } >"${run_dir}/summary.txt"

  cat "${run_dir}/summary.txt"
  return "${status}"
}

failures=0
rows=()
port="${PORT_BASE}"
for backend in ${BACKENDS}; do
  for clients in ${CLIENTS_LIST}; do
    for rep in $(seq 1 "${REPETITIONS}"); do
      if run_case "${backend}" "${clients}" "${rep}" "${port}"; then
        status="ok"
      else
        status="failed"
        failures=$((failures + 1))
      fi
      summary="${OUT_DIR}/${backend}_${clients}_${rep}/summary.txt"
      connected="$(awk -F= '/^connected=/{print $2}' "${summary}" 2>/dev/null)"
      opened="$(awk -F= '/^opened_slots=/{print $2}' "${summary}" 2>/dev/null)"
      disconnected="$(awk -F= '/^disconnected=/{print $2}' "${summary}" 2>/dev/null)"
      errors="$(awk -F= '/^errors=/{print $2}' "${summary}" 2>/dev/null)"
      connect_errors="$(awk -F= '/^connect_errors=/{print $2}' "${summary}" 2>/dev/null)"
      sent="$(awk -F= '/^messages_sent=/{print $2}' "${summary}" 2>/dev/null)"
      recv="$(awk -F= '/^messages_recv=/{print $2}' "${summary}" 2>/dev/null)"
      server_status="$(awk -F= '/^server_status=/{print $2}' "${summary}" 2>/dev/null)"
      rows+=("${backend}|${clients}|${rep}|${status}|${connected:-n/a}|${opened:-n/a}|${disconnected:-n/a}|${connect_errors:-n/a}|${errors:-n/a}|${sent:-n/a}|${recv:-n/a}|${server_status:-n/a}|${OUT_DIR}/${backend}_${clients}_${rep}")
      port=$((port + 1))
    done
  done
done

{
  echo "# WebSocket Docker Scale Matrix"
  echo
  echo "- timestamp: ${STAMP}"
  echo "- backends: ${BACKENDS}"
  echo "- clients_list: ${CLIENTS_LIST}"
  echo "- repetitions: ${REPETITIONS}"
  echo "- server_threads: ${SERVER_THREADS}"
  echo "- client_threads: ${CLIENT_THREADS}"
  echo "- duration: ${DURATION}"
  echo "- ws_drain_sec: ${WS_DRAIN_SEC}"
  echo "- opcode: ${OPCODE}"
  echo "- bind_loopbacks: ${BIND_LOOPBACKS}"
  echo
  echo "| backend | clients | rep | status | connected | opened | disconnected | connect errors | errors | sent | recv | server | report |"
  echo "|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---|---|"
  for row in "${rows[@]}"; do
    IFS='|' read -r backend clients rep status connected opened disconnected connect_errors errors sent recv server_status report <<<"${row}"
    echo "| ${backend} | ${clients} | ${rep} | ${status} | ${connected} | ${opened} | ${disconnected} | ${connect_errors} | ${errors} | ${sent} | ${recv} | ${server_status} | ${report} |"
  done
} >"${OUT_DIR}/report.md"

echo "[ws-matrix] report: ${OUT_DIR}/report.md"
cat "${OUT_DIR}/report.md"

if [[ "${failures}" -ne 0 ]]; then
  exit 1
fi
