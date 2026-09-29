# nim_uwebsocket Benchmark Results

## System

| Component | Value |
|-----------|-------|
| CPU | Apple M1 Pro (10-core) |
| RAM | 16 GB |
| OS | macOS 26.3.1 (Darwin 25.3.0 arm64) |
| Nim | 2.2.8 arm64 |
| Build | `--mm:arc -d:danger --opt:speed --passC:"-flto=thin -march=native"` |
| Allocator | jemalloc |
| Event loop | kqueue (`WITH_GCD=0`) |
| Threads | single-thread (1 event loop) |
| Network | loopback (lo0) |

## HTTP Throughput (wrk)

Server: `benchmark/bench_nim_express.nim` — plaintext and JSON endpoints on port 3002.

### Plaintext (`/plaintext` — 13 byte body)

| Connections | Threads | Req/sec | Avg latency | P50 | P99 | Transfer/sec |
|-------------|---------|--------:|------------:|----:|----:|-------------:|
| 1 | 1 | **34,000** | 66 µs | 25 µs | 870 µs | 5.0 MB/s |
| 64 | 2 | **88,123** | 746 µs | 702 µs | 2.24 ms | 12.9 MB/s |
| 256 | 4 | **90,744** | 2.84 ms | 2.85 ms | 3.40 ms | 13.3 MB/s |

### JSON (`/json` — ~75 byte body)

| Connections | Threads | Req/sec | Avg latency | P50 | P99 | Transfer/sec |
|-------------|---------|--------:|------------:|----:|----:|-------------:|
| 64 | 2 | **90,465** | 731 µs | 722 µs | 1.08 ms | 19.3 MB/s |
| 256 | 4 | **85,483** | 3.03 ms | 2.98 ms | 6.42 ms | 18.3 MB/s |

### Pipelined (16 requests per batch)

| Connections | Threads | Req/sec | Avg latency | Transfer/sec |
|-------------|---------|--------:|------------:|-------------:|
| 64 | 2 | **622,020** | 870 µs | 91.4 MB/s |
| 128 | 4 | **591,643** | 1.87 ms | 86.9 MB/s |

### With timeouts disabled (`NIM_EXPRESS_HEADER_READ_TIMEOUT_MS=0`)

| Connections | Threads | Req/sec | Note |
|-------------|---------|--------:|------|
| 64 | 2 | **96,301** | ~6% faster — timeout phase tracking overhead removed |

## WebSocket Throughput

Server: `benchmark/ws_echo_bench.nim` — pure echo server on port 3400.

### tcpkali (raw send rate — measures server ingest capacity)

| Connections | Payload | Packet rate ↑ | Bandwidth ↑ | Duration |
|-------------|---------|-------------:|------------:|---------:|
| 50 | 64 B | **500,397/s** | 5.7 Gbps | 15s |
| 100 | 64 B | **797,862/s** | 9.1 Gbps | 15s |
| 200 | 64 B | **1,078,806/s** | 12.3 Gbps | 15s |
| 500 | 64 B | **440,301/s** | 5.0 Gbps | 15s |

Peak: **1.08M messages/sec** at 200 connections (single-thread).

tcpkali floods the server at maximum rate. The packet rate measures how fast the
server can parse, unmask, and process inbound WebSocket frames. Echo responses
are backpressured under this one-directional flood — this is intentional and
matches the metric used in earlier benchmarks (800K+ msg/sec).

### Nim async echo RTT (round-trip — request-response)

| Clients | Payload | Msg/sec (recv) | Max inflight/client |
|---------|---------|---------------:|--------------------:|
| 100 | 64 B | **224,852/s** | 16 |

This measures full round-trip echo latency. The throughput is limited by the Nim
`asyncdispatch` client, not the server.

## Performance Fixes Applied

### 1. Loop-level write batching disabled on macOS

The `loopWriteBatchDepth` mechanism defers all response writes until the end of
each event-loop tick. On macOS (kqueue), the event loop processes far fewer
events per tick than Linux (epoll), causing responses to stall for the full
inter-tick interval (~5-10 ms).

**Fix:** Added `loopWriteBatching` option — defaults to `true` on Linux, `false`
on macOS. Configurable via `server.setLoopWriteBatching(bool)` or
`NIM_EXPRESS_LOOP_WRITE_BATCHING` env var.

| Benchmark | Before fix | After fix |
|-----------|-----------|-----------|
| wrk t4 c256 plaintext | 25 req/sec | **90,744 req/sec** |
| wrk t1 c1 plaintext | 0 req/sec | **34,000 req/sec** |

### 2. Hot-path header validation optimization

In minimal header parsing mode, header value byte validation was being run on
every header including ones whose values are discarded. The fix defers
`hasValidHeaderValueBytes` to only run on framing headers (Content-Length,
Transfer-Encoding) whose values are actually parsed. Request-target validation
(NUL/tab/LF/CR check) was merged into the query-position scan to eliminate a
redundant loop.

| Benchmark | Before opt | After opt |
|-----------|-----------|-----------|
| wrk t4 c256 plaintext | 88,269 req/sec | **90,744 req/sec** |

### 3. Security timeout overhead (~5-6%)

The production-default timeouts (30s header-read, 30s body-read, 120s
connection) add ~5-6% overhead compared to disabled timeouts. This is the cost
of slowloris protection and per-phase timeout tracking via `us_socket_timeout`.

| Config | wrk t2 c64 |
|--------|-----------|
| Timeouts enabled (default) | 88,123 req/sec |
| Timeouts disabled | 96,301 req/sec |
| Delta | ~6% |

## Micro-benchmarks (per-operation)

From `benchmark/bench_*.nim` — measures individual optimized operations:

| Operation | Throughput | Notes |
|-----------|-----------|-------|
| HPACK encode | 2.23M ops/sec | Header compression |
| HPACK decode | — | Header decompression |
| H2 SETTINGS ACK serialize | 154-168M ops/sec | Inlined frame generation |
| H2 DATA frame serialize | — | Zero-copy view variant |
| WS frame build | 62.8M ops/sec | 1.87 GB/s at 30B payload |
| WS unmask | 25-26 GB/s | SIMD/alignment-aware XOR |
| UTF-8 validation | — | Zero-allocation validator |
| `fastIntToStr` | 71-96% faster | Digit-pair table vs stdlib |
| HTTP date header | — | Direct char append vs `format()` |

## Build & Reproduce

```bash
# Build uSockets (kqueue backend for macOS)
make usockets-kqueue

# Build benchmark server
make bench NIM_EXTRA_FLAGS="--path:nim_fasthttpclient/src"

# Run HTTP benchmark
./benchmark/bench_nim_express &
sleep 2
wrk -t4 -c256 -d15s --latency http://127.0.0.1:3002/plaintext

# Pipelined
wrk -t2 -c64 -d15s -s benchmark/pipeline.lua --latency http://127.0.0.1:3002/plaintext

# Build and run WS echo benchmark
nim c -d:release -d:danger --opt:speed --mm:arc \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --path:nim_fasthttpclient/src \
  --passC:"-flto=thin -march=native" \
  --passL:"nim_usockets/usockets/uSockets.a -framework CoreFoundation \
  -L/opt/homebrew/lib -ljemalloc -flto=thin -Wl,-dead_strip" \
  -o:benchmark/ws_echo_bench benchmark/ws_echo_bench.nim

NIM_EXPRESS_WS_IDLE_TIMEOUT=0 NIM_EXPRESS_CONNECTION_TIMEOUT=0 \
  ./benchmark/ws_echo_bench &
sleep 3
tcpkali --websocket -c 100 --connect-rate 5000 \
  -m 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
  -T 15s 127.0.0.1:3400

# Run micro-benchmarks
make bench NIM_EXTRA_FLAGS="--path:nim_fasthttpclient/src" \
  BENCH_SRC=benchmark/bench_hpack.nim BENCH_BIN=benchmark/bench_hpack
./benchmark/bench_hpack
```

## Tuning

### Environment variables for throughput

| Variable | Default | For max throughput |
|----------|---------|-------------------|
| `NIM_EXPRESS_LOOP_WRITE_BATCHING` | `false` (macOS), `true` (Linux) | `true` on Linux |
| `NIM_EXPRESS_HEADER_READ_TIMEOUT_MS` | `30000` | `0` (disables slowloris protection) |
| `NIM_EXPRESS_BODY_READ_TIMEOUT_MS` | `30000` | `0` |
| `NIM_EXPRESS_CONNECTION_TIMEOUT` | `120` | `0` |
| `NIM_EXPRESS_WS_IDLE_TIMEOUT` | `60` | `0` |
| `NIM_EXPRESS_WRITE_COALESCE_MODE` | `adaptive` | `throughput` |

### Linux-specific (expected to reach higher numbers)

- `SO_REUSEPORT` with multi-process (`runCluster`)
- `EPOLL_EXCLUSIVE` for exclusive poll registration
- epoll processes many more events per tick than kqueue
- Loop write batching benefits from epoll's batch event delivery
- Expected: 200K+ req/sec single-process, 600K+ multi-process on modest hardware
