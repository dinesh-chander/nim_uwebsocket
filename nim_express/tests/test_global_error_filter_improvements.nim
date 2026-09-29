import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/global_error_filter

type
  CustomErr* = object of CatchableError

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

proc capturedResponseBody(res: Response): string =
  let raw = res.native.capturedRaw
  let bodyStart = raw.find("\r\n\r\n")
  if bodyStart >= 0:
    raw[bodyStart + 4 ..^ 1]
  else:
    ""

let valueCrashHandler = proc(req: Request, res: Response): Future[void] {.async.} =
  raise newException(ValueError, "boom")

let customCrashHandler = proc(req: Request, res: Response): Future[void] {.async.} =
  raise newException(CustomErr, "custom failure")

let overflowCrashHandler = proc(req: Request, res: Response): Future[void] {.async.} =
  raise newException(OverflowDefect, "integer overflow")

let okHandler = proc(req: Request, res: Response): Future[void] {.async.} =
  if not res.finished:
    res.status(200)
    res.send("ok")

suite "global_error_filter unit":
  test "defaultGlobalErrorFilterOptions returns safe defaults":
    let opts = defaultGlobalErrorFilterOptions()
    check opts.filters.len == 0
    check opts.fallbackStatusCode == 500
    check opts.logUnhandled == true

  test "newExceptionFilter stores all fields":
    let h = proc(err: ref Exception, req: Req, res: Res): bool = false
    let f = newExceptionFilter("test", h, 42, "TestErr")
    check f.name == "test"
    check f.priority == 42
    check f.exceptionType == "TestErr"
    check f.handler != nil

  test "builtinFilters returns 5 filters in descending priority order (ISSUE-9)":
    let filters = builtinFilters()
    check filters.len == 5
    check filters[0].name == "ValueError"
    check filters[0].priority == 100
    check filters[1].name == "KeyError"
    check filters[1].priority == 90
    check filters[2].name == "IOError"
    check filters[2].priority == 70
    check filters[3].name == "OSError"
    check filters[3].priority == 60
    check filters[4].name == "JsonParsingError"
    check filters[4].priority == 50
    for f in filters:
      check f.handler != nil

  test "valueErrorFilter handles ValueError with static body (ISSUE-4)":
    let f = valueErrorFilter()
    let req = newMockRequest()
    let res = newMockResponse()
    let err = newException(ValueError, "bad value")
    check f.handler(err, req, res) == true
    check res.statusCode == 400
    check res.finished
    check capturedResponseBody(res) == """{"error":"Bad Request"}"""

  test "valueErrorFilter ignores non-ValueError":
    let f = valueErrorFilter()
    let req = newMockRequest()
    let res = newMockResponse()
    let err = newException(RangeError, "range")
    check f.handler(err, req, res) == false
    check not res.finished

  test "keyErrorFilter handles KeyError with static body (ISSUE-4)":
    let f = keyErrorFilter()
    let req = newMockRequest()
    let res = newMockResponse()
    let err = newException(KeyError, "missing")
    check f.handler(err, req, res) == true
    check res.statusCode == 400
    check res.finished
    check capturedResponseBody(res) == """{"error":"Bad Request"}"""

  test "ioErrorFilter maps IOError to 502 (ISSUE-4)":
    let f = ioErrorFilter()
    let req = newMockRequest()
    let res = newMockResponse()
    let err = newException(IOError, "io failure")
    check f.handler(err, req, res) == true
    check res.statusCode == 502
    check res.finished
    check capturedResponseBody(res) == """{"error":"Bad Gateway"}"""

  test "osErrorFilter maps OSError to 503 (ISSUE-4)":
    let f = osErrorFilter()
    let req = newMockRequest()
    let res = newMockResponse()
    let err = newException(OSError, "os failure")
    check f.handler(err, req, res) == true
    check res.statusCode == 503
    check res.finished
    check capturedResponseBody(res) == """{"error":"Service Unavailable"}"""

  test "jsonParsingErrorFilter uses plain error shape without detail (ISSUE-7)":
    let f = jsonParsingErrorFilter()
    let req = newMockRequest()
    let res = newMockResponse()
    let err = newException(JsonParsingError, "invalid json")
    check f.handler(err, req, res) == true
    check res.statusCode == 400
    check res.finished
    let body = capturedResponseBody(res)
    check body == """{"error":"Bad Request"}"""
    check body.find("detail") < 0

  test "jsonParsingErrorFilter ignores non-JSON errors":
    let f = jsonParsingErrorFilter()
    let req = newMockRequest()
    let res = newMockResponse()
    let err = newException(ValueError, "not json")
    check f.handler(err, req, res) == false
    check not res.finished

  test "builtinFilters is callable repeatedly at setup time (ISSUE-8)":
    let a = builtinFilters()
    let b = builtinFilters()
    check a.len == 5
    check b.len == 5
    check a[0].name == b[0].name

suite "global_error_filter integration":
  test "catches ValueError via built-ins and returns 400 (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilterWithBuiltins()
    runMiddlewareChain(@[mw], req, res, valueCrashHandler)
    check res.statusCode == 400
    check res.finished
    check res.get("content-type").find("application/json") >= 0
    check capturedResponseBody(res) == """{"error":"Bad Request"}"""

  test "unhandled error falls back to 500 (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilterWithBuiltins()
    runMiddlewareChain(@[mw], req, res, customCrashHandler)
    check res.statusCode == 500
    check res.finished
    check capturedResponseBody(res) == """{"error":"Internal Server Error"}"""

  test "ISSUE-1 (contract): filter returning true is authoritative; no fallback appended":
    let claimProc = proc(err: ref Exception, req: Req, res: Res): bool =
      res.status(409)
      res.send("""{"error":"Conflict"}""")
      true
    let claiming = newExceptionFilter("claiming", claimProc, 200)
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilter(@[claiming])
    runMiddlewareChain(@[mw], req, res, valueCrashHandler)
    check res.finished
    check res.statusCode == 409
    check capturedResponseBody(res) == """{"error":"Conflict"}"""

  test "ISSUE-1: filter that sends a response is not overridden":
    let handleProc = proc(err: ref Exception, req: Req, res: Res): bool =
      res.status(418)
      res.send("custom-handled")
      true
    let handling = newExceptionFilter("handling", handleProc, 200)
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilter(@[handling])
    runMiddlewareChain(@[mw], req, res, valueCrashHandler)
    check res.finished
    check res.statusCode == 418
    check capturedResponseBody(res) == "custom-handled"

  test "ISSUE-2: filter throwing before finishing lets next filter handle":
    let throwProc = proc(err: ref Exception, req: Req, res: Res): bool =
      res.status(418)
      raise newException(ValueError, "filter boom")
    let recoverProc = proc(err: ref Exception, req: Req, res: Res): bool =
      res.status(404)
      res.send("recovered")
      true
    let throwing = newExceptionFilter("throwing", throwProc, 100)
    let recovering = newExceptionFilter("recovering", recoverProc, 50)
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilter(@[throwing, recovering])
    runMiddlewareChain(@[mw], req, res, valueCrashHandler)
    check res.finished
    check res.statusCode == 404
    check capturedResponseBody(res) == "recovered"

  test "ISSUE-2: filter throwing after finishing stops the chain":
    var secondCalled = false
    let sendThrowProc = proc(err: ref Exception, req: Req, res: Res): bool =
      res.status(418)
      res.send("done")
      raise newException(ValueError, "after send")
    let secondProc = proc(err: ref Exception, req: Req, res: Res): bool =
      secondCalled = true
      true
    let sendThenThrow = newExceptionFilter("send-then-throw", sendThrowProc, 100)
    let second = newExceptionFilter("second", secondProc, 50)
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilter(@[sendThenThrow, second])
    runMiddlewareChain(@[mw], req, res, valueCrashHandler)
    check res.finished
    check res.statusCode == 418
    check capturedResponseBody(res) == "done"
    check secondCalled == false

  test "ISSUE-5: filter handler error falls back to 500 response":
    let throwProc = proc(err: ref Exception, req: Req, res: Res): bool =
      raise newException(RangeError, "filter failure")
    let throwing = newExceptionFilter("throwing", throwProc, 100)
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilter(@[throwing])
    runMiddlewareChain(@[mw], req, res, valueCrashHandler)
    check res.finished
    check res.statusCode == 500
    check capturedResponseBody(res) == """{"error":"Internal Server Error"}"""

  test "higher priority filter is evaluated first (ISSUE-9)":
    let lowProc = proc(err: ref Exception, req: Req, res: Res): bool =
      res.status(400)
      res.send("low")
      true
    let highProc = proc(err: ref Exception, req: Req, res: Res): bool =
      res.status(422)
      res.send("high")
      true
    let low = newExceptionFilter("low", lowProc, 10)
    let high = newExceptionFilter("high", highProc, 90)
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilter(@[low, high])
    runMiddlewareChain(@[mw], req, res, customCrashHandler)
    check res.finished
    check res.statusCode == 422
    check capturedResponseBody(res) == "high"

  test "custom fallbackStatusCode is respected":
    let opts = GlobalErrorFilterOptions(
      filters: @[], fallbackStatusCode: 503, logUnhandled: false)
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilter(opts)
    runMiddlewareChain(@[mw], req, res, customCrashHandler)
    check res.finished
    check res.statusCode == 503
    check capturedResponseBody(res) == """{"error":"Internal Server Error"}"""

  test "ISSUE-6: OverflowDefect falls back to 500 without stack trace logging":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilterWithBuiltins()
    runMiddlewareChain(@[mw], req, res, overflowCrashHandler)
    check res.finished
    check res.statusCode == 500
    check capturedResponseBody(res) == """{"error":"Internal Server Error"}"""

  test "globalErrorFilterWithBuiltins extra filter overrides built-in by priority":
    let extraProc = proc(err: ref Exception, req: Req, res: Res): bool =
      res.status(422)
      res.send("extra")
      true
    let extra = newExceptionFilter("extra", extraProc, 200)
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilterWithBuiltins(@[extra])
    runMiddlewareChain(@[mw], req, res, valueCrashHandler)
    check res.finished
    check res.statusCode == 422
    check capturedResponseBody(res) == "extra"

  test "successful handler passes through untouched (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = globalErrorFilterWithBuiltins()
    runMiddlewareChain(@[mw], req, res, okHandler)
    check res.statusCode == 200
    check res.finished
    check capturedResponseBody(res) == "ok"
