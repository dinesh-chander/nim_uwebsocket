#!/usr/bin/env bash
# Gate for the nim_utils package: all tests in nim_utils/tests plus the
# nim_fastjson tests nested under src. Exits 0 only when green.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../common.sh"
FILES=("$ROOT_DIR"/nim_utils/tests/test_*.nim
       "$ROOT_DIR"/nim_utils/src/nim_utils/nim_fastjson/tests/test_*.nim)
harness_run_tests "nim_utils" -- "${FILES[@]}"
