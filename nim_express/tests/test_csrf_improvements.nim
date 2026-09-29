import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/csrf

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

proc runSyncMiddlewareChain(
  middlewares: seq[SyncNextMiddleware],
  req: Request, res: Response
) =
  var idx = 0
  proc advance() =
    if idx < middlewares.len:
      let current = middlewares[idx]
      inc idx
      current(req, res, advance)
    elif not res.finished:
      res.status(200)
      res.send("ok")
  advance()

proc isLowerHex(s: string): bool =
  if s.len != 40:
    return false
  for c in s:
    if not (c in {'0'..'9'} or c in {'a'..'f'}):
      return false
  return true

suite "csrf unit":
  test "csrfGenerateToken yields a 40-char lowercase hex token, unique per call":
    let t1 = csrfGenerateToken()
    let t2 = csrfGenerateToken()
    check t1.len == 40
    check isLowerHex(t1)
    check isLowerHex(t2)
    check t1 != t2

  test "csrfConstantTimeEqual: equality, mismatch, length, case (ISSUE-5)":
    check csrfConstantTimeEqual("abc", "abc")
    check not csrfConstantTimeEqual("abc", "abd")
    check not csrfConstantTimeEqual("abc", "abcd")
    check not csrfConstantTimeEqual("abcd", "abc")
    check csrfConstantTimeEqual("", "")
    check not csrfConstantTimeEqual("", "a")
    check not csrfConstantTimeEqual("a", "")
    # Case-insensitive hex comparison
    check csrfConstantTimeEqual("ABC", "abc")
    check csrfConstantTimeEqual("aBc0123", "AbC0123")
    check csrfConstantTimeEqual("DEADBEEF", "deadbeef")
    check not csrfConstantTimeEqual("DEADBEEF", "deadbeeg")

  test "defaultCsrfOptions: JS-readable cookie for header double-submit (ISSUE-2)":
    let d = defaultCsrfOptions()
    check d.httpOnlyCookie == false
    check d.secureCookie == true
    check d.allowClientReadableCookie == true
    check d.allowQueryToken == false
    check d.ignoreMethodsSet == true
    check d.ignoreMethods == {hmGet, hmHead, hmOptions}

  test "normalizeCsrfOptions: partial options keep production fail-safes (regression)":
    let n = normalizeCsrfOptions(CsrfOptions(cookieName: "custom_csrf"))
    check n.cookieName == "custom_csrf"
    check n.secureCookie == true
    check n.httpOnlyCookie == true
    check n.ignoreMethods == {hmGet, hmHead, hmOptions}

  test "normalizeCsrfOptions: explicit opt-outs win over fail-safes (regression)":
    let n = normalizeCsrfOptions(CsrfOptions(
      secureCookie: false, httpOnlyCookie: false,
      allowInsecureCookie: true, allowClientReadableCookie: true))
    check n.secureCookie == false
    check n.httpOnlyCookie == false

  test "normalizeCsrfOptions: explicit empty ignoreMethods is honored (ISSUE-1)":
    let n1 = normalizeCsrfOptions(CsrfOptions(ignoreMethods: {}, ignoreMethodsSet: true))
    check n1.ignoreMethods == {}
    let n2 = normalizeCsrfOptions(CsrfOptions(ignoreMethods: {}))
    check n2.ignoreMethods == {hmGet, hmHead, hmOptions}

  test "normalizeCsrfOptions: rejectStatus range validation (regression)":
    check normalizeCsrfOptions(CsrfOptions(rejectStatus: 200)).rejectStatus == 403
    check normalizeCsrfOptions(CsrfOptions(rejectStatus: 418)).rejectStatus == 418
    check normalizeCsrfOptions(CsrfOptions(rejectStatus: 700)).rejectStatus == 403

suite "csrf integration":
  test "GET (safe method) passes, stores token, emits cookie (regression)":
    let req = newMockRequest(methodKind = hmGet)
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[csrf()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check csrfToken(req).len == 40
    check res.get("set-cookie").find("_csrf=") >= 0

  test "HEAD and OPTIONS (safe methods) pass (regression)":
    for m in [hmHead, hmOptions]:
      let req = newMockRequest(methodKind = m)
      let res = newMockResponse()
      var nextCalled = false
      runMiddlewareChain(@[csrf()], req, res, flagHandler(addr nextCalled))
      check nextCalled
      check res.statusCode == 200

  test "POST with no token is rejected (403) (regression)":
    let req = newMockRequest(methodKind = hmPost)
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[csrf()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403

  test "POST with matching cookie + header token passes (double-submit)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("cookie", "_csrf=tok123"), ("x-csrf-token", "tok123")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[csrf()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200

  test "POST with mismatched token is rejected (403) (ISSUE-5)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("cookie", "_csrf=aaa"), ("x-csrf-token", "bbb")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[csrf()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403

  test "POST token supplied via form field fallback passes (ISSUE-4)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("cookie", "_csrf=formtok")])
    req.locals["form__csrf"] = "formtok"
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[csrf()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200

  test "rotatePerRequest issues a new token after a valid POST (ISSUE-7)":
    var o = defaultCsrfOptions()
    o.rotatePerRequest = true
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("cookie", "_csrf=orig"), ("x-csrf-token", "orig")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[csrf(o)], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check csrfToken(req).len == 40
    check csrfToken(req) != "orig"
    check res.get("set-cookie").find("_csrf=") >= 0

suite "csrfSync integration":
  test "GET (safe method) passes, stores token, emits cookie (ISSUE-8)":
    let req = newMockRequest(methodKind = hmGet)
    let res = newMockResponse()
    runSyncMiddlewareChain(@[csrfSync()], req, res)
    check res.statusCode == 200
    check csrfToken(req).len == 40
    check res.get("set-cookie").find("_csrf=") >= 0

  test "POST with no token is rejected (403) (ISSUE-8)":
    let req = newMockRequest(methodKind = hmPost)
    let res = newMockResponse()
    runSyncMiddlewareChain(@[csrfSync()], req, res)
    check res.statusCode == 403

  test "POST with mismatched token is rejected (403) (ISSUE-8)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("cookie", "_csrf=aaa"), ("x-csrf-token", "bbb")])
    let res = newMockResponse()
    runSyncMiddlewareChain(@[csrfSync()], req, res)
    check res.statusCode == 403

  test "POST with matching cookie + header token passes (ISSUE-8)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("cookie", "_csrf=tok123"), ("x-csrf-token", "tok123")])
    let res = newMockResponse()
    runSyncMiddlewareChain(@[csrfSync()], req, res)
    check res.statusCode == 200

  test "POST token supplied via form field fallback passes (ISSUE-8)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("cookie", "_csrf=formtok")])
    req.locals["form__csrf"] = "formtok"
    let res = newMockResponse()
    runSyncMiddlewareChain(@[csrfSync()], req, res)
    check res.statusCode == 200
