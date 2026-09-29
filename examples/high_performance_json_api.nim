# Build (from nim_uwebsocket root):
# nim c -d:release -d:lto --panics:off --threads:on --opt:speed -o:examples/bin/high_performance_json_api examples/high_performance_json_api.nim

import std/[os, strutils, times, atomics, tables, cpuinfo]
import ../nim_express/src/nim_express
import ../nim_utils/src/nim_utils/nim_fastjson/direct_engine

const
  DefaultPort = 8080
  DefaultWorkers = 0
  RateLimitWindow = 60
  RateLimitMaxRequests = 1000

proc parseEnvIntOr(key: string, default: int): int =
  let raw = getEnv(key, "")
  if raw.len == 0: return default
  try: parseInt(raw)
  except ValueError: default

type
  UserDto = object
    id: int
    name {.jsonSafe.}: string
    email: string
    active: bool

  CreateUserRequest = object
    name: string
    email: string

  ApiResponse[T] = object
    success: bool
    data: T

  ErrorResponse = object
    success: bool
    error {.jsonSafe.}: string
    code: int

  HealthResponse = object
    status {.jsonSafe.}: string
    uptime_seconds: int
    version {.jsonSafe.}: string

  MetricsResponse = object
    uptime_seconds: int
    total_requests: int64
    active_connections: int64
    overload_rejects: int64
    parser_errors: int64
    write_retries: int64
    backpressure_drops: int64
    rate_limit_rejects: int64

  RateLimitEntry = object
    count: int
    windowStart: int64

var processStartTime: float
var requestCounter: Atomic[int64]
var rateLimitRejects: Atomic[int64]

when defined(singleThread) or defined(contextpool_single_thread):
  var jsonBuf: string
  var rateLimitTable: Table[string, RateLimitEntry]
else:
  var jsonBuf {.threadvar.}: string
  var rateLimitTable {.threadvar.}: Table[string, RateLimitEntry]

proc initThreadLocals() =
  jsonBuf = newStringOfCap(8192)
  rateLimitTable = initTable[string, RateLimitEntry]()

proc checkRateLimit(clientIp: string): bool =
  let now = getTime().toUnix()
  if rateLimitTable.hasKey(clientIp):
    var entry = rateLimitTable[clientIp]
    if now - entry.windowStart >= RateLimitWindow:
      entry.count = 1
      entry.windowStart = now
      rateLimitTable[clientIp] = entry
      return true
    if entry.count >= RateLimitMaxRequests:
      return false
    entry.count += 1
    rateLimitTable[clientIp] = entry
    return true
  rateLimitTable[clientIp] = RateLimitEntry(count: 1, windowStart: now)
  true

proc rateLimitMiddleware(): AsyncMiddleware =
  result = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
    req.bindHeaders()
    let clientIp = req.headers.getOrDefault("x-forwarded-for", "unknown")
    if not checkRateLimit(clientIp):
      discard rateLimitRejects.fetchAdd(1, moRelaxed)
      res.native.applyStatusCode(429)
      res.native.setHeader("retry-after", "60")
      let errResp = ErrorResponse(success: false, error: "rate limit exceeded", code: 429)
      serializeDirectInto(jsonBuf, errResp)
      res.native.json(jsonBuf)
      return
    await next()

proc circuitBreakerWrap(cb: CircuitBreaker): AsyncMiddleware =
  circuitBreakerMiddleware(cb)

proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()

  app.server.options.maxConnections = 65536
  app.server.options.maxBodySize = 8 * 1024 * 1024
  app.server.options.connectionTimeout = 120
  app.server.options.gracefulShutdown = true
  app.server.options.gracefulShutdownDrainMs = 15000

  app.server.options.socketNoDelay = true
  app.server.options.socketKeepAlive = true
  app.server.options.socketKeepAliveSeconds = 60
  app.server.options.socketFastOpen = true
  app.server.options.socketSendBufferBytes = 256 * 1024
  app.server.options.socketRecvBufferBytes = 128 * 1024
  app.server.options.socketDeferAcceptSeconds = 5
  app.server.options.socketNotSentLowWaterBytes = 16384

  app.server.options.listenExclusivePort = false
  app.server.options.listenEpollExclusive = true

  app.server.options.writeCoalesceMode = wcmAdaptive
  app.server.options.writeCoalesceMaxBytes = 1024 * 1024
  app.server.options.writeCoalesceMaxResponses = 256

  app.server.options.overloadMaxLoopBacklogBytes = 64 * 1024 * 1024
  app.server.options.overloadMaxPendingResponses = 16384
  app.server.options.overloadCloseOnReject = false
  app.server.options.overloadAdaptiveEnabled = true

  app.server.options.headerReadTimeoutMs = 10000
  app.server.options.bodyReadTimeoutMs = 30000

  app.server.options.readBufferMinCapacity = 8192
  app.server.options.readBufferMaxCapacity = 256 * 1024

  setRequestResponsePoolingEnabled(true)
  setContextPoolMax(8192)

  let upstreamCircuitBreaker = newCircuitBreaker(
    name = "upstream",
    failureThreshold = 5,
    successThreshold = 2,
    timeoutMs = 30000
  )

  app.use(panicRecovery())
  app.use(jsonLogger(JsonLoggerOptions(
    sink: proc(line: string) {.closure.} = echo(line),
    includeFields: {jlfTimestamp, jlfMethod, jlfPath, jlfStatus, jlfDurationMs, jlfRequestId},
    skipPaths: @["/health", "/healthz", "/ready", "/livez"],
    skipHealthChecks: true
  )))
  app.use(rateLimitMiddleware())

  let api = app.group("/api", circuitBreakerWrap(upstreamCircuitBreaker))

  app.get "/health", proc(req: Request, res: Response) =
    let resp = HealthResponse(
      status: "ok",
      uptime_seconds: int(epochTime() - processStartTime),
      version: "1.0.0"
    )
    serializeDirectInto(jsonBuf, resp)
    res.native.json(jsonBuf)

  app.get "/ready", proc(req: Request, res: Response) =
    res.native.json("""{"ready":true}""")

  app.get "/livez", proc(req: Request, res: Response) =
    res.native.json("""{"alive":true}""")

  app.get "/metrics", proc(req: Request, res: Response) =
    let resp = MetricsResponse(
      uptime_seconds: int(epochTime() - processStartTime),
      total_requests: requestCounter.load(moRelaxed),
      active_connections: app.server.getConnectionCount().int64,
      overload_rejects: app.overloadRejectCount(),
      parser_errors: app.parserErrorCount(),
      write_retries: app.writeRetryCount(),
      backpressure_drops: app.backpressureDropCount(),
      rate_limit_rejects: rateLimitRejects.load(moRelaxed)
    )
    serializeDirectInto(jsonBuf, resp)
    res.native.json(jsonBuf)

  api.get "/users", proc(req: Request, res: Response) =
    discard requestCounter.fetchAdd(1, moRelaxed)
    let users = @[
      UserDto(id: 1, name: "Alice", email: "alice@example.com", active: true),
      UserDto(id: 2, name: "Bob", email: "bob@example.com", active: true),
      UserDto(id: 3, name: "Charlie", email: "charlie@example.com", active: false)
    ]
    let resp = ApiResponse[seq[UserDto]](success: true, data: users)
    serializeDirectInto(jsonBuf, resp)
    res.native.json(jsonBuf)

  api.get "/users/:id", proc(req: Request, res: Response) =
    discard requestCounter.fetchAdd(1, moRelaxed)
    let idStr = req.params.getOrDefault("id", "0")
    var id: int
    try:
      id = parseInt(idStr)
    except ValueError:
      res.native.setStatus(Http400)
      let errResp = ErrorResponse(success: false, error: "invalid user id", code: 400)
      serializeDirectInto(jsonBuf, errResp)
      res.native.json(jsonBuf)
      return
    let user = UserDto(id: id, name: "User" & $id, email: "user" & $id & "@example.com", active: true)
    let resp = ApiResponse[UserDto](success: true, data: user)
    serializeDirectInto(jsonBuf, resp)
    res.native.json(jsonBuf)

  api.post "/users", proc(req: Request, res: Response) =
    discard requestCounter.fetchAdd(1, moRelaxed)
    let body = req.rawBody()
    if body.len == 0:
      res.native.setStatus(Http400)
      let errResp = ErrorResponse(success: false, error: "request body required", code: 400)
      serializeDirectInto(jsonBuf, errResp)
      res.native.json(jsonBuf)
      return
    var createReq: CreateUserRequest
    try:
      createReq = deserializeDirect(body, CreateUserRequest)
    except direct_engine.JsonError:
      res.native.setStatus(Http400)
      let errResp = ErrorResponse(success: false, error: "invalid JSON", code: 400)
      serializeDirectInto(jsonBuf, errResp)
      res.native.json(jsonBuf)
      return
    if createReq.name.len == 0 or createReq.email.len == 0:
      res.native.setStatus(Http400)
      let errResp = ErrorResponse(success: false, error: "name and email required", code: 400)
      serializeDirectInto(jsonBuf, errResp)
      res.native.json(jsonBuf)
      return
    let user = UserDto(id: 42, name: createReq.name, email: createReq.email, active: true)
    let resp = ApiResponse[UserDto](success: true, data: user)
    res.native.setStatus(Http201)
    serializeDirectInto(jsonBuf, resp)
    res.native.json(jsonBuf)

  api.get "/echo", proc(req: Request, res: Response) =
    discard requestCounter.fetchAdd(1, moRelaxed)
    req.bindQuery()
    let msg = req.query.getOrDefault("msg", "hello")
    res.native.json("{\"echo\":\"" & msg & "\"}")

  app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
    let errResp = ErrorResponse(success: false, error: "internal server error", code: 500)
    res.native.setStatus(Http500)
    serializeDirectInto(jsonBuf, errResp)
    res.native.json(jsonBuf)

  app.onStartup proc(ctx: ExpressApp) =
    processStartTime = epochTime()
    requestCounter.store(0, moRelaxed)
    rateLimitRejects.store(0, moRelaxed)
    initThreadLocals()
    prewarmContextPools(1024, 1024)

  app

when isMainModule:
  let port = parseEnvIntOr("PORT", DefaultPort)
  let workers = parseEnvIntOr("WORKERS", DefaultWorkers)

  echo "=== nim_express High-Performance JSON API ==="
  echo "Port: ", port
  echo "Workers: ", if workers == 0: $(countProcessors()) & " (auto)" else: $workers
  echo "JSON engine: nim_fastjson (SIMD-accelerated)"
  echo "Rate limit: ", RateLimitMaxRequests, " req/", RateLimitWindow, "s per IP"
  echo "Circuit breaker: upstream (threshold=5, recovery=2)"
  echo ""
  echo "Endpoints:"
  echo "  GET  /health     - Health check"
  echo "  GET  /ready      - Readiness probe"
  echo "  GET  /livez      - Liveness probe"
  echo "  GET  /metrics    - Server metrics"
  echo "  GET  /api/users  - List users"
  echo "  GET  /api/users/:id - Get user by ID"
  echo "  POST /api/users  - Create user"
  echo "  GET  /api/echo   - Echo query param"
  echo ""

  runCluster(createApp, port, workers)
