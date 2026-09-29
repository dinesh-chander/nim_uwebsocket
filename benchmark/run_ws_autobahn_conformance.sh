#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTOBANH_IMAGE="${AUTOBANH_IMAGE:-crossbario/autobahn-testsuite}"
AUTOBANH_OUT="${AUTOBANH_OUT:-$ROOT_DIR/benchmark/reports/autobahn}"
AUTOBANH_CASES="${AUTOBANH_CASES:-[*]}"

if [[ "$(uname -s)" == "Darwin" ]]; then
  DEFAULT_WS_URL="ws://host.docker.internal:3000/ws"
else
  DEFAULT_WS_URL="ws://127.0.0.1:3000/ws"
fi
AUTOBANH_WS_URL="${AUTOBANH_WS_URL:-$DEFAULT_WS_URL}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[conformance-ws] docker is required for Autobahn testsuite"
  exit 1
fi

mkdir -p "$AUTOBANH_OUT"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/fuzzingclient.json" <<EOF
{
  "url": "${AUTOBANH_WS_URL}",
  "outdir": "/reports",
  "cases": ${AUTOBANH_CASES},
  "exclude-cases": [
    "9.*",
    "12.*"
  ],
  "exclude-agent-cases": {}
}
EOF

echo "[conformance-ws] target=${AUTOBANH_WS_URL}"
echo "[conformance-ws] output=${AUTOBANH_OUT}"

docker run --rm \
  -v "$TMP_DIR:/config" \
  -v "$AUTOBANH_OUT:/reports" \
  "$AUTOBANH_IMAGE" \
  wstest -m fuzzingclient -s /config/fuzzingclient.json

if [[ -f "$AUTOBANH_OUT/index.json" ]]; then
  if rg -n '"behavior"\s*:\s*"FAILED"' "$AUTOBANH_OUT/index.json" >/dev/null 2>&1; then
    echo "[conformance-ws] Autobahn reports FAILED cases; inspect $AUTOBANH_OUT/index.json"
    exit 1
  fi
fi

echo "[conformance-ws] completed"
