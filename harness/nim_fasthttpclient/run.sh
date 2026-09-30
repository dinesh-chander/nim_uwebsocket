#!/usr/bin/env bash
# Gate for the nim_fasthttpclient package (async HTTP/1.1 + HTTP/2 + WS client).
# Includes the gated test_client (needs -d:nimFastHttpClientTest).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../common.sh"
FILES=()
for f in "$ROOT_DIR"/nim_fasthttpclient/tests/test_*.nim; do
  [ "$(basename "$f")" = "test_client.nim" ] || FILES+=("$f")
done
harness_run_tests "nim_fasthttpclient" -- "${FILES[@]}" || exit 1
harness_run_tests "nim_fasthttpclient_gated" -d:nimFastHttpClientTest \
  -- "$ROOT_DIR/nim_fasthttpclient/tests/test_client.nim"
