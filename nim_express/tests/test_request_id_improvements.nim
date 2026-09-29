import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/request_id

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

proc setLocalMiddleware(key: string, value: string): AsyncMiddleware =
  result = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
    req.locals[key] = value
    await next()

proc isLowerHex32(s: string): bool =
  if s.len != 32:
    return false
  for c in s:
    if not (c in {'0'..'9'} or c in {'a'..'f'}):
      return false
  true

suite "request_id unit":
  test "buildFallbackRequestId yields 32-char lowercase hex, unique per call (ISSUE-1)":
    let a = buildFallbackRequestId()
    let b = buildFallbackRequestId()
    check a.len == 32
    check b.len == 32
    check isLowerHex32(a)
    check isLowerHex32(b)
    check a == a.toLowerAscii()
    check b == b.toLowerAscii()
    check a != b

suite "request_id integration":
  test "generates a 32-char lowercase hex id, sets local and response header":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[requestId()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    let id = req.locals.getOrDefault("requestId", "")
    check isLowerHex32(id)
    check res.get("x-request-id") == id

  test "two requests get different generated ids":
    let mw = requestId()
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    var next1 = false
    runMiddlewareChain(@[mw], req1, res1, flagHandler(addr next1))
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    var next2 = false
    runMiddlewareChain(@[mw], req2, res2, flagHandler(addr next2))
    check next1
    check next2
    let id1 = req1.locals.getOrDefault("requestId", "")
    let id2 = req2.locals.getOrDefault("requestId", "")
    check id1 != id2
    check isLowerHex32(id1)
    check isLowerHex32(id2)

  test "trustUpstream forwards a valid upstream id verbatim (ISSUE-3)":
    let req = newMockRequest(headerMap = @[("x-request-id", "upstream-42:abc.DEF_0")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[requestId(trustUpstream = true)], req, res,
      flagHandler(addr nextCalled))
    check nextCalled
    let id = req.locals.getOrDefault("requestId", "")
    check id == "upstream-42:abc.DEF_0"
    check res.get("x-request-id") == "upstream-42:abc.DEF_0"

  test "trustUpstream trims surrounding whitespace before validating (ISSUE-3)":
    let req = newMockRequest(headerMap = @[("x-request-id", "  padded-id-1\t")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[requestId(trustUpstream = true)], req, res,
      flagHandler(addr nextCalled))
    check nextCalled
    let id = req.locals.getOrDefault("requestId", "")
    check id == "padded-id-1"
    check res.get("x-request-id") == "padded-id-1"

  test "trustUpstream with whitespace-only header generates a new id (ISSUE-3)":
    let req = newMockRequest(headerMap = @[("x-request-id", "   \t ")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[requestId(trustUpstream = true)], req, res,
      flagHandler(addr nextCalled))
    check nextCalled
    check isLowerHex32(req.locals.getOrDefault("requestId", ""))

  test "trustUpstream rejects unsafe characters and generates a new id (regression)":
    for bad in @["evil<script>", "bad\r\nid", "bad id", "bad/id"]:
      let req = newMockRequest(headerMap = @[("x-request-id", bad)])
      let res = newMockResponse()
      var nextCalled = false
      runMiddlewareChain(@[requestId(trustUpstream = true)], req, res,
        flagHandler(addr nextCalled))
      check nextCalled
      let id = req.locals.getOrDefault("requestId", "")
      check id != bad
      check isLowerHex32(id)
      check res.get("x-request-id") == id

  test "trustUpstream rejects ids longer than 128 chars, accepts exactly 128 (regression)":
    let tooLong = repeat('a', 129)
    let req = newMockRequest(headerMap = @[("x-request-id", tooLong)])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[requestId(trustUpstream = true)], req, res,
      flagHandler(addr nextCalled))
    check nextCalled
    check isLowerHex32(req.locals.getOrDefault("requestId", ""))

    let maxLen = repeat('a', 128)
    let req2 = newMockRequest(headerMap = @[("x-request-id", maxLen)])
    let res2 = newMockResponse()
    var next2 = false
    runMiddlewareChain(@[requestId(trustUpstream = true)], req2, res2,
      flagHandler(addr next2))
    check req2.locals.getOrDefault("requestId", "") == maxLen
    check res2.get("x-request-id") == maxLen

  test "trustUpstream=false ignores the upstream header (regression)":
    let req = newMockRequest(headerMap = @[("x-request-id", "upstream-abc123")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[requestId()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    let id = req.locals.getOrDefault("requestId", "")
    check id != "upstream-abc123"
    check isLowerHex32(id)

  test "custom headerName is read, response header stays X-Request-Id (regression)":
    let req = newMockRequest(headerMap = @[("x-correlation-id", "corr-1")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[requestId(trustUpstream = true, headerName = "x-correlation-id")],
      req, res, flagHandler(addr nextCalled))
    check nextCalled
    let id = req.locals.getOrDefault("requestId", "")
    check id == "corr-1"
    check res.get("x-request-id") == "corr-1"

  test "overwrites requestId local set by an earlier middleware (ISSUE-6 last-write-wins)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(
      @[setLocalMiddleware("requestId", "earlier-id"), requestId()],
      req, res, flagHandler(addr nextCalled))
    check nextCalled
    let id = req.locals.getOrDefault("requestId", "")
    check id != "earlier-id"
    check isLowerHex32(id)
    check res.get("x-request-id") == id
