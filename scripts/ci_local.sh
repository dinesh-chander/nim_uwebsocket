#!/usr/bin/env bash
# Local stand-in for .github/workflows/ci.yml.
#
# This account cannot run GitHub Actions: every job fails before its first step
# (steps=0, ~3s), including a two-line ping probe, so no workflow content can
# turn green regardless of correctness. Until runners are available, run this to
# get the same pre-merge verdict locally. Keep ci.yml: it is the right shape and
# will work the moment runners exist.
#
# Usage: ./scripts/ci_local.sh            run everything for this platform
#        SKIP_FUZZ=1 ./scripts/ci_local.sh  skip the slow fuzz layer
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
LOG_DIR="${LOG_DIR:-/tmp/nim_uwebsocket_ci_local}"
mkdir -p "$LOG_DIR"

RESULTS=()
SKIPPED=()
FAILED_COUNT=0

run_step() {
  local name="$1"
  shift
  echo ""
  echo "=== ci_local: $name"
  if "$@" >"$LOG_DIR/$name.log" 2>&1; then
    echo "    PASS $name (log: $LOG_DIR/$name.log)"
    RESULTS+=("PASS $name")
  else
    echo "    FAIL $name (log: $LOG_DIR/$name.log)"
    tail -15 "$LOG_DIR/$name.log" | sed 's/^/      | /'
    RESULTS+=("FAIL $name")
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

IS_LINUX=0
[ "$(uname -s)" = "Linux" ] && IS_LINUX=1

if [ "$IS_LINUX" = "1" ]; then
  # make test is Linux-only here for the same reason ci.yml scopes it that way:
  # production-check already compiles the package suites everywhere, so an
  # unproven extra suite cannot redden the whole gate.
  run_step make-test make test
fi

run_step production-check make production-check NATIVE_OPT=0

if [ "$IS_LINUX" = "1" ]; then
  run_step linux-compat-check make linux-compat-check NATIVE_OPT=0
  run_step smoke-epoll env USOCKETS_BACKEND=epoll bash scripts/linux_smoke.sh
  if [ "$(ldconfig -p 2>/dev/null | grep -c liburing)" -ge 1 ]; then
    run_step smoke-io-uring env USOCKETS_BACKEND=io_uring bash scripts/linux_smoke.sh
  else
    SKIPPED+=("smoke-io-uring (liburing absent)")
  fi
else
  run_step smoke-gcd bash scripts/macos_smoke.sh
fi

if [ "$IS_LINUX" = "1" ] && [ "${SKIP_FUZZ:-0}" != "1" ]; then
  run_step fuzz env FUZZ_TIMEOUT="${FUZZ_TIMEOUT:-1800}" bash tests/run_fuzz.sh
elif [ "${SKIP_FUZZ:-0}" = "1" ]; then
  SKIPPED+=("fuzz (SKIP_FUZZ=1)")
elif [ "$IS_LINUX" != "1" ]; then
  SKIPPED+=("fuzz (Linux only)")
fi

echo ""
echo "=== ci_local summary"
if [ ${#RESULTS[@]} -gt 0 ]; then
  for r in "${RESULTS[@]}"; do echo "  $r"; done
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
  for s in "${SKIPPED[@]}"; do echo "  SKIP $s"; done
fi

if [ "$FAILED_COUNT" -gt 0 ]; then
  echo "ci_local: $FAILED_COUNT step(s) failed"
  exit 1
fi
echo "ci_local: all steps passed"
