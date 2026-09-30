#!/usr/bin/env bash
# Gate for the nim_express package: all tests in nim_express/tests.
# For middleware-scoped work prefer the narrower harness/middleware/<name>/run.sh.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../common.sh"
FILES=("$ROOT_DIR"/nim_express/tests/test_*.nim)
harness_run_tests "nim_express" -- "${FILES[@]}"
