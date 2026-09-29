# nim_fasthttpclient

High-performance async HTTP client for Nim, built on [nim_usockets](../nim_usockets). Supports HTTP/1.1, HTTP/2 with HPACK header compression, WebSocket, and Server-Sent Events — all driven by the same event loop that powers `nim_express`.

## Features

- **HTTP/1.1** — full request/response lifecycle, persistent connections (keep-alive), chunked transfer encoding
- **HTTP/2** — stream multiplexing, HPACK header compression, flow control, server push
- **WebSocket Client** — RFC 6455 upgrade handshake, binary and text frames
- **Server-Sent Events** — streaming event consumption with automatic reconnection
- **Connection Pooling** — per-host connection reuse with configurable pool size
- **TLS/SSL** — OpenSSL and BoringSSL backends via uSockets
- **Streaming Responses** — process response bodies incrementally without buffering
- **Async I/O** — non-blocking, event-loop-driven architecture (no threads required)
- **Zero-copy Parsing** — minimal allocations on the hot path

## Platform Support

| Platform | Status | Event Loop | Notes |
|----------|--------|------------|-------|
| **Linux** (x86_64, aarch64) | Fully supported | epoll | Recommended for production |
| **macOS** (Apple Silicon, x86_64) | Fully supported | kqueue / GCD | Requires `-framework CoreFoundation` |
| **Windows** | Not yet supported | — | Planned |

### Platform-specific Details

**Linux** — Uses `epoll` for I/O multiplexing. No additional frameworks or link flags are needed beyond the standard C library. `SO_REUSEPORT` and `EPOLL_EXCLUSIVE` are available for multi-process workloads. This is the recommended platform for production deployments.

**macOS** — Uses GCD (Grand Central Dispatch) via `kqueue`. uSockets must be built with `WITH_GCD=1`, and every compile command must include `-framework CoreFoundation`. Homebrew-installed OpenSSL is not on the default linker search path; you will need to pass explicit `-L` and `-I` flags (see [Troubleshooting](#openssl-not-found)). Apple Silicon and Intel are both supported — Homebrew installs to `/opt/homebrew` on ARM and `/usr/local` on x86_64.

### Build Requirements

| Platform | Toolchain |
|----------|-----------|
| Linux | `gcc`, `make`, `build-essential` |
| macOS | Xcode Command Line Tools (`xcode-select --install`) |

## Prerequisites

- **Nim** >= 2.0.0
- **nim_usockets** >= 0.1.0 (sibling package in this repo)
- **OpenSSL** (for TLS/SSL) — optional, required only for HTTPS

```bash
# macOS
brew install openssl

# Ubuntu / Debian
sudo apt install libssl-dev

# Fedora / RHEL
sudo dnf install openssl-devel

# Alpine
apk add openssl-dev
```

## Installation

### From the monorepo (recommended)

```bash
cd nim_uwebsocket/nim_fasthttpclient
nimble install
```

### As a dependency

Add to your `.nimble` file:

```nim
requires "nim_fasthttpclient >= 0.1.0"
requires "nim_usockets >= 0.1.0"
```

## Quick Start

### GET Request

```nim
import nim_fasthttpclient

let client = newHttpClient()

let resp = client.get("http://httpbin.org/get")
echo resp.status
echo resp.body

client.close()
```

### POST with JSON Body

```nim
import nim_fasthttpclient

let client = newHttpClient()

let resp = client.post("http://httpbin.org/post",
  headers = {"Content-Type": "application/json"},
  body = """{"name": "nim", "version": 2}"""
)
echo resp.status
echo resp.body

client.close()
```

### Custom Headers

```nim
import nim_fasthttpclient

let client = newHttpClient()

let resp = client.get("https://api.example.com/data",
  headers = {
    "Authorization": "Bearer my-token",
    "Accept": "application/json",
    "X-Request-Id": "abc-123"
  }
)

client.close()
```

## API Reference

### Creating Clients

```nim
let client = newHttpClient()

let configured = newHttpClient(
  maxConnectionsPerHost = 10,
  connectTimeoutMs = 5000,
  requestTimeoutMs = 30000,
  keepAlive = true
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `maxConnectionsPerHost` | `int` | `6` | Max pooled connections per host:port |
| `connectTimeoutMs` | `int` | `10000` | TCP connect timeout in milliseconds |
| `requestTimeoutMs` | `int` | `30000` | Overall request timeout in milliseconds |
| `keepAlive` | `bool` | `true` | Reuse connections across requests |

### Request Methods

All methods return an `HttpClientResponse` and accept optional `headers` and `body` parameters.

```nim
let resp = client.get(url)
let resp = client.post(url, body = data)
let resp = client.put(url, body = data)
let resp = client.delete(url)
let resp = client.patch(url, body = data)
let resp = client.head(url)
let resp = client.options(url)
```

For full control, use the generic `request` method:

```nim
let resp = client.request(
  method = HttpMethod.hmPost,
  url = "https://api.example.com/resource",
  headers = {"Content-Type": "application/json"},
  body = """{"key": "value"}"""
)
```

### Request / Response Types

```nim
type HttpClientResponse = object
  status: int
  statusText: string
  headers: seq[(string, string)]
  body: string
  httpVersion: string
```

Access response data:

```nim
let resp = client.get("https://example.com")
echo resp.status
echo resp.statusText
echo resp.body
echo resp.httpVersion

for (name, value) in resp.headers:
  echo name, ": ", value
```

### Headers

Pass headers as an `openArray` of tuples:

```nim
let resp = client.get("https://example.com",
  headers = {
    "Accept": "text/html",
    "Accept-Language": "en-US",
    "Cache-Control": "no-cache"
  }
)
```

Read response headers:

```nim
for (name, value) in resp.headers:
  if name == "content-type":
    echo "Content type: ", value
```

### Timeouts

Timeouts are configured at client creation and apply to all requests:

```nim
let client = newHttpClient(
  connectTimeoutMs = 5000,
  requestTimeoutMs = 30000
)
```

| Timeout | Scope | Description |
|---------|-------|-------------|
| `connectTimeoutMs` | Per connection | TCP + TLS handshake deadline |
| `requestTimeoutMs` | Per request | Total time from send to last response byte |

When a timeout fires, the request fails with `HttpTimeoutError`.

### TLS/SSL Configuration

HTTPS works automatically when the URL scheme is `https://`. The client uses the system CA bundle by default.

```nim
let resp = client.get("https://secure.example.com/api")
```

For custom TLS settings (client certificates, pinned CAs, etc.):

```nim
import nim_usockets

let tlsOpts = UsSocketContextOptions(
  certFileName: "client.pem",
  keyFileName: "client-key.pem",
  caFileName: "ca-bundle.crt",
  passphrase: nil,
  sslCiphers: nil,
  sslPreferLowMemoryUsage: 0
)

let client = newHttpClient(tlsOptions = tlsOpts)
let resp = client.get("https://mtls.example.com/api")
```

To build with TLS support, link against OpenSSL and a TLS-enabled uSockets:

```bash
# Build uSockets with OpenSSL
cd nim_usockets/usockets
make clean && WITH_OPENSSL=1 make

# Compile your application
nim c -d:release \
  --path:../nim_usockets/src \
  --passL:"../nim_usockets/usockets/uSockets.a -lssl -lcrypto" \
  app.nim
```

### Connection Pooling

Connections are pooled per `host:port` pair. Keep-alive is enabled by default.

```nim
let client = newHttpClient(maxConnectionsPerHost = 10)

for i in 0 ..< 100:
  let resp = client.get("http://api.example.com/items/" & $i)
  echo resp.status
```

The pool automatically:
- Reuses idle connections for subsequent requests to the same host
- Closes connections that have been idle beyond the keep-alive timeout
- Creates new connections when the pool is empty
- Respects the server's `Connection: close` header

### Streaming Responses

Process large response bodies without buffering the entire payload:

```nim
client.getStream("http://example.com/large-file.bin") do (chunk: openArray[byte]):
  file.writeBuffer(unsafeAddr chunk[0], chunk.len)
```

### HTTP/2

HTTP/2 is negotiated automatically via ALPN during the TLS handshake. No API changes are required — the same request methods work transparently.

```nim
let client = newHttpClient()
let resp = client.get("https://http2-enabled.example.com/api")
echo resp.httpVersion
```

HTTP/2 features used internally:
- **HPACK** header compression (RFC 7541)
- Stream multiplexing
- Flow control with `WINDOW_UPDATE`
- `SETTINGS` negotiation
- `PING` / `GOAWAY` handling

### Server-Sent Events (SSE)

Consume an SSE stream:

```nim
client.sse("http://example.com/events") do (event: SseEvent):
  echo "event: ", event.name
  echo "data: ", event.data
  echo "id: ", event.id
```

### WebSocket Client

Open a WebSocket connection:

```nim
let ws = client.websocket("ws://example.com/ws")

ws.send("hello")

ws.onMessage do (data: string, opcode: int):
  echo "received: ", data

ws.onClose do (code: int, reason: string):
  echo "closed: ", code

ws.close()
```

## Building

### macOS

```bash
# Build uSockets
cd nim_usockets/usockets
make clean && WITH_GCD=1 make

# HTTP only (no TLS)
nim c -d:release --opt:speed \
  --path:../nim_usockets/src \
  --passL:"../nim_usockets/usockets/uSockets.a -framework CoreFoundation" \
  -o:bin/myapp app.nim

# With TLS
cd nim_usockets/usockets && make clean && WITH_GCD=1 WITH_OPENSSL=1 make && cd -

nim c -d:release --opt:speed \
  --path:../nim_usockets/src \
  --passL:"../nim_usockets/usockets/uSockets.a -lssl -lcrypto -framework CoreFoundation" \
  -o:bin/myapp app.nim
```

On Apple Silicon, if Homebrew OpenSSL is not found by the linker:

```bash
nim c -d:release --opt:speed \
  --path:../nim_usockets/src \
  --passC:"-I/opt/homebrew/opt/openssl/include" \
  --passL:"-L/opt/homebrew/opt/openssl/lib" \
  --passL:"../nim_usockets/usockets/uSockets.a -lssl -lcrypto -framework CoreFoundation" \
  -o:bin/myapp app.nim
```

### Linux

```bash
# Build uSockets
cd ../nim_usockets/usockets
make clean && make

# HTTP only (no TLS)
nim c -d:release --opt:speed \
  --path:../nim_usockets/src \
  --passL:"../nim_usockets/usockets/uSockets.a -lpthread -ldl" \
  -o:bin/myapp app.nim

# With TLS
cd ../nim_usockets/usockets && make clean && WITH_OPENSSL=1 make && cd -

nim c -d:release --opt:speed \
  --path:../nim_usockets/src \
  --passL:"../nim_usockets/usockets/uSockets.a -lssl -lcrypto -lpthread -ldl" \
  -o:bin/myapp app.nim
```

### Compile-time Flags

| Flag | Effect |
|------|--------|
| `-d:release` | Enable optimizations, disable runtime checks |
| `--opt:speed` | Optimize for throughput |
| `-d:danger` | Maximum speed, no bounds checking |
| `-d:lto` | Link-time optimization — cross-module inlining |
| `-d:perfModeThroughput` | Tune internal buffers for throughput |
| `-d:perfModeLatency` | Tune internal buffers for low latency |

## Performance Tuning

This section covers how to extract maximum throughput and minimum latency from `nim_fasthttpclient` in production workloads.

### Compile Flags for Production

Always compile with optimizations for production binaries:

```bash
# Good — release with speed optimizations
nim c -d:release --opt:speed app.nim

# Better — disable bounds checking for hot loops
nim c -d:danger --opt:speed app.nim

# Best — add link-time optimization for cross-module inlining
nim c -d:danger --opt:speed -d:lto app.nim
```

`-d:danger` removes array bounds checks, overflow checks, and nil checks. Only use this after your application is thoroughly tested — a buffer overread will segfault instead of raising a clean exception.

`-d:lto` enables GCC/Clang link-time optimization, allowing the compiler to inline across Nim modules and the uSockets C library. This typically yields an additional 5–15% throughput improvement.

### Connection Pooling Configuration

The pool size directly controls concurrency to a given backend. Too few connections serialize requests; too many overwhelm the server or exhaust file descriptors.

```nim
let client = newHttpClient(maxConnectionsPerHost = 20)
```

**Sizing guidelines:**

| Workload | Recommended Pool Size |
|----------|-----------------------|
| Low-traffic API client | 2–4 |
| Service-to-service (moderate) | 6–10 |
| High-throughput fanout | 16–32 |
| Bulk data ingest / scraping | 32–64 |

Each connection consumes one file descriptor. On Linux, check and raise limits if needed:

```bash
ulimit -n 65536
```

For persistent daemons, set limits in `/etc/security/limits.conf` or the systemd unit file (`LimitNOFILE=65536`).

### Keep-Alive Settings

Keep-alive is enabled by default and should remain on for nearly all use cases. Disabling it forces a new TCP (and potentially TLS) handshake per request.

```nim
let persistent = newHttpClient(keepAlive = true)

let oneshot = newHttpClient(keepAlive = false)
```

**When to disable keep-alive:**
- Talking to servers that misbehave with persistent connections
- Load testing where you want to stress connection establishment
- One-off requests to many distinct hosts (no reuse benefit)

**When to keep it on (the default):**
- Repeated requests to the same backend
- Any latency-sensitive path — you save 1–3 RTTs per request

### Timeout Tuning

The two timeout knobs serve different purposes:

```nim
let client = newHttpClient(
  connectTimeoutMs = 3000,
  requestTimeoutMs = 10000
)
```

**`connectTimeoutMs`** — How long to wait for TCP + TLS handshake. Set this aggressively low (1–5 seconds) for service-to-service calls within the same datacenter. A slow connect usually means the backend is down, and waiting longer just delays the failure.

**`requestTimeoutMs`** — How long from sending the request to receiving the last byte of the response. Set this based on the expected response time of the endpoint:

| Scenario | connectTimeoutMs | requestTimeoutMs |
|----------|-----------------|------------------|
| Same-datacenter microservice | 1000–2000 | 5000–10000 |
| Cross-region API | 3000–5000 | 15000–30000 |
| Large file download | 5000 | 120000–300000 |
| Health check / ping | 1000 | 2000 |

Lower timeouts improve tail-latency by failing fast, allowing your retry logic or circuit breaker to route around problems.

### TLS/SSL Performance

TLS adds latency and CPU overhead. Several options reduce its cost.

#### Session Caching

TLS session resumption avoids a full handshake on reconnected sockets. This is handled automatically by OpenSSL when connection pooling is enabled — reused connections inherit the existing TLS session.

#### Cipher Selection

Restrict ciphers to fast, modern options:

```nim
let tlsOpts = UsSocketContextOptions(
  sslCiphers: "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
  sslPreferLowMemoryUsage: 0
)

let client = newHttpClient(tlsOptions = tlsOpts)
```

- **AES-GCM** is fastest on CPUs with AES-NI (most x86_64 and recent ARM).
- **ChaCha20-Poly1305** is faster on hardware without AES-NI (older ARM, some embedded).
- Setting `sslPreferLowMemoryUsage` to `1` trades throughput for lower per-connection memory at the OpenSSL level. Leave at `0` unless memory-constrained.

#### TLS 1.3

TLS 1.3 reduces the handshake to 1 RTT (vs 2 RTTs for TLS 1.2) and supports 0-RTT resumption. It is negotiated automatically when both client and server support it. Ensure your OpenSSL is >= 1.1.1.

### Buffer Sizes

uSockets exposes per-socket send and receive buffer sizes via `us_socket_set_buffer_sizes`. The client's internal buffers are tuned with compile-time flags:

| Flag | Behavior |
|------|----------|
| `-d:perfModeThroughput` | Larger internal buffers — better for bulk transfers |
| `-d:perfModeLatency` | Smaller buffers — reduces memory per connection, faster small-message delivery |

**General guidance:**
- For API calls with small JSON payloads (< 64 KB), the defaults are optimal.
- For streaming large files or bulk data, use `-d:perfModeThroughput` and ensure OS-level socket buffers are also sized up:

```bash
# Linux — increase TCP buffer sizes
sudo sysctl -w net.core.rmem_max=16777216
sudo sysctl -w net.core.wmem_max=16777216
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"
```

### HTTP/2 vs HTTP/1.1

The client negotiates HTTP/2 automatically over TLS via ALPN. Understanding when each protocol wins helps you make the right tradeoff.

**Prefer HTTP/2 when:**
- Making many concurrent requests to the same host — stream multiplexing avoids the overhead of multiple TCP connections
- Servers return many small responses — HPACK header compression reduces overhead
- You want to reduce total connection count against a backend

**Prefer HTTP/1.1 when:**
- Downloading a single large file — HTTP/2 flow control and framing add overhead without benefit
- The server has poor HTTP/2 support or proxies strip it
- Responses are large and independent — HTTP/2 head-of-line blocking at the TCP layer can stall all streams when a packet is lost

To force HTTP/1.1 (bypass ALPN negotiation), connect on a non-TLS port or use a client configuration that does not advertise `h2`:

```nim
let http11Client = newHttpClient(forceHttp11 = true)
```

### Concurrent Request Patterns

Maximize throughput by issuing requests concurrently rather than sequentially:

```nim
import std/asyncdispatch

let client = newHttpClient(maxConnectionsPerHost = 20)

var futures: seq[Future[HttpClientResponse]]
for i in 0 ..< 100:
  futures.add client.getAsync("http://api.example.com/items/" & $i)

let responses = waitFor all(futures)
for resp in responses:
  echo resp.status
```

**Key considerations:**
- Match `maxConnectionsPerHost` to your concurrency level — if you issue 50 concurrent requests but the pool only holds 6 connections, 44 requests queue internally.
- Batch sizes should respect backend rate limits and connection capacity.
- For fan-out to many different hosts, total open connections = `maxConnectionsPerHost × number_of_hosts`. Monitor file descriptor usage.

### DNS Resolution Caching

DNS lookups add latency to the first request against a host. The underlying uSockets layer provides async DNS resolution (`us_dns_resolve_async`) and a cache-clearing API (`us_dns_cache_clear`).

**Best practices:**
- Connection pooling implicitly avoids repeated DNS lookups — reused connections already have a resolved address.
- For long-running services, DNS TTLs may expire while a cached address is still in use. If backends rotate IPs (e.g., behind AWS ELB), periodically close idle connections to force re-resolution.
- In containerized environments with short-lived DNS (Kubernetes services), consider shorter pool idle timeouts to pick up DNS changes promptly.

### TCP_NODELAY

By default, uSockets disables Nagle's algorithm (sets `TCP_NODELAY`), which means data is sent immediately without waiting to coalesce small writes. This is the right default for request/response protocols.

**Impact:**
- **Latency-sensitive workloads** — `TCP_NODELAY` is essential. Without it, small requests (like a short POST body sent after headers) may be delayed 40–200 ms by Nagle's algorithm.
- **Bulk transfers** — `TCP_NODELAY` has negligible impact because the data fills full-size segments regardless.

No application-level configuration is needed; the client sets this automatically.

### Memory Management

#### Reuse Client Instances

Creating a new `HttpClient` for every request is expensive — it allocates a connection pool, event loop resources, and TLS context. Create one client and share it:

```nim
let client = newHttpClient(maxConnectionsPerHost = 10)

proc fetchUser(id: int): HttpClientResponse =
  client.get("http://api.example.com/users/" & $id)

proc fetchOrder(id: int): HttpClientResponse =
  client.get("http://api.example.com/orders/" & $id)
```

If you need different configurations (e.g., different timeouts for different backends), create one client per configuration — not one per request.

#### Streaming Large Responses

Buffering entire responses in memory is the default behavior, which is fine for small payloads. For large responses, use the streaming API to process data in chunks:

```nim
var totalBytes = 0
client.getStream("http://cdn.example.com/dataset.csv") do (chunk: openArray[byte]):
  totalBytes += chunk.len
  outputFile.writeBuffer(unsafeAddr chunk[0], chunk.len)

echo "Downloaded ", totalBytes, " bytes"
```

This avoids allocating a single `string` that could be hundreds of megabytes. The chunk callback is invoked as data arrives from the socket, keeping memory usage proportional to the buffer size rather than the response size.

#### Pre-sizing and Allocation Hints

When building request bodies, pre-allocate strings to avoid repeated resizing:

```nim
var body = newStringOfCap(4096)
body.add """{"users": ["""
for i, user in users:
  if i > 0: body.add ","
  body.add serializeUser(user)
body.add "]}"

let resp = client.post("http://api.example.com/batch", body = body)
```

### Summary: Tuning Checklist

| Knob | Default | Throughput-optimal | Latency-optimal |
|------|---------|-------------------|-----------------|
| Compile flags | `-d:release` | `-d:danger -d:lto --opt:speed` | `-d:danger --opt:speed` |
| `maxConnectionsPerHost` | 6 | 16–64 | 4–8 |
| `keepAlive` | `true` | `true` | `true` |
| `connectTimeoutMs` | 10000 | 5000 | 1000–2000 |
| `requestTimeoutMs` | 30000 | 60000+ | 5000–10000 |
| Buffer tuning | default | `-d:perfModeThroughput` | `-d:perfModeLatency` |
| TLS ciphers | system default | AES-128-GCM | AES-128-GCM |
| HTTP version | auto (H2 over TLS) | H2 for multiplexing | H1.1 for single large transfers |

## Lifecycle Hooks

The client exposes lifecycle hooks that let you observe connection, request, and pool events without modifying client internals. All hooks are optional — nil callbacks are simply not invoked.

### Defining Hooks

Set callbacks on `HttpClientHooks` and attach them to the client via `HttpClientConfig`:

```nim
import nim_fasthttpclient

var config = defaultHttpClientConfig()
config.hooks.onConnectStart = proc(host: string, port: uint16, isTls: bool) {.gcsafe.} =
  echo "connecting to ", host, ":", port, " tls=", isTls

config.hooks.onResponseBody = proc(bodyBytes: int, totalDurationMs: float) {.gcsafe.} =
  echo "received ", bodyBytes, " bytes in ", totalDurationMs, "ms"

config.hooks.onRetry = proc(httpMethod: string, url: string, attempt: int, maxRetries: int, reason: string) {.gcsafe.} =
  echo "retry ", attempt, "/", maxRetries, " for ", httpMethod, " ", url, ": ", reason

var client = newHttpClientFromConfig(config)
```

Or assign hooks directly on an existing client:

```nim
var client = newHttpClient()
client.hooks.onRequestStart = proc(httpMethod: string, url: string, headers: seq[HttpHeader]) {.gcsafe.} =
  echo httpMethod, " ", url
```

### Available Hooks

#### Connection Lifecycle

| Hook | Signature | Fired When |
|------|-----------|------------|
| `onConnectStart` | `(host, port, isTls)` | Before TCP connection attempt |
| `onConnectEnd` | `(host, port, durationMs, error)` | After connection established or failed |
| `onConnectionReuse` | `(host, port)` | When a pooled connection is reused |
| `onConnectionClose` | `(host, port, reason)` | When connection is closed |

#### Request Lifecycle

| Hook | Signature | Fired When |
|------|-----------|------------|
| `onRequestStart` | `(method, url, headers)` | Before sending request |
| `onRequestHeadersSent` | `(method, url, headerBytes)` | After headers sent |
| `onResponseHeaders` | `(statusCode, headers, durationMs)` | When response headers received |
| `onResponseBody` | `(bodyBytes, totalDurationMs)` | When full response received |
| `onRequestError` | `(method, url, error, durationMs)` | On request failure |

#### Retry

| Hook | Signature | Fired When |
|------|-----------|------------|
| `onRetry` | `(method, url, attempt, maxRetries, reason)` | Before retry attempt |

#### Pool

| Hook | Signature | Fired When |
|------|-----------|------------|
| `onPoolAcquire` | `(host, port, poolSize, idle, active)` | Acquiring connection from pool |
| `onPoolRelease` | `(host, port, poolSize)` | Returning connection to pool |
| `onPoolEvict` | `(host, port, reason)` | Connection evicted from pool |

### Built-in Metrics Hooks

Use `newMetricsHooks()` to get pre-configured hooks that collect counters and timing data:

```nim
import nim_fasthttpclient

let (hooks, metrics) = newMetricsHooks()

var config = defaultHttpClientConfig()
config.hooks = hooks
var client = newHttpClientFromConfig(config)

# ... make requests ...

echo metricsJson(metrics)
# {"connectCount":5,"connectErrorCount":0,"connectTotalMs":42.3,...}
```

The `MetricsData` object tracks:
- `connectCount`, `connectErrorCount`, `connectTotalMs` — connection attempts and timing
- `requestCount`, `requestErrorCount` — request lifecycle
- `responseCount`, `responseTotalMs`, `responseTotalBytes` — response metrics
- `retryCount` — retry attempts
- `connectionReuseCount`, `connectionCloseCount` — connection reuse efficiency
- `poolAcquireCount`, `poolReleaseCount`, `poolEvictCount` — pool operations

### Custom Logging Hook Example

```nim
import std/times

var config = defaultHttpClientConfig()
config.hooks.onRequestStart = proc(httpMethod: string, url: string, headers: seq[HttpHeader]) {.gcsafe.} =
  echo "[", now().format("HH:mm:ss"), "] ", httpMethod, " ", url

config.hooks.onResponseBody = proc(bodyBytes: int, totalDurationMs: float) {.gcsafe.} =
  echo "[", now().format("HH:mm:ss"), "] response: ", bodyBytes, "B in ", totalDurationMs.formatFloat(ffDecimal, 1), "ms"

config.hooks.onRequestError = proc(httpMethod: string, url: string, error: string, durationMs: float) {.gcsafe.} =
  echo "[", now().format("HH:mm:ss"), "] ERROR: ", httpMethod, " ", url, " — ", error

var client = newHttpClientFromConfig(config)
```

## Error Handling

All errors are raised as exceptions inheriting from `HttpClientError`.

```nim
try:
  let resp = client.get("https://unreachable.example.com")
except HttpTimeoutError:
  echo "request timed out"
except HttpConnectionError:
  echo "could not connect"
except HttpTlsError:
  echo "TLS handshake failed"
except HttpClientError:
  echo "generic client error: ", getCurrentExceptionMsg()
```

### Error Hierarchy

| Exception | Cause |
|-----------|-------|
| `HttpClientError` | Base type for all client errors |
| `HttpTimeoutError` | Connect or request timeout exceeded |
| `HttpConnectionError` | TCP connection refused, reset, or DNS failure |
| `HttpTlsError` | Certificate verification failure, handshake error |
| `HttpProtocolError` | Malformed response, invalid HTTP framing |

### Retry Patterns

Not every error is worth retrying. Use the exception type to decide:

```nim
import std/os

proc fetchWithRetry(client: HttpClient, url: string, maxRetries = 3): HttpClientResponse =
  var lastErr: ref HttpClientError
  for attempt in 0 ..< maxRetries:
    try:
      return client.get(url)
    except HttpTimeoutError as e:
      lastErr = e
      sleep(100 * (1 shl attempt))
    except HttpConnectionError as e:
      lastErr = e
      sleep(100 * (1 shl attempt))
    except HttpTlsError:
      raise
    except HttpProtocolError:
      raise
  raise lastErr
```

**Retryable errors:**
- `HttpTimeoutError` — transient network congestion or server overload
- `HttpConnectionError` — backend may be restarting or a network blip occurred

**Non-retryable errors:**
- `HttpTlsError` — certificate issues won't resolve by retrying
- `HttpProtocolError` — the server is sending garbage; retrying produces the same result

**Backoff strategy:** Exponential backoff with jitter prevents thundering-herd retries from overloading a recovering backend. The example above doubles the delay on each attempt (100ms, 200ms, 400ms).

### HTTP Status Code Handling

The client does not raise exceptions for HTTP-level errors (4xx, 5xx). Check `resp.status` explicitly:

```nim
let resp = client.get("http://api.example.com/resource")

case resp.status
of 200 .. 299:
  echo "success: ", resp.body
of 429:
  echo "rate limited — retry after backoff"
of 500 .. 599:
  echo "server error — consider retry"
else:
  echo "unexpected status: ", resp.status
```

## Performance

`nim_fasthttpclient` is designed for high-throughput service-to-service communication. Key advantages over `std/httpclient`:

| Aspect | nim_fasthttpclient | std/httpclient |
|--------|-------------------|----------------|
| Event loop | uSockets (epoll/kqueue) | Nim asyncdispatch |
| Connection reuse | Built-in pool | Manual |
| HTTP/2 | Supported | Not supported |
| Allocations per request | Minimal (pre-allocated buffers) | Multiple heap allocs |
| Header parsing | Single-pass, zero-copy slices | String splits |

### Connection Reuse Benefits

Reusing connections eliminates per-request costs:
- TCP three-way handshake (~1 RTT)
- TLS handshake (~2 RTTs for TLS 1.2, ~1 RTT for TLS 1.3)
- TCP slow-start on new connections

For services making repeated calls to the same backend, connection pooling can reduce p99 latency by 50–80%.

## Troubleshooting

### OpenSSL Not Found

```
error: cannot find -lssl / -lcrypto
```

Ensure OpenSSL development headers are installed:

```bash
# macOS (Homebrew)
brew install openssl
export LIBRARY_PATH="/opt/homebrew/opt/openssl/lib:$LIBRARY_PATH"
export CPATH="/opt/homebrew/opt/openssl/include:$CPATH"

# Ubuntu / Debian
sudo apt install libssl-dev

# Fedora / RHEL
sudo dnf install openssl-devel
```

On macOS with Homebrew, you may need to pass explicit paths:

```bash
nim c -d:release \
  --passL:"-L/opt/homebrew/opt/openssl/lib" \
  --passC:"-I/opt/homebrew/opt/openssl/include" \
  --passL:"../nim_usockets/usockets/uSockets.a -lssl -lcrypto -framework CoreFoundation" \
  app.nim
```

On Intel Macs, replace `/opt/homebrew` with `/usr/local`:

```bash
nim c -d:release \
  --passL:"-L/usr/local/opt/openssl/lib" \
  --passC:"-I/usr/local/opt/openssl/include" \
  --passL:"../nim_usockets/usockets/uSockets.a -lssl -lcrypto -framework CoreFoundation" \
  app.nim
```

### DNS Resolution Failures

If DNS resolution fails, the client raises `HttpConnectionError`. Verify connectivity:

```bash
dig api.example.com

nc -zv api.example.com 443
```

For environments without system DNS (containers, sandboxed builds), point to an explicit resolver or use IP addresses directly.

### TLS Certificate Errors

```
HttpTlsError: certificate verify failed
```

Common causes:
- **Self-signed certificates** — provide the CA via `caFileName` in `UsSocketContextOptions`
- **Expired certificates** — check with `openssl s_client -connect host:443`
- **Missing system CA bundle** — install `ca-certificates` on Linux
- **Hostname mismatch** — the certificate's CN/SAN does not match the URL hostname

```bash
openssl s_client -connect api.example.com:443 -showcerts

openssl verify -CAfile ca-bundle.crt server.crt
```

### SIGSEGV on Startup (macOS)

Rebuild uSockets with GCD support and verify the CoreFoundation link flag:

```bash
cd nim_usockets/usockets
make clean && WITH_GCD=1 make
```

Ensure your compile command includes `-framework CoreFoundation`.

### Proxy Configuration

HTTP proxy support is not yet built in. For environments behind a corporate proxy, route traffic through an external tunnel (e.g., `socat`, `stunnel`) or configure OS-level proxy settings.

### Connection Pool Exhaustion

If all pooled connections are in use and new requests stall:
- Increase `maxConnectionsPerHost`
- Ensure responses are fully consumed (read the body or call `discard`)
- Check for leaked connections with logging
- Verify the backend isn't rate-limiting or holding connections open with slow responses

### Hanging Requests

Requests that never complete usually indicate one of:
- **Missing timeout configuration** — always set both `connectTimeoutMs` and `requestTimeoutMs`
- **Server sending data very slowly** — lower `requestTimeoutMs` to cap wait time
- **Event loop blocked** — avoid calling blocking I/O or `sleep()` from the event loop thread; use async alternatives

### High Memory Usage Under Load

- Switch to the streaming API (`getStream`) for large responses
- Reduce `maxConnectionsPerHost` if you don't need high concurrency
- Compile with `-d:perfModeLatency` to use smaller internal buffers
- Set `sslPreferLowMemoryUsage: 1` in `UsSocketContextOptions` to reduce per-connection TLS memory

## License

MIT
