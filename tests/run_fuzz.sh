#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

NIM="${NIM:-nim}"
USOCKETS_LIB="nim_usockets/usockets/uSockets.a"
BIN_DIR="bin"

NIM_COMMON="--mm:arc --hints:off --panics:off --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src --path:nim_fasthttpclient/src --path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd --path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src --path:vendor/jsony/src --path:vendor/checksums"
case "$(uname -s)" in
  Darwin)
    LINK_FLAGS="$USOCKETS_LIB -framework CoreFoundation"
    ;;
  Linux)
    LINK_FLAGS="$USOCKETS_LIB -lpthread -ldl"
    ;;
  *)
    LINK_FLAGS="$USOCKETS_LIB"
    ;;
esac

mkdir -p "$BIN_DIR"

PASSED=0
FAILED=0
TOTAL=0

run_test() {
  local name="$1"
  local src="$2"
  local needs_usockets="${3:-no}"
  local extra_flags="${4:-}"
  TOTAL=$((TOTAL + 1))

  echo ""
  echo "========================================="
  echo "Building: $name"
  echo "========================================="

  local compile_cmd="$NIM c -d:release $NIM_COMMON"
  if [ "$needs_usockets" = "yes" ]; then
    compile_cmd="$compile_cmd --passL:\"$LINK_FLAGS\""
  fi
  if [ -n "$extra_flags" ]; then
    compile_cmd="$compile_cmd $extra_flags"
  fi
  compile_cmd="$compile_cmd -o:$BIN_DIR/$name $src"

  if ! eval "$compile_cmd"; then
    echo "COMPILE FAILED: $name"
    FAILED=$((FAILED + 1))
    return
  fi

  echo ""
  echo "Running: $name"
  echo "-----------------------------------------"

  if "$BIN_DIR/$name"; then
    echo "PASSED: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAILED: $name"
    FAILED=$((FAILED + 1))
  fi
}

echo "============================================"
echo "  Fuzz Test Suite"
echo "============================================"

run_test "fuzz_http_parser" "tests/fuzz_http_parser.nim" "yes" "-d:nimUwebsocketsTest"

run_test "fuzz_websocket" "tests/fuzz_websocket.nim" "yes"

run_test "fuzz_json_parser" "tests/fuzz_json_parser.nim" "no"

run_test "fuzz_fast_collections" "tests/fuzz_fast_collections.nim" "no"

run_test "fuzz_hpack" "tests/fuzz_hpack.nim" "no"

run_test "fuzz_h2_protocol" "tests/fuzz_h2_protocol.nim" "no"

run_test "fuzz_http1_client" "tests/fuzz_http1_client.nim" "no" "--path:nim_fasthttpclient/src"

run_test "fuzz_ws_client" "tests/fuzz_ws_client.nim" "no" "--path:nim_fasthttpclient/src"

run_test "fuzz_sse_client" "tests/fuzz_sse_client.nim" "no" "--path:nim_fasthttpclient/src"

run_test "fuzz_h2_server" "tests/fuzz_h2_server.nim" "no"

run_test "fuzz_h2_client" "tests/fuzz_h2_client.nim" "no" "--path:nim_fasthttpclient/src"

echo ""
echo "========================================="
echo "Building integration server..."
echo "========================================="
INTEG_SERVER_CMD="$NIM c -d:release $NIM_COMMON --passL:\"$LINK_FLAGS\" -o:$BIN_DIR/fuzz_integration_server tests/fuzz_integration_server.nim"
if eval "$INTEG_SERVER_CMD"; then
  run_test "fuzz_integration" "tests/fuzz_integration.nim" "no"
else
  echo "COMPILE FAILED: fuzz_integration_server (skipping integration tests)"
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
fi

echo ""
echo "============================================"
echo "  Results: $PASSED/$TOTAL passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
