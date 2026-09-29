import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/htmx

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

suite "htmx integration":
  test "non-HTMX request still emits Vary: HX-Request, no locals (ISSUE-1)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[htmx()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check res.get("vary") == "HX-Request"
    check req.locals.getOrDefault("htmx") == ""
    check req.locals.getOrDefault("htmx-target") == ""

  test "non-HTMX boosted request emits both Vary values (ISSUE-1, ISSUE-2)":
    let req = newMockRequest(headerMap = @[("hx-boosted", "1")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[htmx()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.get("vary") == "HX-Request, HX-Boosted"
    # extraction stays guarded: no locals for non-HTMX requests (ISSUE-3)
    check req.locals.getOrDefault("htmx") == ""
    check req.locals.getOrDefault("htmx-boosted") == ""

  test "HTMX request sets htmx local and Vary (regression)":
    let req = newMockRequest(headerMap = @[("hx-request", "true")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[htmx()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.isHtmx()
    check req.locals.getOrDefault("htmx") == "true"
    check res.get("vary") == "HX-Request"

  test "HTMX request extracts all standard headers into locals (regression)":
    let req = newMockRequest(headerMap = @[
      ("hx-request", "true"),
      ("hx-target", "main-content"),
      ("hx-trigger", "click"),
      ("hx-trigger-name", "save-btn"),
      ("hx-current-url", "/todos/42"),
      ("hx-prompt", "confirm?"),
      ("hx-boosted", "1"),
      ("hx-history-restore-request", "1"),
    ])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[htmx()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.locals.getOrDefault("htmx") == "true"
    check req.locals.getOrDefault("htmx-target") == "main-content"
    check req.locals.getOrDefault("htmx-trigger") == "click"
    check req.locals.getOrDefault("htmx-trigger-name") == "save-btn"
    check req.locals.getOrDefault("htmx-current-url") == "/todos/42"
    check req.locals.getOrDefault("htmx-prompt") == "confirm?"
    check req.locals.getOrDefault("htmx-boosted") == "1"
    check req.locals.getOrDefault("htmx-history-restore-request") == "1"
    check res.get("vary") == "HX-Request, HX-Boosted"

  test "HTMX boosted request: single hx-boosted lookup, both Vary values (ISSUE-2)":
    let req = newMockRequest(headerMap = @[
      ("hx-request", "true"), ("hx-boosted", "1")
    ])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[htmx()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.locals.getOrDefault("htmx-boosted") == "1"
    check res.get("vary") == "HX-Request, HX-Boosted"

  test "HTMX request with empty header values stores no empty locals (regression)":
    let req = newMockRequest(headerMap = @[
      ("hx-request", "true"),
      ("hx-target", ""),
      ("hx-prompt", ""),
    ])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[htmx()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.locals.getOrDefault("htmx") == "true"
    check req.locals.getOrDefault("htmx-target") == ""
    check req.locals.getOrDefault("htmx-prompt") == ""
    check res.get("vary") == "HX-Request"

  test "nil request: no crash, Vary still emitted, chain continues (ISSUE-4)":
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[htmx()], nil, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.get("vary") == "HX-Request"
