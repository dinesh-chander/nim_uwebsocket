import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/etag

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

suite "etag unit":
  test "stableHash64 is deterministic and matches FNV-1a offset basis for empty input":
    check stableHash64("") == 0xcbf29ce484222325'u64
    check stableHash64("abc") == stableHash64("abc")
    check stableHash64("a") != stableHash64("b")

  test "generateETag weak/strong framing (regression)":
    let weak = generateETag("hello", etWeak)
    let strong = generateETag("hello", etStrong)
    check weak.startsWith("W/\"") and weak.endsWith("\"")
    check strong.startsWith("\"") and strong.endsWith("\"")
    check generateETag("hello") == weak
    check weak != strong

  test "generateETag encodes content length prefix and is deterministic (ISSUE-2)":
    let tag = generateETag("hello", etStrong)
    check tag.startsWith("\"5:")
    check generateETag("hello") == generateETag("hello")
    check generateETag("a") != generateETag("b")

  test "weakEqual ignores weak prefix and whitespace (ISSUE-4/5)":
    check weakEqual("W/\"abc\"", "\"abc\"")
    check weakEqual("w/\"abc\"", "\"abc\"")
    check weakEqual("  W/\"abc\"  ", "\"abc\"")
    check not weakEqual("\"abc\"", "\"def\"")

  test "ifNoneMatchMatches: wildcard, weak comparison, comma list (ISSUE-6)":
    check ifNoneMatchMatches("*", "W/\"abc\"")
    check not ifNoneMatchMatches("", "W/\"abc\"")
    check ifNoneMatchMatches("W/\"abc\"", "W/\"abc\"")
    check ifNoneMatchMatches("\"abc\"", "W/\"abc\"")
    check not ifNoneMatchMatches("W/\"abc\"", "\"def\"")
    check ifNoneMatchMatches("\"a\", W/\"abc\"", "W/\"abc\"")
    check not ifNoneMatchMatches("\"a\", \"b\"", "W/\"abc\"")

  test "methodAllowed: empty CSV defaults to GET/HEAD, case/whitespace tolerant (ISSUE-7)":
    check methodAllowed(hmGet, "")
    check methodAllowed(hmHead, "")
    check not methodAllowed(hmPost, "")
    check methodAllowed(hmGet, "GET,POST")
    check methodAllowed(hmPost, "get,post")
    check not methodAllowed(hmDelete, "GET, POST")
    check methodAllowed(hmPut, "GET,PUT ,DELETE")

suite "etag integration":
  test "etag() sets configuration locals and passes through (regression)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[etag()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check res.locals[EtagLocalEnabled] == "1"
    check res.locals[EtagLocalMode] == "weak"
    check res.locals[EtagLocalAllowedMethods] == "GET,HEAD"
    check res.locals[EtagLocalRespectExisting] == "1"

  test "etag(strong) sets strong mode + custom methods + no respect-existing (ISSUE-2/7)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[etag(ETagOptions(mode: etStrong, allowedMethods: {hmGet, hmPost}, respectExistingHeader: false))], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check res.locals[EtagLocalMode] == "strong"
    check res.locals[EtagLocalAllowedMethods] == "GET,POST"
    check res.locals[EtagLocalRespectExisting] == "0"
