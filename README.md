# nim_uwebsocket

A high-performance web framework for Nim, built on [uSockets](https://github.com/uNetworking/uSockets). Express-style API with HTTP/1.1, HTTP/2, WebSocket, and SSE support — benchmarked at **95k+ req/s** single-process and **130k+ req/s** clustered.

```nim
import nim_express

let app = newExpressApp()
app.get("/") do (req: Request, res: Response):
  res.send("Hello, World!")
app.run(3000)
```

## Architecture

```
nim_uwebsocket/
├── nim_usockets/          C FFI bindings to uSockets (TCP, TLS, event loop)
│   └── usockets/          Vendored uSockets C sources → uSockets.a
├── nim_express/           Express-like web framework (routing, middleware, scaling)
├── nim_fasthttpclient/    HTTP/1.1, HTTP/2, WebSocket, SSE client library
├── nim_utils/             Shared utilities (fast_map, async_logger, nim_fastjson)
├── examples/              Ready-to-run example applications
├── benchmark/             Benchmark suite (Nim, Node.js, .NET comparisons)
└── Makefile               Top-level build orchestration
```

### Data Flow

```
Client ──▶ uSockets (C) ──▶ nim_usockets (FFI) ──▶ nim_express (framework)
                                                        │
                                              ┌─────────┼─────────┐
                                              ▼         ▼         ▼
                                           Router   Middleware   Response
                                         (params,   (compress,   (JSON,
                                          match)    CORS, auth)   HTML)
```

### Layer Responsibilities

| Layer | Role |
|-------|------|
| **uSockets (C)** | Event loop (epoll/kqueue/GCD), TCP/TLS accept, raw I/O |
| **nim_usockets** | Nim FFI bindings, HTTP/1.1 parser, HTTP/2 frames/HPACK, WebSocket protocol, SIMD-accelerated parsing |
| **nim_express** | Routing, middleware pipeline, request/response lifecycle, compression, scaling (cluster/threaded), configuration |
| **nim_fasthttpclient** | Outbound HTTP/1.1 and HTTP/2 client, WebSocket client, SSE streaming, connection pooling |
| **nim_utils** | Shared data structures (`fast_map`, `fast_set`), async logger, SIMD-accelerated JSON engine |

### How the Subprojects Fit Together

```
                ┌──────────────────────────────────────────┐
                │          Your Application Code           │
                └──────────┬───────────────┬───────────────┘
                           │               │
                ┌──────────▼──────────┐    │
                │    nim_express      │    │
                │  (routing, MW, app) │    │
                └──────────┬──────────┘    │
                           │               │
          ┌────────────────┼───────────────┼────────────────┐
          │                │               │                │
 ┌────────▼────────┐  ┌───▼────────┐  ┌───▼──────────────┐ │
 │  nim_usockets   │  │ nim_utils  │  │ nim_fasthttpclient│ │
 │ (server-side    │  │ (fast_map, │  │ (outbound HTTP,   │ │
 │  HTTP/WS/H2)    │  │  fastjson, │  │  WS, SSE client)  │ │
 │                 │  │  logger)   │  │                   │ │
 └────────┬────────┘  └───────────┘  └───────────────────┘ │
          │                                                 │
 ┌────────▼────────────────────────────────────────────────┘
 │  uSockets.a (C)
 │  Event loop, TCP/TLS, raw socket I/O
 └─────────────────────────────────────────────────────────
```

- **nim_usockets** wraps the C uSockets library, providing typed Nim access to the event loop, TCP listeners, HTTP/1.1 parsing, HTTP/2 framing, and WebSocket protocol handling.
- **nim_express** builds the application framework on top of nim_usockets — routing, middleware, JSON/HTML responses, compression, cluster scaling, and configuration profiles.
- **nim_fasthttpclient** provides outbound connectivity — HTTP/1.1 and HTTP/2 clients with connection pooling, WebSocket client, and SSE streaming.
- **nim_utils** is a shared library consumed by all other subprojects — hash maps, hash sets, the async logger, and the SIMD-accelerated JSON engine.

## Subprojects

| Package | Description | README |
|---------|-------------|--------|
| [**nim_usockets**](nim_usockets/) | Low-level Nim bindings for the uSockets C library. TCP/TLS socket management, event loop integration, HTTP/1.1 parsing, HTTP/2 protocol with HPACK, and WebSocket protocol handling. | [README](nim_usockets/README.md) |
| [**nim_express**](nim_express/) | Express-style web framework. Route definitions with `:param` support, middleware pipeline, JSON/HTML responses, static file serving, template rendering, cluster/threaded scaling. | [README](nim_express/README.md) |
| [**nim_fasthttpclient**](nim_fasthttpclient/) | High-performance HTTP client supporting HTTP/1.1, HTTP/2 (with HPACK), WebSocket client, and SSE streaming. Connection pooling included. | [README](nim_fasthttpclient/README.md) |
| [**nim_utils**](nim_utils/) | Shared utilities: `fast_map` (optimized hash map), `fast_set`, `async_logger` (POSIX batched I/O), `nim_fastjson` (SIMD-accelerated JSON serde). | [README](nim_utils/README.md) |

## Features

- **HTTP/1.1** — full request/response lifecycle, keep-alive, chunked transfer
- **HTTP/2** — server-side frame handling, HPACK header compression, flow control, stream management
- **WebSocket** — RFC 6455 with per-message compression (deflate, zstd), pub/sub topics, backpressure
- **Server-Sent Events** — streaming push to clients
- **HTTP/2 Client** — HPACK header compression, stream multiplexing (via `nim_fasthttpclient`)
- **Routing** — path parameters (`:id`), method-based (GET/POST/PUT/DELETE/PATCH)
- **Middleware** — composable pipeline with 36 built-in middlewares
- **Scaling** — `runCluster` (multi-process), `runThreaded` (multi-thread), `runAuto` (platform-aware)
- **Compression** — gzip, brotli, zstd, deflate via libdeflate + zippy
- **JSON** — SIMD-accelerated `nim_fastjson` with strict RFC 8259 compliance and typed deserialization
- **Templates** — built-in HTML template rendering with layouts
- **Configuration** — JSON files, environment variables, named profiles (`linux-throughput`, `latency`, `balanced`, etc.)
- **TLS** — OpenSSL and BoringSSL support via uSockets
- **Docker** — Dockerfile and Docker Compose support included

## Platform Support

### Comprehensive Matrix

| Feature | Linux (x86_64) | Linux (ARM64) | macOS (Intel) | macOS (Apple Silicon) | Windows |
|---------|----------------|---------------|---------------|----------------------|---------|
| **HTTP/1.1 server** | Yes (epoll/io_uring) | Yes (epoll/io_uring) | Yes (GCD) | Yes (GCD) | Limited (single process) |
| **HTTP/2 server** | Yes | Yes | Yes | Yes | Yes |
| **WebSocket** | Yes | Yes | Yes | Yes | Yes |
| **SSE** | Yes | Yes | Yes | Yes | Yes |
| **Multi-process (`runCluster`)** | Yes (SO_REUSEPORT) | Yes (SO_REUSEPORT) | No | No | No (no fork) |
| **Multi-thread (`runThreaded`)** | Yes (epoll) | Yes (epoll) | No (GCD limitation) | No (GCD limitation) | No |
| **`runAuto`** | Cluster | Cluster | Single process | Single process | Single process |
| **TLS (OpenSSL/BoringSSL)** | Yes | Yes | Yes | Yes | Untested |
| **SIMD JSON** | SSE2 | NEON | SSE2 | NEON | Scalar SWAR fallback |
| **SIMD HTTP parsing** | SSE2 | NEON | SSE2 | NEON | Scalar fallback |
| **async_logger** | Yes (writev) | Yes (writev) | Yes (writev) | Yes (writev) | No (POSIX-only) |
| **CPU affinity** | Yes | Yes | No | No | No |
| **NUMA binding** | Yes | No | No | No | No |
| **TCP_FASTOPEN** | Yes | Yes | Yes (client only) | Yes (client only) | No |
| **SO_REUSEPORT load balancing** | Yes | Yes | No (binds but does not distribute) | No | No |
| **epoll exclusive** | Yes | Yes | N/A | N/A | N/A |

### Platform-Specific Notes

**Linux** is the primary production target. All scaling modes, socket options, and kernel tuning parameters are fully supported. epoll is the default event loop backend; io_uring is available with `USOCKETS_BACKEND=io_uring` when liburing is installed and the runtime allows io_uring syscalls.

**macOS** uses GCD (Grand Central Dispatch) for the event loop and links CoreFoundation. Multi-threading does not work because GCD's event loop is not safe to run in spawned threads; GCD builds fail fast if the event loop is started outside the process main thread. Multi-process via `SO_REUSEPORT` binds successfully but macOS does not distribute connections across listeners; use nginx or haproxy for load balancing across multiple ports instead.

**Windows** runs in single-process mode only. `fork()` is not available. The async_logger module does not compile (no `writev`). SIMD JSON falls back to the portable SWAR (8-byte) path.

## Quick Start

### Prerequisites

- **Nim** >= 2.0.0
- **gcc** and **make**
- macOS: Xcode Command Line Tools
- Linux: `build-essential`

### Build

```bash
git clone <repo-url> && cd nim_uwebsocket

make usockets              # macOS defaults to GCD; Linux defaults to epoll
# or on Linux:
make usockets USOCKETS_BACKEND=epoll
make usockets USOCKETS_BACKEND=io_uring

make bench
./benchmark/bench_nim_express

make examples
```

### Hello World

Create `app.nim`:

```nim
import nim_express

let app = newExpressApp()

app.get("/") do (req: Request, res: Response):
  res.send("Hello, World!")

app.get("/json") do (req: Request, res: Response):
  res.json(%*{"message": "Hello, JSON!"})

app.run(3000)
```

Compile and run:

```bash
# macOS
nim c -d:release --opt:speed \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --passL:"nim_usockets/usockets/uSockets.a -framework CoreFoundation" \
  app.nim

# Linux
nim c -d:release --opt:speed \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
  --path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
  --path:vendor/jsony/src --path:vendor/checksums \
  --passL:"nim_usockets/usockets/uSockets.a -lpthread -ldl" \
  app.nim

./app
# Server listening on http://0.0.0.0:3000
curl http://localhost:3000/json
```

### Scaling

```nim
proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()
  app.getSync("/json") do (req: Request, res: Response):
    res.json(%*{"message": "Hello!"})
  return app

runAuto(createApp, 3000)

# Or explicitly:
runCluster(createApp, 3000, numWorkers = 4)   # Linux: multi-process
runThreaded(createApp, 3000, numThreads = 4)  # Linux: multi-threaded
```

## Building from Source

### Linux (Ubuntu/Debian)

```bash
sudo apt-get install build-essential

cd nim_usockets/usockets
make clean && make

cd ../..
nim c -d:release --opt:speed \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
  --path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
  --path:vendor/jsony/src --path:vendor/checksums \
  --passL:"nim_usockets/usockets/uSockets.a -lpthread -ldl" \
  app.nim
```

### Linux (RHEL/Fedora/Amazon Linux)

```bash
sudo yum groupinstall "Development Tools"
# or: sudo dnf groupinstall "Development Tools"

cd nim_usockets/usockets
make clean && make

cd ../..
nim c -d:release --opt:speed \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
  --path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
  --path:vendor/jsony/src --path:vendor/checksums \
  --passL:"nim_usockets/usockets/uSockets.a -lpthread -ldl" \
  app.nim
```

### macOS

```bash
xcode-select --install

cd nim_usockets/usockets
make clean && WITH_GCD=1 make

cd ../..
nim c -d:release --opt:speed \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --passL:"nim_usockets/usockets/uSockets.a -framework CoreFoundation" \
  app.nim
```

### Windows

```bash
cd nim_usockets/usockets
make clean && make

cd ../..
nim c -d:release --opt:speed ^
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src ^
  --passL:"nim_usockets/usockets/uSockets.a" ^
  app.nim
```

> Import modules individually instead of `nim_utils` to avoid pulling in the POSIX-only `async_logger`.

### Building with TLS

```bash
cd nim_usockets/usockets
make clean
WITH_OPENSSL=1 make

# Or with BoringSSL (must build BoringSSL first)
make boringssl
WITH_BORINGSSL=1 make
```

Then compile your app with SSL link flags:

```bash
nim c -d:release \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
  --path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
  --path:vendor/jsony/src --path:vendor/checksums \
  --passL:"nim_usockets/usockets/uSockets.a -lssl -lcrypto -lpthread -ldl" \
  app.nim
```

### uSockets Build Options

| Variable | Default | Description |
|----------|---------|-------------|
| `WITH_GCD=1` | Off | Use Grand Central Dispatch event loop (required on macOS) |
| `WITH_OPENSSL=1` | Off | Link against OpenSSL for TLS support |
| `WITH_BORINGSSL=1` | Off | Link against BoringSSL instead of OpenSSL |
| `WITH_LIBUV=1` | Off | Use libuv as the event loop backend instead of native epoll/kqueue |
| `WITH_WOLFSSL=1` | Off | Link against wolfSSL for TLS |

### Docker

```bash
docker build -t nim-uwebsocket .

docker build --build-arg USOCKETS_BACKEND=io_uring -t nim-uwebsocket:iouring .

docker build --build-arg APP_SOURCE=examples/hello_app.nim -t my-app .

docker run -p 3000:3000 nim-uwebsocket

docker run --security-opt seccomp=unconfined -p 3000:3000 nim-uwebsocket:iouring

docker compose up
```

The default Docker image uses epoll. io_uring images require a host kernel with io_uring enabled and a seccomp profile that permits io_uring syscalls; `--security-opt seccomp=unconfined` is the simplest smoke-test setting, while production deployments should use an explicit allowlist profile.

#### Docker Build Arguments

| Arg | Default | Description |
|-----|---------|-------------|
| `NIM_VERSION` | `2.2.10` | Nim compiler version |
| `WITH_OPENSSL` | `0` | Enable OpenSSL (`1` to enable) |
| `USOCKETS_BACKEND` | `epoll` | Linux event loop backend: `epoll` or `io_uring` |
| `TCP_FASTOPEN_QUEUE` | `4096` | TCP Fast Open queue length compiled into uSockets |
| `IOURING_MAX_CONNECTIONS` | `65536` | Registered-file capacity for io_uring builds |
| `IOURING_RECV_BUFFERS` | `8192` | Registered receive-buffer count for io_uring builds |
| `IOURING_RECV_BUFFER_SIZE` | `2048` | Per-buffer receive size for io_uring provided buffers |
| `IOURING_ENTRIES` | `2048` | io_uring submission/completion queue depth |
| `SSL_LINK_FLAGS` | *(empty)* | Additional link flags for SSL |
| `APP_SOURCE` | `benchmark/bench_nim_express.nim` | Nim source file to compile |
| `APP_BINARY` | `app` | Output binary name |

## Performance

Single-process on Apple M-series, `wrk -t4 -c100 -d30s /json`:

| Metric | nim_express | Node ultimate-express |
|--------|-------------|----------------------|
| Throughput | **~95k req/s** | ~66k req/s |
| p50 latency | ~1.0 ms | ~1.5 ms |
| p99 latency | ~1.2 ms | ~2.3 ms |

Clustered (4 workers): **~130k req/s**

**43% faster throughput** and **48% lower p99 latency** compared to Node.js ultimate-express.

### Performance Optimizations

- SIMD-accelerated HTTP parsing (NEON on ARM64, SSE2 on x86_64)
- Pre-computed status line strings — no allocation per response
- Single-pass HTTP header parsing
- Single socket write (headers + body combined)
- Fast integer-to-string via digit-pairs lookup table
- Compile-time JSON field planning with SIMD string escape scanning
- Object pools for zero-GC-pressure request handling
- Adaptive write coalescing (latency, balanced, throughput, adaptive modes)
- dragonbox float formatting

## Performance Tuning

### Nim Compiler Flags

| Flag | Effect | Use Case |
|------|--------|----------|
| `-d:release` | Disables runtime assertions, enables `{.push checks: off.}` in hot paths | Production builds |
| `-d:danger` | Everything in `-d:release` plus disables all bounds, overflow, and nil checks | Benchmarks only — not safe for production |
| `-d:lto` | Link-time optimization — cross-module inlining, dead code elimination | Maximum binary performance |
| `--opt:speed` | Compiler optimization level `-O3` | Always use for production |
| `--panics:off` | Converts `Defect` exceptions into catchable errors instead of `abort()` | Required for Defect-recovery middleware |
| `--threads:on` | Enables multi-threading support | Required for `runThreaded` |
| `--gc:orc` | ORC garbage collector (default in Nim 2.x) — deterministic, cycle-collecting | Default, recommended |
| `--gc:arc` | ARC garbage collector — no cycle collection, lower overhead | Use when you can guarantee no reference cycles |

#### Build Mode Comparison

| Mode | Flags | Safety | Speed | Use |
|------|-------|--------|-------|-----|
| **Debug** | *(none)* | Full checks, stack traces | Slowest | Development, debugging |
| **Release** | `-d:release --opt:speed` | Assertions off, some checks remain | Fast | Production |
| **Release + LTO** | `-d:release --opt:speed -d:lto` | Same as release | Faster | Production (longer compile) |
| **Danger** | `-d:danger --opt:speed` | All checks off | Fastest | Benchmarks only |

Example production build with all recommended flags:

```bash
nim c -d:release --opt:speed -d:lto --gc:orc --panics:off \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
  --path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
  --path:vendor/jsony/src --path:vendor/checksums \
  --passL:"nim_usockets/usockets/uSockets.a -lpthread -ldl" \
  app.nim
```

### OS-Level Tuning

#### File Descriptors

Each connection consumes one file descriptor. The default limit (typically 1024) is far too low for production:

```bash
# Check current limits
ulimit -n

# Set for the current session
ulimit -n 65536

# Permanent (Linux) — add to /etc/security/limits.conf:
# *    soft    nofile    65536
# *    hard    nofile    65536

# Or via systemd service:
# [Service]
# LimitNOFILE=65536
```

#### TCP Kernel Parameters (Linux)

```bash
# Increase connection backlog
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.core.netdev_max_backlog=65535

# Increase local port range for outbound connections
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# Enable TCP fast open
sudo sysctl -w net.ipv4.tcp_fastopen=3

# Tune TCP memory
sudo sysctl -w net.ipv4.tcp_mem="786432 1048576 1572864"
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"

# Enable TCP window scaling
sudo sysctl -w net.ipv4.tcp_window_scaling=1

# Reduce TIME_WAIT sockets
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
sudo sysctl -w net.ipv4.tcp_fin_timeout=15
```

To persist across reboots, add these to `/etc/sysctl.conf` or a file in `/etc/sysctl.d/`.

#### macOS Kernel Parameters

```bash
sudo sysctl -w kern.maxfiles=65536
sudo sysctl -w kern.maxfilesperproc=65536
sudo sysctl -w net.inet.tcp.msl=15000
```

### Network Tuning

These settings are configurable via `config.json`, environment variables, or named profiles.

| Setting | Config Key | Env Variable | Effect |
|---------|-----------|--------------|--------|
| **TCP_NODELAY** | `socket.noDelay` | `NIM_EXPRESS_SOCKET_NODELAY` | Disables Nagle's algorithm — lower latency, more syscalls |
| **TCP_CORK** | *(via write coalescing)* | `NIM_EXPRESS_WRITE_COALESCE_MODE` | Batches small writes into fewer syscalls — higher throughput |
| **SO_REUSEPORT** | *(automatic in `runCluster`)* | — | Kernel-level load balancing across processes (Linux only) |
| **TCP_FASTOPEN** | `socket.fastOpen` | `NIM_EXPRESS_SOCKET_FASTOPEN` | Sends data in the SYN packet — saves one RTT on new connections |
| **SO_SNDBUF** | `socket.sendBufferBytes` | `NIM_EXPRESS_SOCKET_SNDBUF` | Socket send buffer size in bytes |
| **SO_RCVBUF** | `socket.recvBufferBytes` | `NIM_EXPRESS_SOCKET_RCVBUF` | Socket receive buffer size in bytes |
| **TCP_NOTSENT_LOWAT** | `socket.notSentLowWaterBytes` | `NIM_EXPRESS_SOCKET_NOTSENT_LOWAT` | Wake writer only when unsent data drops below threshold (reduces wakeups) |
| **TCP_DEFER_ACCEPT** | `socket.deferAcceptSeconds` | `NIM_EXPRESS_SOCKET_DEFER_ACCEPT_SEC` | Delay accept until data arrives — filters idle connections (Linux) |
| **SO_INCOMING_CPU** | `socket.incomingCpu` | `NIM_EXPRESS_SOCKET_INCOMING_CPU` | Pin incoming connections to a specific CPU (Linux) |
| **Listen backlog** | `net.core.somaxconn` (sysctl) | — | Maximum pending connection queue depth |

### Scaling Strategy Guide

| Scenario | Strategy | Why |
|----------|----------|-----|
| **Linux, max throughput** | `runCluster` with `numWorkers = CPU count` | Independent processes, no GIL, kernel-level SO_REUSEPORT distribution |
| **Linux, shared state needed** | `runThreaded` with `numThreads = CPU count` | Threads share memory; use `{.gcsafe.}` carefully |
| **Linux, mixed** | `runCluster` + per-worker threads | Processes for isolation, threads for I/O within each worker |
| **macOS, development** | Single process (`app.run(3000)`) | GCD limitation prevents effective multi-threading |
| **macOS, load testing** | Multiple processes on different ports + nginx | `./bench_multiport 3010 4` then nginx upstream |
| **Windows** | Single process | No fork, no SO_REUSEPORT |
| **Docker / Kubernetes** | `runAuto` per container or single process with replicas | Use replicas for isolation; use in-container workers only when CPU and memory limits are sized for them |
| **Auto-detect** | `runAuto(createApp, 3000)` | Picks cluster on Linux, single process elsewhere |

```nim
# Threads vs. processes — quick reference
runCluster(createApp, 3000, numWorkers = 4)   # 4 independent processes
runThreaded(createApp, 3000, numThreads = 4)  # 4 threads in one process
runAuto(createApp, 3000)                      # platform-aware auto-selection
```

### Memory Tuning

**Garbage collector.** Nim 2.x defaults to ORC (deterministic, cycle-collecting). For request-handling hot paths, the framework uses object pools to avoid GC pressure entirely. If your application creates no reference cycles, `--gc:arc` has lower overhead.

**Context pool pre-warming.** Pre-allocate request/response context objects at startup to avoid allocation spikes on the first burst of traffic:

```json
{
  "runtime": {
    "contextPoolPrewarm": 512,
    "requestResponsePoolingEnabled": true
  }
}
```

**Max connections.** Cap the maximum number of concurrent connections to prevent memory exhaustion:

```json
{
  "server": {
    "maxConnections": 10000,
    "maxPendingBytesPerSocket": 1048576
  }
}
```

**Per-connection memory budget.** The framework enforces a 32MB default per-connection memory cap. Large request bodies can be spilled to disk:

```json
{
  "body": {
    "spillThresholdBytes": 1048576,
    "spillDir": "/tmp/nim_express_spill"
  }
}
```

**Buffer pre-allocation for JSON.** Use `serializeDirectInto` with a pre-sized buffer to eliminate per-request allocation in the JSON hot path:

```nim
var buf {.threadvar.}: string

proc handleJson(req: Request, res: Response) =
  if buf.len == 0:
    buf = newStringOfCap(4096)
  buf.setLen(0)
  serializeDirectInto(buf, myData)
  res.send(buf, "application/json")
```

### Write Coalescing

The framework batches multiple HTTP responses into fewer socket writes. Choose a mode that matches your workload:

| Mode | Behavior | Best For |
|------|----------|----------|
| `latency` | Flush after every response | Real-time APIs, WebSocket |
| `balanced` | Small batches (16 responses / 64KB) | Mixed workloads |
| `throughput` | Large batches (48–256 responses / 256KB) | Bulk APIs, benchmarks |
| `adaptive` | Auto-adjusts batch size based on backlog | Variable traffic patterns |

```json
{
  "coalesce": {
    "mode": "throughput",
    "maxBytes": 262144,
    "maxResponses": 128
  }
}
```

### Overload Protection

The framework includes built-in overload shedding — it rejects requests with HTTP 503 when the system is saturated, preventing cascading failure:

```json
{
  "overload": {
    "maxBacklogBytes": 8388608,
    "maxPendingResponses": 4096,
    "closeOnReject": false,
    "adaptive": {
      "enabled": true,
      "minBacklogBytes": 1048576,
      "maxBacklogBytes": 16777216,
      "tightenStepPercent": 10,
      "relaxStepPercent": 5,
      "cooldownRequests": 100
    }
  }
}
```

### Monitoring and Metrics

Use `optimizationMetricsJson` to inspect runtime performance counters. This returns a JSON object with current buffer utilization, coalescing statistics, connection counts, and overload status — useful for dashboards and alerting:

```nim
app.get("/metrics") do (req: Request, res: Response):
  res.send(app.optimizationMetricsJson(), "application/json")
```

### Profiling Guidance

**CPU profiling.** Compile with frame pointers for accurate profiling:

```bash
nim c -d:release --opt:speed --passC:"-fno-omit-frame-pointer" \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
  --path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
  --path:vendor/jsony/src --path:vendor/checksums \
  --passL:"nim_usockets/usockets/uSockets.a -lpthread -ldl" app.nim
```

Then use your preferred profiler:

```bash
# Linux — perf
perf record -g ./app
perf report

# macOS — Instruments
xcrun xctrace record --template "Time Profiler" --launch ./app

# Any platform — valgrind (slower but more detailed)
valgrind --tool=callgrind ./app
```

**Latency profiling.** Use `wrk` with latency reporting to establish a baseline:

```bash
wrk -t4 -c100 -d30s --latency http://localhost:3000/json
```

**Memory profiling.** Nim's ORC GC is deterministic — use `valgrind --tool=massif` or track allocations via `--gc:orc -d:nimAllocStats`.

## Standards Compliance

| Standard | Coverage | Subproject |
|----------|----------|------------|
| **HTTP/1.1** (RFC 7230–7235) | Request/response lifecycle, keep-alive, chunked transfer, content negotiation | nim_usockets, nim_express |
| **HTTP/2** (RFC 7540/9113) | Frame types, HPACK header compression, flow control, stream states, settings negotiation | nim_usockets |
| **WebSocket** (RFC 6455) | Full handshake, frame masking, per-message compression, close handshake, ping/pong | nim_usockets, nim_express |
| **JSON** (RFC 8259) | Strict parsing — rejects leading zeros, leading `+`, incomplete fractions/exponents, unescaped control chars, `NaN`/`Infinity`; depth limit of 512 | nim_utils (nim_fastjson) |
| **RFC 7807** | Problem Details error responses from error_handler middleware | nim_express |
| **HPACK** (RFC 7541) | Header compression for HTTP/2 — static table, dynamic table, Huffman encoding | nim_usockets |
| **TLS 1.2/1.3** | Via OpenSSL or BoringSSL through uSockets | nim_usockets (uSockets) |

## Configuration

### config.json

Place a `config.json` in the working directory or mount to `/etc/nim_express/config.json`:

```json
{
  "profile": "linux-throughput",
  "server": { "host": "0.0.0.0", "port": 3000, "trustProxy": false },
  "runtime": { "asyncPumpIntervalMs": 1, "maxInflightAsyncRequests": 8192 },
  "socket": {
    "noDelay": true, "keepAlive": true,
    "sendBufferBytes": 524288, "recvBufferBytes": 524288
  },
  "coalesce": { "mode": "throughput" },
  "overload": {
    "maxBacklogBytes": 8388608, "maxPendingResponses": 4096,
    "adaptive": { "enabled": true }
  },
  "websocket": { "compression": { "enabled": true, "thresholdBytes": 1024 } }
}
```

### Named Profiles

| Profile | Optimized For |
|---------|--------------|
| `linux-throughput` | Maximum req/s on Linux (aggressive coalescing, large buffers) |
| `throughput` | General throughput across platforms |
| `latency` | Minimum response latency |
| `websocket` | WebSocket-heavy workloads |
| `balanced` | Mixed workloads |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `NIM_EXPRESS_PROFILE` | Config profile name |
| `NIM_EXPRESS_SCALE_MODE` | Scaling strategy: `auto`, `cluster`, `threaded` |
| `NIM_EXPRESS_WORKERS` | Number of cluster workers (0 = auto) |
| `NIM_EXPRESS_THREADS` | Number of threads (0 = auto) |
| `NIM_EXPRESS_BASE_PORT` | Base listening port |
| `NIM_EXPRESS_CPU_LIST` | CPU affinity list (e.g., `0-7`) |
| `NIM_EXPRESS_NUMA_NODE` | NUMA node binding |
| `NIM_EXPRESS_CONFIG` | Path to config JSON file |

### Production Configuration

For process crash recovery from Defect errors (nil access, index out of bounds, assertion failures), compile with `--panics:off`:

```bash
nim c -d:release --panics:off app.nim
```

In Nim 2.x with the default ORC memory manager, `--panics:on` is the default, which means `except Defect` handlers are dead code — Defects cause an immediate `abort()`. The middleware Defect handlers (`panic_recovery`, `error_handler`, `global_error_filter`, `circuit_breaker`, `proxy`, `graceful_shutdown`, `logger`, `json_logger`) only function when compiled with `--panics:off`.

A compile-time hint is emitted when this flag is missing. CI tests are run with `--panics:off` to exercise Defect recovery paths.

## Middleware

### Built-in Middleware (36 total)

| Middleware | Description |
|------------|-------------|
| Compression | gzip, brotli, zstd, deflate with configurable thresholds |
| CORS | Cross-origin resource sharing headers |
| Rate Limiting | Request rate limiting per client |
| Static Files | Serve files from a directory with ETag support |
| Security Headers | HSTS, X-Frame-Options, CSP, etc. |
| Logger | Request/response logging with multiple formats (dev, common, combined, short, tiny) |
| JSON Logger | NDJSON structured logging with configurable fields and custom sinks |
| Auth | Authentication middleware hooks |
| ETag | Conditional response caching |
| Error Handler | RFC 7807 Problem Details responses with dev/production modes |
| Panic Recovery | Generic 500 responder for uncaught exceptions and Defects |
| Global Error Filter | Ordered exception filters (ASP.NET-style) with built-in handlers for ValueError, KeyError, IOError, etc. |
| Circuit Breaker | Classic closed/open/half-open breaker with 503 + Retry-After |
| Graceful Shutdown | SIGTERM handling, in-flight drain, 503 during shutdown |
| Proxy | Reverse proxy with hop-by-hop header stripping, X-Forwarded-* support, CONNECT/TRACE blocking |

```nim
let app = newExpressApp()
app.use(compressionMiddleware())
app.use(corsMiddleware(origins = @["*"]))
app.use(rateLimitMiddleware(maxRequests = 100, windowSecs = 60))
```

## Platform Scaling

| Platform | Multi-process | Multi-thread | Recommended |
|----------|--------------|--------------|-------------|
| Linux | `runCluster` (SO_REUSEPORT) | `runThreaded` (epoll) | `runCluster` or `runThreaded` |
| macOS | Limited (no LB on SO_REUSEPORT) | Limited (GCD) | Single process + nginx |
| Windows | Not supported | Not supported | Single process |

### macOS Scaling with nginx

```bash
./bench_multiport 3010 4

nginx -c /path/to/nginx_loadbalancer.conf
```

## Security

- Defect recovery middleware with `--panics:off` support
- Slowloris protection via header/body read timeouts (30s defaults)
- SSRF protection in proxy middleware (private IP blocklist)
- CONNECT/TRACE method blocking in proxy
- Log injection prevention via `sanitizeLogField`
- RFC 7807 Problem Details error responses (no stack traces in production)
- Per-connection memory budgets (32MB default)
- Request size limits (headers 16KB, body 10MB, URI 8KB)

## Testing

71 test files with ~485+ test cases including fuzz testing.

```bash
nimble test

nim c -r --panics:off nim_express/tests/test_router.nim
nim c -r nim_usockets/tests/test_h2_compliance_fixes.nim
nim c -r nim_utils/nim_fastjson/tests/test_rfc8259_compliance_fixes.nim
```

## CI/CD

GitHub Actions runs on every push and PR:

- **Platforms:** Ubuntu (latest) and macOS (latest)
- **Compiler:** Nim 2.2.10
- **Tests:** All test suites across nim_express, nim_usockets, nim_utils, and nim_fastjson
- **Fuzz tests:** Included (non-blocking)
- **Release:** Automated on `v*` tags with CHANGELOG body and benchmark binary artifact

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Build uSockets for your platform (see [Building from Source](#building-from-source))
4. Make your changes and add tests
5. Run the test suite: `nimble test`
6. Submit a pull request

## License

MIT
