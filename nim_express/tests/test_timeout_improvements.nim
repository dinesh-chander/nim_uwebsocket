import std/[unittest, asyncdispatch, strutils, times]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/timeout

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

suite "timeout middleware":
  test "handler completing in time succeeds and leaves budget intact":
    let req = newMockRequest()
    let res = newMockResponse()
    var handled = false
    proc fastHandler(r: Request, s: Response): Future[void] {.async.} =
      handled = true
      if not s.finished:
        s.status(200)
        s.send("ok")
    runMiddlewareChain(@[timeout(30000)], req, res, fastHandler)
    check handled
    check res.finished
    check res.statusCode == 200
    check not req.locals.hasKey("_timed_out")
    check req.locals["_timeout_budget_ms"] == "30000"
    check req.locals["_deadline"].len > 0
    check req.locals["_timeout_started_ms"].len > 0
    check not req.requestCancelled()
    check req.lifecycleState == rlsActive
    check requestTimeoutRemainingMs(req) > 0

  test "zero and negative budgets are clamped to 1ms":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[timeout(0)], req, res)
    check req.locals["_timeout_budget_ms"] == "1"

    let req2 = newMockRequest()
    let res2 = newMockResponse()
    runMiddlewareChain(@[timeout(-5)], req2, res2)
    check req2.locals["_timeout_budget_ms"] == "1"

  test "handler exceeding the budget produces 504 and cancels the request":
    let req = newMockRequest()
    let res = newMockResponse()
    proc slowHandler(r: Request, s: Response): Future[void] {.async.} =
      await sleepAsync(200)
      if not s.finished:
        s.status(200)
        s.send("late")
    runMiddlewareChain(@[timeout(1)], req, res, slowHandler)
    check res.finished
    check res.statusCode == 504
    check req.locals["_timed_out"] == "1"
    check req.locals["_timeout_budget_ms"] == "1"
    check req.requestCancelled()
    check req.cancelReason == rcrTimeout
    check requestTimeoutRemainingMs(req) == -1

  test "deadline and start metadata derive from a single clock snapshot":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[timeout(2500)], req, res)
    let deadline = req.locals["_deadline"].parseFloat()
    let startedMs: int64 = req.locals["_timeout_started_ms"].parseInt()
    let budgetMs = req.locals["_timeout_budget_ms"].parseInt()
    check budgetMs == 2500
    let gap = deadline - startedMs.float / 1000.0
    check gap >= 2.5 - 1e-6
    check gap < 2.5 + 0.002

  test "handler exception propagates through the middleware":
    let req = newMockRequest()
    let res = newMockResponse()
    proc failingHandler(r: Request, s: Response): Future[void] {.async.} =
      raise newException(ValueError, "boom")
    var caught = ""
    try:
      runMiddlewareChain(@[timeout(30000)], req, res, failingHandler)
    except CatchableError as e:
      caught = e.msg
    check caught.startsWith("boom")
    check not req.locals.hasKey("_timed_out")
    check not req.requestCancelled()

  test "timeoutPreset maps to the documented budgets":
    let cases: seq[(TimeoutPreset, int)] = @[(tpApiStrict, 5000),
                                            (tpApiDefault, 15000),
                                            (tpLongPoll, 60000)]
    for presetCase in cases:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[timeoutPreset(presetCase[0])], req, res)
      check req.locals["_timeout_budget_ms"] == $presetCase[1]
