#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$BENCH_DIR/.." && pwd)"
USOCKETS_DIR="$ROOT_DIR/nim_usockets/usockets"
PGO_DIR="${PGO_DIR:-$BENCH_DIR/.pgo-data}"
NPROC="$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 4 )"
source "$BENCH_DIR/build_helpers.sh"
bench_set_common_paths "$ROOT_DIR"
NATIVE_CFLAGS="$(bench_native_cflags)"
USOCKETS_LINK_FLAGS="$(bench_platform_link_flags "../nim_usockets/usockets/uSockets.a")"

case "$(uname -s)" in
  Darwin)
    LOOP_FLAG="WITH_GCD=1"
    ;;
  Linux)
    LOOP_FLAG=""
    ;;
  *)
    echo "Unsupported platform for this script"
    exit 1
    ;;
esac

build_usockets() {
  local prof_flags="$1"
  pushd "$USOCKETS_DIR" >/dev/null
  make clean
  make -j"$NPROC" $LOOP_FLAG CFLAGS="$prof_flags"
  popd >/dev/null
}

build_nim_bench() {
  local stage="$1"
  local prof_flags="$2"
  local cache_dir="$PGO_DIR/nimcache_${stage}"
  pushd "$BENCH_DIR" >/dev/null
  rm -rf "$cache_dir"
  nim c -f --nimcache:"$cache_dir" -d:release -d:danger --opt:speed --hints:off \
    "${BENCH_COMMON_PATHS[@]}" \
    --passC:"-Ofast -flto $NATIVE_CFLAGS $prof_flags" \
    --passL:"$USOCKETS_LINK_FLAGS -flto $prof_flags" \
    -o:bench_nim_express_pgo bench_nim_express.nim
  popd >/dev/null
}

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required (brew install wrk / apt install wrk)."
  exit 1
fi

rm -rf "$PGO_DIR"
mkdir -p "$PGO_DIR"

echo "[1/4] Building instrumented uSockets + nim_express"
build_usockets "-fprofile-generate=$PGO_DIR"
build_nim_bench generate "-fprofile-generate=$PGO_DIR"

echo "[2/4] Running profiling workload"
pushd "$BENCH_DIR" >/dev/null
./bench_nim_express_pgo >/tmp/bench_nim_express_pgo_train.log 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
sleep 1.5
wrk -t4 -c200 -d20s http://127.0.0.1:3002/json >/dev/null
wrk -t4 -c200 -d20s http://127.0.0.1:3002/plaintext >/dev/null
kill "$PID" 2>/dev/null || true
trap - EXIT
popd >/dev/null

echo "[3/4] Rebuilding uSockets + nim_express with profile use"
build_usockets "-fprofile-use=$PGO_DIR -fprofile-correction -Wno-error=coverage-mismatch"
build_nim_bench use "-fprofile-use=$PGO_DIR -fprofile-correction -Wno-error=coverage-mismatch"

echo "[4/4] Done"
echo "Built binary: $BENCH_DIR/bench_nim_express_pgo"
