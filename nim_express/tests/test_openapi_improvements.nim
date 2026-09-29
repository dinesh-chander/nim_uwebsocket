import std/[unittest, asyncdispatch, strutils, json, sequtils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/openapi

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

proc newTestRegistry(): OpenApiRegistry =
  result = newOpenApiRegistry()
  result.documentGet("/users/:id", RouteDoc(summary: "Get user", tags: @["users"]))
  result.documentPost("/users", RouteDoc(summary: "Create user",
    requestBodyContentType: "application/json"))

suite "openapi spec document":
  test "spec path serves 200 JSON with valid OpenAPI document (regression)":
    let reg = newTestRegistry()
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.finished
    check res.statusCode == 200
    check res.get("content-type").find("application/json") >= 0
    let spec = parseJson(res.native.capturedBody)
    check spec["openapi"].getStr() == "3.0.3"
    check spec["info"]["title"].getStr() == "API"
    check spec["paths"]["/users/{id}"]["get"]["summary"].getStr() == "Get user"
    check spec["paths"]["/users"]["post"]["summary"].getStr() == "Create user"

  test "spec path emits path parameter for :id (regression)":
    let reg = newTestRegistry()
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let spec = parseJson(res.native.capturedBody)
    let params = spec["paths"]["/users/{id}"]["get"]["parameters"]
    check params.len == 1
    check params[0]["name"].getStr() == "id"
    check params[0]["in"].getStr() == "path"
    check params[0]["required"].getBool()

  test "non-spec paths pass through to next (regression)":
    let reg = newTestRegistry()
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/users/1")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.native.capturedBody == "ok"

  test "non-GET requests on spec path pass through (regression)":
    let reg = newTestRegistry()
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json", methodKind = hmPost)
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled

  test "custom spec and UI paths are honored":
    let reg = newTestRegistry()
    var opts = defaultOpenApiOptions()
    opts.specPath = "/docs/openapi.json"
    opts.uiPath = "/docs"
    let mw = openapi(reg, opts)
    let req = newMockRequest(pathVal = "/docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.get("content-type").find("application/json") >= 0
    check parseJson(res.native.capturedBody)["openapi"].getStr() == "3.0.3"
    # Default path no longer matches
    let req2 = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res2 = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req2, res2, flagHandler(addr nextCalled))
    check nextCalled

suite "openapi swagger ui":
  test "ui path serves HTML with spec url injected (regression)":
    let reg = newTestRegistry()
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.finished
    check res.statusCode == 200
    check res.get("content-type").find("text/html") >= 0
    check res.native.capturedBody.find("swagger-ui") >= 0
    check res.native.capturedBody.find("/api-docs/openapi.json") >= 0
    check res.native.capturedBody.find("{{SPEC_URL}}") < 0

  test "trailing slash on ui path is normalized (ISSUE-10)":
    let reg = newTestRegistry()
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.finished
    check res.get("content-type").find("text/html") >= 0
    check res.native.capturedBody.find("swagger-ui") >= 0

  test "trailing slash on spec path is normalized (ISSUE-10)":
    let reg = newTestRegistry()
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json/")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.finished
    check res.get("content-type").find("application/json") >= 0
    check parseJson(res.native.capturedBody)["openapi"].getStr() == "3.0.3"

suite "openapi caching and etag":
  test "spec response carries version-based ETag (ISSUE-11)":
    let reg = newTestRegistry()
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    # newTestRegistry() documents two routes -> version == 2
    check res.get("etag") == "\"2\""

  test "cache serves same spec across requests without rebuild (regression)":
    let reg = newTestRegistry()
    let mw = openapi(reg)
    let req1 = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1)
    let body1 = res1.native.capturedBody
    let req2 = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2)
    check res2.native.capturedBody == body1
    check res2.get("etag") == res1.get("etag")

suite "openapi route registration":
  test "re-documenting same method+pattern does not duplicate in spec (ISSUE-1)":
    let reg = newOpenApiRegistry()
    reg.documentGet("/users/:id", RouteDoc(summary: "first"))
    reg.documentGet("/users/:id", RouteDoc(summary: "second"))
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let spec = parseJson(res.native.capturedBody)
    check spec["paths"]["/users/{id}"]["get"]["summary"].getStr() == "second"
    check toSeq(spec["paths"]["/users/{id}"].keys()) == @["get"]

  test "mixed-case method normalizes to lower-case key in spec (ISSUE-8)":
    let reg = newOpenApiRegistry()
    reg.document("GeT", "/mixed", RouteDoc(summary: "mixed"))
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let spec = parseJson(res.native.capturedBody)
    check spec["paths"]["/mixed"].hasKey("get")
    check not spec["paths"]["/mixed"].hasKey("Get")

  test "nil registry falls back to an empty spec":
    let mw = openapi(nil)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.statusCode == 200
    let spec = parseJson(res.native.capturedBody)
    check spec["paths"].len == 0

suite "openapi pattern edge cases":
  test "trailing-colon pattern does not emit empty braces (ISSUE-3)":
    let reg = newOpenApiRegistry()
    reg.documentGet("/users/:", RouteDoc(summary: "weird"))
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let spec = parseJson(res.native.capturedBody)
    let paths = spec["paths"]
    check not paths.hasKey("/users/{}")
    check paths.hasKey("/users/:")

  test "invalid parameter name is not wrapped in braces (ISSUE-4)":
    let reg = newOpenApiRegistry()
    reg.documentGet("/x/:na(me", RouteDoc(summary: "bad param"))
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let spec = parseJson(res.native.capturedBody)
    let paths = spec["paths"]
    check not paths.hasKey("/x/{na(me")
    check paths.hasKey("/x/na(me")
    check not paths["/x/na(me"]["get"].hasKey("parameters")

  test "dotted parameter name is kept (ISSUE-4)":
    let reg = newOpenApiRegistry()
    reg.documentGet("/files/:file.name", RouteDoc(summary: "dotted"))
    let mw = openapi(reg)
    let req = newMockRequest(pathVal = "/api-docs/openapi.json")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let spec = parseJson(res.native.capturedBody)
    check spec["paths"].hasKey("/files/{file.name}")
    let params = spec["paths"]["/files/{file.name}"]["get"]["parameters"]
    check params[0]["name"].getStr() == "file.name"
