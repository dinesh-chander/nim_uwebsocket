#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_SCRIPT="${ROOT_DIR}/benchmark/run_linux_transport_ceiling.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "run_linux_transport_knob_matrix.sh must run on Linux." >&2
  exit 1
fi

POLICIES="${POLICIES:-baseline exclusive edge exclusive_edge}"
BACKENDS="${BACKENDS:-epoll}"

for policy in ${POLICIES}; do
  case "${policy}" in
    baseline)
      export NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE=0
      export NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER=0
      ;;
    exclusive)
      export NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE=1
      export NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER=0
      ;;
    edge)
      export NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE=0
      export NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER=1
      ;;
    exclusive_edge)
      export NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE=1
      export NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER=1
      ;;
    *)
      echo "unknown policy: ${policy}" >&2
      exit 1
      ;;
  esac

  echo "[knob-matrix] policy=${policy} backends=${BACKENDS}"
  BACKENDS="${BACKENDS}" "${BASE_SCRIPT}"
done
