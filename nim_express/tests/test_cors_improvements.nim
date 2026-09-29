import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/cors

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

suite "cors unit":
  test "corsOriginMatched is case-insensitive and empty-safe":
    check not corsOriginMatched("", @[])
    check corsOriginMatched("http://a.com", @["http://a.com"])
    check corsOriginMatched("HTTP://A.COM", @["http://a.com"])
    check not corsOriginMatched("http://a.com", @["http://b.com"])
    check not corsOriginMatched("", @["http://a.com"])
    check corsOriginMatched("http://a.com", @["http://b.com", "http://a.com"])

  test "allowedOrigins containing '*' is rejected at setup (ISSUE-4)":
    expect ValueError:
      var o1 = CorsOptions()
      o1.allowedOrigins = @["*"]
      discard cors(o1)
    expect ValueError:
      var o2 = CorsOptions()
      o2.allowedOrigins = @["*"]
      discard corsSync(o2)

  test "reflect + credentials without an allowlist denies preflights by design (ISSUE-5)":
    var o5 = CorsOptions()
    o5.origin = "reflect"
    o5.credentials = true
    let mw = cors(o5)
    let req = newMockRequest(methodKind = hmOptions,
      headerMap = @[("origin", "http://any.com")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403
    check res.get("access-control-allow-origin").len == 0
    check res.get("access-control-allow-credentials").len == 0

  test "fixed origin with an allowlist is rejected at setup (ISSUE-6)":
    var o6 = CorsOptions()
    o6.origin = "http://fixed.com"
    o6.allowedOrigins = @["http://a.com"]
    expect ValueError:
      discard cors(o6)
    expect ValueError:
      discard corsSync(o6)

suite "cors integration":
  test "simple wildcard GET emits ACAO:* and HEAD in default methods (ISSUE-9, regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[cors()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check res.get("access-control-allow-origin") == "*"
    check res.get("access-control-allow-methods").find("HEAD") >= 0

  test "simple wildcard OPTIONS preflight short-circuits with 204 (regression)":
    let req = newMockRequest(methodKind = hmOptions)
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[cors()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 204
    check res.get("access-control-allow-origin") == "*"

  test "reflect mode sends Vary: Origin even when the request has no Origin (ISSUE-1)":
    var r1 = CorsOptions()
    r1.origin = "reflect"
    let mw = cors(r1)
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.get("Vary").find("Origin") >= 0
    check res.get("access-control-allow-origin").len == 0

  test "reflect mode does not echo Origin: null, but reflects a real origin (ISSUE-13)":
    var r13 = CorsOptions()
    r13.origin = "reflect"
    let mw = cors(r13)
    let reqNull = newMockRequest(headerMap = @[("origin", "null")])
    let resNull = newMockResponse()
    var nextNull = false
    runMiddlewareChain(@[mw], reqNull, resNull, flagHandler(addr nextNull))
    check resNull.get("access-control-allow-origin").len == 0
    check resNull.get("Vary").find("Origin") >= 0

    let reqGood = newMockRequest(headerMap = @[("origin", "http://good.com")])
    let resGood = newMockResponse()
    var nextGood = false
    runMiddlewareChain(@[mw], reqGood, resGood, flagHandler(addr nextGood))
    check resGood.get("access-control-allow-origin") == "http://good.com"

  test "reflected access-control-request-headers are sanitized (ISSUE-7)":
    var r7 = CorsOptions()
    r7.allowedHeaders = @["*"]
    let mw = cors(r7)
    let reqDirty = newMockRequest(headerMap = @[("access-control-request-headers", "x, y" & "\x01")])
    let resDirty = newMockResponse()
    var nextDirty = false
    runMiddlewareChain(@[mw], reqDirty, resDirty, flagHandler(addr nextDirty))
    check resDirty.get("access-control-allow-headers").find("\x01") < 0
    check resDirty.get("Vary").find("Access-Control-Request-Headers") >= 0

    let reqClean = newMockRequest(headerMap = @[("access-control-request-headers", "x-custom, other")])
    let resClean = newMockResponse()
    var nextClean = false
    runMiddlewareChain(@[mw], reqClean, resClean, flagHandler(addr nextClean))
    check resClean.get("access-control-allow-headers") == "x-custom, other"

  test "fixed origin sends the origin verbatim with no Vary: Origin (ISSUE-11)":
    var r11 = CorsOptions()
    r11.origin = "http://fixed.com"
    let mw = cors(r11)
    let req = newMockRequest(headerMap = @[("origin", "http://a.com")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.get("access-control-allow-origin") == "http://fixed.com"
    check res.get("Vary").len == 0

  test "reflect + credentials reflects an allowlisted origin with Vary: Origin (regression)":
    var rReg = CorsOptions()
    rReg.origin = "reflect"
    rReg.credentials = true
    rReg.allowedOrigins = @["http://a.com"]
    let mw = cors(rReg)
    let req = newMockRequest(headerMap = @[("origin", "http://a.com")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.get("access-control-allow-origin") == "http://a.com"
    check res.get("access-control-allow-credentials") == "true"
    check res.get("Vary").find("Origin") >= 0

  test "preflight echoes access-control-allow-private-network when enabled (ISSUE-12)":
    var p12 = CorsOptions()
    p12.allowPrivateNetwork = true
    let mw = cors(p12)
    let req = newMockRequest(methodKind = hmOptions,
      headerMap = @[("access-control-request-private-network", "true")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 204
    check res.get("access-control-allow-private-network") == "true"

    let reqOff = newMockRequest(methodKind = hmOptions,
      headerMap = @[("access-control-request-private-network", "true")])
    let resOff = newMockResponse()
    var nextOff = false
    runMiddlewareChain(@[cors()], reqOff, resOff, flagHandler(addr nextOff))
    check resOff.get("access-control-allow-private-network").len == 0

    let reqGet = newMockRequest(headerMap = @[("access-control-request-private-network", "true")])
    let resGet = newMockResponse()
    var nextGet = false
    runMiddlewareChain(@[mw], reqGet, resGet, flagHandler(addr nextGet))
    check nextGet
    check resGet.get("access-control-allow-private-network").len == 0

  test "preflight with a method outside the configured list is rejected with 403 (ISSUE-15)":
    let mw = cors()
    let req = newMockRequest(methodKind = hmOptions,
      headerMap = @[("access-control-request-method", "TRACE")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403

    let reqOk = newMockRequest(methodKind = hmOptions,
      headerMap = @[("access-control-request-method", "post")])
    let resOk = newMockResponse()
    var nextOk = false
    runMiddlewareChain(@[mw], reqOk, resOk, flagHandler(addr nextOk))
    check not nextOk
    check resOk.statusCode == 204

    let reqPlain = newMockRequest(methodKind = hmOptions)
    let resPlain = newMockResponse()
    var nextPlain = false
    runMiddlewareChain(@[mw], reqPlain, resPlain, flagHandler(addr nextPlain))
    check not nextPlain
    check resPlain.statusCode == 204

  test "preflight method validation applies on the simple wildcard path (ISSUE-15)":
    var m15 = CorsOptions()
    m15.methods = @["GET"]
    let mw = cors(m15)
    let req = newMockRequest(methodKind = hmOptions,
      headerMap = @[("access-control-request-method", "POST")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403
    check res.get("access-control-allow-methods") == "GET"
