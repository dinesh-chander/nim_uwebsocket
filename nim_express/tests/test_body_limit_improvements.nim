import std/[unittest, asyncdispatch, json, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/body_limit

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

proc capturedResponseBody(res: Response): string =
  let raw = res.native.capturedRaw
  let bodyStart = raw.find("\r\n\r\n")
  if bodyStart >= 0:
    raw[bodyStart + 4 ..^ 1]
  else:
    ""

suite "body_limit unit":
  test "payloadTooLargeBody is the exact generic 413 body without limit text":
    check payloadTooLargeBody == """{"error":"Payload Too Large"}"""
    check payloadTooLargeBody.find("limit") < 0
    check payloadTooLargeBody.find("1048576") < 0

  test "normalizeContentTypeLimits tokenizes entries and skips unusable ones":
    let n1 = normalizeContentTypeLimits(@[
      ContentTypeLimitEntry(contentType: " Application/JSON ; charset=utf-8", maxBytes: 100)])
    check n1.len == 1
    check n1[0].contentType == "application/json"
    check n1[0].maxBytes == 100

    check normalizeContentTypeLimits(@[
      ContentTypeLimitEntry(contentType: "", maxBytes: 5)]).len == 0
    check normalizeContentTypeLimits(@[
      ContentTypeLimitEntry(contentType: "   ", maxBytes: 5)]).len == 0
    check normalizeContentTypeLimits(@[
      ContentTypeLimitEntry(contentType: "text/*", maxBytes: 5)]).len == 0
    check normalizeContentTypeLimits(@[
      ContentTypeLimitEntry(contentType: "*/*", maxBytes: 5)]).len == 0
    check normalizeContentTypeLimits(@[]).len == 0

    let n2 = normalizeContentTypeLimits(@[
      ContentTypeLimitEntry(contentType: "TEXT/PLAIN", maxBytes: 10),
      ContentTypeLimitEntry(contentType: "*/*", maxBytes: 20),
      ContentTypeLimitEntry(contentType: "application/xml", maxBytes: 30)])
    check n2.len == 2
    check n2[0].contentType == "text/plain"
    check n2[0].maxBytes == 10
    check n2[1].contentType == "application/xml"
    check n2[1].maxBytes == 30

  test "resolveLimit matches the content-type token case-insensitively ignoring params":
    let limits = @[
      ContentTypeLimitEntry(contentType: "application/json", maxBytes: 10),
      ContentTypeLimitEntry(contentType: "multipart/form-data", maxBytes: 20)]
    check resolveLimit(limits, 1000, "application/json") == 10
    check resolveLimit(limits, 1000, "Application/JSON; charset=utf-8") == 10
    check resolveLimit(limits, 1000, "  MULTIPART/FORM-DATA ; boundary=x") == 20
    check resolveLimit(limits, 1000, "text/plain") == 1000
    check resolveLimit(limits, 1000, "") == 1000
    check resolveLimit(@[], 777, "application/json") == 777
    check resolveLimit(@[], 777, "") == 777

suite "body_limit integration":
  test "body under limit passes and body is bound (regression)":
    let mw = bodyLimit(1024)
    var nextRan = false
    let req = newMockRequest("/", hmPost, "hello")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check nextRan
    check res.statusCode == 200
    check res.finished
    check req.body == "hello"

  test "declared content-length over limit returns 413 and closes connection":
    let mw = bodyLimit(100)
    var nextRan = false
    let req = newMockRequest("/", hmPost, "", headerMap = @[("content-length", "999999")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check not nextRan
    check res.statusCode == 413
    check res.finished
    check res.get("Connection") == "close"
    let raw = res.native.capturedRaw
    let bodyStart = raw.find("\r\n\r\n")
    check bodyStart >= 0
    check raw[bodyStart + 4 ..^ 1] == payloadTooLargeBody
    check raw.find("limit") < 0
    check raw.find("999999") < 0

  test "comma-separated content-length uses first value (ISSUE-1)":
    let mw = bodyLimit(100)
    var nextRan = false
    let req = newMockRequest("/", hmPost, "12345",
      headerMap = @[("content-length", "5, 5")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check nextRan
    check res.statusCode == 200
    check res.finished
    check req.body == "12345"

    var nextRan2 = false
    let req2 = newMockRequest("/", hmPost, "12345",
      headerMap = @[("content-length", " 5 , 5")])
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, flagHandler(addr nextRan2))
    check nextRan2
    check res2.statusCode == 200
    check res2.finished

  test "comma-separated content-length over limit returns 413":
    let mw = bodyLimit(4)
    var nextRan = false
    let req = newMockRequest("/", hmPost, "12345",
      headerMap = @[("content-length", "5, 5")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check not nextRan
    check res.statusCode == 413
    check res.finished
    check capturedResponseBody(res) == payloadTooLargeBody

  test "malformed content-length still returns 400 (defense-in-depth)":
    let mw = bodyLimit(100)
    var nextRan = false
    let req = newMockRequest("/", hmPost, "",
      headerMap = @[("content-length", "not-a-number")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check not nextRan
    check res.statusCode == 400
    check res.finished
    check res.get("Connection") == "close"

  test "actual body over limit returns 413 without content-length header":
    let mw = bodyLimit(10)
    var nextRan = false
    let req = newMockRequest("/", hmPost, repeat("a", 50))
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextRan))
    check not nextRan
    check res.statusCode == 413
    check res.finished
    check res.get("Connection") == "close"
    check capturedResponseBody(res) == payloadTooLargeBody

  test "per-type limit applies after normalization (ISSUE-3)":
    let opts = BodyLimitOptions(
      maxBytes: 1000,
      contentTypeLimits: @[ContentTypeLimitEntry(
        contentType: " Application/JSON ; charset=utf-8", maxBytes: 10)])
    let mw = bodyLimit(opts)

    var nextRan1 = false
    let req1 = newMockRequest("/", hmPost, "12345",
      headerMap = @[("content-type", "application/json")])
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, flagHandler(addr nextRan1))
    check nextRan1
    check res1.statusCode == 200
    check res1.finished

    var nextRan2 = false
    let req2 = newMockRequest("/", hmPost, repeat("a", 11),
      headerMap = @[("content-type", "application/json; charset=utf-8")])
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, flagHandler(addr nextRan2))
    check not nextRan2
    check res2.statusCode == 413
    check res2.finished
    check capturedResponseBody(res2) == payloadTooLargeBody

    var nextRan3 = false
    let req3 = newMockRequest("/", hmPost, repeat("a", 500),
      headerMap = @[("content-type", "text/plain")])
    let res3 = newMockResponse()
    runMiddlewareChain(@[mw], req3, res3, flagHandler(addr nextRan3))
    check nextRan3
    check res3.statusCode == 200
    check res3.finished

  test "int overload clamps zero/negative maxBytes to 1 byte (ISSUE-2)":
    let mw0 = bodyLimit(0)
    var nextRan1 = false
    let req1 = newMockRequest("/", hmPost, "a")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw0], req1, res1, flagHandler(addr nextRan1))
    check nextRan1
    check res1.statusCode == 200

    var nextRan2 = false
    let req2 = newMockRequest("/", hmPost, "ab")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw0], req2, res2, flagHandler(addr nextRan2))
    check not nextRan2
    check res2.statusCode == 413

    let mwNeg = bodyLimit(-5)
    var nextRan3 = false
    let req3 = newMockRequest("/", hmPost, "a")
    let res3 = newMockResponse()
    runMiddlewareChain(@[mwNeg], req3, res3, flagHandler(addr nextRan3))
    check nextRan3
    check res3.statusCode == 200

  test "options overload maxBytes=0 allows only empty bodies (ISSUE-2)":
    let mw = bodyLimit(BodyLimitOptions(maxBytes: 0, contentTypeLimits: @[]))
    var nextRan1 = false
    let req1 = newMockRequest("/", hmPost, "")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, flagHandler(addr nextRan1))
    check nextRan1
    check res1.statusCode == 200
    check res1.finished

    var nextRan2 = false
    let req2 = newMockRequest("/", hmPost, "a")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, flagHandler(addr nextRan2))
    check not nextRan2
    check res2.statusCode == 413
    check res2.finished
