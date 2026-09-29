import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/response_time

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

proc timingProbeHandler(probe: ptr string): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    probe[] = res.get("X-Response-Time")
    if not res.finished:
      res.status(200)
      res.send("ok")

# Splits "12.345ms" into (true, 12.345); validates the "<digits>.<3 digits>ms"
# structure produced by formatFloat(ms, ffDecimal, 3) & "ms".
proc parseMsValue(value: string): (bool, float) =
  if value.len <= 2 or value[^2] != 'm' or value[^1] != 's':
    return (false, 0.0)
  let num = value[0 ..^ 3]
  let dot = num.find('.')
  if dot < 1 or num[dot + 1 ..^ 1].len != 3:
    return (false, 0.0)
  var intPart = 0.0
  for c in num[0 ..< dot]:
    if c notin {'0'..'9'}:
      return (false, 0.0)
    intPart = intPart * 10.0 + (ord(c) - ord('0')).float
  var fracPart = 0.0
  for c in num[dot + 1 ..^ 1]:
    if c notin {'0'..'9'}:
      return (false, 0.0)
    fracPart = fracPart * 10.0 + (ord(c) - ord('0')).float
  result = (true, intPart + fracPart / 1000.0)

suite "response_time unit":
  test "defaultResponseTimeOptions uses the default header name (ISSUE-4)":
    let d = defaultResponseTimeOptions()
    check d.headerName == defaultResponseTimeHeaderName
    check d.headerName == "X-Response-Time"

  test "normalizeResponseTimeHeaderName passes valid tokens through (ISSUE-4)":
    check normalizeResponseTimeHeaderName("X-Response-Time") == "X-Response-Time"
    check normalizeResponseTimeHeaderName("x-custom-time") == "x-custom-time"
    check normalizeResponseTimeHeaderName("X_Custom-Time.9") == "X_Custom-Time.9"

  test "normalizeResponseTimeHeaderName falls back on empty/invalid names (ISSUE-4)":
    check normalizeResponseTimeHeaderName("") == defaultResponseTimeHeaderName
    check normalizeResponseTimeHeaderName("bad header") == defaultResponseTimeHeaderName
    check normalizeResponseTimeHeaderName("bad\thdr") == defaultResponseTimeHeaderName
    check normalizeResponseTimeHeaderName("a/b") == defaultResponseTimeHeaderName
    check normalizeResponseTimeHeaderName("Set-Cookie") == "Set-Cookie"

suite "response_time integration":
  test "default middleware sets X-Response-Time in <ms>.<3 digits>ms format":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[responseTime()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.finished
    let v = res.get("X-Response-Time")
    check v.len > 0
    var parsedOk: bool
    var ms: float
    (parsedOk, ms) = parseMsValue(v)
    check parsedOk
    check ms >= 0.0

  test "custom header name is honored and default is not set":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(
      @[responseTime(ResponseTimeOptions(headerName: "X-Custom-Time"))],
      req, res, flagHandler(addr nextCalled))
    check nextCalled
    let v = res.get("X-Custom-Time")
    check v.len > 0
    var parsedOk: bool
    var ms: float
    (parsedOk, ms) = parseMsValue(v)
    check parsedOk
    check res.get("X-Response-Time").len == 0

  test "invalid custom header name falls back to default at construction (ISSUE-4)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(
      @[responseTime(ResponseTimeOptions(headerName: "bad header"))],
      req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.get("X-Response-Time").len > 0

  test "header is absent during next() and written at finalization (ISSUE-5)":
    let req = newMockRequest()
    let res = newMockResponse()
    var duringNext = ""
    runMiddlewareChain(@[responseTime()], req, res, timingProbeHandler(addr duringNext))
    check duringNext == ""
    let v = res.get("X-Response-Time")
    check v.len > 0
    var parsedOk: bool
    var ms: float
    (parsedOk, ms) = parseMsValue(v)
    check parsedOk

  test "header survives alongside an upstream middleware in the chain":
    let req = newMockRequest()
    let res = newMockResponse()
    res.set("X-Upstream", "1")
    var nextCalled = false
    let upstream: AsyncMiddleware =
      proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
        await next()
    runMiddlewareChain(@[upstream, responseTime()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.get("X-Upstream") == "1"
    var parsedOk: bool
    var ms: float
    (parsedOk, ms) = parseMsValue(res.get("X-Response-Time"))
    check parsedOk
