#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXAMPLES_DIR="$ROOT_DIR/examples"
BIN_DIR="$SCRIPT_DIR/bin"

SERVICE_A_BIN="$BIN_DIR/service_a"
SERVICE_B_BIN="$BIN_DIR/service_b"

SERVICE_A_PORT=3200
SERVICE_B_PORT=3201

cleanup() {
  echo ""
  echo "==> Cleaning up..."
  [ -n "${SERVICE_B_PID:-}" ] && kill "$SERVICE_B_PID" 2>/dev/null && echo "  Stopped Service B (PID $SERVICE_B_PID)"
  [ -n "${SERVICE_A_PID:-}" ] && kill "$SERVICE_A_PID" 2>/dev/null && echo "  Stopped Service A (PID $SERVICE_A_PID)"
  wait 2>/dev/null
}
trap cleanup EXIT

echo "============================================"
echo "  Proxy Benchmark: Service A -> Service B"
echo "============================================"
echo ""

echo "==> Building services..."
mkdir -p "$BIN_DIR"

cd "$EXAMPLES_DIR"
echo "  Building Service B..."
nim c -d:release --mm:arc --hints:off \
  --path:../nim_utils/src --path:../nim_usockets/src \
  --path:../nim_express/src --path:../nim_fasthttpclient/src \
  -o:"$SERVICE_B_BIN" \
  proxy_benchmark/service_b.nim

echo "  Building Service A (fast proxy)..."
nim c -d:release --mm:arc --hints:off \
  --path:../nim_utils/src --path:../nim_usockets/src \
  --path:../nim_express/src --path:../nim_fasthttpclient/src \
  -o:"$SERVICE_A_BIN" \
  proxy_benchmark/service_a_async.nim

echo ""
echo "==> Starting services..."

"$SERVICE_B_BIN" &
SERVICE_B_PID=$!
echo "  Service B started (PID $SERVICE_B_PID)"

sleep 1

"$SERVICE_A_BIN" &
SERVICE_A_PID=$!
echo "  Service A started (PID $SERVICE_A_PID)"

sleep 1

echo ""
echo "==> Waiting for services to be ready..."
for i in $(seq 1 10); do
  if curl -sf "http://127.0.0.1:$SERVICE_B_PORT/health" > /dev/null 2>&1; then
    echo "  Service B ready"
    break
  fi
  sleep 0.5
done

for i in $(seq 1 10); do
  if curl -sf "http://127.0.0.1:$SERVICE_A_PORT/" > /dev/null 2>&1; then
    echo "  Service A ready"
    break
  fi
  sleep 0.5
done

echo ""
echo "==> Verifying proxy (single request)..."
RESPONSE_SIZE=$(curl -sf "http://127.0.0.1:$SERVICE_A_PORT/" | wc -c | tr -d ' ')
echo "  Response size: ${RESPONSE_SIZE} bytes"
if [ "$RESPONSE_SIZE" -lt 1024 ]; then
  echo "  WARNING: Response less than 1KB (${RESPONSE_SIZE} bytes)"
fi

echo ""
echo "==> Direct backend (Service B) baseline..."
if command -v wrk &> /dev/null; then
  echo ""
  echo "--- wrk: Service B direct (4 threads, 100 connections, 10s) ---"
  wrk -t4 -c100 -d10s "http://127.0.0.1:$SERVICE_B_PORT/" | tee /tmp/bench_service_b.txt
  echo ""

  echo "--- wrk: Service A proxy (4 threads, 100 connections, 10s) ---"
  wrk -t4 -c100 -d10s "http://127.0.0.1:$SERVICE_A_PORT/" | tee /tmp/bench_service_a_100.txt
  echo ""

  echo "--- wrk: Service A proxy (4 threads, 256 connections, 10s) ---"
  wrk -t4 -c256 -d10s "http://127.0.0.1:$SERVICE_A_PORT/" | tee /tmp/bench_service_a_256.txt
  echo ""
else
  echo "wrk not found. Install with: brew install wrk"
  echo ""
  echo "Falling back to curl timing..."
  for run in 1 2 3; do
    echo -n "  Request $run: "
    curl -sf -o /dev/null -w "time_total=%{time_total}s size=%{size_download}B\n" "http://127.0.0.1:$SERVICE_A_PORT/"
  done
  echo ""
fi

echo "==> Profiling Service A with sample (5 seconds)..."
if command -v sample &> /dev/null; then
  SAMPLE_FILE="/tmp/service_a_profile.txt"
  echo "  Generating CPU profile for PID $SERVICE_A_PID..."

  if command -v wrk &> /dev/null; then
    wrk -t2 -c50 -d10s "http://127.0.0.1:$SERVICE_A_PORT/" > /dev/null 2>&1 &
    WRK_PID=$!
  fi

  sample "$SERVICE_A_PID" 5 -f "$SAMPLE_FILE" 2>/dev/null || true

  if [ -n "${WRK_PID:-}" ]; then
    wait "$WRK_PID" 2>/dev/null || true
  fi

  if [ -f "$SAMPLE_FILE" ]; then
    echo "  Profile saved to $SAMPLE_FILE"
    echo "  Top functions:"
    grep -E "^\s+[0-9]+" "$SAMPLE_FILE" | head -20 || echo "  (profile too short or empty)"
  fi
else
  echo "  sample command not available (macOS only)"
fi

echo ""
echo "============================================"
echo "  Benchmark Complete"
echo "============================================"
echo ""
echo "Results saved to:"
echo "  /tmp/bench_service_b.txt"
echo "  /tmp/bench_service_a_100.txt"
echo "  /tmp/bench_service_a_256.txt"
echo "  /tmp/service_a_profile.txt"
