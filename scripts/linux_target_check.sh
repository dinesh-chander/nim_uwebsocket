#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIM="${NIM:-nim}"
NIMCACHE_ROOT="${NIMCACHE_ROOT:-/tmp/nim_uwebsocket_linux_target_check}"

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

run_check() {
  local name="$1"
  shift
  echo "+ linux-target check: ${name}"
  "$NIM" check --os:linux --cpu:amd64 --skipProjCfg:on --skipParentCfg:on \
    --hints:off --verbosity:0 --nimcache:"$NIMCACHE_ROOT/$name" "$@"
}

require_dry_run_contains() {
  local label="$1"
  local pattern="$2"
  shift 2
  local output
  echo "+ make dry-run: ${label}"
  output="$("$@" 2>&1)"
  if ! grep -q -- "$pattern" <<<"$output"; then
    echo "linux-target check failed: ${label} did not contain ${pattern}" >&2
    echo "$output" >&2
    exit 1
  fi
}

require_dry_run_not_contains() {
  local label="$1"
  local pattern="$2"
  shift 2
  local output
  echo "+ make dry-run negative: ${label}"
  output="$("$@" 2>&1)"
  if grep -q -- "$pattern" <<<"$output"; then
    echo "linux-target check failed: ${label} unexpectedly contained ${pattern}" >&2
    echo "$output" >&2
    exit 1
  fi
}

require_dry_run_fails() {
  local label="$1"
  shift
  local output_file="$NIMCACHE_ROOT/${label//[^A-Za-z0-9_]/_}.dryrun.txt"
  echo "+ make dry-run rejection: ${label}"
  if "$@" >"$output_file" 2>&1; then
    echo "linux-target check failed: ${label} unexpectedly succeeded" >&2
    cat "$output_file" >&2
    exit 1
  fi
}

mkdir -p "$NIMCACHE_ROOT"

run_check nim_utils "${COMMON_PATHS[@]}" "$ROOT_DIR/nim_utils/src/nim_utils.nim"
run_check nim_usockets "${COMMON_PATHS[@]}" -d:nimUwebsocketsTest "$ROOT_DIR/nim_usockets/src/nim_usockets.nim"
run_check nim_fasthttpclient "${COMMON_PATHS[@]}" "$ROOT_DIR/nim_fasthttpclient/src/nim_fasthttpclient.nim"
run_check nim_express "${COMMON_PATHS[@]}" "$ROOT_DIR/nim_express/src/nim_express.nim"
run_check websocketload "${COMMON_PATHS[@]}" "$ROOT_DIR/nim_websocketcli/websocketload.nim"
run_check linux_multiprocess --threads:on "${COMMON_PATHS[@]}" "$ROOT_DIR/examples/linux_multiprocess.nim"
run_check linux_multithreaded --threads:on "${COMMON_PATHS[@]}" "$ROOT_DIR/examples/linux_multithreaded.nim"
run_check linux_multiprocess_iouring --threads:on -d:LIBUS_USE_IO_URING "${COMMON_PATHS[@]}" "$ROOT_DIR/examples/linux_multiprocess.nim"
run_check linux_multithreaded_iouring --threads:on -d:LIBUS_USE_IO_URING "${COMMON_PATHS[@]}" "$ROOT_DIR/examples/linux_multithreaded.nim"

echo "+ linux-target config check: nim_usockets io_uring"
(
	  cd "$ROOT_DIR/nim_usockets"
	  "$NIM" check --os:linux --cpu:amd64 -d:LIBUS_USE_IO_URING --hints:off --verbosity:0 \
	    "${COMMON_PATHS[@]}" \
	    --nimcache:"$NIMCACHE_ROOT/nim_usockets_iouring" src/nim_usockets.nim
	)

echo "+ linux-target config check: nim_express io_uring"
(
	  cd "$ROOT_DIR/nim_express"
	  "$NIM" check --os:linux --cpu:amd64 -d:LIBUS_USE_IO_URING --hints:off --verbosity:0 \
	    "${COMMON_PATHS[@]}" \
	    --nimcache:"$NIMCACHE_ROOT/nim_express_iouring" src/nim_express.nim
	)

echo "+ linux-target config check: nim_fasthttpclient tests io_uring"
(
	  cd "$ROOT_DIR/nim_fasthttpclient/tests"
	  "$NIM" check --os:linux --cpu:amd64 -d:LIBUS_USE_IO_URING --hints:off --verbosity:0 \
	    "${COMMON_PATHS[@]}" \
	    --nimcache:"$NIMCACHE_ROOT/nim_fasthttpclient_tests_iouring" test_integration.nim
	)

require_dry_run_contains "Linux epoll bench links pthread/dl" "-lpthread -ldl" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Linux USOCKETS_BACKEND=epoll NATIVE_OPT=0 USE_PGO=0
require_dry_run_not_contains "Linux epoll bench omits liburing" "-luring" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Linux USOCKETS_BACKEND=epoll NATIVE_OPT=0 USE_PGO=0
require_dry_run_not_contains "Linux epoll bench omits io_uring defines" "LIBUS_USE_IO_URING" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Linux USOCKETS_BACKEND=epoll NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "Linux io_uring usockets build flag" "WITH_IO_URING=1" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Linux USOCKETS_BACKEND=io_uring NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "Linux io_uring C define" "-DLIBUS_USE_IO_URING" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Linux USOCKETS_BACKEND=io_uring NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "Linux io_uring Nim define" "-d:LIBUS_USE_IO_URING" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Linux USOCKETS_BACKEND=io_uring NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "Linux io_uring bench links liburing" "-luring" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Linux USOCKETS_BACKEND=io_uring NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "Darwin GCD usockets build flag" "WITH_GCD=1" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Darwin USOCKETS_BACKEND=gcd NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "Darwin GCD Nim define" "-d:LIBUS_USE_GCD" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Darwin USOCKETS_BACKEND=gcd NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "Darwin GCD CoreFoundation link" "-framework CoreFoundation" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Darwin USOCKETS_BACKEND=gcd NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "Darwin kqueue aliases to GCD" "WITH_GCD=1" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Darwin USOCKETS_BACKEND=kqueue NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "WebSocket random object bench target exists" "ws_random_object_bench.nim" \
  make -C "$ROOT_DIR" -n ws-random-object-bench UNAME_S=Linux USOCKETS_BACKEND=epoll NATIVE_OPT=0 USE_PGO=0
require_dry_run_contains "uSockets backend stamp is written" ".uSockets.backend" \
  make -C "$ROOT_DIR" -n usockets UNAME_S=Linux USOCKETS_BACKEND=io_uring NATIVE_OPT=0 USE_PGO=0

require_dry_run_fails "Linux rejects gcd backend" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Linux USOCKETS_BACKEND=gcd NATIVE_OPT=0
require_dry_run_fails "Linux rejects kqueue backend" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Linux USOCKETS_BACKEND=kqueue NATIVE_OPT=0
require_dry_run_fails "Darwin rejects epoll backend" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Darwin USOCKETS_BACKEND=epoll NATIVE_OPT=0
require_dry_run_fails "Darwin rejects io_uring backend" \
  make -C "$ROOT_DIR" -n bench UNAME_S=Darwin USOCKETS_BACKEND=io_uring NATIVE_OPT=0

bash -n \
  "$ROOT_DIR/scripts/ensure_deps.sh" \
  "$ROOT_DIR/scripts/linux_smoke.sh" \
  "$ROOT_DIR/tests/run_fuzz.sh" \
  "$ROOT_DIR/benchmark/build_helpers.sh" \
  "$ROOT_DIR/benchmark/build_nim_express_pgo.sh" \
  "$ROOT_DIR/benchmark/run_http_conformance_pack.sh" \
  "$ROOT_DIR/benchmark/run_linux_single_process.sh" \
  "$ROOT_DIR/benchmark/run_linux_transport_ceiling.sh"

python3 -m py_compile "$ROOT_DIR/scripts/run_http_compliance_iterations.py"

grep -q 'make -C "${ROOT_DIR}" usockets' "$ROOT_DIR/benchmark/run_linux_transport_ceiling.sh" || {
  echo "linux-target check failed: transport ceiling script must use top-level make usockets" >&2
  exit 1
}
grep -q 'USOCKETS_STAMP' "$ROOT_DIR/Makefile" || {
  echo "linux-target check failed: Makefile must stamp uSockets backend builds" >&2
  exit 1
}

echo "linux-target check: PASS"
