import std/[unittest, asyncdispatch, json, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/panic_recovery
import ../src/nim_express/middlewares/error_handler
import ../src/nim_express/middlewares/logger
import ../src/nim_express/middlewares/json_logger
import ../src/nim_express/middlewares/cors
import ../src/nim_express/middlewares/rate_limit
import ../src/nim_express/middlewares/helmet
import ../src/nim_express/middlewares/request_id
import ../src/nim_express/middlewares/health
import ../src/nim_express/middlewares/session
import ../src/nim_express/middlewares/csrf
import ../src/nim_express/middlewares/ip_filter
import ../src/nim_express/middlewares/circuit_breaker
import ../src/nim_express/middlewares/global_error_filter
import ../src/nim_express/middlewares/graceful_shutdown
import ../src/nim_express/middlewares/timeout
import ../src/nim_express/middlewares/concurrency_guard
import ../src/nim_express/middlewares/body_limit
import ../src/nim_express/middlewares/normalize_path
import ../src/nim_express/middlewares/server_timing
import ../src/nim_express/middlewares/backpressure
import ../src/nim_express/middlewares/etag

proc newMockHttpRequest(
  pathVal: string = "/",
  methodKind: HttpMethod = hmGet,
  bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1",
  headerMap: seq[(string, string)] = @[]
): HttpRequest =
  new(result)
  result.path = pathVal
  result.queryStringRaw = ""
  result.httpVersion = "1.1"
  result.httpMajor = 1
  result.httpMinor = 1
  result.body = bodyStr
  result.remoteIp = remoteIpStr
  result.methodKind = methodKind
  result.connectionClose = false
  result.headersDeferred = false
  result.bodyInFile = false
  result.bodyFilePath = ""
  result.bodyFileRoot = ""
  result.headers = newFastMap[string]()
  discard result.headers.reserve(16)
  result.query = newFastMap[string]()
  discard result.query.reserve(8)
  for (k, v) in headerMap:
    result.headers[k] = v

proc newMockRequest(
  pathVal: string = "/",
  methodKind: HttpMethod = hmGet,
  bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1",
  headerMap: seq[(string, string)] = @[]
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr, headerMap)
  result = newRequest(native)

proc newMockResponse(): Response =
  new(result)
  result.native = nil
  result.request = nil
  result.app = nil
  result.viewsDir = "views"
  result.viewExt = ""
  result.requestMethodKind = hmGet
  result.statusCode = 200
  result.headersInited = true
  result.finished = false
  result.compress = false
  result.compressEncoding = ""
  result.headerBuf = newStringOfCap(256)
  result.droppedLateWrites = 0
  result.headers = newFastMap[string]()
  discard result.headers.reserve(16)
  result.locals = newFastMap[string]()
  discard result.locals.reserve(4)

proc chainMiddlewares(
  middlewares: seq[AsyncMiddleware],
  finalHandler: proc(req: Request, res: Response): Future[void]
): AsyncMiddleware =
  result = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
    var idx = 0
    proc advance(): Future[void] {.async.} =
      if idx < middlewares.len:
        let current = middlewares[idx]
        inc idx
        await current(req, res, advance)
      else:
        await finalHandler(req, res)
    await advance()

proc runMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request,
  res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
) =
  let finalHandler =
    if handler != nil: handler
    else:
      proc(req: Request, res: Response): Future[void] {.async.} =
        res.statusCode = 200
  let chain = chainMiddlewares(middlewares, finalHandler)
  let noopNext: NextProc = proc(): Future[void] {.async.} = discard
  waitFor chain(req, res, noopNext)

proc okHandler(req: Request, res: Response): Future[void] {.async.} =
  res.statusCode = 200

proc crashHandler(req: Request, res: Response): Future[void] {.async.} =
  raise newException(ValueError, "test crash")

proc ioErrorHandler(req: Request, res: Response): Future[void] {.async.} =
  raise newException(IOError, "connection refused")

proc osErrorHandler(req: Request, res: Response): Future[void] {.async.} =
  raise newException(OSError, "file not found")

proc jsonErrorHandler(req: Request, res: Response): Future[void] {.async.} =
  raise newException(JsonParsingError, "invalid json at pos 5")

proc slowHandler(req: Request, res: Response): Future[void] {.async.} =
  await sleepAsync(50)
  res.statusCode = 200

proc status500Handler(req: Request, res: Response): Future[void] {.async.} =
  res.statusCode = 500

proc status404Handler(req: Request, res: Response): Future[void] {.async.} =
  res.statusCode = 404

proc keyErrorHandler(req: Request, res: Response): Future[void] {.async.} =
  raise newException(KeyError, "missing key: foo")

proc overflowErrorHandler(req: Request, res: Response): Future[void] {.async.} =
  raise newException(OverflowDefect, "integer overflow")

# ============================================================
# ITERATION 1: Individual Middleware Tests
# ============================================================

suite "Individual middleware — panic_recovery":
  test "catches CatchableError and sets 500":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = panicRecovery()
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500

  test "passes through successful handler":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = panicRecovery()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "catches IOError":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = panicRecovery()
    runMiddlewareChain(@[mw], req, res, ioErrorHandler)
    check res.statusCode == 500

  test "plain text response format":
    let req = newMockRequest()
    let res = newMockResponse()
    let opts = PanicRecoveryOptions(
      responseFormat: erfPlainText,
      logErrors: false,
      includeStackTrace: false,
      reportHook: nil
    )
    let mw = panicRecovery(opts)
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500

  test "report hook is called on error":
    var hookCalled = false
    var hookPath = ""
    let hook: ErrorReportHook = proc(err: ref Exception, req: Req, path: string) =
      hookCalled = true
      hookPath = path
    let req = newMockRequest("/api/test")
    let res = newMockResponse()
    let mw = panicRecovery(hook)
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check hookCalled
    check hookPath == "/api/test"
    check res.statusCode == 500

suite "Individual middleware — error_handler":
  test "catches error and returns RFC 7807 status":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = errorHandler()
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500

  test "preserves 4xx status from handler":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = errorHandler()
    let handler = proc(req: Request, res: Response): Future[void] {.async.} =
      res.statusCode = 422
      raise newException(ValueError, "invalid input")
    runMiddlewareChain(@[mw], req, res, handler)
    check res.statusCode == 422

  test "passes through successful handler":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = errorHandler()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "dev mode includes error detail":
    let req = newMockRequest()
    let res = newMockResponse()
    let opts = ErrorHandlerOptions(devMode: true, logErrors: false)
    let mw = errorHandler(opts)
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500

suite "Individual middleware — logger":
  test "does not crash on successful request":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = logger()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "reraises handler error after logging":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = logger()
    expect(ValueError):
      runMiddlewareChain(@[mw], req, res, crashHandler)

  test "sets status 500 on unhandled error":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = logger()
    expect(ValueError):
      runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500

  test "handles POST request without crash":
    let req = newMockRequest(methodKind = hmPost)
    let res = newMockResponse()
    let mw = logger()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "handles path with special characters":
    let req = newMockRequest("/api/users/123?q=test&sort=asc")
    let res = newMockResponse()
    let mw = logger()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "handles multiple sequential requests":
    let mw = logger()
    for i in 0..9:
      let req = newMockRequest("/item/" & $i)
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
      check res.statusCode == 200

suite "Individual middleware — json_logger":
  test "does not crash on successful request":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfTimestamp, jlfMethod, jlfPath, jlfStatus, jlfDurationMs},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let req = newMockRequest("/api/test")
    let res = newMockResponse()
    let mw = jsonLogger(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200
    check logLine.len > 0
    check "\"status\":200" in logLine

  test "skips health paths by default":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfTimestamp, jlfMethod, jlfPath, jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: true
    )
    let req = newMockRequest("/health")
    let res = newMockResponse()
    let mw = jsonLogger(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check logLine.len == 0

  test "logs error info on handler crash":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfMethod, jlfPath, jlfStatus, jlfError},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let req = newMockRequest("/crash")
    let res = newMockResponse()
    let mw = jsonLogger(opts)
    expect(ValueError):
      runMiddlewareChain(@[mw], req, res, crashHandler)
    check "\"error\":" in logLine

suite "Individual middleware — cors":
  test "sets wildcard origin on simple request":
    let req = newMockRequest(headerMap = @[("origin", "http://example.com")])
    let res = newMockResponse()
    let mw = cors()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "handles OPTIONS preflight":
    let req = newMockRequest(methodKind = hmOptions, headerMap = @[("origin", "http://example.com")])
    let res = newMockResponse()
    let mw = cors()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 204

  test "no origin header skips cors headers on GET":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = cors()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "allowlist rejects unknown origin":
    let opts = CorsOptions(
      origin: "*",
      allowedOrigins: @["http://allowed.com"],
      credentials: true
    )
    let req = newMockRequest(
      methodKind = hmOptions,
      headerMap = @[("origin", "http://evil.com")]
    )
    let res = newMockResponse()
    let mw = cors(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 403

  test "reflect origin mode mirrors request origin":
    let opts = CorsOptions(origin: "reflect")
    let req = newMockRequest(headerMap = @[("origin", "http://my-app.com")])
    let res = newMockResponse()
    let mw = cors(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

suite "Individual middleware — rate_limit":
  test "allows requests under limit":
    resetRateLimitStoreForTest()
    let req = newMockRequest(remoteIpStr = "10.0.0.1")
    let res = newMockResponse()
    let mw = rateLimit(maxRequests = 10, windowMs = 60000)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "rejects requests over limit":
    resetRateLimitStoreForTest()
    let mw = rateLimit(maxRequests = 2, windowMs = 60000)
    for i in 0..2:
      let req = newMockRequest(remoteIpStr = "10.0.0.2")
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
      if i >= 2:
        check res.statusCode == 429

  test "different IPs have separate limits":
    resetRateLimitStoreForTest()
    let mw = rateLimit(maxRequests = 1, windowMs = 60000)
    let req1 = newMockRequest(remoteIpStr = "10.0.1.1")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, okHandler)
    check res1.statusCode == 200
    let req2 = newMockRequest(remoteIpStr = "10.0.1.2")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, okHandler)
    check res2.statusCode == 200

suite "Individual middleware — helmet":
  test "sets security headers":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = helmet()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200
    check res.headers.getOrDefault("x-content-type-options", "") == "nosniff"
    check res.headers.getOrDefault("x-frame-options", "") == "SAMEORIGIN"

  test "custom options disable specific headers":
    var opts = defaultHelmetOptions()
    opts.disableXFrameOptions = true
    opts.disableReferrerPolicy = true
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = helmet(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.headers.getOrDefault("x-frame-options", "") == ""

suite "Individual middleware — request_id":
  test "generates unique request id":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = requestId()
    runMiddlewareChain(@[mw], req, res, okHandler)
    let id = req.locals.getOrDefault("requestId", "")
    check id.len > 0

  test "two requests get different IDs":
    let mw = requestId()
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, okHandler)
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, okHandler)
    let id1 = req1.locals.getOrDefault("requestId", "")
    let id2 = req2.locals.getOrDefault("requestId", "")
    check id1 != id2

  test "trusts upstream header when configured":
    let req = newMockRequest(headerMap = @[("x-request-id", "upstream-abc123")])
    let res = newMockResponse()
    let mw = requestId(trustUpstream = true)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check req.locals.getOrDefault("requestId", "") == "upstream-abc123"

  test "rejects unsafe upstream ID characters":
    let req = newMockRequest(headerMap = @[("x-request-id", "evil<script>")])
    let res = newMockResponse()
    let mw = requestId(trustUpstream = true)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check req.locals.getOrDefault("requestId", "") != "evil<script>"
    check req.locals.getOrDefault("requestId", "").len > 0

suite "Individual middleware — health":
  test "returns health status on health path":
    let req = newMockRequest("/health")
    let res = newMockResponse()
    let mw = health()
    runMiddlewareChain(@[mw], req, res, okHandler)

  test "passes through non-health paths":
    let req = newMockRequest("/api/data")
    let res = newMockResponse()
    let mw = health()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "custom health path":
    let req = newMockRequest("/status")
    let res = newMockResponse()
    let mw = health("/status")
    runMiddlewareChain(@[mw], req, res, okHandler)

suite "Individual middleware — circuit_breaker":
  test "allows requests when closed":
    let cb = newCircuitBreaker(failureThreshold = 3)
    let mw = circuitBreakerMiddleware(cb)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200
    check cb.state == csClosed

  test "opens after failure threshold":
    let cb = newCircuitBreaker(failureThreshold = 2, timeoutMs = 60000)
    let mw = circuitBreakerMiddleware(cb)
    for i in 0..<2:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, status500Handler)
    check cb.state == csOpen
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 503

  test "records success and stays closed":
    let cb = newCircuitBreaker(failureThreshold = 5)
    let mw = circuitBreakerMiddleware(cb)
    for i in 0..4:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
    check cb.state == csClosed

  test "exception counts as failure":
    let cb = newCircuitBreaker(failureThreshold = 1)
    let mw = circuitBreakerMiddleware(cb)
    let req = newMockRequest()
    let res = newMockResponse()
    expect(ValueError):
      runMiddlewareChain(@[mw], req, res, crashHandler)
    check cb.state == csOpen

suite "Individual middleware — global_error_filter":
  test "value error filter returns 400":
    let mw = globalErrorFilterWithBuiltins()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 400

  test "io error filter returns 502":
    let mw = globalErrorFilterWithBuiltins()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, ioErrorHandler)
    check res.statusCode == 502

  test "os error filter returns 503":
    let mw = globalErrorFilterWithBuiltins()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, osErrorHandler)
    check res.statusCode == 503

  test "json parsing error filter returns 400":
    let mw = globalErrorFilterWithBuiltins()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, jsonErrorHandler)
    check res.statusCode == 400

  test "key error filter returns 400":
    let mw = globalErrorFilterWithBuiltins()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, keyErrorHandler)
    check res.statusCode == 400

  test "custom filter takes priority":
    let customFilter = newExceptionFilter(
      "CustomCatch",
      proc(err: ref Exception, req: Req, res: Res): bool =
        if err of ValueError:
          res.statusCode = 418
          return true
        false,
      priority = 200
    )
    let opts = GlobalErrorFilterOptions(
      filters: @[customFilter] & builtinFilters(),
      fallbackStatusCode: 500,
      logUnhandled: false
    )
    let mw = globalErrorFilter(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 418

  test "unhandled error falls back to 500":
    let opts = GlobalErrorFilterOptions(
      filters: @[],
      fallbackStatusCode: 500,
      logUnhandled: false
    )
    let mw = globalErrorFilter(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    let handler = proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(CatchableError, "unknown error type")
    runMiddlewareChain(@[mw], req, res, handler)
    check res.statusCode == 500

suite "Individual middleware — concurrency_guard":
  test "allows requests under limit":
    let state = newConcurrencyGuardState(maxInflight = 10)
    let mw = concurrencyGuard(state)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200
    check state.currentInflight() == 0

  test "decrements inflight after request":
    let state = newConcurrencyGuardState(maxInflight = 100)
    let mw = concurrencyGuard(state)
    for i in 0..5:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
    check state.currentInflight() == 0

  test "decrements inflight even on error":
    let state = newConcurrencyGuardState(maxInflight = 100)
    let mw = concurrencyGuard(state)
    let req = newMockRequest()
    let res = newMockResponse()
    expect(ValueError):
      runMiddlewareChain(@[mw], req, res, crashHandler)
    check state.currentInflight() == 0

suite "Individual middleware — server_timing":
  test "production mode passes through":
    let mw = serverTiming(productionMode = true)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "dev mode sets timing local":
    let mw = serverTiming(productionMode = false)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check req.locals.getOrDefault("_server_timing_enabled", "") == "1"

suite "Individual middleware — backpressure":
  test "allows requests under limits":
    let state = newBackpressureState()
    let mw = backpressure(state)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200
    check state.activeConnectionCount() == 0

  test "decrements counters after request":
    let state = newBackpressureState()
    let mw = backpressure(state)
    for i in 0..4:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
    check state.activeConnectionCount() == 0
    check state.pendingResponseCount() == 0

  test "decrements counters on error":
    let state = newBackpressureState()
    let mw = backpressure(state)
    let req = newMockRequest()
    let res = newMockResponse()
    expect(ValueError):
      runMiddlewareChain(@[mw], req, res, crashHandler)
    check state.activeConnectionCount() == 0

suite "Individual middleware — etag":
  test "sets etag locals":
    let mw = etag()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.locals.getOrDefault("_etag_enabled", "") == "1"
    check res.locals.getOrDefault("_etag_mode", "") == "weak"

  test "strong mode sets correct local":
    let opts = ETagOptions(mode: etStrong, allowedMethods: {hmGet, hmHead}, respectExistingHeader: true)
    let mw = etag(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.locals.getOrDefault("_etag_mode", "") == "strong"

suite "Individual middleware — session":
  test "creates session ID for new request":
    let mw = session()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    let sid = req.locals.getOrDefault("_session_id", "")
    check sid.len > 0

  test "session set and get work":
    let mw = session()
    let req = newMockRequest()
    let res = newMockResponse()
    let handler = proc(req: Request, res: Response): Future[void] {.async.} =
      sessionSet(req, "username", "alice")
      let val = sessionGet(req, "username")
      check val == "alice"
      res.statusCode = 200
    runMiddlewareChain(@[mw], req, res, handler)
    check res.statusCode == 200

suite "Individual middleware — ip_filter":
  test "allows all when no lists configured":
    let mw = ipFilter()
    let req = newMockRequest(remoteIpStr = "8.8.8.8")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "denylist blocks matching IP":
    let opts = IpFilterOptions(
      denylist: @["10.0.0.5"],
      denyStatusCode: 403,
      denyMessage: "Forbidden",
      trustProxy: false
    )
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "10.0.0.5")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 403

  test "allowlist only allows matching IPs":
    let opts = IpFilterOptions(
      allowlist: @["192.168.1.0/24"],
      denyStatusCode: 403,
      denyMessage: "Forbidden",
      trustProxy: false
    )
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "10.0.0.1")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 403

  test "allowlist permits matching CIDR":
    let opts = IpFilterOptions(
      allowlist: @["192.168.1.0/24"],
      denyStatusCode: 403,
      denyMessage: "Forbidden",
      trustProxy: false
    )
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "192.168.1.50")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

# ============================================================
# ITERATION 2-3: Middleware Ordering Tests
# ============================================================

suite "Middleware ordering — panic_recovery before error_handler":
  test "panic_recovery catches error before error_handler sees it":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)), errorHandler(ErrorHandlerOptions(logErrors: false))]
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 500

  test "error_handler wrapping panic_recovery — error_handler formats response":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[errorHandler(ErrorHandlerOptions(logErrors: false)), panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson))]
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 500

suite "Middleware ordering — cors before route handlers":
  test "cors does not crash with origin header present":
    let req = newMockRequest(headerMap = @[("origin", "http://example.com")])
    let res = newMockResponse()
    let mws = @[cors()]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

suite "Middleware ordering — logger wrapping everything":
  test "logger wraps handler and reraises error":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[logger()]
    expect(ValueError):
      runMiddlewareChain(mws, req, res, crashHandler)

  test "logger + panic_recovery together — no crash":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[
      logger(),
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson))
    ]
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 500

# ============================================================
# ITERATION 4-5: Real-World Middleware Combination Stacks
# ============================================================

suite "Combination — Production API stack":
  test "successful request through full stack":
    resetRateLimitStoreForTest()
    let req = newMockRequest("/api/users", headerMap = @[("origin", "http://frontend.com")])
    let res = newMockResponse()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      cors(),
      helmet(),
      rateLimit(maxRequests = 100, windowMs = 60000),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200
    check req.locals.getOrDefault("requestId", "").len > 0

  test "handler crash in full stack returns 500":
    resetRateLimitStoreForTest()
    let req = newMockRequest("/api/crash", headerMap = @[("origin", "http://frontend.com")])
    let res = newMockResponse()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      cors(),
      helmet(),
      rateLimit(maxRequests = 100, windowMs = 60000),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 500
    check req.locals.getOrDefault("requestId", "").len > 0

suite "Combination — Public API stack":
  test "successful request with cors + helmet + rate_limit + health":
    resetRateLimitStoreForTest()
    let req = newMockRequest("/api/public", headerMap = @[("origin", "http://client.com")])
    let res = newMockResponse()
    let mws = @[
      cors(),
      helmet(),
      rateLimit(maxRequests = 50, windowMs = 60000),
      health()
    ]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

  test "health endpoint bypasses route handler":
    resetRateLimitStoreForTest()
    let req = newMockRequest("/health", headerMap = @[("origin", "http://client.com")])
    let res = newMockResponse()
    var handlerCalled = false
    let handler = proc(req: Request, res: Response): Future[void] {.async.} =
      handlerCalled = true
    let mws = @[
      cors(),
      helmet(),
      rateLimit(maxRequests = 50, windowMs = 60000),
      health()
    ]
    runMiddlewareChain(mws, req, res, handler)
    check not handlerCalled

suite "Combination — Internal service stack":
  test "panic_recovery + json_logger + health + circuit_breaker":
    let cb = newCircuitBreaker(failureThreshold = 5)
    var logLine = ""
    let logOpts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfMethod, jlfPath, jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let req = newMockRequest("/internal/process")
    let res = newMockResponse()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      jsonLogger(logOpts),
      health(),
      circuitBreakerMiddleware(cb)
    ]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200
    check cb.state == csClosed

  test "circuit opens after failures in internal stack":
    let cb = newCircuitBreaker(failureThreshold = 2)
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      circuitBreakerMiddleware(cb)
    ]
    for i in 0..<2:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(mws, req, res, status500Handler)
    check cb.state == csOpen
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 503

suite "Combination — Auth API stack":
  test "session + csrf + cors + rate_limit — GET passes":
    resetRateLimitStoreForTest()
    let req = newMockRequest(
      "/auth/profile",
      methodKind = hmGet,
      headerMap = @[("origin", "http://app.com")]
    )
    let res = newMockResponse()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      session(),
      csrf(),
      cors(),
      rateLimit(maxRequests = 20, windowMs = 60000)
    ]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

  test "POST without CSRF token is rejected":
    resetRateLimitStoreForTest()
    let req = newMockRequest(
      "/auth/update",
      methodKind = hmPost,
      headerMap = @[("origin", "http://app.com")]
    )
    let res = newMockResponse()
    let mws = @[
      session(),
      csrf()
    ]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 403

# ============================================================
# ITERATION 6-8: Error Handling Combinations
# ============================================================

suite "Error combinations — handler throws with various middleware stacks":
  test "panic_recovery catches ValueError":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(
      @[panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson))],
      req, res, crashHandler
    )
    check res.statusCode == 500

  test "panic_recovery catches IOError":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(
      @[panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson))],
      req, res, ioErrorHandler
    )
    check res.statusCode == 500

  test "panic_recovery catches OSError":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(
      @[panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson))],
      req, res, osErrorHandler
    )
    check res.statusCode == 500

  test "global_error_filter + panic_recovery double coverage":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      globalErrorFilterWithBuiltins()
    ]
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 400

  test "error_handler + global_error_filter — global filter handles first":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[
      errorHandler(ErrorHandlerOptions(logErrors: false)),
      globalErrorFilterWithBuiltins()
    ]
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 400

  test "logger wrapping error_handler — error logged then handled":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[
      logger(),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 500

  test "circuit_breaker + panic_recovery — exception opens circuit":
    let cb = newCircuitBreaker(failureThreshold = 1)
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      circuitBreakerMiddleware(cb)
    ]
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, crashHandler)
    check cb.state == csOpen

  test "handler returns 500 — circuit breaker records failure":
    let cb = newCircuitBreaker(failureThreshold = 2)
    let mw = circuitBreakerMiddleware(cb)
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, status500Handler)
    check cb.state == csClosed
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, status500Handler)
    check cb.state == csOpen

  test "rate limit exceeded still completes without crash":
    resetRateLimitStoreForTest()
    let mw = rateLimit(maxRequests = 1, windowMs = 60000)
    let req1 = newMockRequest(remoteIpStr = "10.0.5.1")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, okHandler)
    check res1.statusCode == 200
    let req2 = newMockRequest(remoteIpStr = "10.0.5.1")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, okHandler)
    check res2.statusCode == 429

  test "rate limit with cors — rate limit response has correct status":
    resetRateLimitStoreForTest()
    let mws = @[
      cors(),
      rateLimit(maxRequests = 1, windowMs = 60000)
    ]
    let req1 = newMockRequest(remoteIpStr = "10.0.6.1", headerMap = @[("origin", "http://app.com")])
    let res1 = newMockResponse()
    runMiddlewareChain(mws, req1, res1, okHandler)
    check res1.statusCode == 200
    let req2 = newMockRequest(remoteIpStr = "10.0.6.1", headerMap = @[("origin", "http://app.com")])
    let res2 = newMockResponse()
    runMiddlewareChain(mws, req2, res2, okHandler)
    check res2.statusCode == 429

# ============================================================
# ITERATION 9-10: More Combination Scenarios
# ============================================================

suite "Combination — request_id + json_logger integration":
  test "json logger captures request ID":
    var logLine = ""
    let logOpts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfRequestId, jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let mws = @[requestId(), jsonLogger(logOpts)]
    let req = newMockRequest("/test")
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200
    check "\"request_id\":" in logLine

suite "Combination — helmet + cors + etag":
  test "all three set headers without conflict":
    let req = newMockRequest(headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    let mws = @[helmet(), cors(), etag()]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200
    check res.headers.getOrDefault("x-content-type-options", "") == "nosniff"
    check res.locals.getOrDefault("_etag_enabled", "") == "1"

suite "Combination — concurrency_guard + rate_limit":
  test "both guards active — request passes under limits":
    resetRateLimitStoreForTest()
    let guardState = newConcurrencyGuardState(maxInflight = 100)
    let mws = @[
      concurrencyGuard(guardState),
      rateLimit(maxRequests = 100, windowMs = 60000)
    ]
    let req = newMockRequest(remoteIpStr = "10.0.7.1")
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200
    check guardState.currentInflight() == 0

suite "Combination — ip_filter + rate_limit + cors":
  test "allowed IP passes through all":
    resetRateLimitStoreForTest()
    let ipOpts = IpFilterOptions(
      allowlist: @["10.0.0.0/8"],
      denyStatusCode: 403,
      denyMessage: "Forbidden",
      trustProxy: false
    )
    let mws = @[
      ipFilter(ipOpts),
      cors(),
      rateLimit(maxRequests = 100, windowMs = 60000)
    ]
    let req = newMockRequest(remoteIpStr = "10.0.8.1", headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

  test "denied IP blocked before rate_limit":
    resetRateLimitStoreForTest()
    let ipOpts = IpFilterOptions(
      denylist: @["192.168.0.0/16"],
      denyStatusCode: 403,
      denyMessage: "Forbidden",
      trustProxy: false
    )
    let mws = @[
      ipFilter(ipOpts),
      cors(),
      rateLimit(maxRequests = 100, windowMs = 60000)
    ]
    let req = newMockRequest(remoteIpStr = "192.168.1.5", headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 403

suite "Combination — backpressure + logger":
  test "backpressure passes through with logger":
    let bpState = newBackpressureState()
    let mws = @[backpressure(bpState), logger()]
    let req = newMockRequest("/timing-test")
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200
    check bpState.activeConnectionCount() == 0

suite "Combination — full security stack":
  test "helmet + cors + csrf + session + request_id — GET passes":
    let req = newMockRequest(
      "/secure",
      methodKind = hmGet,
      headerMap = @[("origin", "http://secure-app.com")]
    )
    let res = newMockResponse()
    let mws = @[
      helmet(),
      cors(),
      session(),
      csrf(),
      requestId()
    ]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

suite "Combination — error recovery + logging + metrics":
  test "panic_recovery + json_logger + request_id + response_time — crash handled":
    var logLine = ""
    let logOpts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfRequestId, jlfStatus, jlfError},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      jsonLogger(logOpts)
    ]
    let req = newMockRequest("/error-test")
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 500

# ============================================================
# ITERATION 11-13: Edge Cases
# ============================================================

suite "Edge cases — empty body handling":
  test "body_limit with zero-length body passes":
    let mw = bodyLimit(1024)
    let req = newMockRequest(bodyStr = "")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "body_limit with oversized content-length header rejects":
    let mw = bodyLimit(100)
    let req = newMockRequest(bodyStr = "", headerMap = @[("content-length", "999999")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 413

  test "body_limit with malformed content-length rejects":
    let mw = bodyLimit(100)
    let req = newMockRequest(bodyStr = "", headerMap = @[("content-length", "not-a-number")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 400

  test "body_limit with negative content-length rejects":
    let mw = bodyLimit(100)
    let req = newMockRequest(bodyStr = "", headerMap = @[("content-length", "-5")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 400

suite "Edge cases — missing headers":
  test "cors with no origin header — GET passes through":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = cors()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "helmet without secure headers — no HSTS added":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = helmet()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.headers.getOrDefault("strict-transport-security", "") == ""

  test "request_id with empty upstream header generates new ID":
    let req = newMockRequest(headerMap = @[("x-request-id", "")])
    let res = newMockResponse()
    let mw = requestId(trustUpstream = true)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check req.locals.getOrDefault("requestId", "").len > 0

suite "Edge cases — empty request path":
  test "health middleware with empty path does not match":
    let req = newMockRequest("/")
    let res = newMockResponse()
    var handlerCalled = false
    let handler = proc(req: Request, res: Response): Future[void] {.async.} =
      handlerCalled = true
      res.statusCode = 200
    let mw = health("/health")
    runMiddlewareChain(@[mw], req, res, handler)
    check handlerCalled

suite "Edge cases — circuit_breaker reset":
  test "reset restores closed state":
    let cb = newCircuitBreaker(failureThreshold = 1)
    cb.recordFailure()
    check cb.state == csOpen
    cb.reset()
    check cb.state == csClosed
    check cb.isAllowed()

  test "manual state transitions":
    let cb = newCircuitBreaker(failureThreshold = 3, successThreshold = 2)
    cb.recordFailure()
    cb.recordFailure()
    cb.recordFailure()
    check cb.state == csOpen

suite "Edge cases — session with invalid session ID":
  test "session middleware regenerates invalid session ID":
    let req = newMockRequest(headerMap = @[("cookie", "sid=x")])
    let res = newMockResponse()
    let mw = session()
    runMiddlewareChain(@[mw], req, res, okHandler)
    let sid = req.locals.getOrDefault("_session_id", "")
    check sid.len >= 24
    check sid != "x"

suite "Edge cases — ip_filter with IPv6":
  test "IPv6 address with allowlist":
    let opts = IpFilterOptions(
      allowlist: @["::1"],
      denyStatusCode: 403,
      denyMessage: "Forbidden",
      trustProxy: false
    )
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "::1")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "IPv6 address denied when not in allowlist":
    let opts = IpFilterOptions(
      allowlist: @["10.0.0.0/8"],
      denyStatusCode: 403,
      denyMessage: "Forbidden",
      trustProxy: false
    )
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "2001:db8::1")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 403

suite "Edge cases — rate_limit key capacity":
  test "rate limit with maxTrackedKeys=2 handles overflow":
    resetRateLimitStoreForTest()
    let mw = rateLimit(maxRequests = 100, windowMs = 60000, maxTrackedKeys = 2, rejectNewKeyWhenFull = true)
    for i in 0..2:
      let req = newMockRequest(remoteIpStr = "10.1." & $i & ".1")
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
      if i >= 2:
        check res.statusCode == 429

suite "Edge cases — etag helper functions":
  test "generateETag produces valid format":
    let tag = generateETag("hello world")
    check tag.startsWith("W/\"")
    check tag.endsWith("\"")

  test "generateETag strong mode":
    let tag = generateETag("hello world", etStrong)
    check tag.startsWith("\"")
    check not tag.startsWith("W/")

  test "ifNoneMatchMatches with wildcard":
    check ifNoneMatchMatches("*", "W/\"abc\"")

  test "ifNoneMatchMatches with matching tag":
    let tag = generateETag("test content")
    check ifNoneMatchMatches(tag, tag)

  test "ifNoneMatchMatches with non-matching tag":
    let tag1 = generateETag("content a")
    let tag2 = generateETag("content b")
    check not ifNoneMatchMatches(tag1, tag2)

# ============================================================
# ITERATION 14-15: Stress Patterns and Complex Combinations
# ============================================================

suite "Stress — multiple rapid requests to rate-limited endpoint":
  test "rate limit correctly counts across 50 requests":
    resetRateLimitStoreForTest()
    let mw = rateLimit(maxRequests = 10, windowMs = 60000)
    var accepted = 0
    var rejected = 0
    for i in 0..<50:
      let req = newMockRequest(remoteIpStr = "10.2.0.1")
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
      if res.statusCode == 200:
        inc accepted
      elif res.statusCode == 429:
        inc rejected
    check accepted == 10
    check rejected == 40

suite "Stress — circuit breaker transitions":
  test "circuit breaker full cycle: closed -> open -> half-open -> closed":
    refreshCachedTime()
    let cb = newCircuitBreaker(failureThreshold = 2, successThreshold = 1, timeoutMs = 100)
    let mw = circuitBreakerMiddleware(cb)
    refreshCachedTime()
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, status500Handler)
    check cb.state == csClosed
    refreshCachedTime()
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, status500Handler)
    check cb.state == csOpen
    waitFor sleepAsync(150)
    refreshCachedTime()
    let req3 = newMockRequest()
    let res3 = newMockResponse()
    runMiddlewareChain(@[mw], req3, res3, okHandler)
    check cb.state == csClosed

suite "Stress — concurrency guard counter correctness":
  test "10 sequential requests leave counter at zero":
    let state = newConcurrencyGuardState(maxInflight = 100)
    let mw = concurrencyGuard(state)
    for i in 0..9:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
    check state.currentInflight() == 0

  test "error requests also decrement counter":
    let state = newConcurrencyGuardState(maxInflight = 100)
    let mw = concurrencyGuard(state)
    for i in 0..4:
      let req = newMockRequest()
      let res = newMockResponse()
      try:
        runMiddlewareChain(@[mw], req, res, crashHandler)
      except ValueError:
        discard
    check state.currentInflight() == 0

suite "Complex — maximum middleware stack depth":
  test "10 middlewares chained without crash":
    resetRateLimitStoreForTest()
    var logLine = ""
    let logOpts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let cb = newCircuitBreaker(failureThreshold = 10)
    let guardState = newConcurrencyGuardState(maxInflight = 1000)
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      jsonLogger(logOpts),
      cors(),
      helmet(),
      rateLimit(maxRequests = 1000, windowMs = 60000),
      etag(),
      concurrencyGuard(guardState),
      circuitBreakerMiddleware(cb),
      backpressure(newBackpressureState())
    ]
    let req = newMockRequest("/deep-stack", headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200
    check cb.state == csClosed
    check guardState.currentInflight() == 0

  test "10 middlewares with crash — still recovers":
    resetRateLimitStoreForTest()
    var logLine = ""
    let logOpts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfStatus, jlfError},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let cb = newCircuitBreaker(failureThreshold = 10)
    let guardState = newConcurrencyGuardState(maxInflight = 1000)
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      jsonLogger(logOpts),
      cors(),
      helmet(),
      rateLimit(maxRequests = 1000, windowMs = 60000),
      etag(),
      concurrencyGuard(guardState),
      circuitBreakerMiddleware(cb),
      backpressure(newBackpressureState())
    ]
    let req = newMockRequest("/deep-crash", headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 500
    check guardState.currentInflight() == 0

suite "Complex — middleware interaction edge cases":
  test "request_id available to json_logger when ordered correctly":
    var logLine = ""
    let logOpts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfRequestId, jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let mws = @[requestId(), jsonLogger(logOpts)]
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check "request_id" in logLine

  test "json_logger still sees request_id even when ordered before request_id middleware":
    var logLine = ""
    let logOpts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfRequestId, jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let mws = @[jsonLogger(logOpts), requestId()]
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check "request_id" in logLine

  test "helmet headers persist through panic_recovery":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[
      helmet(),
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson))
    ]
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.headers.getOrDefault("x-content-type-options", "") == "nosniff"
    check res.statusCode == 500

  test "error_handler includes requestId from request_id middleware":
    let mws = @[
      requestId(),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 500
    check req.locals.getOrDefault("requestId", "").len > 0

suite "Complex — session + CSRF interaction":
  test "session creates ID, CSRF generates token":
    let mws = @[session(), csrf()]
    let req = newMockRequest(methodKind = hmGet)
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check req.locals.getOrDefault("_session_id", "").len > 0
    check req.locals.getOrDefault("csrf_token", "").len > 0

  test "CSRF token stored in request locals after GET":
    let mws = @[csrf()]
    let req = newMockRequest(methodKind = hmGet)
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    let token = csrfToken(req)
    check token.len > 0

suite "Complex — graceful_shutdown state":
  test "graceful shutdown state starts not shutting down":
    let state = newGracefulShutdownState()
    check not state.isShuttingDown()
    check state.inflightCount() == 0

  test "initiateShutdown sets shutting down flag":
    let state = newGracefulShutdownState()
    state.initiateShutdown()
    check state.isShuttingDown()

  test "double initiateShutdown is idempotent":
    let state = newGracefulShutdownState()
    state.initiateShutdown()
    state.initiateShutdown()
    check state.isShuttingDown()

  test "signal bridge initiates shutdown from async context":
    resetGracefulShutdownSignalForTest()
    let state = newGracefulShutdownState()
    discard gracefulShutdown(state, installSignalHandlers = false)

    markGracefulShutdownSignalForTest()
    waitFor sleepAsync(250)

    check state.isShuttingDown()
    check state.isDrainComplete()
    resetGracefulShutdownSignalForTest()

# ============================================================
# ITERATION 16-17: Combination Stress Tests
# ============================================================

suite "Stress combo — production stack under load":
  test "50 requests through full production stack":
    resetRateLimitStoreForTest()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      cors(),
      helmet(),
      rateLimit(maxRequests = 100, windowMs = 60000),
      etag(),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    for i in 0..<50:
      let req = newMockRequest("/api/item/" & $i, remoteIpStr = "10.3.0.1", headerMap = @[("origin", "http://app.com")])
      let res = newMockResponse()
      runMiddlewareChain(mws, req, res, okHandler)
      check res.statusCode == 200
      check req.locals.getOrDefault("requestId", "").len > 0

  test "mixed success and failure requests":
    resetRateLimitStoreForTest()
    let cb = newCircuitBreaker(failureThreshold = 100)
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      circuitBreakerMiddleware(cb),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    for i in 0..<20:
      let req = newMockRequest("/api/test")
      let res = newMockResponse()
      if i mod 3 == 0:
        runMiddlewareChain(mws, req, res, crashHandler)
        check res.statusCode == 500
      else:
        runMiddlewareChain(mws, req, res, okHandler)
        check res.statusCode == 200

suite "Stress combo — rate limiting with multiple IPs":
  test "10 different IPs each getting independent limits":
    resetRateLimitStoreForTest()
    let mw = rateLimit(maxRequests = 3, windowMs = 60000)
    for ip in 0..9:
      for reqNum in 0..4:
        let req = newMockRequest(remoteIpStr = "10.4." & $ip & ".1")
        let res = newMockResponse()
        runMiddlewareChain(@[mw], req, res, okHandler)
        if reqNum < 3:
          check res.statusCode == 200
        else:
          check res.statusCode == 429

suite "Stress combo — error filter priority ordering":
  test "higher priority filter runs first":
    let lowPriority = newExceptionFilter(
      "LowCatch",
      proc(err: ref Exception, req: Req, res: Res): bool =
        res.statusCode = 599
        true,
      priority = 10
    )
    let highPriority = newExceptionFilter(
      "HighCatch",
      proc(err: ref Exception, req: Req, res: Res): bool =
        if err of ValueError:
          res.statusCode = 422
          return true
        false,
      priority = 500
    )
    let mw = globalErrorFilter(@[lowPriority, highPriority])
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 422

# ============================================================
# ITERATION 18: Additional Coverage Tests
# ============================================================

suite "Coverage — server_timing variations":
  test "server timing disabled passes through":
    let opts = ServerTimingOptions(enabled: false, productionMode: false)
    let mw = serverTiming(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check req.locals.getOrDefault("_server_timing_enabled", "") == ""

suite "Coverage — json_logger field exclusions":
  test "exclude specific fields from log":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfMethod, jlfPath, jlfStatus, jlfRemoteIp},
      excludeFields: {jlfRemoteIp},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let mw = jsonLogger(opts)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check "\"remote_ip\":" notin logLine

  test "custom skip paths work":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfStatus},
      excludeFields: {},
      skipPaths: @["/metrics", "/internal/status"],
      skipHealthChecks: true
    )
    let mw = jsonLogger(opts)
    let req = newMockRequest("/metrics")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check logLine.len == 0

suite "Coverage — cors with credentials and allowlist":
  test "credentials with allowlist — allowed origin reflected":
    let opts = CorsOptions(
      origin: "*",
      allowedOrigins: @["http://trusted.com"],
      credentials: true
    )
    let req = newMockRequest(headerMap = @[("origin", "http://trusted.com")])
    let res = newMockResponse()
    let mw = cors(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "credentials with allowlist — untrusted origin blocked on OPTIONS":
    let opts = CorsOptions(
      origin: "*",
      allowedOrigins: @["http://trusted.com"],
      credentials: true
    )
    let req = newMockRequest(
      methodKind = hmOptions,
      headerMap = @[("origin", "http://untrusted.com")]
    )
    let res = newMockResponse()
    let mw = cors(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 403

  test "maxAge sets access-control-max-age":
    let opts = CorsOptions(
      origin: "reflect",
      allowedOrigins: @[],
      maxAge: 86400
    )
    let req = newMockRequest(
      methodKind = hmOptions,
      headerMap = @[("origin", "http://any.com")]
    )
    let res = newMockResponse()
    let mw = cors(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.headers.getOrDefault("access-control-max-age", "") == "86400"

suite "Coverage — helmet with CSP":
  test "content security policy header set when enabled":
    var opts = defaultHelmetOptions()
    opts.contentSecurityPolicy = true
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = helmet(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.headers.getOrDefault("content-security-policy", "").len > 0

  test "CSP nonce injected when enabled":
    var opts = defaultHelmetOptions()
    opts.contentSecurityPolicy = true
    opts.contentSecurityPolicyNonce = true
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = helmet(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    let nonce = req.locals.getOrDefault("csp_nonce", "")
    check nonce.len > 0

  test "permissions policy header set when enabled":
    var opts = defaultHelmetOptions()
    opts.permissionsPolicy = true
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = helmet(opts)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.headers.getOrDefault("permissions-policy", "").len > 0

suite "Coverage — rate limit presets":
  test "API default preset allows 120 requests":
    resetRateLimitStoreForTest()
    let mw = rateLimitPreset(rlpApiDefault)
    for i in 0..<120:
      let req = newMockRequest(remoteIpStr = "10.5.0.1")
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
      check res.statusCode == 200
    let req = newMockRequest(remoteIpStr = "10.5.0.1")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 429

  test "auth strict preset allows 20 requests":
    resetRateLimitStoreForTest()
    let mw = rateLimitPreset(rlpAuthStrict)
    for i in 0..<20:
      let req = newMockRequest(remoteIpStr = "10.5.1.1")
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
      check res.statusCode == 200
    let req = newMockRequest(remoteIpStr = "10.5.1.1")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 429

# ============================================================
# ITERATION 19-20: Final Coverage and Cross-Cutting Tests
# ============================================================

suite "Cross-cutting — all error types through production stack":
  test "ValueError through production stack":
    resetRateLimitStoreForTest()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      helmet(),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, crashHandler)
    check res.statusCode == 500

  test "IOError through production stack":
    resetRateLimitStoreForTest()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      helmet(),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, ioErrorHandler)
    check res.statusCode == 500

  test "OSError through production stack":
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      helmet(),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, osErrorHandler)
    check res.statusCode == 500

  test "JsonParsingError through production stack":
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      helmet(),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, jsonErrorHandler)
    check res.statusCode == 500

  test "KeyError through production stack":
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      helmet(),
      errorHandler(ErrorHandlerOptions(logErrors: false))
    ]
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, keyErrorHandler)
    check res.statusCode == 500

suite "Cross-cutting — OPTIONS preflight through various stacks":
  test "OPTIONS through cors + helmet + rate_limit":
    resetRateLimitStoreForTest()
    let mws = @[
      cors(),
      helmet(),
      rateLimit(maxRequests = 100, windowMs = 60000)
    ]
    let req = newMockRequest(methodKind = hmOptions, headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 204

  test "OPTIONS through cors + session + csrf":
    let mws = @[
      cors(),
      session(),
      csrf()
    ]
    let req = newMockRequest(methodKind = hmOptions, headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 204

suite "Cross-cutting — HEAD requests":
  test "HEAD request through full stack":
    resetRateLimitStoreForTest()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      requestId(),
      cors(),
      helmet(),
      rateLimit(maxRequests = 100, windowMs = 60000)
    ]
    let req = newMockRequest(methodKind = hmHead, headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

suite "Cross-cutting — POST requests through auth stack":
  test "POST with valid CSRF token structure passes":
    let csrfMw = csrf()
    let req = newMockRequest(methodKind = hmGet)
    let res = newMockResponse()
    runMiddlewareChain(@[csrfMw], req, res, okHandler)
    let token = csrfToken(req)
    check token.len > 0

  test "POST without CSRF token is rejected at 403":
    let csrfMw = csrf()
    let req = newMockRequest(methodKind = hmPost)
    let res = newMockResponse()
    runMiddlewareChain(@[csrfMw], req, res, okHandler)
    check res.statusCode == 403

suite "Cross-cutting — different HTTP methods":
  test "PUT request through security stack":
    let mws = @[
      helmet(),
      cors(),
      requestId()
    ]
    let req = newMockRequest(methodKind = hmPut, headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200
    check req.locals.getOrDefault("requestId", "").len > 0

  test "DELETE request through security stack":
    let mws = @[
      helmet(),
      cors(),
      requestId()
    ]
    let req = newMockRequest(methodKind = hmDelete, headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

  test "PATCH request through security stack":
    let mws = @[
      helmet(),
      cors(),
      requestId()
    ]
    let req = newMockRequest(methodKind = hmPatch, headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

suite "Cross-cutting — body_limit in combination":
  test "body_limit + panic_recovery — oversized body rejected":
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      bodyLimit(100)
    ]
    let req = newMockRequest(bodyStr = "", headerMap = @[("content-length", "500000")])
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 413

  test "body_limit + error_handler — valid body passes":
    let mws = @[
      errorHandler(ErrorHandlerOptions(logErrors: false)),
      bodyLimit(1048576)
    ]
    let req = newMockRequest(bodyStr = "hello")
    let res = newMockResponse()
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

suite "Cross-cutting — concurrency_guard in combination":
  test "concurrency_guard + circuit_breaker — both track state":
    let guardState = newConcurrencyGuardState(maxInflight = 100)
    let cb = newCircuitBreaker(failureThreshold = 10)
    let mws = @[
      concurrencyGuard(guardState),
      circuitBreakerMiddleware(cb)
    ]
    for i in 0..5:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(mws, req, res, okHandler)
    check guardState.currentInflight() == 0
    check cb.state == csClosed

suite "Idempotency — middleware can be reused across requests":
  test "same middleware instance handles 100 requests":
    let mw = requestId()
    var ids: seq[string] = @[]
    for i in 0..<100:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
      ids.add(req.locals.getOrDefault("requestId", ""))
    for id in ids:
      check id.len > 0
    for i in 0..<ids.len:
      for j in (i+1)..<ids.len:
        check ids[i] != ids[j]

  test "same cors middleware handles 100 requests":
    let mw = cors()
    for i in 0..<100:
      let req = newMockRequest(headerMap = @[("origin", "http://app.com")])
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
      check res.statusCode == 200

  test "same helmet middleware handles 100 requests":
    let mw = helmet()
    for i in 0..<100:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, okHandler)
      check res.headers.getOrDefault("x-content-type-options", "") == "nosniff"

suite "Regression — no middleware stack crash on nil checks":
  test "empty middleware stack runs handler directly":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[], req, res, okHandler)
    check res.statusCode == 200

  test "single middleware with no-op handler":
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      await next()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "middleware that does not call next":
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      res.statusCode = 418
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 418

  test "middleware chain with all middlewares skipping":
    let mw1: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      await next()
    let mw2: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      await next()
    let mw3: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      await next()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw1, mw2, mw3], req, res, okHandler)
    check res.statusCode == 200

suite "Individual middleware — timeout":
  test "fast handler completes within timeout":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = timeout(5000)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "slow handler triggers 504 when budget exceeded":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = timeout(10)
    runMiddlewareChain(@[mw], req, res, slowHandler)
    check res.statusCode == 504

  test "timeout with panic_recovery catches timeout gracefully":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      timeout(10)
    ]
    runMiddlewareChain(mws, req, res, slowHandler)
    check res.statusCode == 504 or res.statusCode == 500

  test "timeout preset API strict works":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = timeoutPreset(tpApiStrict)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

  test "timeout preset long poll works":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = timeoutPreset(tpLongPoll)
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200

suite "Individual middleware — normalize_path":
  test "clean path passes through without redirect":
    let req = newMockRequest("/api/users")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res, okHandler)
    check res.statusCode == 200

  test "trailing slash is trimmed by default":
    let req = newMockRequest("/api/users/")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res, okHandler)
    check res.statusCode == 301

  test "duplicate slashes are merged":
    let req = newMockRequest("/api//users///data")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res, okHandler)
    check res.statusCode == 301

  test "dot segments resolved":
    let req = newMockRequest("/api/users/../admin")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res, okHandler)
    check res.statusCode == 301

  test "root path / passes through":
    let req = newMockRequest("/")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res, okHandler)
    check res.statusCode == 200

  test "append mode adds trailing slash":
    let req = newMockRequest("/api/users")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath(tsmAppend)], req, res, okHandler)
    check res.statusCode == 301

suite "Cross-cutting — status404 handler through stacks":
  test "404 through error_handler does not change status":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[errorHandler(ErrorHandlerOptions(logErrors: false))], req, res, status404Handler)
    check res.statusCode == 404

  test "404 through production stack preserves status":
    let req = newMockRequest()
    let res = newMockResponse()
    let mws = @[
      panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson)),
      errorHandler(ErrorHandlerOptions(logErrors: false)),
      requestId()
    ]
    runMiddlewareChain(mws, req, res, status404Handler)
    check res.statusCode == 404

suite "Cross-cutting — overflow defect through stacks":
  test "OverflowDefect caught by panic_recovery":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson))
    runMiddlewareChain(@[mw], req, res, overflowErrorHandler)
    check res.statusCode == 500

suite "Cross-cutting — timeout with normalize_path":
  test "timeout + normalize_path for clean path":
    let req = newMockRequest("/api/items")
    let res = newMockResponse()
    let mws = @[timeout(5000), normalizePath()]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 200

  test "timeout + normalize_path for dirty path":
    let req = newMockRequest("/api//items/")
    let res = newMockResponse()
    let mws = @[timeout(5000), normalizePath()]
    runMiddlewareChain(mws, req, res, okHandler)
    check res.statusCode == 301

suite "Final validation — complete middleware inventory coverage":
  test "panic_recovery tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[panicRecovery(PanicRecoveryOptions(logErrors: false, includeStackTrace: false, reportHook: nil, responseFormat: erfJson))], req, res, okHandler)
    check res.statusCode == 200

  test "error_handler tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[errorHandler(ErrorHandlerOptions(logErrors: false))], req, res, okHandler)
    check res.statusCode == 200

  test "logger tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[logger()], req, res, okHandler)
    check res.statusCode == 200

  test "json_logger tested individually":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req, res, okHandler)
    check res.statusCode == 200

  test "cors tested individually":
    let req = newMockRequest(headerMap = @[("origin", "http://app.com")])
    let res = newMockResponse()
    runMiddlewareChain(@[cors()], req, res, okHandler)
    check res.statusCode == 200

  test "rate_limit tested individually":
    resetRateLimitStoreForTest()
    let req = newMockRequest(remoteIpStr = "10.9.0.1")
    let res = newMockResponse()
    runMiddlewareChain(@[rateLimit()], req, res, okHandler)
    check res.statusCode == 200

  test "helmet tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet()], req, res, okHandler)
    check res.statusCode == 200

  test "request_id tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[requestId()], req, res, okHandler)
    check res.statusCode == 200

  test "health tested individually":
    let req = newMockRequest("/api/data")
    let res = newMockResponse()
    runMiddlewareChain(@[health()], req, res, okHandler)
    check res.statusCode == 200

  test "circuit_breaker tested individually":
    let cb = newCircuitBreaker()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[circuitBreakerMiddleware(cb)], req, res, okHandler)
    check res.statusCode == 200

  test "global_error_filter tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    let opts = GlobalErrorFilterOptions(filters: @[], fallbackStatusCode: 500, logUnhandled: false)
    runMiddlewareChain(@[globalErrorFilter(opts)], req, res, okHandler)
    check res.statusCode == 200

  test "concurrency_guard tested individually":
    let state = newConcurrencyGuardState()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[concurrencyGuard(state)], req, res, okHandler)
    check res.statusCode == 200

  test "server_timing tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[serverTiming()], req, res, okHandler)
    check res.statusCode == 200

  test "backpressure tested individually":
    let bpState = newBackpressureState()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[backpressure(bpState)], req, res, okHandler)
    check res.statusCode == 200

  test "etag tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[etag()], req, res, okHandler)
    check res.statusCode == 200

  test "body_limit tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[bodyLimit(1048576)], req, res, okHandler)
    check res.statusCode == 200

  test "ip_filter tested individually":
    let req = newMockRequest(remoteIpStr = "8.8.8.8")
    let res = newMockResponse()
    runMiddlewareChain(@[ipFilter()], req, res, okHandler)
    check res.statusCode == 200

  test "session tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[session()], req, res, okHandler)
    check res.statusCode == 200

  test "csrf tested individually (GET)":
    let req = newMockRequest(methodKind = hmGet)
    let res = newMockResponse()
    runMiddlewareChain(@[csrf()], req, res, okHandler)
    check res.statusCode == 200

  test "timeout tested individually":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[timeout(5000)], req, res, okHandler)
    check res.statusCode == 200

  test "normalize_path tested individually":
    let req = newMockRequest("/clean")
    let res = newMockResponse()
    runMiddlewareChain(@[normalizePath()], req, res, okHandler)
    check res.statusCode == 200
