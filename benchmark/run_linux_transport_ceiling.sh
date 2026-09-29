#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
USOCKETS_DIR="${ROOT_DIR}/nim_usockets/usockets"
EXAMPLES_DIR="${ROOT_DIR}/examples"
REPORT_ROOT="${ROOT_DIR}/benchmark/reports"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-${REPORT_ROOT}/linux_transport_ceiling_${STAMP}}"
mkdir -p "${OUT_DIR}"
source "${ROOT_DIR}/benchmark/build_helpers.sh"
bench_set_common_paths "${ROOT_DIR}"
NATIVE_CFLAGS="$(bench_native_cflags)"
PLATFORM_CFLAGS="$(bench_platform_cflags)"

PORT_BASE="${PORT_BASE:-3950}"
SEED="${SEED:-1000}"
THREADS="${THREADS:-8}"
CONNS="${CONNS:-200}"
DURATION="${DURATION:-20s}"
WARMUP="${WARMUP:-3s}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-8}"
PROFILE="${NIM_EXPRESS_PROFILE:-linux-throughput}"
SCENARIO="${SCENARIO:-hotpath}"
HOTPATH_ENDPOINT="${HOTPATH_ENDPOINT:-/plaintext}"
TODO_ENDPOINT="${TODO_ENDPOINT:-/todos/fragment}"
TODO_READY_ENDPOINT="${TODO_READY_ENDPOINT:-/}"
IOURING_MAX_CONNECTIONS="${IOURING_MAX_CONNECTIONS:-65536}"
IOURING_RECV_BUFFERS="${IOURING_RECV_BUFFERS:-8192}"
IOURING_RECV_BUFFER_SIZE="${IOURING_RECV_BUFFER_SIZE:-2048}"
IOURING_ENTRIES="${IOURING_ENTRIES:-2048}"

case "${SCENARIO}" in
  hotpath|todo_fragment) ;;
  *)
    echo "unsupported SCENARIO=${SCENARIO}; use hotpath or todo_fragment" >&2
    exit 1
    ;;
esac

APP_BIN="${APP_BIN:-${ROOT_DIR}/benchmark/linux_transport_${SCENARIO}}"

# Default to epoll-only for stability. Opt-in io_uring via RUN_IO_URING=1 or explicit BACKENDS.
if [[ -n "${BACKENDS:-}" ]]; then
  BACKENDS="${BACKENDS}"
elif [[ "${RUN_IO_URING:-0}" == "1" ]]; then
  BACKENDS="epoll io_uring"
else
  BACKENDS="epoll"
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "run_linux_transport_ceiling.sh must run on Linux." >&2
  exit 1
fi

for backend in ${BACKENDS}; do
  case "${backend}" in
    epoll|io_uring) ;;
    *)
      echo "unsupported Linux backend: ${backend}" >&2
      exit 1
      ;;
  esac
done

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd nim
need_cmd make
need_cmd wrk
need_cmd curl

cmd_first_line() {
  if command -v "$1" >/dev/null 2>&1; then
    { "$@" 2>&1 || true; } | head -1
  else
    echo "n/a"
  fi
  return 0
}

file_one_line() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    tr '\n' ' ' <"${path}" | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]$//'
  else
    echo "n/a"
  fi
}

git_value() {
  if command -v git >/dev/null 2>&1 && git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${ROOT_DIR}" "$@" 2>/dev/null || echo "n/a"
  else
    echo "n/a"
  fi
}

git_dirty_flag() {
  if command -v git >/dev/null 2>&1 && git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "${ROOT_DIR}" diff --quiet --ignore-submodules -- && git -C "${ROOT_DIR}" diff --cached --quiet --ignore-submodules --; then
      echo "0"
    else
      echo "1"
    fi
  else
    echo "n/a"
  fi
}

cpu_model() {
  local value
  value="$(awk -F: '/model name|Hardware|Processor/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  if [[ -n "${value}" ]]; then
    echo "${value}"
  else
    echo "n/a"
  fi
}

docker_runtime() {
  if [[ -f /.dockerenv ]]; then
    echo "docker"
  elif grep -qaE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
    echo "container"
  else
    echo "host"
  fi
}

proc_status_value() {
  local key="$1"
  local value
  value="$(awk -v k="${key}:" '$1 == k {print $2; exit}' /proc/self/status 2>/dev/null || true)"
  if [[ -n "${value}" ]]; then
    echo "${value}"
  else
    echo "n/a"
  fi
}

GIT_SHA="$(git_value rev-parse --short=12 HEAD)"
GIT_DIRTY="$(git_dirty_flag)"
KERNEL="$(uname -a)"
MACHINE="$(uname -m)"
CPU_MODEL="$(cpu_model)"
DOCKER_RUNTIME="$(docker_runtime)"
SECCOMP_MODE="$(proc_status_value Seccomp)"
SECCOMP_FILTERS="$(proc_status_value Seccomp_filters)"
CGROUP_CPU_MAX="$(file_one_line /sys/fs/cgroup/cpu.max)"
CGROUP_MEM_MAX="$(file_one_line /sys/fs/cgroup/memory.max)"
NIM_VERSION_LINE="$(cmd_first_line nim --version)"
CC_VERSION_LINE="$(cmd_first_line cc --version)"
WRK_VERSION_LINE="$(cmd_first_line wrk --version)"
LIBURING_VERSION="$(pkg-config --modversion liburing 2>/dev/null || echo n/a)"
USOCKETS_STAMP_FILE="${ROOT_DIR}/nim_usockets/usockets/.uSockets.backend"

NPROC="$(nproc 2>/dev/null || echo 4)"
APP_WORKERS="${APP_WORKERS:-${NPROC}}"
APP_SCALE_MODE="${APP_SCALE_MODE:-${NIM_EXPRESS_SCALE_MODE:-}}"

resolve_app_scale_mode() {
  local backend="$1"
  if [[ -n "${APP_SCALE_MODE}" ]]; then
    echo "${APP_SCALE_MODE}"
  elif [[ "${backend}" == "io_uring" ]]; then
    # io_uring is fastest and cleanest with one owner loop per process.
    # Threaded SO_REUSEPORT mode can leave a small tail of wrk timeouts.
    echo "cluster"
  elif [[ "${APP_WORKERS}" =~ ^[0-9]+$ && "${APP_WORKERS}" -gt 1 ]]; then
    echo "threaded"
  else
    echo "single"
  fi
}

build_usockets() {
  local backend="$1"
  make -C "${ROOT_DIR}" usockets \
    USOCKETS_BACKEND="${backend}" \
    NATIVE_OPT="${NATIVE_OPT:-1}" \
    TCP_FASTOPEN_QUEUE="${TCP_FASTOPEN_QUEUE:-4096}" \
    IOURING_MAX_CONNECTIONS="${IOURING_MAX_CONNECTIONS}" \
    IOURING_RECV_BUFFERS="${IOURING_RECV_BUFFERS}" \
    IOURING_RECV_BUFFER_SIZE="${IOURING_RECV_BUFFER_SIZE}" \
    IOURING_ENTRIES="${IOURING_ENTRIES}" \
    >/dev/null
}

build_app() {
  local backend="$1"
  local backend_define=()
  local link_flags="${ROOT_DIR}/nim_usockets/usockets/uSockets.a -lpthread -ldl -flto"
  if [[ "${backend}" == "io_uring" ]]; then
    backend_define=(-d:LIBUS_USE_IO_URING)
    link_flags="${link_flags} -luring"
  fi

  if [[ "${SCENARIO}" == "todo_fragment" ]]; then
    link_flags="${link_flags} -lsqlite3"
    pushd "${EXAMPLES_DIR}" >/dev/null
    nim c -f --nimcache:"${OUT_DIR}/nimcache/${backend}_${SCENARIO}" -d:release -d:danger --opt:speed --mm:arc --hints:off \
      ${backend_define[@]+"${backend_define[@]}"} \
      "${BENCH_COMMON_PATHS[@]}" \
      --passC:"-O3 -flto ${PLATFORM_CFLAGS} ${NATIVE_CFLAGS}" \
      --passL:"${link_flags}" \
      -o:"${APP_BIN}" \
      todo_sqlite_mvc_app.nim >/dev/null
    popd >/dev/null
  else
    nim c -f --nimcache:"${OUT_DIR}/nimcache/${backend}_${SCENARIO}" -d:release -d:danger --opt:speed --mm:arc --hints:off \
      ${backend_define[@]+"${backend_define[@]}"} \
      "${BENCH_COMMON_PATHS[@]}" \
      --passC:"-O3 -flto ${PLATFORM_CFLAGS} ${NATIVE_CFLAGS}" \
      --passL:"${link_flags}" \
      -o:"${APP_BIN}" \
      "${ROOT_DIR}/benchmark/bench_nim_express.nim" >/dev/null
  fi
}

seed_todos() {
  local port="$1"
  seq 1 "${SEED}" | xargs -P8 -I{} sh -c \
    'curl -fsS -o /dev/null -X POST -H "content-type: application/json" --data "{\"title\":\"seed-{}\"}" "http://127.0.0.1:'"${port}"'/todos"'
}

wrk_metric() {
  local pattern="$1"
  local wrk_file="$2"
  awk -v p="$pattern" '$0 ~ p {print $2}' "${wrk_file}" | tail -1
}

wrk_latency_percentile() {
  local pct="$1"
  local wrk_file="$2"
  awk -v p="${pct}%" '$1 == p {print $2}' "${wrk_file}" | tail -1
}

assert_wrk_clean() {
  local out="$1"
  if ! grep -q 'Requests/sec:' "${out}"; then
    return 1
  fi
  if grep -Eq 'Non-2xx or 3xx responses:[[:space:]]*[1-9][0-9]*' "${out}"; then
    return 1
  fi
  awk '
    /Socket errors:/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "connect" || $i == "read" || $i == "write" || $i == "timeout") {
          v = $(i + 1); gsub(",", "", v)
          if ((v + 0) > 0) bad = 1
        }
      }
    }
    END { exit bad ? 1 : 0 }
  ' "${out}"
}

run_backend() {
  local backend="$1"
  local port="$2"
  local run_dir="${OUT_DIR}/${backend}"
  mkdir -p "${run_dir}"

  echo "[linux-ceiling] backend=${backend}"

  if ! build_usockets "${backend}"; then
    echo "status=failed" >"${run_dir}/summary.txt"
    echo "reason=build_usockets_failed" >>"${run_dir}/summary.txt"
    return 1
  fi

  if ! build_app "${backend}"; then
    echo "status=failed" >"${run_dir}/summary.txt"
    echo "reason=build_app_failed" >>"${run_dir}/summary.txt"
    return 1
  fi

  local path="${HOTPATH_ENDPOINT}"
  local ready_path="${HOTPATH_ENDPOINT}"
  local scale_mode
  scale_mode="$(resolve_app_scale_mode "${backend}")"
  if [[ "${SCENARIO}" == "todo_fragment" ]]; then
    path="${TODO_ENDPOINT}"
    ready_path="${TODO_READY_ENDPOINT}"
  fi
  local url="http://127.0.0.1:${port}${path}"
  local ready_url="http://127.0.0.1:${port}${ready_path}"

  local db="/tmp/todo_linux_transport_${backend}_${STAMP}.db"
  rm -f "${db}" "${db}-wal" "${db}-shm"

  TODO_DB_PATH="${db}" \
  PORT="${port}" \
  TODO_LOG=0 \
  NIM_EXPRESS_PROFILE="${PROFILE}" \
  NIM_EXPRESS_WORKERS="${APP_WORKERS}" \
  NIM_EXPRESS_SCALE_MODE="${scale_mode}" \
  NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE="${NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE:-0}" \
  NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER="${NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER:-0}" \
  "${APP_BIN}" >"${run_dir}/server.log" 2>&1 &
  local server_pid=$!

  cleanup_server() {
    kill "${server_pid}" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      if ! kill -0 "${server_pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "${server_pid}" >/dev/null 2>&1; then
      kill -9 "${server_pid}" >/dev/null 2>&1 || true
    fi
    wait "${server_pid}" >/dev/null 2>&1 || true
  }
  trap cleanup_server RETURN

  local ready=0
  for _ in $(seq 1 120); do
    if curl -fsS "${ready_url}" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.1
  done
  if [[ "${ready}" != "1" ]]; then
    echo "status=failed" >"${run_dir}/summary.txt"
    echo "reason=server_not_ready" >>"${run_dir}/summary.txt"
    return 1
  fi

  if [[ "${SCENARIO}" == "todo_fragment" ]]; then
    seed_todos "${port}" || true
  fi

  wrk -t"${THREADS}" -c"${CONNS}" -d"${WARMUP}" "${url}" >/dev/null || true

  if ! wrk -t"${THREADS}" -c"${CONNS}" -d"${DURATION}" --latency "${url}" >"${run_dir}/wrk.txt" 2>&1; then
    echo "status=failed" >"${run_dir}/summary.txt"
    echo "reason=wrk_failed" >>"${run_dir}/summary.txt"
    return 1
  fi
  if ! assert_wrk_clean "${run_dir}/wrk.txt"; then
    echo "status=failed" >"${run_dir}/summary.txt"
    echo "reason=wrk_socket_or_status_errors" >>"${run_dir}/summary.txt"
    return 1
  fi

  if command -v perf >/dev/null 2>&1; then
    perf record -F 99 -g -p "${server_pid}" -o "${run_dir}/perf.data" -- sleep "${SAMPLE_SECONDS}" >/dev/null 2>&1 || true
    perf script -i "${run_dir}/perf.data" >"${run_dir}/perf.script" 2>/dev/null || true
    perf report --stdio --no-children --sort symbol -i "${run_dir}/perf.data" >"${run_dir}/perf_top.txt" 2>/dev/null || true
  fi

  local rps avg p50 p90 p99 requests transfer_sec socket_errors non_2xx
  rps="$(awk '/Requests\/sec:/ {print $2}' "${run_dir}/wrk.txt" | tail -1)"
  avg="$(awk '/Latency[[:space:]]+/ {print $2}' "${run_dir}/wrk.txt" | head -1)"
  p50="$(wrk_latency_percentile 50 "${run_dir}/wrk.txt")"
  p90="$(wrk_latency_percentile 90 "${run_dir}/wrk.txt")"
  p99="$(wrk_latency_percentile 99 "${run_dir}/wrk.txt")"
  requests="$(awk '/requests in/ {print $1}' "${run_dir}/wrk.txt" | tail -1)"
  transfer_sec="$(awk '/Transfer\/sec:/ {print $2}' "${run_dir}/wrk.txt" | tail -1)"
  socket_errors="$(grep -E 'Socket errors:' "${run_dir}/wrk.txt" | tail -1 | sed 's/^[[:space:]]*//')"
  non_2xx="$(awk -F: '/Non-2xx or 3xx responses:/ {gsub(/^[ \t]+/, "", $2); print $2}' "${run_dir}/wrk.txt" | tail -1)"

  [[ -z "${rps}" ]] && rps="n/a"
  [[ -z "${avg}" ]] && avg="n/a"
  [[ -z "${p50}" ]] && p50="n/a"
  [[ -z "${p90}" ]] && p90="n/a"
  [[ -z "${p99}" ]] && p99="n/a"
  [[ -z "${requests}" ]] && requests="n/a"
  [[ -z "${transfer_sec}" ]] && transfer_sec="n/a"
  [[ -z "${socket_errors}" ]] && socket_errors="none"
  [[ -z "${non_2xx}" ]] && non_2xx="0"

  {
    echo "status=ok"
    echo "backend=${backend}"
    echo "scenario=${SCENARIO}"
    echo "scale_mode=${scale_mode}"
    echo "app_workers=${APP_WORKERS}"
    echo "url=${url}"
    echo "rps=${rps}"
    echo "latency_avg=${avg}"
    echo "p50=${p50}"
    echo "p90=${p90}"
    echo "p99=${p99}"
    echo "requests=${requests}"
    echo "transfer_sec=${transfer_sec}"
    echo "socket_errors=${socket_errors}"
    echo "non_2xx_or_3xx=${non_2xx}"
    echo "git_sha=${GIT_SHA}"
    echo "git_dirty=${GIT_DIRTY}"
    echo "kernel=${KERNEL}"
    echo "machine=${MACHINE}"
    echo "cpu_model=${CPU_MODEL}"
    echo "docker_runtime=${DOCKER_RUNTIME}"
    echo "seccomp=${SECCOMP_MODE}"
    echo "seccomp_filters=${SECCOMP_FILTERS}"
    echo "cgroup_cpu_max=${CGROUP_CPU_MAX}"
    echo "cgroup_memory_max=${CGROUP_MEM_MAX}"
    echo "nim_version=${NIM_VERSION_LINE}"
    echo "cc_version=${CC_VERSION_LINE}"
    echo "wrk_version=${WRK_VERSION_LINE}"
    echo "liburing_version=${LIBURING_VERSION}"
    echo "native_opt=${NATIVE_OPT:-1}"
    echo "native_cflags=${NATIVE_CFLAGS}"
    echo "platform_cflags=${PLATFORM_CFLAGS}"
    echo "iouring_max_connections=${IOURING_MAX_CONNECTIONS}"
    echo "iouring_recv_buffers=${IOURING_RECV_BUFFERS}"
    echo "iouring_recv_buffer_size=${IOURING_RECV_BUFFER_SIZE}"
    echo "iouring_entries=${IOURING_ENTRIES}"
    echo "usockets_stamp=$(file_one_line "${USOCKETS_STAMP_FILE}")"
  } >"${run_dir}/summary.txt"

  trap - RETURN
  cleanup_server
  return 0
}

port="${PORT_BASE}"
declare -a report_rows=()
failures=0
for backend in ${BACKENDS}; do
  run_dir="${OUT_DIR}/${backend}"
  if run_backend "${backend}" "${port}"; then
    report_rows+=("${backend}|ok|$(awk -F= '/^rps=/{print $2}' "${run_dir}/summary.txt")|$(awk -F= '/^latency_avg=/{print $2}' "${run_dir}/summary.txt")|$(awk -F= '/^p50=/{print $2}' "${run_dir}/summary.txt")|$(awk -F= '/^p90=/{print $2}' "${run_dir}/summary.txt")|$(awk -F= '/^p99=/{print $2}' "${run_dir}/summary.txt")|-")
  else
    failures=$((failures + 1))
    reason="$(awk -F= '/^reason=/{print $2}' "${run_dir}/summary.txt" 2>/dev/null | tail -1)"
    [[ -z "${reason}" ]] && reason="unknown"
    report_rows+=("${backend}|failed|n/a|n/a|n/a|n/a|n/a|${reason}")
  fi
  port=$((port + 1))
done

{
  echo "# Linux Transport Benchmark"
  echo
  echo "- timestamp: ${STAMP}"
  echo "- profile: ${PROFILE}"
  echo "- scenario: ${SCENARIO}"
  if [[ "${SCENARIO}" == "hotpath" ]]; then
    echo "- app: benchmark/bench_nim_express.nim"
    echo "- endpoint: ${HOTPATH_ENDPOINT}"
  else
    echo "- app: examples/todo_sqlite_mvc_app.nim"
    echo "- endpoint: ${TODO_ENDPOINT}"
    echo "- readiness endpoint: ${TODO_READY_ENDPOINT}"
    echo "- seed: ${SEED}"
  fi
  echo "- backends: ${BACKENDS}"
  echo "- epoll_exclusive: ${NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE:-0}"
  echo "- epoll_edge_trigger: ${NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER:-0}"
  echo "- duration: ${DURATION}"
  echo "- wrk threads: ${THREADS}"
  echo "- connections: ${CONNS}"
  echo "- app_workers: ${APP_WORKERS}"
  echo "- app_scale_mode: ${APP_SCALE_MODE:-auto}"
  echo "- git_sha: ${GIT_SHA}"
  echo "- git_dirty: ${GIT_DIRTY}"
  echo "- kernel: ${KERNEL}"
  echo "- machine: ${MACHINE}"
  echo "- cpu: ${CPU_MODEL}"
  echo "- docker_runtime: ${DOCKER_RUNTIME}"
  echo "- seccomp: ${SECCOMP_MODE}"
  echo "- seccomp_filters: ${SECCOMP_FILTERS}"
  echo "- cgroup_cpu_max: ${CGROUP_CPU_MAX}"
  echo "- cgroup_memory_max: ${CGROUP_MEM_MAX}"
  echo "- nim: ${NIM_VERSION_LINE}"
  echo "- cc: ${CC_VERSION_LINE}"
  echo "- wrk: ${WRK_VERSION_LINE}"
  echo "- liburing: ${LIBURING_VERSION}"
  echo "- native_opt: ${NATIVE_OPT:-1}"
  echo "- native_cflags: ${NATIVE_CFLAGS}"
  echo "- platform_cflags: ${PLATFORM_CFLAGS}"
  echo "- iouring_max_connections: ${IOURING_MAX_CONNECTIONS}"
  echo "- iouring_recv_buffers: ${IOURING_RECV_BUFFERS}"
  echo "- iouring_recv_buffer_size: ${IOURING_RECV_BUFFER_SIZE}"
  echo "- iouring_entries: ${IOURING_ENTRIES}"
  echo
  echo "Use \`SCENARIO=todo_fragment\` for the SQLite/template application endpoint. Set \`TODO_ENDPOINT=/todos/fragment?mode=full\` to measure the explicit full-list path. The default \`hotpath\` scenario is the transport/framework ceiling and is the comparable path for historical lightweight req/s numbers. io_uring defaults to cluster scale mode because each worker process owns its own io_uring loop; override with \`APP_SCALE_MODE=\` only when intentionally testing another mode."
  echo
  echo "| backend | status | scale | workers | req/s | avg latency | p50 | p90 | p99 | reason |"
  echo "|---|---|---|---:|---:|---:|---:|---:|---:|---|"
  for row in "${report_rows[@]}"; do
    IFS='|' read -r backend status rps avg p50 p90 p99 reason <<<"${row}"
    summary_file="${OUT_DIR}/${backend}/summary.txt"
    scale="$(awk -F= '/^scale_mode=/{print $2}' "${summary_file}" 2>/dev/null | tail -1)"
    workers="$(awk -F= '/^app_workers=/{print $2}' "${summary_file}" 2>/dev/null | tail -1)"
    [[ -z "${scale}" ]] && scale="n/a"
    [[ -z "${workers}" ]] && workers="n/a"
    echo "| ${backend} | ${status} | ${scale} | ${workers} | ${rps} | ${avg} | ${p50} | ${p90} | ${p99} | ${reason} |"
  done
  echo
  echo "## Artifacts"
  echo
  echo "- Per-backend output under: \`${OUT_DIR}/<backend>/\`"
  echo "- wrk output: \`wrk.txt\`"
  echo "- perf capture (when available): \`perf.data\`, \`perf.script\`, \`perf_top.txt\`"
} >"${OUT_DIR}/report.md"

echo "[linux-ceiling] report: ${OUT_DIR}/report.md"
cat "${OUT_DIR}/report.md"
if [[ "${failures}" -ne 0 ]]; then
  exit 1
fi
