#!/usr/bin/env bash
set -eu

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIM="${NIM:-nim}"
NIMCACHE_ROOT="${NIMCACHE_ROOT:-/tmp/nim_uwebsocket_tests}"
TEST_BIN_ROOT="$NIMCACHE_ROOT/bin"
NIM_EXTRA_FLAGS="${NIM_EXTRA_FLAGS:-}"
EXTRA_FLAGS=()
if [ -n "$NIM_EXTRA_FLAGS" ]; then
  # shellcheck disable=SC2206
  EXTRA_FLAGS=($NIM_EXTRA_FLAGS)
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

mkdir -p "$NIMCACHE_ROOT" "$TEST_BIN_ROOT"

run_test_dir() {
  label="$1"
  test_dir="$2"
  shift 2
  idx=0
  find "$test_dir" -maxdepth 1 -name 'test_*.nim' -type f | sort | while IFS= read -r test_file; do
    case "$(basename "$test_file")" in
      test_h2_live_server.nim|test_ws_live_server.nim)
        echo "+ skip manual live server fixture $test_file"
        continue
        ;;
    esac
    idx=$((idx + 1))
    base="$(basename "$test_file" .nim)"
    echo "+ $label/$base"
    "$NIM" c --run --nimcache:"$NIMCACHE_ROOT/${label}_${idx}" \
      -o:"$TEST_BIN_ROOT/${label}_${idx}_${base}" "$@" "$test_file"
  done
}

run_test_dir nim_utils "$ROOT_DIR/nim_utils/tests" "${COMMON_PATHS[@]}"
run_test_dir nim_fastjson "$ROOT_DIR/nim_utils/src/nim_utils/nim_fastjson/tests" "${COMMON_PATHS[@]}"
run_test_dir nim_usockets "$ROOT_DIR/nim_usockets/tests" "${COMMON_PATHS[@]}" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" -d:nimUwebsocketsTest
run_test_dir nim_fasthttpclient "$ROOT_DIR/nim_fasthttpclient/tests" "${COMMON_PATHS[@]}" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
"$NIM" c --run --nimcache:"$NIMCACHE_ROOT/nim_fasthttpclient_gated_client" \
  -o:"$TEST_BIN_ROOT/nim_fasthttpclient_gated_client" \
  "${COMMON_PATHS[@]}" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" -d:nimFastHttpClientTest "$ROOT_DIR/nim_fasthttpclient/tests/test_client.nim"
run_test_dir nim_express "$ROOT_DIR/nim_express/tests" "${COMMON_PATHS[@]}" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"
