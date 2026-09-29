#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/benchmark/reports/stability_matrix_${STAMP}}"
PORT_BASE="${PORT_BASE:-3600}"
SERVER_THREADS="${SERVER_THREADS:-4}"
CLIENT_THREADS="${CLIENT_THREADS:-8}"
BUILD_ONCE="${BUILD_ONCE:-1}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "run_stability_matrix.sh must run inside Linux/Docker." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

failures=0
rows=()

record_row() {
  rows+=("$1|$2|$3|$4")
}

check_metric_zero() {
  local file="$1"
  local key="$2"
  if [[ ! -r "${file}" ]]; then
    return 1
  fi
  grep -q "\"${key}\":0" "${file}"
}

build_binaries() {
  USOCKETS_BACKEND=epoll NATIVE_OPT=0 make -C "${ROOT_DIR}" ws-echo-bench websocketload >"${OUT_DIR}/build.log" 2>&1
}

run_http_case() {
  local name="$1"
  local path="$2"
  local connections="$3"
  local duration="$4"
  local port="$5"
  local run_dir="${OUT_DIR}/${name}"
  mkdir -p "${run_dir}"

  THREADS="${SERVER_THREADS}" PORT="${port}" NIM_EXPRESS_WS_KEEPALIVE_INTERVAL_MS=0 \
    "${ROOT_DIR}/benchmark/ws_echo_bench" >"${run_dir}/server.log" 2>&1 &
  local server_pid=$!
  cleanup() {
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  }
  trap cleanup RETURN

  for _ in $(seq 1 120); do
    curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && break
    sleep 0.1
  done

  set +e
  wrk -t8 -c"${connections}" -d"${duration}s" --latency "http://127.0.0.1:${port}${path}" >"${run_dir}/wrk.log" 2>"${run_dir}/wrk.err"
  local status=$?
  set -e

  curl -fsS "http://127.0.0.1:${port}/metrics" >"${run_dir}/metrics.txt" 2>/dev/null || true
  if kill -0 "${server_pid}" >/dev/null 2>&1; then
    echo "SERVER_ALIVE" >"${run_dir}/status.txt"
  else
    echo "SERVER_EXITED" >"${run_dir}/status.txt"
  fi
  cleanup
  trap - RETURN

  local reason="ok"
  if [[ "${status}" -ne 0 ]]; then
    reason="wrk_exit_${status}"
  elif ! grep -q "SERVER_ALIVE" "${run_dir}/status.txt"; then
    reason="server_exited"
  elif ! check_metric_zero "${run_dir}/metrics.txt" "parser_errors"; then
    reason="parser_errors"
  elif ! check_metric_zero "${run_dir}/metrics.txt" "overload_rejects"; then
    reason="overload_rejects"
  elif grep -q "Socket errors:" "${run_dir}/wrk.log" && ! grep -q "Socket errors: connect 0, read 0, write 0, timeout 0" "${run_dir}/wrk.log"; then
    reason="socket_errors"
  fi

  if [[ "${reason}" != "ok" ]]; then
    failures=$((failures + 1))
  fi
  record_row "${name}" "$([[ "${reason}" == "ok" ]] && echo ok || echo failed)" "${reason}" "${run_dir}"
}

run_ws_case() {
  local name="$1"
  local clients="$2"
  local duration="$3"
  local drain_sec="$4"
  local out_mps="$5"
  local opcode="$6"
  local port="$7"
  local bind_loopbacks="${8:-0}"
  local run_dir="${OUT_DIR}/${name}"
  mkdir -p "${run_dir}"

  THREADS="${SERVER_THREADS}" PORT="${port}" NIM_EXPRESS_WS_KEEPALIVE_INTERVAL_MS=0 \
    "${ROOT_DIR}/benchmark/ws_echo_bench" >"${run_dir}/server.log" 2>&1 &
  local server_pid=$!
  cleanup() {
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  }
  trap cleanup RETURN

  for _ in $(seq 1 120); do
    curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && break
    sleep 0.1
  done

  local args=(
    -h 127.0.0.1
    -p "${port}"
    --path /
    -c "${clients}"
    -d "${duration}"
    --drain-sec "${drain_sec}"
    -t "${CLIENT_THREADS}"
    -s 64
    --open-msgs 0
    --no-reply-on-recv
    --out-mps "${out_mps}"
    --ramp-sec "$(( duration > 10 ? 10 : 1 ))"
    --opcode "${opcode}"
  )
  if [[ "${bind_loopbacks}" != "0" ]]; then
    args+=(--bind-loopbacks "${bind_loopbacks}")
  fi

  set +e
  "${ROOT_DIR}/nim_websocketcli/websocketload" "${args[@]}" >"${run_dir}/client.log" 2>"${run_dir}/client.err"
  local status=$?
  set -e

  curl -fsS "http://127.0.0.1:${port}/metrics" >"${run_dir}/metrics.txt" 2>/dev/null || true
  if kill -0 "${server_pid}" >/dev/null 2>&1; then
    echo "SERVER_ALIVE" >"${run_dir}/status.txt"
  else
    echo "SERVER_EXITED" >"${run_dir}/status.txt"
  fi
  cleanup
  trap - RETURN

  local connected opened disconnected still_open connect_errors errors sent recv
  connected="$(awk -F: '/Connected:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  opened="$(awk -F: '/Opened slots:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  disconnected="$(awk -F: '/Disconnected:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  still_open="$(awk -F: '/Still open:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  connect_errors="$(awk -F: '/Connect Errors:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  errors="$(awk -F: '/Errors:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  sent="$(awk -F: '/Messages sent:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  recv="$(awk -F: '/Messages recv:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"

  local reason="ok"
  if [[ "${status}" -ne 0 ]]; then
    reason="client_exit_${status}"
  elif ! grep -q "SERVER_ALIVE" "${run_dir}/status.txt"; then
    reason="server_exited"
  elif [[ "${opened:-0}" != "${clients}" || "${connected:-0}" != "${clients}" || "${disconnected:-0}" != "${clients}" ]]; then
    reason="connection_accounting"
  elif [[ "${still_open:-1}" != "0" || "${connect_errors:-1}" != "0" || "${errors:-1}" != "0" ]]; then
    reason="client_errors"
  elif [[ "${sent:-0}" != "${recv:-1}" ]]; then
    reason="message_mismatch"
  elif ! check_metric_zero "${run_dir}/metrics.txt" "parser_errors"; then
    reason="parser_errors"
  elif ! check_metric_zero "${run_dir}/metrics.txt" "backpressure_drops"; then
    reason="backpressure_drops"
  fi

  if [[ "${reason}" != "ok" ]]; then
    failures=$((failures + 1))
  fi
  record_row "${name}" "$([[ "${reason}" == "ok" ]] && echo ok || echo failed)" "${reason}" "${run_dir}"
}

if [[ "${BUILD_ONCE}" == "1" ]]; then
  build_binaries
fi

port="${PORT_BASE}"
run_http_case "http_health_200c_15s" "/health" 200 15 "${port}"; port=$((port + 1))
run_http_case "http_metrics_200c_15s" "/metrics" 200 15 "${port}"; port=$((port + 1))
run_ws_case "ws_text_1k_drain" 1000 10 3 1 text "${port}" 0; port=$((port + 1))
run_ws_case "ws_binary_1k_drain" 1000 10 3 1 binary "${port}" 0; port=$((port + 1))
run_ws_case "ws_text_5k_drain" 5000 15 5 1 text "${port}" 2; port=$((port + 1))

{
  echo "# Stability Matrix"
  echo
  echo "- timestamp: ${STAMP}"
  echo "- server_threads: ${SERVER_THREADS}"
  echo "- client_threads: ${CLIENT_THREADS}"
  echo
  echo "| scenario | status | reason | report |"
  echo "|---|---|---|---|"
  for row in "${rows[@]}"; do
    IFS='|' read -r name status reason report <<<"${row}"
    echo "| ${name} | ${status} | ${reason} | ${report} |"
  done
} >"${OUT_DIR}/report.md"

cat "${OUT_DIR}/report.md"
exit "${failures}"
