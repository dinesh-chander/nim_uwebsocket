import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/concurrency_guard

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

suite "concurrency_guard unit":
  test "concurrencyGuardRejectStatus clamps to body-bearing 4xx/5xx (ISSUE-4)":
    check concurrencyGuardRejectStatus(200) == 503
    check concurrencyGuardRejectStatus(304) == 503
    check concurrencyGuardRejectStatus(0) == 503
    check concurrencyGuardRejectStatus(600) == 503
    check concurrencyGuardRejectStatus(400) == 400
    check concurrencyGuardRejectStatus(429) == 429
    check concurrencyGuardRejectStatus(500) == 500
    check concurrencyGuardRejectStatus(503) == 503
    check concurrencyGuardRejectStatus(599) == 599

  test "concurrencyGuardRetryAfter clamps to >= 0 and preserves 0 (ISSUE-3)":
    check concurrencyGuardRetryAfter(0) == 0
    check concurrencyGuardRetryAfter(-5) == 0
    check concurrencyGuardRetryAfter(30) == 30

  test "newConcurrencyGuardState clamps maxInflight to >= 1":
    check newConcurrencyGuardState(0).maxInflight == 1
    check newConcurrencyGuardState(-3).maxInflight == 1
    check newConcurrencyGuardState(1024).maxInflight == 1024

  test "accessors are nil-safe":
    check currentInflight(nil) == 0'i64
    check rejectedCount(nil) == 0'i64
    resetConcurrencyGuardState(nil)

  test "reset at quiescence clears counters (ISSUE-1)":
    let state = newConcurrencyGuardState(10)
    resetConcurrencyGuardState(state)
    check currentInflight(state) == 0'i64
    check rejectedCount(state) == 0'i64

suite "concurrency_guard integration":
  test "below-limit request passes through and the counter returns to 0 (regression)":
    let state = newConcurrencyGuardState(8)
    let mw = concurrencyGuard(state)
    var nextRan = false
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check nextRan
    check res.statusCode == 200
    check res.finished
    check currentInflight(state) == 0'i64

  test "request above the limit is rejected with 503, Retry-After and a body":
    let state = newConcurrencyGuardState(maxInflight = 1)
    let mw = concurrencyGuard(state, statusCode = 503, retryAfterSeconds = 2, message = "busy")
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    var next2Called = false
    let gate = newFuture[void]("cg-gate")
    proc next1(): Future[void] {.async.} =
      await gate
    proc next2(): Future[void] {.async.} =
      next2Called = true
    proc scenario(): Future[void] {.async.} =
      let f1 = mw(req1, res1, next1)
      await sleepAsync(10)
      await mw(req2, res2, next2)
      gate.complete()
      await f1
    waitFor scenario()
    check not next2Called
    check res2.statusCode == 503
    check res2.finished
    check res2.get("Retry-After") == "2"
    check rejectedCount(state) == 1'i64
    check currentInflight(state) == 0'i64
    check res2.native.capturedRaw.find("busy") >= 0

  test "retryAfterSeconds = 0 still emits Retry-After: 0 (ISSUE-3)":
    let state = newConcurrencyGuardState(maxInflight = 1)
    let mw = concurrencyGuard(state, retryAfterSeconds = 0)
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    let gate = newFuture[void]("cg-gate2")
    proc next1(): Future[void] {.async.} =
      await gate
    proc scenario(): Future[void] {.async.} =
      let f1 = mw(req1, res1, next1)
      await sleepAsync(10)
      await mw(req2, res2, proc(): Future[void] {.async.} = discard)
      gate.complete()
      await f1
    waitFor scenario()
    check res2.statusCode == 503
    check res2.get("Retry-After") == "0"

  test "statusCode = 204 is clamped to 503 (ISSUE-4)":
    let state = newConcurrencyGuardState(maxInflight = 1)
    let mw = concurrencyGuard(state, statusCode = 204)
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    let gate = newFuture[void]("cg-gate3")
    proc next1(): Future[void] {.async.} =
      await gate
    proc scenario(): Future[void] {.async.} =
      let f1 = mw(req1, res1, next1)
      await sleepAsync(10)
      await mw(req2, res2, proc(): Future[void] {.async.} = discard)
      gate.complete()
      await f1
    waitFor scenario()
    check res2.statusCode == 503

  test "rejection does not overwrite an already-finished response (ISSUE-5)":
    let state = newConcurrencyGuardState(maxInflight = 1)
    let mw = concurrencyGuard(state, statusCode = 503, retryAfterSeconds = 9)
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    res2.finished = true
    res2.statusCode = 200
    let gate = newFuture[void]("cg-gate4")
    proc next1(): Future[void] {.async.} =
      await gate
    proc scenario(): Future[void] {.async.} =
      let f1 = mw(req1, res1, next1)
      await sleepAsync(10)
      await mw(req2, res2, proc(): Future[void] {.async.} = discard)
      gate.complete()
      await f1
    waitFor scenario()
    check res2.statusCode == 200
    check res2.get("Retry-After").len == 0

  test "reset during flight is a no-op; the counter returns to 0, not negative (ISSUE-1)":
    let state = newConcurrencyGuardState(maxInflight = 1)
    let mw = concurrencyGuard(state)
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    var didResetDuringFlight = false
    var inflightDuringReset: int64 = -12345
    proc next1(): Future[void] {.async.} =
      resetConcurrencyGuardState(state)
      inflightDuringReset = currentInflight(state)
      didResetDuringFlight = true
      if not res1.finished:
        res1.status(200)
        res1.send("ok")
    waitFor mw(req1, res1, next1)
    check didResetDuringFlight
    check inflightDuringReset == 1'i64
    check currentInflight(state) == 0'i64
