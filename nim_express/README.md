# nim_express

An Express.js-inspired web framework for Nim, built on top of [uWebSockets](https://github.com/uNetworking/uWebSockets) via [nim_usockets](../nim_usockets). Delivers high throughput with a familiar middleware-based API, supporting both synchronous and asynchronous handlers, HTTP/1.1, HTTP/2, WebSockets, response compression, and multi-threaded/multi-process modes.

## Features

- **Express-style routing** — GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS with `:param` placeholders and `*` wildcards
- **Middleware pipeline** — composable async and sync middleware with `use()`, route groups, and per-route middleware
- **Built-in middleware suite** — CORS, CSRF, Helmet, rate limiting, sessions, compression, logging, error handling, static files, and more (30+ modules)
- **JSON parsing** — automatic body parsing with `std/json` and high-performance typed deserialization via `nim_fastjson`
- **Static file serving** — with cache control, ETag support, and MIME detection
- **WebSocket support** — pub/sub, backpressure management, per-message compression
- **HTTP/2** — transparent support via the underlying uSockets layer
- **Response compression** — gzip, brotli, zstd with adaptive policy controls
- **Multi-threaded mode** — `runThreaded()` with SO_REUSEPORT for shared-port parallelism
- **Multi-process cluster** — `runCluster()` with fork-based worker supervision and restart policies
- **Configuration** — JSON config files + environment variable overrides with profile presets
- **Performance profiles** — `throughput`, `latency`, `balanced`, `websocket`, `linux-throughput` presets for tuning socket, I/O, and coalescing parameters
- **Graceful shutdown** — SIGTERM/SIGINT handling with in-flight request draining
- **Request/response pooling** — optional object pooling to reduce GC pressure at high RPS
- **Built-in HTTP client** — connection-pooled, event-loop-integrated HTTP client for outbound requests

## Platform Support

| Platform | Backend | Multi-threading | Multi-process | Recommended scaling |
|----------|---------|-----------------|---------------|---------------------|
| Linux | epoll or io_uring | Full (SO_REUSEPORT + per-thread event loop) | Full (fork + SO_REUSEPORT) | `runCluster` or `runThreaded` |
| macOS | GCD | Limited (single event loop with GCD backend) | Limited (SO_REUSEPORT doesn't load-balance) | Single process + nginx |
| Windows | — | Not supported | Not supported (no fork) | Single process |

### Build differences per platform

**Linux:**
- Supports `TCP_FASTOPEN`, `TCP_DEFER_ACCEPT`, `SO_INCOMING_CPU`, `EPOLL_EXCLUSIVE`, and CPU affinity via `NIM_EXPRESS_CPU_LIST`
- `runCluster` and `runThreaded` use SO_REUSEPORT for kernel-level connection distribution
- Edge-triggered epoll available via `NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER`; io_uring available with `USOCKETS_BACKEND=io_uring`
- Best production performance — use the `linux-throughput` profile

**macOS:**
- Uses GCD-based async pump; `macosHighQos` option to request user-interactive QoS class
- GCD builds require event-loop startup on the process main thread and fail fast otherwise
- `runThreaded` falls back to 1 thread because the GCD event loop does not survive thread creation
- `runCluster` falls back to 1 worker because SO_REUSEPORT does not distribute connections on macOS
- Scale by running multiple instances on different ports behind nginx/haproxy
- Requires `-d:LIBUS_USE_GCD` compile flag and `-framework CoreFoundation` link flag

**Windows:**
- Single-process mode only; `runAuto` selects single-process automatically
- No fork, no SO_REUSEPORT

## Prerequisites

- **Nim** >= 2.0.0
- **nim_usockets** built and available (see [nim_usockets README](../nim_usockets/README.md))
- **C compiler** — gcc or clang
- Compression libraries (optional, for response compression):
  - zlib (gzip)
  - brotli
  - zstd

## Installation

```bash
nimble install
```

### Dependencies (from nimble)

```
nim >= 2.0.0
nim_usockets >= 0.1.0
zippy >= 0.10.0
libdeflate_gzip >= 0.6.0
brotli >= 0.1.0
zstd >= 0.9.0
malebolgia >= 1.3.2
```

## Quick Start

### Hello World

```nim
import nim_express/src/nim_express/app

let app = newExpressApp()

app.get "/", proc(req: Request, res: Response) =
  res.send("Hello, World!")

app.run(3000)
```

### JSON API

```nim
import nim_express/src/nim_express/app
import std/json

let app = newExpressApp()

app.get "/api/status", proc(req: Request, res: Response) =
  res.json(%*{"status": "ok", "version": "1.0.0"})

app.post "/api/echo", proc(req: Request, res: Response) =
  let body = req.getJsonBody()
  if body.isNil:
    res.status(400).json(%*{"error": "Invalid JSON"})
  else:
    res.json(body)

app.run(3000)
```

### Typed JSON deserialization (nim_fastjson)

```nim
type
  CreateUser = object
    name: string
    email: string

app.post "/api/users", proc(req: Request, res: Response) =
  let (ok, user) = req.tryParseBody[:CreateUser]()
  if not ok:
    res.status(400).json(%*{"error": "Invalid body"})
    return
  res.status(201).json(%*{"name": user.name, "email": user.email})
```

### Static file serving

```nim
import nim_express/src/nim_express/app
import nim_express/src/nim_express/middlewares

let app = newExpressApp()
app.use(serveStatic("public", prefix = "/static"))
app.run(3000)
```

### WebSocket

```nim
let app = newExpressApp()

app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
  ws.send("Echo: " & message)

app.onWsOpen proc(ws: WebSocket) =
  ws.subscribe("broadcast")

app.run(3000)
```

### Async handler

```nim
app.getAsync "/api/data", proc(req: Request, res: Response): Future[void] {.async.} =
  let data = await fetchExternalData()
  res.json(%*{"result": data})
```

## Routing

### HTTP methods

```nim
app.get    "/path", handler
app.post   "/path", handler
app.put    "/path", handler
app.delete "/path", handler
app.patch  "/path", handler
app.head   "/path", handler
app.options "/path", handler
app.all    "/path", handler   # matches all methods
```

Each method has a sync variant (default, fastest path) and an async variant for I/O-bound handlers:

```nim
app.get "/sync", proc(req: Request, res: Response) =
  res.send("fast")

app.getAsync "/async", proc(req: Request, res: Response): Future[void] {.async.} =
  await sleepAsync(100)
  res.send("delayed")
```

### Path parameters

Use `:name` to capture path segments:

```nim
app.get "/users/:id", proc(req: Request, res: Response) =
  let userId = req.param("id")
  res.json(%*{"userId": userId})

app.get "/files/:dir/:name", proc(req: Request, res: Response) =
  let dir = req.param("dir")
  let name = req.param("name")
  res.send(dir & "/" & name)
```

### Wildcard routes

Use `*` for catch-all matching:

```nim
app.get "/static/*", proc(req: Request, res: Response) =
  res.send("Matched: " & $req.path)
```

### Route groups

Group routes under a common prefix with shared middleware:

```nim
let api = app.group("/api/v1")

api.get "/users", proc(req: Request, res: Response) =
  res.json(%*{"users": []})

api.post "/users", proc(req: Request, res: Response) =
  res.status(201).json(%*{"created": true})

let admin = api.group("/admin")
admin.get "/stats", proc(req: Request, res: Response) =
  res.json(%*{"connections": 42})
```

## Middleware

### Using middleware

```nim
app.use(myMiddleware())

app.use("/api", apiOnlyMiddleware())

let api = app.group("/api", authMiddleware())
```

### Writing custom middleware

Async middleware:

```nim
proc timing(): AsyncMiddleware =
  result = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
    let start = epochTime()
    await next()
    let ms = ((epochTime() - start) * 1000).int
    res.set("X-Response-Time", $ms & "ms")
```

Sync middleware (faster, no async overhead):

```nim
proc addHeader(): SyncNextMiddleware =
  result = proc(req: Request, res: Response, next: proc()) =
    res.set("X-Powered-By", "nim_express")
    next()
```

### Built-in middleware

All exported via `import nim_express/src/nim_express/middlewares`:

#### CORS

```nim
app.use(cors(CorsOptions(
  origin: @["https://example.com"],
  methods: "GET,POST,PUT,DELETE",
  allowHeaders: "Content-Type,Authorization",
  credentials: true,
  maxAge: 86400
)))
```

A sync variant `corsSync()` is also available for zero-async-overhead CORS.

| Option | Default | Performance note |
|--------|---------|------------------|
| `maxAge` | `0` | Set to 86400 to let browsers cache preflight responses for 24 hours, eliminating redundant OPTIONS requests |
| `origin` | `*` | Wildcard is fastest; per-origin list requires string matching per request |

#### CSRF protection

```nim
app.use(csrf())

app.get "/form", proc(req: Request, res: Response) =
  let token = csrfToken(req)
  res.sendHtml("<input type='hidden' name='_csrf' value='" & token & "'>")
```

#### Helmet (security headers)

```nim
app.use(helmet())

app.use(helmet(HelmetOptions(
  contentSecurityPolicy: "default-src 'self'",
  xFrameOptions: "DENY",
  referrerPolicy: "strict-origin-when-cross-origin"
)))
```

#### Rate limiting

```nim
app.use(rateLimit(
  windowMs = 60_000,
  maxRequests = 100,
  message = "Too many requests"
))

app.use(rateLimitPreset("api"))
```

| Parameter | Default | Tuning guidance |
|-----------|---------|-----------------|
| `windowMs` | `60000` | Shorter windows use less memory (fewer entries) but give less burst tolerance |
| `maxRequests` | `100` | Raise for API-heavy clients; lower for login/auth endpoints |
| `message` | `"Too many requests"` | Static string is pre-serialized, no per-request cost |

**Memory impact:** The rate limiter maintains one counter per client IP per window. At 100k unique IPs with a 60-second window, expect ~10 MB of memory. Stale entries are cleaned up when the window expires.

#### IP filtering

```nim
import nim_express/src/nim_express/middlewares/ip_filter

app.use(ipFilter(IpFilterOptions(
  allowlist: @["10.0.0.0/8", "192.168.1.0/24"],
  denylist: @["10.0.0.5"],
  mode: ifmAllowlist
)))
```

#### Session management

```nim
app.use(session(SessionOptions(
  secret: "your-secret-key",
  name: "sid",
  maxAge: 3600,
  secure: true,
  httpOnly: true,
  sameSite: "Strict",
  store: inMemorySessionStore()
)))

app.get "/profile", proc(req: Request, res: Response) =
  let username = sessionGet(req, "username", "anonymous")
  res.json(%*{"user": username})

app.post "/login", proc(req: Request, res: Response) =
  sessionSet(req, "username", "alice")
  res.json(%*{"ok": true})
```

| Option | Default | Performance note |
|--------|---------|------------------|
| `store` | `inMemorySessionStore()` | In-memory is fastest but not shared across processes. Use Redis/external store for `runCluster` |
| `maxAge` | `3600` | Shorter sessions = less memory in the store |
| `secure` | `false` | No performance impact; always set to `true` in production |
| `sameSite` | `""` | Set to `"Strict"` or `"Lax"` to reduce CSRF attack surface |

#### Response compression

```nim
app.use(compression())

installCompressionPolicy(app, CompressionPolicyOptions(
  minBytes: 1024,
  minSavingsRatio: 0.1
))
```

The framework supports gzip, brotli, and zstd with automatic content negotiation based on `Accept-Encoding`.

| Option | Default | Tuning guidance |
|--------|---------|-----------------|
| `minBytes` | `1024` | Responses smaller than this skip compression entirely — saves CPU for small JSON payloads |
| `minSavingsRatio` | `0.1` | Skip compression when the compressed output saves less than 10% |
| `level` | engine default | Higher levels = better ratio but more CPU. Level 1-4 is typical for real-time APIs |
| `memLevel` | engine default | Higher = more memory per compression context, slightly better ratio |
| `offloadThresholdBytes` | `0` | When > 0, bodies above this size are compressed on a thread pool to avoid blocking the event loop |
| `maxCompressMicrosPerSecond` | `0` | CPU budget limiter; 0 = unlimited |
| `disableWhenBackpressureAboveBytes` | `0` | Auto-disable compression when socket backpressure exceeds this threshold |

#### Text logging

```nim
app.use(logger(llInfo))
```

Log levels: `llDebug`, `llInfo`, `llWarn`, `llError`. Output format: `GET /path 200 - 5ms`.

Log formats: `lfDev` (colored), `lfCombined` (Apache combined), `lfCommon` (Apache common), `lfShort`, `lfTiny`.

```nim
app.use(logger(lfDev))
```

**Performance:** Text logger uses `echo` (stdout with newline). At very high RPS, stdout I/O can become a bottleneck. Use `llWarn` or `llError` in production to log only failures, or switch to the JSON logger with `skipHealthChecks: true`.

#### Structured JSON logging

```nim
import nim_express/src/nim_express/middlewares/json_logger

app.use(jsonLogger())

app.use(jsonLogger(JsonLoggerOptions(
  skipHealthChecks: true,
  excludeFields: {jlfUserAgent}
)))
```

Emits NDJSON to stdout. Auto-skips health-check paths (`/health`, `/healthz`, `/ready`, etc.).

| Option | Default | Performance note |
|--------|---------|------------------|
| `skipHealthChecks` | `true` | Eliminates log noise from load balancer probes |
| `excludeFields` | `{}` | Each excluded field saves one string allocation per request. Exclude `jlfUserAgent` for API-only services |
| `sink` | `nil` (stdout) | Custom sink proc for writing to a buffer, file, or external log aggregator |
| `skipPaths` | `[]` | Additional paths to skip beyond the built-in health paths |

Available fields: `jlfTimestamp`, `jlfMethod`, `jlfPath`, `jlfStatus`, `jlfDurationMs`, `jlfRequestId`, `jlfTraceId`, `jlfRemoteIp`, `jlfUserAgent`, `jlfContentLength`, `jlfError`.

**Performance comparison — logger vs jsonLogger:**

| Aspect | `logger` (text) | `jsonLogger` (NDJSON) |
|--------|----------------|-----------------------|
| Format | Human-readable one-liner | Machine-parseable JSON |
| Allocation | 1-2 string allocs per request | 1 pre-sized 512-byte buffer per request |
| I/O | `echo` (line-buffered stdout) | `echo` or custom sink |
| Best for | Development, low-RPS | Production, log aggregation pipelines |

#### Error handling (RFC 7807)

```nim
import nim_express/src/nim_express/middlewares/error_handler

app.use(errorHandler(ErrorHandlerOptions(
  devMode: true,
  logErrors: true
)))
```

Catches unhandled exceptions and returns `application/problem+json` responses per RFC 7807.

| Option | Default | Description |
|--------|---------|-------------|
| `devMode` | `false` | When `true` and `NIM_EXPRESS_ENV != "production"`, includes exception details and type in the response |
| `logErrors` | `true` | Write error details to stderr |

#### Panic recovery

```nim
app.use(panicRecovery())

app.use(panicRecovery(PanicRecoveryOptions(
  responseFormat: erfJson,
  logErrors: true,
  includeStackTrace: false,
  reportHook: proc(err: ref Exception, req: Request, path: string) =
    echo "PANIC: ", err.msg
)))
```

| Option | Default | Description |
|--------|---------|-------------|
| `responseFormat` | `erfJson` | `erfJson` or `erfPlainText` |
| `logErrors` | `true` | Write panics to stderr |
| `includeStackTrace` | `false` | Include stack trace in stderr output |
| `reportHook` | `nil` | Custom callback for error reporting integration (Sentry, Datadog, etc.) |

**Important:** Requires `--panics:off` to catch `Defect` exceptions. Without it, Defects terminate the process immediately.

#### Global error filter

```nim
app.use(globalErrorFilterWithBuiltins())

app.use(globalErrorFilter(@[
  valueErrorFilter(),
  keyErrorFilter(),
  ioErrorFilter(),
  osErrorFilter(),
  jsonParsingErrorFilter(),
  newExceptionFilter("MyError", proc(err: ref Exception, req: Request, res: Response): bool =
    if err of MyCustomError:
      res.status(422).json(%*{"error": "Validation failed"})
      return true
    false
  )
]))
```

Maps exception types to HTTP responses. Built-in filters handle `ValueError` → 400, `KeyError` → 400, `IOError` → 502, `OSError` → 503, `JsonParsingError` → 400.

Filters are sorted by `priority` (higher runs first). Built-in priorities: ValueError=100, KeyError=90, IOError=70, OSError=60, JsonParsingError=50.

#### Graceful shutdown

```nim
app.use(gracefulShutdown(GracefulShutdownOptions(
  drainTimeoutMs: 30000,
  healthPath: "/health",
  forceExitOnTimeout: true,
  shutdownHooks: @[
    proc() = echo "Closing database connections...",
    proc() = echo "Flushing metrics..."
  ]
)))
```

Handles SIGTERM/SIGINT, returns 503 for new requests during drain, and runs cleanup hooks.

| Option | Default | Tuning guidance |
|--------|---------|-----------------|
| `drainTimeoutMs` | `30000` | Match your load balancer's deregistration delay (typically 30s for AWS ALB/ELB) |
| `healthPath` | `"/health"` | Returns 503 during shutdown so the load balancer stops routing |
| `forceExitOnTimeout` | `false` | Set to `true` in production to prevent zombie processes if drain stalls |
| `shutdownHooks` | `[]` | Run in order after drain completes — close DB pools, flush metrics, etc. |

**Drain behavior:** On SIGTERM/SIGINT, the middleware immediately rejects new requests with 503 + `Connection: close`. In-flight requests are allowed to complete up to `drainTimeoutMs`. A background loop checks every 1 second whether all in-flight requests have drained.

#### Circuit breaker

```nim
let cb = newCircuitBreaker(
  name = "external-api",
  failureThreshold = 5,
  successThreshold = 2,
  timeoutMs = 30000
)

app.use(circuitBreakerMiddleware(cb))
```

States: `Closed` → `Open` (after threshold failures) → `HalfOpen` (after timeout) → `Closed` (after consecutive successes). Returns 503 with `Retry-After` when open.

| Option | Default | Tuning guidance |
|--------|---------|-----------------|
| `failureThreshold` | `5` | Number of consecutive 5xx responses before opening the circuit |
| `successThreshold` | `2` | Number of consecutive successes in HalfOpen before closing |
| `timeoutMs` | `30000` | How long the circuit stays Open before allowing a probe request |
| `name` | `"default"` | Included in the 503 response body for debugging |

**HalfOpen behavior:** The circuit allows up to `successThreshold` concurrent probe requests in HalfOpen state. A single failure immediately re-opens the circuit. This prevents a thundering herd of requests when the upstream recovers.

#### Reverse proxy

```nim
import nim_express/src/nim_express/middlewares/proxy

app.use("/api", proxy(ProxyOptions(
  target: "http://backend:8080",
  stripPrefix: "/api",
  addXForwardedHeaders: true,
  blockPrivateUpstreams: true,
  timeoutMs: 30000
)))
```

**Connection reuse.** `proxy` opens a new upstream connection for every request and
resolves DNS on the event loop. For pooled upstream connections and offloaded DNS,
build `fastProxy` once and keep it for the process lifetime:

```nim
import nim_express/src/nim_express/middlewares/fast_proxy

app.use("/api", fastProxy("http://backend:8080"))
```

| Option | Default | Description |
|--------|---------|-------------|
| `target` | `""` | Static upstream URL |
| `targetResolver` | `nil` | Dynamic per-request upstream resolver (overrides `target`) |
| `timeoutMs` | `30000` | Upstream request timeout |
| `stripPrefix` | `""` | Remove this prefix before forwarding |
| `pathRewriter` | `nil` | Custom path transformation function |
| `preserveHostHeader` | `false` | Forward the original Host header to upstream |
| `addXForwardedHeaders` | `true` | Add X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Host |
| `blockPrivateUpstreams` | `true` | Block requests to RFC 1918 / link-local / loopback addresses |

#### Request ID

```nim
app.use(requestId())
```

Generates or propagates a unique request ID for every request, stored in `req.locals["requestId"]`.

#### Health endpoint

```nim
app.use(health())
```

Responds to `/health` (configurable) with 200 OK and request count metrics.

#### Body limit

```nim
app.use(bodyLimit(BodyLimitOptions(maxBytes: 1_048_576)))
```

#### Request timeout

```nim
app.use(timeout(5000))
```

#### Concurrency guard

```nim
app.use(concurrencyGuard(maxConcurrent = 100))
```

#### ETag

```nim
app.use(etag())
```

#### Server-Timing

```nim
app.use(serverTiming())
```

#### Path normalization

```nim
app.use(normalizePath())
```

#### Method override

```nim
app.use(methodOverride())
```

#### Static files

```nim
app.use(serveStatic("public"))

app.use(serveStatic("assets", prefix = "/static", cache = StaticCacheOptions(
  defaultMaxAgeSeconds: 600,
  immutableMaxAgeSeconds: 31536000,
  immutableExtensions: @[".css", ".js", ".woff2"]
)))
```

#### OpenAPI / Swagger

```nim
app.use(openapi())
```

## Request API

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `req.path` | `string` | Request path (e.g. `"/users/42"`) |
| `req.methodKind` | `HttpMethod` | HTTP method enum (`hmGet`, `hmPost`, etc.) |
| `req.body` | `string` | Raw request body (call `req.bindBody()` or `req.rawBody()` first) |
| `req.jsonBody` | `JsonNode` | Parsed JSON body (call `req.getJsonBody()` first) |
| `req.headers` | `FastMap[string]` | Request headers (call `req.bindHeaders()` first) |
| `req.params` | `FastMap[string]` | Route parameters |
| `req.query` | `FastMap[string]` | Query string parameters (call `req.bindQuery()` first) |
| `req.cookies` | `FastMap[string]` | Parsed cookies |
| `req.locals` | `FastMap[string]` | Per-request key-value store for middleware communication |
| `req.correlationId` | `string` | Auto-generated correlation ID |

### Methods

```nim
req.get("content-type")        # get a header value
req.param("id")                # get a route parameter
req.getCookie("session")       # get a cookie value
req.getJsonBody()              # parse and return JSON body
req.rawBody()                  # raw body string
req.parseBody[:MyType]()       # typed deserialization via nim_fastjson
req.tryParseBody[:MyType]()    # safe typed parse returning (ok, value)
req.rawQuery()                 # raw query string
req.accepts("text/html", "application/json")  # content negotiation
req.hostname()                 # hostname from Host header
req.protocol()                 # "http" or "https"
req.secure()                   # true if HTTPS
req.fresh(etag, lastModified)  # conditional request freshness check
```

## Response API

### Chaining

Most response methods return `Response` for chaining:

```nim
res.status(201).set("X-Custom", "value").json(%*{"created": true})
```

### Methods

```nim
res.send("Hello")              # send text/plain response
res.json(%*{"key": "value"})   # send JSON response
res.json(myTypedObject)        # serialize typed object to JSON via nim_fastjson
res.json("{\"raw\":true}")     # send pre-serialized JSON string
res.status(404)                # set status code (chainable)
res.set("Header", "value")     # set response header (chainable)
res.redirect("/new-location")  # 302 redirect
res.redirect("/new", 301)      # redirect with custom status
res.sendStatus(204)            # send status code with default body
res.cookie("name", "value",    # set a cookie
  maxAge = 3600,
  path = "/",
  secure = true,
  httpOnly = true,
  sameSite = "Strict"
)
res.clearCookie("name")        # clear a cookie
res.render("index", locals)    # render an embedded view template
```

## Configuration

### Config file

nim_express loads configuration from `config.json` (or `settings.json` as fallback) in the working directory:

```json
{
  "profile": "balanced",
  "server": {
    "host": "0.0.0.0",
    "port": 3000,
    "trustProxy": false,
    "maxBodySize": 8388608,
    "connectionTimeoutSeconds": 120,
    "maxConnections": 65536,
    "maxPendingBytesPerSocket": 0,
    "minimalHeaderParsing": false,
    "gracefulShutdown": true,
    "macosHighQos": false,
    "tlsFlattenThreshold": 0
  },
  "runtime": {
    "asyncPumpIntervalMs": 1,
    "maxInflightAsyncRequests": 8192,
    "contextPoolPrewarm": 256,
    "requestResponsePoolingEnabled": false
  },
  "socket": {
    "noDelay": true,
    "keepAlive": true,
    "keepAliveSeconds": 60,
    "fastOpen": true,
    "sendBufferBytes": 262144,
    "recvBufferBytes": 131072,
    "notSentLowWaterBytes": 0,
    "deferAcceptSeconds": 0,
    "incomingCpu": -1,
    "exclusivePort": false,
    "epollExclusive": false,
    "epollEdgeTrigger": false
  },
  "coalesce": {
    "mode": "balanced",
    "maxBytes": 65536,
    "maxResponses": 16,
    "throughputMaxBytes": 131072,
    "throughputMaxResponses": 32
  },
  "budgets": {
    "parseRequestsPerRead": 512,
    "parseBytesPerRead": 8388608,
    "loopRequests": 4096,
    "loopBytes": 67108864,
    "writeIterations": 512,
    "writeBytes": 8388608,
    "loopWriteBytes": 67108864
  },
  "overload": {
    "maxBacklogBytes": 16777216,
    "maxPendingResponses": 4096,
    "closeOnReject": false,
    "adaptive": {
      "enabled": false,
      "minBacklogBytes": 0,
      "maxBacklogBytes": 0,
      "minPendingResponses": 0,
      "maxPendingResponses": 0,
      "tightenStepPercent": 10,
      "relaxStepPercent": 5,
      "cooldownRequests": 100
    }
  },
  "websocket": {
    "keepaliveIntervalMs": 30000,
    "idleTimeoutSeconds": 120,
    "maxBackpressureBytes": 1048576,
    "backpressureHighWaterBytes": 0,
    "closeOnBackpressureLimit": false,
    "resetIdleTimeoutOnSend": false,
    "writeCoalesceMaxBytes": 0,
    "writeCoalesceMaxFrames": 0,
    "socketRecvBufferBytes": 0,
    "socketSendBufferBytes": 0,
    "socketNotSentLowWaterBytes": 0,
    "compression": {
      "enabled": false,
      "thresholdBytes": 0,
      "minSavingsBytes": 0,
      "disableForBinary": false,
      "disableForText": false,
      "backpressureBypassBytes": 0
    }
  },
  "body": {
    "spillThresholdBytes": 0,
    "spillDir": "/tmp/nim_express_bodies"
  }
}
```

### Loading config

```nim
let cfg = loadAppEnvConfig()
app.applyAppEnvConfig(cfg)
app.listen(cfg.host, cfg.port) do (success: bool):
  echo "Listening on port ", cfg.port

let cfg = loadAppEnvConfig("custom-config.json", strictConfig = true)
app.run(cfg)
```

Or use the convenience wrapper:

```nim
let cfg = app.loadAndApplyAppEnvConfig()
```

### Precedence

**defaults** → **config.json** → **environment variables** (highest priority)

When `strictConfig = true` (or `NIM_EXPRESS_STRICT_CONFIG=true`), JSON parse errors raise an `IOError` instead of falling back to defaults. Environment variable overrides are always applied regardless of `strictConfig`.

### Performance profiles

Set via config JSON or `NIM_EXPRESS_PROFILE`:

| Profile | Optimized for | Key settings |
|---------|---------------|--------------|
| `throughput` | Maximum requests/sec | Large buffers, aggressive coalescing (256 KB / 128 responses), minimal header parsing, high overload limits |
| `latency` | Minimum response latency | TCP_NODELAY, minimal coalescing (8 KB / 4 responses), overload protection disabled |
| `balanced` | General-purpose mix | TCP_NODELAY, moderate coalescing (64 KB / 16 responses), sensible overload limits |
| `websocket` | WebSocket-heavy workloads | Tuned backpressure (2 MB limit, 1.5 MB high water), write coalescing (128 KB / 64 frames) |
| `linux-throughput` | Linux-specific maximum throughput | All of `throughput` plus epoll exclusive, CPU affinity, TCP_FASTOPEN, TCP_DEFER_ACCEPT |

## Environment Variables

### Core

| Variable | Default | Description |
|----------|---------|-------------|
| `NIM_EXPRESS_HOST` / `HOST` | `0.0.0.0` | Listen address |
| `NIM_EXPRESS_PORT` / `PORT` | `3000` | Listen port |
| `NIM_EXPRESS_PROFILE` | — | Performance profile preset |
| `NIM_EXPRESS_ENV` | — | Environment name (`production`, `development`) |
| `NIM_EXPRESS_CONFIG` | — | Path to config file |
| `NIM_EXPRESS_STRICT_CONFIG` | `false` | Raise on config parse errors |
| `NIM_EXPRESS_TRUST_PROXY` | `false` | Trust X-Forwarded-* headers |

### Server tuning

| Variable | Description | Performance impact |
|----------|-------------|-------------------|
| `NIM_EXPRESS_MAX_BODY_SIZE` | Maximum request body in bytes | Lower values reject large uploads early, saving memory |
| `NIM_EXPRESS_CONNECTION_TIMEOUT_SEC` | Connection idle timeout | Lower values free file descriptors faster under high connection churn |
| `NIM_EXPRESS_MAX_CONNECTIONS` | Maximum concurrent connections | Caps memory usage; set based on available RAM |
| `NIM_EXPRESS_MAX_PENDING_BYTES_PER_SOCKET` | Per-socket write buffer limit | Prevents a single slow client from consuming unbounded memory |
| `NIM_EXPRESS_GRACEFUL_SHUTDOWN` | Enable graceful shutdown at server level | — |
| `NIM_EXPRESS_MINIMAL_HEADER_PARSING` | Skip parsing unused headers | Reduces per-request CPU for APIs that don't inspect headers |
| `NIM_EXPRESS_MACOS_HIGH_QOS` | Request high QoS on macOS | Hints to macOS scheduler to prioritize the event loop thread |
| `NIM_EXPRESS_TLS_FLATTEN_THRESHOLD` | TLS record flattening threshold | Reduces small-record overhead for TLS workloads |

### Async runtime

| Variable | Description | Performance impact |
|----------|-------------|-------------------|
| `NIM_EXPRESS_ASYNC_PUMP_INTERVAL_MS` | Async dispatcher poll interval (1-60000) | Lower = more responsive async handlers but more CPU when idle |
| `NIM_EXPRESS_MAX_INFLIGHT_ASYNC_REQUESTS` | Cap on concurrent async handlers | Prevents runaway memory from too many in-flight async operations |
| `NIM_EXPRESS_CONTEXT_POOL_PREWARM` | Pre-allocate request/response objects | Eliminates GC pauses during initial traffic ramp |
| `NIM_EXPRESS_REQUEST_RESPONSE_POOLING` | Enable object pool reuse | Reduces GC pressure at high RPS; adds pool management overhead at low RPS |

### Socket options

| Variable | Description | Performance impact |
|----------|-------------|-------------------|
| `NIM_EXPRESS_SOCKET_NODELAY` | TCP_NODELAY | Disables Nagle's algorithm; reduces latency, may increase packet count |
| `NIM_EXPRESS_SOCKET_KEEPALIVE` | SO_KEEPALIVE | Detects dead connections; frees resources |
| `NIM_EXPRESS_SOCKET_KEEPALIVE_SEC` | Keep-alive interval | — |
| `NIM_EXPRESS_SOCKET_FASTOPEN` | TCP_FASTOPEN | Saves one RTT on new connections (Linux) |
| `NIM_EXPRESS_SOCKET_SNDBUF` | SO_SNDBUF | Larger = more kernel-buffered data, higher memory per socket |
| `NIM_EXPRESS_SOCKET_RCVBUF` | SO_RCVBUF | Larger = better burst absorption |
| `NIM_EXPRESS_SOCKET_NOTSENT_LOWAT` | TCP_NOTSENT_LOWAT | Controls when the kernel wakes the writer; lower = more responsive, higher CPU |
| `NIM_EXPRESS_SOCKET_DEFER_ACCEPT_SEC` | TCP_DEFER_ACCEPT (Linux) | Delays accept until data arrives; reduces wasted accepts from connection scanners |

### Write coalescing

| Variable | Description | Performance impact |
|----------|-------------|-------------------|
| `NIM_EXPRESS_WRITE_COALESCE_MODE` | `adaptive`, `latency`, `balanced`, `throughput` | Controls the trade-off between response latency and syscall efficiency |
| `NIM_EXPRESS_WRITE_COALESCE_MAX_BYTES` | Max bytes per coalesced write | Larger = fewer syscalls but higher per-response latency |
| `NIM_EXPRESS_WRITE_COALESCE_MAX_RESPONSES` | Max responses per coalesced write | — |

### Event loop budgets

| Variable | Description |
|----------|-------------|
| `NIM_EXPRESS_PARSE_BUDGET_REQUESTS` | Max requests parsed per read event |
| `NIM_EXPRESS_PARSE_BUDGET_BYTES` | Max bytes parsed per read event |
| `NIM_EXPRESS_LOOP_DISPATCH_REQUESTS` | Max requests dispatched per loop iteration |
| `NIM_EXPRESS_LOOP_DISPATCH_BYTES` | Max bytes dispatched per loop iteration |
| `NIM_EXPRESS_WRITE_BUDGET_ITERATIONS` | Max write iterations per flush |
| `NIM_EXPRESS_WRITE_BUDGET_BYTES` | Max bytes written per flush |
| `NIM_EXPRESS_LOOP_WRITE_BUDGET_BYTES` | Max total write bytes per loop iteration |

### Overload protection

| Variable | Description | Performance impact |
|----------|-------------|-------------------|
| `NIM_EXPRESS_OVERLOAD_MAX_BACKLOG_BYTES` | Reject when backlog exceeds | Prevents OOM under sustained overload |
| `NIM_EXPRESS_OVERLOAD_MAX_PENDING_RESPONSES` | Reject when pending responses exceed | Caps memory used by response buffers |
| `NIM_EXPRESS_OVERLOAD_CLOSE_ON_REJECT` | Close connection on overload reject | `true` frees resources faster but forces client reconnect |
| `NIM_EXPRESS_OVERLOAD_ADAPTIVE` | Enable adaptive overload thresholds | Auto-tunes rejection thresholds based on observed load |

### WebSocket

| Variable | Description |
|----------|-------------|
| `NIM_EXPRESS_WS_KEEPALIVE_INTERVAL_MS` | WebSocket ping interval |
| `NIM_EXPRESS_WS_IDLE_TIMEOUT_SEC` | WebSocket idle disconnect |
| `NIM_EXPRESS_WS_MAX_BACKPRESSURE_BYTES` | Max buffered WebSocket bytes |
| `NIM_EXPRESS_WS_BACKPRESSURE_HIGH_WATER_BYTES` | High water mark for backpressure callbacks |
| `NIM_EXPRESS_WS_CLOSE_ON_BACKPRESSURE_LIMIT` | Close WebSocket when backpressure limit reached |
| `NIM_EXPRESS_WS_COMPRESSION_ENABLED` | Enable per-message compression |
| `NIM_EXPRESS_WS_WRITE_COALESCE_MAX_BYTES` | Max bytes per coalesced WebSocket write |
| `NIM_EXPRESS_WS_WRITE_COALESCE_MAX_FRAMES` | Max frames per coalesced WebSocket write |

### Body spilling

| Variable | Description | Performance impact |
|----------|-------------|-------------------|
| `NIM_EXPRESS_BODY_SPILL_THRESHOLD_BYTES` | Spill large bodies to disk (0 = disabled) | Prevents large uploads from exhausting memory; adds disk I/O latency |
| `NIM_EXPRESS_BODY_SPILL_DIR` | Directory for spilled bodies | Use a fast filesystem (tmpfs/ramdisk) to minimize spill latency |

### Linux-specific

| Variable | Description | Performance impact |
|----------|-------------|-------------------|
| `NIM_EXPRESS_CPU_LIST` | CPU affinity for worker threads (e.g. `0-3,6,7`) | Pin workers to physical cores; avoids context switching overhead |
| `NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE` | EPOLLEXCLUSIVE for load distribution | Prevents thundering herd on accept |
| `NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER` | Edge-triggered epoll | Reduces epoll_wait wakeups; requires correct drain loops |
| `NIM_EXPRESS_LISTEN_EXCLUSIVE_PORT` | SO_REUSEPORT exclusive | — |

## Building

### Linux (recommended for production)

```bash
nim c -d:release -d:danger --panics:off --threads:on -o:server src/main.nim
```

For maximum performance with link-time optimization:

```bash
nim c -d:release -d:danger -d:lto --panics:off --threads:on --opt:speed -o:server src/main.nim
```

### macOS (development)

```bash
nim c -d:release --panics:off -d:LIBUS_USE_GCD --threads:on \
  --passL:"-framework CoreFoundation" -o:server src/main.nim
```

### macOS (production, without GCD threading)

```bash
nim c -d:release -d:danger --panics:off -d:LIBUS_USE_GCD --threads:on \
  --passL:"-framework CoreFoundation" --opt:speed -o:server src/main.nim
```

### Important: `--panics:off`

The `--panics:off` flag is **required** for middleware error recovery. With Nim 2.x defaults (`--panics:on`), `Defect` exceptions terminate the process immediately. Setting `--panics:off` allows the panic recovery and error handler middleware to catch `Defect` exceptions and return 500 responses instead of crashing.

### Debug build

```bash
nim c --panics:off --threads:on -o:server src/main.nim
```

### Common defines

| Flag | Description | When to use |
|------|-------------|-------------|
| `-d:release` | Enable optimizations | Always in production |
| `-d:danger` | Disable all runtime checks (bounds, overflow, nil) | Production where throughput is critical |
| `-d:lto` | Link-time optimization across compilation units | Production; 5-15% throughput improvement, longer compile |
| `--panics:off` | Allow Defect recovery in middleware | Always (required for error handling) |
| `--threads:on` | Enable multi-threading support | Required for `runThreaded`, async pump wake thread on macOS |
| `--opt:speed` | Optimize for speed over size | Production |
| `-d:LIBUS_USE_GCD` | macOS GCD backend | macOS only |
| `-d:singleThread` | Disable thread-local storage (single-thread only) | Micro-optimization for single-process deployments |

## Scaling Modes

### Single process

```nim
let app = newExpressApp()
app.get "/", proc(req: Request, res: Response) =
  res.send("Hello!")
app.run(3000)
```

The simplest mode. All platforms. Single event loop, single thread. Suitable for development and low-to-moderate traffic.

### Multi-threaded (`runThreaded`)

```nim
proc createApp(): ExpressApp =
  let app = newExpressApp()
  app.get "/", proc(req: Request, res: Response) =
    res.send("Hello from worker!")
  app

runThreaded(createApp, port = 3000, numThreads = 4)
```

Each thread runs its own event loop. On Linux with SO_REUSEPORT, the kernel distributes connections across threads.

- **Linux:** Full support. Each thread binds to the same port via SO_REUSEPORT. The kernel balances incoming connections.
- **macOS:** Falls back to 1 thread (GCD event loop cannot be created in spawned threads).
- **Windows:** Not supported.

### Multi-process cluster (`runCluster`)

```nim
proc createApp(): ExpressApp =
  let app = newExpressApp()
  app.get "/", proc(req: Request, res: Response) =
    res.send("Hello from worker!")
  app

runCluster(createApp, port = 3000, numWorkers = 4)
```

Fork-based worker supervision with configurable restart backoff and storm protection.

- **Linux:** Full support. Workers fork and bind the same port via SO_REUSEPORT.
- **macOS:** Falls back to 1 worker (SO_REUSEPORT doesn't load-balance, GCD doesn't survive fork).
- **Windows:** Not available (no fork).

### Auto-select (`runAuto`)

```nim
runAuto(createApp, port = 3000)
```

Picks the best mode for the current platform:
- **Linux:** `runCluster` with `defaultWorkerCount()` workers (40% of CPUs, or full cpuset for `linux-throughput` profile)
- **macOS:** Single process
- **Windows:** Single process

### Which mode for which workload

| Workload | Linux | macOS |
|----------|-------|-------|
| Development / prototyping | `app.run(3000)` | `app.run(3000)` |
| CPU-bound API (JSON serialization, computation) | `runThreaded` or `runCluster` | Single process + nginx across ports |
| I/O-bound API (database queries, upstream calls) | `runAuto` | Single process (async handles concurrency) |
| WebSocket-heavy (chat, real-time) | `runThreaded` (shared-memory pub/sub) | Single process |
| Mixed HTTP + WebSocket | `runCluster` | Single process + nginx |

### macOS scaling with nginx

Since macOS cannot use `runThreaded` or `runCluster` effectively, scale by running multiple instances on different ports behind nginx:

```bash
./server --port=3010 &
./server --port=3011 &
./server --port=3012 &
./server --port=3013 &
```

```nginx
upstream nim_backend {
    server 127.0.0.1:3010;
    server 127.0.0.1:3011;
    server 127.0.0.1:3012;
    server 127.0.0.1:3013;
}

server {
    listen 3000;
    location / {
        proxy_pass http://nim_backend;
    }
}
```

## Performance Tuning

### Compile flags for production

The recommended production build on Linux:

```bash
nim c \
  -d:release \
  -d:danger \
  -d:lto \
  --panics:off \
  --threads:on \
  --opt:speed \
  -o:server src/main.nim
```

| Flag | Effect | Typical impact |
|------|--------|----------------|
| `-d:release` | Enables `-O3`, disables debug info | 2-5x faster than debug |
| `-d:danger` | Removes bounds checks, overflow checks, nil checks | 10-30% throughput improvement over `-d:release` |
| `-d:lto` | Link-time optimization across all modules | 5-15% throughput improvement; compile time doubles |
| `--opt:speed` | Favor speed over binary size | Marginal improvement when combined with `-d:release` |
| `--panics:off` | Allow Defect recovery | Required for error handling middleware |

### Server options that affect throughput

| Setting | Default | Guidance |
|---------|---------|----------|
| `maxConnections` | `65536` | Set based on available file descriptors (`ulimit -n`). Each connection uses ~2-4 KB |
| `connectionTimeoutSeconds` | `120` | Lower (30-60s) for stateless APIs to reclaim idle connections faster |
| `maxBodySize` | `8388608` (8 MB) | Lower for JSON APIs (e.g. 1 MB) to reject oversized payloads early |
| `maxPendingBytesPerSocket` | `0` (unlimited) | Set to 256 KB - 1 MB to bound per-socket memory from slow clients |
| `minimalHeaderParsing` | `false` | Set to `true` for APIs that don't inspect headers — skips allocating header map |

### Middleware ordering for performance

Middleware runs in registration order. Place cheap/rejecting middleware first to short-circuit before expensive work:

```nim
app.use(gracefulShutdown(...))     # 1. Must be first to track in-flight requests
app.use(panicRecovery())           # 2. Catch panics from all downstream middleware
app.use(requestId())               # 3. Cheap: generates one UUID
app.use(helmet())                  # 4. Cheap: sets static headers
app.use(cors())                    # 5. May short-circuit OPTIONS preflight
app.use(rateLimit(...))            # 6. Rejects excess traffic before body parsing
app.use(bodyLimit(...))            # 7. Rejects oversized bodies before reading
app.use(timeout(30000))            # 8. Installs timeout budget
app.use(compression())             # 9. Runs after handler (wraps response)
app.use(jsonLogger())              # 10. Logs after handler completes
app.use(errorHandler(...))         # 11. Catches errors from handlers
```

**Principles:**
- Rejecting middleware (rate limit, body limit, IP filter) should go before any I/O work
- Logging middleware should wrap handlers to measure duration
- Compression wraps the response and runs after the handler
- Error handlers should be near the end to catch everything above them

### Async handler best practices

```nim
app.get "/sync", proc(req: Request, res: Response) =
  res.json(%*{"fast": true})

app.getAsync "/io-bound", proc(req: Request, res: Response): Future[void] {.async.} =
  let data = await dbQuery("SELECT ...")
  res.json(%*{"data": data})
```

- Use **sync handlers** for CPU-bound work (JSON serialization, in-memory lookups). They avoid the async state machine overhead entirely.
- Use **async handlers** only when you need to `await` I/O (database, HTTP calls, file I/O). Each in-flight async handler consumes memory for its coroutine state.
- Cap concurrent async handlers with `maxInflightAsyncRequests` (default 8192) to prevent memory exhaustion under load.
- The async pump polls at `asyncPumpIntervalMs` (default 1ms). Lower values increase responsiveness but consume more CPU when idle.

### Request/response object pooling

```nim
let cfg = loadAppEnvConfig()
cfg.requestResponsePoolingEnabled = true
cfg.contextPoolPrewarm = 512
app.applyAppEnvConfig(cfg)
```

At high RPS (>50k req/s), enabling object pooling reduces GC pressure by reusing `Request` and `Response` objects instead of allocating new ones per request. The pool is thread-local, so each thread in `runThreaded` mode maintains its own pool. Max pool size is controlled by `setContextPoolMax()` (default 4096).

### Write coalescing

Write coalescing batches multiple response writes into a single syscall. This is the single most impactful tuning knob for throughput:

| Mode | Behavior | Best for |
|------|----------|----------|
| `latency` | Minimal batching (8 KB / 4 responses) | Real-time APIs, WebSocket |
| `balanced` | Moderate batching (64 KB / 16 responses) | General purpose |
| `throughput` | Aggressive batching (256 KB / 128 responses) | Benchmark, batch APIs |
| `adaptive` | Auto-adjusts based on load | Unknown workload |

### Body size limits and spill-to-disk

For services that accept file uploads or large payloads:

```json
{
  "server": {
    "maxBodySize": 104857600
  },
  "body": {
    "spillThresholdBytes": 1048576,
    "spillDir": "/tmp/nim_express_bodies"
  }
}
```

When `spillThresholdBytes > 0`, request bodies larger than the threshold are written to disk instead of held in memory. The handler reads the body from the spill file via `req.rawBody()` transparently. The file is automatically deleted when the request completes.

Use a tmpfs/ramdisk mount for `spillDir` to minimize disk I/O latency while still bounding memory usage.

### Overload protection

The built-in overload protection rejects requests with 503 when the server is overwhelmed:

```json
{
  "overload": {
    "maxBacklogBytes": 16777216,
    "maxPendingResponses": 4096,
    "closeOnReject": false,
    "adaptive": {
      "enabled": true,
      "tightenStepPercent": 10,
      "relaxStepPercent": 5,
      "cooldownRequests": 100
    }
  }
}
```

**Adaptive mode** automatically tightens thresholds when rejection rate is high and relaxes when load drops. This prevents cascading failures without manual tuning.

### Connection draining and graceful shutdown timing

For zero-downtime deployments behind a load balancer:

1. Load balancer sends health check to `/health`
2. Deploy sends SIGTERM to the old process
3. Graceful shutdown middleware starts returning 503 on `/health`
4. Load balancer stops routing new connections (deregistration delay)
5. In-flight requests complete up to `drainTimeoutMs`
6. Shutdown hooks run (close DB connections, flush metrics)
7. Process exits

**Timing guidelines:**

| Setting | Value | Why |
|---------|-------|-----|
| `drainTimeoutMs` | 30000 | Must be >= load balancer deregistration delay |
| `forceExitOnTimeout` | `true` | Prevent zombie processes from stuck requests |
| Load balancer health check interval | 5-10s | Faster detection of shutdown state |
| Load balancer deregistration delay | 30s | Match `drainTimeoutMs` |

## Production Deployment Checklist

### Build

- [ ] Compile with `-d:release -d:danger --panics:off --threads:on`
- [ ] Add `-d:lto` for additional throughput (increases compile time)
- [ ] On macOS, include `-d:LIBUS_USE_GCD --passL:"-framework CoreFoundation"`
- [ ] Verify binary runs without SIGSEGV (rebuild uSockets with `WITH_GCD=1` on macOS if needed)

### Configuration

- [ ] Set `NIM_EXPRESS_ENV=production`
- [ ] Choose a performance profile (`balanced` for general, `linux-throughput` for Linux)
- [ ] Enable `strictConfig = true` to catch config file errors at startup
- [ ] Set `trustProxy = true` if behind a reverse proxy / load balancer
- [ ] Configure `maxBodySize` to the smallest acceptable value for your API
- [ ] Set `maxConnections` based on available RAM and file descriptor limit

### Middleware

- [ ] `gracefulShutdown` is first in the middleware stack
- [ ] `panicRecovery` is second (catches Defects from all downstream)
- [ ] `helmet` is included for security headers
- [ ] `rateLimit` is configured for public-facing endpoints
- [ ] `bodyLimit` prevents oversized payloads
- [ ] `errorHandler` returns structured errors (RFC 7807)
- [ ] `jsonLogger` with `skipHealthChecks: true` for production logging
- [ ] `compression` for responses > 1 KB

### Scaling

- [ ] Linux: use `runCluster` or `runThreaded` with worker count = CPU count
- [ ] macOS: deploy multiple instances behind nginx
- [ ] Set `NIM_EXPRESS_CPU_LIST` on Linux to pin workers to physical cores
- [ ] Configure `ulimit -n` to at least `maxConnections + 1024`

### Monitoring

- [ ] Expose `/metrics` endpoint with `optimizationMetricsJson()`
- [ ] Monitor: parser errors, overload rejects, write retries, backpressure drops
- [ ] Set up alerts for sustained 503 responses (overload or circuit breaker open)

### Security

- [ ] Set `blockPrivateUpstreams: true` on all proxy middleware
- [ ] Enable CSRF protection for browser-facing forms
- [ ] Configure CORS with explicit origin allowlist (not wildcard) in production
- [ ] Set session cookies with `secure: true`, `httpOnly: true`, `sameSite: "Strict"`
- [ ] Use `bodyLimit` to prevent request body abuse

## Troubleshooting

### All platforms

| Symptom | Cause | Fix |
|---------|-------|-----|
| 500 errors with no logs | Defect exception killing the process | Compile with `--panics:off` |
| Memory growth over time | Object pool disabled, GC not keeping up | Enable `requestResponsePoolingEnabled` and set `contextPoolPrewarm` |
| Slow response times under load | Write coalescing too aggressive | Switch to `latency` or `balanced` coalesce mode |
| 503 "Service Unavailable" | Overload protection rejecting | Increase `overloadMaxPendingResponses` or enable adaptive mode |
| Request body empty | Body not bound before access | Call `req.rawBody()` or `req.getJsonBody()` before accessing `req.body` |
| Middleware not running | Registered after `app.listen()` | Register all middleware before calling `listen()` or `run()` |

### Linux

| Symptom | Cause | Fix |
|---------|-------|-----|
| `EMFILE` / too many open files | File descriptor limit too low | `ulimit -n 65536` or set in systemd unit |
| Uneven load across workers | Missing EPOLL_EXCLUSIVE | Set `NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE=true` |
| High CPU with few connections | Edge-triggered epoll misconfigured | Disable edge trigger or verify drain loops |
| `TCP_FASTOPEN` not working | Kernel setting disabled | `sysctl -w net.ipv4.tcp_fastopen=3` |

### macOS

| Symptom | Cause | Fix |
|---------|-------|-----|
| SIGSEGV on startup | uSockets not built with GCD | Rebuild: `cd nim_usockets/usockets && WITH_GCD=1 make` |
| SIGSEGV on startup | Missing CoreFoundation link | Add `--passL:"-framework CoreFoundation"` |
| `runThreaded` only uses 1 thread | GCD limitation | Expected behavior; use nginx for scaling |
| `runCluster` only uses 1 worker | SO_REUSEPORT limitation on macOS | Expected behavior; use nginx for scaling |
| High latency spikes | Low QoS scheduling | Set `NIM_EXPRESS_MACOS_HIGH_QOS=true` |

### Monitoring

The framework exposes operational metrics via `optimizationMetricsJson()`:

```nim
app.get "/metrics", proc(req: Request, res: Response) =
  res.json(app.optimizationMetricsJson())
```

Returns parser errors, overload rejects, write retries, backpressure drops, connection counts, WebSocket counts, in-flight async request counts, and page pool statistics.

## Built-in HTTP client

For outbound requests from handlers, use the integrated connection-pooled HTTP client:

```nim
let client = app.createHttpClient("api",
  maxConnsPerHost = 16,
  requestTimeoutMs = 5000,
  connectTimeoutMs = 2000,
  keepAliveTimeoutMs = 60000
)
```

The client initializes with the server's event loop at startup, avoiding thread-safety issues.

## Plugin system

Register plugins with dependency ordering and lifecycle hooks:

```nim
discard app.registerPlugin(pluginDef(
  id = "database",
  initHook = proc(): bool =
    echo "Database connected"
    true,
  shutdownHook = proc() =
    echo "Database disconnected"
))
```

Plugins initialize in topological dependency order at startup and shut down in reverse order. Plugins must be registered before `listen()` is called.

## License

MIT
