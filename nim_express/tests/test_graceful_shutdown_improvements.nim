## Tests for graceful_shutdown middleware review fixes.
##
## Covers (see reviews/findings/graceful_shutdown.review.md):
##   ISSUE-1  shutdown hooks run exactly once (exchange guard)
##   ISSUE-2  monotonic clock for the drain timeout
##   ISSUE-3  SA_RESTART set on the installed signal handler
##   ISSUE-8  Defect in a hook propagates (no longer swallowed)
##   ISSUE-11 health vs non-health path comparison (no `$req.path` copy)
##   ISSUE-12 timeout comparison uses >=
##
## Hooks run on a dedicated thread (ISSUE-6), so tests that assert hook side
## effects wait for hooksCompleted(state) before checking.

import std/[unittest, asyncdispatch, strutils, atomics, monotimes, times]
when defined(posix):
  import std/posix
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/graceful_shutdown

# ---------------------------------------------------------------------------
# Mock request/response harness (mirrors test_csrf_improvements.nim lines 8-111)
# ---------------------------------------------------------------------------

proc newMockHttpRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[]
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
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[]
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr, headerMap)
  result = newRequest(native)

proc newMockResponse(): Response =
  new(result)
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = hmGet
  nativeRes.connectionClose = false
  result.native = nativeRes
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

proc startMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
): Future[void] =
  var idx = 0
  proc finalHandler(r: Request, s: Response): Future[void] {.async.} =
    if handler != nil:
      await handler(r, s)
    elif not s.finished:
      s.status(200)
  proc advance(): Future[void] {.async.} =
    if idx < middlewares.len:
      let current = middlewares[idx]
      inc idx
      await current(req, res, advance)
    else:
      await finalHandler(req, res)
  result = advance()

proc runMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
) =
  waitFor startMiddlewareChain(middlewares, req, res, handler)

proc flagHandler(flag: ptr bool): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    flag[] = true
    if not res.finished:
      res.status(200)
      res.send("ok")

## The response body is handed to the native writer separately from the header
## buffer, so it is only visible in the captured raw response.
proc capturedResponseBody(res: Response): string =
  let raw = res.native.capturedRaw
  let bodyStart = raw.find("\r\n\r\n")
  if bodyStart >= 0:
    raw[bodyStart + 4 ..^ 1]
  else:
    ""

# Shared counter incremented by shutdown hooks (thread-safe for the async loop).
var gHookRuns {.global.}: Atomic[int]

proc waitForHooksCompleted(state: GracefulShutdownState, timeoutMs: int = 5000) =
  let start = getMonoTime()
  while not hooksCompleted(state):
    if getMonoTime() - start > initDuration(milliseconds = timeoutMs.int64):
      break
    waitFor sleepAsync(10)

# ---------------------------------------------------------------------------
# Unit tests: pure logic / state machine / predicates
# ---------------------------------------------------------------------------

suite "graceful_shutdown unit":
  test "default options expose sensible production values":
    let d = defaultGracefulShutdownOptions()
    check d.drainTimeoutMs == 30000
    check d.healthPath == "/health"
    check d.forceExitOnTimeout == false
    check d.shutdownHooks.len == 0

  test "new state starts idle: not shutting down, zero inflight, not drained":
    var state = newGracefulShutdownState()
    check not isShuttingDown(state)
    check inflightCount(state) == 0'i64
    check not isDrainComplete(state)

  test "nil state predicates are safe (no access violation)":
    check not isShuttingDown(nil)
    check inflightCount(nil) == 0'i64
    check not isDrainComplete(nil)

  test "initiateShutdown sets the flag and is idempotent":
    var state = newGracefulShutdownState()
    check not isShuttingDown(state)
    initiateShutdown(state)
    check isShuttingDown(state)
    check not isDrainComplete(state)
    initiateShutdown(state)
    check isShuttingDown(state)
    check not isDrainComplete(state)

# ---------------------------------------------------------------------------
# Integration tests: through the middleware chain
# ---------------------------------------------------------------------------

suite "graceful_shutdown integration":
  test "normal request passes through and inflight is balanced":
    var state = newGracefulShutdownState()
    let mw = gracefulShutdown(state, installSignalHandlers = false)
    let req = newMockRequest(pathVal = "/")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check inflightCount(state) == 0'i64

  test "shutdown returns 503 + Connection: close for non-health path (ISSUE-11)":
    var state = newGracefulShutdownState()
    let mw = gracefulShutdown(state, installSignalHandlers = false)
    initiateShutdown(state)
    let req = newMockRequest(pathVal = "/api/items")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.statusCode == 503
    check res.get("connection") == "close"
    let body = capturedResponseBody(res)
    check body.find("shutting_down") >= 0
    check body.find("Service Unavailable") >= 0

  test "shutdown health path returns the distinct shutting_down payload (ISSUE-11)":
    var state = newGracefulShutdownState()
    let mw = gracefulShutdown(state, installSignalHandlers = false)
    initiateShutdown(state)
    let req = newMockRequest(pathVal = "/health")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.statusCode == 503
    check res.get("connection") == "close"
    let body = capturedResponseBody(res)
    check body.find("shutting_down") >= 0
    # Health payload is {"status":"shutting_down"}, not the error envelope.
    check body.find("Service Unavailable") < 0

  test "shutdown hooks run exactly once across repeated drain-complete checks (ISSUE-1)":
    gHookRuns.store(0)
    var state = newGracefulShutdownState(GracefulShutdownOptions(
      drainTimeoutMs: 30000,
      healthPath: "/health",
      shutdownHooks: @[proc() {.closure, gcsafe.} = discard gHookRuns.fetchAdd(1)],
      forceExitOnTimeout: false))
    let mw = gracefulShutdown(state, installSignalHandlers = false)
    initiateShutdown(state)
    # Each request during shutdown re-enters checkDrainStatus; the exchange
    # guard ensures the hooks fire only from the winning caller.
    for i in 0 ..< 5:
      let req = newMockRequest(pathVal = "/api/item" & $i)
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res)
      check res.statusCode == 503
    waitForHooksCompleted(state)
    check gHookRuns.load() == 1
    check isDrainComplete(state)

  test "drain timeout fires when in-flight requests exceed the budget (ISSUE-2, ISSUE-12)":
    gHookRuns.store(0)
    # drainTimeoutMs is clamped to a 1000ms minimum; the request stays
    # in-flight long enough for the monotonic-clock timeout to trip.
    var state = newGracefulShutdownState(GracefulShutdownOptions(
      drainTimeoutMs: 1000,
      healthPath: "/health",
      shutdownHooks: @[proc() {.closure, gcsafe.} = discard gHookRuns.fetchAdd(1)],
      forceExitOnTimeout: false))
    let mw = gracefulShutdown(state, installSignalHandlers = false)
    let req = newMockRequest(pathVal = "/slow")
    let res = newMockResponse()
    var nextCalled = false
    let handler = proc(r: Request, s: Response): Future[void] {.async.} =
      nextCalled = true
      initiateShutdown(state)
      await sleepAsync(1500)
      if not s.finished:
        s.status(200)
        s.send("slow-ok")
    runMiddlewareChain(@[mw], req, res, handler)
    waitForHooksCompleted(state)
    check nextCalled
    check isDrainComplete(state)
    check gHookRuns.load() == 1

  test "CatchableError in a shutdown hook is caught, not propagated (regression)":
    gHookRuns.store(0)
    var state = newGracefulShutdownState(GracefulShutdownOptions(
      drainTimeoutMs: 30000,
      healthPath: "/health",
      shutdownHooks: @[proc() {.closure, gcsafe.} =
        discard gHookRuns.fetchAdd(1)
        raise newException(ValueError, "hook failed")],
      forceExitOnTimeout: false))
    let mw = gracefulShutdown(state, installSignalHandlers = false)
    let req = newMockRequest(pathVal = "/")
    let res = newMockResponse()
    var nextCalled = false
    let handler = proc(r: Request, s: Response): Future[void] {.async.} =
      nextCalled = true
      initiateShutdown(state)
      if not s.finished:
        s.status(200)
        s.send("ok")
    # Must not raise: the CatchableError is swallowed inside runShutdownHooks.
    runMiddlewareChain(@[mw], req, res, handler)
    waitForHooksCompleted(state)
    check nextCalled
    check gHookRuns.load() == 1
    check isDrainComplete(state)

  test "signal flag triggers shutdown via the drain loop":
    resetGracefulShutdownSignalForTest()
    var state = newGracefulShutdownState()
    let mw = gracefulShutdown(state, installSignalHandlers = false)
    check mw != nil
    check not isShuttingDown(state)
    markGracefulShutdownSignalForTest()
    waitFor sleepAsync(300)
    check isShuttingDown(state)
    resetGracefulShutdownSignalForTest()

  when defined(posix):
    test "SA_RESTART is set on the installed signal handler (ISSUE-3)":
      resetGracefulShutdownSignalForTest()
      proc noopProbe(x: cint) {.noconv.} =
        discard x
      # Save the pre-existing SIGTERM handler so we can restore it.
      var original: Sigaction
      var cap: Sigaction
      cap.sa_handler = noopProbe
      cap.sa_flags = 0
      discard sigemptyset(cap.sa_mask)
      discard sigaction(SIGTERM, cap, addr original)

      let state = newGracefulShutdownState()
      let mw = gracefulShutdown(state, installSignalHandlers = true)
      check mw != nil

      # Install a probe and capture the handler the middleware installed.
      var installed: Sigaction
      var cap2: Sigaction
      cap2.sa_handler = noopProbe
      cap2.sa_flags = 0
      discard sigemptyset(cap2.sa_mask)
      discard sigaction(SIGTERM, cap2, addr installed)
      check (installed.sa_flags and SA_RESTART) != 0

      # Restore the original handler.
      var tmp: Sigaction
      discard sigaction(SIGTERM, original, addr tmp)

  test "Defect in a shutdown hook propagates from runShutdownHooks (ISSUE-8)":
    # Hooks run on a dedicated thread, so propagation is verified by invoking
    # runShutdownHooks directly on the calling thread: a Defect must escape
    # (only CatchableError is swallowed).
    var state = newGracefulShutdownState(GracefulShutdownOptions(
      drainTimeoutMs: 30000,
      healthPath: "/health",
      shutdownHooks: @[proc() {.closure, gcsafe.} =
        raise newException(OverflowDefect, "hook defect")],
      forceExitOnTimeout: false))
    var caughtDefect = false
    try:
      state.runShutdownHooks()
    except Defect:
      caughtDefect = true
    check caughtDefect
