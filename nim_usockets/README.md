# nim_usockets

Low-level, high-performance async networking library for Nim, powered by [uSockets](https://github.com/uNetworking/uSockets). Provides direct FFI bindings to the uSockets C library along with a batteries-included HTTP/1.1, HTTP/2, and WebSocket server implementation.

## Features

- **TCP sockets** — non-blocking I/O with per-socket extension data and backpressure tracking
- **UDP sockets** — packet buffer API for datagram send/receive with batched I/O
- **TLS/SSL** — OpenSSL-backed encryption with SNI, ALPN, configurable ciphers, and cert/key loading
- **HTTP/1.1 server** — zero-copy header parsing, chunked transfer encoding, `Expect: 100-continue`, keep-alive, and adaptive write coalescing
- **HTTP/2 server** — full frame parser, HPACK header compression, flow control, push promise, trailers, and GOAWAY
- **WebSocket server** — RFC 6455 compliant with per-message deflate compression, pub/sub topics, prepared messages, backpressure management, and keepalive pings
- **Timers** — periodic and one-shot timers integrated into the event loop
- **Event loop** — single-threaded reactor backed by platform-native I/O (epoll or io_uring on Linux, GCD on macOS)
- **Graceful shutdown** — configurable drain period with SIGINT/SIGTERM handling
- **Overload protection** — adaptive request rejection, backlog/pending limits, and spill-to-disk for large request bodies
- **Per-phase timeouts** — independent header-read, body-read, handler-exec, and write-drain timeout enforcement
- **SIMD/NEON/SSE2 parsing** — hardware-accelerated HTTP header scanning on ARM64 and x86-64

## Platform Support

| Platform | I/O Backend | Multi-thread | Multi-process | Status |
|----------|-------------|--------------|---------------|--------|
| **Linux** | epoll or io_uring | Yes | Yes (`SO_REUSEPORT`) | Fully supported |
| **macOS** | GCD | No (GCD limitation) | No (no effective load-balancing) | Fully supported (single-process) |
| **Windows** | — | — | — | Not yet supported |

### Linux

- epoll is the default backend; io_uring is available with `USOCKETS_BACKEND=io_uring` and liburing.
- `SO_REUSEPORT` distributes incoming connections across processes.
- `EPOLLEXCLUSIVE` prevents thundering-herd on shared listen sockets.
- `TCP_DEFER_ACCEPT`, `TCP_FASTOPEN`, `SO_INCOMING_CPU` are all available.
- Multi-threading and multi-process (`fork`) scaling both work.

### macOS

- GCD (Grand Central Dispatch) backend with CoreFoundation linkage.
- GCD does **not** function correctly in spawned threads. GCD builds require `listen` and `run` to start on the process main thread and fail fast otherwise; use single-process mode.
- `SO_REUSEPORT` allows binding but does **not** distribute connections across sockets.
- Scale horizontally with nginx/haproxy in front of multiple single-process instances on different ports.
- `pthread_set_qos_class_self_np` with `QOS_CLASS_USER_INITIATED` is applied when `macosHighQos` is enabled (default: true).

## Prerequisites

### General

- **Nim** >= 2.0.0
- **nimble** (ships with Nim)
- A C compiler (gcc or clang)

### Linux

```bash
# Debian/Ubuntu
sudo apt install build-essential libssl-dev

# Fedora/RHEL
sudo dnf install gcc make openssl-devel

# Arch
sudo pacman -S base-devel openssl
```

### macOS

```bash
xcode-select --install
brew install openssl
```

## Building uSockets

nim_usockets bundles the uSockets C source. You must compile the static library before using the Nim bindings.

### Linux

```bash
cd nim_usockets/usockets
make
```

### macOS

The GCD event loop backend is required on macOS:

```bash
cd nim_usockets/usockets
WITH_GCD=1 make
```

### With TLS support (either platform)

```bash
WITH_OPENSSL=1 make          # Linux
WITH_GCD=1 WITH_OPENSSL=1 make   # macOS
```

### Cleaning and rebuilding

```bash
make clean
WITH_GCD=1 make                 # macOS
WITH_IO_URING=1 make            # Linux io_uring
make                            # Linux epoll
```

## Installation

### Via nimble

```bash
nimble install
```

### Manual setup

```bash
nimble setup   # builds bundled uSockets sources
```

The nimble file declares the following dependencies:

```nim
requires "nim >= 2.0.0"
requires "zippy >= 0.10.0"
```

## Quick Start

### Minimal HTTP Server

```nim
import nim_usockets/http

let server = newHttpServer()

server.handle proc(req: HttpRequest, res: HttpResponse) =
  res.setHeader("content-type", "text/plain")
  res.send("Hello, World!")

server.listen("0.0.0.0", 3000) do(success: bool):
  if success:
    echo "Listening on http://localhost:3000"

server.run()
```

### JSON API Server

```nim
import nim_usockets/http

let server = newHttpServer()

server.handle proc(req: HttpRequest, res: HttpResponse) =
  case req.path
  of "/health":
    res.json("""{"status":"ok"}""")
  of "/echo":
    res.setHeader("content-type", "application/json")
    res.send(req.body)
  else:
    res.setStatus(Http404)
    res.json("""{"error":"not found"}""")

server.listen("0.0.0.0", 8080) do(success: bool):
  if success:
    echo "API server on :8080"

server.run()
```

### WebSocket Server

```nim
import nim_usockets/http

let server = newHttpServer()

server.handle proc(req: HttpRequest, res: HttpResponse) =
  if req.isWebSocketUpgrade():
    discard upgradeToWebSocket(req, res)
  else:
    res.send("Use WebSocket to connect")

server.onWebSocketOpen proc(ws: WebSocket) =
  echo "Client connected"
  ws.sendText("Welcome!")

server.onWebSocket proc(ws: WebSocket, message: string, isBinary: bool) =
  ws.send(message, isBinary)

server.onWebSocketClose proc(ws: WebSocket) =
  echo "Client disconnected"

server.listen("0.0.0.0", 9001) do(success: bool):
  if success:
    echo "WebSocket server on :9001"

server.run()
```

### WebSocket Pub/Sub

```nim
import nim_usockets/http

let server = newHttpServer()

server.handle proc(req: HttpRequest, res: HttpResponse) =
  if req.isWebSocketUpgrade():
    discard upgradeToWebSocket(req, res)
  else:
    res.send("WebSocket only")

server.onWebSocketOpen proc(ws: WebSocket) =
  discard ws.subscribe("chat")

server.onWebSocket proc(ws: WebSocket, message: string, isBinary: bool) =
  discard server.publish("chat", message)

server.listen("0.0.0.0", 9002) do(success: bool):
  if success:
    echo "Pub/Sub server on :9002"

server.run()
```

### TLS Server

```nim
import nim_usockets/http
import nim_usockets/types

let options = defaultServerOptions()
let sslOptions = UsSocketContextOptions(
  keyFileName: "server.key",
  certFileName: "server.crt",
  passphrase: nil,
  dhParamsFileName: nil,
  caFileName: nil,
  sslCiphers: nil,
  sslPreferLowMemoryUsage: 0
)

let server = newHttpServer(UseSsl, options)

server.handle proc(req: HttpRequest, res: HttpResponse) =
  res.send("Secure Hello!")

server.listen("0.0.0.0", 443) do(success: bool):
  if success:
    echo "TLS server on :443"

server.run()
```

### Low-Level TCP Echo Server (raw uSockets API)

```nim
import nim_usockets/usockets

proc onOpen(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr {.cdecl.} =
  echo "Connection opened"
  result = s

proc onData(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} =
  discard us_socket_write(0, s, data, length, 0)
  result = s

proc onClose(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.} =
  echo "Connection closed"
  result = s

let loop = us_create_loop(nil, nil, nil, nil, 0)
let options = defaultSocketContextOptions()
let context = us_create_socket_context(0, loop, 0, options)

us_socket_context_on_open(0, context, onOpen)
us_socket_context_on_data(0, context, onData)
us_socket_context_on_close(0, context, onClose)

let listenSocket = us_socket_context_listen(0, context, "0.0.0.0", 4000, 0, 0)
if listenSocket != nil:
  echo "TCP echo server on :4000"
  us_loop_run(loop)
```

### Timer Example

```nim
import nim_usockets/http

let server = newHttpServer()

server.handle proc(req: HttpRequest, res: HttpResponse) =
  res.send("OK")

server.setInterval(proc() =
  echo "tick"
, 5000)

server.listen("0.0.0.0", 3000) do(success: bool):
  if success:
    echo "Server with 5s timer on :3000"

server.run()
```

## API Reference

### Core Types (`nim_usockets/types`)

```
SslMode             NoSsl, UseSsl
UsSocketContextOptions   TLS cert/key/CA/ciphers configuration
UsLoopPtr           Opaque event loop handle
UsSocketContextPtr  Opaque socket context handle
UsSocketPtr         Opaque connected socket handle
UsListenSocketPtr   Opaque listen socket handle
UsTimerPtr          Opaque timer handle
UsUdpSocketPtr      Opaque UDP socket handle
ListenOptions       loDefault, loExclusivePort, loEpollExclusive, loEpollEdgeTrigger
```

### Event Loop (`nim_usockets/usockets`)

| Proc | Description |
|------|-------------|
| `us_create_loop(hint, wakeupCb, preCb, postCb, extSize)` | Create a new event loop |
| `us_loop_run(loop)` | Run the event loop (blocking) |
| `us_loop_free(loop)` | Free the event loop |
| `us_wakeup_loop(loop)` | Wake loop from another thread |
| `us_loop_iteration_number(loop)` | Current loop iteration counter |
| `us_loop_integrate(loop)` | Integrate with external loop (GCD) |

### Socket Context (`nim_usockets/usockets`)

| Proc | Description |
|------|-------------|
| `us_create_socket_context(ssl, loop, extSize, options)` | Create a socket context |
| `us_socket_context_listen(ssl, context, host, port, options, extSize)` | Listen for connections |
| `us_socket_context_listen_unix(ssl, context, path, options, extSize)` | Listen on Unix domain socket |
| `us_socket_context_connect(ssl, context, host, port, sourceHost, options, extSize)` | Connect to remote host |
| `us_socket_context_on_open(ssl, context, cb)` | Set connection-open callback |
| `us_socket_context_on_data(ssl, context, cb)` | Set data-received callback |
| `us_socket_context_on_close(ssl, context, cb)` | Set connection-close callback |
| `us_socket_context_on_writable(ssl, context, cb)` | Set writable callback |
| `us_socket_context_on_timeout(ssl, context, cb)` | Set timeout callback |
| `us_socket_context_on_end(ssl, context, cb)` | Set half-close (FIN) callback |
| `us_socket_context_add_server_name(ssl, context, pattern, options, user)` | Add SNI hostname |
| `us_socket_context_free(ssl, context)` | Free a socket context |

### Socket I/O (`nim_usockets/usockets`)

| Proc | Description |
|------|-------------|
| `us_socket_write(ssl, s, data, length, msgMore)` | Write data to socket |
| `us_socket_write2(ssl, s, header, headerLen, payload, payloadLen)` | Write header+payload atomically |
| `us_socket_close(ssl, s, code, reason)` | Close a socket |
| `us_socket_shutdown(ssl, s)` | Half-close (send FIN) |
| `us_socket_flush(ssl, s)` | Flush pending writes |
| `us_socket_cork(ssl, s)` / `us_socket_uncork(ssl, s)` | Cork/uncork TCP writes |
| `us_socket_timeout(ssl, s, seconds)` | Set socket timeout |
| `us_socket_long_timeout(ssl, s, minutes)` | Set long timeout |
| `us_socket_remote_address(ssl, s, buf, length)` | Get remote IP address |
| `us_socket_local_port(ssl, s)` / `us_socket_remote_port(ssl, s)` | Get local/remote port |
| `us_socket_is_established(ssl, s)` | Check if connection is established |
| `us_socket_is_shut_down(ssl, s)` | Check if socket is shut down |
| `us_socket_set_buffer_sizes(ssl, s, sendSize, recvSize)` | Set socket buffer sizes |

### Timers (`nim_usockets/usockets`)

| Proc | Description |
|------|-------------|
| `us_create_timer(loop, fallthrough, extSize)` | Create a timer |
| `us_timer_set(timer, cb, ms, repeatMs)` | Arm timer with delay and repeat interval |
| `us_timer_close(timer)` | Close and free a timer |
| `us_timer_loop(timer)` | Get the timer's parent loop |

### UDP (`nim_usockets/usockets`)

| Proc | Description |
|------|-------------|
| `us_create_udp_packet_buffer()` | Create UDP packet buffer |
| `us_create_udp_socket(loop, buf, dataCb, drainCb, host, port, user)` | Create UDP socket |
| `us_udp_socket_bind(s, hostname, port)` | Bind UDP socket |
| `us_udp_socket_send(s, buf, num)` | Send UDP packets |
| `us_udp_socket_receive(s, buf)` | Receive UDP packets |
| `us_udp_packet_buffer_payload(buf, index)` | Get packet payload |
| `us_udp_packet_buffer_payload_length(buf, index)` | Get packet payload length |

### DNS (`nim_usockets/usockets`)

| Proc | Description |
|------|-------------|
| `us_dns_resolve_async(loop, host, port, callback, userData)` | Async DNS resolution |
| `us_dns_cache_clear()` | Clear DNS cache |

### HTTP Server (`nim_usockets/http`)

#### Server Lifecycle

```nim
proc newHttpServer*(ssl: SslMode = NoSsl, options: ServerOptions = defaultServerOptions()): HttpServer
proc handle*(server: HttpServer, handler: HttpHandler)
proc listen*(server: HttpServer, host: string, port: int, callback: proc(success: bool) = nil)
proc run*(server: HttpServer)
proc shutdown*(server: HttpServer)
proc close*(server: HttpServer)
```

#### Request

```nim
proc path*(req: HttpRequest): lent string
proc queryStringRaw*(req: HttpRequest): lent string
proc httpVersion*(req: HttpRequest): lent string
proc upgradeHeader*(req: HttpRequest): lent string
proc contentTypeHeader*(req: HttpRequest): lent string
proc cookieHeader*(req: HttpRequest): lent string
proc secWebSocketKeyHeader*(req: HttpRequest): lent string
proc knownHeaderValue*(req: HttpRequest, kind: ParsedHeaderKind): string
proc isWebSocketUpgrade*(req: HttpRequest): bool
```

Fields on `HttpRequest`:
- `methodKind: HttpMethod` — GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT
- `body: string` — request body
- `httpMajor`, `httpMinor: int` — HTTP version components
- `rawHeaderSlices: seq[RawHeaderSlice]` — parsed header positions for zero-copy access

#### Response

```nim
proc setStatus*(res: HttpResponse, status: HttpStatus)
proc applyStatusCode*(res: HttpResponse, code: int)
proc setHeader*(res: HttpResponse, key, value: string)
proc send*(res: HttpResponse, data: string)
proc json*(res: HttpResponse, data: string)
proc html*(res: HttpResponse, data: string)
proc sendHeaders*(res: HttpResponse)
proc tryEnd*(res: HttpResponse, ...)
proc startChunkedStream*(res: HttpResponse, ...)
proc writeChunkedStream*(res: HttpResponse, chunk: string): bool
proc finishChunkedStream*(res: HttpResponse, closeAfterWrite: bool = false): bool
proc onWritable*(res: HttpResponse, handler: HttpWritableHandler): HttpResponse
proc pauseRead*(res: HttpResponse)
proc resumeRead*(res: HttpResponse)
proc retainHttpResponse*(res: HttpResponse)
proc releaseHttpResponse*(res: HttpResponse)
```

HTTP/2 specific:
```nim
proc h2SendTrailers*(res: HttpResponse, trailers: seq[(string, string)])
proc h2PushPromise*(res: HttpResponse, path: string, pushHeaders: seq[(string, string)], pushBody: string = "")
```

#### WebSocket

```nim
proc upgradeToWebSocket*(req: HttpRequest, res: HttpResponse): WebSocket
proc send*(ws: WebSocket, data: string, binary: bool = false, bypassCompression: bool = false)
proc sendText*(ws: WebSocket, data: string)
proc sendBinary*(ws: WebSocket, data: string)
proc sendUncompressed*(ws: WebSocket, data: string, binary: bool = false)
proc ping*(ws: WebSocket, data: string = "")
proc close*(ws: WebSocket, code: int = 1000, reason: string = "")
proc cork*(ws: WebSocket, callback: proc(ctx: WebSocketCorkContext))
proc subscribe*(ws: WebSocket, topic: string): bool
proc unsubscribe*(ws: WebSocket, topic: string): bool
```

Prepared messages for efficient broadcasting:
```nim
proc prepareWsMessage*(data: string, binary: bool = false): PreparedWsMessage
proc sendPrepared*(ws: WebSocket, msg: PreparedWsMessage): bool
proc broadcastPrepared*(server: HttpServer, msg: PreparedWsMessage): int
proc publishPrepared*(server: HttpServer, topic: string, msg: PreparedWsMessage): int
proc publish*(server: HttpServer, topic: string, data: string, binary: bool = false): int
```

#### Server Event Hooks

```nim
proc onStart*(server: HttpServer, callback: TimerCallback)
proc onConnectionOpen*(server: HttpServer, handler: ConnectionOpenHandler)
proc onConnectionClose*(server: HttpServer, handler: ConnectionCloseHandler)
proc onRequestStart*(server: HttpServer, handler: RequestStartHandler)
proc onRequestEnd*(server: HttpServer, handler: RequestEndHandler)
proc onBeforeHeaders*(server: HttpServer, handler: BeforeHeadersHandler)
proc onBeforeWrite*(server: HttpServer, handler: BeforeWriteHandler)
proc onAfterWrite*(server: HttpServer, handler: AfterWriteHandler)
proc onBackpressure*(server: HttpServer, handler: BackpressureHandler)
proc onTimeout*(server: HttpServer, handler: TimeoutHandler)
proc onError*(server: HttpServer, handler: ErrorHandler)
proc onPanic*(server: HttpServer, handler: PanicHandler)
proc onWebSocket*(server: HttpServer, handler: WebSocketHandler)
proc onWebSocketOpen*(server: HttpServer, handler: WebSocketOpenHandler)
proc onWebSocketClose*(server: HttpServer, handler: WebSocketCloseHandler)
proc onWebSocketDrain*(server: HttpServer, handler: WebSocketDrainHandler)
proc onWebSocketDropped*(server: HttpServer, handler: WebSocketDroppedHandler)
proc onWebSocketHighWater*(server: HttpServer, handler: WebSocketHighWaterHandler)
proc onWebSocketUpgradeValidate*(server: HttpServer, handler: WebSocketUpgradeValidateHandler)
proc setInterval*(server: HttpServer, callback: TimerCallback, intervalMs: int)
proc setLoopCallbacks*(server: HttpServer, preCallback, postCallback: TimerCallback)
```

### HTTP/2 Protocol (`nim_usockets/h2_protocol`)

Frame types, settings, and serialization for the HTTP/2 wire protocol:

```nim
proc defaultH2Settings*(): H2Settings
proc parseH2Frame*(data: openArray[byte], pos: var int): Option[H2Frame]
proc serializeH2Frame*(frame: H2Frame, buf: var string)
proc serializeSettings*(settings: H2Settings, buf: var string)
proc serializeHeaders*(streamId: uint32, headerBlock: string, endStream, endHeaders: bool, buf: var string)
proc serializeData*(streamId: uint32, data: string, endStream: bool, buf: var string)
proc serializeGoaway*(lastStreamId, errorCode: uint32, buf: var string)
proc serializeWindowUpdate*(streamId, increment: uint32, buf: var string)
proc serializePing*(data: array[8, byte], ack: bool, buf: var string)
proc serializeRstStream*(streamId, errorCode: uint32, buf: var string)
proc serializePushPromise*(streamId, promisedStreamId: uint32, headerBlock: string, buf: var string)
proc serializeTrailers*(streamId: uint32, headerBlock: string, buf: var string)
```

### HPACK Header Compression (`nim_usockets/hpack`)

```nim
proc initHpackEncoder*(huffman: bool = true): HpackEncoder
proc hpackEncode*(encoder: var HpackEncoder, headers: openArray[(string, string)], buf: var string)
proc initHpackDecoder*(maxSize: int = 4096): HpackDecoder
proc hpackDecode*(decoder: var HpackDecoder, data: openArray[byte]): seq[(string, string)]
proc huffmanEncode*(src: openArray[byte], buf: var string)
proc huffmanDecode*(data: openArray[byte], buf: var string)
```

## Configuration

### ServerOptions Defaults

| Option | Default | Description |
|--------|---------|-------------|
| `maxBodySize` | 10 MB | Max request body size |
| `maxHeaderBytes` | 16 KB | Max total header bytes |
| `maxHeaderCount` | 100 | Max number of headers |
| `maxHeaderLineBytes` | 8 KB | Max bytes per header line |
| `maxRequestUriBytes` | 8192 | Max request URI length |
| `connectionTimeout` | 120s | Overall connection lifespan limit |
| `maxConnections` | 100,000 | Max concurrent connections |
| `headerReadTimeoutMs` | 30,000 | Header-read phase timeout (slowloris protection) |
| `bodyReadTimeoutMs` | 30,000 | Body-read phase timeout |
| `handlerExecTimeoutMs` | 0 (disabled) | Handler execution timeout |
| `writeDrainTimeoutMs` | 0 (disabled) | Write-drain timeout |
| `gracefulShutdownDrainMs` | 3,000 | Drain period before forced close |

### WebSocket Defaults

| Option | Default | Description |
|--------|---------|-------------|
| `wsKeepaliveInterval` | 30,000 ms | Keepalive ping interval |
| `wsIdleTimeoutSeconds` | 60s | Idle connection timeout |
| `wsMaxBackpressure` | 128 KB | Max queued outgoing bytes per socket |
| `wsMaxFragmentCount` | 1,024 | Max continuation fragments |
| `wsCompressionEnabled` | false | permessage-deflate support |
| `wsCompressionMinBytes` | 1,024 | Min payload size to compress |

### Socket Tuning Defaults

| Option | Default | Description |
|--------|---------|-------------|
| `socketNoDelay` | true | TCP_NODELAY |
| `socketKeepAlive` | true | SO_KEEPALIVE |
| `socketKeepAliveSeconds` | 60 | Keepalive idle time |
| `socketSendBufferBytes` | 512 KB | SO_SNDBUF |
| `socketRecvBufferBytes` | 512 KB | SO_RCVBUF |
| `socketNotSentLowWaterBytes` | 16 KB | TCP_NOTSENT_LOWAT |

### Write Coalescing Modes

The server supports four write coalescing strategies via `writeCoalesceMode`:

| Mode | Behavior |
|------|----------|
| `wcmAdaptive` (default) | Automatically selects latency or throughput profile based on payload size and backlog depth |
| `wcmLatency` | Low-latency mode — small coalescing windows (8 KB / 3 responses) |
| `wcmBalanced` | Middle-ground between latency and throughput |
| `wcmThroughput` | High-throughput mode — large coalescing windows (128 KB / 32 responses) |

### Performance Tuning Compile Defines

| Define | Effect |
|--------|--------|
| `-d:perfModeThroughput` | Larger parse budgets and coalescing buffers for maximum throughput |
| `-d:perfModeLatency` | Smaller budgets and buffers for minimum latency |
| (neither) | Balanced defaults |

## Compilation Flags

### Building your application

```bash
# Linux
nim c -d:release --opt:speed \
  --passL:"-L./usockets -lusockets -lpthread -ldl" \
  your_app.nim

# macOS
nim c -d:release --opt:speed \
  --passL:"./usockets/uSockets.a -framework CoreFoundation" \
  your_app.nim
```

### Required and recommended flags

| Flag | Required | Purpose |
|------|----------|---------|
| `--passL:"path/to/uSockets.a"` | Yes | Link the uSockets static library; add `-lpthread -ldl` on Linux |
| `-framework CoreFoundation` | macOS only | Required by GCD event loop backend |
| `-d:release` | Recommended | Enable optimizations |
| `--opt:speed` | Recommended | Optimize for speed over size |
| `--panics:off` | Required for recovery | Allows Defect recovery in panic handler callbacks; without this, Defects terminate the process |
| `--threads:on` | If using threads | Required for `crossThreadDeferEnabled`, body spill offload, or multi-threaded scaling |
| `-d:singleThread` | Optional | Single-threaded mode; avoids thread-local storage overhead |

### All compile-time defines

| Define | Default | Effect |
|--------|---------|--------|
| `-d:release` | off | Standard Nim release mode with optimizations |
| `-d:danger` | off | Like release but also disables runtime checks (bounds, overflow) |
| `-d:lto` | off | Link-time optimization for cross-module inlining |
| `-d:perfModeThroughput` | off | Throughput-optimized constants (see table below) |
| `-d:perfModeLatency` | off | Latency-optimized constants (see table below) |
| `-d:singleThread` | off | Avoids thread-local storage overhead for object pools |
| `-d:uws_disable_segment_coalesce_copy` | off | Disable segment-coalesce copy optimization |
| `-d:h2debug` | off | Emit HTTP/2 frame-level debug logging to stderr |
| `-d:nimUwebsocketsTest` | off | Enable test instrumentation hooks |
| `--panics:off` | on | Required for Defect recovery in `onPanic` handlers |
| `--threads:on` | off | Enable threading support for spill offload and cross-thread defer |

### Nimble task example

```nim
requires "nim_usockets"

task build, "Build the application":
  exec "nim c -d:release --opt:speed --passL:\"./usockets/uSockets.a -lpthread -ldl\" src/main.nim"
```

---

## Performance Tuning

This section covers every tunable knob available in nim_usockets. Settings are organized from most impactful to most specialized.

### Compile-Time Performance Profiles

The `-d:perfModeThroughput` and `-d:perfModeLatency` defines switch compile-time constants that affect parsing budgets, buffer sizes, and coalescing behavior:

| Constant | Latency | Balanced (default) | Throughput |
|----------|---------|-------------------|------------|
| `SmallFrameStackLimit` | 256 | 1,024 | 2,048 |
| `WsPreparedDirectThreshold` | 1 KB | 4 KB | 8 KB |
| `InputCompactThreshold` | 16 KB | 64 KB | 128 KB |
| `WsInputCompactThreshold` | 16 KB | 64 KB | 128 KB |
| `DefaultParseBudgetRequestsPerRead` | 4 | 32 | 64 |
| `DefaultParseBudgetBytesPerRead` | 64 KB | 512 KB | 1 MB |

**When to use each:**
- **Throughput** — bulk API traffic, batch processing, high-connection-count servers where raw req/s matters most
- **Latency** — real-time APIs, gaming backends, financial services where p99 latency matters most
- **Balanced** — general-purpose web servers, mixed traffic patterns

### Write Coalescing

Write coalescing batches multiple response writes into fewer syscalls. The adaptive mode (default) automatically switches between latency and throughput profiles based on payload size and backlog depth.

| Option | Default | Purpose |
|--------|---------|---------|
| `writeCoalesceMode` | `wcmAdaptive` | Mode selector |
| `writeCoalesceMaxBytes` | 64 KB | Hard cap on coalesced bytes per flush |
| `writeCoalesceMaxResponses` | 16 | Hard cap on coalesced responses per flush |
| `writeCoalesceLatencyMaxBytes` | 8 KB | Latency-profile byte cap |
| `writeCoalesceLatencyMaxResponses` | 3 | Latency-profile response cap |
| `writeCoalesceThroughputMaxBytes` | 128 KB | Throughput-profile byte cap |
| `writeCoalesceThroughputMaxResponses` | 32 | Throughput-profile response cap |
| `writeCoalesceSmallPayloadBytes` | 4 KB | Payloads <= this prefer latency profile |
| `writeCoalesceLargePayloadBytes` | 32 KB | Payloads >= this prefer throughput profile |
| `writeCoalesceP99GuardPendingBytes` | 96 KB | Switch to latency profile when pending bytes are below this |
| `writeCoalesceP99GuardPendingResponses` | 8 | Switch to latency profile when pending responses are below this |

**Recommendations:**
- For minimum latency: `writeCoalesceMode = wcmLatency`
- For maximum throughput: `writeCoalesceMode = wcmThroughput`
- For mixed workloads: keep `wcmAdaptive` and tune the small/large payload thresholds
- The P99 guard prevents throughput-mode from hurting tail latency when the server is lightly loaded

```nim
var opts = defaultServerOptions()
opts.writeCoalesceMode = wcmThroughput
opts.writeCoalesceThroughputMaxBytes = 256 * 1024
opts.writeCoalesceThroughputMaxResponses = 64
let server = newHttpServer(NoSsl, opts)
```

### Fairness Budgets

Fairness budgets prevent a single hot socket or a burst of traffic from starving other connections. There are three independent budget layers:

#### Per-Read Parse Budget

Limits how many requests are parsed from a single socket's receive buffer before yielding to other sockets.

| Option | Default | Purpose |
|--------|---------|---------|
| `parseBudgetRequestsPerRead` | 32 | Max requests parsed per data callback |
| `parseBudgetBytesPerRead` | 512 KB | Max bytes consumed per data callback |

```nim
server.setParseFairnessBudget(requestsPerRead = 16, bytesPerRead = 256 * 1024)
```

#### Per-Loop Dispatch Budget

Limits total requests/bytes dispatched across all sockets in a single event loop iteration.

| Option | Default | Purpose |
|--------|---------|---------|
| `loopDispatchBudgetRequests` | 256 | Max dispatched requests per loop iteration |
| `loopDispatchBudgetBytes` | 4 MB | Max dispatched bytes per loop iteration |

```nim
server.setLoopDispatchFairnessBudget(requestsPerLoop = 512, bytesPerLoop = 8 * 1024 * 1024)
```

#### Per-Flush Write Budget

Limits how much queued write data is drained per socket per flush, and globally per loop iteration.

| Option | Default | Purpose |
|--------|---------|---------|
| `writeBudgetIterationsPerFlush` | 32 | Max queued write iterations drained per socket |
| `writeBudgetBytesPerFlush` | 512 KB | Max queued write bytes drained per socket |
| `loopWriteBudgetBytes` | 4 MB | Max queued write bytes drained per loop iteration |

```nim
server.setWriteFairnessBudget(iterationsPerFlush = 64, bytesPerFlush = 1024 * 1024)
server.setLoopWriteFairnessBudget(bytesPerLoop = 8 * 1024 * 1024)
```

### Adaptive Read Buffers

Per-socket input buffers resize dynamically between a minimum and maximum capacity. The shrink threshold controls how aggressively buffers downsize after a traffic burst.

| Option | Default | Purpose |
|--------|---------|---------|
| `readBufferMinCapacity` | 1 KB | Lower bound for adaptive buffer sizing |
| `readBufferMaxCapacity` | 64 KB | Upper bound for adaptive buffer sizing |
| `readBufferShrinkPercent` | 25 | Shrink when utilization falls below this % of current target |

### Connection Limits and File Descriptors

| Option | Default | Purpose |
|--------|---------|---------|
| `maxConnections` | 100,000 | Max concurrent connections accepted |
| `maxPendingBytesPerSocket` | 64 KB | Max queued unsent bytes per socket |

On Linux, you may need to raise the file descriptor limit:

```bash
ulimit -n 200000

# Persistent (add to /etc/security/limits.conf):
*  soft  nofile  200000
*  hard  nofile  200000
```

Also raise the system-wide limit:

```bash
echo 200000 > /proc/sys/fs/file-max

# Persistent (add to /etc/sysctl.conf):
fs.file-max = 200000
```

### Timeout Tuning

All timeouts are in milliseconds. Setting to 0 disables the timeout.

| Option | Default | Security Trade-off |
|--------|---------|-------------------|
| `headerReadTimeoutMs` | 30,000 | Lower = better slowloris protection, higher = tolerates slow clients |
| `bodyReadTimeoutMs` | 30,000 | Lower = better slow-body protection, higher = tolerates large uploads on slow links |
| `handlerExecTimeoutMs` | 0 | Enable to prevent handler stalls from consuming resources indefinitely |
| `writeDrainTimeoutMs` | 0 | Enable to time out slow consumers that don't read responses |
| `connectionTimeout` | 120s | Final backstop on total connection lifespan |
| `gracefulShutdownDrainMs` | 3,000 | Time allowed for in-flight requests to complete during shutdown |

```nim
var opts = defaultServerOptions()
opts.headerReadTimeoutMs = 10_000
opts.bodyReadTimeoutMs = 60_000
opts.handlerExecTimeoutMs = 30_000
opts.writeDrainTimeoutMs = 15_000
opts.connectionTimeout = 300
opts.gracefulShutdownDrainMs = 10_000
let server = newHttpServer(NoSsl, opts)
```

### Memory and Buffer Sizing

| Option | Default | Purpose |
|--------|---------|---------|
| `maxBodySize` | 10 MB | Max request body size; requests exceeding this are rejected |
| `maxHeaderBytes` | 16 KB | Max total header bytes per request |
| `maxHeaderCount` | 100 | Max number of header fields |
| `maxHeaderLineBytes` | 8 KB | Max bytes per individual header line |
| `maxRequestUriBytes` | 8,192 | Max request-target length |
| `maxRequestMemory` | 32 MB | Total in-flight request memory budget across all connections |
| `minimalHeaderParsing` | false | Parse only hot/required headers for lower overhead |
| `tlsFlattenThreshold` | 16 KB | Merge header+body for TLS writes up to this size |

### Socket-Level Tuning

| Option | Default | Purpose |
|--------|---------|---------|
| `socketNoDelay` | true | `TCP_NODELAY` — disables Nagle's algorithm |
| `socketKeepAlive` | true | `SO_KEEPALIVE` — enables TCP keepalive probes |
| `socketKeepAliveSeconds` | 60 | Keepalive idle time before first probe |
| `socketFastOpen` | false | `TCP_FASTOPEN` — send data in SYN packet (Linux) |
| `socketSendBufferBytes` | 512 KB | `SO_SNDBUF` on accepted sockets |
| `socketRecvBufferBytes` | 512 KB | `SO_RCVBUF` on accepted sockets |
| `socketNotSentLowWaterBytes` | 16 KB | `TCP_NOTSENT_LOWAT` — writable notification threshold |
| `socketDeferAcceptSeconds` | 0 | `TCP_DEFER_ACCEPT` — delay accept until data arrives (Linux only) |
| `socketIncomingCpu` | -1 | `SO_INCOMING_CPU` — bind socket to CPU for locality (Linux only) |

#### Linux-Specific Socket Options

```nim
var opts = defaultServerOptions()
opts.socketFastOpen = true
opts.socketDeferAcceptSeconds = 5
opts.socketIncomingCpu = 0
opts.listenExclusivePort = true
opts.listenEpollExclusive = true
```

- `TCP_DEFER_ACCEPT`: delays the accept syscall until the client sends data, reducing wakeups for connections that connect but never send.
- `SO_INCOMING_CPU`: hint to the kernel to route connections to a specific CPU for better cache locality.
- `EPOLLEXCLUSIVE`: prevents thundering herd when multiple threads/processes share a listen socket.

#### macOS-Specific Options

```nim
var opts = defaultServerOptions()
opts.macosHighQos = true
```

- `macosHighQos` (default: true) sets `QOS_CLASS_USER_INITIATED` on the event loop thread via `pthread_set_qos_class_self_np`, giving it higher scheduling priority.

### Overload Controller (AIMD)

The overload controller rejects new requests with `503 Service Unavailable` when the server is under pressure. It supports both static thresholds and an adaptive AIMD (Additive Increase, Multiplicative Decrease) mode.

#### Static Overload Controller

```nim
server.setOverloadController(
  maxBacklogBytes = 2 * 1024 * 1024,
  maxPendingResponses = 500,
  closeOnReject = false
)
```

| Option | Default | Purpose |
|--------|---------|---------|
| `overloadMaxLoopBacklogBytes` | 0 (disabled) | Reject when queued response bytes exceed this |
| `overloadMaxPendingResponses` | 0 (disabled) | Reject when pending response slots exceed this |
| `overloadCloseOnReject` | false | Close connection immediately after sending 503 |
| `overloadRetryAfterSeconds` | 1 | `Retry-After` header value on 503 responses (0 disables) |

#### Adaptive (AIMD) Overload Controller

The adaptive controller automatically adjusts thresholds: it tightens limits when overload is detected and relaxes them when pressure clears.

```nim
server.setAdaptiveOverloadController(
  enabled = true,
  minBacklogBytes = 256 * 1024,
  maxBacklogBytes = 4 * 1024 * 1024,
  minPendingResponses = 64,
  maxPendingResponses = 1000,
  tightenStepPercent = 20,
  relaxStepPercent = 10,
  cooldownRequests = 64
)
```

| Option | Default | Purpose |
|--------|---------|---------|
| `overloadAdaptiveEnabled` | false | Enable AIMD adaptive tuning |
| `overloadAdaptiveMinBacklogBytes` | 256 KB | Lower clamp for adaptive backlog limit |
| `overloadAdaptiveMaxBacklogBytes` | 0 (static max) | Upper clamp for adaptive backlog limit |
| `overloadAdaptiveMinPendingResponses` | 64 | Lower clamp for adaptive pending-response limit |
| `overloadAdaptiveMaxPendingResponses` | 0 (static max) | Upper clamp for adaptive pending-response limit |
| `overloadAdaptiveTightenStepPercent` | 20 | Percent decrease per overload detection |
| `overloadAdaptiveRelaxStepPercent` | 10 | Percent increase when pressure clears |
| `overloadAdaptiveCooldownRequests` | 64 | Samples needed before applying one adjustment |

### Body Spill-to-Disk

When request bodies exceed a threshold, the server can spill them to disk to bound memory usage. With `--threads:on`, spill writes are offloaded to a background thread.

```nim
server.setBodySpillToDisk(
  thresholdBytes = 1 * 1024 * 1024,
  spillDir = "/tmp/nim_spill"
)
```

| Option | Default | Purpose |
|--------|---------|---------|
| `bodySpillThreshold` | 0 (disabled) | Content-Length >= this triggers spill-to-disk |
| `bodySpillDir` | `""` | Temp directory for spilled bodies (empty = system default) |
| `bodySpillOffloadEnabled` | true | Offload spill writes to background thread (`--threads:on` required) |
| `bodySpillOffloadQueueLimit` | 256 | Max queued offload spill jobs |
| `bodySpillOffloadQueueBytesLimit` | 8 MB | Max queued offload spill bytes |
| `spillPressureRejectThreshold` | 8 | Spill pressure score that triggers overload rejection |
| `spillPressureRecoverThreshold` | 2 | Spill pressure score that clears rejection |

### WebSocket Compression

```nim
var opts = defaultServerOptions()
opts.wsCompressionEnabled = true
opts.wsCompressionMinBytes = 512
opts.wsCompressionMinSavingsBytes = 24
opts.wsCompressionServerNoContextTakeover = true
opts.wsCompressionClientNoContextTakeover = true
opts.wsCompressionDisableForBinary = true
opts.wsCompressionBackpressureBypassBytes = 256 * 1024
let server = newHttpServer(NoSsl, opts)
```

| Option | Default | Purpose |
|--------|---------|---------|
| `wsCompressionEnabled` | false | Negotiate permessage-deflate when client offers it |
| `wsCompressionMinBytes` | 1,024 | Minimum payload bytes before attempting compression |
| `wsCompressionMinSavingsBytes` | 24 | Minimum bytes saved to use compressed payload |
| `wsCompressionServerNoContextTakeover` | true | Require no server compression context takeover |
| `wsCompressionClientNoContextTakeover` | true | Require no client compression context takeover |
| `wsCompressionDisableForBinary` | false | Bypass compression for binary frames |
| `wsCompressionDisableForText` | false | Bypass compression for text frames |
| `wsCompressionBackpressureBypassBytes` | 0 (disabled) | Skip compression when pending bytes exceed this |

- Compression is negotiated only when the client offers `permessage-deflate` with both `server_no_context_takeover` and `client_no_context_takeover`.
- Per-message bypass: `send(ws, data, binary, bypassCompression = true)` or `sendUncompressed(ws, data)`.
- Control frames (ping/pong/close) are never compressed.
- Max compression ratio is capped at 1024x to protect against compression bombs.

### WebSocket Backpressure

| Option | Default | Purpose |
|--------|---------|---------|
| `wsMaxBackpressure` | 128 KB | Max queued outgoing bytes per WebSocket |
| `wsBackpressureHighWaterBytes` | 0 (disabled) | High-water threshold for backpressure queue |
| `wsBackpressureHighWaterAction` | `bhwDropNewest` | Action on high-water overflow: `bhwDropNewest`, `bhwDropOldest`, `bhwClose` |
| `wsCloseOnBackpressureLimit` | false | Force-close socket when backpressure limit is hit |
| `wsWriteCoalesceMaxBytes` | 64 KB | Max WebSocket queued bytes coalesced into one flush |
| `wsWriteCoalesceMaxFrames` | 1 | Max WebSocket queued frames coalesced into one flush |
| `wsSocketRecvBufferBytes` | 0 (inherit) | Override `SO_RCVBUF` for WebSocket sockets |
| `wsSocketSendBufferBytes` | 0 (inherit) | Override `SO_SNDBUF` for WebSocket sockets |
| `wsSocketNotSentLowWaterBytes` | 0 (inherit) | Override `TCP_NOTSENT_LOWAT` for WebSocket sockets |

### WebSocket Idle and Keepalive

| Option | Default | Purpose |
|--------|---------|---------|
| `wsKeepaliveInterval` | 30,000 ms | Interval between keepalive pings |
| `wsIdleTimeoutSeconds` | 60s | Idle timeout (0 = disabled) |
| `wsResetIdleTimeoutOnSend` | true | Refresh idle timeout after successful send/drain |
| `wsMaxFragmentCount` | 1,024 | Max continuation fragments before forcing close |

### Object Pooling

HttpRequest, HttpResponse, and WebSocket objects are pooled in thread-local (or global with `-d:singleThread`) free lists to reduce allocation pressure.

| Pool | Max Size | Purpose |
|------|----------|---------|
| `HttpRequest` | 128 | Reuses parsed request objects |
| `HttpResponse` | 4,096 | Reuses response writer objects |
| `WebSocket` | 4,096 | Reuses WebSocket wrapper objects |

These pool sizes are compile-time constants. The `-d:singleThread` flag uses global pools instead of thread-local storage, avoiding TLS overhead in single-threaded deployments.

### SIMD and SWAR Acceleration

HTTP header parsing uses platform-specific SIMD instructions for scanning bytes:

| Architecture | Instruction Set | Functions |
|-------------|-----------------|-----------|
| ARM64 (aarch64) | NEON | `neon_find_byte`, `neon_find_crlf`, `neon_find_header_terminator` |
| x86-64 (amd64) | SSE2 | `sse2_find_byte`, `sse2_find_crlf`, `sse2_find_header_terminator` |
| Fallback | SWAR (64-bit word tricks) | `swarFindByte`, `swarFindCrlf`, `swarFindHeaderTerminator` |

WebSocket unmasking also uses SIMD-accelerated zero-copy routines via the `ws_simd` module.

These are selected automatically at compile time based on the target architecture — no configuration is needed.

### Cross-Thread Defer

| Option | Default | Purpose |
|--------|---------|---------|
| `crossThreadDeferEnabled` | false | Enable `deferFromAnyThread` gateway |
| `crossThreadDeferQueueLimit` | 4,096 | Max callbacks queued before drops |

Requires `--threads:on`. Allows scheduling callbacks onto the event loop from any thread.

### Listen Socket Options (Linux epoll)

| Option | Default | Purpose |
|--------|---------|---------|
| `listenExclusivePort` | false | uSockets exclusive-port listen option (Linux `SO_REUSEPORT`-style) |
| `listenEpollExclusive` | false | `EPOLLEXCLUSIVE` for thundering-herd avoidance |
| `listenEpollEdgeTrigger` | false | `EPOLLET` edge-triggered listen registration |

### Multi-Threading vs Multi-Process

| Approach | Platform | Pros | Cons |
|----------|----------|------|------|
| Single process | All | Simplest, no IPC needed | Limited to one CPU core |
| Multi-process (`fork`) | Linux | `SO_REUSEPORT` load-balancing, process isolation | No shared state without IPC |
| Multi-threaded | Linux | Shared memory, lower overhead | GC complexity, data races possible |
| Reverse proxy (nginx) | All | Works everywhere, health checks, SSL termination | Extra hop, config overhead |

**Linux high-performance recipe:**

```bash
nim c -d:release -d:danger -d:lto --opt:speed \
  -d:perfModeThroughput \
  --threads:on \
  --passL:"-L./usockets -lusockets" \
  your_app.nim
```

**macOS scaling recipe:**

Run multiple processes on different ports and load-balance with nginx:

```bash
for port in 3010 3011 3012 3013; do
  ./your_app --port=$port &
done
```

### Graceful Shutdown

| Option | Default | Purpose |
|--------|---------|---------|
| `gracefulShutdown` | true | Enable SIGINT/SIGTERM signal handling |
| `gracefulShutdownDrainMs` | 3,000 | Time allowed for in-flight requests to complete |

Set `gracefulShutdownDrainMs` higher if your application has long-running handlers:

```nim
var opts = defaultServerOptions()
opts.gracefulShutdownDrainMs = 30_000
let server = newHttpServer(NoSsl, opts)
```

### Complete High-Performance Example

```nim
import nim_usockets/http

var opts = defaultServerOptions()

opts.writeCoalesceMode = wcmThroughput
opts.writeCoalesceThroughputMaxBytes = 256 * 1024
opts.writeCoalesceThroughputMaxResponses = 64

opts.parseBudgetRequestsPerRead = 64
opts.parseBudgetBytesPerRead = 1024 * 1024
opts.loopDispatchBudgetRequests = 512
opts.loopDispatchBudgetBytes = 8 * 1024 * 1024

opts.socketFastOpen = true
opts.socketSendBufferBytes = 1024 * 1024
opts.socketRecvBufferBytes = 1024 * 1024

opts.readBufferMaxCapacity = 128 * 1024

opts.headerReadTimeoutMs = 10_000
opts.bodyReadTimeoutMs = 10_000
opts.connectionTimeout = 60

opts.overloadAdaptiveEnabled = true
opts.overloadMaxLoopBacklogBytes = 4 * 1024 * 1024
opts.overloadMaxPendingResponses = 1000

opts.maxConnections = 200_000
opts.minimalHeaderParsing = true

let server = newHttpServer(NoSsl, opts)

server.handle proc(req: HttpRequest, res: HttpResponse) =
  res.json("""{"status":"fast"}""")

server.listen("0.0.0.0", 3000) do(success: bool):
  if success:
    echo "High-performance server on :3000"

server.run()
```

Compile with:

```bash
nim c -d:release -d:danger -d:lto -d:perfModeThroughput --opt:speed \
  --passL:"./usockets/uSockets.a -lpthread -ldl" \
  your_app.nim
```

---

## Troubleshooting

### SIGSEGV on startup (macOS)

**Cause:** uSockets was built without the GCD backend, or `-framework CoreFoundation` was not linked.

**Fix:**
```bash
cd usockets && make clean && WITH_GCD=1 make
```
Then recompile your application with `-framework CoreFoundation` in `--passL`.

### Linker errors: undefined reference to `us_create_loop`

**Cause:** The uSockets static library is not linked.

**Fix:** Ensure `--passL:"/path/to/uSockets.a"` or `--passL:"-L/path/to/usockets -lusockets"` is passed to the Nim compiler.

### OpenSSL not found (macOS with Homebrew)

**Cause:** Homebrew installs OpenSSL in a non-standard path.

**Fix:**
```bash
export PKG_CONFIG_PATH="/opt/homebrew/opt/openssl/lib/pkgconfig:$PKG_CONFIG_PATH"
WITH_GCD=1 WITH_OPENSSL=1 make
```

### WebSocket closes immediately after upgrade

**Cause:** WebSocket accept-key generation must use raw SHA-1 bytes (not hex). Also verify that `onWebSocket` / `onWebSocketOpen` handlers are registered before calling `listen()`.

### `Ambiguous call` compiler errors

**Cause:** Multiple modules export the same identifier (e.g., `HttpMethod`).

**Fix:** Use fully qualified names: `http.HttpMethod` or `types.SslMode`.

### SO_REUSEPORT does not load-balance on macOS

macOS allows `SO_REUSEPORT` binding but does not distribute connections across sockets. Use nginx or haproxy in front of multiple single-process instances listening on different ports for macOS scaling.

### Multi-threading does not work on macOS

The GCD event loop backend does not function correctly in spawned threads. On macOS, start `listen`/`run` from the process main thread, use single-process mode, and scale horizontally with a reverse proxy.

### Connection timeouts firing too aggressively

The default `connectionTimeout` is 120 seconds and `headerReadTimeoutMs` / `bodyReadTimeoutMs` are 30 seconds each. For long-lived connections (e.g., SSE, long-polling), increase or disable these:

```nim
var opts = defaultServerOptions()
opts.connectionTimeout = 0
opts.headerReadTimeoutMs = 60_000
opts.bodyReadTimeoutMs = 60_000
let server = newHttpServer(NoSsl, opts)
```

### High memory usage under load

- Enable body spill-to-disk for large request bodies: `server.setBodySpillToDisk(1 * 1024 * 1024)`
- Reduce `maxRequestMemory` to bound total in-flight request memory
- Lower `maxConnections` to match available file descriptors
- Reduce socket buffer sizes (`socketSendBufferBytes`, `socketRecvBufferBytes`) — the defaults (512 KB each) consume 1 MB per connection

### WebSocket messages being dropped

- Check if `wsMaxBackpressure` is being exceeded — increase it or handle the `onWebSocketHighWater` event
- If `wsBackpressureHighWaterAction` is `bhwDropNewest` (default), new messages are silently dropped when the high-water mark is hit
- Use `onWebSocketDropped` to monitor dropped messages
- Increase `wsWriteCoalesceMaxBytes` and `wsWriteCoalesceMaxFrames` for bursty traffic

### 503 responses under moderate load

- The overload controller may be too aggressive — raise `overloadMaxLoopBacklogBytes` and `overloadMaxPendingResponses`
- If using adaptive mode, increase `overloadAdaptiveMaxBacklogBytes` or reduce `overloadAdaptiveTightenStepPercent`
- Check if spill pressure is triggering rejection — lower `spillPressureRejectThreshold` or increase `bodySpillOffloadQueueLimit`

### Slowloris/slow-body attacks

- `headerReadTimeoutMs` (default: 30s) and `bodyReadTimeoutMs` (default: 30s) protect against these
- Lower them for stricter protection: 5–10 seconds is aggressive but effective
- `connectionTimeout` (default: 120s) provides the final backstop

## License

MIT

## Credits

- [uSockets](https://github.com/uNetworking/uSockets) — The C networking foundation
- [uWebSockets](https://github.com/uNetworking/uWebSockets) — The C++ library that inspired the architecture
- [zippy](https://github.com/guzba/zippy) — Nim compression library used for deflate/gzip
