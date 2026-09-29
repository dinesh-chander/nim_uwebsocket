#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Resolve Linux scaling layout knobs for nim_express docs.

Supported environment knobs:
  NIM_EXPRESS_PROFILE          (default: linux-throughput, allowed: "", linux-throughput)
  NIM_EXPRESS_SCALE_MODE       (default: cluster, allowed: auto|cluster|threaded)
  NIM_EXPRESS_WORKERS          (default: 0, non-negative integer; 0 => 40% CPU default)
  NIM_EXPRESS_THREADS          (default: 0, non-negative integer; 0 => 40% CPU default)
  NIM_EXPRESS_BASE_PORT        (default: 3002, non-negative integer)
  NIM_EXPRESS_CPU_LIST         (default: computed 0-(workers-1), format: 0-7 or 0,2,4-6)
  NIM_EXPRESS_NUMA_NODE        (default: 0, non-negative integer)
  NIM_EXPRESS_CPU_COUNT_OVERRIDE (optional, docs/testing helper)
  NIM_EXPRESS_DOCS_ALLOW_NON_LINUX=1 to run outside Linux for docs/testing.

Example:
  NIM_EXPRESS_WORKERS=8 NIM_EXPRESS_CPU_LIST=0-7 ./nim_express/docs/scripts/linux_scaling_layout.sh
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_nonneg_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "${name} must be a non-negative integer, got '${value}'"
}

detect_cpu_count() {
  if [[ -n "${NIM_EXPRESS_CPU_COUNT_OVERRIDE:-}" ]]; then
    require_nonneg_int "NIM_EXPRESS_CPU_COUNT_OVERRIDE" "${NIM_EXPRESS_CPU_COUNT_OVERRIDE}"
    if (( NIM_EXPRESS_CPU_COUNT_OVERRIDE == 0 )); then
      fail "NIM_EXPRESS_CPU_COUNT_OVERRIDE must be >= 1"
    fi
    echo "${NIM_EXPRESS_CPU_COUNT_OVERRIDE}"
    return
  fi

  if command -v nproc >/dev/null 2>&1; then
    nproc
    return
  fi

  if command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
    return
  fi

  echo "1"
}

default_worker_count() {
  local cpu_count="$1"
  local workers=$(( cpu_count * 40 / 100 ))
  if (( workers < 1 )); then
    workers=1
  fi
  echo "${workers}"
}

expand_cpu_list() {
  local raw="$1"
  local token
  local start
  local stop
  local i
  local -a expanded=()
  local -a tokens=()

  IFS=',' read -r -a tokens <<< "${raw}"
  for token in "${tokens[@]}"; do
    token="${token//[[:space:]]/}"
    [[ -n "${token}" ]] || continue

    if [[ "${token}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      stop="${BASH_REMATCH[2]}"
      if (( stop < start )); then
        fail "invalid CPU range '${token}'"
      fi
      for ((i=start; i<=stop; i++)); do
        expanded+=("${i}")
      done
    elif [[ "${token}" =~ ^[0-9]+$ ]]; then
      expanded+=("${token}")
    else
      fail "invalid CPU token '${token}' in NIM_EXPRESS_CPU_LIST"
    fi
  done

  if (( ${#expanded[@]} == 0 )); then
    fail "NIM_EXPRESS_CPU_LIST expands to empty set"
  fi

  printf '%s\n' "${expanded[@]}"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ "${NIM_EXPRESS_DOCS_ALLOW_NON_LINUX:-0}" != "1" ]] && [[ "$(uname -s)" != "Linux" ]]; then
    fail "this helper is Linux-only (set NIM_EXPRESS_DOCS_ALLOW_NON_LINUX=1 for docs/testing)"
  fi

  local profile="${NIM_EXPRESS_PROFILE:-linux-throughput}"
  local scale_mode="${NIM_EXPRESS_SCALE_MODE:-cluster}"
  local workers_raw="${NIM_EXPRESS_WORKERS:-0}"
  local threads_raw="${NIM_EXPRESS_THREADS:-0}"
  local base_port_raw="${NIM_EXPRESS_BASE_PORT:-3002}"
  local cpu_list_raw="${NIM_EXPRESS_CPU_LIST:-}"
  local numa_node_raw="${NIM_EXPRESS_NUMA_NODE:-0}"

  case "${profile}" in
    ""|linux-throughput) ;;
    *) fail "NIM_EXPRESS_PROFILE must be empty or linux-throughput, got '${profile}'" ;;
  esac

  case "${scale_mode}" in
    auto|cluster|threaded) ;;
    *) fail "NIM_EXPRESS_SCALE_MODE must be auto|cluster|threaded, got '${scale_mode}'" ;;
  esac

  require_nonneg_int "NIM_EXPRESS_WORKERS" "${workers_raw}"
  require_nonneg_int "NIM_EXPRESS_THREADS" "${threads_raw}"
  require_nonneg_int "NIM_EXPRESS_BASE_PORT" "${base_port_raw}"
  require_nonneg_int "NIM_EXPRESS_NUMA_NODE" "${numa_node_raw}"

  local cpu_count
  cpu_count="$(detect_cpu_count)"

  local workers="${workers_raw}"
  if (( workers == 0 )); then
    workers="$(default_worker_count "${cpu_count}")"
  fi

  local threads="${threads_raw}"
  if (( threads == 0 )); then
    threads="$(default_worker_count "${cpu_count}")"
  fi

  if [[ -z "${cpu_list_raw}" ]]; then
    cpu_list_raw="0-$((workers - 1))"
  fi

  local -a cpus=()
  mapfile -t cpus < <(expand_cpu_list "${cpu_list_raw}")

  echo "profile=${profile}"
  echo "scale_mode=${scale_mode}"
  echo "workers=${workers}"
  echo "threads=${threads}"
  echo "base_port=${base_port_raw}"
  echo "numa_node=${numa_node_raw}"
  echo "cpu_list=${cpu_list_raw}"
  echo "cpu_count_detected=${cpu_count}"

  local i
  local port
  local cpu_index
  local cpu
  for ((i=0; i<workers; i++)); do
    port=$((base_port_raw + i))
    cpu_index=$((i % ${#cpus[@]}))
    cpu="${cpus[$cpu_index]}"
    echo "worker[${i}]=port:${port},cpu:${cpu},numa:${numa_node_raw}"
  done

  echo "affinity_env=WORKERS=${workers} BASE_PORT=${base_port_raw} CPU_LIST=${cpu_list_raw} NUMA_NODE=${numa_node_raw}"
}

main "${@:-}"
