import std/[unittest, asyncdispatch, deques, os, strutils, options]

import ../src/nim_express/[types, request, response, fastrand, json_utils]
import ../src/nim_express/middlewares/[cors, etag, fast_proxy, helmet, htmx, static_files]
import nim_fasthttpclient/client as fastclient
import nim_fasthttpclient/connection_pool as fastpool
import nim_fasthttpclient/types as fasttypes

type
  DemoPayload = object
    id: int
    name: string

proc toFastMap(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    discard result.put(k, v)

proc newReq(
  methodKind: types.HttpMethod = types.hmGet,
  path: string = "/",
  headers: openArray[(string, string)] = []
): Request =
  var nativeReq: types.HttpRequest
  new(nativeReq)
  nativeReq.methodKind = methodKind
  nativeReq.path = path
  nativeReq.headers = toFastMap(headers)
  result = newRequest(nativeReq)

proc newRes(methodKind: types.HttpMethod = types.hmGet): Response =
  var nativeRes: types.HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = methodKind
  result = newResponse(nativeRes)

proc makeNext(flag: ptr bool): NextProc =
  proc (): Future[void] {.async.} =
    flag[] = true

proc fastHeaderValue(headers: seq[fasttypes.HttpHeader], name: string): string =
  for header in headers:
    if header.name.cmpIgnoreCase(name) == 0:
      return header.value
  ""

suite "Coverage for uncovered nim_express modules":
  test "fastrand is deterministic and bounded":
    seedFastRand(12345'u64)
    let first = fastRand()
    let second = fastRand()
    seedFastRand(12345'u64)
    check first == fastRand()
    check second == fastRand()

    seedFastRand(0'u64)
    check fastRand() != 0'u64

    for _ in 0 ..< 64:
      let value = fastRandRange(10)
      check value >= 0 and value < 10
      let bounded = fastRandRange(-5, 5)
      check bounded >= -5 and bounded <= 5

  test "json utils parse and builders":
    let payload = DemoPayload(id: 7, name: "alpha")
    let encoded = """{"id":7,"name":"alpha"}"""
    let fallback = DemoPayload(id: 1, name: "fallback")
    let parsedOr = json_utils.fromJsonOr[DemoPayload]("{invalid", fallback)
    check parsedOr.id == fallback.id
    check parsedOr.name == fallback.name

    let okOption = json_utils.tryFromJson[DemoPayload](encoded)
    check okOption.isSome
    check okOption.get().id == 7
    check json_utils.tryFromJson[DemoPayload]("{invalid").isNone

    check errorJson("boom").contains("\"error\":\"boom\"")
    check messageJson("ok").contains("\"message\":\"ok\"")
    check statusJson("up").contains("\"status\":\"up\"")
    check dataJson(42).contains("\"data\":42")
    check successJson(payload).contains("\"success\":true")
    check listJson(@[1, 2, 3]).contains("\"count\":3")

  test "cors preflight rejects wildcard credentials without an allowlist":
    let mw = cors(CorsOptions(
      origin: "*",
      credentials: true,
      maxAge: 120,
      methods: @["GET", "POST"],
      allowedHeaders: @["Content-Type", "Authorization"]
    ))
    let req = newReq(hmOptions, "/api", [("origin", "https://example.com")])
    let res = newRes(hmOptions)
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))

    check not nextCalled
    check res.statusCode == 403
    check res.get("access-control-allow-origin") == ""
    check res.get("access-control-allow-credentials") == ""
    check res.get("access-control-max-age") == "120"
    check res.get("vary") == ""

  test "cors default path falls through on non-options":
    let mw = cors()
    let req = newReq(hmGet, "/api")
    let res = newRes(hmGet)
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))

    check nextCalled
    check res.get("access-control-allow-origin") == "*"
    check res.get("access-control-allow-methods").contains("OPTIONS")

  test "cors reflected request headers add Vary guard":
    let mw = cors(CorsOptions(allowedHeaders: @["*"]))
    let req = newReq(hmOptions, "/api", [
      ("access-control-request-headers", "x-api-key, x-trace-id")
    ])
    let res = newRes(hmOptions)
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))

    check not nextCalled
    check res.statusCode == 204
    check res.get("access-control-allow-headers") == "x-api-key, x-trace-id"
    check res.get("vary").contains("Access-Control-Request-Headers")

  test "etag helpers are deterministic and middleware continues":
    let a = generateETag("body-a")
    let b = generateETag("body-a")
    let c = generateETag("body-b")
    check a == b
    check a != c
    check a.endsWith("\"") and (a.startsWith("W/\"") or a.startsWith("\""))

    let mw = etag()
    let req = newReq()
    let res = newRes()
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))
    check nextCalled

  test "helmet sets security headers":
    let mw = helmet()
    let req = newReq(headers = [
      ("x-forwarded-proto", "https"),
      ("x-forwarded-for", "198.51.100.10, 203.0.113.44")
    ])
    req.trustProxyEnabled = true
    req.trustedProxyHopCount = 1
    let res = newRes()
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))
    check nextCalled
    check res.get("x-content-type-options") == "nosniff"
    check res.get("x-frame-options") == "SAMEORIGIN"
    check res.get("strict-transport-security").contains("max-age")

  test "htmx middleware propagates request metadata to locals":
    let mw = htmx()
    let req = newReq(hmGet, "/fragment", [
      ("hx-request", "true"),
      ("hx-target", "list"),
      ("hx-trigger", "refresh"),
      ("hx-trigger-name", "btn")
    ])
    let res = newRes()
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))

    check nextCalled
    check req.locals.getOrDefault("htmx", "") == "true"
    check req.locals.getOrDefault("htmx-target", "") == "list"
    check req.locals.getOrDefault("htmx-trigger", "") == "refresh"
    check req.locals.getOrDefault("htmx-trigger-name", "") == "btn"

  test "serveStatic handles unavailable roots and traversal guards":
    let missingRoot = getTempDir() / "nim_express_missing_static_root"
    let missingMw = serveStatic(missingRoot)
    let missingReq = newReq(hmGet, "/x.js")
    let missingRes = newRes()
    var missingNext = false
    waitFor missingMw(missingReq, missingRes, makeNext(addr missingNext))
    check missingNext

    let root = getTempDir() / "nim_express_static_root_test"
    if not dirExists(root):
      createDir(root)

    let prefixedMw = serveStatic(root, "/assets")
    let badReq = newReq(hmGet, "/assets/../secret.txt")
    let badRes = newRes()
    var badNext = false
    waitFor prefixedMw(badReq, badRes, makeNext(addr badNext))
    check not badNext
    check badRes.statusCode == 403

    let mismatchReq = newReq(hmGet, "/api/health")
    let mismatchRes = newRes()
    var mismatchNext = false
    waitFor prefixedMw(mismatchReq, mismatchRes, makeNext(addr mismatchNext))
    check mismatchNext

    let spacedPath = root / "hello world.txt"
    writeFile(spacedPath, "ok")
    let encodedReq = newReq(hmHead, "/assets/hello%20world.txt")
    let encodedRes = newRes(hmHead)
    var encodedNext = false
    waitFor prefixedMw(encodedReq, encodedRes, makeNext(addr encodedNext))
    check not encodedNext
    check encodedRes.statusCode == 200

    writeFile(root / "literal+plus.txt", "plus")
    writeFile(root / "literal space.txt", "space")
    let plusReq = newReq(hmHead, "/assets/literal+plus.txt")
    let plusRes = newRes(hmHead)
    var plusNext = false
    waitFor prefixedMw(plusReq, plusRes, makeNext(addr plusNext))
    check not plusNext
    check plusRes.statusCode == 200

    let spaceReq = newReq(hmHead, "/assets/literal%20space.txt")
    let spaceRes = newRes(hmHead)
    var spaceNext = false
    waitFor prefixedMw(spaceReq, spaceRes, makeNext(addr spaceNext))
    check not spaceNext
    check spaceRes.statusCode == 200

  test "fast proxy rejects private upstreams before dispatch":
    let mw = fastProxy("http://127.0.0.1:65535")
    let req = newReq(hmGet, "/api")
    let res = newRes()
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403

  test "fast proxy default forwarded headers match options path":
    var capturedHeaders: seq[fasttypes.HttpHeader] = @[]
    var client = fastclient.newHttpClient(maxConnsPerHost = 1)
    client.initialized = true
    client.ssl = 0
    client.hooks.onRequestStart = proc(
      httpMethod: string,
      url: string,
      headers: seq[fasttypes.HttpHeader]
    ) {.gcsafe.} =
      {.cast(gcsafe).}:
        capturedHeaders = headers

    let conn = cast[ptr fasttypes.PooledConnection](alloc0(sizeof(fasttypes.PooledConnection)))
    conn[] = fasttypes.PooledConnection(
      host: "203.0.113.10",
      port: 8080'u16,
      useSsl: false,
      state: fasttypes.csOpen,
      isHttp2: false,
      cachedPoolKey: fastpool.poolKey("203.0.113.10", 8080'u16, false),
      pendingCallbacks: initDeque[fasttypes.ResponseCallback](16)
    )
    client.pool.addConnection(conn)

    let mw = fastProxy(FastProxyOptions(
      target: "http://203.0.113.10:8080",
      addXForwardedHeaders: true,
      blockPrivateUpstreams: false,
      allowPrivateUpstreams: true,
      client: addr client
    ))
    let req = newReq(hmGet, "/api", [("host", "service.example")])
    req.native.remoteIp = "198.51.100.23"
    let res = newRes()
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))

    check not nextCalled
    check res.statusCode == 502
    check capturedHeaders.fastHeaderValue("X-Forwarded-For") == "198.51.100.23"
    check capturedHeaders.fastHeaderValue("X-Forwarded-Proto") == "http"
    check capturedHeaders.fastHeaderValue("X-Forwarded-Host") == "service.example"

    client.pool.removeConnection(conn)
    `=destroy`(conn[])
    dealloc(conn)
