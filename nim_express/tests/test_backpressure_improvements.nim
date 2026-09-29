import std/[unittest, asyncdispatch, json, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/backpressure

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

proc okHandler(req: Request, res: Response): Future[void] {.async.} =
  res.status(200)
  res.send("ok")

proc slowHandler(req: Request, res: Response): Future[void] {.async.} =
  await sleepAsync(25)
  res.status(200)
  res.send("ok")

proc flagHandler(flag: ptr bool): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    flag[] = true
    if not res.finished:
      res.status(200)
      res.send("ok")

suite "backpressure unit":
  test "defaultBackpressureOptions returns documented defaults":
    let opts = defaultBackpressureOptions()
    check opts.maxConnections == 10000
    check opts.maxPendingResponses == 5000
    check opts.maxResponseTimeMs == 30000
    check opts.retryAfterSeconds == 5
    check opts.loadMetricsHook == nil

  test "newBackpressureState starts with zeroed counters":
    let state = newBackpressureState()
    check activeConnectionCount(state) == 0
    check pendingResponseCount(state) == 0
    check shedRequestCount(state) == 0

  test "counters handle nil state":
    check activeConnectionCount(nil) == 0
    check pendingResponseCount(nil) == 0
    check shedRequestCount(nil) == 0

suite "backpressure integration":
  test "normal path returns 200 and balances counters (regression)":
    let state = newBackpressureState()
    let mw = backpressure(state)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200
    check res.finished
    check res.get("Retry-After") == ""
    check activeConnectionCount(state) == 0
    check pendingResponseCount(state) == 0
    check shedRequestCount(state) == 0

  test "hook raising CatchableError falls through to handler without writing a response":
    let state = newBackpressureState()
    var handlerRan = false
    let mw = backpressure(state, BackpressureOptions(
      maxConnections: 10000,
      maxPendingResponses: 5000,
      maxResponseTimeMs: 30000,
      retryAfterSeconds: 5,
      loadMetricsHook: proc(): tuple[shouldShed: bool, retryAfterSeconds: int] =
        raise newException(ValueError, "hook boom")
    ))
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr handlerRan))
    check handlerRan
    check res.statusCode == 200
    check res.finished
    check res.get("Retry-After") == ""
    check activeConnectionCount(state) == 0
    check pendingResponseCount(state) == 0
    check shedRequestCount(state) == 0

  test "hook shed returns 503 with Retry-After, exact JSON body, no handler call":
    let state = newBackpressureState()
    var handlerRan = false
    let mw = backpressure(state, BackpressureOptions(
      maxConnections: 10000,
      maxPendingResponses: 5000,
      maxResponseTimeMs: 30000,
      retryAfterSeconds: 5,
      loadMetricsHook: proc(): tuple[shouldShed: bool, retryAfterSeconds: int] =
        (shouldShed: true, retryAfterSeconds: 0)
    ))
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr handlerRan))
    check not handlerRan
    check res.statusCode == 503
    check res.finished
    check res.get("Retry-After") == "5"
    let raw = res.native.capturedRaw
    let bodyStart = raw.find("\r\n\r\n")
    check bodyStart >= 0
    check raw[bodyStart + 4 ..^ 1] == """{"error":"Service Unavailable"}"""
    check activeConnectionCount(state) == 0
    check pendingResponseCount(state) == 0
    check shedRequestCount(state) == 1

  test "hook retryAfterSeconds overrides configured Retry-After":
    let state = newBackpressureState()
    let mw = backpressure(state, BackpressureOptions(
      maxConnections: 10000,
      maxPendingResponses: 5000,
      maxResponseTimeMs: 30000,
      retryAfterSeconds: 5,
      loadMetricsHook: proc(): tuple[shouldShed: bool, retryAfterSeconds: int] =
        (shouldShed: true, retryAfterSeconds: 7)
    ))
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.statusCode == 503
    check res.get("Retry-After") == "7"

  test "configured retryAfterSeconds clamped to at least 1 second":
    let state = newBackpressureState()
    let mw = backpressure(state, BackpressureOptions(
      maxConnections: 10000,
      maxPendingResponses: 5000,
      maxResponseTimeMs: 30000,
      retryAfterSeconds: 0,
      loadMetricsHook: proc(): tuple[shouldShed: bool, retryAfterSeconds: int] =
        (shouldShed: true, retryAfterSeconds: 0)
    ))
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.statusCode == 503
    check res.get("Retry-After") == "1"

  test "maxConnections exceeded sheds concurrent request with 503":
    let state = newBackpressureState()
    let mw = backpressure(state, BackpressureOptions(
      maxConnections: 1,
      maxPendingResponses: 5000,
      maxResponseTimeMs: 30000,
      retryAfterSeconds: 5,
      loadMetricsHook: nil
    ))
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    let f1 = startMiddlewareChain(@[mw], req1, res1, slowHandler)
    let f2 = startMiddlewareChain(@[mw], req2, res2, okHandler)
    waitFor f2
    check res2.statusCode == 503
    check res2.finished
    check res2.get("Retry-After") == "5"
    let raw = res2.native.capturedRaw
    let bodyStart = raw.find("\r\n\r\n")
    check bodyStart >= 0
    check raw[bodyStart + 4 ..^ 1] == """{"error":"Service Unavailable"}"""
    waitFor f1
    check res1.statusCode == 200
    check res1.finished
    check activeConnectionCount(state) == 0
    check pendingResponseCount(state) == 0
    check shedRequestCount(state) == 1

  test "maxPendingResponses exceeded sheds concurrent request with 503":
    let state = newBackpressureState()
    let mw = backpressure(state, BackpressureOptions(
      maxConnections: 10000,
      maxPendingResponses: 1,
      maxResponseTimeMs: 30000,
      retryAfterSeconds: 5,
      loadMetricsHook: nil
    ))
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    let f1 = startMiddlewareChain(@[mw], req1, res1, slowHandler)
    let f2 = startMiddlewareChain(@[mw], req2, res2, okHandler)
    waitFor f2
    check res2.statusCode == 503
    check res2.finished
    check res2.get("Retry-After") == "5"
    waitFor f1
    check res1.statusCode == 200
    check activeConnectionCount(state) == 0
    check pendingResponseCount(state) == 0
    check shedRequestCount(state) == 1

  test "maxResponseTimeMs exceeded sheds request after slow completion":
    let state = newBackpressureState()
    let mw = backpressure(state, BackpressureOptions(
      maxConnections: 10000,
      maxPendingResponses: 5000,
      maxResponseTimeMs: 5,
      retryAfterSeconds: 5,
      loadMetricsHook: nil
    ))
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, slowHandler)
    check res1.statusCode == 200
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, okHandler)
    check res2.statusCode == 503
    check res2.finished
    check res2.get("Retry-After") == "5"

  test "counters decrement when downstream handler raises":
    let state = newBackpressureState()
    let mw = backpressure(state)
    let req = newMockRequest()
    let res = newMockResponse()
    expect ValueError:
      runMiddlewareChain(@[mw], req, res,
        proc(r: Request, s: Response): Future[void] {.async.} =
          raise newException(ValueError, "handler boom"))
    check activeConnectionCount(state) == 0
    check pendingResponseCount(state) == 0

  test "resetBackpressureState clears counters":
    let state = newBackpressureState()
    let mw = backpressure(state, BackpressureOptions(
      maxConnections: 1,
      maxPendingResponses: 5000,
      maxResponseTimeMs: 30000,
      retryAfterSeconds: 5,
      loadMetricsHook: nil
    ))
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    let f1 = startMiddlewareChain(@[mw], req1, res1, slowHandler)
    let f2 = startMiddlewareChain(@[mw], req2, res2, okHandler)
    waitFor f2
    waitFor f1
    check shedRequestCount(state) == 1
    resetBackpressureState(state)
    check activeConnectionCount(state) == 0
    check pendingResponseCount(state) == 0
    check shedRequestCount(state) == 0

  test "convenience overload exposes maxResponseTimeMs":
    let mw = backpressure(10000, 5000, 5)
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, slowHandler)
    check res1.statusCode == 200
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, okHandler)
    check res2.statusCode == 503
    check res2.get("Retry-After") == "5"
