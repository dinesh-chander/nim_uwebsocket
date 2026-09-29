import std/[unittest, asyncdispatch, strutils, os]
when not defined(windows):
  import std/posix
import ../src/nim_express/[types, app, response, offload]

proc blockingDouble(x: int): int =
  sleep(10)
  x * 2

proc blockingSlow(): int =
  sleep(100)
  1

suite "Stability contracts":
  test "macOS GCD event loop has an explicit main-thread guard":
    assertMacosGcdMainThread("test")
    check MacosGcdMainThreadError.contains("process main thread")
    let appSource = readFile(parentDir(parentDir(currentSourcePath())) / "src" / "nim_express" / "app.nim")
    check appSource.contains("pthread_main_np")
    check appSource.contains("assertMacosGcdMainThread(\"runServerLoop\")")

  test "request cancellation lifecycle is one-way and hook is single-shot":
    var req: Request
    new(req)
    req.lifecycleState = rlsActive
    req.cancelReason = rcrNone
    req.cancelNotified = false

    var hookCalls = 0
    var seenReason = rcrNone
    req.onCancel(proc(r: Request, reason: RequestCancelReason) =
      inc hookCalls
      seenReason = reason
    )

    check req.notifyRequestTimeout()
    check req.requestCancelled()
    check req.cancelReason == rcrTimeout
    check hookCalls == 1
    check seenReason == rcrTimeout
    check req.notifyRequestDisconnect() == false
    check hookCalls == 1

    req.markRequestReleased()
    check req.requestReleased()
    check req.notifyRequestShutdown() == false

  test "late writes are dropped after cancellation/release":
    var req: Request
    new(req)
    req.lifecycleState = rlsActive

    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet

    var res: Response
    new(res)
    res.native = nativeRes
    res.request = req
    res.headers = newFastMap[string]()

    discard req.notifyRequestTimeout()
    res.send("ignored")
    check res.droppedLateWritesCount() == 1

    req.markRequestReleased()
    res.text("ignored-again")
    check res.droppedLateWritesCount() == 2

  test "timeout/protocol hooks and router lock are explicit":
    let app = newExpressApp()

    var timeoutPhase = ""
    app.onTimeoutMetadataHook(proc(
      kind: string,
      phase: string,
      remoteIp: string,
      requestSeq: uint64,
      isWebSocket: bool
    ) =
      timeoutPhase = phase
    )
    check app.timeoutMetadataHook != nil
    check app.server.timeoutMetadataHandler != nil
    app.server.timeoutMetadataHandler("header_read", "header_read", "127.0.0.1", 1'u64, false)
    check timeoutPhase == "header_read"

    app.onProtocolErrorHook(proc(statusCode: int, remoteIp: string): tuple[statusCode: int, body: string, closeConnection: bool] =
      (statusCode: 429, body: """{"error":"too_many"}""", closeConnection: false)
    )
    let transformed = app.protocolErrorHook(400, "127.0.0.1")
    check transformed.statusCode == 429
    check transformed.closeConnection == false
    check transformed.body.contains("too_many")

    app.listenStarted = true
    expect ValueError:
      app.use(proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
        await next()
      )

    let router = newRouter()
    router.lockRouterMutations("listen_started")
    expect ValueError:
      router.ensureRouterMutable()

  test "offload outcome contract classifies ok timeout and error":
    check DefaultOffloadTimeoutMs > 0
    let ok = waitFor runOffloadOutcome("double", "req-1", 500, blockingDouble(21))
    check ok.kind == ookOk
    check ok.value == 42
    check ok.operation == "double"
    check ok.correlationId == "req-1"

    let timed = waitFor runOffloadOutcome("slow", "req-2", 5, blockingSlow())
    check timed.kind == ookOffloadTimeout
    check timed.errorClass == "offload_timeout"
    check timed.operation == "slow"
    check timed.correlationId == "req-2"
    check timed.offloadOutcomeClass() == "offload_timeout"
    check timed.errorMessage.contains("after 5ms")

    let errored = OffloadOutcome[int](
      kind: ookOffloadError,
      value: 0,
      errorClass: "offload_error",
      errorMessage: "boom",
      operation: "error",
      correlationId: "req-3"
    )
    check errored.offloadOutcomeClass() == "offload_error"
    let encodedError = formatOffloadOutcomeEvent(errored)
    check encodedError.contains("\"class\":\"offload_error\"")
    check encodedError.contains("\"operation\":\"error\"")

    let app = newExpressApp()
    var emitted = ""
    app.onErrorHook(proc(message: string) =
      emitted = message
    )
    app.emitOffloadOutcome(timed)
    check emitted.contains("\"class\":\"offload_timeout\"")
    check emitted.contains("\"operation\":\"slow\"")
    check emitted.contains("\"correlation_id\":\"req-2\"")

  when compileOption("threads"):
    test "offload completion falls back when dispatch loop does not drain":
      let server = newHttpServer()
      setOffloadDispatchServer(server)
      try:
        let completed = waitFor runOffload(blockingDouble(7))
        check completed == 14
      finally:
        setOffloadDispatchServer(nil)
        server.close()

  test "optimization metrics expose stability counters":
    let app = newExpressApp()
    let metrics = app.optimizationMetrics()
    check metrics.get("overload_reject_backlog", -1'i64) >= 0'i64
    check metrics.get("overload_reject_pending", -1'i64) >= 0'i64
    check metrics.get("shutdown_drained_connections", -1'i64) >= 0'i64
    check metrics.get("shutdown_forced_connections", -1'i64) >= 0'i64
    metrics.close()

    let encoded = app.optimizationMetricsJson()
    check encoded.contains("\"overload_reject_backlog\":")
    check encoded.contains("\"shutdown_forced_connections\":")

  when not defined(windows):
    test "cluster supervision policy uses rolling window cap and emits structured event":
      let policy = ClusterSupervisionPolicy(
        baseBackoffMs: 10,
        maxBackoffMs: 40,
        jitterMs: 8,
        restartStormCap: 2,
        restartStormWindowMs: 100,
        hardRespawnCap: 3,
        hardRespawnWindowMs: 120
      )
      let delay = boundedRespawnDelayMs(policy, 1)
      check delay >= 10
      check delay <= 18
      check boundedRespawnDelayMs(policy, 3) >= 40
      check boundedRespawnDelayMs(policy, 3) <= 48

      var restartWindow: seq[int64] = @[]
      check canRespawnWorker(policy, restartWindow, 1_000)
      check canRespawnWorker(policy, restartWindow, 1_050)
      check canRespawnWorker(policy, restartWindow, 1_090) == false
      check canRespawnWorker(policy, restartWindow, 1_250)

      var hardWindow: seq[int64] = @[]
      check withinHardRespawnBudget(policy, hardWindow, 1_000)
      check withinHardRespawnBudget(policy, hardWindow, 1_050)
      check withinHardRespawnBudget(policy, hardWindow, 1_090)
      check withinHardRespawnBudget(policy, hardWindow, 1_100) == false
      check withinHardRespawnBudget(policy, hardWindow, 1_250)

      for _ in 0 ..< 32:
        let jitter = respawnJitterMs(8)
        check jitter >= 0
        check jitter <= 8

      let evt = formatWorkerFailureEvent(1, Pid(123), 9.cint, 2)
      check evt.contains("\"event\":\"cluster_worker_exit\"")
      check evt.contains("\"worker_slot\":1")
      check evt.contains("\"restart_count\":2")

    test "cluster parent shutdown flag is explicit and resettable":
      resetClusterParentSignalFlags()
      check not clusterParentShutdownRequested()
      markClusterParentShutdownForTest()
      check clusterParentShutdownRequested()
      resetClusterParentSignalFlags()
      check not clusterParentShutdownRequested()
      check DefaultClusterWorkerShutdownGraceMs > 0
