import std/[unittest, asyncdispatch, json, os]
import ../src/nim_express/[app, request, response, config, types]

type
  EnvSnapshot = tuple[key: string, existed: bool, value: string]

proc makeRequest(
  path: string = "/",
  methodKind: HttpMethod = hmGet,
  headers: openArray[(string, string)] = []
): Request =
  var native: HttpRequest
  new(native)
  native.methodKind = methodKind
  native.path = path
  if headers.len > 0:
    native.headers = newFastMap[string]()
    discard native.headers.reserve(max(8, headers.len * 2))
    for (key, value) in headers:
      native.headers[key] = value
  newRequest(native)

proc makeResponse(methodKind: HttpMethod = hmGet): Response =
  var native: HttpResponse
  new(native)
  native.requestMethod = methodKind
  newResponse(native)

proc snapshotEnv(keys: openArray[string]): seq[EnvSnapshot] =
  result = newSeqOfCap[EnvSnapshot](keys.len)
  for key in keys:
    result.add((key: key, existed: existsEnv(key), value: getEnv(key, "")))

proc restoreEnv(snapshot: openArray[EnvSnapshot]) =
  for entry in snapshot:
    if entry.existed:
      putEnv(entry.key, entry.value)
    else:
      delEnv(entry.key)

proc runAppMiddlewares(app: ExpressApp, path: string): int =
  let req = makeRequest(path = path)
  let res = makeResponse()
  var nextCount = 0
  proc nextProc(): Future[void] {.async.} =
    inc nextCount
  for mw in app.middlewares:
    waitFor mw(req, res, nextProc)
  nextCount

suite "DevX feature APIs":
  test "route groups compose prefixes and preserve middleware inheritance":
    let webApp = newExpressApp()
    var apiHits = 0
    var v1Hits = 0
    let apiMw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      inc apiHits
      await next()
    let v1Mw: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      inc v1Hits
      await next()

    let api = webApp.group("/api", apiMw)
    let v1 = api.group("v1", v1Mw)
    v1.get("/users", proc(req: Request, res: Response) = discard)

    check webApp.router.getRoutes.len == 1
    check webApp.router.getRoutes[0].pattern == "/api/v1/users"

    discard runAppMiddlewares(webApp, "/api/v1/users")
    check apiHits == 1
    check v1Hits == 1

    discard runAppMiddlewares(webApp, "/api/health")
    check apiHits == 2
    check v1Hits == 1

  test "typed locals helpers support coercion and defaults":
    let req = makeRequest()
    req.setLocal("user_id", 42)
    req.setLocal("is_admin", true)
    req.setLocal("name", "dinesh")

    check req.local("name") == "dinesh"
    check req.local("missing", "fallback") == "fallback"

    let userId = req.localInt("user_id")
    check userId.ok
    check userId.value == 42

    let admin = req.localBool("is_admin")
    check admin.ok
    check admin.value

    let missingInt = req.localInt("not_set", required = false, defaultValue = 7)
    check missingInt.ok
    check missingInt.value == 7

    req.setLocal("bad_int", "NaN")
    let badInt = req.localInt("bad_int")
    check badInt.ok == false
    check badInt.error.source == rfsLocal

  test "request abort hook surface is single-shot":
    let req = makeRequest(path = "/slow")
    var calls = 0
    var seenReason = rcrNone
    req.onAbort(proc(reason: RequestCancelReason) =
      inc calls
      seenReason = reason
    )

    check req.aborted() == false
    check req.abortReason() == rcrNone
    check req.notifyRequestTimeout()
    check req.aborted()
    check req.abortReason() == rcrTimeout
    check seenReason == rcrTimeout
    check calls == 1
    check req.notifyRequestDisconnect() == false
    check calls == 1

  test "env config loader validates bounds and can apply in one call":
    const envKeys = [
      "HOST",
      "PORT",
      "NIM_EXPRESS_HOST",
      "NIM_EXPRESS_PORT",
      "NIM_EXPRESS_TRUST_PROXY",
      "NIM_EXPRESS_ASYNC_PUMP_INTERVAL_MS",
      "NIM_EXPRESS_MAX_INFLIGHT_ASYNC_REQUESTS",
      "NIM_EXPRESS_CONTEXT_POOL_PREWARM",
      "NIM_EXPRESS_MAX_PENDING_BYTES_PER_SOCKET"
    ]
    let saved = snapshotEnv(envKeys)
    defer:
      restoreEnv(saved)

    for key in envKeys:
      delEnv(key)
    putEnv("HOST", "127.0.0.1")
    putEnv("PORT", "8088")
    putEnv("NIM_EXPRESS_TRUST_PROXY", "true")
    putEnv("NIM_EXPRESS_ASYNC_PUMP_INTERVAL_MS", "25")
    putEnv("NIM_EXPRESS_MAX_INFLIGHT_ASYNC_REQUESTS", "333")
    putEnv("NIM_EXPRESS_CONTEXT_POOL_PREWARM", "111")
    putEnv("NIM_EXPRESS_MAX_PENDING_BYTES_PER_SOCKET", "4096")

    let cfg = loadAppEnvConfig()
    check cfg.host == "127.0.0.1"
    check cfg.port == 8088
    check cfg.trustProxy
    check cfg.asyncPumpIntervalMs == 25
    check cfg.maxInflightAsyncRequests == 333
    check cfg.contextPoolPrewarm == 111
    check cfg.maxPendingBytesPerSocket == 4096

    let webApp = newExpressApp()
    let applied = webApp.loadAndApplyAppEnvConfig()
    check applied.port == 8088
    check webApp.getTrustProxy()
    check webApp.getAsyncPumpIntervalMs() == 25
    check webApp.getMaxInflightAsyncRequests() == 333
    check webApp.getContextPoolPrewarm() == 111
    check webApp.server.options.maxPendingBytesPerSocket == 4096

    putEnv("NIM_EXPRESS_PORT", "99999")
    putEnv("NIM_EXPRESS_MAX_INFLIGHT_ASYNC_REQUESTS", "-1")
    let fallback = loadAppEnvConfig()
    check fallback.port == DefaultEnvPort
    check fallback.maxInflightAsyncRequests == DefaultEnvMaxInflightAsyncRequests

  test "RFC7807 helper emits expected fields and headers":
    let body = buildRfc7807ProblemBody(
      statusCode = 422,
      detail = "validation failed",
      typeUri = "https://example.com/problems/validation",
      title = "Validation Error",
      instance = "/todos/42",
      extensions = @[
        (key: "request_id", value: "req-123"),
        (key: "status", value: "ignored")
      ]
    )
    let payload = parseJson(body)
    check payload["type"].getStr() == "https://example.com/problems/validation"
    check payload["title"].getStr() == "Validation Error"
    check payload["status"].getInt() == 422
    check payload["detail"].getStr() == "validation failed"
    check payload["instance"].getStr() == "/todos/42"
    check payload["request_id"].getStr() == "req-123"
    check payload["status"].kind == JInt

    let res = makeResponse()
    discard res.problemDetails(422, "validation failed")
    check res.statusCode == 422
    check res.get("content-type") == "application/problem+json; charset=utf-8"

  test "plugin lifecycle resolves dependencies and shuts down in reverse order":
    let webApp = newExpressApp()
    var initOrder: seq[string] = @[]
    var shutdownOrder: seq[string] = @[]

    check webApp.registerPlugin(pluginDef(
      id = "db",
      initHook = proc(): bool =
        initOrder.add("db")
        true,
      shutdownHook = proc() =
        shutdownOrder.add("db")
    ))
    check webApp.registerPlugin(pluginDef(
      id = "cache",
      dependsOn = @["db"],
      initHook = proc(): bool =
        initOrder.add("cache")
        true,
      shutdownHook = proc() =
        shutdownOrder.add("cache")
    ))
    check webApp.initializePlugins()
    check initOrder == @["db", "cache"]
    webApp.shutdownPlugins()
    check shutdownOrder == @["cache", "db"]

  test "advice phases run in deterministic order":
    let webApp = newExpressApp()
    var phases: seq[string] = @[]
    webApp.onBeforeRouteMatchAdvice(proc(req: Request, res: Response): bool =
      phases.add("before_route")
      true
    )
    webApp.onBeforeHandlerAdvice(proc(req: Request, res: Response, routePattern: string): bool =
      phases.add("before_handler:" & routePattern)
      true
    )
    webApp.onAfterHandlerAdvice(proc(req: Request, res: Response) =
      phases.add("after_handler")
    )
    webApp.get("/advice", proc(req: Request, res: Response) =
      phases.add("handler")
      res.send("ok")
    )
    let req = makeRequest(path = "/advice")
    let res = makeResponse()
    waitFor webApp.handleRequestForTest(req, res)
    check phases == @[
      "before_route",
      "before_handler:/advice",
      "handler",
      "after_handler"
    ]
    check res.finished

  test "sync middleware and sync handler adapt to async APIs":
    let webApp = newExpressApp()
    var events: seq[string] = @[]
    webApp.use(proc(req: Request, res: Response, next: proc() {.closure.}) =
      events.add("mw")
      next()
    )
    webApp.getAsync("/adapted", proc(req: Request, res: Response) =
      events.add("handler")
      res.send("ok")
    )
    let req = makeRequest(path = "/adapted")
    let res = makeResponse()
    waitFor webApp.handleRequestForTest(req, res)
    check events == @["mw", "handler"]
    check res.finished

  test "request snapshot detaches owned data for async/background use":
    var native: HttpRequest
    new(native)
    native.methodKind = hmGet
    native.path = "/snapshot"
    native.queryStringRaw = "page=2&active=true"
    native.headers = newFastMap[string]()
    discard native.headers.reserve(4)
    discard native.headers.put("x-user-id", "42")
    native.body = "{\"hello\":true}"
    let req = newRequest(native)
    req.params["id"] = "77"
    req.setLocal("role", "admin")

    let snap = req.snapshot(includeBody = true)
    req.params["id"] = "updated"
    req.setLocal("role", "guest")

    check snap.path == "/snapshot"
    check snap.query.getOrDefault("page", "") == "2"
    check snap.headers.getOrDefault("x-user-id", "") == "42"
    check snap.params.getOrDefault("id", "") == "77"
    check snap.locals.getOrDefault("role", "") == "admin"
    check snap.body == "{\"hello\":true}"

  test "generic typed extractors support string/int/bool":
    let req = makeRequest(path = "/extract")
    req.setLocal("id", 123)
    req.setLocal("enabled", true)
    req.setLocal("name", "nim")
    let id = localAs[int](req, "id")
    let enabled = localAs[bool](req, "enabled")
    let name = localAs[string](req, "name")
    let missing = localAs[int](req, "missing", required = false, defaultValue = 9)
    check id.ok and id.value == 123
    check enabled.ok and enabled.value
    check name.ok and name.value == "nim"
    check missing.ok and missing.value == 9

  test "route manifest reports shadowed routes":
    let webApp = newExpressApp()
    webApp.use(proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      await next()
    )
    webApp.get("/dup", proc(req: Request, res: Response) = res.send("first"))
    webApp.get("/dup", proc(req: Request, res: Response) = res.send("second"))
    let manifest = webApp.routeManifestEntries()
    var dup: seq[RouteManifestEntry] = @[]
    for entry in manifest:
      if entry.httpMethod == "GET" and entry.pattern == "/dup":
        dup.add(entry)
    check dup.len == 2
    check dup[0].shadowed == false
    check dup[1].shadowed
    check dup[0].middlewareCount >= 1

  test "allowed host guard normalizes ports IPv6 and can be disabled":
    let webApp = newExpressApp()
    webApp.setAllowedHosts(@["example.com", "[::1]"])
    webApp.get("/host", proc(req: Request, res: Response) =
      res.send("ok")
    )

    let ipv6Req = makeRequest("/host", headers = [("host", "[::1]:3000")])
    let ipv6Res = makeResponse()
    waitFor webApp.handleRequestForTest(ipv6Req, ipv6Res)
    check ipv6Res.statusCode == 200
    check ipv6Res.native.capturedBody == "ok"

    let malformedReq = makeRequest("/host", headers = [("host", "bad host")])
    let malformedRes = makeResponse()
    waitFor webApp.handleRequestForTest(malformedReq, malformedRes)
    check malformedRes.statusCode == 421

    webApp.setAllowedHosts(@[])
    let disabledReq = makeRequest("/host", headers = [("host", "unlisted.example")])
    let disabledRes = makeResponse()
    waitFor webApp.handleRequestForTest(disabledReq, disabledRes)
    check disabledRes.statusCode == 200
    check disabledRes.native.capturedBody == "ok"

  test "inspector emits parse and timeout events":
    let webApp = newExpressApp()
    var kinds: seq[InspectorEventKind] = @[]
    var phases: seq[string] = @[]
    webApp.onInspector(proc(event: InspectorEvent) =
      kinds.add(event.kind)
      phases.add(event.phase)
    )
    discard webApp.invokeProtocolErrorTransform(400, "127.0.0.1")

    let req = makeRequest(path = "/timeout")
    let res = makeResponse()
    req.setRequestTimeoutBudget(1)
    req.timeoutStartedAtMs = 0'i64
    waitFor webApp.handleRequestForTest(req, res)

    check iekParseError in kinds
    check iekTimeout in kinds
    check "request_timeout" in phases
