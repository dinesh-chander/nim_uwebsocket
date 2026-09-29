import std/unittest
import ../src/nim_usockets/http

suite "Stream controls and server hooks":
  test "pause/resume read are safe on detached response":
    var res: HttpResponse
    new(res)
    res.socket = nil
    res.ssl = 0
    res.pauseRead()
    res.resumeRead()
    check res.isReadPaused() == false

  test "response lifecycle helpers stay engine-owned and nil-safe":
    var res: HttpResponse
    new(res)

    check res.autoEndEnabled() == false
    check res.connectionCloseEnabled() == false
    check res.bodyWasSent() == false

    res.setAutoEndEnabled(true)
    res.setConnectionCloseEnabled(true)
    res.markBodySent()
    res.applyStatusCode(404)

    check res.autoEndEnabled() == true
    check res.connectionCloseEnabled() == true
    check res.bodyWasSent() == true
    check res.statusCode == Http404
    check res.statusCodeInt == 404

    res.applyStatusCode(422)
    check res.statusCode == Http200
    check res.statusCodeInt == 422

    var req: HttpRequest
    new(req)
    req.methodKind = hmConnect
    res.requestRef = req
    res.requestMethod = hmConnect
    check res.requestHandle() == req
    check res.requestMethodKind() == hmConnect

    var nilRes: HttpResponse = nil
    nilRes.setAutoEndEnabled(true)
    nilRes.setConnectionCloseEnabled(true)
    nilRes.markBodySent()
    nilRes.applyStatusCode(201)
    check nilRes.autoEndEnabled() == false
    check nilRes.connectionCloseEnabled() == false
    check nilRes.bodyWasSent() == false
    check nilRes.requestHandle() == nil
    check nilRes.requestMethodKind() == hmGet

  test "server hook setters are assignable":
    let server = newHttpServer()
    server.onConnectionOpen(proc(remoteIp: string) = discard)
    let closeHandler: ConnectionCloseHandler =
      proc(remoteIp: string, wasWebSocket: bool, requestSeq: uint64, socketKey: uint64) {.closure.} =
        discard
    server.onConnectionClose(closeHandler)
    server.onRequestStart(proc(req: HttpRequest) = discard)
    server.onRequestEnd(proc(req: HttpRequest, statusCode: int, durationMicros: int64) = discard)
    server.onBeforeHeaders(proc(req: HttpRequest, res: HttpResponse) = discard)
    server.onBeforeWrite(proc(bytes: int, isWebSocket: bool) = discard)
    server.onAfterWrite(proc(bytes: int, ok: bool, isWebSocket: bool) = discard)
    server.onBackpressure(proc(bufferedBytes: int64, isWebSocket: bool) = discard)
    server.onTimeout(proc(kind: string, remoteIp: string) = discard)
    server.onError(proc(message: string) = discard)
    server.onPanic(proc(message: string) = discard)
    server.setWsCompressionEnabled(true)
    server.setWsCompressionThreshold(2048)
    server.setWsCompressionNoContextTakeover(true, true)
    server.setWsCompressionBypass(disableForBinary = true, disableForText = false)
    server.setWsCompressionBackpressureBypass(4096)

    check server.connectionOpenHandler != nil
    check server.connectionCloseHandler != nil
    check server.requestStartHandler != nil
    check server.requestEndHandler != nil
    check server.beforeHeadersHandler != nil
    check server.beforeWriteHandler != nil
    check server.afterWriteHandler != nil
    check server.backpressureHandler != nil
    check server.timeoutHandler != nil
    check server.errorHandler != nil
    check server.panicHandler != nil
    check server.options.wsCompressionEnabled == true
    check server.options.wsCompressionMinBytes == 2048
    check server.options.wsCompressionServerNoContextTakeover == true
    check server.options.wsCompressionClientNoContextTakeover == true
    check server.options.wsCompressionDisableForBinary == true
    check server.options.wsCompressionDisableForText == false
    check server.options.wsCompressionBackpressureBypassBytes == 4096

  test "ws high-water decision and policy setters":
    let noTrigger = decideWsBackpressureHighWater(128, 256, 1024, bhwDropNewest)
    check noTrigger.triggered == false
    check noTrigger.projectedBytes == 384

    let triggerNewest = decideWsBackpressureHighWater(900, 300, 1024, bhwDropNewest)
    check triggerNewest.triggered
    check triggerNewest.projectedBytes == 1200
    check triggerNewest.action == bhwDropNewest

    let triggerOldest = decideWsBackpressureHighWater(900, 300, 1024, bhwDropOldest)
    check triggerOldest.triggered
    check triggerOldest.action == bhwDropOldest

    let server = newHttpServer()
    server.setWsBackpressureHighWater(4096)
    server.setWsBackpressureHighWaterAction(bhwDropOldest)
    server.onWebSocketHighWater(proc(ws: WebSocket, bufferedBytes: int64, action: BackpressureHighWaterAction) = discard)

    check server.options.wsBackpressureHighWaterBytes == 4096
    check server.options.wsBackpressureHighWaterAction == bhwDropOldest
    check server.wsHighWaterHandler != nil
    check server.getBackpressureHighWaterEventCount() == 0

  test "fairness budget options are configurable with safe minimums":
    let defaults = defaultServerOptions()
    check defaults.parseBudgetRequestsPerRead > 0
    check defaults.parseBudgetBytesPerRead >= 1024
    check defaults.loopDispatchBudgetRequests > 0
    check defaults.loopDispatchBudgetBytes >= 1024
    check defaults.writeBudgetIterationsPerFlush > 0
    check defaults.writeBudgetBytesPerFlush >= 1024
    check defaults.loopWriteBudgetBytes >= 1024

    let server = newHttpServer()
    server.setParseFairnessBudget(0, 0)
    server.setLoopDispatchFairnessBudget(0, 0)
    server.setWriteFairnessBudget(0, 0)
    server.setLoopWriteFairnessBudget(0)

    check server.options.parseBudgetRequestsPerRead == 1
    check server.options.parseBudgetBytesPerRead == 1024
    check server.options.loopDispatchBudgetRequests == 1
    check server.options.loopDispatchBudgetBytes == 1024
    check server.options.writeBudgetIterationsPerFlush == 1
    check server.options.writeBudgetBytesPerFlush == 1024
    check server.options.loopWriteBudgetBytes == 1024
