#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_PATH="${DOCS_DIR}/scripts/linux_scaling_layout.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail "expected output to contain '${needle}'"
  fi
}

assert_fails() {
  local expected="$1"
  shift
  local out
  set +e
  out="$("$@" 2>&1)"
  local code=$?
  set -e
  if (( code == 0 )); then
    fail "expected command to fail"
  fi
  assert_contains "${out}" "${expected}"
}

test_default_worker_sizing() {
  local out
out="$(
    NIM_EXPRESS_DOCS_ALLOW_NON_LINUX=1 \
    NIM_EXPRESS_CPU_COUNT_OVERRIDE=10 \
    env bash "${SCRIPT_PATH}"
  )"

  assert_contains "${out}" "workers=4"
  assert_contains "${out}" "threads=4"
  assert_contains "${out}" "base_port=3002"
  assert_contains "${out}" "worker[0]=port:3002,cpu:0,numa:0"
  assert_contains "${out}" "worker[3]=port:3005,cpu:3,numa:0"
}

test_explicit_knobs_and_cpu_range_expansion() {
  local out
out="$(
    NIM_EXPRESS_DOCS_ALLOW_NON_LINUX=1 \
    NIM_EXPRESS_WORKERS=3 \
    NIM_EXPRESS_THREADS=2 \
    NIM_EXPRESS_BASE_PORT=4000 \
    NIM_EXPRESS_CPU_LIST=2,4-5 \
    NIM_EXPRESS_NUMA_NODE=1 \
    NIM_EXPRESS_SCALE_MODE=cluster \
    NIM_EXPRESS_PROFILE=linux-throughput \
    env bash "${SCRIPT_PATH}"
  )"

  assert_contains "${out}" "workers=3"
  assert_contains "${out}" "threads=2"
  assert_contains "${out}" "cpu_list=2,4-5"
  assert_contains "${out}" "worker[0]=port:4000,cpu:2,numa:1"
  assert_contains "${out}" "worker[1]=port:4001,cpu:4,numa:1"
  assert_contains "${out}" "worker[2]=port:4002,cpu:5,numa:1"
}

test_invalid_knobs() {
  assert_fails "NIM_EXPRESS_WORKERS must be a non-negative integer" \
    env NIM_EXPRESS_DOCS_ALLOW_NON_LINUX=1 NIM_EXPRESS_WORKERS=abc bash "${SCRIPT_PATH}"

  assert_fails "invalid CPU token" \
    env NIM_EXPRESS_DOCS_ALLOW_NON_LINUX=1 NIM_EXPRESS_CPU_LIST=0,a bash "${SCRIPT_PATH}"

  assert_fails "NIM_EXPRESS_SCALE_MODE must be auto|cluster|threaded" \
    env NIM_EXPRESS_DOCS_ALLOW_NON_LINUX=1 NIM_EXPRESS_SCALE_MODE=bad bash "${SCRIPT_PATH}"

  assert_fails "NIM_EXPRESS_PROFILE must be empty or linux-throughput" \
    env NIM_EXPRESS_DOCS_ALLOW_NON_LINUX=1 NIM_EXPRESS_PROFILE=fast bash "${SCRIPT_PATH}"
}

test_linux_guard() {
  if [[ "$(uname -s)" == "Linux" ]]; then
    return
  fi

  assert_fails "this helper is Linux-only" bash "${SCRIPT_PATH}"
}

main() {
  test_default_worker_sizing
  test_explicit_knobs_and_cpu_range_expansion
  test_invalid_knobs
  test_linux_guard
  echo "ok: linux scaling layout knob parsing tests passed"
}

main "$@"
