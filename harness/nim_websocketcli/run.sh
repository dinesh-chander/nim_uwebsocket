#!/usr/bin/env bash
# Gate for the nim_websocketcli package (websocketload tooling).
# NOTE: runs from inside nim_websocketcli/ because its nim.cfg links uSockets.a
# with a path relative to that directory.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../common.sh"
cd "$ROOT_DIR/nim_websocketcli"
harness_nim_check "nim_websocketcli" -- \
  "$ROOT_DIR/nim_websocketcli/src/nim_websocketcli/main.nim" \
  "$ROOT_DIR/nim_websocketcli/websocketload.nim" || exit 1
harness_run_tests "nim_websocketcli" -- "$ROOT_DIR/nim_websocketcli/tests/test_websocketload_config.nim"
