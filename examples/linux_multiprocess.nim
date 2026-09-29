# Build (from nim_uwebsocket root):
# nim c -d:release -d:lto --panics:off --threads:on --opt:speed -o:examples/bin/linux_multiprocess examples/linux_multiprocess.nim

import std/[json, os, strutils, times, cpuinfo]
import ../nim_express/src/nim_express

const
  DefaultPort = 8080
  DefaultWorkers = 0

proc parseEnvIntOr(key: string, default: int): int =
  let raw = getEnv(key, "")
  if raw.len == 0: return default
  try: parseInt(raw)
  except ValueError: default

when defined(posix):
  import std/posix

var processStartTime: float

proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()

  app.server.options.maxConnections = 32768
  app.server.options.maxBodySize = 4 * 1024 * 1024
  app.server.options.connectionTimeout = 120
  app.server.options.gracefulShutdown = true
  app.server.options.gracefulShutdownDrainMs = 15000

  app.server.options.socketNoDelay = true
  app.server.options.socketKeepAlive = true
  app.server.options.socketKeepAliveSeconds = 60
  app.server.options.socketFastOpen = true
  app.server.options.socketSendBufferBytes = 128 * 1024
  app.server.options.socketRecvBufferBytes = 128 * 1024
  app.server.options.socketDeferAcceptSeconds = 5
  app.server.options.socketNotSentLowWaterBytes = 16384

  app.server.options.listenExclusivePort = false
  app.server.options.listenEpollExclusive = true
  app.server.options.listenEpollEdgeTrigger = true

  app.server.options.writeCoalesceMode = wcmAdaptive
  app.server.options.writeCoalesceMaxBytes = 512 * 1024
  app.server.options.writeCoalesceMaxResponses = 128

  app.server.options.overloadMaxLoopBacklogBytes = 32 * 1024 * 1024
  app.server.options.overloadMaxPendingResponses = 8192
  app.server.options.overloadCloseOnReject = false
  app.server.options.overloadAdaptiveEnabled = true
  app.server.options.overloadAdaptiveMinBacklogBytes = 4 * 1024 * 1024
  app.server.options.overloadAdaptiveMaxBacklogBytes = 64 * 1024 * 1024
  app.server.options.overloadAdaptiveMinPendingResponses = 1024
  app.server.options.overloadAdaptiveMaxPendingResponses = 16384
  app.server.options.overloadAdaptiveTightenStepPercent = 10
  app.server.options.overloadAdaptiveRelaxStepPercent = 5
  app.server.options.overloadAdaptiveCooldownRequests = 500

  app.server.options.parseBudgetRequestsPerRead = 32
  app.server.options.parseBudgetBytesPerRead = 256 * 1024

  app.server.options.readBufferMinCapacity = 8192
  app.server.options.readBufferMaxCapacity = 128 * 1024

  app.server.options.headerReadTimeoutMs = 10000
  app.server.options.bodyReadTimeoutMs = 30000

  setRequestResponsePoolingEnabled(true)
  setContextPoolMax(4096)

  app.use(panicRecovery())
  app.use(jsonLogger(JsonLoggerOptions(
    sink: proc(line: string) {.closure.} = echo(line),
    includeFields: {jlfTimestamp, jlfMethod, jlfPath, jlfStatus, jlfDurationMs},
    skipPaths: @["/health", "/healthz", "/ready"],
    skipHealthChecks: true
  )))

  app.get "/health", proc(req: Request, res: Response) =
    res.jsonRaw("""{"status":"ok"}""")

  app.get "/ready", proc(req: Request, res: Response) =
    res.jsonRaw("""{"ready":true}""")

  app.get "/", proc(req: Request, res: Response) =
    when defined(posix):
      let pid = getpid()
    else:
      let pid = -1
    res.json(%*{"message": "nim_express cluster worker", "pid": pid})

  app.get "/api/echo", proc(req: Request, res: Response) =
    req.bindQuery()
    let msg = req.query.getOrDefault("msg", "hello")
    res.json(%*{"echo": msg})

  app.get "/api/quote", proc(req: Request, res: Response) =
    res.json(%*{"echo": "a\"b"})

  app.get "/api/large", proc(req: Request, res: Response) =
    let payload = repeat('x', 32 * 1024)
    res.json(%*{"payload": payload})

  app.post "/api/data", proc(req: Request, res: Response) =
    let body = req.rawBody()
    res.jsonRaw("{\"received\":" & $body.len & "}")

  app.get "/api/metrics", proc(req: Request, res: Response) =
    let uptimeSeconds = epochTime() - processStartTime
    when defined(posix):
      let pid = $getpid()
    else:
      let pid = "unknown"
    var resp = "{\"pid\":" & pid
    resp.add(",\"uptime_seconds\":")
    resp.add($int(uptimeSeconds))
    resp.add(",\"metrics\":")
    resp.add(app.optimizationMetricsJson())
    resp.add("}")
    res.jsonRaw(resp)

  app.get "/api/info", proc(req: Request, res: Response) =
    when defined(posix):
      let pid = $getpid()
    else:
      let pid = "unknown"
    let cpus = countProcessors()
    var resp = "{\"pid\":" & pid
    resp.add(",\"cpus\":")
    resp.add($cpus)
    resp.add(",\"max_connections\":")
    resp.add($app.server.options.maxConnections)
    resp.add(",\"write_coalesce\":\"adaptive\"")
    resp.add(",\"epoll_exclusive\":true")
    resp.add(",\"overload_adaptive\":true")
    resp.add("}")
    res.jsonRaw(resp)

  app.onStartup proc(ctx: ExpressApp) =
    processStartTime = epochTime()
    prewarmContextPools(512, 512)

  app

when isMainModule:
  let port = parseEnvIntOr("PORT", DefaultPort)
  let workers = parseEnvIntOr("WORKERS", DefaultWorkers)

  echo "=== nim_express Multi-Process Cluster ==="
  echo "Port: ", port
  echo "Workers: ", if workers == 0: $(countProcessors()) & " (auto)" else: $workers
  echo "SO_REUSEPORT: enabled (kernel load balancing)"
  echo "EPOLL_EXCLUSIVE: enabled"
  echo "Overload: adaptive AIMD"
  echo ""

  runCluster(createApp, port, workers)
