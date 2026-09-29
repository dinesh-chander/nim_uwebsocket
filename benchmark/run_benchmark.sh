#!/usr/bin/env bash
set -euo pipefail

BENCHMARK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$BENCHMARK_DIR/.." && pwd)"
cd "$BENCHMARK_DIR"
source "${ROOT_DIR}/benchmark/build_helpers.sh"
STAMP="$(date +%Y%m%d_%H%M%S)"
BUILD_OUT_DIR="${ROOT_DIR}/benchmark/reports/run_benchmark_${STAMP}"
mkdir -p "${BUILD_OUT_DIR}"
bench_init_cold_build "${ROOT_DIR}" "${BUILD_OUT_DIR}"
bench_set_common_paths "${ROOT_DIR}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Benchmark settings
THREADS=4
DURATION=120s  # 2 minutes per test
CONCURRENCY_LEVELS=(10 50 100)

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Web Framework Benchmark (wrk)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Tool: wrk (https://github.com/wg/wrk)"
echo "Duration: $DURATION per endpoint"
echo "Threads: $THREADS"
echo "Concurrency levels: ${CONCURRENCY_LEVELS[*]}"
echo ""

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

for cmd in wrk node npm nim make pkill ps awk grep head tail; do
    need_cmd "$cmd"
done

echo "wrk version: $(wrk --version 2>&1 | head -1)"
echo ""

# Kill any existing servers
pkill -f bench_asynchttp 2>/dev/null || true
pkill -f bench_nim_express 2>/dev/null || true
pkill -f bench_ultimate_express 2>/dev/null || true
pkill -f htmx_app 2>/dev/null || true
sleep 2

# Compile Nim servers
echo -e "${YELLOW}Compiling Nim servers...${NC}"
bench_rebuild_usockets "${BUILD_OUT_DIR}/build_usockets.log"
USOCKETS_LINK_FLAGS="$(bench_platform_link_flags "${ROOT_DIR}/nim_usockets/usockets/uSockets.a")"
bench_nim bench_asynchttp c -d:release --opt:speed -d:danger --hints:off \
    bench_asynchttp.nim >"${BUILD_OUT_DIR}/build_bench_asynchttp.log" 2>&1
bench_nim bench_nim_express c -d:release --opt:speed -d:danger --hints:off \
    "${BENCH_COMMON_PATHS[@]}" \
    --passL:"${USOCKETS_LINK_FLAGS}" \
    bench_nim_express.nim >"${BUILD_OUT_DIR}/build_bench_nim_express.log" 2>&1

# Install Node.js dependencies if needed
if [ ! -d "node_modules" ]; then
    echo -e "${YELLOW}Installing Node.js dependencies...${NC}"
    npm install --silent
fi

# Results file
RESULTS_FILE="benchmark_results.txt"
CSV_FILE="benchmark_results.csv"
echo "Benchmark Results - $(date)" > "$RESULTS_FILE"
echo "Tool: wrk, Duration: $DURATION, Threads: $THREADS" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

# CSV header
echo "framework,endpoint,connections,req_per_sec,latency_avg,latency_stdev,latency_max,p50,p75,p90,p99,transfer_per_sec,memory_kb,cpu_percent" > "$CSV_FILE"

# Function to run benchmark for one server
run_server_benchmark() {
    local name="$1"
    local port="$2"
    local pid="$3"

    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  $name${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo "" >> "$RESULTS_FILE"
    echo "=== $name ===" >> "$RESULTS_FILE"

    # Wait for server to be ready
    sleep 2

    # Warmup
    echo -e "${CYAN}Warming up...${NC}"
    wrk -t2 -c10 -d5s http://localhost:$port/json > /dev/null 2>&1

    for conns in "${CONCURRENCY_LEVELS[@]}"; do
        echo ""
        echo -e "${YELLOW}Testing with $conns concurrent connections${NC}"
        echo "" >> "$RESULTS_FILE"
        echo "--- $conns connections ---" >> "$RESULTS_FILE"

        for endpoint in "/json" "/plaintext"; do
            echo "  $endpoint endpoint ($DURATION)..."
            echo "" >> "$RESULTS_FILE"
            echo "$endpoint:" >> "$RESULTS_FILE"

            # Run wrk with --latency flag for percentile distribution
            local output
            if ! output=$(wrk -t"$THREADS" -c"$conns" -d"$DURATION" --latency "http://localhost:$port$endpoint" 2>&1); then
                echo "$output" >> "$RESULTS_FILE"
                echo "wrk failed for $name $endpoint with $conns connections" >&2
                return 1
            fi
            echo "$output" >> "$RESULTS_FILE"

            # Parse results
            local req_sec=$(echo "$output" | grep "Requests/sec" | awk '{print $2}')
            local latency_avg=$(echo "$output" | grep "Latency" | head -1 | awk '{print $2}')
            local latency_stdev=$(echo "$output" | grep "Latency" | head -1 | awk '{print $3}')
            local latency_max=$(echo "$output" | grep "Latency" | head -1 | awk '{print $4}')
            local transfer=$(echo "$output" | grep "Transfer/sec" | awk '{print $2}')

            # Parse percentiles
            local p50=$(echo "$output" | grep "50%" | awk '{print $2}')
            local p75=$(echo "$output" | grep "75%" | awk '{print $2}')
            local p90=$(echo "$output" | grep "90%" | awk '{print $2}')
            local p99=$(echo "$output" | grep "99%" | awk '{print $2}')

            # Get memory/CPU
            local mem=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' ')
            local cpu=$(ps -o %cpu= -p $pid 2>/dev/null | tr -d ' ')

            # Display results
            echo "    Req/sec: $req_sec"
            echo "    Latency: avg=$latency_avg, stdev=$latency_stdev, max=$latency_max"
            echo "    Percentiles: p50=$p50, p75=$p75, p90=$p90, p99=$p99"
            echo "    Transfer: $transfer"

            # Write to CSV
            echo "$name,$endpoint,$conns,$req_sec,$latency_avg,$latency_stdev,$latency_max,$p50,$p75,$p90,$p99,$transfer,${mem:-0},${cpu:-0}" >> "$CSV_FILE"
        done

        local mem=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' ')
        local cpu=$(ps -o %cpu= -p $pid 2>/dev/null | tr -d ' ')
        echo ""
        echo "  Memory: ${mem:-N/A} KB, CPU: ${cpu:-N/A}%"
        echo "" >> "$RESULTS_FILE"
        echo "Memory: ${mem:-N/A} KB, CPU: ${cpu:-N/A}%" >> "$RESULTS_FILE"
    done

    echo ""
}

# 1. Benchmark asynchttpserver
echo -e "${YELLOW}Starting asynchttpserver on port 3001...${NC}"
./bench_asynchttp &
ASYNC_PID=$!
run_server_benchmark "Nim asynchttpserver" 3001 $ASYNC_PID
kill $ASYNC_PID 2>/dev/null || true
sleep 2

# 2. Benchmark nim_express
echo -e "${YELLOW}Starting nim_express on port 3002...${NC}"
./bench_nim_express &
EXPRESS_PID=$!
run_server_benchmark "nim_express (uWebSockets)" 3002 $EXPRESS_PID
kill $EXPRESS_PID 2>/dev/null || true
sleep 2

# 3. Benchmark ultimate-express
echo -e "${YELLOW}Starting ultimate-express on port 3003...${NC}"
node bench_ultimate_express.js &
ULTIMATE_PID=$!
run_server_benchmark "ultimate-express (Node.js)" 3003 $ULTIMATE_PID
kill $ULTIMATE_PID 2>/dev/null || true

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Benchmark Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Results saved to:"
echo "  - $RESULTS_FILE (full output)"
echo "  - $CSV_FILE (parseable data)"
echo ""

# Print summary table
echo -e "${CYAN}=== SUMMARY TABLE (/json endpoint) ===${NC}"
echo ""
printf "%-28s %6s %10s %8s %8s %8s %8s %10s\n" "Framework" "Conns" "Req/sec" "Avg" "p50" "p99" "Max" "Memory"
printf "%-28s %6s %10s %8s %8s %8s %8s %10s\n" "----------------------------" "------" "----------" "--------" "--------" "--------" "--------" "----------"

# Parse CSV and print summary for /json only
tail -n +2 "$CSV_FILE" | while IFS=, read -r fw ep conns rps lat_avg lat_std lat_max p50 p75 p90 p99 transfer mem cpu; do
    if [ "$ep" == "/json" ]; then
        printf "%-28s %6s %10s %8s %8s %8s %8s %10s\n" "$fw" "$conns" "$rps" "$lat_avg" "$p50" "$p99" "$lat_max" "${mem}KB"
    fi
done

echo ""
echo -e "${CYAN}=== SUMMARY TABLE (/plaintext endpoint) ===${NC}"
echo ""
printf "%-28s %6s %10s %8s %8s %8s %8s %10s\n" "Framework" "Conns" "Req/sec" "Avg" "p50" "p99" "Max" "Memory"
printf "%-28s %6s %10s %8s %8s %8s %8s %10s\n" "----------------------------" "------" "----------" "--------" "--------" "--------" "--------" "----------"

tail -n +2 "$CSV_FILE" | while IFS=, read -r fw ep conns rps lat_avg lat_std lat_max p50 p75 p90 p99 transfer mem cpu; do
    if [ "$ep" == "/plaintext" ]; then
        printf "%-28s %6s %10s %8s %8s %8s %8s %10s\n" "$fw" "$conns" "$rps" "$lat_avg" "$p50" "$p99" "$lat_max" "${mem}KB"
    fi
done
