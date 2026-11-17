#!/usr/bin/env bash
set -euo pipefail

# Cross-target compile check for macOS, runnable on any host.
#
# `nim check --os:macosx` type-checks both event-loop backends' code paths
# (LIBUS_USE_GCD) and every `when defined(macosx)` / non-x86 branch without a
# Mac or an Apple SDK. It cannot link, so it complements scripts/macos_smoke.sh
# (real build plus live smoke) instead of replacing it.
#
# Apple Silicon takes the portable (non-SSE2) branches that x86 Linux builds
# never compile, so arm64 is checked first and is not optional.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIM="${NIM:-nim}"
NIMCACHE_ROOT="${NIMCACHE_ROOT:-/tmp/nim_uwebsocket_macos_target_check}"

COMMON_PATHS=(
  --path:"$ROOT_DIR/nim_utils/src"
  --path:"$ROOT_DIR/nim_usockets/src"
  --path:"$ROOT_DIR/nim_fasthttpclient/src"
  --path:"$ROOT_DIR/nim_express/src"
  --path:"$ROOT_DIR/vendor/zippy/src"
  --path:"$ROOT_DIR/vendor/brotli/src"
  --path:"$ROOT_DIR/vendor/nim_zstd"
  --path:"$ROOT_DIR/vendor/nim_libdeflate_gzip/src"
  --path:"$ROOT_DIR/vendor/malebolgia/src"
  --path:"$ROOT_DIR/vendor/jsony/src"
  --path:"$ROOT_DIR/vendor/checksums"
  --path:"$ROOT_DIR/vendor/nimsimd/src"
)

# GCD is the only supported macOS event loop; the define switches the Nim
# bindings onto the CoreFoundation/libdispatch code paths.
MACOS_FLAGS=(--os:macosx -d:LIBUS_USE_GCD)

run_check() {
  local name="$1"
  local cpu="$2"
  shift 2
  echo "+ macos-target check: ${name} (${cpu})"
  "$NIM" check "${MACOS_FLAGS[@]}" --cpu:"$cpu" --skipProjCfg:on --skipParentCfg:on \
    --hints:off --verbosity:0 --nimcache:"$NIMCACHE_ROOT/${name}_${cpu}" "$@"
}

mkdir -p "$NIMCACHE_ROOT"

for cpu in arm64 amd64; do
  run_check nim_utils "$cpu" "${COMMON_PATHS[@]}" "$ROOT_DIR/nim_utils/src/nim_utils.nim"
  run_check nim_usockets "$cpu" "${COMMON_PATHS[@]}" -d:nimUwebsocketsTest \
    "$ROOT_DIR/nim_usockets/src/nim_usockets.nim"
  run_check nim_fasthttpclient "$cpu" "${COMMON_PATHS[@]}" \
    "$ROOT_DIR/nim_fasthttpclient/src/nim_fasthttpclient.nim"
  run_check nim_express "$cpu" "${COMMON_PATHS[@]}" "$ROOT_DIR/nim_express/src/nim_express.nim"
  run_check websocketload "$cpu" "${COMMON_PATHS[@]}" "$ROOT_DIR/nim_websocketcli/websocketload.nim"
  run_check bench_nim_express "$cpu" "${COMMON_PATHS[@]}" "$ROOT_DIR/benchmark/bench_nim_express.nim"
  run_check showcase_app "$cpu" "${COMMON_PATHS[@]}" "$ROOT_DIR/examples/showcase_app.nim"
  run_check htmx_app "$cpu" "${COMMON_PATHS[@]}" "$ROOT_DIR/examples/htmx_app.nim"
done

# The live-server test is what scripts/macos_smoke.sh builds on a Mac; checking
# it here keeps its test-only hooks covered by the cross-target pass.
run_check ws_live_server arm64 "${COMMON_PATHS[@]}" -d:nimUwebsocketsTest \
  "$ROOT_DIR/nim_usockets/tests/test_ws_live_server.nim"

echo "macos-target check: PASS"
