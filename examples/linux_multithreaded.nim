# Build (from nim_uwebsocket root):
# nim c -d:release -d:lto --panics:off --threads:on --opt:speed -o:examples/bin/linux_multithreaded examples/linux_multithreaded.nim

import std/[json, os, strutils, cpuinfo]
import ../nim_express/src/nim_express

const
  DefaultPort = 8080
  DefaultThreads = 0

proc parseEnvIntOr(key: string, default: int): int =
  let raw = getEnv(key, "")
  if raw.len == 0: return default
  try: parseInt(raw)
  except ValueError: default

proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()

  app.server.options.maxConnections = 65536
  app.server.options.maxBodySize = 4 * 1024 * 1024
  app.server.options.connectionTimeout = 120
  app.server.options.gracefulShutdown = true

  app.server.options.socketNoDelay = true
  app.server.options.socketKeepAlive = true
  app.server.options.socketKeepAliveSeconds = 60
  app.server.options.socketFastOpen = true
  app.server.options.socketSendBufferBytes = 256 * 1024
  app.server.options.socketRecvBufferBytes = 128 * 1024
  app.server.options.socketDeferAcceptSeconds = 5
  app.server.options.socketNotSentLowWaterBytes = 16384

  app.server.options.writeCoalesceMode = wcmThroughput
  app.server.options.writeCoalesceMaxBytes = 1024 * 1024
  app.server.options.writeCoalesceMaxResponses = 256
  app.server.options.writeCoalesceThroughputMaxBytes = 512 * 1024
  app.server.options.writeCoalesceThroughputMaxResponses = 128

  app.server.options.listenExclusivePort = false
  app.server.options.listenEpollExclusive = true

  app.server.options.overloadMaxLoopBacklogBytes = 64 * 1024 * 1024
  app.server.options.overloadMaxPendingResponses = 16384
  app.server.options.overloadCloseOnReject = false

  app.server.options.parseBudgetRequestsPerRead = 64
  app.server.options.parseBudgetBytesPerRead = 512 * 1024

  app.server.options.readBufferMinCapacity = 8192
  app.server.options.readBufferMaxCapacity = 256 * 1024

  app.server.options.wsKeepaliveInterval = 30000
  app.server.options.wsIdleTimeoutSeconds = 120
  app.server.options.wsMaxBackpressure = 16 * 1024 * 1024
  app.server.options.wsBackpressureHighWaterBytes = 8 * 1024 * 1024
  app.server.options.wsBackpressureHighWaterAction = bhwDropNewest
  app.server.options.wsCloseOnBackpressureLimit = true
  app.server.options.wsResetIdleTimeoutOnSend = true
  app.server.options.wsCompressionEnabled = true
  app.server.options.wsCompressionServerNoContextTakeover = true
  app.server.options.wsCompressionClientNoContextTakeover = true

  app.server.options.headerReadTimeoutMs = 10000
  app.server.options.bodyReadTimeoutMs = 30000

  setRequestResponsePoolingEnabled(true)
  setContextPoolMax(8192)

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
    res.jsonRaw("""{"message":"nim_express multithreaded server"}""")

  app.get "/api/echo", proc(req: Request, res: Response) =
    req.bindQuery()
    let msg = req.query.getOrDefault("msg", "hello")
    res.json(%*{"echo": msg})

  app.post "/api/json", proc(req: Request, res: Response) =
    let body = req.rawBody()
    res.jsonRaw("{\"received\":" & $body.len & "}")

  app.get "/api/metrics", proc(req: Request, res: Response) =
    let metricsJson = app.optimizationMetricsJson()
    res.jsonRaw(metricsJson)

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    if not isBinary and message.startsWith("subscribe:"):
      let topic = message[10..^1].strip()
      if topic.len > 0:
        discard ws.subscribe(topic)
        ws.send($(%*{"subscribed": topic}))
    elif not isBinary and message.startsWith("publish:"):
      let colonPos = message.find(':', 8)
      if colonPos > 8:
        let topic = message[8..<colonPos].strip()
        let payload = message[colonPos+1..^1]
        discard app.server.publish(topic, payload)
    else:
      ws.send(message, isBinary)

  app.onWsOpen proc(ws: WebSocket) =
    discard ws.subscribe("broadcast")

  app.onWsClose proc(ws: WebSocket) =
    discard

  app.onStartup proc(ctx: ExpressApp) =
    prewarmContextPools(1024, 1024)

  app

when isMainModule:
  let port = parseEnvIntOr("PORT", DefaultPort)
  let threads = parseEnvIntOr("THREADS", DefaultThreads)

  echo "=== nim_express Multi-Threaded Server ==="
  echo "Port: ", port
  echo "Threads: ", if threads == 0: $(countProcessors()) & " (auto)" else: $threads
  echo "Write coalesce: throughput"
  echo "Max connections: 65536"
  echo ""

  runThreaded(createApp, port, threads)
