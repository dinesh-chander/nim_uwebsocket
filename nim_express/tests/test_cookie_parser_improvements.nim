import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/cookie_parser

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

suite "cookie_parser unit":
  test "CookieParseRejectedKey is the shared magic key (ISSUE-5)":
    check CookieParseRejectedKey == "_cookie_parse_rejected"

  test "parseCookieHeaderBounded (view) parses a valid header (ISSUE-1)":
    let req = newMockRequest(headerMap = @[("cookie", "a=1; b=2")])
    let view = req.getView("cookie")
    var cookies = newFastMap[string]()
    check parseCookieHeaderBounded(view, cookies)
    check cookies.getOrDefault("a", "") == "1"
    check cookies.getOrDefault("b", "") == "2"

  test "parseCookieHeaderBounded (string) matches the view path":
    var cookies = newFastMap[string]()
    check parseCookieHeaderBounded("x=9; y=10", cookies)
    check cookies.getOrDefault("x", "") == "9"
    check cookies.getOrDefault("y", "") == "10"

  test "parseCookieHeaderBounded rejects a control byte in a value (ISSUE-4)":
    let req = newMockRequest(headerMap = @[("cookie", "a=1" & "\r\nX-Evil: 1")])
    let view = req.getView("cookie")
    var cookies = newFastMap[string]()
    check not parseCookieHeaderBounded(view, cookies)

  test "parseCookieHeaderBounded rejects an oversized value":
    var big = "k="
    for _ in 1 .. 2100:
      big.add('v')
    let req = newMockRequest(headerMap = @[("cookie", big)])
    let view = req.getView("cookie")
    var cookies = newFastMap[string]()
    check not parseCookieHeaderBounded(view, cookies)

  test "parseCookieHeaderBounded rejects more than maxPairs":
    var header = ""
    for i in 0 ..< 70:
      if i > 0:
        header.add("; ")
      header.add($i & "=" & $i)
    let req = newMockRequest(headerMap = @[("cookie", header)])
    let view = req.getView("cookie")
    var cookies = newFastMap[string]()
    check not parseCookieHeaderBounded(view, cookies)

  test "cookieParseRejected / markCookiesParsed are nil-safe (ISSUE-5)":
    check not cookieParseRejected(nil)
    markCookiesParsed(nil)

suite "cookie_parser integration":
  test "valid cookie header is eagerly parsed into req.cookies (ISSUE-1/2)":
    let req = newMockRequest(headerMap = @[("cookie", "sid=abc; theme=dark")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[cookieParser()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.cookies.getOrDefault("sid", "") == "abc"
    check req.cookies.getOrDefault("theme", "") == "dark"
    check req.getCookie("sid") == "abc"
    check not cookieParseRejected(req)

  test "header with a control byte is rejected and flagged (ISSUE-4)":
    let req = newMockRequest(headerMap = @[("cookie", "a=1" & "\r\nX-Evil: 1")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[cookieParser()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.cookies.len == 0
    check cookieParseRejected(req)
    check req.locals.getOrDefault(CookieParseRejectedKey, "") == "1"
    check req.getCookie("a") == ""

  test "nil request is handled gracefully (ISSUE-6)":
    let mw = cookieParser()
    var nextCalled = false
    let res = newMockResponse()
    runMiddlewareChain(@[mw], nil, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200

  test "no cookie header leaves req.cookies empty and unflagged (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[cookieParser()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.cookies.len == 0
    check not cookieParseRejected(req)
