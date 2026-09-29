#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIM_BIN="${NIM_BIN:-nim}"
USOCKETS_LIB="${USOCKETS_LIB:-$ROOT_DIR/nim_usockets/usockets/uSockets.a}"
JEMALLOC_LIBDIR="${JEMALLOC_LIBDIR:-/opt/homebrew/lib}"

LINK_FLAGS="$USOCKETS_LIB"
case "$(uname -s)" in
  Darwin)
    LINK_FLAGS="$LINK_FLAGS -framework CoreFoundation"
    ;;
  Linux)
    LINK_FLAGS="$LINK_FLAGS -lpthread -ldl"
    ;;
esac
if [[ -d "$JEMALLOC_LIBDIR" ]]; then
  LINK_FLAGS="$LINK_FLAGS -L$JEMALLOC_LIBDIR -ljemalloc"
fi

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
)

echo "[conformance-http] running nim_usockets parser/compliance suites"
(
  cd "$ROOT_DIR"
  "$NIM_BIN" c -r -d:nimUwebsocketsTest "${COMMON_PATHS[@]}" --passL:"$LINK_FLAGS" nim_usockets/tests/test_http_parser_framing_compliance.nim
  "$NIM_BIN" c -r -d:nimUwebsocketsTest "${COMMON_PATHS[@]}" --passL:"$LINK_FLAGS" nim_usockets/tests/test_http_parser_rfc_extended.nim
  "$NIM_BIN" c -r -d:nimUwebsocketsTest "${COMMON_PATHS[@]}" --passL:"$LINK_FLAGS" nim_usockets/tests/test_http_parser_property_fuzz_compliance.nim
  "$NIM_BIN" c -r -d:nimUwebsocketsTest "${COMMON_PATHS[@]}" --passL:"$LINK_FLAGS" nim_usockets/tests/test_http_ws_safety_regressions.nim
)

echo "[conformance-http] running nim_express surface/compliance suites"
(
  cd "$ROOT_DIR"
  "$NIM_BIN" c -r "${COMMON_PATHS[@]}" --passL:"$LINK_FLAGS" nim_express/tests/test_http_surface_compliance.nim
  "$NIM_BIN" c -r "${COMMON_PATHS[@]}" --passL:"$LINK_FLAGS" nim_express/tests/test_http_surface_compliance_extended.nim
)

echo "[conformance-http] all selected suites passed"
