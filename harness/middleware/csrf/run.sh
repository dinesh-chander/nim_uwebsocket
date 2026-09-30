#!/usr/bin/env bash
# Gate for the csrf middleware: compile-check the module, run its tests
# (test_csrf*), falling back to the integration middlewares gates when no
# dedicated test file exists. Exits 0 only when everything is green.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../../common.sh"

NAME="csrf"
harness_nim_check "mw_${NAME}" -- "nim_express/src/nim_express/middlewares/${NAME}.nim" || exit 1

FILES=()
for f in "$ROOT_DIR"/nim_express/tests/test_${NAME}*.nim; do
  [ -e "$f" ] && FILES+=("$f")
done
if [ ${#FILES[@]} -eq 0 ]; then
  FILES=("$ROOT_DIR/nim_express/tests/test_integration_middlewares.nim"
         "$ROOT_DIR/nim_express/tests/test_middleware_resilience.nim")
fi
harness_run_tests "mw_${NAME}" -- "${FILES[@]}"
