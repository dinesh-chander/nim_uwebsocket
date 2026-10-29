#!/usr/bin/env bash
set -eu

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIM="${NIM:-nim}"
NIMCACHE_ROOT="${NIMCACHE_ROOT:-/tmp/nim_uwebsocket_verify}"
TEST_BIN_ROOT="$NIMCACHE_ROOT/bin"
NIM_EXTRA_FLAGS="${NIM_EXTRA_FLAGS:-}"
EXTRA_FLAGS=()
if [ -n "$NIM_EXTRA_FLAGS" ]; then
  # shellcheck disable=SC2206
  EXTRA_FLAGS=($NIM_EXTRA_FLAGS)
fi

run_nim() {
  echo "+ $*"
  "$@"
}

check_sources() {
  package="$1"
  shift
  src_dir="$ROOT_DIR/$package/src"
  idx=0
  find "$src_dir" -name '*.nim' -type f | sort | while IFS= read -r src; do
    idx=$((idx + 1))
    run_nim "$NIM" check --warnings:on --hints:on --styleCheck:hint \
      --nimcache:"$NIMCACHE_ROOT/check_${package}_$idx" "$@" "$src"
  done
}

run_tests_in_dir() {
  label="$1"
  test_dir="$2"
  shift 2
  idx=0
  mkdir -p "$TEST_BIN_ROOT"
  find "$test_dir" -maxdepth 1 -name 'test_*.nim' -type f | sort | while IFS= read -r test_file; do
    case "$(basename "$test_file")" in
      test_h2_live_server.nim|test_ws_live_server.nim)
        echo "+ skip manual live server fixture $test_file"
        continue
        ;;
    esac
    idx=$((idx + 1))
    base="$(basename "$test_file" .nim)"
    run_nim "$NIM" c --run --nimcache:"$NIMCACHE_ROOT/test_${label}_$idx" \
      -o:"$TEST_BIN_ROOT/${label}_${idx}_${base}" "$@" "$test_file"
  done
}

run_tests() {
  package="$1"
  shift
  run_tests_in_dir "$package" "$ROOT_DIR/$package/tests" "$@"
}

doc_project() {
  package="$1"
  entry="$2"
  shift 2
  out_dir="$ROOT_DIR/docs/api/$package"
  mkdir -p "$out_dir"
  doc_log="$NIMCACHE_ROOT/doc_${package}.log"
  echo "+ $NIM doc --project --outdir:$out_dir --nimcache:$NIMCACHE_ROOT/doc_$package $* $ROOT_DIR/$entry"
  set +e
  "$NIM" doc --project --outdir:"$out_dir" --nimcache:"$NIMCACHE_ROOT/doc_$package" "$@" "$ROOT_DIR/$entry" >"$doc_log" 2>&1
  doc_status=$?
  set -e
  cat "$doc_log"
  if [ "$doc_status" -eq 0 ]; then
    return 0
  fi
  if grep -q 'tools/dochack/dochack.nim' "$doc_log"; then
    echo "+ html docs skipped for $package: Nim toolchain is missing tools/dochack/dochack.nim"
    run_nim "$NIM" jsondoc --out:"$out_dir/$package.json" --nimcache:"$NIMCACHE_ROOT/jsondoc_$package" "$@" "$ROOT_DIR/$entry"
    return 0
  fi
  return "$doc_status"
}

mkdir -p "$NIMCACHE_ROOT" "$TEST_BIN_ROOT"

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

check_sources nim_utils "${COMMON_PATHS[@]}"
check_sources nim_usockets "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -d:nimUwebsocketsTest
check_sources nim_fasthttpclient "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}
check_sources nim_express "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}

run_tests nim_utils "${COMMON_PATHS[@]}"
run_tests_in_dir nim_utils_nim_fastjson "$ROOT_DIR/nim_utils/nim_fastjson/tests" "${COMMON_PATHS[@]}"
run_tests nim_usockets "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -d:nimUwebsocketsTest
run_tests nim_fasthttpclient "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}
run_nim "$NIM" c --run --nimcache:"$NIMCACHE_ROOT/test_nim_fasthttpclient_gated_client" \
  -o:"$TEST_BIN_ROOT/nim_fasthttpclient_gated_client" \
  "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -d:nimFastHttpClientTest "$ROOT_DIR/nim_fasthttpclient/tests/test_client.nim"
run_tests nim_express "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}

doc_project nim_utils nim_utils/src/nim_utils.nim "${COMMON_PATHS[@]}"
doc_project nim_usockets nim_usockets/src/nim_usockets.nim "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -d:nimUwebsocketsTest
doc_project nim_fasthttpclient nim_fasthttpclient/src/nim_fasthttpclient.nim "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}
doc_project nim_express nim_express/src/nim_express.nim "${COMMON_PATHS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}
