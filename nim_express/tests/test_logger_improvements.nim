import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/logger

# ---- mock harness (pattern copied from test_csrf_improvements.nim) ----

proc newMockHttpRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[],
  httpMajor: int = 1, httpMinor: int = 1
): HttpRequest =
  new(result)
  result.path = pathVal
  result.queryStringRaw = ""
  result.httpVersion = "1.1"
  result.httpMajor = httpMajor
  result.httpMinor = httpMinor
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
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[],
  httpMajor: int = 1, httpMinor: int = 1
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr, headerMap, httpMajor, httpMinor)
  result = newRequest(native)

proc newNilNativeRequest(): Request =
  new(result)
  result.native = nil
  result.methodKind = hmGet
  result.headers = newFastMap[string]()
  discard result.headers.reserve(4)
  result.locals = newFastMap[string]()
  discard result.locals.reserve(4)

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

proc waitForSafe(fut: Future[void]): Future[void] {.async.} =
  ## Await a future while swallowing any CatchableError so the caller can inspect
  ## `fut.failed`/`fut.error` deterministically (waitFor's re-raise is racy).
  try:
    await fut
  except CatchableError:
    discard

# ---- log capture ----

var capturedLines: seq[string]

proc capturingSink(line: string) =
  capturedLines.add(line)

proc statusHandler(code: int): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    discard res.status(code)

proc captureLog(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
): seq[string] =
  capturedLines.setLen(0)
  let prevSink = loggerSink
  loggerSink = capturingSink
  try:
    runMiddlewareChain(middlewares, req, res, handler)
  finally:
    loggerSink = prevSink
  result = capturedLines

# ---- unit tests: pure sanitization logic ----

suite "logger.sanitizeLogField":
  test "empty string":
    check sanitizeLogField("") == ""

  test "plain path unchanged":
    check sanitizeLogField("/api/v1/users") == "/api/v1/users"

  test "newline escaped":
    check sanitizeLogField("a\nb") == "a\\x0Ab"

  test "carriage return escaped":
    check sanitizeLogField("a\rb") == "a\\x0Db"

  test "tab escaped":
    check sanitizeLogField("a\tb") == "a\\x09b"

  test "DEL byte escaped":
    check sanitizeLogField("a\x7fb") == "a\\x7Fb"

  test "backslash escaped":
    check sanitizeLogField("a\\b") == "a\\\\b"

  test "double quote escaped":
    check sanitizeLogField("a\"b") == "a\\\"b"

  test "U+2028 line separator escaped":
    check sanitizeLogField("a\u2028b") == "a\\u2028b"

  test "U+2029 paragraph separator escaped":
    check sanitizeLogField("a\u2029b") == "a\\u2029b"

  test "U+2028 not falsely matched on partial bytes":
    # 0xE2 0x80 followed by a non-separator byte must pass through untouched
    check sanitizeLogField("\xe2\x80\xaf") == "\xe2\x80\xaf"

  test "mixed control, backslash and quote":
    check sanitizeLogField("a\nb\\c\"d") == "a\\x0Ab\\\\c\\\"d"

# ---- integration tests: level-based logger ----

suite "logger(level)":
  test "llInfo logs 200":
    let req = newMockRequest("/hello")
    let res = newMockResponse()
    let lines = captureLog(@[logger(llInfo)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0].startsWith("GET /hello 200 - ")
    check lines[0].endsWith("ms")

  test "llDebug logs 200":
    let req = newMockRequest("/d")
    let res = newMockResponse()
    let lines = captureLog(@[logger(llDebug)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0].startsWith("GET /d 200 - ")

  test "llInfo includes requestId when present":
    let req = newMockRequest("/hello")
    req.locals["requestId"] = "abc123"
    let res = newMockResponse()
    let lines = captureLog(@[logger(llInfo)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0].endsWith("ms reqId=abc123")

  test "llWarn suppresses 200":
    let req = newMockRequest("/w")
    let res = newMockResponse()
    let lines = captureLog(@[logger(llWarn)], req, res, statusHandler(200))
    check lines.len == 0

  test "llWarn logs 404":
    let req = newMockRequest("/w")
    let res = newMockResponse()
    let lines = captureLog(@[logger(llWarn)], req, res, statusHandler(404))
    check lines.len == 1
    check lines[0].startsWith("GET /w 404 - ")

  test "llError suppresses 404":
    let req = newMockRequest("/e")
    let res = newMockResponse()
    let lines = captureLog(@[logger(llError)], req, res, statusHandler(404))
    check lines.len == 0

  test "llError logs 500":
    let req = newMockRequest("/e")
    let res = newMockResponse()
    let lines = captureLog(@[logger(llError)], req, res, statusHandler(500))
    check lines.len == 1
    check lines[0].startsWith("GET /e 500 - ")

  test "path is sanitized in the log line":
    let req = newMockRequest("/a\nb")
    let res = newMockResponse()
    let lines = captureLog(@[logger(llInfo)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0].startsWith("GET /a\\x0Ab 200 - ")

  test "handler error is re-raised and status forced to 500":
    let req = newMockRequest("/boom")
    let res = newMockResponse()
    capturedLines.setLen(0)
    let prevSink = loggerSink
    loggerSink = capturingSink
    let fut = startMiddlewareChain(@[logger(llError)], req, res,
      proc(r: Request, s: Response): Future[void] {.async.} =
        raise newException(ValueError, "boom"))
    waitFor waitForSafe(fut)
    loggerSink = prevSink
    check fut.failed
    let err = fut.error
    check err != nil
    if err != nil:
      # asyncdispatch appends the async traceback to the message; the original
      # message is the leading content. `is` is unreliable across the async
      # re-raise boundary, so match on the type name and message prefix.
      check err.name == "ValueError"
      check err.msg.startsWith("boom")
    check res.statusCode == 500
    check capturedLines.len == 1
    check capturedLines[0].startsWith("GET /boom 500 - ")

  test "handler error keeps pre-existing 4xx status":
    let req = newMockRequest("/bad")
    let res = newMockResponse()
    capturedLines.setLen(0)
    let prevSink = loggerSink
    loggerSink = capturingSink
    let fut = startMiddlewareChain(@[logger(llWarn)], req, res,
      proc(r: Request, s: Response): Future[void] {.async.} =
        s.status(404)
        raise newException(ValueError, "nope"))
    waitFor waitForSafe(fut)
    loggerSink = prevSink
    check fut.failed
    check res.statusCode == 404
    check capturedLines.len == 1
    check capturedLines[0].startsWith("GET /bad 404 - ")

# ---- integration tests: format-based logger ----

suite "logger(format)":
  test "lfDev 200 uses green colour":
    let req = newMockRequest("/ok")
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfDev)], req, res, statusHandler(200))
    check lines.len == 1
    check "\e[32m" in lines[0]
    check "GET" in lines[0]
    check "/ok" in lines[0]
    check "200" in lines[0]

  test "lfDev 404 uses yellow colour":
    let req = newMockRequest("/missing")
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfDev)], req, res, statusHandler(404))
    check lines.len == 1
    check "\e[33m" in lines[0]

  test "lfCommon emits ip, request line and size":
    let req = newMockRequest("/api", headerMap = @[("content-length", "42")])
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfCommon)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0].startsWith("127.0.0.1 - - ")
    check "\"GET /api HTTP/1.1\" 200 42" in lines[0]

  test "lfCommon derives HTTP/1.0 from native version":
    let req = newMockRequest("/api", httpMinor = 0)
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfCommon)], req, res, statusHandler(200))
    check lines.len == 1
    check "HTTP/1.0" in lines[0]

  test "lfCommon uses dash when content-length absent":
    let req = newMockRequest("/api")
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfCommon)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0].endsWith(" 200 -")

  test "lfCombined includes referer and user-agent":
    let req = newMockRequest("/page",
      headerMap = @[("referer", "http://ref.example"), ("user-agent", "TestAgent/1.0")])
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfCombined)], req, res, statusHandler(200))
    check lines.len == 1
    check "\"GET /page HTTP/1.1\" 200 -" in lines[0]
    check "\"http://ref.example\" \"TestAgent/1.0\"" in lines[0]

  test "lfCombined falls back to dash for missing headers":
    let req = newMockRequest("/page")
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfCombined)], req, res, statusHandler(301))
    check lines.len == 1
    check lines[0].endsWith(" \"-\" \"-\"")

  test "lfShort format":
    let req = newMockRequest("/x")
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfShort)], req, res, statusHandler(301))
    check lines.len == 1
    check lines[0].startsWith("GET /x 301 ")
    check lines[0].endsWith("ms")

  test "lfShort includes requestId":
    let req = newMockRequest("/x")
    req.locals["requestId"] = "r1"
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfShort)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0].endsWith("ms reqId=r1")

  test "lfTiny format":
    let req = newMockRequest("/x")
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfTiny)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0] == "GET /x 200"

  test "lfTiny includes requestId":
    let req = newMockRequest("/x")
    req.locals["requestId"] = "r2"
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfTiny)], req, res, statusHandler(500))
    check lines.len == 1
    check lines[0] == "GET /x 500 reqId=r2"

  test "nil native common does not crash and uses fallbacks":
    let req = newNilNativeRequest()
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfCommon)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0].startsWith("- - - ")
    check "HTTP/1.1" in lines[0]
    check lines[0].endsWith(" 200 -")

  test "nil native combined does not crash":
    let req = newNilNativeRequest()
    let res = newMockResponse()
    let lines = captureLog(@[logger(lfCombined)], req, res, statusHandler(200))
    check lines.len == 1
    check lines[0].startsWith("- - - ")
    check lines[0].endsWith(" \"-\" \"-\"")
