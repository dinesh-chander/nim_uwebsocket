#!/usr/bin/env bash
# Gate for the nim_usockets package (FFI + HTTP/WS server core).
# Requires the -d:nimUwebsocketsTest compile flag. Exits 0 only when green.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../common.sh"
FILES=("$ROOT_DIR"/nim_usockets/tests/test_*.nim)
harness_run_tests "nim_usockets" -d:nimUwebsocketsTest -- "${FILES[@]}"
