#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/benchmark/reports/template_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${OUT_DIR}"
source "${ROOT_DIR}/benchmark/build_helpers.sh"
bench_init_cold_build "${ROOT_DIR}" "${OUT_DIR}"
bench_set_common_paths "${ROOT_DIR}"

NIM_FLAGS="${NIM_FLAGS:--d:release --opt:speed --mm:arc}"
TEMPLATE_RENDER_MODE="${TEMPLATE_RENDER_MODE:-pairs}"

bench_rebuild_usockets "${OUT_DIR}/build_usockets.log"
USOCKETS_LINK_FLAGS="$(bench_platform_link_flags "${ROOT_DIR}/nim_usockets/usockets/uSockets.a")"
bench_nim template_pipeline c ${NIM_FLAGS} \
  "${BENCH_COMMON_PATHS[@]}" \
  --passL:"${USOCKETS_LINK_FLAGS}" \
  -o:"${OUT_DIR}/bench_template_pipeline" \
  "${ROOT_DIR}/benchmark/bench_template_pipeline.nim" \
  >"${OUT_DIR}/build.log" 2>&1

NIM_EXPRESS_TEMPLATE_RENDER_MODE="${TEMPLATE_RENDER_MODE}" \
  "${OUT_DIR}/bench_template_pipeline" | tee "${OUT_DIR}/result.txt"

echo "[template-bench] report: ${OUT_DIR}/result.txt"
