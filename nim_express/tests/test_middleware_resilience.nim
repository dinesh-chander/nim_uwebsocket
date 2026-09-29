import std/[unittest, asyncdispatch, atomics, net, strutils, times, os]
import std/asynchttpserver except Request

import ../src/nim_express/[app, types, request, response]
import ../src/nim_express/offload
import ../src/nim_express/middlewares/[timeout, file_helpers, io_helpers, body_parser, body_limit, rate_limit, request_id, cookie_parser, logger]

proc toFastMap(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    discard result.put(k, v)

proc openFdCount(): int =
  when defined(posix):
    if dirExists("/dev/fd"):
      for kind, path in walkDir("/dev/fd"):
        if kind in {pcFile, pcLinkToFile}:
          inc result

proc reserveLoopbackPort(): Port =
  let sock = newSocket()
  try:
    sock.bindAddr(Port(0), "127.0.0.1")
    let (_, port) = sock.getLocalAddr()
    port
  finally:
    sock.close()

suite "Middleware resilience":
  test "before-headers hook throw does not leak pooled wrappers":
    var seedReqNative: HttpRequest
    new(seedReqNative)
    seedReqNative.methodKind = hmGet
    let seededReq = acquireRequest(seedReqNative)
    releaseRequest(seededReq)

    var seedResNative: HttpResponse
    new(seedResNative)
    seedResNative.requestMethod = hmGet
    let seededRes = acquireResponse(seedResNative)
    releaseResponse(seededRes)

    let reqPoolBefore = requestPoolSize()
    let resPoolBefore = responsePoolSize()

    let webApp = newExpressApp()
    webApp.onBeforeHeaders(proc(req: Request, res: Response) =
      raise newException(ValueError, "boom")
    )
    check webApp.server.beforeHeadersHandler != nil

    var nativeReq: HttpRequest
    new(nativeReq)
    nativeReq.methodKind = hmGet
    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet

    expect ValueError:
      webApp.server.beforeHeadersHandler(nativeReq, nativeRes)
    expect ValueError:
      webApp.server.beforeHeadersHandler(nativeReq, nativeRes)

    check requestPoolSize() == reqPoolBefore
    check responsePoolSize() == resPoolBefore

  test "timeout middleware marks request cancelled on timeout":
    var nativeReq: HttpRequest
    new(nativeReq)
    nativeReq.methodKind = hmGet
    let req = newRequest(nativeReq)

    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet
    nativeRes.connectionClose = false
    let res = newResponse(nativeRes)

    var nextEntered = false
    let mw = timeout(5)
    proc nextProc(): Future[void] {.async.} =
      nextEntered = true
      await sleepAsync(20)

    waitFor mw(req, res, nextProc)
    check nextEntered
    check req.requestCancelled()
    check req.cancelReason == rcrTimeout
    check res.statusCode == 504

  test "before-route advice rejection without response finalizes request":
    let webApp = newExpressApp()
    webApp.onBeforeRouteMatchAdvice(proc(req: Request, res: Response): bool =
      false
    )
    webApp.get("/guarded", proc(req: Request, res: Response) =
      res.send("should not run")
    )

    var nativeReq: HttpRequest
    new(nativeReq)
    nativeReq.methodKind = hmGet
    nativeReq.path = "/guarded"
    nativeReq.headers = newFastMap[string]()
    let req = newRequest(nativeReq)

    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet
    nativeRes.connectionClose = false
    let res = newResponse(nativeRes)
    waitFor webApp.handleRequestForTest(req, res)

    check res.finished
    check res.statusCode == 500
    check res.native.capturedRaw.toLowerAscii().contains("500 internal server error")

  test "bodyLimit rejects spilled oversized body before reading file":
    let spillRoot = getTempDir() / ("nim_express_body_limit_" & $getCurrentProcessId())
    createDir(spillRoot)
    let spillPath = spillRoot / "large_body.dat"
    writeFile(spillPath, repeat("x", 4096))
    try:
      var nativeReq: HttpRequest
      new(nativeReq)
      nativeReq.methodKind = hmPost
      nativeReq.path = "/upload"
      nativeReq.headers = newFastMap[string]()
      nativeReq.bodyInFile = true
      nativeReq.bodyFilePath = spillPath
      nativeReq.bodyFileRoot = spillRoot
      let req = newRequest(nativeReq)

      var nativeRes: HttpResponse
      new(nativeRes)
      nativeRes.requestMethod = hmPost
      nativeRes.connectionClose = false
      let res = newResponse(nativeRes)

      var nextCalled = false
      proc nextProc(): Future[void] {.async.} =
        nextCalled = true

      let mw = bodyLimit(1024)
      waitFor mw(req, res, nextProc)

      check not nextCalled
      check res.statusCode == 413
      check req.body.len == 0
      check fileExists(spillPath)
    finally:
      if fileExists(spillPath):
        removeFile(spillPath)
      if dirExists(spillRoot):
        removeDir(spillRoot)

  test "sendFile returns notFound for missing file path":
    var nativeReq: HttpRequest
    new(nativeReq)
    nativeReq.methodKind = hmGet
    nativeReq.headers = newFastMap[string]()
    let req = newRequest(nativeReq)

    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet
    nativeRes.connectionClose = false
    let res = newResponse(nativeRes)

    let missing = getTempDir() / ("nim_express_missing_" & $epochTime() & ".txt")
    waitFor sendFile(res, req, missing)
    check res.statusCode == 404

  test "rate limiter uses bounded sanitized forwarded key":
    let keyBase = "198.51.100." & $((epochTime().int mod 200) + 1)
    let mw = rateLimit(maxRequests = 1, windowMs = 60000, trustProxy = true)

    var req1Native: HttpRequest
    new(req1Native)
    req1Native.methodKind = hmGet
    req1Native.remoteIp = "127.0.0.1"
    req1Native.headers = toFastMap([("x-forwarded-for", keyBase & "\n")])
    let req1 = newRequest(req1Native)

    var res1Native: HttpResponse
    new(res1Native)
    res1Native.requestMethod = hmGet
    let res1 = newResponse(res1Native)
    var next1 = false
    proc nextProc1(): Future[void] {.async.} =
      next1 = true
    waitFor mw(req1, res1, nextProc1)
    check next1

    var req2Native: HttpRequest
    new(req2Native)
    req2Native.methodKind = hmGet
    req2Native.remoteIp = "127.0.0.1"
    req2Native.headers = toFastMap([("x-forwarded-for", keyBase & "!!!")])
    let req2 = newRequest(req2Native)

    var res2Native: HttpResponse
    new(res2Native)
    res2Native.requestMethod = hmGet
    let res2 = newResponse(res2Native)
    var next2 = false
    proc nextProc2(): Future[void] {.async.} =
      next2 = true
    waitFor mw(req2, res2, nextProc2)
    check next2 == false
    check res2.statusCode == 429

  test "cookie parsing enforces deterministic pair and token bounds":
    var rawPairs: seq[string] = @[]
    for i in 0 ..< (DefaultMaxCookiePairs + 4):
      rawPairs.add("k" & $i & "=v" & $i)
    let oversizedCookie = rawPairs.join("; ")

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.headers = toFastMap([("cookie", oversizedCookie)])
    let req = newRequest(reqNative)
    check req.getCookie("k0") == ""
    check req.locals.get("_cookie_parse_rejected", "") == "1"

    let mw = cookieParser()
    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    var nextCalled = false
    proc nextProc(): Future[void] {.async.} =
      nextCalled = true
    waitFor mw(req, res, nextProc)
    check nextCalled
    check req.cookies.len == 0
    check req.locals.get("_cookie_parse_rejected", "") == "1"

  test "rate limiter caps tracked key cardinality and exposes drop metrics":
    resetRateLimitStoreForTest()
    let mw = rateLimit(
      maxRequests = 1000,
      windowMs = 60_000,
      trustProxy = true,
      maxTrackedKeys = 8,
      rejectNewKeyWhenFull = true
    )

    var rejected = 0
    for i in 0 ..< 40:
      var reqNative: HttpRequest
      new(reqNative)
      reqNative.methodKind = hmGet
      reqNative.remoteIp = "127.0.0.1"
      reqNative.headers = toFastMap([("x-forwarded-for", "198.51.100." & $i & ", 127.0.0.1")])
      let req = newRequest(reqNative)
      req.trustedProxyHopCount = 1

      var resNative: HttpResponse
      new(resNative)
      resNative.requestMethod = hmGet
      let res = newResponse(resNative)
      var nextCalled = false
      proc nextProc(): Future[void] {.async.} =
        nextCalled = true
      waitFor mw(req, res, nextProc)
      if not nextCalled and res.statusCode == 429:
        inc rejected

    check rateLimitTrackedKeyCount() <= 8
    check rejected > 0
    check rateLimitKeyCapacityDrops() >= rejected.int64

  test "offload event output escapes structured fields":
    let outcome = OffloadOutcome[int](
      kind: ookOffloadError,
      value: 0,
      errorClass: "offload_error",
      errorMessage: "line1\n\"quoted\"",
      operation: "op\"x",
      correlationId: "id\\z"
    )
    let encoded = formatOffloadOutcomeEvent(outcome)
    check encoded.contains("\\n")
    check encoded.contains("\\\"quoted\\\"")
    check encoded.contains("op\\\"x")
    check encoded.contains("id\\\\z")

  test "fallback request id format avoids pointer-like separators":
    let id1 = buildFallbackRequestId()
    let id2 = buildFallbackRequestId()
    check id1.len == 32
    check id2.len == 32
    check id1 != id2
    check '-' notin id1
    for c in id1:
      check c in {'0'..'9', 'A'..'F', 'a'..'f'}

  test "readFileAsync failure does not leak descriptors":
    when defined(posix):
      let baseline = openFdCount()
      let readTarget = getTempDir()
      for _ in 0 ..< 32:
        expect CatchableError:
          discard waitFor readFileAsync(readTarget)
      let after = openFdCount()
      check after <= baseline + 2

  test "outbound helpers apply bounded timeout policy":
    check DefaultOutboundTimeoutMs > 0
    let port = reserveLoopbackPort()
    let server = newAsyncHttpServer()
    var slowResponses = 0
    proc slowHandler(req: asynchttpserver.Request) {.async.} =
      inc slowResponses
      await sleepAsync(150)
      await req.respond(Http200, "ok")
    let serveFuture = server.serve(port, slowHandler)
    waitFor sleepAsync(20)
    let url = "http://127.0.0.1:" & $int(port) & "/slow"

    expect CatchableError:
      discard waitFor fetchAsync(url, timeoutMs = 5)
    expect CatchableError:
      discard waitFor postAsync(url, "{}", timeoutMs = 5)

    check waitFor(fetchAsync(url, timeoutMs = 1000)) == "ok"
    check waitFor(postAsync(url, "{}", timeoutMs = 1000)) == "ok"
    check slowResponses >= 2
    server.close()
    try:
      discard waitFor(serveFuture.withTimeout(200))
    except CatchableError:
      discard

  test "hostname uses safe forwarded-host tokenization":
    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.headers = toFastMap([
      ("x-forwarded-for", "198.51.100.10, 127.0.0.1"),
      ("x-forwarded-host", "spoof.example.com, edge.example.com:8443"),
      ("host", "origin.example.com:8080")
    ])
    let req = newRequest(reqNative)
    req.trustProxyEnabled = true
    req.trustedProxyHopCount = 1
    check req.hostname() == "edge.example.com"

    reqNative.headers = toFastMap([
      ("x-forwarded-for", "198.51.100.10, 127.0.0.1"),
      ("x-forwarded-host", "evil host\r\nx:1"),
      ("host", "origin.example.com:8080")
    ])
    let fallbackReq = newRequest(reqNative)
    fallbackReq.trustProxyEnabled = true
    fallbackReq.trustedProxyHopCount = 1
    check fallbackReq.hostname() == "origin.example.com"

  test "timeout middleware cancels downstream future on expiry":
    var nativeReq: HttpRequest
    new(nativeReq)
    nativeReq.methodKind = hmGet
    let req = newRequest(nativeReq)

    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet
    let res = newResponse(nativeRes)

    let mw = timeout(5)
    var ticks = 0
    proc nextProc(): Future[void] {.async.} =
      while not req.requestCancelled():
        inc ticks
        await sleepAsync(3)

    waitFor mw(req, res, nextProc)
    check req.requestCancelled()
    check req.cancelReason == rcrTimeout
    check res.statusCode == 504
    check ticks > 0
    check req.locals.get("_timed_out", "") == "1"

  test "overload rejection cancels existing async future without pooling wrappers":
    let previousPooling = getRequestResponsePoolingEnabled()
    setRequestResponsePoolingEnabled(true)
    try:
      let reqPoolBefore = requestPoolSize()
      let resPoolBefore = responsePoolSize()
      let webApp = newExpressApp()
      webApp.setMaxInflightAsyncRequests(1)
      webApp.inflightAsyncRequests.store(1'i64, moRelaxed)

      var nativeReq: HttpRequest
      new(nativeReq)
      nativeReq.methodKind = hmGet
      nativeReq.path = "/busy"
      let req = acquireRequest(nativeReq)

      var nativeRes: HttpResponse
      new(nativeRes)
      nativeRes.requestMethod = hmGet
      nativeRes.connectionClose = false
      let res = acquireResponse(nativeRes, webApp)
      res.request = req

      let fut = newFuture[void]("overload-rejected-existing-future")
      let accepted = webApp.scheduleExistingAsyncFutureForTest(req, res, fut)

      check accepted == false
      check req.cancelReason == rcrTimeout
      check res.finished == true
      check res.statusCode == 503

      req.markRequestReleased()
      releaseResponse(res)
      releaseRequest(req)

      check requestPoolSize() == reqPoolBefore
      check responsePoolSize() == resPoolBefore
    finally:
      setRequestResponsePoolingEnabled(previousPooling)

  test "middleware stall emits deterministic failure response and error signal":
    let webApp = newExpressApp()
    var errors: seq[string] = @[]
    webApp.onErrorHook(proc(message: string) =
      errors.add(message)
    )
    webApp.use(proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      discard
    )
    webApp.get("/stall", proc(req: Request, res: Response) =
      res.send("ok")
    )

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.path = "/stall"
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)

    waitFor webApp.handleRequestForTest(req, res)
    check res.statusCode == 500
    check resNative.bodyWasSent()
    check errors.join("\n").contains("class=middleware_stall")

  test "async pump poll failures are surfaced with bounded telemetry":
    let webApp = newExpressApp()
    var errors: seq[string] = @[]
    webApp.onErrorHook(proc(message: string) =
      errors.add(message)
    )
    resetAsyncPumpPollTelemetryForTest()
    for _ in 0 ..< 8:
      webApp.recordAsyncPumpPollFailure("simulated")
    check asyncPumpPollFailureCount() == 8
    check errors.len == 1
    check errors[0].contains("class=async_pump_poll_failure")

  test "sendFile fallback enforces bounded in-memory payload cap":
    let root = getTempDir() / ("nim_express_static_cap_" & $epochTime())
    createDir(root)
    let staticPath = root / "large.txt"
    writeFile(staticPath, repeat("x", 128))
    defer:
      if fileExists(staticPath):
        removeFile(staticPath)
      if dirExists(root):
        removeDir(root)

    let webApp = newExpressApp()
    webApp.set("static_fallback_max_bytes", "16")

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.headers = newFastMap[string]()
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.app = webApp

    waitFor sendFile(res, req, staticPath)
    check res.statusCode == 413

  test "body-file deletion is restricted to trusted spill roots":
    resetSkippedBodyFileDeleteCount()
    let trustedRoot = getTempDir() / ("nim_express_spill_trusted_" & $epochTime())
    let untrustedRoot = getTempDir() / ("nim_express_spill_untrusted_" & $epochTime())
    createDir(trustedRoot)
    createDir(untrustedRoot)
    let trustedPath = trustedRoot / "trusted.tmp"
    let untrustedPath = untrustedRoot / "untrusted.tmp"
    writeFile(trustedPath, "ok")
    writeFile(untrustedPath, "ok")
    defer:
      if fileExists(trustedPath):
        removeFile(trustedPath)
      if fileExists(untrustedPath):
        removeFile(untrustedPath)
      if dirExists(trustedRoot):
        removeDir(trustedRoot)
      if dirExists(untrustedRoot):
        removeDir(untrustedRoot)

    var trustedNative: HttpRequest
    new(trustedNative)
    trustedNative.methodKind = hmPost
    trustedNative.bodyInFile = true
    trustedNative.bodyFilePath = trustedPath
    trustedNative.bodyFileRoot = trustedRoot
    let trustedReq = newRequest(trustedNative)
    releaseRequest(trustedReq)
    check not fileExists(trustedPath)

    var untrustedNative: HttpRequest
    new(untrustedNative)
    untrustedNative.methodKind = hmPost
    untrustedNative.bodyInFile = true
    untrustedNative.bodyFilePath = untrustedPath
    untrustedNative.bodyFileRoot = trustedRoot
    let untrustedReq = newRequest(untrustedNative)
    releaseRequest(untrustedReq)
    check fileExists(untrustedPath)
    check skippedBodyFileDeleteCount() >= 1

  test "logger sanitizes control characters in logged fields":
    let sanitized = sanitizeLogField("/todos\r\nx\x01y")
    check "\r" notin sanitized
    check "\n" notin sanitized
    check sanitized.contains("\\x0D")
    check sanitized.contains("\\x0A")
    check sanitized.contains("\\x01")

  test "trust proxy policy enforces allowlist and hop boundaries":
    var untrustedNative: HttpRequest
    new(untrustedNative)
    untrustedNative.methodKind = hmGet
    untrustedNative.remoteIp = "10.0.0.8"
    untrustedNative.headers = toFastMap([
      ("x-forwarded-for", "198.51.100.4"),
      ("x-forwarded-proto", "https"),
      ("x-forwarded-host", "edge.example.com"),
      ("host", "origin.example.com:8080")
    ])
    let untrustedReq = newRequest(untrustedNative)
    untrustedReq.trustProxyEnabled = true
    untrustedReq.trustedProxyHopCount = 1
    untrustedReq.trustedProxyAllowlist = "127.0.0.1"
    check untrustedReq.protocol() == "http"
    check untrustedReq.hostname() == "origin.example.com"

    var trustedNative: HttpRequest
    new(trustedNative)
    trustedNative.methodKind = hmGet
    trustedNative.remoteIp = "127.0.0.1"
    trustedNative.headers = toFastMap([
      ("x-forwarded-for", "198.51.100.7, 127.0.0.1"),
      ("x-forwarded-proto", "https"),
      ("x-forwarded-host", "edge.example.com"),
      ("host", "origin.example.com:8080")
    ])
    let trustedReq = newRequest(trustedNative)
    trustedReq.trustProxyEnabled = true
    trustedReq.trustedProxyHopCount = 1
    trustedReq.trustedProxyAllowlist = "127.0.0.1"
    check trustedReq.protocol() == "https"
    check trustedReq.hostname() == "edge.example.com"

  test "rate limiter falls back to socket identity when forwarded chain is untrusted":
    resetRateLimitStoreForTest()
    let mw = rateLimit(maxRequests = 1, windowMs = 60_000, trustProxy = true)

    var req1Native: HttpRequest
    new(req1Native)
    req1Native.methodKind = hmGet
    req1Native.remoteIp = "10.0.0.8"
    req1Native.headers = toFastMap([("x-forwarded-for", "198.51.100.1")])
    let req1 = newRequest(req1Native)
    req1.trustedProxyHopCount = 1
    req1.trustedProxyAllowlist = "127.0.0.1"

    var res1Native: HttpResponse
    new(res1Native)
    res1Native.requestMethod = hmGet
    let res1 = newResponse(res1Native)
    var next1 = false
    proc nextProc1(): Future[void] {.async.} =
      next1 = true
    waitFor mw(req1, res1, nextProc1)
    check next1

    var req2Native: HttpRequest
    new(req2Native)
    req2Native.methodKind = hmGet
    req2Native.remoteIp = "10.0.0.8"
    req2Native.headers = toFastMap([("x-forwarded-for", "203.0.113.9")])
    let req2 = newRequest(req2Native)
    req2.trustedProxyHopCount = 1
    req2.trustedProxyAllowlist = "127.0.0.1"

    var res2Native: HttpResponse
    new(res2Native)
    res2Native.requestMethod = hmGet
    let res2 = newResponse(res2Native)
    var next2 = false
    proc nextProc2(): Future[void] {.async.} =
      next2 = true
    waitFor mw(req2, res2, nextProc2)
    check not next2
    check res2.statusCode == 429

  test "fallback app correlation id format is opaque":
    let id1 = buildFallbackCorrelationId()
    let id2 = buildFallbackCorrelationId()
    check id1.len == 32
    check id2.len == 32
    check id1 != id2
    check '-' notin id1
    for c in id1:
      check c in {'0'..'9', 'A'..'F', 'a'..'f'}

  test "request lifecycle hooks are exception-safe":
    let webApp = newExpressApp()
    var errorEvents: seq[string] = @[]
    webApp.onErrorHook(proc(message: string) =
      errorEvents.add(message)
    )
    webApp.onRequestStartHook(proc(req: Request) =
      raise newException(ValueError, "start-fail")
    )
    webApp.onRouteMatched(proc(routePattern: string, req: Request) =
      raise newException(ValueError, "route-fail")
    )
    webApp.onRequestEndHook(proc(req: Request, res: Response, durationMicros: int64) =
      raise newException(ValueError, "end-fail")
    )

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    let req = newRequest(reqNative)
    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)

    webApp.invokeRequestStartHook(req)
    webApp.invokeRouteMatchedHook("/todos/:id", req)
    webApp.invokeRequestEndHook(req, res, 10)

    check errorEvents.len >= 3
    check errorEvents.join("\n").contains("hook=requestStartHook")
    check errorEvents.join("\n").contains("hook=routeMatchedHook")
    check errorEvents.join("\n").contains("hook=requestEndHook")

  test "transport telemetry hooks remain safe when user hooks throw":
    let webApp = newExpressApp()
    var errorEvents: seq[string] = @[]
    webApp.onErrorHook(proc(message: string) =
      errorEvents.add(message)
    )
    webApp.onConnectionOpen(proc(remoteIp: string) =
      raise newException(ValueError, "open-fail")
    )
    webApp.onConnectionClose(proc(remoteIp: string, wasWebSocket: bool) =
      raise newException(ValueError, "close-fail")
    )
    webApp.onTimeoutHook(proc(kind: string, remoteIp: string) =
      raise newException(ValueError, "timeout-fail")
    )
    webApp.onTimeoutMetadataHook(proc(
      kind: string,
      phase: string,
      remoteIp: string,
      requestSeq: uint64,
      isWebSocket: bool
    ) =
      raise newException(ValueError, "timeout-meta-fail")
    )
    webApp.onBeforeWrite(proc(bytes: int, isWebSocket: bool) =
      raise newException(ValueError, "before-write-fail")
    )
    webApp.onAfterWrite(proc(bytes: int, ok: bool, isWebSocket: bool) =
      raise newException(ValueError, "after-write-fail")
    )
    webApp.onBackpressure(proc(bufferedBytes: int64, isWebSocket: bool) =
      raise newException(ValueError, "backpressure-fail")
    )
    webApp.onPanicHook(proc(message: string) =
      raise newException(ValueError, "panic-fail")
    )

    webApp.server.connectionOpenHandler("127.0.0.1")
    webApp.server.connectionCloseHandler("127.0.0.1", false, 0'u64, 0'u64)
    webApp.server.timeoutHandler("header_read", "127.0.0.1")
    webApp.server.timeoutMetadataHandler("header_read", "header_read", "127.0.0.1", 1'u64, false)
    webApp.server.beforeWriteHandler(64, false)
    webApp.server.afterWriteHandler(64, true, false)
    webApp.server.backpressureHandler(1024'i64, false)
    webApp.server.panicHandler("panic")

    let combined = errorEvents.join("\n")
    check combined.contains("hook=connectionOpenHook")
    check combined.contains("hook=connectionCloseHook")
    check combined.contains("hook=timeoutHook")
    check combined.contains("hook=timeoutMetadataHook")
    check combined.contains("hook=beforeWriteHook")
    check combined.contains("hook=afterWriteHook")
    check combined.contains("hook=backpressureHook")
    check combined.contains("hook=panicHook")

  test "protocolErrorHook failures fall back safely":
    let webApp = newExpressApp()
    var errorEvents: seq[string] = @[]
    webApp.onErrorHook(proc(message: string) =
      errorEvents.add(message)
    )
    webApp.onProtocolErrorHook(proc(
      statusCode: int,
      remoteIp: string
    ): tuple[statusCode: int, body: string, closeConnection: bool] =
      raise newException(ValueError, "protocol-fail")
    )
    let transformed = webApp.invokeProtocolErrorTransform(431, "127.0.0.1")
    check transformed.statusCode == 431
    check transformed.closeConnection
    check transformed.body.len == 0
    let combined = errorEvents.join("\n")
    check combined.contains("class=protocol_error")
    check combined.contains("hook=protocolErrorHook")

  test "query parsing enforces pair and token bounds":
    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    var heavyParts: seq[string] = @[]
    for i in 0 ..< (DefaultMaxQueryPairs + 16):
      heavyParts.add("k" & $i & "=v" & $i)
    heavyParts.add(repeat("x", DefaultMaxQueryKeyBytes + 8) & "=1")
    heavyParts.add("ok=" & repeat("y", DefaultMaxQueryValueBytes + 16))
    reqNative.queryStringRaw = heavyParts.join("&")
    let req = newRequest(reqNative)
    req.bindQuery()
    check req.queryParam("k0") == "v0"
    check req.queryParam("k127") == "v127"
    check req.queryParam("k128", "missing") == "missing"
    check req.queryParam(repeat("x", DefaultMaxQueryKeyBytes + 8), "missing") == "missing"
    check req.queryParam("ok", "missing") == "missing"

  test "urlencoded parser enforces deterministic bounds":
    let parser = bodyParser()
    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmPost
    reqNative.headers = toFastMap([("content-type", "application/x-www-form-urlencoded")])
    var pairs: seq[string] = @[]
    for i in 0 ..< 300:
      pairs.add("k" & $i & "=v")
    reqNative.body = pairs.join("&")
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmPost
    let res = newResponse(resNative)

    var nextCalled = false
    proc nextProc(): Future[void] {.async.} =
      nextCalled = true
    waitFor parser(req, res, nextProc)
    check nextCalled == false
    check res.statusCode == 413

    var reqNativeTooLarge: HttpRequest
    new(reqNativeTooLarge)
    reqNativeTooLarge.methodKind = hmPost
    reqNativeTooLarge.headers = toFastMap([("content-type", "application/x-www-form-urlencoded")])
    reqNativeTooLarge.body = "a=" & repeat("z", DefaultUrlEncodedMaxValueBytes + 1)
    let reqTooLarge = newRequest(reqNativeTooLarge)
    var resNativeTooLarge: HttpResponse
    new(resNativeTooLarge)
    resNativeTooLarge.requestMethod = hmPost
    let resTooLarge = newResponse(resNativeTooLarge)
    var nextTooLarge = false
    proc nextTooLargeProc(): Future[void] {.async.} =
      nextTooLarge = true
    waitFor parser(reqTooLarge, resTooLarge, nextTooLargeProc)
    check nextTooLarge == false
    check resTooLarge.statusCode == 413

  test "json builder escapes all control bytes below 0x20":
    var builder = initJsonBuilder()
    let raw = "a" & chr(1) & "\n\r\t" & chr(0x1f) & "\"\\"
    builder.addEscaped(raw)
    let encoded = builder.finish()
    check encoded.contains("\\u0001")
    check encoded.contains("\\u001f")
    check encoded.contains("\\n")
    check encoded.contains("\\r")
    check encoded.contains("\\t")
    check encoded.contains("\\\"")
    check encoded.contains("\\\\")
    check not encoded.contains(chr(1))

  test "json builder preserves long safe spans while escaping sentinels":
    var builder = initJsonBuilder()
    let raw = repeat("abcdefghijklmnopqrstuvwxyz0123456789", 64) & "\"tail\n"
    builder.addEscaped(raw)
    let encoded = builder.finish()
    check encoded.startsWith("\"abcdefghijklmnopqrstuvwxyz")
    check encoded.endsWith("\\\"tail\\n\"")
    check encoded.contains(repeat("abcdefghijklmnopqrstuvwxyz0123456789", 8))

  test "timeout middleware enforces downstream middleware deadline":
    let webApp = newExpressApp()
    webApp.use(timeout(10))
    webApp.use(proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      await sleepAsync(50)
      await next()
    )
    webApp.get("/slow", proc(req: Request, res: Response) =
      res.status(200).send("ok")
    )

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.path = "/slow"
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req
    res.app = webApp

    waitFor webApp.handleRequestForTest(req, res)
    check req.requestCancelled()
    check req.cancelReason == rcrTimeout
    check req.locals.getOrDefault("_timed_out", "") == "1"
    check res.statusCode == 504

  test "jsonify drops late writes for cancelled requests":
    type TinyPayload = object
      ok: bool

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    let req = newRequest(reqNative)
    discard req.notifyRequestTimeout()

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req

    res.jsonify(TinyPayload(ok: true))
    check res.finished == false
    check res.droppedLateWritesCount() == 1

  test "urlencoded parser counts malformed segments toward cap":
    let parser = bodyParser()
    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmPost
    reqNative.headers = toFastMap([("content-type", "application/x-www-form-urlencoded")])
    reqNative.body = repeat("a&", 300)
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmPost
    let res = newResponse(resNative)

    var nextCalled = false
    proc nextProc(): Future[void] {.async.} =
      nextCalled = true
    waitFor parser(req, res, nextProc)
    check nextCalled == false
    check res.statusCode == 413

  test "rate limiter state is isolated per middleware instance":
    let limiterA = rateLimit(maxRequests = 1, windowMs = 60_000)
    let limiterB = rateLimit(maxRequests = 1, windowMs = 60_000)

    proc runLimiter(limiter: AsyncMiddleware): tuple[nextCalled: bool, statusCode: int] =
      var reqNative: HttpRequest
      new(reqNative)
      reqNative.methodKind = hmGet
      reqNative.remoteIp = "198.51.100.77"
      let req = newRequest(reqNative)

      var resNative: HttpResponse
      new(resNative)
      resNative.requestMethod = hmGet
      let res = newResponse(resNative)

      var nextCalled = false
      proc nextProc(): Future[void] {.async.} =
        nextCalled = true
      waitFor limiter(req, res, nextProc)
      (nextCalled: nextCalled, statusCode: res.statusCode)

    check runLimiter(limiterA) == (nextCalled: true, statusCode: 200)
    check runLimiter(limiterB) == (nextCalled: true, statusCode: 200)
    check runLimiter(limiterA) == (nextCalled: false, statusCode: 429)
    check runLimiter(limiterB) == (nextCalled: false, statusCode: 429)
