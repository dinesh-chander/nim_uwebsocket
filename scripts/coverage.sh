#!/usr/bin/env bash
#
# scripts/coverage.sh — LLVM source-level coverage for the Nim test suite.
#
# Mirrors scripts/test_all.sh discovery/flags (same five run_test_dir groups,
# same skips, same gated test_client.nim, same --path list). Each test is
# compiled with clang source-based coverage flags, run with LLVM_PROFILE_FILE
# so its .profraw lands next to the binary, then profiles are merged and
# reports are emitted:
#
#   COVERAGE_OUT/coverage.txt   llvm-cov report per binary (one section each)
#   COVERAGE_OUT/html/<bin>/    llvm-cov HTML export per binary
#   COVERAGE_OUT/summary.md     per-package line coverage + top 20
#                               least-covered files + failed tests
#
# Knobs (environment variables):
#   COVERAGE_FILTER   substring match on test filenames (default: empty = all)
#   COVERAGE_OUT      output directory (default: <repo root>/coverage)
#   NIM               nim binary (default: nim)
#   NIM_EXTRA_FLAGS   extra nim flags, same semantics as test_all.sh
#   COVERAGE_JOBS     parallel compile workers (default: nproc)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIM="${NIM:-nim}"
COVERAGE_FILTER="${COVERAGE_FILTER:-}"
COVERAGE_OUT="${COVERAGE_OUT:-$ROOT_DIR/coverage}"
NIM_EXTRA_FLAGS="${NIM_EXTRA_FLAGS:-}"
JOBS="${COVERAGE_JOBS:-$(nproc)}"

# Clang 23 requires the full -fprofile-instr-generate spelling.
COV_CFLAGS="-fprofile-instr-generate -fcoverage-mapping"
COV_LFLAGS="-fprofile-instr-generate -fcoverage-mapping"

BIN_DIR="$COVERAGE_OUT/bin"
CACHE_DIR="$COVERAGE_OUT/cache"
LOG_DIR="$COVERAGE_OUT/logs"
REPORT_DIR="$COVERAGE_OUT/reports"
HTML_DIR="$COVERAGE_OUT/html"
MERGED="$COVERAGE_OUT/merged.profdata"
BUILD_FAILURES="$COVERAGE_OUT/build_failures.txt"
FAILED_TESTS="$COVERAGE_OUT/failed_tests.txt"

command -v "$NIM" >/dev/null 2>&1 || { echo "error: $NIM not found on PATH" >&2; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "error: clang not found on PATH" >&2; exit 1; }
command -v llvm-profdata >/dev/null 2>&1 || { echo "error: llvm-profdata not found on PATH" >&2; exit 1; }
command -v llvm-cov >/dev/null 2>&1 || { echo "error: llvm-cov not found on PATH" >&2; exit 1; }

mkdir -p "$BIN_DIR" "$CACHE_DIR" "$LOG_DIR" "$REPORT_DIR" "$HTML_DIR"

# Same --path list as scripts/test_all.sh
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
# Bash arrays do NOT survive `export` into xargs child shells (the child sees
# an empty array), so pass the flags as a newline-separated string and split
# them in build_one. Paths never contain newlines or spaces.
COMMON_PATHS_NL="$(printf '%s\n' "${COMMON_PATHS[@]}")"

# ---------------------------------------------------------------- discovery

MANIFEST=()

# add_test_dir <label> <test_dir>: one manifest entry per test_*.nim,
# same skip list and sort order as test_all.sh.
add_test_dir() {
  local label="$1" test_dir="$2"
  local idx=0 test_file
  while IFS= read -r test_file; do
    case "$(basename "$test_file")" in
      test_h2_live_server.nim|test_ws_live_server.nim)
        echo "+ skip manual live server fixture $test_file"
        continue
        ;;
    esac
    if [ -n "$COVERAGE_FILTER" ]; then
      case "$(basename "$test_file")" in
        *"$COVERAGE_FILTER"*) ;;
        *) continue ;;
      esac
    fi
    idx=$((idx + 1))
    MANIFEST+=("$(printf '%s\t%s\t%s' "$idx" "$label" "$test_file")")
  done < <(find "$test_dir" -maxdepth 1 -name 'test_*.nim' -type f | sort)
}

add_test_dir nim_utils "$ROOT_DIR/nim_utils/tests"
add_test_dir nim_fastjson "$ROOT_DIR/nim_utils/src/nim_utils/nim_fastjson/tests"
add_test_dir nim_usockets "$ROOT_DIR/nim_usockets/tests"
add_test_dir nim_fasthttpclient "$ROOT_DIR/nim_fasthttpclient/tests"

# Gated client test, same as test_all.sh (separate job from the dir entry).
GATED_CLIENT="$ROOT_DIR/nim_fasthttpclient/tests/test_client.nim"
if [ -n "$COVERAGE_FILTER" ]; then
  case "$(basename "$GATED_CLIENT")" in *"$COVERAGE_FILTER"*) ;; *) GATED_CLIENT="" ;; esac
fi
if [ -n "$GATED_CLIENT" ]; then
  MANIFEST+=("$(printf '1\t%s\t%s' nim_fasthttpclient_gated_client "$GATED_CLIENT")")
fi

add_test_dir nim_express "$ROOT_DIR/nim_express/tests"

if [ "${#MANIFEST[@]}" -eq 0 ]; then
  echo "no tests matched COVERAGE_FILTER='${COVERAGE_FILTER}'; nothing to do"
  exit 0
fi
echo "coverage: ${#MANIFEST[@]} test binaries selected (filter='${COVERAGE_FILTER:-<all>}') -> $COVERAGE_OUT"

# ------------------------------------------- uSockets archive for clang/coverage
# The shared uSockets.a (built by the root Makefile) is compiled with -flto, so
# its archive members are GCC LTO objects. The clang driver used for coverage
# (clang + ld.bfd) does not load the LTO plugin for archive members, so linking
# it fails with `plugin needed to handle lto object` and
# `undefined reference to us_socket_write*' for every uSockets-dependent test.
# Workaround: build a non-LTO, coverage-instrumented archive from the same
# vendored sources into $COVERAGE_OUT and link it AFTER the config-anchored
# uSockets.a (that archive's LTO members are skipped with a warning; the
# symbols resolve from this one). The shared uSockets.a is left untouched.
# Incremental: rebuilt only when a vendored source is newer than the archive.
USOCKETS_DIR="$ROOT_DIR/nim_usockets/usockets"
USOCKETS_COV_A=""
if [ -f "$USOCKETS_DIR/src/socket.c" ]; then
  USOCKETS_COV_A="$COVERAGE_OUT/uSockets.cov.a"
  USOCKETS_COV_OBJDIR="$COVERAGE_OUT/usockets_obj"
  newest_src="$(find "$USOCKETS_DIR/src" -name '*.c' -newer "$USOCKETS_COV_A" -print -quit 2>/dev/null || true)"
  if [ ! -f "$USOCKETS_COV_A" ] || [ -n "$newest_src" ]; then
    echo "building non-LTO coverage-instrumented uSockets archive -> $USOCKETS_COV_A"
    mkdir -p "$USOCKETS_COV_OBJDIR"
    # Same source list and flags as the vendored usockets/Makefile default
    # target, minus -flto, plus the coverage instrumentation flags.
    for usrc in "$USOCKETS_DIR"/src/*.c "$USOCKETS_DIR"/src/eventing/*.c \
                "$USOCKETS_DIR"/src/crypto/*.c "$USOCKETS_DIR"/src/io_uring/*.c; do
      clang -std=c11 -I"$USOCKETS_DIR/src" -D_GNU_SOURCE -DLIBUS_NO_SSL -O3 \
        -fprofile-instr-generate -fcoverage-mapping \
        -c "$usrc" -o "$USOCKETS_COV_OBJDIR/$(basename "$usrc").o"
    done
    rm -f "$USOCKETS_COV_A"
    ar rcs "$USOCKETS_COV_A" "$USOCKETS_COV_OBJDIR"/*.o
  else
    echo "uSockets coverage archive up to date: $USOCKETS_COV_A"
  fi
fi

# ---------------------------------------------------------------- compile

# build_one <idx<TAB>label<TAB>file>: compile one test with coverage flags.
# Failures are recorded, never fatal (xargs keeps going).
build_one() {
  local job="$1"
  local idx label file base bin log
  local extra=() ex=()
  IFS=$'\t' read -r idx label file <<<"$job"
  local cpaths=()
  readarray -t cpaths <<<"$COMMON_PATHS_NL"
  base="$(basename "$file" .nim)"
  bin="$BIN_DIR/${label}_${idx}_${base}"
  log="$LOG_DIR/build_${label}_${idx}_${base}.log"
  case "$label" in
    nim_usockets) extra+=(-d:nimUwebsocketsTest) ;;
    nim_fasthttpclient_gated_client) extra+=(-d:nimFastHttpClientTest) ;;
  esac
  if [ -n "$NIM_EXTRA_FLAGS" ]; then
    # shellcheck disable=SC2206
    read -ra ex <<<"$NIM_EXTRA_FLAGS"
  fi
  # Link the non-LTO coverage archive after the config-anchored uSockets.a.
  passL="$COV_LFLAGS"
  if [ -n "${USOCKETS_COV_A:-}" ] && [ -f "$USOCKETS_COV_A" ]; then
    passL="$passL $USOCKETS_COV_A"
  fi
  if "$NIM" c --cc:clang \
      --passC:"$COV_CFLAGS" \
      --passL:"$passL" \
      --nimcache:"$CACHE_DIR/${label}_${idx}" \
      -o:"$bin" \
      "${cpaths[@]}" \
      ${extra[@]+"${extra[@]}"} \
      ${ex[@]+"${ex[@]}"} \
      "$file" >"$log" 2>&1; then
    echo "ok   $label/$idx $base"
  else
    echo "FAIL build $label/$idx $base (see $log)"
    printf '%s\t%s\t%s\t%s\n' "$label" "$idx" "$base" "$log" >>"$BUILD_FAILURES"
  fi
}
export -f build_one
export ROOT_DIR NIM COVERAGE_OUT BIN_DIR CACHE_DIR LOG_DIR NIM_EXTRA_FLAGS \
  COV_CFLAGS COV_LFLAGS BUILD_FAILURES COMMON_PATHS_NL USOCKETS_COV_A

echo "compiling ${#MANIFEST[@]} test binaries (-P$JOBS)..."
: >"$BUILD_FAILURES"
printf '%s\n' "${MANIFEST[@]}" \
  | xargs -d '\n' -n 1 -P "$JOBS" bash -c 'build_one "$1"' _

# ---------------------------------------------------------------- run

echo "running test binaries..."
: >"$FAILED_TESTS"
RAN=0
BUILT=0
for job in "${MANIFEST[@]}"; do
  idx="${job%%$'\t'*}"; rest="${job#*$'\t'}"
  label="${rest%%$'\t'*}"; file="${rest#*$'\t'}"
  base="$(basename "$file" .nim)"
  bin="$BIN_DIR/${label}_${idx}_${base}"
  if [ ! -x "$bin" ]; then
    continue
  fi
  BUILT=$((BUILT + 1))
  RAN=$((RAN + 1))
  profraw="$bin.profraw"
  rm -f "$profraw"
  rc=0
  LLVM_PROFILE_FILE="$profraw" "$bin" \
    >"$LOG_DIR/run_${label}_${idx}_${base}.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL test $label/$idx $base (exit $rc)"
    printf '%s\t%s\t%s\t%s\n' "$label" "$idx" "$base" "$rc" >>"$FAILED_TESTS"
  fi
done
echo "ran $RAN/$BUILT built binaries; failures recorded in $FAILED_TESTS"

# ---------------------------------------------------------------- reports

PROFRAW_COUNT="$(find "$BIN_DIR" -name '*.profraw' -type f | wc -l | tr -d ' ')"
echo "profile data: $PROFRAW_COUNT .profraw files"

if [ "$PROFRAW_COUNT" -eq 0 ]; then
  {
    echo "# Coverage summary"
    echo
    echo "No profile data: no test binary produced a .profraw file."
  } >"$COVERAGE_OUT/summary.md"
  : >"$COVERAGE_OUT/coverage.txt"
  echo "coverage: no profile data; wrote empty reports to $COVERAGE_OUT"
  exit 0
fi

find "$BIN_DIR" -name '*.profraw' -type f -print0 \
  | xargs -0 llvm-profdata merge -o "$MERGED"

echo "generating reports + html..."
: >"$COVERAGE_OUT/coverage.txt"
ALL_TSV="$REPORT_DIR/all_rows.tsv"
: >"$ALL_TSV"
for job in "${MANIFEST[@]}"; do
  idx="${job%%$'\t'*}"; rest="${job#*$'\t'}"
  label="${rest%%$'\t'*}"; file="${rest#*$'\t'}"
  base="$(basename "$file" .nim)"
  bin="$BIN_DIR/${label}_${idx}_${base}"
  [ -x "$bin" ] || continue
  name="${label}_${idx}_${base}"
  report="$REPORT_DIR/${name}.report"
  llvm-cov report "$bin" -instr-profile="$MERGED" >"$report" 2>&1 || true
  {
    echo "=== $name ==="
    echo
    cat "$report"
    echo
  } >>"$COVERAGE_OUT/coverage.txt"
  # filename<TAB>lines<TAB>missed_lines per per-file row.
  # llvm-cov report columns: 1=Filename ... 8=Lines 9=Missed Lines 10=LineCov%
  awk 'NF>=10 && $1!="Filename" && $1!="TOTAL" && $8 ~ /^[0-9]+$/ && $9 ~ /^[0-9]+$/ \
       { print $1 "\t" $8 "\t" $9 }' "$report" >>"$ALL_TSV"
  # llvm-cov export cannot emit HTML (JSON/lcov only); llvm-cov show does.
  llvm-cov show "$bin" -instr-profile="$MERGED" \
    --format=html --output-dir="$HTML_DIR/$name"
done

# ---------------------------------------------------------------- summary

SUMMARY="$COVERAGE_OUT/summary.md"
{
  echo "# Test suite coverage summary"
  echo
  echo "- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$COVERAGE_FILTER" ]; then
    echo "- COVERAGE_FILTER: \`$COVERAGE_FILTER\`"
  else
    echo "- COVERAGE_FILTER: (all tests)"
  fi
  echo "- Binaries: $BUILT built, $RAN run, $(wc -l <"$FAILED_TESTS" | tr -d ' ') failed tests, $(wc -l <"$BUILD_FAILURES" | tr -d ' ') failed builds"
  echo "- Profile: \`merged.profdata\` merged from $PROFRAW_COUNT .profraw files"
  echo "- Reports: \`coverage.txt\` (per-binary llvm-cov report), \`html/\` (per-binary HTML)"
  echo
  echo "## Line coverage per package"
  echo
  echo "| Package | Lines | Missed | Coverage |"
  echo "|---|---:|---:|---:|"
  awk -F'\t' '
    {
      file=$1; lines=$2+0; missed=$3+0
      if (lines<=0) next
      # Nim module coverage lives in generated C: @p<module>@s<file>.nim.c —
      # map by embedded module name; also count C helpers under each src dir.
      if (file ~ /nim_fastjson/) pkg="nim_fastjson"
      else if (file ~ /@pnim_express/ || file ~ /nim_express\/src\//) pkg="nim_express"
      else if (file ~ /@pnim_usockets/ || file ~ /nim_usockets\/src\//) pkg="nim_usockets"
      else if (file ~ /@pnim_fasthttpclient/ || file ~ /nim_fasthttpclient\/src\//) pkg="nim_fasthttpclient"
      else if (file ~ /@pnim_utils/ || file ~ /nim_utils\/src\//) pkg="nim_utils"
      else next
      pl[pkg]+=lines; pm[pkg]+=missed
    }
    END {
      n=split("nim_utils nim_fastjson nim_usockets nim_fasthttpclient nim_express", order, " ")
      for (i=1; i<=n; i++) {
        p=order[i]
        if (p in pl) printf "| %s | %d | %d | %.2f%% |\n", p, pl[p], pm[p], (pl[p]-pm[p])*100/pl[p]
      }
    }' "$ALL_TSV"
  echo
  echo "## Top 20 least-covered files"
  echo
  echo "| File | Lines | Missed | Coverage |"
  echo "|---|---:|---:|---:|"
  # One row per file across binaries (best coverage seen for that file);
  # sorted ascending by line coverage.
  awk -F'\t' '
    {
      file=$1; lines=$2+0; missed=$3+0
      if (lines<=0) next
      # Project code only — skip Nim stdlib .c noise. Project Nim modules
      # surface as generated @p<module>@s<file>.nim.c; C helpers under src/.
      if (file !~ /@pnim_express/ && file !~ /@pnim_usockets/ && \
          file !~ /@pnim_fasthttpclient/ && file !~ /@pnim_utils/ && \
          file !~ /nim_utils\/src\// && file !~ /nim_usockets\/src\// && \
          file !~ /nim_fasthttpclient\/src\// && file !~ /nim_express\/src\//) next
      # Normalize generated module C to its Nim path so the same module
      # compiled under several test caches dedupes to one row:
      # cache/<t>/@pnim_utils@shelpers@sfast_map.nim.c -> nim_utils/helpers/fast_map.nim
      key=file; disp=file
      if (file ~ /cache\/[^\/]+\/@p/) {
        m=file
        sub(/.*\/@p/, "", m)
        gsub(/@s/, "/", m)
        sub(/\.c$/, "", m)
        key="nim:" m; disp=m
      }
      cov=(lines-missed)*100/lines
      if (!(key in best) || cov>best[key]) { best[key]=cov; fl[key]=lines; fm[key]=missed; dk[key]=disp }
    }
    END { for (k in best) printf "%.4f\t%d\t%d\t%s\n", best[k], fl[k], fm[k], dk[k] }' "$ALL_TSV" \
    | sort -t"$(printf '\t')" -k1,1g -k2,2nr | head -20 \
    | awk -F'\t' '{ printf "| %s | %d | %d | %.2f%% |\n", $4, $2, $3, $1 }'
  echo
  echo "## Notes"
  echo
  echo "- Nim 2.2.8 C output has no #line markers, so Nim module lines are attributed to generated C files (\`cache/<test>/@p<module>@s<file>.nim.c\`). The module name is embedded in the filename, so this script maps them back to real Nim paths: the per-package table and top-20 list both include Nim modules (deduped across test caches) plus C helpers under each src dir."
  echo
  echo "## Failed tests"
  echo
  if [ -s "$FAILED_TESTS" ]; then
    awk -F'\t' '{ printf "- `%s/%s %s` (exit %s)\n", $1, $2, $3, $4 }' "$FAILED_TESTS"
  else
    echo "(none)"
  fi
  echo
  echo "## Failed builds"
  echo
  if [ -s "$BUILD_FAILURES" ]; then
    awk -F'\t' '{ printf "- `%s/%s %s` (log: %s)\n", $1, $2, $3, $4 }' "$BUILD_FAILURES"
  else
    echo "(none)"
  fi
} >"$SUMMARY"

echo "coverage: wrote $SUMMARY"
echo "coverage: html in $HTML_DIR/"
