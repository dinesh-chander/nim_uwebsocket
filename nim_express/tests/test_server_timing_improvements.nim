import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/server_timing

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

proc enabledTimingOptions(): ServerTimingOptions =
  ServerTimingOptions(enabled: true, productionMode: false)

proc parseServerTimingDur(headerVal: string): float =
  let marker = "total;dur="
  if not headerVal.startsWith(marker):
    return -1.0
  parseFloat(headerVal[marker.len..^1])

suite "serverTiming unit":
  test "defaultServerTimingOptions: production-safe default (ISSUE-1, ISSUE-6)":
    let d = defaultServerTimingOptions()
    check d.enabled == true
    check d.productionMode == true

  test "explicit options are preserved (ISSUE-6)":
    let o = ServerTimingOptions(enabled: false, productionMode: false)
    check o.enabled == false
    check o.productionMode == false

suite "serverTiming integration":
  test "default serverTiming() is a no-op pass-through (ISSUE-1)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[serverTiming()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.locals.getOrDefault("_server_timing_enabled", "") == ""
    check req.locals.getOrDefault("_server_timing_start", "") == ""
    check res.get("server-timing") == ""

  test "serverTiming(false) records enabled flag and start before next (ISSUE-4)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[serverTiming(false)], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.locals.getOrDefault("_server_timing_enabled", "") == "1"
    let startRaw = req.locals.getOrDefault("_server_timing_start", "")
    check startRaw.len > 0
    check parseInt(startRaw) >= 0

  test "serverTiming(true) disables timing (ISSUE-1)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[serverTiming(true)], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.locals.getOrDefault("_server_timing_enabled", "") == ""
    check req.locals.getOrDefault("_server_timing_start", "") == ""

  test "enabled=false disables timing even with productionMode=false (ISSUE-1)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(
      @[serverTiming(ServerTimingOptions(enabled: false, productionMode: false))],
      req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.locals.getOrDefault("_server_timing_enabled", "") == ""
    check req.locals.getOrDefault("_server_timing_start", "") == ""

  test "nil request passes through without crashing (ISSUE-2)":
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[serverTiming(false)], nil, res, flagHandler(addr nextCalled))
    check nextCalled

  test "nil req.locals passes through without crashing (ISSUE-2)":
    let req = newMockRequest()
    req.locals = nil
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[serverTiming(false)], req, res, flagHandler(addr nextCalled))
    check nextCalled

  test "end-to-end: res.send() emits Server-Timing header with non-negative dur (ISSUE-4)":
    let req = newMockRequest()
    let res = newMockResponse()
    res.request = req
    var nextCalled = false
    runMiddlewareChain(@[serverTiming(enabledTimingOptions())], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.finished
    let headerVal = res.get("server-timing")
    check headerVal.startsWith("total;dur=")
    let dur = parseServerTimingDur(headerVal)
    check dur >= 0.0

  test "end-to-end: disabled middleware emits no Server-Timing header (ISSUE-1)":
    let req = newMockRequest()
    let res = newMockResponse()
    res.request = req
    var nextCalled = false
    runMiddlewareChain(@[serverTiming()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.finished
    check res.get("server-timing") == ""

  test "works when placed before another middleware in the chain (ISSUE-4)":
    let req = newMockRequest()
    let res = newMockResponse()
    res.request = req
    var innerCalled = false
    let inner: AsyncMiddleware =
      proc(r: Request, s: Response, next: NextProc): Future[void] {.async.} =
        innerCalled = true
        await next()
    var nextCalled = false
    runMiddlewareChain(
      @[serverTiming(enabledTimingOptions()), inner],
      req, res, flagHandler(addr nextCalled))
    check innerCalled
    check nextCalled
    check req.locals.getOrDefault("_server_timing_enabled", "") == "1"
    let startRaw = req.locals.getOrDefault("_server_timing_start", "")
    check startRaw.len > 0
    check parseInt(startRaw) >= 0
    let dur = parseServerTimingDur(res.get("server-timing"))
    check dur >= 0.0
