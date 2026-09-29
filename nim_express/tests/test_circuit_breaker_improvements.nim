import std/[unittest, asyncdispatch, json, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/circuit_breaker

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

proc status500Handler(req: Request, res: Response): Future[void] {.async.} =
  res.status(500)
  res.send("internal error")

proc boomHandler(req: Request, res: Response): Future[void] {.async.} =
  raise newException(ValueError, "boom")

suite "circuit_breaker unit":
  test "circuitBreakerRejectBody is generic JSON with no circuit name (ISSUE-6)":
    check circuitBreakerRejectBody == """{"error":"Service unavailable","state":"open"}"""
    check circuitBreakerRejectBody.find("circuit") < 0
    check circuitBreakerRejectBody.find("name") < 0
    let j = parseJson(circuitBreakerRejectBody)
    check j.hasKey("error")
    check j["error"].getStr() == "Service unavailable"
    check j.hasKey("state")
    check j["state"].getStr() == "open"
    check not j.hasKey("circuit")
    check not j.hasKey("name")

  test "consecutive-failure semantics: success in closed resets the counter (ISSUE-4)":
    let cb = newCircuitBreaker("test", failureThreshold = 3, successThreshold = 2, timeoutMs = 30000)
    check cb.state == csClosed
    cb.recordFailure()
    cb.recordFailure()
    check cb.state == csClosed
    check cb.isAllowed()
    cb.recordSuccess()
    cb.recordFailure()
    cb.recordFailure()
    check cb.state == csClosed
    cb.recordFailure()
    check cb.state == csOpen
    check not cb.isAllowed()
    cb.reset()
    check cb.state == csClosed
    check cb.isAllowed()

  test "newCircuitBreaker clamps invalid options to defaults":
    let cb = newCircuitBreaker("x", failureThreshold = 0, successThreshold = 0, timeoutMs = 10)
    check cb.options.failureThreshold == 5
    check cb.options.successThreshold == 2
    check cb.options.timeoutMs == 30000

suite "circuit_breaker integration":
  test "open circuit rejects with 503, Retry-After and a generic body (ISSUE-6)":
    let cb = newCircuitBreaker("payment-gateway-prod", failureThreshold = 1, successThreshold = 2, timeoutMs = 30000)
    cb.recordFailure()
    check cb.state == csOpen
    let mw = circuitBreakerMiddleware(cb)
    var nextRan = false
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check not nextRan
    check res.statusCode == 503
    check res.finished
    check res.get("Retry-After") == "30"
    let raw = res.native.capturedRaw
    check raw.find(circuitBreakerRejectBody) >= 0
    check raw.find("payment-gateway-prod") < 0

  test "closed circuit passes a 2xx handler through (regression)":
    let cb = newCircuitBreaker("ok", failureThreshold = 3, successThreshold = 2, timeoutMs = 30000)
    let mw = circuitBreakerMiddleware(cb)
    var nextRan = false
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check nextRan
    check res.statusCode == 200
    check res.finished
    check cb.state == csClosed

  test "three consecutive 500 responses open the circuit, next request gets 503":
    let cb = newCircuitBreaker("flaky", failureThreshold = 3, successThreshold = 2, timeoutMs = 30000)
    let mw = circuitBreakerMiddleware(cb)
    for i in 0 ..< 3:
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, status500Handler)
      check res.statusCode == 500
      check res.finished
    check cb.state == csOpen
    var nextRan = false
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check not nextRan
    check res.statusCode == 503
    check res.finished
    check res.get("Retry-After") == "30"

  test "handler exception records a failure and re-raises (ISSUE-2)":
    let cb = newCircuitBreaker("ex", failureThreshold = 1, successThreshold = 2, timeoutMs = 30000)
    let mw = circuitBreakerMiddleware(cb)
    let req = newMockRequest()
    let res = newMockResponse()
    var caught = false
    try:
      runMiddlewareChain(@[mw], req, res, boomHandler)
    except ValueError:
      caught = true
    check caught
    check cb.state == csOpen
