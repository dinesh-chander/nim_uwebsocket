import std/[unittest, os, strutils]
import ../src/nim_express/[app, response, types, paged_buffer]

suite "Hooks and compression policy":
  test "hook setters wire to app/server":
    let app = newExpressApp()
    var opened = false
    var closed = false
    var sawBp = false

    app.onConnectionOpen(proc(remoteIp: string) = opened = remoteIp.len >= 0)
    app.onConnectionClose(proc(remoteIp: string, wasWebSocket: bool) =
      closed = remoteIp.len >= 0 and (wasWebSocket or not wasWebSocket)
    )
    app.onBackpressure(proc(bufferedBytes: int64, isWebSocket: bool) =
      sawBp = bufferedBytes >= 0 and (isWebSocket or not isWebSocket)
    )

    check app.connectionOpenHook != nil
    check app.connectionCloseHook != nil
    check app.backpressureHook != nil
    check app.server.connectionOpenHandler != nil
    check app.server.connectionCloseHandler != nil
    check app.server.backpressureHandler != nil

    # suppress unused warnings
    check opened == false
    check closed == false
    check sawBp == false

  test "compression policy applies and can bypass by hook":
    let app = newExpressApp()
    var native: HttpResponse
    new(native)
    native.requestMethod = hmGet
    native.connectionClose = false

    var res = newResponse(native)
    res.app = app
    res.compress = true
    res.set("content-type", "application/json")
    res.send("x".repeat(3000))
    check res.headersInited
    check res.headers.getOrDefault("content-encoding", "") == "gzip"

    # hook can disable compression
    var bypassReason = ""
    app.shouldCompressWith(proc(req: Request, contentType: string, bodyBytes: int): bool = false)
    app.onCompressionBypass(proc(req: Request, reason: string) = bypassReason = reason)

    var native2: HttpResponse
    new(native2)
    native2.requestMethod = hmGet
    native2.connectionClose = false

    var res2 = newResponse(native2)
    res2.app = app
    res2.compress = true
    res2.send("x".repeat(3000))
    check res2.headers.getOrDefault("content-encoding", "") == ""
    check bypassReason.len > 0

  test "compression policy offloads bodies above the configured threshold":
    let app = newExpressApp()
    app.setCompressionOffloadThreshold(1)

    var compressedBytes = 0
    app.onCompressionResult(proc(
      req: Request,
      inBytes: int,
      outBytes: int,
      cpuMicros: int64,
      ratio: float
    ) =
      compressedBytes = outBytes
    )

    var native: HttpResponse
    new(native)
    native.requestMethod = hmGet
    native.connectionClose = false

    var res = newResponse(native)
    res.app = app
    res.compress = true
    res.set("content-type", "application/json")
    res.send("x".repeat(3000))

    check res.headers.getOrDefault("content-encoding", "") == "gzip"
    check compressedBytes > 0

  test "compression hooks fail closed without orphaning response":
    let app = newExpressApp()
    app.shouldCompressWith(proc(req: Request, contentType: string, bodyBytes: int): bool =
      raise newException(ValueError, "should hook failed")
    )
    app.onCompressionBypass(proc(req: Request, reason: string) =
      raise newException(ValueError, "bypass hook failed")
    )

    var native: HttpResponse
    new(native)
    native.requestMethod = hmGet
    native.connectionClose = false

    var res = newResponse(native)
    res.app = app
    res.compress = true
    res.set("content-type", "text/plain; charset=utf-8")
    res.send("x".repeat(3000))

    check res.finished
    check res.statusCode == 200
    check res.headers.getOrDefault("content-encoding", "") == ""
    check native.bodyWasSent() == true

    let app2 = newExpressApp()
    app2.onCompressionResult(proc(
      req: Request,
      inBytes: int,
      outBytes: int,
      cpuMicros: int64,
      ratio: float
    ) =
      raise newException(ValueError, "result hook failed")
    )

    var native2: HttpResponse
    new(native2)
    native2.requestMethod = hmGet
    native2.connectionClose = false

    var res2 = newResponse(native2)
    res2.app = app2
    res2.compress = true
    res2.set("content-type", "text/plain; charset=utf-8")
    res2.send("x".repeat(3000))

    check res2.finished
    check res2.headers.getOrDefault("content-encoding", "") == "gzip"
    check native2.bodyWasSent() == true

  test "response-time request hooks borrow spilled bodies without deleting them":
    let spillRoot = getTempDir() / ("nim_express_hook_spill_" & $getCurrentProcessId())
    createDir(spillRoot)
    let spillPath = spillRoot / "body.dat"
    writeFile(spillPath, "request-body")
    try:
      var nativeReq: HttpRequest
      new(nativeReq)
      nativeReq.methodKind = hmPost
      nativeReq.path = "/upload"
      nativeReq.bodyInFile = true
      nativeReq.bodyFilePath = spillPath
      nativeReq.bodyFileRoot = spillRoot

      var nativeRes: HttpResponse
      new(nativeRes)
      nativeRes.requestMethod = hmGet
      nativeRes.requestRef = nativeReq

      let app = newExpressApp()
      var hookBody = ""
      app.onBeforeHeaders(proc(req: Request, res: Response) =
        hookBody = req.rawBody()
      )
      app.server.beforeHeadersHandler(nativeReq, nativeRes)
      check hookBody == "request-body"
      check fileExists(spillPath)

      var hintedBodyBytes = -1
      app.shouldCompressWith(proc(req: Request, contentType: string, bodyBytes: int): bool =
        hintedBodyBytes = req.rawBodySizeHint()
        true
      )

      var res = newResponse(nativeRes)
      res.app = app
      res.compress = true
      res.set("content-type", "text/plain; charset=utf-8")
      res.send("x".repeat(3000))

      check hintedBodyBytes == "request-body".len
      check fileExists(spillPath)

      let owner = acquireRequest(nativeReq)
      releaseRequest(owner)
      check not fileExists(spillPath)
    finally:
      if fileExists(spillPath):
        removeFile(spillPath)
      if dirExists(spillRoot):
        removeDir(spillRoot)

  test "before-headers hook mutations are copied to native response":
    let app = newExpressApp()
    app.onBeforeHeaders(proc(req: Request, res: Response) =
      res.set("X-Before", "1")
      res.cookie("sid", "abc")
    )

    var nativeReq: HttpRequest
    new(nativeReq)
    nativeReq.methodKind = hmGet

    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet

    app.server.beforeHeadersHandler(nativeReq, nativeRes)
    check nativeRes.headersInited
    check nativeRes.headers.getOrDefault("x-before", "") == "1"

  test "framework response marks body completion via engine lifecycle API":
    var native: HttpResponse
    new(native)
    native.requestMethod = hmGet
    native.setConnectionCloseEnabled(false)

    var res = newResponse(native)
    res.send("ok")

    check native.bodyWasSent() == true

  test "ws high-water policy surfaces and metrics key exists":
    let app = newExpressApp()
    app.setWsBackpressureHighWater(2048)
    app.setWsBackpressureHighWaterAction(bhwDropOldest)
    app.onWsHighWater(proc(ws: WebSocket, bufferedBytes: int64, action: BackpressureHighWaterAction) = discard)

    check app.server.options.wsBackpressureHighWaterBytes == 2048
    check app.server.options.wsBackpressureHighWaterAction == bhwDropOldest
    check app.wsHighWaterHandler != nil
    check app.backpressureHighWaterCount() == 0

    let metrics = app.optimizationMetrics()
    var highWaterEvents = -1'i64
    check metrics.tryGet("backpressure_high_water_events", highWaterEvents)
    check highWaterEvents == 0

  test "paged buffer policy and metrics are exposed via app":
    let app = newExpressApp()
    discard app.setPageBufferPoolPolicy(
      maxRetainedPages = 2,
      maxRetainedBytes = 64'i64,
      trimNow = true,
      trimTargetPages = 0,
      trimTargetBytes = 0'i64
    )
    discard app.trimPageBufferPool(retainPages = 0, retainBytes = 0'i64)
    resetPagePoolMetrics()

    var buf = initPageBuffer(32)
    buf.add("abc")
    buf.release()

    let poolMetrics = app.pageBufferPoolMetrics()
    when defined(pagepool_metrics):
      check (poolMetrics.hitCount + poolMetrics.missCount) >= 1'i64
    else:
      check poolMetrics.hitCount == 0'i64
      check poolMetrics.missCount == 0'i64
    check poolMetrics.retainedPages == 1
    check poolMetrics.retainedBytes == 32'i64

    let snapshot = app.optimizationMetrics()
    check snapshot.get("page_pool_hits", -1'i64) >= 0'i64
    check snapshot.get("page_pool_misses", -1'i64) >= 0'i64
    check snapshot.get("page_pool_bytes", -1'i64) >= 0'i64
    check snapshot.get("page_pool_retained", -1'i64) >= 0'i64
    snapshot.close()

    discard app.trimPageBufferPool(retainPages = 0, retainBytes = 0'i64)
