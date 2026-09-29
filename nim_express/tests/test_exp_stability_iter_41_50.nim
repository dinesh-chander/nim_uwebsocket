import std/[unittest, asyncdispatch, strutils, times, os]

import ../src/nim_express/[app, types, response, request, offload]
import ../src/nim_express/middlewares/[timeout]

proc toFastMap(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    discard result.put(k, v)

proc blockingSlow(): int =
  sleep(100)
  1

suite "exp stability iter 41-50":
  test "timeout enforcement ignores req.locals tampering":
    let webApp = newExpressApp()
    webApp.use(timeout(10))
    webApp.use(proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      req.locals["_timeout_budget_ms"] = "999999"
      req.locals["_timeout_started_ms"] = "0"
      await sleepAsync(30)
      await next()
    )
    webApp.get("/tamper", proc(req: Request, res: Response) =
      res.send("ok")
    )

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.path = "/tamper"
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req
    res.app = webApp

    waitFor webApp.handleRequestForTest(req, res)
    check req.requestCancelled()
    check req.cancelReason == rcrTimeout
    check res.statusCode == 504

  test "cancelled contexts are not returned to wrapper pools":
    let beforeReqPool = requestPoolSize()
    let beforeResPool = responsePoolSize()

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    let req = newRequest(reqNative)
    discard req.notifyRequestTimeout()

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req

    releaseResponse(res)
    releaseRequest(req)

    check requestPoolSize() == beforeReqPool
    check responsePoolSize() == beforeResPool

  test "disconnect notification targets request identity before remote ip fallback":
    var req1Native: HttpRequest
    new(req1Native)
    req1Native.methodKind = hmGet
    req1Native.remoteIp = "203.0.113.77"
    let req1 = newRequest(req1Native)
    req1.requestSeq = 11'u64

    var req2Native: HttpRequest
    new(req2Native)
    req2Native.methodKind = hmGet
    req2Native.remoteIp = "203.0.113.77"
    let req2 = newRequest(req2Native)
    req2.requestSeq = 22'u64

    registerActiveAsyncRequestForTest(req1)
    registerActiveAsyncRequestForTest(req2)
    notifyAsyncDisconnectForTest("203.0.113.77", 22'u64, 0'u64)

    check req1.requestCancelled() == false
    check req2.requestCancelled()
    check req2.cancelReason == rcrDisconnect

    unregisterActiveAsyncRequestForTest(req1)
    unregisterActiveAsyncRequestForTest(req2)

  test "async handler that returns without sending triggers deterministic fallback":
    let webApp = newExpressApp()
    webApp.getAsync("/nosend", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(1)
    )

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.path = "/nosend"
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req
    res.app = webApp

    waitFor webApp.handleRequestForTest(req, res)
    check res.statusCode == 500

  test "trusted forwarded parsing uses trusted-edge side when hop count is configured":
    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.remoteIp = "127.0.0.1"
    reqNative.headers = toFastMap([
      ("x-forwarded-for", "198.51.100.10, 203.0.113.90, 127.0.0.1"),
      ("x-forwarded-proto", "http, https"),
      ("x-forwarded-host", "spoof.example, edge.example.com:443"),
      ("host", "origin.example.com:8080")
    ])
    let req = newRequest(reqNative)
    req.trustProxyEnabled = true
    req.trustedProxyHopCount = 1
    req.trustedProxyAllowlist = "127.0.0.1"

    check req.trustedClientIp() == "203.0.113.90"
    check req.protocol() == "https"
    check req.hostname() == "edge.example.com"

  test "compression keeps existing vary values when adding accept-encoding":
    let webApp = newExpressApp()
    webApp.set("compression", "true")

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req
    res.app = webApp
    res.compress = true
    res.append("Vary", "Origin")

    res.send(repeat("abcd", 1024))
    let vary = res.get("vary").toLowerAscii()
    check vary.contains("origin")
    check vary.contains("accept-encoding")

  test "html responses apply compression etag and server timing policies":
    let webApp = newExpressApp()
    webApp.set("compression", "true")

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req
    res.app = webApp
    res.compress = true
    res.append("Vary", "Origin")
    res.html(repeat("<main>abcd</main>", 1024))

    check res.get("content-encoding").len > 0
    let vary = res.get("vary").toLowerAscii()
    check vary.contains("origin")
    check vary.contains("accept-encoding")

    var req2Native: HttpRequest
    new(req2Native)
    req2Native.methodKind = hmGet
    let req2 = newRequest(req2Native)
    req2.locals["_server_timing_enabled"] = "1"
    req2.locals["_server_timing_start"] = "0"

    var res2Native: HttpResponse
    new(res2Native)
    res2Native.requestMethod = hmGet
    let res2 = newResponse(res2Native)
    res2.request = req2
    res2.app = webApp
    res2.locals["_etag_enabled"] = "1"
    res2.html("<h1>ok</h1>")

    check res2.get("etag").len > 0
    check res2.get("server-timing").contains("total;dur=")

  test "offload timeout path returns promptly across repeated timeouts":
    let started = epochTime()
    for _ in 0 ..< 3:
      let timed = waitFor runOffloadOutcome("slow", "iter-46", 5, blockingSlow())
      check timed.kind == ookOffloadTimeout
      check timed.errorClass == "offload_timeout"
    let elapsedMs = int((epochTime() - started) * 1000.0)
    check elapsedMs < 1000
