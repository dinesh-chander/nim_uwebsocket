import std/[asyncdispatch, os, strutils, times, unittest]

import ../src/nim_express/[app, types, request, response]
import ../src/nim_express/middlewares/[output_cache, static_files]

proc toFastMap(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    discard result.put(k, v)

proc newReq(
  methodKind: HttpMethod = hmGet,
  path: string = "/",
  headers: openArray[(string, string)] = []
): Request =
  var nativeReq: HttpRequest
  new(nativeReq)
  nativeReq.methodKind = methodKind
  nativeReq.path = path
  nativeReq.headers = toFastMap(headers)
  result = newRequest(nativeReq)

proc newRes(methodKind: HttpMethod = hmGet): Response =
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = methodKind
  nativeRes.requestIsHttp11 = true
  result = newResponse(nativeRes)

proc makeNext(flag: ptr bool): NextProc =
  proc (): Future[void] {.async.} =
    flag[] = true

suite "Static and output cache security":
  test "embedded cached render never replays prior response headers or status":
    let webApp = newExpressApp()
    webApp.embedView("static-card", "<section>cached</section>", [("ignored", "ignored")])

    let firstRes = newRes()
    firstRes.app = webApp
    discard firstRes.status(202)
    discard firstRes.set("X-Private-Token", "one-user-only")
    discard firstRes.cookie("sid", "secret")
    firstRes.render("static-card", [("ignored", "ignored")])
    check firstRes.native.capturedBody == "<section>cached</section>"
    check firstRes.statusCode == 202
    check firstRes.native.capturedHeader.toLowerAscii().contains("202")
    check firstRes.native.capturedHeader.toLowerAscii().contains("x-private-token")
    check firstRes.native.capturedHeader.toLowerAscii().contains("set-cookie")

    let secondRes = newRes()
    secondRes.app = webApp
    secondRes.render("static-card", [("ignored", "ignored")])
    let secondHeader = secondRes.native.capturedHeader.toLowerAscii()
    check secondRes.native.capturedBody == "<section>cached</section>"
    check secondHeader.contains("200 ok")
    check not secondHeader.contains("202 accepted")
    check not secondHeader.contains("x-private-token")
    check not secondHeader.contains("set-cookie")

  test "output cache varies by Accept-Encoding by default":
    let policy = initOutputCachePolicy()
    check "accept-encoding" in policy.varyByHeaders

    let store = newOutputCacheStore()
    let mw = outputCache(store, policy)

    let gzipReq = newReq(hmGet, "/asset", [("accept-encoding", "gzip")])
    let gzipRes = newRes()
    var gzipRendered = false
    waitFor mw(gzipReq, gzipRes, proc(): Future[void] {.async.} =
      gzipRendered = true
      gzipRes.set("Content-Encoding", "gzip")
      discard gzipRes.append("Vary", "Accept-Encoding")
      gzipRes.send("gzip-body")
    )
    check gzipRendered
    check gzipRes.native.capturedBody == "gzip-body"
    check outputCacheEntryCount(store) == 1

    let plainReq = newReq(hmGet, "/asset")
    let plainRes = newRes()
    var plainRendered = false
    waitFor mw(plainReq, plainRes, proc(): Future[void] {.async.} =
      plainRendered = true
      discard plainRes.append("Vary", "Accept-Encoding")
      plainRes.send("plain-body")
    )
    check plainRendered
    check plainRes.native.capturedBody == "plain-body"
    check plainRes.native.capturedHeader.toLowerAscii().find("content-encoding") < 0
    check outputCacheEntryCount(store) == 2

    let gzipReq2 = newReq(hmGet, "/asset", [("accept-encoding", "gzip")])
    let gzipRes2 = newRes()
    var rerendered = false
    waitFor mw(gzipReq2, gzipRes2, makeNext(addr rerendered))
    check not rerendered
    check gzipRes2.native.capturedBody == "gzip-body"
    check gzipRes2.native.capturedHeader.toLowerAscii().contains("content-encoding: gzip")

  test "output cache refuses responses with uncovered Vary headers":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    let req = newReq(hmGet, "/profile", [("origin", "https://example.com")])
    let res = newRes()

    waitFor mw(req, res, proc(): Future[void] {.async.} =
      discard res.append("Vary", "Origin")
      res.send("origin-specific")
    )

    check res.native.capturedBody == "origin-specific"
    check outputCacheEntryCount(store) == 0

  test "output cache bypasses SSE accept requests":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    let req = newReq(hmGet, "/events", [("accept", "text/event-stream")])
    let res = newRes()
    var rendered = false

    waitFor mw(req, res, proc(): Future[void] {.async.} =
      rendered = true
      res.send("event-stream-body")
    )

    check rendered
    check res.native.capturedBody == "event-stream-body"
    check outputCacheEntryCount(store) == 0

  test "output cache refuses chunked responses":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    let req = newReq(hmGet, "/streamed")
    let res = newRes()

    waitFor mw(req, res, proc(): Future[void] {.async.} =
      res.native.sendPreparedResponse(
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n",
        "chunked-body"
      )
    )

    check res.native.capturedBody == "chunked-body"
    check outputCacheEntryCount(store) == 0

  test "output cache does not store uncacheable response directives":
    let cases = @[
      (caseName: "no-cache", headerName: "Cache-Control", headerValue: "no-cache"),
      (caseName: "no-store", headerName: "Cache-Control", headerValue: "no-store"),
      (caseName: "private", headerName: "Cache-Control", headerValue: "private"),
      (caseName: "set-cookie", headerName: "Set-Cookie", headerValue: "sid=abc; HttpOnly")
    ]
    for cacheCase in cases:
      let store = newOutputCacheStore()
      let mw = outputCache(store)
      let req1 = newReq(hmGet, "/uncacheable-" & cacheCase.caseName)
      let res1 = newRes()
      var renderCount = 0

      waitFor mw(req1, res1, proc(): Future[void] {.async.} =
        inc renderCount
        res1.set(cacheCase.headerName, cacheCase.headerValue)
        res1.send("render-" & $renderCount)
      )

      let req2 = newReq(hmGet, "/uncacheable-" & cacheCase.caseName)
      let res2 = newRes()
      waitFor mw(req2, res2, proc(): Future[void] {.async.} =
        inc renderCount
        res2.set(cacheCase.headerName, cacheCase.headerValue)
        res2.send("render-" & $renderCount)
      )

      check renderCount == 2
      check res1.native.capturedBody == "render-1"
      check res2.native.capturedBody == "render-2"
      check outputCacheEntryCount(store) == 0

  test "output cache evicts old entries when total byte budget is exceeded":
    let store = newOutputCacheStore()
    let policy = initOutputCachePolicy(
      maxBodyBytes = 512,
      maxEntries = 10,
      maxTotalBytes = 512
    )
    let mw = outputCache(store, policy)
    let bodyA = repeat("a", 256)
    let bodyB = repeat("b", 256)

    let reqA = newReq(hmGet, "/budget-a")
    let resA = newRes()
    var rendersA = 0
    waitFor mw(reqA, resA, proc(): Future[void] {.async.} =
      inc rendersA
      resA.send(bodyA)
    )
    check rendersA == 1
    check outputCacheEntryCount(store) == 1

    let reqB = newReq(hmGet, "/budget-b")
    let resB = newRes()
    var rendersB = 0
    waitFor mw(reqB, resB, proc(): Future[void] {.async.} =
      inc rendersB
      resB.send(bodyB)
    )
    check rendersB == 1
    check outputCacheEntryCount(store) == 1

    let reqA2 = newReq(hmGet, "/budget-a")
    let resA2 = newRes()
    waitFor mw(reqA2, resA2, proc(): Future[void] {.async.} =
      inc rendersA
      resA2.send("rerendered-a")
    )
    check rendersA == 2
    check resA2.native.capturedBody == "rerendered-a"

  test "output cache forwards chunked streams live and skips caching":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    let req = newReq(hmGet, "/live-stream")
    let res = newRes()
    let liveNative = res.native
    var chunkVisibleBeforeCompletion = false
    var handlerCompleted = false

    waitFor mw(req, res, proc(): Future[void] {.async.} =
      check res.startChunked("text/plain; charset=utf-8")
      check res.writeChunk("alpha")
      chunkVisibleBeforeCompletion =
        liveNative.capturedRaw.contains("transfer-encoding: chunked") and
        liveNative.capturedRaw.contains("5\r\nalpha\r\n")
      await sleepAsync(1)
      check res.endChunked()
      handlerCompleted = true
    )

    check handlerCompleted
    check chunkVisibleBeforeCompletion
    check liveNative.capturedRaw.contains("0\r\n\r\n")
    check outputCacheEntryCount(store) == 0

  when defined(posix):
    test "serveStatic rejects precompressed symlink escaping root":
      let base = getTempDir() / ("nim_express_static_security_" & $getCurrentProcessId() & "_" & $epochTime())
      let root = base / "public"
      let outside = base / "outside.txt"
      createDir(root)
      try:
        writeFile(root / "app.js", "console.log('safe');")
        writeFile(outside, "secret")
        createSymlink(outside, root / "app.js.br")

        let req = newReq(hmGet, "/app.js", [("accept-encoding", "br")])
        let res = newRes()
        let mw = serveStatic(root)
        var nextCalled = false
        waitFor mw(req, res, makeNext(addr nextCalled))

        check not nextCalled
        check res.statusCode == 403
      finally:
        if dirExists(base):
          removeDir(base)

    test "serveStatic rejects files reached through symlinked parent":
      let base = getTempDir() / ("nim_express_static_parentlink_" & $getCurrentProcessId() & "_" & $epochTime())
      let root = base / "public"
      let outsideDir = base / "outside"
      createDir(root)
      createDir(outsideDir)
      try:
        writeFile(outsideDir / "secret.txt", "secret")
        createSymlink(outsideDir, root / "linked")

        let req = newReq(hmGet, "/linked/secret.txt")
        let res = newRes()
        let mw = serveStatic(root)
        var nextCalled = false
        waitFor mw(req, res, makeNext(addr nextCalled))

        check not nextCalled
        check res.statusCode == 403
      finally:
        if dirExists(base):
          removeDir(base)

  test "serveStatic applies fallback cap to byte ranges":
    let base = getTempDir() / ("nim_express_static_range_cap_" & $getCurrentProcessId() & "_" & $epochTime())
    let root = base / "public"
    createDir(root)
    try:
      writeFile(root / "large.txt", repeat("x", 64))

      let webApp = newExpressApp()
      webApp.set("static_fallback_max_bytes", "16")
      let req = newReq(hmGet, "/large.txt", [("range", "bytes=0-31")])
      let res = newRes()
      res.app = webApp
      let mw = serveStatic(root)
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))

      check not nextCalled
      check res.statusCode == 413
      check res.native.capturedBody == "static fallback payload too large"
    finally:
      if dirExists(base):
        removeDir(base)
