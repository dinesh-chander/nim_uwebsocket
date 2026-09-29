import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/app
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/method_override

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

suite "method_override unit":
  test "defaultMethodOverrideOptions shape (regression)":
    let d = defaultMethodOverrideOptions()
    check d.sources == @[mosHeader, mosQuery, mosForm]
    check d.headerName == "x-http-method-override"
    check d.queryParam == "_method"
    check d.formField == "_method"
    check d.fromMethods == {hmPost}
    check d.allowedMethods == {hmPut, hmPatch, hmDelete}
    check not d.rejectInvalid
    check d.rejectStatus == 400
    check d.plusAsSpace
    check d.maxFormBytes == DefaultMethodOverrideMaxFormBytes
    check d.auditHook == nil

  test "resolveOverrideMethod: header source resolves PUT (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "PUT")])
    let r = resolveOverrideMethod(req)
    check r.kind == morkResolved
    check r.methodKind == hmPut
    check r.source == mosHeader
    check r.rawToken == "PUT"

  test "resolveOverrideMethod: lowercase token is uppercased (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "  patch  ")])
    let r = resolveOverrideMethod(req)
    check r.kind == morkResolved
    check r.methodKind == hmPatch
    check r.rawToken == "PATCH"

  test "resolveOverrideMethod: query source resolves delete (regression)":
    let req = newMockRequest(methodKind = hmPost)
    req.native.query["_method"] = "delete"
    let r = resolveOverrideMethod(req)
    check r.kind == morkResolved
    check r.methodKind == hmDelete
    check r.source == mosQuery
    check r.rawToken == "DELETE"

  test "resolveOverrideMethod: form source resolves patch (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = "name=x&_method=patch",
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let r = resolveOverrideMethod(req)
    check r.kind == morkResolved
    check r.methodKind == hmPatch
    check r.source == mosForm
    check r.rawToken == "PATCH"

  test "resolveOverrideMethod: form value decodes + and %XX (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = "_method=put&other=a%20b",
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let r = resolveOverrideMethod(req)
    check r.kind == morkResolved
    check r.methodKind == hmPut

  test "resolveOverrideMethod: header beats query beats form (precedence)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = "_method=patch",
      headerMap = @[
        ("x-http-method-override", "PUT"),
        ("content-type", "application/x-www-form-urlencoded")
      ])
    req.native.query["_method"] = "delete"
    let r = resolveOverrideMethod(req)
    check r.kind == morkResolved
    check r.source == mosHeader
    check r.methodKind == hmPut

  test "resolveOverrideMethod: query beats form when header absent":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = "_method=patch",
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    req.native.query["_method"] = "delete"
    let r = resolveOverrideMethod(req)
    check r.kind == morkResolved
    check r.source == mosQuery
    check r.methodKind == hmDelete

  test "resolveOverrideMethod: no candidates yields morkNone (regression)":
    let req = newMockRequest(methodKind = hmPost)
    check resolveOverrideMethod(req).kind == morkNone

  test "resolveOverrideMethod: non-POST is not eligible (regression)":
    let req = newMockRequest(
      methodKind = hmGet,
      headerMap = @[("x-http-method-override", "PUT")])
    check resolveOverrideMethod(req).kind == morkNone

  test "resolveOverrideMethod: fromMethods gate is configurable":
    var opts = defaultMethodOverrideOptions()
    opts.fromMethods = {hmGet, hmPost}
    let req = newMockRequest(
      methodKind = hmGet,
      headerMap = @[("x-http-method-override", "PUT")])
    let r = resolveOverrideMethod(req, opts)
    check r.kind == morkResolved
    check r.methodKind == hmPut

  test "resolveOverrideMethod: nil request yields morkNone":
    check resolveOverrideMethod(nil).kind == morkNone

  test "resolveOverrideMethod: unparseable token yields morkInvalidToken (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "FLY")])
    let r = resolveOverrideMethod(req)
    check r.kind == morkInvalidToken
    check r.source == mosHeader
    check r.rawToken == "FLY"

  test "resolveOverrideMethod: non-alpha token treated as absent (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "PU1")])
    check resolveOverrideMethod(req).kind == morkNone

  test "resolveOverrideMethod: disallowed target yields morkDisallowedTarget (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "GET")])
    let r = resolveOverrideMethod(req)
    check r.kind == morkDisallowedTarget
    check r.methodKind == hmGet
    check r.source == mosHeader

  test "resolveOverrideMethod: CONNECT and TRACE are not valid targets (ISSUE-4)":
    for tok in ["CONNECT", "TRACE"]:
      let req = newMockRequest(
        methodKind = hmPost,
        headerMap = @[("x-http-method-override", tok)])
      let r = resolveOverrideMethod(req)
      check r.kind == morkInvalidToken
      check r.source == mosHeader

  test "resolveOverrideMethod: 16-char alpha token treated as absent (ISSUE-3)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "A".repeat(16))])
    check resolveOverrideMethod(req).kind == morkNone

  test "resolveOverrideMethod: 15-char alpha token still reported invalid (ISSUE-3)":
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "A".repeat(15))])
    check resolveOverrideMethod(req).kind == morkInvalidToken

  test "resolveOverrideMethod: oversized form body is not materialized (ISSUE-1)":
    let big = "_method=put&pad=" & "a".repeat(16 * 1024)
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = big,
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let r = resolveOverrideMethod(req)
    check r.kind == morkNone
    check req.body.len == 0

  test "resolveOverrideMethod: custom maxFormBytes enforced pre-bind (ISSUE-1)":
    var opts = defaultMethodOverrideOptions()
    opts.maxFormBytes = 16
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = "_method=put&pad=12345678",
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let r = resolveOverrideMethod(req, opts)
    check r.kind == morkNone
    check req.body.len == 0

  test "resolveOverrideMethod: form body within limit still parses (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = "_method=put&pad=" & "a".repeat(100),
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let r = resolveOverrideMethod(req)
    check r.kind == morkResolved
    check r.methodKind == hmPut
    check r.source == mosForm

  test "resolveOverrideMethod: non-form content-type is ignored (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = "_method=put",
      headerMap = @[("content-type", "application/json")])
    check resolveOverrideMethod(req).kind == morkNone

  test "applyMethodOverride: rewrites wrapper and native, audit hook args (regression)":
    var auditCalled = false
    var orig, newM: HttpMethod
    var src: MethodOverrideSource
    var tok = ""
    var opts = defaultMethodOverrideOptions()
    opts.auditHook =
      proc(req: Req, o: HttpMethod, n: HttpMethod, s: MethodOverrideSource, t: string) =
        auditCalled = true
        orig = o
        newM = n
        src = s
        tok = t
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "put")])
    check applyMethodOverride(req, opts)
    check req.methodKind == hmPut
    check req.native.methodKind == hmPut
    check auditCalled
    check orig == hmPost
    check newM == hmPut
    check src == mosHeader
    check tok == "PUT"

  test "applyMethodOverride: no override leaves method untouched (regression)":
    var auditCalled = false
    var opts = defaultMethodOverrideOptions()
    opts.auditHook =
      proc(req: Req, o: HttpMethod, n: HttpMethod, s: MethodOverrideSource, t: string) =
        auditCalled = true
    let req = newMockRequest(methodKind = hmPost)
    check not applyMethodOverride(req, opts)
    check req.methodKind == hmPost
    check not auditCalled

  test "applyMethodOverride: throwing audit hook does not crash (regression)":
    var opts = defaultMethodOverrideOptions()
    opts.auditHook =
      proc(req: Req, o: HttpMethod, n: HttpMethod, s: MethodOverrideSource, t: string) =
        raise newException(ValueError, "boom")
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "PUT")])
    check applyMethodOverride(req, opts)
    check req.methodKind == hmPut

  test "applyMethodOverride: same-method resolution is a no-op (regression)":
    var auditCalled = false
    var opts = defaultMethodOverrideOptions()
    opts.allowedMethods = {hmPost, hmPut, hmPatch, hmDelete}
    opts.auditHook =
      proc(req: Req, o: HttpMethod, n: HttpMethod, s: MethodOverrideSource, t: string) =
        auditCalled = true
    let req = newMockRequest(
      methodKind = hmPost,
      headerMap = @[("x-http-method-override", "POST")])
    check not applyMethodOverride(req, opts)
    check req.methodKind == hmPost
    check not auditCalled

suite "method_override integration":
  test "POST + header override hits PUT route (advice runs before route match)":
    let app = newExpressApp()
    var putCalled = false
    app.put "/thing", proc(req: Request, res: Response) =
      putCalled = true
      res.send("put")
    installMethodOverride(app)
    let req = newMockRequest(
      pathVal = "/thing", methodKind = hmPost,
      headerMap = @[("x-http-method-override", "PUT")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check putCalled
    check req.methodKind == hmPut
    check res.finished

  test "POST + query _method hits DELETE route":
    let app = newExpressApp()
    var delCalled = false
    app.delete "/thing", proc(req: Request, res: Response) =
      delCalled = true
      res.send("del")
    installMethodOverride(app)
    let req = newMockRequest(pathVal = "/thing", methodKind = hmPost)
    req.native.query["_method"] = "delete"
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check delCalled
    check req.methodKind == hmDelete

  test "POST + form _method hits PATCH route":
    let app = newExpressApp()
    var patchCalled = false
    app.patch "/thing", proc(req: Request, res: Response) =
      patchCalled = true
      res.send("patch")
    installMethodOverride(app)
    let req = newMockRequest(
      pathVal = "/thing", methodKind = hmPost,
      bodyStr = "_method=patch",
      headerMap = @[("content-type", "application/x-www-form-urlencoded")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check patchCalled
    check req.methodKind == hmPatch

  test "GET + override header is not rewritten (POST-only gate)":
    let app = newExpressApp()
    var getCalled = false
    app.get "/thing", proc(req: Request, res: Response) =
      getCalled = true
      res.send("get")
    installMethodOverride(app)
    let req = newMockRequest(
      pathVal = "/thing", methodKind = hmGet,
      headerMap = @[("x-http-method-override", "PUT")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check getCalled
    check req.methodKind == hmGet

  test "rejectInvalid sends configured status and stops the chain":
    let app = newExpressApp()
    var postCalled = false
    app.post "/thing", proc(req: Request, res: Response) =
      postCalled = true
      res.send("post")
    var opts = defaultMethodOverrideOptions()
    opts.rejectInvalid = true
    opts.rejectStatus = 400
    installMethodOverride(app, opts)
    let req = newMockRequest(
      pathVal = "/thing", methodKind = hmPost,
      headerMap = @[("x-http-method-override", "FLY")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check not postCalled
    check res.finished
    check res.statusCode == 400

  test "audit hook failure is forwarded to app.errorHook (ISSUE-2)":
    let app = newExpressApp()
    var putCalled = false
    app.put "/thing", proc(req: Request, res: Response) =
      putCalled = true
      res.send("put")
    var opts = defaultMethodOverrideOptions()
    opts.auditHook =
      proc(req: Req, o: HttpMethod, n: HttpMethod, s: MethodOverrideSource, t: string) =
        raise newException(ValueError, "audit boom")
    installMethodOverride(app, opts)
    var errorMsg = ""
    app.errorHook = proc(msg: string) =
      errorMsg = msg
    let req = newMockRequest(
      pathVal = "/thing", methodKind = hmPost,
      headerMap = @[("x-http-method-override", "PUT")])
    let res = newMockResponse()
    res.app = app
    waitFor app.handleRequestForTest(req, res)
    check putCalled
    check req.methodKind == hmPut
    check errorMsg.find("method_override: audit hook failed") >= 0
    check errorMsg.find("audit boom") >= 0

  test "options.sources is snapshotted at install time (ISSUE-9)":
    let app = newExpressApp()
    var putCalled = false
    app.put "/thing", proc(req: Request, res: Response) =
      putCalled = true
      res.send("put")
    var opts = defaultMethodOverrideOptions()
    opts.sources = @[mosHeader]
    installMethodOverride(app, opts)
    opts.sources[0] = mosQuery
    let req = newMockRequest(
      pathVal = "/thing", methodKind = hmPost,
      headerMap = @[("x-http-method-override", "PUT")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check putCalled
    check req.methodKind == hmPut
