#!/usr/bin/env bash
# Shared environment for all harness units (packages and middlewares).
# Usage: source this file from a unit's run.sh, then call harness_run_tests.
#
#   source "$ROOT_DIR/harness/common.sh"
#   harness_run_tests "rate_limit" -d: ... <test files...>
#
# Exits non-zero if any test fails. Prints a one-line summary per test and a
# final "HARNESS <label>: ok" / "HARNESS <label>: FAILED" line so agents can
# parse the gate result unambiguously.

set -u

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NIM="${NIM:-nim}"
HARNESS_CACHE_ROOT="${HARNESS_CACHE_ROOT:-/tmp/nim_harness_tests}"

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

# C backend for harness builds: clang (LLVM), matching the top-level Makefile.
# uSockets.a is built as clang LTO bitcode, so the final link must run LTO
# (-flto) or the archive symbols are unreadable ("file format not recognized").
COMMON_FLAGS=(--cc:clang --passL:"-flto")

# harness_run_tests <label> [extra nim flags...] -- <test file> [<test file>...]
# Everything after "--" is a test file. Flags before "--" are appended to the
# compile line (e.g. -d:nimUwebsocketsTest).
harness_run_tests() {
  local label="$1"; shift
  local -a extra=()
  while [ "$1" != "--" ]; do
    extra+=("$1"); shift
  done
  shift # drop "--"
  local -a files=("$@")

  local cache_dir="$HARNESS_CACHE_ROOT/$label"
  local bin_dir="$cache_dir/bin"
  mkdir -p "$cache_dir" "$bin_dir"

  local passed=0 failed=0 skipped=0 idx=0
  local base out
  for base in "${files[@]}"; do
    local f="$base"
    case "$f" in /*) : ;; *) f="$ROOT_DIR/$f" ;; esac
    [ -f "$f" ] || { echo "HARNESS $label: missing test file $base"; return 2; }
    local b; b="$(basename "$f" .nim)"
    case "$b" in
      test_h2_live_server|test_ws_live_server)
        echo "+ skip manual live server fixture $b"
        skipped=$((skipped + 1)); continue
        ;;
    esac
    idx=$((idx + 1))
    out="$bin_dir/${idx}_${b}"
    echo "+ $label/$b"
    if "$NIM" c --run --nimcache:"$cache_dir/nimcache_${idx}" -o:"$out" \
        "${COMMON_FLAGS[@]}" "${COMMON_PATHS[@]}" "${extra[@]}" "$f" >"$cache_dir/${idx}_${b}.log" 2>&1; then
      echo "  ok"
      passed=$((passed + 1))
    else
      echo "  FAILED (log: $cache_dir/${idx}_${b}.log)"
      tail -n 15 "$cache_dir/${idx}_${b}.log" | sed 's/^/    /'
      failed=$((failed + 1))
    fi
  done

  echo "HARNESS $label: $passed passed, $failed failed, $skipped skipped"
  [ "$failed" -eq 0 ]
}

# harness_nim_check <label> <extra flags> -- <nim files...>
# Compile-check only (no run). Gate for code that has no executable test.
harness_nim_check() {
  local label="$1"; shift
  local -a extra=()
  while [ "$1" != "--" ]; do
    extra+=("$1"); shift
  done
  shift
  local cache_dir="$HARNESS_CACHE_ROOT/check_$label"
  mkdir -p "$cache_dir"
  local failed=0 f b
  for f in "$@"; do
    case "$f" in /*) : ;; *) f="$ROOT_DIR/$f" ;; esac
    b="$(basename "$f" .nim)"
    echo "+ check $label/$b"
    if "$NIM" check --nimcache:"$cache_dir/nimcache_${b}" \
        "${COMMON_FLAGS[@]}" "${COMMON_PATHS[@]}" "${extra[@]}" "$f" >"$cache_dir/${b}.log" 2>&1; then
      echo "  ok"
    else
      echo "  FAILED (log: $cache_dir/${b}.log)"
      tail -n 10 "$cache_dir/${b}.log" | sed 's/^/    /'
      failed=$((failed + 1))
    fi
  done
  echo "HARNESS $label-check: $failed failed"
  [ "$failed" -eq 0 ]
}
