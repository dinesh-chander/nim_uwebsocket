import std/[unittest, asyncdispatch, json, strutils]
import ../src/nim_express/app
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/panic_recovery
import ../src/nim_express/middlewares/error_handler
import ../src/nim_express/middlewares/logger
import ../src/nim_express/middlewares/json_logger
import ../src/nim_express/middlewares/circuit_breaker
import ../src/nim_express/middlewares/global_error_filter

proc newMockHttpResponse(): HttpResponse =
  new(result)
  result.socket = nil
  result.ssl = 0
  result.statusCode = Http200
  result.statusCodeInt = 200
  result.requestMethod = hmGet
  result.requestIsHttp11 = true
  result.autoEnd = false
  result.connectionClose = false
  result.headersInited = false
  result.bodySent = false
  result.headersSent = false
  result.chunkedStarted = false
  result.chunkedFinished = false
  result.headers = newFastMap[string]()
  discard result.headers.reserve(8)
  result.capturedHeader = ""
  result.capturedBody = ""
  result.capturedRaw = ""

proc newMockHttpRequest(
  pathVal: string = "/",
  methodKind: HttpMethod = hmGet,
  bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1",
  headerMap: seq[(string, string)] = @[]
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
  pathVal: string = "/",
  methodKind: HttpMethod = hmGet,
  bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1",
  headerMap: seq[(string, string)] = @[]
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr, headerMap)
  result = newRequest(native)

proc newMockResponse(): Response =
  let nativeRes = newMockHttpResponse()
  new(result)
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

proc getCapturedBody(res: Response): string =
  if res.native != nil:
    return res.native.capturedBody
  ""

suite "Gap 1: Real ExpressApp pipeline basic tests":
  test "basic GET route returns 200":
    let app = newExpressApp()
    app.get "/hello", proc(req: Request, res: Response) =
      res.send("hello world")
    let req = newMockRequest("/hello")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "basic GET route with custom status":
    let app = newExpressApp()
    app.get "/created", proc(req: Request, res: Response) =
      res.status(201).send("created")
    let req = newMockRequest("/created")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 201

  test "unmatched route returns 404":
    let app = newExpressApp()
    app.get "/exists", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/missing")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 404
    check res.finished == true

  test "POST route matches POST method":
    let app = newExpressApp()
    app.post "/submit", proc(req: Request, res: Response) =
      res.status(201).send("submitted")
    let req = newMockRequest("/submit", hmPost)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 201
    check res.finished == true

  test "PUT route matches PUT method":
    let app = newExpressApp()
    app.put "/update", proc(req: Request, res: Response) =
      res.status(200).send("updated")
    let req = newMockRequest("/update", hmPut)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 200
    check res.finished == true

  test "DELETE route matches DELETE method":
    let app = newExpressApp()
    app.delete "/remove", proc(req: Request, res: Response) =
      res.status(204).send("")
    let req = newMockRequest("/remove", hmDelete)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 204
    check res.finished == true

  test "PATCH route matches PATCH method":
    let app = newExpressApp()
    app.patch "/modify", proc(req: Request, res: Response) =
      res.send("patched")
    let req = newMockRequest("/modify", hmPatch)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 200
    check res.finished == true

  test "GET does not match POST route":
    let app = newExpressApp()
    app.post "/only-post", proc(req: Request, res: Response) =
      res.send("posted")
    let req = newMockRequest("/only-post", hmGet)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 405

  test "dynamic route with param":
    let app = newExpressApp()
    app.get "/users/:id", proc(req: Request, res: Response) =
      let userId = req.params.getOrDefault("id", "")
      res.send("user:" & userId)
    let req = newMockRequest("/users/42")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 200
    check res.finished == true
    check res.getCapturedBody().contains("user:42")

  test "dynamic route with multiple params":
    let app = newExpressApp()
    app.get "/orgs/:org/users/:id", proc(req: Request, res: Response) =
      let org = req.params.getOrDefault("org", "")
      let id = req.params.getOrDefault("id", "")
      res.send(org & "/" & id)
    let req = newMockRequest("/orgs/acme/users/7")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("acme/7")

  test "async route handler works through pipeline":
    let app = newExpressApp()
    app.getAsync "/async", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
      res.send("async-done")
    let req = newMockRequest("/async")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "async middleware discard next waits for downstream route":
    let app = newExpressApp()
    var handlerCompleted = false
    app.use(proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      discard next()
    )
    app.getAsync "/discard-next", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(5)
      handlerCompleted = true
      res.send("done")
    let req = newMockRequest("/discard-next")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check handlerCompleted
    check res.finished == true
    check res.statusCode == 200
    check res.getCapturedBody().contains("done")

  test "multiple routes only match correct one":
    let app = newExpressApp()
    app.get "/a", proc(req: Request, res: Response) =
      res.send("route-a")
    app.get "/b", proc(req: Request, res: Response) =
      res.send("route-b")
    app.get "/c", proc(req: Request, res: Response) =
      res.send("route-c")
    let req = newMockRequest("/b")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("route-b")

  test "json response through pipeline":
    let app = newExpressApp()
    app.get "/json", proc(req: Request, res: Response) =
      res.json(%*{"key": "value"})
    let req = newMockRequest("/json")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

suite "Gap 2: RouteGroup and prefix mounting":
  test "group with prefix routes correctly":
    let app = newExpressApp()
    let api = app.group("/api")
    api.get "/users", proc(req: Request, res: Response) =
      res.send("api-users")
    let req = newMockRequest("/api/users")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("api-users")

  test "group route does not match without prefix":
    let app = newExpressApp()
    let api = app.group("/api")
    api.get "/users", proc(req: Request, res: Response) =
      res.send("api-users")
    let req = newMockRequest("/users")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 404

  test "nested groups work":
    let app = newExpressApp()
    let api = app.group("/api")
    let v1 = api.group("/v1")
    v1.get "/users", proc(req: Request, res: Response) =
      res.send("v1-users")
    let req = newMockRequest("/api/v1/users")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("v1-users")

  test "nested groups do not match partial prefix":
    let app = newExpressApp()
    let api = app.group("/api")
    let v1 = api.group("/v1")
    v1.get "/users", proc(req: Request, res: Response) =
      res.send("v1-users")
    let req = newMockRequest("/api/users")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 404

  test "group-specific middleware runs for group routes":
    var middlewareRan = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      middlewareRan = true
      req.locals["group_mw"] = "yes"
      await next()
    let app = newExpressApp()
    let api = app.group("/api", mw)
    api.get "/test", proc(req: Request, res: Response) =
      res.send("group-test")
    let req = newMockRequest("/api/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check middlewareRan == true

  test "group middleware does not run for non-group routes":
    var groupMwRan = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      groupMwRan = true
      await next()
    let app = newExpressApp()
    let api = app.group("/api", mw)
    api.get "/test", proc(req: Request, res: Response) =
      res.send("group-test")
    app.get "/other", proc(req: Request, res: Response) =
      res.send("other")
    let req = newMockRequest("/other")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check groupMwRan == false

  test "multiple groups with different middlewares":
    var apiMwRan = false
    var adminMwRan = false
    let apiMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      apiMwRan = true
      await next()
    let adminMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      adminMwRan = true
      await next()
    let app = newExpressApp()
    let api = app.group("/api", apiMw)
    let admin = app.group("/admin", adminMw)
    api.get "/data", proc(req: Request, res: Response) =
      res.send("api-data")
    admin.get "/panel", proc(req: Request, res: Response) =
      res.send("admin-panel")
    block:
      apiMwRan = false
      adminMwRan = false
      let req = newMockRequest("/api/data")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
      check apiMwRan == true
      check adminMwRan == false
    block:
      apiMwRan = false
      adminMwRan = false
      let req = newMockRequest("/admin/panel")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
      check adminMwRan == true
      check apiMwRan == false

  test "group POST route":
    let app = newExpressApp()
    let api = app.group("/api")
    api.post "/items", proc(req: Request, res: Response) =
      res.status(201).send("created")
    let req = newMockRequest("/api/items", hmPost)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 201

  test "group PUT route":
    let app = newExpressApp()
    let api = app.group("/api")
    api.put "/items", proc(req: Request, res: Response) =
      res.send("updated")
    let req = newMockRequest("/api/items", hmPut)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "group DELETE route":
    let app = newExpressApp()
    let api = app.group("/api")
    api.delete "/items", proc(req: Request, res: Response) =
      res.status(204).send("")
    let req = newMockRequest("/api/items", hmDelete)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 204

  test "group PATCH route":
    let app = newExpressApp()
    let api = app.group("/api")
    api.patch "/items", proc(req: Request, res: Response) =
      res.send("patched")
    let req = newMockRequest("/api/items", hmPatch)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "group with dynamic param route":
    let app = newExpressApp()
    let api = app.group("/api")
    api.get "/users/:id", proc(req: Request, res: Response) =
      let id = req.params.getOrDefault("id", "")
      res.send("user:" & id)
    let req = newMockRequest("/api/users/99")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("user:99")

  test "group async route":
    let app = newExpressApp()
    let api = app.group("/api")
    api.getAsync "/slow", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
      res.send("slow-done")
    let req = newMockRequest("/api/slow")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "group middleware order: global runs before group":
    var order: seq[string] = @[]
    let globalMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("global")
      await next()
    let groupMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("group")
      await next()
    let app = newExpressApp()
    app.use(globalMw)
    let api = app.group("/api", groupMw)
    api.get "/test", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/api/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check order == @["global", "group", "handler"]

  test "deeply nested group three levels":
    let app = newExpressApp()
    let api = app.group("/api")
    let v2 = api.group("/v2")
    let admin = v2.group("/admin")
    admin.get "/dashboard", proc(req: Request, res: Response) =
      res.send("deep-dashboard")
    let req = newMockRequest("/api/v2/admin/dashboard")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("deep-dashboard")

suite "Gap 3: Path-scoped middleware":
  test "path-scoped middleware runs for matching path":
    var ran = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      ran = true
      await next()
    let app = newExpressApp()
    app.use("/api", mw)
    app.get "/api/data", proc(req: Request, res: Response) =
      res.send("data")
    let req = newMockRequest("/api/data")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == true

  test "path-scoped middleware skips non-matching path":
    var ran = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      ran = true
      await next()
    let app = newExpressApp()
    app.use("/api", mw)
    app.get "/web/page", proc(req: Request, res: Response) =
      res.send("page")
    let req = newMockRequest("/web/page")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == false

  test "multiple path-scoped middlewares on different paths":
    var apiRan = false
    var webRan = false
    let apiMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      apiRan = true
      await next()
    let webMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      webRan = true
      await next()
    let app = newExpressApp()
    app.use("/api", apiMw)
    app.use("/web", webMw)
    app.get "/api/test", proc(req: Request, res: Response) =
      res.send("api")
    app.get "/web/test", proc(req: Request, res: Response) =
      res.send("web")
    block:
      apiRan = false
      webRan = false
      let req = newMockRequest("/api/test")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check apiRan == true
      check webRan == false
    block:
      apiRan = false
      webRan = false
      let req = newMockRequest("/web/test")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check apiRan == false
      check webRan == true

  test "path-scoped middleware combined with global middleware":
    var order: seq[string] = @[]
    let globalMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("global")
      await next()
    let apiMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("api")
      await next()
    let app = newExpressApp()
    app.use(globalMw)
    app.use("/api", apiMw)
    app.get "/api/test", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/api/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check order == @["global", "api", "handler"]

  test "path-scoped middleware does not match similar but different prefix":
    var ran = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      ran = true
      await next()
    let app = newExpressApp()
    app.use("/api", mw)
    app.get "/apiv2/test", proc(req: Request, res: Response) =
      res.send("v2")
    let req = newMockRequest("/apiv2/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == false

  test "path-scoped middleware matches exact path":
    var ran = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      ran = true
      await next()
    let app = newExpressApp()
    app.use("/api", mw)
    app.get "/api", proc(req: Request, res: Response) =
      res.send("api-root")
    let req = newMockRequest("/api")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == true

  test "path-scoped middleware with nested subpath":
    var ran = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      ran = true
      await next()
    let app = newExpressApp()
    app.use("/api", mw)
    app.get "/api/v1/users/42/profile", proc(req: Request, res: Response) =
      res.send("deep-path")
    let req = newMockRequest("/api/v1/users/42/profile")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == true

  test "path-scoped SyncNextMiddleware via use overload":
    var ran = false
    let syncMw: SyncNextMiddleware = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.} =
      ran = true
      next()
    let app = newExpressApp()
    app.use("/api", syncMw)
    app.get "/api/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/api/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == true

  test "global middleware runs even when path-scoped skips":
    var globalRan = false
    var scopedRan = false
    let globalMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      globalRan = true
      await next()
    let scopedMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      scopedRan = true
      await next()
    let app = newExpressApp()
    app.use(globalMw)
    app.use("/api", scopedMw)
    app.get "/other", proc(req: Request, res: Response) =
      res.send("other")
    let req = newMockRequest("/other")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check globalRan == true
    check scopedRan == false

  test "path-scoped middleware with root prefix matches everything":
    var ran = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      ran = true
      await next()
    let app = newExpressApp()
    app.use("/", mw)
    app.get "/anything", proc(req: Request, res: Response) =
      res.send("anything")
    let req = newMockRequest("/anything")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == true

  test "multiple path-scoped middlewares on same path run in order":
    var order: seq[string] = @[]
    let mw1: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("first")
      await next()
    let mw2: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("second")
      await next()
    let app = newExpressApp()
    app.use("/api", mw1)
    app.use("/api", mw2)
    app.get "/api/test", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/api/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check order == @["first", "second", "handler"]

  test "path-scoped middleware for POST routes":
    var ran = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      ran = true
      await next()
    let app = newExpressApp()
    app.use("/api", mw)
    app.post "/api/submit", proc(req: Request, res: Response) =
      res.status(201).send("ok")
    let req = newMockRequest("/api/submit", hmPost)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == true
    check res.statusCode == 201

  test "path-scoped middleware setting locals used by handler":
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["auth"] = "admin"
      await next()
    let app = newExpressApp()
    app.use("/secure", mw)
    app.get "/secure/data", proc(req: Request, res: Response) =
      let auth = req.locals.getOrDefault("auth", "none")
      res.send("auth:" & auth)
    let req = newMockRequest("/secure/data")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("auth:admin")

suite "Gap 4: Sync middleware":
  test "sync middleware via useSync works":
    var ran = false
    let syncMw: SyncNextMiddleware = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.} =
      ran = true
      next()
    let app = newExpressApp()
    app.useSync(syncMw)
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == true

  test "useSync runs on production native fast path":
    var ran = false
    let syncMw: SyncNextMiddleware = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.} =
      ran = true
      req.locals["native_sync"] = "yes"
      next()
    let app = newExpressApp()
    app.useSync(syncMw)
    app.get "/native-sync", proc(req: Request, res: Response) =
      res.send("sync:" & req.locals.getOrDefault("native_sync", "no"))
    app.setupHandlersForTest()
    let nativeReq = newMockHttpRequest("/native-sync")
    let nativeRes = newMockHttpResponse()
    app.server.handler(nativeReq, nativeRes)
    check ran == true
    check nativeRes.capturedBody.contains("sync:yes")

  test "production native fast path converts unsent sync handler to 500":
    let app = newExpressApp()
    var errors: seq[string] = @[]
    app.onErrorHook(proc(message: string) =
      errors.add(message)
    )
    app.get "/native-stall", proc(req: Request, res: Response) =
      discard

    app.setupHandlersForTest()
    let nativeReq = newMockHttpRequest("/native-stall")
    let nativeRes = newMockHttpResponse()
    app.server.handler(nativeReq, nativeRes)

    check nativeRes.capturedHeader.contains("500 Internal Server Error")
    check nativeRes.capturedBody.contains("Internal Server Error")
    check errors.join("\n").contains("class=handler_stall")

  test "production native fast path request-end hook sees active request":
    let app = newExpressApp()
    var hookCalled = false
    var releasedInHook = true
    var pathInHook = ""
    app.onRequestEndHook(proc(req: Request, res: Response, durationMicros: int64) =
      hookCalled = true
      releasedInHook = req.requestReleased()
      pathInHook = req.path
    )
    app.get "/native-end-hook", proc(req: Request, res: Response) =
      res.send("ok")

    app.setupHandlersForTest()
    let nativeReq = newMockHttpRequest("/native-end-hook")
    let nativeRes = newMockHttpResponse()
    app.server.handler(nativeReq, nativeRes)

    check hookCalled
    check not releasedInHook
    check pathInHook == "/native-end-hook"
    check nativeRes.capturedBody == "ok"

  test "sync middleware that does not call next stops chain":
    var handlerRan = false
    let syncMw: SyncNextMiddleware = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.} =
      discard
    let app = newExpressApp()
    app.useSync(syncMw)
    app.get "/test", proc(req: Request, res: Response) =
      handlerRan = true
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check handlerRan == false

  test "sync middleware sets locals used by handler":
    let syncMw: SyncNextMiddleware = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.} =
      req.locals["from_sync"] = "yes"
      next()
    let app = newExpressApp()
    app.useSync(syncMw)
    app.get "/test", proc(req: Request, res: Response) =
      let val = req.locals.getOrDefault("from_sync", "no")
      res.send("sync:" & val)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("sync:yes")

  test "multiple sync middlewares run in order":
    var order: seq[string] = @[]
    let mw1: SyncNextMiddleware = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.} =
      order.add("sync1")
      next()
    let mw2: SyncNextMiddleware = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.} =
      order.add("sync2")
      next()
    let app = newExpressApp()
    app.useSync(mw1)
    app.useSync(mw2)
    app.get "/test", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check "sync1" in order
    check "sync2" in order
    check "handler" in order

  test "sync middleware via use overload (auto-converted to async)":
    var ran = false
    let syncMw: SyncNextMiddleware = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.} =
      ran = true
      next()
    let app = newExpressApp()
    app.use(syncMw)
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check ran == true

  test "sync middleware combined with async middleware":
    var order: seq[string] = @[]
    let syncMw: SyncNextMiddleware = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.} =
      order.add("sync")
      next()
    let asyncMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("async")
      await next()
    let app = newExpressApp()
    app.use(syncMw)
    app.use(asyncMw)
    app.get "/test", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check "sync" in order
    check "async" in order
    check "handler" in order

  test "async middleware resumes after downstream handler completes":
    var order: seq[string] = @[]
    let app = newExpressApp()
    app.use(proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("before")
      await next()
      order.add("after:" & res.native.capturedBody)
    )
    app.get "/post-next", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("done")
    let req = newMockRequest("/post-next")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check order == @["before", "handler", "after:done"]

suite "Gap 5: App-level error handler":
  test "custom error handler receives exception from handler":
    var errorReceived = ""
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      errorReceived = err.msg
      res.status(503).send("custom error")
    app.get "/crash", proc(req: Request, res: Response) =
      raise newException(ValueError, "handler-boom")
    let req = newMockRequest("/crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check errorReceived == "handler-boom"
    check res.statusCode == 503

  test "custom error handler can set custom status and body":
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      res.status(422).send("validation failed")
    app.getAsync "/fail", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "bad input")
    let req = newMockRequest("/fail")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 422

  test "error handler not called on success":
    var errorHandlerCalled = false
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      errorHandlerCalled = true
    app.get "/ok", proc(req: Request, res: Response) =
      res.send("all good")
    let req = newMockRequest("/ok")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check errorHandlerCalled == false

  test "error handler called when async handler throws":
    var caughtType = ""
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      caughtType = $err.name
      res.status(503).send("service error")
    app.getAsync "/io-error", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(IOError, "connection refused")
    let req = newMockRequest("/io-error")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 503
    check caughtType == "IOError"

  test "error handler called when sync handler throws":
    var caughtMsg = ""
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      caughtMsg = err.msg
      res.status(500).send("caught")
    app.get "/sync-crash", proc(req: Request, res: Response) =
      raise newException(ValueError, "sync-boom")
    let req = newMockRequest("/sync-crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check caughtMsg == "sync-boom"

  test "no error handler results in default 500":
    let app = newExpressApp()
    app.getAsync "/crash", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "unhandled")
    let req = newMockRequest("/crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500

  test "error handler with different exception types":
    var lastExcType = ""
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      lastExcType = $err.name
      if err of IOError:
        res.status(502).send("gateway error")
      elif err of KeyError:
        res.status(400).send("bad key")
      else:
        res.status(500).send("unknown error")
    app.getAsync "/io", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(IOError, "io fail")
    app.getAsync "/key", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(KeyError, "key fail")
    block:
      let req = newMockRequest("/io")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 502
      check lastExcType == "IOError"
    block:
      let req = newMockRequest("/key")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 400
      check lastExcType == "KeyError"

suite "Gap 6: Router-level middleware":
  test "router middleware runs for all routes":
    var routerMwRan = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      routerMwRan = true
      await next()
    let app = newExpressApp()
    app.router.use(mw)
    app.get "/a", proc(req: Request, res: Response) =
      res.send("a")
    app.get "/b", proc(req: Request, res: Response) =
      res.send("b")
    block:
      routerMwRan = false
      let req = newMockRequest("/a")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
      check routerMwRan == true
    block:
      routerMwRan = false
      let req = newMockRequest("/b")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
      check routerMwRan == true

  test "router middleware combined with app middleware":
    var order: seq[string] = @[]
    let appMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("app")
      await next()
    let routerMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("router")
      await next()
    let app = newExpressApp()
    app.use(appMw)
    app.router.use(routerMw)
    app.get "/test", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check order == @["app", "router", "handler"]

  test "router middleware runs even for unmatched routes":
    var routerMwRan = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      routerMwRan = true
      await next()
    let app = newExpressApp()
    app.router.use(mw)
    app.get "/exists", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/missing")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check routerMwRan == true
    check res.statusCode == 404

  test "multiple router middlewares run in order":
    var order: seq[string] = @[]
    let mw1: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("r1")
      await next()
    let mw2: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("r2")
      await next()
    let app = newExpressApp()
    app.router.use(mw1)
    app.router.use(mw2)
    app.get "/test", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check order == @["r1", "r2", "handler"]

suite "Gap 7: Middleware + routing interaction":
  test "middleware setting locals used by route handler":
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["user_id"] = "123"
      req.locals["role"] = "admin"
      await next()
    let app = newExpressApp()
    app.use(mw)
    app.get "/profile", proc(req: Request, res: Response) =
      let userId = req.locals.getOrDefault("user_id", "")
      let role = req.locals.getOrDefault("role", "")
      res.send(userId & ":" & role)
    let req = newMockRequest("/profile")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("123:admin")

  test "middleware response before handler - handler should not run":
    var handlerRan = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      res.status(401).send("unauthorized")
    let app = newExpressApp()
    app.use(mw)
    app.get "/secret", proc(req: Request, res: Response) =
      handlerRan = true
      res.send("secret data")
    let req = newMockRequest("/secret")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 401
    check res.finished == true
    check handlerRan == false

  test "404 path - middleware runs but no route matches":
    var mwRan = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      mwRan = true
      await next()
    let app = newExpressApp()
    app.use(mw)
    app.get "/exists", proc(req: Request, res: Response) =
      res.send("found")
    let req = newMockRequest("/not-here")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check mwRan == true
    check res.statusCode == 404

  test "wildcard route with middleware":
    var mwRan = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      mwRan = true
      await next()
    let app = newExpressApp()
    app.use(mw)
    app.get "/files/*path", proc(req: Request, res: Response) =
      let filePath = req.params.getOrDefault("path", "")
      res.send("file:" & filePath)
    let req = newMockRequest("/files/docs/readme.txt")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check mwRan == true
    check res.finished == true

  test "middleware does not call next - handler skipped":
    var handlerRan = false
    let blocker: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      discard
    let app = newExpressApp()
    app.use(blocker)
    app.get "/blocked", proc(req: Request, res: Response) =
      handlerRan = true
      res.send("should not run")
    let req = newMockRequest("/blocked")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check handlerRan == false

  test "middleware chain - first passes, second blocks":
    var order: seq[string] = @[]
    let mw1: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw1")
      await next()
    let mw2: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw2")
      res.status(403).send("forbidden")
    let app = newExpressApp()
    app.use(mw1)
    app.use(mw2)
    app.get "/test", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check order == @["mw1", "mw2"]
    check res.statusCode == 403

  test "middleware exception propagates":
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      raise newException(ValueError, "middleware-error")
    let app = newExpressApp()
    app.use(mw)
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500

  test "middleware modifies response headers":
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      res.set("x-custom", "middleware-value")
      await next()
    let app = newExpressApp()
    app.use(mw)
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.headers.getOrDefault("x-custom", "") == "middleware-value"

  test "three middlewares run in order before handler":
    var order: seq[string] = @[]
    let mw1: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw1")
      await next()
    let mw2: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw2")
      await next()
    let mw3: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw3")
      await next()
    let app = newExpressApp()
    app.use(mw1)
    app.use(mw2)
    app.use(mw3)
    app.get "/test", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check order == @["mw1", "mw2", "mw3", "handler"]

  test "middleware adds request id used by handler":
    let idMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["requestId"] = "req-12345"
      await next()
    let app = newExpressApp()
    app.use(idMw)
    app.get "/trace", proc(req: Request, res: Response) =
      let rid = req.locals.getOrDefault("requestId", "")
      res.set("x-request-id", rid)
      res.send("traced")
    let req = newMockRequest("/trace")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.headers.getOrDefault("x-request-id", "") == "req-12345"

  test "middleware checks request method":
    let methodGuard: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      if req.methodKind == hmDelete:
        res.status(405).send("DELETE not allowed here")
        return
      await next()
    let app = newExpressApp()
    app.use(methodGuard)
    app.get "/resource", proc(req: Request, res: Response) =
      res.send("ok")
    app.delete "/resource", proc(req: Request, res: Response) =
      res.send("deleted")
    let req = newMockRequest("/resource", hmDelete)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 405

  test "middleware conditional next based on header":
    let authMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.bindHeaders()
      let token = req.headers.getOrDefault("authorization", "")
      if token == "Bearer valid-token":
        req.locals["authenticated"] = "true"
        await next()
      else:
        res.status(401).send("unauthorized")
    let app = newExpressApp()
    app.use(authMw)
    app.get "/protected", proc(req: Request, res: Response) =
      res.send("protected-data")
    block:
      let req = newMockRequest("/protected", hmGet, "", "127.0.0.1", @[("authorization", "Bearer valid-token")])
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
      check res.statusCode == 200
    block:
      let req = newMockRequest("/protected", hmGet, "", "127.0.0.1", @[("authorization", "Bearer invalid")])
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 401

  test "middleware modifying response status but calling next":
    let statusMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      res.status(202)
      await next()
    let app = newExpressApp()
    app.use(statusMw)
    app.get "/test", proc(req: Request, res: Response) =
      res.send("accepted")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 202

  test "middleware for POST with body processing":
    let bodyMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.bindBody()
      if req.body.len > 1000:
        res.status(413).send("too large")
        return
      await next()
    let app = newExpressApp()
    app.use(bodyMw)
    app.post "/submit", proc(req: Request, res: Response) =
      res.status(201).send("ok")
    block:
      let req = newMockRequest("/submit", hmPost, "small body")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 201
    block:
      let bigBody = 'x'.repeat(1500)
      let req = newMockRequest("/submit", hmPost, bigBody)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 413

suite "Gap 8: Real middlewares through real pipeline":
  test "panic_recovery catches handler crash":
    let app = newExpressApp()
    app.use(panicRecovery(PanicRecoveryOptions(
      responseFormat: erfJson,
      logErrors: false,
      includeStackTrace: false,
      reportHook: nil
    )))
    app.getAsync "/crash", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "test crash")
    let req = newMockRequest("/crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check res.finished == true

  test "panic_recovery passes through success":
    let app = newExpressApp()
    app.use(panicRecovery(PanicRecoveryOptions(
      responseFormat: erfJson,
      logErrors: false,
      includeStackTrace: false,
      reportHook: nil
    )))
    app.get "/ok", proc(req: Request, res: Response) =
      res.send("all good")
    let req = newMockRequest("/ok")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "panic_recovery middleware passes through on success":
    let app = newExpressApp()
    app.use(panicRecovery(PanicRecoveryOptions(
      responseFormat: erfJson,
      logErrors: false,
      includeStackTrace: false,
      reportHook: nil
    )))
    app.get "/ok2", proc(req: Request, res: Response) =
      res.send("fine again")
    let req = newMockRequest("/ok2")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "panic_recovery plain text format":
    let app = newExpressApp()
    app.use(panicRecovery(PanicRecoveryOptions(
      responseFormat: erfPlainText,
      logErrors: false,
      includeStackTrace: false,
      reportHook: nil
    )))
    app.getAsync "/crash", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "text crash")
    let req = newMockRequest("/crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check res.finished == true

  test "error_handler produces RFC 7807 response":
    let app = newExpressApp()
    app.use(errorHandler(ErrorHandlerOptions(devMode: true, logErrors: false)))
    app.getAsync "/crash", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "bad value")
    let req = newMockRequest("/crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check res.finished == true

  test "error_handler passes through on success":
    let app = newExpressApp()
    app.use(errorHandler(ErrorHandlerOptions(devMode: false, logErrors: false)))
    app.get "/ok", proc(req: Request, res: Response) =
      res.send("fine")
    let req = newMockRequest("/ok")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "error_handler middleware with multiple success routes":
    let app = newExpressApp()
    app.use(errorHandler(ErrorHandlerOptions(devMode: false, logErrors: false)))
    app.get "/one", proc(req: Request, res: Response) =
      res.status(200).send("one")
    app.get "/two", proc(req: Request, res: Response) =
      res.status(201).send("two")
    block:
      let req = newMockRequest("/one")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 200
    block:
      let req = newMockRequest("/two")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 201

  test "circuit_breaker allows requests when closed":
    let cb = newCircuitBreaker("test-cb", failureThreshold = 3, successThreshold = 2, timeoutMs = 1000)
    let app = newExpressApp()
    app.use(circuitBreakerMiddleware(cb))
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200
    check cb.state == csClosed

  test "circuit_breaker rejects when manually opened":
    let cb = newCircuitBreaker("test-cb", failureThreshold = 2, successThreshold = 1, timeoutMs = 60000)
    cb.recordFailure()
    cb.recordFailure()
    check cb.state == csOpen
    let app = newExpressApp()
    app.use(circuitBreakerMiddleware(cb))
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 503

  test "circuit_breaker records success":
    let cb = newCircuitBreaker("test-cb", failureThreshold = 5, successThreshold = 2, timeoutMs = 1000)
    let app = newExpressApp()
    app.use(circuitBreakerMiddleware(cb))
    app.get "/ok", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/ok")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 200
    check cb.state == csClosed

  test "circuit_breaker records success when handler succeeds":
    let cb = newCircuitBreaker("test-cb", failureThreshold = 3, successThreshold = 1, timeoutMs = 1000)
    let app = newExpressApp()
    app.use(circuitBreakerMiddleware(cb))
    app.get "/ok", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/ok")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 200
    check cb.state == csClosed

  test "logger middleware passes through success":
    let app = newExpressApp()
    app.use(logger(llError))
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "logger middleware re-raises exceptions":
    let app = newExpressApp()
    app.use(logger(llError))
    app.getAsync "/crash", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "logged crash")
    let req = newMockRequest("/crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500

  test "json_logger middleware with custom sink":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfMethod, jlfPath, jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let app = newExpressApp()
    app.use(jsonLogger(opts))
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check logLine.contains("\"path\":\"/test\"")

  test "json_logger skips health paths":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfMethod, jlfPath, jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: true
    )
    let app = newExpressApp()
    app.use(jsonLogger(opts))
    app.get "/health", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/health")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check logLine == ""

  test "json_logger logs default status for success route":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfMethod, jlfPath, jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let app = newExpressApp()
    app.use(jsonLogger(opts))
    app.get "/ok", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/ok")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check logLine.contains("\"path\":\"/ok\"")

  test "global_error_filter passes through 200 response":
    let app = newExpressApp()
    app.use(globalErrorFilterWithBuiltins())
    app.get "/good", proc(req: Request, res: Response) =
      res.send("good")
    let req = newMockRequest("/good")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 200

  test "global_error_filter passes through 201 response":
    let app = newExpressApp()
    app.use(globalErrorFilterWithBuiltins())
    app.get "/created", proc(req: Request, res: Response) =
      res.status(201).send("created")
    let req = newMockRequest("/created")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 201

  test "global_error_filter does not interfere with 404":
    let app = newExpressApp()
    app.use(globalErrorFilterWithBuiltins())
    app.get "/exists", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/missing")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 404

  test "global_error_filter with multiple routes":
    let app = newExpressApp()
    app.use(globalErrorFilterWithBuiltins())
    app.get "/a", proc(req: Request, res: Response) =
      res.send("a")
    app.get "/b", proc(req: Request, res: Response) =
      res.status(201).send("b")
    block:
      let req = newMockRequest("/a")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 200
    block:
      let req = newMockRequest("/b")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 201

  test "global_error_filter passes through success":
    let app = newExpressApp()
    app.use(globalErrorFilterWithBuiltins())
    app.get "/ok", proc(req: Request, res: Response) =
      res.send("fine")
    let req = newMockRequest("/ok")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "global_error_filter does not alter success responses":
    let app = newExpressApp()
    app.use(globalErrorFilter(@[valueErrorFilter()]))
    app.get "/fine", proc(req: Request, res: Response) =
      res.send("fine")
    let req = newMockRequest("/fine")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 200
    check res.finished == true

  test "circuit_breaker reset allows requests after manual open":
    let cb = newCircuitBreaker("reset-cb", failureThreshold = 1, successThreshold = 1, timeoutMs = 60000)
    cb.recordFailure()
    check cb.state == csOpen
    let app = newExpressApp()
    app.use(circuitBreakerMiddleware(cb))
    app.get "/ok", proc(req: Request, res: Response) =
      res.send("ok")
    block:
      let req = newMockRequest("/ok")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 503
    cb.reset()
    check cb.state == csClosed
    block:
      let req = newMockRequest("/ok")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 200

  test "logger middleware with warn level through pipeline":
    let app = newExpressApp()
    app.use(logger(llWarn))
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "json_logger with excluded fields":
    var logLine = ""
    let opts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfMethod, jlfPath, jlfStatus},
      excludeFields: {jlfRemoteIp, jlfUserAgent},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let app = newExpressApp()
    app.use(jsonLogger(opts))
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check logLine.contains("\"method\"")
    check not logLine.contains("\"remote_ip\"")

  test "panic_recovery + error_handler stacked":
    let app = newExpressApp()
    app.use(panicRecovery(PanicRecoveryOptions(
      responseFormat: erfJson,
      logErrors: false,
      includeStackTrace: false,
      reportHook: nil
    )))
    app.use(errorHandler(ErrorHandlerOptions(devMode: false, logErrors: false)))
    app.getAsync "/crash", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "stacked crash")
    let req = newMockRequest("/crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check res.finished == true

suite "Gap 9: Response completion edge cases":
  test "handler calls send twice - second is no-op":
    let app = newExpressApp()
    app.get "/double", proc(req: Request, res: Response) =
      res.send("first")
      res.send("second")
    let req = newMockRequest("/double")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("first")

  test "middleware sends then calls next - handler should not execute response":
    var handlerRan = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      res.status(200).send("from-middleware")
      await next()
    let app = newExpressApp()
    app.use(mw)
    app.get "/test", proc(req: Request, res: Response) =
      handlerRan = true
      res.send("from-handler")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("from-middleware")

  test "handler that does not finalize gets server error":
    let app = newExpressApp()
    app.get "/no-send", proc(req: Request, res: Response) =
      res.status(204)
    let req = newMockRequest("/no-send")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check res.finished == true

  test "status then json":
    let app = newExpressApp()
    app.get "/json-status", proc(req: Request, res: Response) =
      res.status(201).json(%*{"created": true})
    let req = newMockRequest("/json-status")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 201
    check res.finished == true

  test "multiple status calls before send uses last":
    let app = newExpressApp()
    app.get "/multi-status", proc(req: Request, res: Response) =
      res.status(200)
      res.status(201)
      res.status(202)
      res.send("final")
    let req = newMockRequest("/multi-status")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 202

  test "send empty string":
    let app = newExpressApp()
    app.get "/empty", proc(req: Request, res: Response) =
      res.send("")
    let req = newMockRequest("/empty")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "jsonRaw through pipeline":
    let app = newExpressApp()
    app.get "/raw-json", proc(req: Request, res: Response) =
      res.jsonRaw("""{"fast":true}""")
    let req = newMockRequest("/raw-json")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "serverError helper through pipeline":
    let app = newExpressApp()
    app.get "/error", proc(req: Request, res: Response) =
      res.serverError("custom error message")
    let req = newMockRequest("/error")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check res.finished == true

  test "notFound helper through pipeline":
    let app = newExpressApp()
    app.get "/not-here", proc(req: Request, res: Response) =
      res.notFound()
    let req = newMockRequest("/not-here")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 404
    check res.finished == true

  test "set header after send is no-op":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.send("ok")
      res.set("x-late", "should-not-appear")
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "status after send is no-op":
    let app = newExpressApp()
    app.get "/test", proc(req: Request, res: Response) =
      res.status(200).send("ok")
      discard res.status(500)
    let req = newMockRequest("/test")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "async handler after delay sends response":
    let app = newExpressApp()
    app.getAsync "/delayed", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(5)
      res.send("delayed-response")
    let req = newMockRequest("/delayed")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.statusCode == 200

  test "badRequest helper through pipeline":
    let app = newExpressApp()
    app.get "/bad", proc(req: Request, res: Response) =
      res.badRequest("invalid input")
    let req = newMockRequest("/bad")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 400
    check res.finished == true

suite "Gap 10: Multiple routes with different middleware stacks":
  test "different routes get different middlewares":
    var publicMwRan = false
    var adminMwRan = false
    let publicMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      publicMwRan = true
      req.locals["access"] = "public"
      await next()
    let adminMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      adminMwRan = true
      req.locals["access"] = "admin"
      await next()
    let app = newExpressApp()
    let pub = app.group("/public", publicMw)
    let admin = app.group("/admin", adminMw)
    pub.get "/page", proc(req: Request, res: Response) =
      res.send("public-page")
    admin.get "/dashboard", proc(req: Request, res: Response) =
      res.send("admin-dashboard")
    block:
      publicMwRan = false
      adminMwRan = false
      let req = newMockRequest("/public/page")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
      check publicMwRan == true
      check adminMwRan == false
    block:
      publicMwRan = false
      adminMwRan = false
      let req = newMockRequest("/admin/dashboard")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
      check adminMwRan == true
      check publicMwRan == false

  test "shared global + different group middlewares":
    var globalRan = false
    var apiRan = false
    var webRan = false
    let globalMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      globalRan = true
      await next()
    let apiMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      apiRan = true
      await next()
    let webMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      webRan = true
      await next()
    let app = newExpressApp()
    app.use(globalMw)
    let api = app.group("/api", apiMw)
    let web = app.group("/web", webMw)
    api.get "/data", proc(req: Request, res: Response) =
      res.send("api-data")
    web.get "/page", proc(req: Request, res: Response) =
      res.send("web-page")
    block:
      globalRan = false
      apiRan = false
      webRan = false
      let req = newMockRequest("/api/data")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check globalRan == true
      check apiRan == true
      check webRan == false
    block:
      globalRan = false
      apiRan = false
      webRan = false
      let req = newMockRequest("/web/page")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check globalRan == true
      check webRan == true
      check apiRan == false

  test "panic_recovery shared + group-specific auth":
    var authChecked = false
    let authMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      authChecked = true
      req.bindHeaders()
      let token = req.headers.getOrDefault("authorization", "")
      if token.len == 0:
        res.status(401).send("unauthorized")
        return
      await next()
    let app = newExpressApp()
    app.use(panicRecovery(PanicRecoveryOptions(
      responseFormat: erfJson,
      logErrors: false,
      includeStackTrace: false,
      reportHook: nil
    )))
    let secured = app.group("/secured", authMw)
    secured.get "/data", proc(req: Request, res: Response) =
      res.send("secured-data")
    app.get "/public", proc(req: Request, res: Response) =
      res.send("public")
    block:
      authChecked = false
      let req = newMockRequest("/public")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
      check res.statusCode == 200
      check authChecked == false
    block:
      authChecked = false
      let req = newMockRequest("/secured/data")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check authChecked == true
      check res.statusCode == 401
    block:
      authChecked = false
      let req = newMockRequest("/secured/data", hmGet, "", "127.0.0.1", @[("authorization", "Bearer xyz")])
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check authChecked == true
      check res.statusCode == 200

  test "multiple HTTP methods with shared global middleware":
    var globalCount = 0
    let globalMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      inc globalCount
      await next()
    let app = newExpressApp()
    app.use(globalMw)
    app.get "/resource", proc(req: Request, res: Response) =
      res.send("got")
    app.post "/resource", proc(req: Request, res: Response) =
      res.status(201).send("created")
    app.delete "/resource", proc(req: Request, res: Response) =
      res.status(204).send("")
    block:
      globalCount = 0
      let req = newMockRequest("/resource", hmGet)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 200
      check globalCount == 1
    block:
      globalCount = 0
      let req = newMockRequest("/resource", hmPost)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 201
      check globalCount == 1
    block:
      globalCount = 0
      let req = newMockRequest("/resource", hmDelete)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 204
      check globalCount == 1

  test "group with error handler middleware":
    let app = newExpressApp()
    let api = app.group("/api")
    app.use(panicRecovery(PanicRecoveryOptions(
      responseFormat: erfJson,
      logErrors: false,
      includeStackTrace: false,
      reportHook: nil
    )))
    api.getAsync "/crash", proc(req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "api crash")
    let req = newMockRequest("/api/crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check res.finished == true

  test "circuit_breaker per group with manual state":
    let cbApi = newCircuitBreaker("api-cb", failureThreshold = 2, successThreshold = 1, timeoutMs = 60000)
    let cbAdmin = newCircuitBreaker("admin-cb", failureThreshold = 5, successThreshold = 2, timeoutMs = 60000)
    let app = newExpressApp()
    let api = app.group("/api", circuitBreakerMiddleware(cbApi))
    let admin = app.group("/admin", circuitBreakerMiddleware(cbAdmin))
    api.get "/test", proc(req: Request, res: Response) =
      res.send("api-ok")
    admin.get "/test", proc(req: Request, res: Response) =
      res.send("admin-ok")
    cbApi.recordFailure()
    cbApi.recordFailure()
    check cbApi.state == csOpen
    check cbAdmin.state == csClosed
    block:
      let req = newMockRequest("/api/test")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 503
    block:
      let req = newMockRequest("/admin/test")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 200

  test "multiple middleware stacks with different success routes":
    let app = newExpressApp()
    app.use(panicRecovery(PanicRecoveryOptions(
      responseFormat: erfJson,
      logErrors: false,
      includeStackTrace: false,
      reportHook: nil
    )))
    app.use(globalErrorFilterWithBuiltins())
    app.get "/a", proc(req: Request, res: Response) =
      res.send("route-a")
    app.get "/b", proc(req: Request, res: Response) =
      res.status(201).send("route-b")
    app.get "/c", proc(req: Request, res: Response) =
      res.status(204).send("")
    block:
      let req = newMockRequest("/a")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 200
    block:
      let req = newMockRequest("/b")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 201
    block:
      let req = newMockRequest("/c")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 204

  test "full middleware stack: logger + group auth":
    var logLine = ""
    let logOpts = JsonLoggerOptions(
      sink: proc(line: string) = logLine = line,
      includeFields: {jlfMethod, jlfPath, jlfStatus},
      excludeFields: {},
      skipPaths: @[],
      skipHealthChecks: false
    )
    let authMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.bindHeaders()
      let auth = req.headers.getOrDefault("authorization", "")
      if auth.len == 0:
        res.status(401).send("unauthorized")
        return
      await next()
    let app = newExpressApp()
    app.use(jsonLogger(logOpts))
    let secured = app.group("/secure", authMw)
    secured.get "/data", proc(req: Request, res: Response) =
      res.send("secret-data")
    app.get "/open", proc(req: Request, res: Response) =
      res.send("open-data")
    block:
      logLine = ""
      let req = newMockRequest("/open")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 200
      check logLine.contains("\"status\":200")
    block:
      logLine = ""
      let req = newMockRequest("/secure/data", hmGet, "", "127.0.0.1", @[("authorization", "Bearer token")])
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 200
      check logLine.contains("\"status\":200")

suite "Additional: HEAD and OPTIONS methods":
  test "HEAD route works through pipeline":
    let app = newExpressApp()
    app.head "/test", proc(req: Request, res: Response) =
      res.status(200).send("")
    let req = newMockRequest("/test", hmHead)
    let res = newMockResponse()
    res.requestMethodKind = hmHead
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 200
    check res.finished == true

  test "OPTIONS route works through pipeline":
    let app = newExpressApp()
    app.options "/opts", proc(req: Request, res: Response) =
      res.status(204).send("")
    let req = newMockRequest("/opts", hmOptions)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 204

  test "HEAD falls back to GET route":
    let app = newExpressApp()
    app.get "/only-get", proc(req: Request, res: Response) =
      res.send("get")
    let req = newMockRequest("/only-get", hmHead)
    let res = newMockResponse()
    res.requestMethodKind = hmHead
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 200
    check res.finished == true

  test "OPTIONS on unregistered route returns 404":
    let app = newExpressApp()
    app.get "/something", proc(req: Request, res: Response) =
      res.send("ok")
    let req = newMockRequest("/nowhere", hmOptions)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 404

suite "Additional: Error handler edge cases":
  test "error handler that throws gets caught by framework":
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      raise newException(ValueError, "error handler itself failed")
    app.get "/crash-eh", proc(req: Request, res: Response) =
      raise newException(IOError, "original error")
    let req = newMockRequest("/crash-eh")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check res.finished == true

  test "error handler with OSError":
    var caughtType = ""
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      caughtType = $err.name
      res.status(503).send("service unavailable")
    app.get "/os-fail", proc(req: Request, res: Response) =
      raise newException(OSError, "disk full")
    let req = newMockRequest("/os-fail")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check caughtType == "OSError"
    check res.statusCode == 503

  test "error handler with JsonParsingError":
    var caughtMsg = ""
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      caughtMsg = err.msg
      res.status(400).send("bad json")
    app.get "/parse-fail", proc(req: Request, res: Response) =
      raise newException(JsonParsingError, "invalid json at pos 42")
    let req = newMockRequest("/parse-fail")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check caughtMsg == "invalid json at pos 42"
    check res.statusCode == 400

  test "error handler only called for routes that throw":
    var errorCount = 0
    let app = newExpressApp()
    app.onError proc(err: ref Exception, req: Request, res: Response): Future[void] {.async.} =
      inc errorCount
      res.status(500).send("error")
    app.get "/good", proc(req: Request, res: Response) =
      res.send("good")
    app.get "/bad", proc(req: Request, res: Response) =
      raise newException(ValueError, "bad")
    block:
      errorCount = 0
      let req = newMockRequest("/good")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check errorCount == 0
    block:
      errorCount = 0
      let req = newMockRequest("/bad")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check errorCount == 1

suite "Additional: Complex routing patterns":
  test "static route takes priority over dynamic":
    let app = newExpressApp()
    app.get "/users/me", proc(req: Request, res: Response) =
      res.send("me-route")
    app.get "/users/:id", proc(req: Request, res: Response) =
      let id = req.params.getOrDefault("id", "")
      res.send("user:" & id)
    let req = newMockRequest("/users/me")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("me-route")

  test "dynamic route param extraction":
    let app = newExpressApp()
    app.get "/items/:category/:id", proc(req: Request, res: Response) =
      let cat = req.params.getOrDefault("category", "")
      let id = req.params.getOrDefault("id", "")
      res.send(cat & ":" & id)
    let req = newMockRequest("/items/books/42")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("books:42")

  test "multiple methods on same path":
    let app = newExpressApp()
    app.get "/res", proc(req: Request, res: Response) =
      res.send("get-res")
    app.post "/res", proc(req: Request, res: Response) =
      res.status(201).send("post-res")
    app.put "/res", proc(req: Request, res: Response) =
      res.send("put-res")
    app.delete "/res", proc(req: Request, res: Response) =
      res.status(204).send("")
    app.patch "/res", proc(req: Request, res: Response) =
      res.send("patch-res")
    block:
      let req = newMockRequest("/res", hmGet)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.getCapturedBody().contains("get-res")
    block:
      let req = newMockRequest("/res", hmPost)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 201
    block:
      let req = newMockRequest("/res", hmPut)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.getCapturedBody().contains("put-res")
    block:
      let req = newMockRequest("/res", hmDelete)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 204
    block:
      let req = newMockRequest("/res", hmPatch)
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.getCapturedBody().contains("patch-res")

  test "group routes with param":
    let app = newExpressApp()
    let api = app.group("/api")
    api.get "/items/:id", proc(req: Request, res: Response) =
      let id = req.params.getOrDefault("id", "")
      res.send("api-item:" & id)
    let req = newMockRequest("/api/items/123")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.getCapturedBody().contains("api-item:123")

  test "deeply nested route with middleware and params":
    var mwRan = false
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      mwRan = true
      await next()
    let app = newExpressApp()
    let api = app.group("/api", mw)
    let v2 = api.group("/v2")
    v2.get "/users/:userId/posts/:postId", proc(req: Request, res: Response) =
      let uid = req.params.getOrDefault("userId", "")
      let pid = req.params.getOrDefault("postId", "")
      res.send(uid & ":" & pid)
    let req = newMockRequest("/api/v2/users/42/posts/7")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check mwRan == true
    check res.getCapturedBody().contains("42:7")

  test "many routes - correct dispatch":
    let app = newExpressApp()
    for i in 0..<20:
      let idx = i
      app.get "/route" & $idx, proc(req: Request, res: Response) =
        res.send("route" & $idx)
    let req = newMockRequest("/route15")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

suite "Additional: Request and response helpers":
  test "request body access through pipeline":
    let app = newExpressApp()
    app.post "/echo", proc(req: Request, res: Response) =
      req.bindBody()
      res.send(req.body)
    let req = newMockRequest("/echo", hmPost, "hello-body")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("hello-body")

  test "request headers access through pipeline":
    let app = newExpressApp()
    app.get "/headers", proc(req: Request, res: Response) =
      let ct = req.get("content-type")
      res.send("ct:" & ct)
    let req = newMockRequest("/headers", hmGet, "", "127.0.0.1", @[("content-type", "text/plain")])
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("ct:text/plain")

  test "request cookies pre-populated through pipeline":
    let app = newExpressApp()
    app.get "/cookies", proc(req: Request, res: Response) =
      let session = req.cookies.getOrDefault("session", "none")
      res.set("x-session", session)
      res.send("ok")
    let req = newMockRequest("/cookies")
    req.cookies["session"] = "abc123"
    req.cookies["theme"] = "dark"
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.headers.getOrDefault("x-session", "") == "abc123"

  test "response content-type through pipeline":
    let app = newExpressApp()
    app.get "/html", proc(req: Request, res: Response) =
      res.contentType("text/html; charset=utf-8")
      res.send("<h1>Hello</h1>")
    let req = newMockRequest("/html")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "locals pass between middleware and handler":
    let mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["timestamp"] = "2024-01-01"
      req.locals["version"] = "1.0"
      res.locals["x-powered-by"] = "nim-express"
      await next()
    let app = newExpressApp()
    app.use(mw)
    app.get "/info", proc(req: Request, res: Response) =
      let ts = req.locals.getOrDefault("timestamp", "")
      let ver = req.locals.getOrDefault("version", "")
      let powered = res.locals.getOrDefault("x-powered-by", "")
      res.send(ts & "|" & ver & "|" & powered)
    let req = newMockRequest("/info")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("2024-01-01|1.0|nim-express")

  test "request query parameters":
    let app = newExpressApp()
    app.get "/search", proc(req: Request, res: Response) =
      req.bindQuery()
      let q = req.query.getOrDefault("q", "")
      res.send("query:" & q)
    let nativeReq = newMockHttpRequest("/search", hmGet)
    nativeReq.queryStringRaw = "q=hello&page=1"
    let req = newRequest(nativeReq)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("query:hello")

  test "multiple response headers":
    let app = newExpressApp()
    app.get "/multi-header", proc(req: Request, res: Response) =
      res.set("x-custom-1", "value1")
      res.set("x-custom-2", "value2")
      res.set("cache-control", "no-cache")
      res.send("ok")
    let req = newMockRequest("/multi-header")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.headers.getOrDefault("x-custom-1", "") == "value1"
    check res.headers.getOrDefault("x-custom-2", "") == "value2"
    check res.headers.getOrDefault("cache-control", "") == "no-cache"

suite "Additional: Middleware ordering edge cases":
  test "five middlewares in correct order":
    var order: seq[string] = @[]
    let app = newExpressApp()
    let m1: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw1")
      await next()
    let m2: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw2")
      await next()
    let m3: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw3")
      await next()
    let m4: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw4")
      await next()
    let m5: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      order.add("mw5")
      await next()
    app.use(m1)
    app.use(m2)
    app.use(m3)
    app.use(m4)
    app.use(m5)
    app.get "/five", proc(req: Request, res: Response) =
      order.add("handler")
      res.send("ok")
    let req = newMockRequest("/five")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check order.len == 6
    check order[0] == "mw1"
    check order[1] == "mw2"
    check order[2] == "mw3"
    check order[3] == "mw4"
    check order[4] == "mw5"
    check order[5] == "handler"

  test "middleware that conditionally adds to locals":
    let condMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      if req.path == "/special":
        req.locals["special"] = "yes"
      await next()
    let app = newExpressApp()
    app.use(condMw)
    app.get "/special", proc(req: Request, res: Response) =
      let s = req.locals.getOrDefault("special", "no")
      res.send("special:" & s)
    app.get "/normal", proc(req: Request, res: Response) =
      let s = req.locals.getOrDefault("special", "no")
      res.send("special:" & s)
    block:
      let req = newMockRequest("/special")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.getCapturedBody().contains("special:yes")
    block:
      let req = newMockRequest("/normal")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.getCapturedBody().contains("special:no")

  test "middleware sending response for all paths stops handler":
    var handlerRan = false
    let blockAll: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      res.status(503).send("maintenance")
    let app = newExpressApp()
    app.use(blockAll)
    app.get "/a1", proc(req: Request, res: Response) =
      handlerRan = true
      res.send("a")
    app.get "/b1", proc(req: Request, res: Response) =
      handlerRan = true
      res.send("b")
    block:
      handlerRan = false
      let req = newMockRequest("/a1")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 503
      check handlerRan == false
    block:
      handlerRan = false
      let req = newMockRequest("/b1")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.statusCode == 503
      check handlerRan == false

  test "middleware modifying multiple locals in chain":
    let mw1: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["a"] = "1"
      await next()
    let mw2: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["b"] = "2"
      await next()
    let mw3: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["c"] = "3"
      await next()
    let app = newExpressApp()
    app.use(mw1)
    app.use(mw2)
    app.use(mw3)
    app.get "/all", proc(req: Request, res: Response) =
      let a = req.locals.getOrDefault("a", "")
      let b = req.locals.getOrDefault("b", "")
      let c = req.locals.getOrDefault("c", "")
      res.send(a & b & c)
    let req = newMockRequest("/all")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.getCapturedBody().contains("123")

  test "middleware overwriting previous middleware locals":
    let mw1: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["role"] = "user"
      await next()
    let mw2: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["role"] = "admin"
      await next()
    let app = newExpressApp()
    app.use(mw1)
    app.use(mw2)
    app.get "/role", proc(req: Request, res: Response) =
      let role = req.locals.getOrDefault("role", "")
      res.send("role:" & role)
    let req = newMockRequest("/role")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.getCapturedBody().contains("role:admin")

  test "app recompiles pipelines on subsequent calls":
    let app = newExpressApp()
    app.get "/v1", proc(req: Request, res: Response) =
      res.send("v1")
    block:
      let req = newMockRequest("/v1")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
    block:
      let req = newMockRequest("/v1")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true

suite "Additional: Route method coverage":
  test "POST with body through pipeline":
    let app = newExpressApp()
    app.post "/submit", proc(req: Request, res: Response) =
      req.bindBody()
      res.status(201).send("received:" & $req.body.len)
    let req = newMockRequest("/submit", hmPost, "payload-data")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 201
    check res.finished == true

  test "PUT replaces resource":
    let app = newExpressApp()
    app.put "/items/1", proc(req: Request, res: Response) =
      res.send("replaced")
    let req = newMockRequest("/items/1", hmPut, "new-data")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true

  test "DELETE returns 204":
    let app = newExpressApp()
    app.delete "/items/:id", proc(req: Request, res: Response) =
      res.status(204).send("")
    let req = newMockRequest("/items/99", hmDelete)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 204

  test "PATCH partial update":
    let app = newExpressApp()
    app.patch "/items/:id", proc(req: Request, res: Response) =
      let id = req.params.getOrDefault("id", "")
      res.send("patched:" & id)
    let req = newMockRequest("/items/55", hmPatch)
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("patched:55")

suite "Additional: Async handler patterns":
  test "async handler with sleepAsync":
    let app = newExpressApp()
    app.getAsync "/slow", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
      res.send("done-slow")
    let req = newMockRequest("/slow")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.finished == true
    check res.getCapturedBody().contains("done-slow")

  test "async POST handler":
    let app = newExpressApp()
    app.postAsync "/async-post", proc(req: Request, res: Response): Future[void] {.async.} =
      req.bindBody()
      await sleepAsync(1)
      res.status(201).send("async-created")
    let req = newMockRequest("/async-post", hmPost, "data")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 201
    check res.finished == true

  test "async handler that raises gets 500":
    let app = newExpressApp()
    app.getAsync "/async-crash", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
      raise newException(IOError, "async failure")
    let req = newMockRequest("/async-crash")
    let res = newMockResponse()
    waitFor app.handleRequestForTest(req, res)
    check res.statusCode == 500
    check res.finished == true

  test "multiple async routes with different delays":
    let app = newExpressApp()
    app.getAsync "/fast-async", proc(req: Request, res: Response): Future[void] {.async.} =
      res.send("fast")
    app.getAsync "/medium-async", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
      res.send("medium")
    block:
      let req = newMockRequest("/fast-async")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
    block:
      let req = newMockRequest("/medium-async")
      let res = newMockResponse()
      waitFor app.handleRequestForTest(req, res)
      check res.finished == true
