#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXAMPLES_DIR="$ROOT_DIR/examples"
BIN_DIR="$SCRIPT_DIR/bin"
RESULTS_DIR="$SCRIPT_DIR"

SERVICE_A_PORT=3200
SERVICE_B_PORT=3201

WRK_THREADS=4
WRK_CONNS=100
WRK_DURATION=10s

cleanup() {
  echo ""
  echo "==> Cleaning up..."
  [ -n "${SERVICE_B_PID:-}" ] && kill "$SERVICE_B_PID" 2>/dev/null && echo "  Stopped Service B (PID $SERVICE_B_PID)"
  [ -n "${SERVICE_A_PID:-}" ] && kill "$SERVICE_A_PID" 2>/dev/null && echo "  Stopped Service A (PID $SERVICE_A_PID)"
  [ -n "${WRK_BG_PID:-}" ] && kill "$WRK_BG_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

echo "================================================================"
echo "  Comprehensive Proxy Benchmark: Service A -> Service B"
echo "  wrk: -t${WRK_THREADS} -c${WRK_CONNS} -d${WRK_DURATION}"
echo "================================================================"
echo ""

echo "==> Building services..."
mkdir -p "$BIN_DIR"

cd "$EXAMPLES_DIR"
echo "  Building Service B..."
nim c -d:release -d:danger --mm:arc --hints:off \
  --path:../nim_utils/src --path:../nim_usockets/src \
  --path:../nim_express/src --path:../nim_fasthttpclient/src \
  -o:"$BIN_DIR/service_b" \
  proxy_benchmark/service_b.nim 2>&1 | sed '/^$/d'

echo "  Building Service A (fast proxy)..."
nim c -d:release -d:danger --mm:arc --hints:off \
  --path:../nim_utils/src --path:../nim_usockets/src \
  --path:../nim_express/src --path:../nim_fasthttpclient/src \
  -o:"$BIN_DIR/service_a" \
  proxy_benchmark/service_a.nim 2>&1 | sed '/^$/d'

echo ""
echo "==> Starting services..."

"$BIN_DIR/service_b" &
SERVICE_B_PID=$!
echo "  Service B started (PID $SERVICE_B_PID)"

sleep 1

"$BIN_DIR/service_a" &
SERVICE_A_PID=$!
echo "  Service A started (PID $SERVICE_A_PID)"

sleep 2

echo ""
echo "==> Waiting for services to be ready..."
for i in $(seq 1 20); do
  if curl -sf "http://127.0.0.1:$SERVICE_B_PORT/health" > /dev/null 2>&1; then
    echo "  Service B ready"
    break
  fi
  sleep 0.5
done

for i in $(seq 1 20); do
  if curl -sf "http://127.0.0.1:$SERVICE_A_PORT/health" > /dev/null 2>&1; then
    echo "  Service A ready"
    break
  fi
  sleep 0.5
done

echo ""
echo "==> Verifying proxy..."
PROXY_RESP=$(curl -sf "http://127.0.0.1:$SERVICE_A_PORT/api/small" 2>/dev/null || echo "FAILED")
echo "  /api/small via proxy: $PROXY_RESP"
PROXY_MEDIUM_SIZE=$(curl -sf "http://127.0.0.1:$SERVICE_A_PORT/api/medium" 2>/dev/null | wc -c | tr -d ' ')
echo "  /api/medium via proxy: ${PROXY_MEDIUM_SIZE} bytes"
PROXY_LARGE_SIZE=$(curl -sf "http://127.0.0.1:$SERVICE_A_PORT/api/large" 2>/dev/null | wc -c | tr -d ' ')
echo "  /api/large via proxy: ${PROXY_LARGE_SIZE} bytes"
PROXY_ECHO=$(curl -sf -X POST -d '{"test":true}' "http://127.0.0.1:$SERVICE_A_PORT/api/echo" 2>/dev/null || echo "FAILED")
echo "  /api/echo via proxy: $PROXY_ECHO"

extract_rps() {
  grep "Requests/sec" | awk '{print $2}'
}

if ! command -v wrk &> /dev/null; then
  echo ""
  echo "ERROR: wrk not found. Install with: brew install wrk"
  exit 1
fi

echo ""
echo "================================================================"
echo "  DIRECT Backend Benchmarks (Service B :${SERVICE_B_PORT})"
echo "================================================================"

echo ""
echo "--- /api/small (direct) ---"
wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${WRK_DURATION} "http://127.0.0.1:$SERVICE_B_PORT/api/small" 2>&1 | tee /tmp/bench_direct_small.txt
DIRECT_SMALL=$(cat /tmp/bench_direct_small.txt | extract_rps)

echo ""
echo "--- /api/medium (direct) ---"
wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${WRK_DURATION} "http://127.0.0.1:$SERVICE_B_PORT/api/medium" 2>&1 | tee /tmp/bench_direct_medium.txt
DIRECT_MEDIUM=$(cat /tmp/bench_direct_medium.txt | extract_rps)

echo ""
echo "--- /api/large (direct) ---"
wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${WRK_DURATION} "http://127.0.0.1:$SERVICE_B_PORT/api/large" 2>&1 | tee /tmp/bench_direct_large.txt
DIRECT_LARGE=$(cat /tmp/bench_direct_large.txt | extract_rps)

echo ""
echo "================================================================"
echo "  PROXY Benchmarks (Service A :${SERVICE_A_PORT} -> B :${SERVICE_B_PORT})"
echo "================================================================"

echo ""
echo "--- /api/small (proxy) ---"
wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${WRK_DURATION} "http://127.0.0.1:$SERVICE_A_PORT/api/small" 2>&1 | tee /tmp/bench_proxy_small.txt
PROXY_SMALL=$(cat /tmp/bench_proxy_small.txt | extract_rps)

echo ""
echo "--- /api/medium (proxy) ---"
wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${WRK_DURATION} "http://127.0.0.1:$SERVICE_A_PORT/api/medium" 2>&1 | tee /tmp/bench_proxy_medium.txt
PROXY_MEDIUM=$(cat /tmp/bench_proxy_medium.txt | extract_rps)

echo ""
echo "--- /api/large (proxy) ---"
wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${WRK_DURATION} "http://127.0.0.1:$SERVICE_A_PORT/api/large" 2>&1 | tee /tmp/bench_proxy_large.txt
PROXY_LARGE=$(cat /tmp/bench_proxy_large.txt | extract_rps)

echo ""
echo "--- /api/echo POST (proxy) ---"
cat > /tmp/post_bench.lua <<'LUAEOF'
wrk.method = "POST"
wrk.body   = '{"key":"value","number":42,"nested":{"a":1}}'
wrk.headers["Content-Type"] = "application/json"
LUAEOF
wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${WRK_DURATION} -s /tmp/post_bench.lua "http://127.0.0.1:$SERVICE_A_PORT/api/echo" 2>&1 | tee /tmp/bench_proxy_echo.txt
PROXY_ECHO_RPS=$(cat /tmp/bench_proxy_echo.txt | extract_rps)

echo ""
echo "================================================================"
echo "  CPU Profiling Service A during /api/medium benchmark"
echo "================================================================"

if command -v sample &> /dev/null; then
  SAMPLE_FILE="/tmp/service_a_profile.txt"
  echo "  Starting wrk load + sample profiler..."

  wrk -t2 -c50 -d15s "http://127.0.0.1:$SERVICE_A_PORT/api/medium" > /dev/null 2>&1 &
  WRK_BG_PID=$!

  sleep 1
  sample "$SERVICE_A_PID" 10 -f "$SAMPLE_FILE" 2>/dev/null || true

  wait "$WRK_BG_PID" 2>/dev/null || true
  unset WRK_BG_PID

  if [ -f "$SAMPLE_FILE" ]; then
    echo "  Profile saved to $SAMPLE_FILE"

    if command -v stackcollapse-sample.awk &> /dev/null && command -v flamegraph.pl &> /dev/null; then
      echo "  Generating flamegraph..."
      stackcollapse-sample.awk "$SAMPLE_FILE" | flamegraph.pl > "$RESULTS_DIR/flamegraph_proxy_medium.svg" 2>/dev/null || true
      if [ -f "$RESULTS_DIR/flamegraph_proxy_medium.svg" ]; then
        echo "  Flamegraph saved to $RESULTS_DIR/flamegraph_proxy_medium.svg"
      else
        echo "  Flamegraph generation failed (tools may need FlameGraph repo in PATH)"
      fi
    else
      echo "  stackcollapse-sample.awk / flamegraph.pl not in PATH, skipping flamegraph"
      echo "  Install FlameGraph: git clone https://github.com/brendangregg/FlameGraph"
    fi

    echo ""
    echo "  Top functions from profile:"
    grep -E "^\s+[0-9]+" "$SAMPLE_FILE" 2>/dev/null | head -15 || echo "  (profile too short or empty)"
  fi
else
  echo "  sample command not available (macOS only)"
fi

echo ""
echo "================================================================"
echo "  RESULTS SUMMARY"
echo "================================================================"
echo ""
printf "%-18s %12s %12s %10s\n" "Endpoint" "Direct req/s" "Proxy req/s" "Overhead"
printf "%-18s %12s %12s %10s\n" "------------------" "------------" "------------" "----------"

calc_overhead() {
  local direct=$1
  local proxy=$2
  if [ -z "$direct" ] || [ -z "$proxy" ] || [ "$direct" = "0" ]; then
    echo "N/A"
    return
  fi
  awk "BEGIN { printf \"%.1f%%\", (1 - $proxy / $direct) * 100 }"
}

OH_SMALL=$(calc_overhead "${DIRECT_SMALL:-0}" "${PROXY_SMALL:-0}")
OH_MEDIUM=$(calc_overhead "${DIRECT_MEDIUM:-0}" "${PROXY_MEDIUM:-0}")
OH_LARGE=$(calc_overhead "${DIRECT_LARGE:-0}" "${PROXY_LARGE:-0}")

printf "%-18s %12s %12s %10s\n" "/api/small" "${DIRECT_SMALL:-N/A}" "${PROXY_SMALL:-N/A}" "$OH_SMALL"
printf "%-18s %12s %12s %10s\n" "/api/medium" "${DIRECT_MEDIUM:-N/A}" "${PROXY_MEDIUM:-N/A}" "$OH_MEDIUM"
printf "%-18s %12s %12s %10s\n" "/api/large" "${DIRECT_LARGE:-N/A}" "${PROXY_LARGE:-N/A}" "$OH_LARGE"
printf "%-18s %12s %12s %10s\n" "/api/echo (POST)" "N/A" "${PROXY_ECHO_RPS:-N/A}" "N/A"

echo ""
echo "================================================================"
echo "  Benchmark Complete"
echo "================================================================"
