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

## Reference copies of the ORIGINAL allocation-based implementation, kept here
## verbatim so the span-based rewrite can be compared against real behaviour
## rather than against a re-statement of intent.
proc refStripWeakPrefix(tag: string): string =
  let trimmed = tag.strip()
  if trimmed.len >= 2 and (trimmed.startsWith("W/") or trimmed.startsWith("w/")):
    return trimmed[2..^1].strip()
  trimmed

proc refIfNoneMatchMatches(ifNoneMatch, etag: string): bool =
  let header = ifNoneMatch.strip()
  if header.len == 0 or etag.len == 0:
    return false
  if header == "*":
    return true
  for raw in header.split(','):
    let candidate = raw.strip()
    if candidate.len == 0:
      continue
    if candidate == "*":
      return true
    if refStripWeakPrefix(candidate) == refStripWeakPrefix(etag):
      return true
  false

suite "etag_core span-based If-None-Match (audit MWA-001)":
  test "span scanner agrees with the original split/strip logic on a matrix":
    let headers = @[
      "", " ", "*", " , ", "\"abc\"", "W/\"abc\"", "w/\"abc\"",
      " \"abc\" , \"def\" ", "\"a,b\"", "\"abc", "abc,,def", "\t\"abc\"\t",
      "abc, *", "\"ABC\"", "\"\"", "\"abc\",\"abc\"", "x,\"abc\"", "\"abc\",",
      "W/abc", "\"abc\" ,*,\"x\"", "  ,  ", "W/\"abc\",W/\"abc\"", "\"\"",
      "\r\n\"abc\"", "*, ", "\"abc\";q=1"]
    let etags = @["", "\"abc\"", "abc", "W/\"abc\"", "\"a,b\"", "\"ABC\"",
                  "\"abc", "*", "W/", " \"abc\" "]
    var checked = 0
    var mismatches = 0
    var firstMismatch = ""
    for h in headers:
      for e in etags:
        let want = refIfNoneMatchMatches(h, e)
        let got = ifNoneMatchMatches(h, e)
        if want != got:
          if mismatches == 0:
            firstMismatch = "header=" & escape(h) & " etag=" & escape(e) &
              " want=" & $want & " got=" & $got
          inc mismatches
        inc checked
    check checked == headers.len * etags.len
    if mismatches != 0:
      echo "firstMismatch=", firstMismatch
    check mismatches == 0

  test "stripWeakPrefix output is unchanged for adversarial validators":
    for tag in @[
      "", " ", "W/\"abc\"", "w/\"abc\"", "W/", "w/", "  W/\"abc\"  ",
      "WW/abc", "W//abc", "\"abc\"", "W/  \"abc\"  ", "W/x", "wx", "*",
      "\tW/\"a b\"\t", "W/\"\"", "W/\"\"abc\""]:
      check stripWeakPrefix(tag) == refStripWeakPrefix(tag)
