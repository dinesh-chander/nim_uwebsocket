import std/[unittest, asyncdispatch, json, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/body_parser

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
  nativeRes.requestMethod = hmPost
  nativeRes.connectionClose = false
  result.native = nativeRes
  result.request = nil
  result.app = nil
  result.viewsDir = "views"
  result.viewExt = ""
  result.requestMethodKind = hmPost
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

suite "body_parser unit":
  test "contentTypeCharset extracts the charset parameter case-insensitively":
    check contentTypeCharset("text/plain") == ""
    check contentTypeCharset("text/plain; charset=utf-8") == "utf-8"
    check contentTypeCharset("text/plain;charset=utf-8") == "utf-8"
    check contentTypeCharset("text/plain; charset=UTF-8") == "utf-8"
    check contentTypeCharset("text/plain; charset=utf8") == "utf8"
    check contentTypeCharset("text/plain; charset=  utf-8 ") == "utf-8"
    check contentTypeCharset("application/json; charset=utf-8; version=1") == "utf-8"
    check contentTypeCharset("text/plain; name=charset") == ""
    check contentTypeCharset("text/plain; boundary=xyz") == ""
    check contentTypeCharset("text/plain; charset") == ""
    check contentTypeCharset("text/plain; charset=; x=1") == ""

  test "contentTypeCharset strips quotes around the charset value (ISSUE-2)":
    check contentTypeCharset("text/plain; charset=\"utf-8\"") == "utf-8"
    check contentTypeCharset("text/plain; charset=\"UTF-8\"") == "utf-8"
    check contentTypeCharset("text/plain; charset=\"iso-8859-1\"") == "iso-8859-1"
    check contentTypeCharset("text/plain; a=b; charset=\"utf-8\"; c=d") == "utf-8"

suite "body_parser integration":
  test "urlencoded key-only pair is stored with an empty value (ISSUE-1)":
    let mw = urlencoded()
    var nextRan = false
    let req = newMockRequest("/", hmPost, "flag&other=value",
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check nextRan
    check res.statusCode == 200
    check res.finished
    check req.locals["form_flag"] == ""
    check req.locals["form_other"] == "value"

  test "urlencoded filters underscore-prefixed keys (ISSUE-10)":
    let mw = urlencoded()
    var nextRan = false
    let req = newMockRequest("/", hmPost, "_json_valid=0&name=x",
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check nextRan
    check res.statusCode == 200
    check res.finished
    check req.locals["form_name"] == "x"
    check req.locals.getOrDefault("_json_valid") == ""
    check req.locals.getOrDefault("form__json_valid") == ""

    var nextRan2 = false
    let req2 = newMockRequest("/", hmPost, "%5Fserver_timing_enabled=1&ok=yes",
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, flagHandler(addr nextRan2))
    check nextRan2
    check res2.statusCode == 200
    check res2.finished
    check req2.locals.getOrDefault("_server_timing_enabled") == ""
    check req2.locals["form_ok"] == "yes"

  test "text requireUtf8 accepts quoted charset=\"utf-8\" (ISSUE-2/ISSUE-5)":
    let opts = TextParserOptions(
      limitBytes: 1024, acceptedMimeTypes: @["text/*"], requireUtf8: true)
    let mw = text(opts)
    var nextRan = false
    let req = newMockRequest("/", hmPost, "hello",
      headerMap = @[("content-type", "text/plain; charset=\"utf-8\"")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check nextRan
    check res.statusCode == 200
    check res.finished
    check req.locals["body_text"] == "hello"

  test "text requireUtf8 accepts hyphenless charset=utf8 (ISSUE-5)":
    let opts = TextParserOptions(
      limitBytes: 1024, acceptedMimeTypes: @["text/*"], requireUtf8: true)
    let mw = text(opts)
    var nextRan = false
    let req = newMockRequest("/", hmPost, "hello",
      headerMap = @[("content-type", "text/plain; charset=utf8")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check nextRan
    check res.statusCode == 200
    check res.finished
    check req.locals["body_text"] == "hello"

  test "text requireUtf8 without a charset parameter passes (regression)":
    let opts = TextParserOptions(
      limitBytes: 1024, acceptedMimeTypes: @["text/*"], requireUtf8: true)
    let mw = text(opts)
    var nextRan = false
    let req = newMockRequest("/", hmPost, "hello",
      headerMap = @[("content-type", "text/plain")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check nextRan
    check res.statusCode == 200
    check res.finished
    check req.locals["body_text"] == "hello"

  test "text requireUtf8 rejects non-utf8 charsets with 415":
    let opts = TextParserOptions(
      limitBytes: 1024, acceptedMimeTypes: @["text/*"], requireUtf8: true)
    let mw = text(opts)
    for ct in @[
      "text/plain; charset=iso-8859-1",
      "text/plain; charset=utf-16",
      "text/plain; charset=\"windows-1252\"",
    ]:
      var nextRan = false
      let req = newMockRequest("/", hmPost, "hello",
        headerMap = @[("content-type", ct)])
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
      check not nextRan
      check res.statusCode == 415
      check res.finished

  test "bodyParser routes json and urlencoded normally (regression)":
    let mw = bodyParser()

    var nextRan = false
    let reqJson = newMockRequest("/", hmPost, """{"a":1}""",
      headerMap = @[("content-type", "application/json")])
    let resJson = newMockResponse()
    runMiddlewareChain(@[mw], reqJson, resJson, flagHandler(addr nextRan))
    check nextRan
    check resJson.statusCode == 200
    check resJson.finished
    check reqJson.locals["_json_valid"] == "1"

    var nextRan2 = false
    let reqForm = newMockRequest("/", hmPost, "greeting=hi",
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let resForm = newMockResponse()
    runMiddlewareChain(@[mw], reqForm, resForm, flagHandler(addr nextRan2))
    check nextRan2
    check resForm.statusCode == 200
    check resForm.finished
    check reqForm.locals["form_greeting"] == "hi"

    var nextRan3 = false
    let reqOther = newMockRequest("/", hmPost, "raw text",
      headerMap = @[("content-type", "text/plain")])
    let resOther = newMockResponse()
    runMiddlewareChain(@[mw], reqOther, resOther, flagHandler(addr nextRan3))
    check nextRan3
    check resOther.statusCode == 200
    check resOther.finished
