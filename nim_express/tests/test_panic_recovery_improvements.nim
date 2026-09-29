import std/[unittest, asyncdispatch, strutils, json, os]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/panic_recovery

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

let gTmpDir = getTempDir() / "nim_uws_panicrec_tests" / $getCurrentProcessId()

proc tmpLogPath(name: string): string =
  let parent = getTempDir() / "nim_uws_panicrec_tests"
  if not dirExists(parent):
    createDir(parent)
  if not dirExists(gTmpDir):
    createDir(gTmpDir)
  result = gTmpDir / name

proc withCapturedStderr(path: string, body: proc() {.closure.}) =
  let saved = stderr
  if fileExists(path):
    removeFile(path)
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved

let crashHandler = proc(req: Request, res: Response): Future[void] {.async.} =
  raise newException(ValueError, "boom")

let okHandler = proc(req: Request, res: Response): Future[void] {.async.} =
  if not res.finished:
    res.status(200)
    res.send("ok")

let partialThenCrash = proc(req: Request, res: Response): Future[void] {.async.} =
  if not res.finished:
    res.status(200)
    res.send("partial")
  raise newException(ValueError, "boom")

let defectHandler = proc(req: Request, res: Response): Future[void] {.async.} =
  let d = newException(Defect, "defect-boom")
  d.name = "test_defect"
  raise d

suite "panic_recovery unit":
  test "defaultPanicRecoveryOptions returns production-safe defaults (regression)":
    let d = defaultPanicRecoveryOptions()
    check d.responseFormat == erfJson
    check d.logErrors
    check not d.includeStackTrace
    check d.reportHook.isNil

suite "panic_recovery integration":
  test "catches CatchableError and returns 500 JSON (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[panicRecovery()], req, res, crashHandler)
    check res.statusCode == 500
    check res.finished
    let body = capturedResponseBody(res)
    check body == """{"error":"Internal Server Error"}"""
    check parseJson(body)["error"].str == "Internal Server Error"
    let raw = res.native.capturedRaw
    check raw.find("500") >= 0
    check raw.find("application/json; charset=utf-8") >= 0

  test "non-error handler passes through untouched (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[panicRecovery()], req, res, okHandler)
    check res.statusCode == 200
    check res.finished
    check capturedResponseBody(res) == "ok"

  test "erfPlainText returns a text/plain 500 body (ISSUE-1)":
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = panicRecovery(PanicRecoveryOptions(responseFormat: erfPlainText))
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500
    check res.finished
    check capturedResponseBody(res) == "Internal Server Error"
    let raw = res.native.capturedRaw
    check raw.find("text/plain; charset=utf-8") >= 0
    check raw.find("application/json") < 0

  test "does not double-write when response already finished (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[panicRecovery()], req, res, partialThenCrash)
    check res.statusCode == 200
    check res.finished
    check capturedResponseBody(res) == "partial"

  test "reportHook receives raw exception, request and raw unsanitized path (ISSUE-4)":
    let req = newMockRequest(pathVal = "/raw\npath")
    let res = newMockResponse()
    var hookPath = ""
    var hookMsg = ""
    var hookReq: Request
    let hook = proc(err: ref Exception, r: Req, p: string) =
      hookPath = p
      hookMsg = err.msg
      hookReq = r
    let mw = panicRecovery(hook)
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500
    check hookPath == "/raw\npath"
    check hookMsg.startsWith("boom")
    check hookReq == req
    check capturedResponseBody(res) == """{"error":"Internal Server Error"}"""

  test "failing reportHook does not break recovery (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    let hook = proc(err: ref Exception, r: Req, p: string) =
      raise newException(ValueError, "hook-fail")
    let mw = panicRecovery(hook)
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check res.statusCode == 500
    check res.finished
    check capturedResponseBody(res) == """{"error":"Internal Server Error"}"""

  test "catches Defect and returns 500 JSON (debug builds, ISSUE-3)":
    let req = newMockRequest()
    let res = newMockResponse()
    var hookName = ""
    var hookMsg = ""
    let hook = proc(err: ref Exception, r: Req, p: string) =
      hookName = $err.name
      hookMsg = err.msg
    let mw = panicRecovery(hook)
    runMiddlewareChain(@[mw], req, res, defectHandler)
    check res.statusCode == 500
    check res.finished
    check hookName == "test_defect"
    check hookMsg.startsWith("defect-boom")
    check capturedResponseBody(res) == """{"error":"Internal Server Error"}"""

  test "hook-only overload wires hook with default options (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    var hookCalled = false
    let mw = panicRecovery(proc(err: ref Exception, r: Req, p: string) =
      hookCalled = true)
    runMiddlewareChain(@[mw], req, res, crashHandler)
    check hookCalled
    check res.statusCode == 500
    check capturedResponseBody(res) == """{"error":"Internal Server Error"}"""

suite "panic_recovery stderr logging":
  test "logErrors=true logs message line, no trace by default (ISSUE-2)":
    let logPath = tmpLogPath("err_default.log")
    withCapturedStderr(logPath):
      let req = newMockRequest()
      let res = newMockResponse()
      runMiddlewareChain(@[panicRecovery()], req, res, crashHandler)
    let content = readFile(logPath)
    removeFile(logPath)
    let lines = content.strip().split("\n")
    check lines.len == 1
    check lines[0].find("[panic_recovery]") >= 0
    check lines[0].find("GET") >= 0
    check lines[0].find("500: boom") >= 0

  test "includeStackTrace=true appends the stack trace (ISSUE-2)":
    let logPath = tmpLogPath("err_trace.log")
    var opts = defaultPanicRecoveryOptions()
    opts.includeStackTrace = true
    let mw = panicRecovery(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    withCapturedStderr(logPath):
      runMiddlewareChain(@[mw], req, res, crashHandler)
    let content = readFile(logPath)
    removeFile(logPath)
    let lines = content.strip().split("\n")
    check lines.len >= 2
    check lines[0].find("500: boom") >= 0

  test "logErrors=false produces no stderr output (regression)":
    let logPath = tmpLogPath("err_off.log")
    let req = newMockRequest()
    let res = newMockResponse()
    let mw = panicRecovery(PanicRecoveryOptions(logErrors: false))
    withCapturedStderr(logPath):
      runMiddlewareChain(@[mw], req, res, crashHandler)
    let content = readFile(logPath)
    removeFile(logPath)
    check content == ""
    check res.statusCode == 500

  test "control chars in path are escaped in the log line (ISSUE-4)":
    let logPath = tmpLogPath("err_inject.log")
    withCapturedStderr(logPath):
      let req = newMockRequest(pathVal = "/a\nb")
      let res = newMockResponse()
      runMiddlewareChain(@[panicRecovery()], req, res, crashHandler)
    let content = readFile(logPath)
    removeFile(logPath)
    let lines = content.strip().split("\n")
    check lines.len == 1
    check lines[0].find("/a\\x0Ab") >= 0
    if dirExists(gTmpDir):
      removeDir(gTmpDir)
