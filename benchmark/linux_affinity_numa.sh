#!/usr/bin/env bash
set -euo pipefail

# Linux-only helper for process pinning and NUMA placement.
# Usage:
#   benchmark/linux_affinity_numa.sh ./benchmark/bench_nim_express
#   WORKERS=4 BASE_PORT=3002 benchmark/linux_affinity_numa.sh ./nim_express/bin/htmx_app

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script is Linux-only." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <binary> [args...]" >&2
  exit 1
fi

BIN="$1"
shift || true

if ! command -v numactl >/dev/null 2>&1; then
  echo "numactl not found. Install numactl first." >&2
  exit 1
fi

WORKERS="${WORKERS:-1}"
BASE_PORT="${BASE_PORT:-3002}"
CPU_LIST="${CPU_LIST:-}"
NUMA_NODE="${NUMA_NODE:-0}"

if [[ -z "$CPU_LIST" ]]; then
  CPU_LIST="0-$((WORKERS-1))"
fi

expand_cpu_list() {
  local input="$1"
  local out=()
  local part start end cpu
  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [[ -z "$part" ]] && continue
    if [[ "$part" == *-* ]]; then
      start="${part%-*}"
      end="${part#*-}"
      if [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]]; then
        if (( end < start )); then
          local tmp="$start"
          start="$end"
          end="$tmp"
        fi
        for ((cpu=start; cpu<=end; cpu++)); do
          out+=("$cpu")
        done
      fi
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      out+=("$part")
    fi
  done
  if (( ${#out[@]} == 0 )); then
    echo "invalid CPU_LIST: $input" >&2
    return 1
  fi
  printf '%s\n' "${out[@]}"
}

mapfile -t CPU_ARRAY < <(expand_cpu_list "$CPU_LIST")

echo "Launching with NUMA node ${NUMA_NODE}, CPU list ${CPU_LIST}, workers ${WORKERS}"

declare -a pids=()
for ((i=0; i<WORKERS; i++)); do
  PORT=$((BASE_PORT + i))
  CPU="${CPU_ARRAY[$((i % ${#CPU_ARRAY[@]}))]}"

  PORT="$PORT" numactl --cpunodebind="${NUMA_NODE}" --membind="${NUMA_NODE}" \
    taskset -c "${CPU}" "${BIN}" "$@" >/tmp/nim_affinity_${PORT}.log 2>&1 &
  pids+=("$!")
  echo "worker=${i} pid=${pids[-1]} cpu=${CPU} port=${PORT}"
done

cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

wait
