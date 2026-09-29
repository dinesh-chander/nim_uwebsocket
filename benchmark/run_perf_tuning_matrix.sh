#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/benchmark/reports/perf_tuning_matrix_${STAMP}}"
PORT_BASE="${PORT_BASE:-3700}"
BUILD_ONCE="${BUILD_ONCE:-1}"

HTTP_PATHS="${HTTP_PATHS:-/health /metrics}"
HTTP_THREADS_LIST="${HTTP_THREADS_LIST:-1 2 4}"
HTTP_CONNS_LIST="${HTTP_CONNS_LIST:-100 200 500}"
HTTP_WRK_THREADS="${HTTP_WRK_THREADS:-8}"
HTTP_DURATION="${HTTP_DURATION:-20}"
HTTP_P99_TARGET_US="${HTTP_P99_TARGET_US:-5000}"

WS_SERVER_THREADS_LIST="${WS_SERVER_THREADS_LIST:-4}"
WS_CLIENT_THREADS="${WS_CLIENT_THREADS:-8}"
WS_CLIENTS_LIST="${WS_CLIENTS_LIST:-1000 5000}"
WS_OUT_MPS_LIST="${WS_OUT_MPS_LIST:-1 5}"
WS_COALESCE_FRAMES_LIST="${WS_COALESCE_FRAMES_LIST:-1 8}"
WS_OPCODE_LIST="${WS_OPCODE_LIST:-text binary}"
WS_DURATION="${WS_DURATION:-20}"
WS_DRAIN_SEC="${WS_DRAIN_SEC:-5}"
WS_BIND_LOOPBACKS="${WS_BIND_LOOPBACKS:-2}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "run_perf_tuning_matrix.sh must run inside Linux/Docker." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

port="${PORT_BASE}"
http_rows=()
ws_rows=()

latency_to_us() {
  local value="$1"
  if [[ "${value}" =~ ^([0-9.]+)us$ ]]; then
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%.0f", v }'
  elif [[ "${value}" =~ ^([0-9.]+)ms$ ]]; then
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%.0f", v * 1000 }'
  elif [[ "${value}" =~ ^([0-9.]+)s$ ]]; then
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%.0f", v * 1000000 }'
  else
    echo "999999999"
  fi
}

metric_zero() {
  local file="$1"
  local key="$2"
  [[ -r "${file}" ]] && grep -q "\"${key}\":0" "${file}"
}

socket_errors_clean() {
  local file="$1"
  if ! grep -q "Socket errors:" "${file}"; then
    return 0
  fi
  grep -q "Socket errors: connect 0, read 0, write 0, timeout 0" "${file}"
}

build_binaries() {
  USOCKETS_BACKEND=epoll NATIVE_OPT=0 make -C "${ROOT_DIR}" ws-echo-bench websocketload >"${OUT_DIR}/build.log" 2>&1
}

start_server() {
  local run_dir="$1"
  local server_threads="$2"
  local server_port="$3"
  local coalesce_frames="${4:-1}"
  THREADS="${server_threads}" \
    PORT="${server_port}" \
    NIM_EXPRESS_WS_KEEPALIVE_INTERVAL_MS=0 \
    NIM_EXPRESS_WS_WRITE_COALESCE_MAX_FRAMES="${coalesce_frames}" \
    "${ROOT_DIR}/benchmark/ws_echo_bench" >"${run_dir}/server.log" 2>&1 &
  echo "$!"
}

wait_server() {
  local server_port="$1"
  for _ in $(seq 1 120); do
    curl -fsS "http://127.0.0.1:${server_port}/health" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

stop_server() {
  local pid="$1"
  kill "${pid}" >/dev/null 2>&1 || true
  wait "${pid}" >/dev/null 2>&1 || true
}

run_http_case() {
  local path="$1"
  local server_threads="$2"
  local conns="$3"
  local run_port="$4"
  local safe_path="${path//\//_}"
  safe_path="${safe_path##_}"
  [[ -z "${safe_path}" ]] && safe_path="root"
  local run_dir="${OUT_DIR}/http_${safe_path}_thr${server_threads}_c${conns}"
  mkdir -p "${run_dir}"

  local server_pid
  server_pid="$(start_server "${run_dir}" "${server_threads}" "${run_port}")"
  if ! wait_server "${run_port}"; then
    stop_server "${server_pid}"
    http_rows+=("${path}|${server_threads}|${conns}|failed|server_start|0|n/a|n/a|n/a|n/a|${run_dir}")
    return
  fi

  set +e
  wrk -t"${HTTP_WRK_THREADS}" -c"${conns}" -d"${HTTP_DURATION}s" --latency \
    "http://127.0.0.1:${run_port}${path}" >"${run_dir}/wrk.log" 2>"${run_dir}/wrk.err"
  local wrk_status=$?
  set -e

  curl -fsS "http://127.0.0.1:${run_port}/metrics" >"${run_dir}/metrics.txt" 2>/dev/null || true
  if kill -0 "${server_pid}" >/dev/null 2>&1; then
    echo "SERVER_ALIVE" >"${run_dir}/status.txt"
  else
    echo "SERVER_EXITED" >"${run_dir}/status.txt"
  fi
  stop_server "${server_pid}"

  local rps avg p50 p99 p99_us status reason
  rps="$(awk '/Requests\/sec:/ {print $2}' "${run_dir}/wrk.log" | tail -1)"
  avg="$(awk '/Latency[[:space:]]+/ {print $2; exit}' "${run_dir}/wrk.log")"
  p50="$(awk '$1 == "50%" {print $2; exit}' "${run_dir}/wrk.log")"
  p99="$(awk '$1 == "99%" {print $2; exit}' "${run_dir}/wrk.log")"
  p99_us="$(latency_to_us "${p99:-}")"
  status="ok"
  reason="ok"
  if [[ "${wrk_status}" -ne 0 ]]; then
    status="failed"; reason="wrk_exit_${wrk_status}"
  elif ! grep -q "SERVER_ALIVE" "${run_dir}/status.txt"; then
    status="failed"; reason="server_exited"
  elif ! socket_errors_clean "${run_dir}/wrk.log"; then
    status="failed"; reason="socket_errors"
  elif ! metric_zero "${run_dir}/metrics.txt" "parser_errors"; then
    status="failed"; reason="parser_errors"
  elif ! metric_zero "${run_dir}/metrics.txt" "overload_rejects"; then
    status="failed"; reason="overload_rejects"
  elif [[ "${p99_us}" -gt "${HTTP_P99_TARGET_US}" ]]; then
    status="over_target"; reason="p99_${p99_us}us"
  fi

  http_rows+=("${path}|${server_threads}|${conns}|${status}|${reason}|${rps:-0}|${avg:-n/a}|${p50:-n/a}|${p99:-n/a}|${p99_us}|${run_dir}")
}

run_ws_case() {
  local server_threads="$1"
  local clients="$2"
  local out_mps="$3"
  local coalesce_frames="$4"
  local opcode="$5"
  local run_port="$6"
  local run_dir="${OUT_DIR}/ws_thr${server_threads}_c${clients}_mps${out_mps}_coal${coalesce_frames}_${opcode}"
  mkdir -p "${run_dir}"

  local server_pid
  server_pid="$(start_server "${run_dir}" "${server_threads}" "${run_port}" "${coalesce_frames}")"
  if ! wait_server "${run_port}"; then
    stop_server "${server_pid}"
    ws_rows+=("${server_threads}|${clients}|${out_mps}|${coalesce_frames}|${opcode}|failed|server_start|0|0|0|n/a|${run_dir}")
    return
  fi

  local args=(
    -h 127.0.0.1
    -p "${run_port}"
    --path /
    -c "${clients}"
    -d "${WS_DURATION}"
    --drain-sec "${WS_DRAIN_SEC}"
    -t "${WS_CLIENT_THREADS}"
    -s 64
    --open-msgs 0
    --no-reply-on-recv
    --out-mps "${out_mps}"
    --ramp-sec "$(( WS_DURATION > 10 ? 10 : 1 ))"
    --opcode "${opcode}"
  )
  if [[ "${WS_BIND_LOOPBACKS}" != "0" ]]; then
    args+=(--bind-loopbacks "${WS_BIND_LOOPBACKS}")
  fi

  set +e
  "${ROOT_DIR}/nim_websocketcli/websocketload" "${args[@]}" >"${run_dir}/client.log" 2>"${run_dir}/client.err"
  local client_status=$?
  set -e

  curl -fsS "http://127.0.0.1:${run_port}/metrics" >"${run_dir}/metrics.txt" 2>/dev/null || true
  if kill -0 "${server_pid}" >/dev/null 2>&1; then
    echo "SERVER_ALIVE" >"${run_dir}/status.txt"
  else
    echo "SERVER_EXITED" >"${run_dir}/status.txt"
  fi
  stop_server "${server_pid}"

  local opened disconnected still_open connect_errors errors sent recv recv_rate status reason
  opened="$(awk -F: '/Opened slots:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  disconnected="$(awk -F: '/Disconnected:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  still_open="$(awk -F: '/Still open:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  connect_errors="$(awk -F: '/Connect Errors:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  errors="$(awk -F: '/Errors:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  sent="$(awk -F: '/Messages sent:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  recv="$(awk -F: '/Messages recv:/ {gsub(/[^0-9]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"
  recv_rate="$(awk -F: '/Recv rate:/ {gsub(/[^0-9.]/, "", $2); print $2}' "${run_dir}/client.log" | tail -1)"

  status="ok"
  reason="ok"
  if [[ "${client_status}" -ne 0 ]]; then
    status="failed"; reason="client_exit_${client_status}"
  elif ! grep -q "SERVER_ALIVE" "${run_dir}/status.txt"; then
    status="failed"; reason="server_exited"
  elif [[ "${opened:-0}" != "${clients}" || "${disconnected:-0}" != "${clients}" ]]; then
    status="failed"; reason="connection_accounting"
  elif [[ "${still_open:-1}" != "0" || "${connect_errors:-1}" != "0" || "${errors:-1}" != "0" ]]; then
    status="failed"; reason="client_errors"
  elif [[ "${sent:-0}" != "${recv:-1}" ]]; then
    status="failed"; reason="message_mismatch"
  elif ! metric_zero "${run_dir}/metrics.txt" "parser_errors"; then
    status="failed"; reason="parser_errors"
  elif ! metric_zero "${run_dir}/metrics.txt" "backpressure_drops"; then
    status="failed"; reason="backpressure_drops"
  fi

  ws_rows+=("${server_threads}|${clients}|${out_mps}|${coalesce_frames}|${opcode}|${status}|${reason}|${sent:-0}|${recv:-0}|${recv_rate:-0}|${opened:-n/a}|${run_dir}")
}

if [[ "${BUILD_ONCE}" == "1" ]]; then
  build_binaries
fi

for path in ${HTTP_PATHS}; do
  for threads in ${HTTP_THREADS_LIST}; do
    for conns in ${HTTP_CONNS_LIST}; do
      run_http_case "${path}" "${threads}" "${conns}" "${port}"
      port=$((port + 1))
    done
  done
done

for server_threads in ${WS_SERVER_THREADS_LIST}; do
  for clients in ${WS_CLIENTS_LIST}; do
    for out_mps in ${WS_OUT_MPS_LIST}; do
      for coalesce_frames in ${WS_COALESCE_FRAMES_LIST}; do
        for opcode in ${WS_OPCODE_LIST}; do
          run_ws_case "${server_threads}" "${clients}" "${out_mps}" "${coalesce_frames}" "${opcode}" "${port}"
          port=$((port + 1))
        done
      done
    done
  done
done

{
  echo "# Performance Tuning Matrix"
  echo
  echo "- timestamp: ${STAMP}"
  echo "- http_p99_target_us: ${HTTP_P99_TARGET_US}"
  echo "- http_duration: ${HTTP_DURATION}s"
  echo "- ws_duration: ${WS_DURATION}s"
  echo "- ws_drain_sec: ${WS_DRAIN_SEC}"
  echo
  echo "## HTTP Results"
  echo
  echo "| path | server threads | conns | status | reason | req/s | avg | p50 | p99 | p99 us | report |"
  echo "|---|---:|---:|---|---|---:|---:|---:|---:|---:|---|"
  for row in "${http_rows[@]}"; do
    IFS='|' read -r path threads conns status reason rps avg p50 p99 p99_us report <<<"${row}"
    echo "| ${path} | ${threads} | ${conns} | ${status} | ${reason} | ${rps} | ${avg} | ${p50} | ${p99} | ${p99_us} | ${report} |"
  done
  echo
  echo "## HTTP Best Under Target"
  echo
  printf "%s\n" "${http_rows[@]}" |
    awk -F'|' '$4 == "ok" {print $6 "|" $0}' |
    sort -t'|' -k1,1nr |
    head -10 |
    awk -F'|' 'BEGIN {print "| rank | path | threads | conns | req/s | p99 | report |"; print "|---:|---|---:|---:|---:|---:|---|"} {printf "| %d | %s | %s | %s | %s | %s | %s |\n", NR, $2, $3, $4, $7, $10, $12}'
  echo
  echo "## WebSocket Results"
  echo
  echo "| server threads | clients | out mps | coalesce frames | opcode | status | reason | sent | recv | recv rate | opened | report |"
  echo "|---:|---:|---:|---:|---|---|---|---:|---:|---:|---:|---|"
  for row in "${ws_rows[@]}"; do
    IFS='|' read -r threads clients out_mps coalesce opcode status reason sent recv recv_rate opened report <<<"${row}"
    echo "| ${threads} | ${clients} | ${out_mps} | ${coalesce} | ${opcode} | ${status} | ${reason} | ${sent} | ${recv} | ${recv_rate} | ${opened} | ${report} |"
  done
  echo
  echo "## WebSocket Best Accurate"
  echo
  printf "%s\n" "${ws_rows[@]}" |
    awk -F'|' '$6 == "ok" {print $10 "|" $0}' |
    sort -t'|' -k1,1nr |
    head -10 |
    awk -F'|' 'BEGIN {print "| rank | clients | out mps | coalesce | opcode | recv rate | report |"; print "|---:|---:|---:|---:|---|---:|---|"} {printf "| %d | %s | %s | %s | %s | %s | %s |\n", NR, $3, $4, $5, $6, $11, $13}'
} >"${OUT_DIR}/report.md"

cat "${OUT_DIR}/report.md"
