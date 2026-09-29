# Build (from nim_uwebsocket root):
# nim c -d:release -d:lto --panics:off --threads:on --opt:speed -o:examples/bin/linux_io_uring examples/linux_io_uring.nim

import std/[json, os, strutils, times, cpuinfo, atomics]
import ../nim_express/src/nim_express

const
  DefaultPort = 8080
  DefaultWorkers = 0
  BodySpillDir = "/tmp/nim_express_spill"

proc parseEnvIntOr(key: string, default: int): int =
  let raw = getEnv(key, "")
  if raw.len == 0: return default
  try: parseInt(raw)
  except ValueError: default

when defined(posix):
  import std/posix

var processStartTime: float
var requestCounter: Atomic[int64]

proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()

  # The bundled io_uring backend registers direct file slots at build time.
  # Raise LIBUS_IO_URING_MAX_CONNECTIONS when rebuilding uSockets before
  # increasing this beyond the default.
  app.server.options.maxConnections = parseEnvIntOr("MAX_CONNECTIONS", 4096)
  app.server.options.maxBodySize = 64 * 1024 * 1024
  app.server.options.connectionTimeout = 120
  app.server.options.gracefulShutdown = true
  app.server.options.gracefulShutdownDrainMs = 30000

  # Direct io_uring accepted sockets do not expose native fd handles for
  # per-connection setsockopt in this backend yet; unsupported tunables are
  # reported through transport metrics instead of being silently applied.

  app.server.options.listenExclusivePort = false
  app.server.options.listenEpollExclusive = true
  app.server.options.listenEpollEdgeTrigger = true

  app.server.options.writeCoalesceMode = wcmAdaptive
  app.server.options.writeCoalesceMaxBytes = 2 * 1024 * 1024
  app.server.options.writeCoalesceMaxResponses = 512
  app.server.options.writeCoalesceLatencyMaxBytes = 32 * 1024
  app.server.options.writeCoalesceLatencyMaxResponses = 8
  app.server.options.writeCoalesceThroughputMaxBytes = 1024 * 1024
  app.server.options.writeCoalesceThroughputMaxResponses = 256
  app.server.options.writeCoalesceSmallPayloadBytes = 1024
  app.server.options.writeCoalesceLargePayloadBytes = 65536
  app.server.options.writeCoalesceP99GuardPendingBytes = 4 * 1024 * 1024
  app.server.options.writeCoalesceP99GuardPendingResponses = 64

  app.server.options.bodySpillThreshold = 1 * 1024 * 1024
  app.server.options.bodySpillDir = BodySpillDir
  app.server.options.bodySpillOffloadEnabled = true
  app.server.options.bodySpillOffloadQueueLimit = 64
  app.server.options.bodySpillOffloadQueueBytesLimit = 128 * 1024 * 1024

  app.server.options.overloadMaxLoopBacklogBytes = 128 * 1024 * 1024
  app.server.options.overloadMaxPendingResponses = 32768
  app.server.options.overloadCloseOnReject = false
  app.server.options.overloadRetryAfterSeconds = 1
  app.server.options.overloadAdaptiveEnabled = true
  app.server.options.overloadAdaptiveMinBacklogBytes = 8 * 1024 * 1024
  app.server.options.overloadAdaptiveMaxBacklogBytes = 128 * 1024 * 1024
  app.server.options.overloadAdaptiveMinPendingResponses = 2048
  app.server.options.overloadAdaptiveMaxPendingResponses = 32768
  app.server.options.overloadAdaptiveTightenStepPercent = 15
  app.server.options.overloadAdaptiveRelaxStepPercent = 5
  app.server.options.overloadAdaptiveCooldownRequests = 1000

  app.server.options.spillPressureRejectThreshold = 80
  app.server.options.spillPressureRecoverThreshold = 40

  app.server.options.parseBudgetRequestsPerRead = 128
  app.server.options.parseBudgetBytesPerRead = 1024 * 1024
  app.server.options.loopDispatchBudgetRequests = 256
  app.server.options.loopDispatchBudgetBytes = 2 * 1024 * 1024
  app.server.options.writeBudgetIterationsPerFlush = 32
  app.server.options.writeBudgetBytesPerFlush = 1024 * 1024
  app.server.options.loopWriteBudgetBytes = 4 * 1024 * 1024

  app.server.options.readBufferMinCapacity = 16384
  app.server.options.readBufferMaxCapacity = 512 * 1024
  app.server.options.readBufferShrinkPercent = 50

  app.server.options.minimalHeaderParsing = true
  app.server.options.tlsFlattenThreshold = 4096
  app.server.options.maxPendingBytesPerSocket = 4 * 1024 * 1024

  app.server.options.headerReadTimeoutMs = 5000
  app.server.options.bodyReadTimeoutMs = 60000
  app.server.options.handlerExecTimeoutMs = 30000
  app.server.options.writeDrainTimeoutMs = 30000

  setRequestResponsePoolingEnabled(true)
  setContextPoolMax(16384)

  app.use(panicRecovery())
  app.use(jsonLogger(JsonLoggerOptions(
    sink: proc(line: string) {.closure.} = echo(line),
    includeFields: {jlfTimestamp, jlfMethod, jlfPath, jlfStatus, jlfDurationMs},
    skipPaths: @["/health", "/healthz", "/ready", "/metrics"],
    skipHealthChecks: true
  )))

  app.get "/health", proc(req: Request, res: Response) =
    res.jsonRaw("""{"status":"ok"}""")

  app.get "/ready", proc(req: Request, res: Response) =
    res.jsonRaw("""{"ready":true}""")

  app.get "/", proc(req: Request, res: Response) =
    discard requestCounter.fetchAdd(1, moRelaxed)
    res.jsonRaw("""{"message":"nim_express linux-optimized server"}""")

  app.get "/api/echo", proc(req: Request, res: Response) =
    discard requestCounter.fetchAdd(1, moRelaxed)
    req.bindQuery()
    let msg = req.query.getOrDefault("msg", "hello")
    res.json(%*{"echo": msg})

  app.post "/api/data", proc(req: Request, res: Response) =
    discard requestCounter.fetchAdd(1, moRelaxed)
    let body = req.rawBody()
    res.json(%*{"received": body.len, "spilled": req.native.bodyInFile})

  app.post "/api/upload", proc(req: Request, res: Response) =
    discard requestCounter.fetchAdd(1, moRelaxed)
    let body = req.rawBody()
    let spilled = req.native.bodyInFile
    var payload = newJObject()
    payload["size"] = %body.len
    payload["spilled"] = %spilled
    if spilled and req.native.bodyFilePath.len > 0:
      payload["spill_path"] = %req.native.bodyFilePath
    res.json(payload)

  app.get "/metrics", proc(req: Request, res: Response) =
    let uptimeSeconds = epochTime() - processStartTime
    let totalRequests = requestCounter.load(moRelaxed)
    when defined(posix):
      let pid = $getpid()
    else:
      let pid = "unknown"
    var resp = "{\"pid\":" & pid
    resp.add(",\"uptime_seconds\":")
    resp.add($int(uptimeSeconds))
    resp.add(",\"total_requests\":")
    resp.add($totalRequests)
    resp.add(",\"overload_rejects\":")
    resp.add($app.overloadRejectCount())
    resp.add(",\"parser_errors\":")
    resp.add($app.parserErrorCount())
    resp.add(",\"write_retries\":")
    resp.add($app.writeRetryCount())
    resp.add(",\"backpressure_drops\":")
    resp.add($app.backpressureDropCount())
    resp.add(",\"config\":{")
    resp.add("\"write_coalesce\":\"adaptive\"")
    resp.add(",\"body_spill_threshold\":")
    resp.add($app.server.options.bodySpillThreshold)
    resp.add(",\"overload_adaptive\":true")
    resp.add(",\"minimal_header_parsing\":true")
    resp.add(",\"max_connections\":")
    resp.add($app.server.options.maxConnections)
    resp.add(",\"tcp_fastopen\":true")
    resp.add(",\"tcp_defer_accept\":")
    resp.add($app.server.options.socketDeferAcceptSeconds)
    resp.add(",\"epoll_exclusive\":true")
    resp.add(",\"epoll_edge_trigger\":true")
    resp.add("}}")
    res.jsonRaw(resp)

  app.onStartup proc(ctx: ExpressApp) =
    processStartTime = epochTime()
    requestCounter.store(0, moRelaxed)
    try:
      createDir(BodySpillDir)
    except OSError:
      discard
    prewarmContextPools(2048, 2048)

  app

when isMainModule:
  let port = parseEnvIntOr("PORT", DefaultPort)
  let workers = parseEnvIntOr("WORKERS", DefaultWorkers)

  echo "=== nim_express Linux-Optimized Server ==="
  echo "Port: ", port
  echo "Workers: ", if workers == 0: $(countProcessors()) & " (auto)" else: $workers
  echo ""
  echo "Linux optimizations:"
  echo "  TCP_FASTOPEN: enabled"
  echo "  TCP_DEFER_ACCEPT: 10s"
  echo "  TCP_NODELAY: enabled"
  echo "  TCP_NOTSENT_LOWAT: 32768"
  echo "  EPOLL_EXCLUSIVE: enabled"
  echo "  EPOLLET: enabled"
  echo "  Write coalesce: adaptive (latency/throughput auto-select)"
  echo "  Body spill: >=1MB -> ", BodySpillDir
  echo "  Overload: adaptive AIMD with Retry-After"
  echo "  Fairness budgets: request/byte/write per-loop"
  echo "  Minimal header parsing: enabled"
  echo "  Read buffer: 16KB-512KB adaptive"
  echo "  Context pools: 16384 pre-warmed"
  echo ""

  runCluster(createApp, port, workers)
