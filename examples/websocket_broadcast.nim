# Build (from nim_uwebsocket root):
# nim c -d:release -d:lto --panics:off --threads:on --opt:speed -o:examples/bin/websocket_broadcast examples/websocket_broadcast.nim

import std/[json, os, strutils, times, atomics, cpuinfo]
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
var messagesReceived: Atomic[int64]
var messagesSent: Atomic[int64]
var messagesDropped: Atomic[int64]
var connectionsOpened: Atomic[int64]
var connectionsClosed: Atomic[int64]

proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()

  app.server.options.maxConnections = 131072
  app.server.options.maxBodySize = 1 * 1024 * 1024
  app.server.options.connectionTimeout = 300
  app.server.options.gracefulShutdown = true
  app.server.options.gracefulShutdownDrainMs = 10000

  app.server.options.socketNoDelay = true
  app.server.options.socketKeepAlive = true
  app.server.options.socketKeepAliveSeconds = 60
  app.server.options.socketSendBufferBytes = 256 * 1024
  app.server.options.socketRecvBufferBytes = 64 * 1024

  app.server.options.listenExclusivePort = false
  app.server.options.listenEpollExclusive = true

  app.server.options.writeCoalesceMode = wcmThroughput
  app.server.options.writeCoalesceMaxBytes = 2 * 1024 * 1024
  app.server.options.writeCoalesceMaxResponses = 512

  app.server.options.wsKeepaliveInterval = 20000
  app.server.options.wsIdleTimeoutSeconds = 120
  app.server.options.wsResetIdleTimeoutOnSend = true

  app.server.options.wsMaxBackpressure = 32 * 1024 * 1024
  app.server.options.wsBackpressureHighWaterBytes = 16 * 1024 * 1024
  app.server.options.wsBackpressureHighWaterAction = bhwDropNewest
  app.server.options.wsCloseOnBackpressureLimit = true

  app.server.options.wsCompressionEnabled = true
  app.server.options.wsCompressionMinBytes = 128
  app.server.options.wsCompressionServerNoContextTakeover = true
  app.server.options.wsCompressionClientNoContextTakeover = true
  app.server.options.wsCompressionDisableForBinary = true
  app.server.options.wsCompressionDisableForText = false
  app.server.options.wsCompressionBackpressureBypassBytes = 8 * 1024 * 1024
  app.server.options.wsCompressionMinSavingsBytes = 32

  app.server.options.wsWriteCoalesceMaxBytes = 512 * 1024
  app.server.options.wsWriteCoalesceMaxFrames = 64
  app.server.options.wsSocketRecvBufferBytes = 64 * 1024
  app.server.options.wsSocketSendBufferBytes = 256 * 1024
  app.server.options.wsSocketNotSentLowWaterBytes = 16384

  app.server.options.overloadMaxLoopBacklogBytes = 64 * 1024 * 1024
  app.server.options.overloadMaxPendingResponses = 8192
  app.server.options.overloadCloseOnReject = false

  app.server.options.headerReadTimeoutMs = 5000
  app.server.options.bodyReadTimeoutMs = 10000

  setRequestResponsePoolingEnabled(true)
  setContextPoolMax(4096)

  app.use(panicRecovery())

  app.get "/health", proc(req: Request, res: Response) =
    res.native.setHeader("content-type", "application/json")
    res.native.`end`("""{"status":"ok"}""")

  app.get "/", proc(req: Request, res: Response) =
    let wsCount = app.server.getWebSocketCount()
    let connCount = app.server.getConnectionCount()
    res.native.setHeader("content-type", "application/json")
    var resp = "{\"service\":\"websocket-broadcast\""
    resp.add(",\"websockets\":")
    resp.add($wsCount)
    resp.add(",\"connections\":")
    resp.add($connCount)
    resp.add("}")
    res.native.`end`(resp)

  app.get "/metrics", proc(req: Request, res: Response) =
    let uptimeSeconds = int(epochTime() - processStartTime)
    let wsCount = app.server.getWebSocketCount()
    let connCount = app.server.getConnectionCount()
    let received = messagesReceived.load(moRelaxed)
    let sent = messagesSent.load(moRelaxed)
    let dropped = messagesDropped.load(moRelaxed)
    let opened = connectionsOpened.load(moRelaxed)
    let closed = connectionsClosed.load(moRelaxed)
    let overloads = app.overloadRejectCount()
    let bpDrops = app.backpressureDropCount()
    let bpHwEvents = app.backpressureHighWaterCount()
    when defined(posix):
      let pid = $getpid()
    else:
      let pid = "unknown"
    res.native.setHeader("content-type", "application/json")
    var resp = "{\"pid\":" & pid
    resp.add(",\"uptime_seconds\":")
    resp.add($uptimeSeconds)
    resp.add(",\"websockets_active\":")
    resp.add($wsCount)
    resp.add(",\"connections_active\":")
    resp.add($connCount)
    resp.add(",\"connections_opened_total\":")
    resp.add($opened)
    resp.add(",\"connections_closed_total\":")
    resp.add($closed)
    resp.add(",\"messages_received_total\":")
    resp.add($received)
    resp.add(",\"messages_sent_total\":")
    resp.add($sent)
    resp.add(",\"messages_dropped_total\":")
    resp.add($dropped)
    resp.add(",\"overload_rejects\":")
    resp.add($overloads)
    resp.add(",\"backpressure_drops\":")
    resp.add($bpDrops)
    resp.add(",\"backpressure_high_water_events\":")
    resp.add($bpHwEvents)
    if uptimeSeconds > 0:
      resp.add(",\"messages_per_second\":")
      resp.add($(received div int64(uptimeSeconds)))
    resp.add("}")
    res.native.`end`(resp)

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    discard messagesReceived.fetchAdd(1, moRelaxed)

    if not isBinary and message.len > 0:
      if message.startsWith("subscribe:"):
        let topic = message[10..^1].strip()
        if topic.len > 0 and topic.len <= 256:
          discard ws.subscribe(topic)
          ws.send($(%*{"type": "subscribed", "topic": topic}))
          discard messagesSent.fetchAdd(1, moRelaxed)
        return

      if message.startsWith("unsubscribe:"):
        let topic = message[12..^1].strip()
        if topic.len > 0:
          discard ws.unsubscribe(topic)
          ws.send($(%*{"type": "unsubscribed", "topic": topic}))
          discard messagesSent.fetchAdd(1, moRelaxed)
        return

      if message.startsWith("publish:"):
        let colonPos = message.find(':', 8)
        if colonPos > 8:
          let topic = message[8..<colonPos].strip()
          let payload = message[colonPos+1..^1]
          if topic.len > 0 and topic.len <= 256:
            let count = app.server.publish(topic, payload, false)
            discard messagesSent.fetchAdd(int64(count), moRelaxed)
        return

      if message.startsWith("broadcast:"):
        let payload = message[10..^1]
        let count = app.server.publish("broadcast", payload, false)
        discard messagesSent.fetchAdd(int64(count), moRelaxed)
        return

      if message == "ping":
        ws.send("{\"type\":\"pong\",\"ts\":" & $getTime().toUnix() & "}")
        discard messagesSent.fetchAdd(1, moRelaxed)
        return

    ws.send(message, isBinary)
    discard messagesSent.fetchAdd(1, moRelaxed)

  app.onWsOpen proc(ws: WebSocket) =
    discard connectionsOpened.fetchAdd(1, moRelaxed)
    discard ws.subscribe("broadcast")
    ws.send("{\"type\":\"welcome\",\"ts\":" & $getTime().toUnix() & "}")
    discard messagesSent.fetchAdd(1, moRelaxed)

  app.onWsClose proc(ws: WebSocket) =
    discard connectionsClosed.fetchAdd(1, moRelaxed)

  app.onWsDrain proc(ws: WebSocket, bufferedBytes: int64) =
    discard

  app.onWsDropped proc(ws: WebSocket, payloadBytes: int, isBinary: bool) =
    discard messagesDropped.fetchAdd(1, moRelaxed)

  app.onWsHighWater proc(ws: WebSocket, bufferedBytes: int64, action: BackpressureHighWaterAction) =
    discard

  app.onStartup proc(ctx: ExpressApp) =
    processStartTime = epochTime()
    messagesReceived.store(0, moRelaxed)
    messagesSent.store(0, moRelaxed)
    messagesDropped.store(0, moRelaxed)
    connectionsOpened.store(0, moRelaxed)
    connectionsClosed.store(0, moRelaxed)
    prewarmContextPools(512, 512)

  app

when isMainModule:
  let port = parseEnvIntOr("PORT", DefaultPort)
  let workers = parseEnvIntOr("WORKERS", DefaultWorkers)

  echo "=== nim_express WebSocket Broadcast Server ==="
  echo "Port: ", port
  echo "Workers: ", if workers == 0: $(countProcessors()) & " (auto)" else: $workers
  echo "Max connections: 131072"
  echo ""
  echo "WebSocket config:"
  echo "  Keepalive ping: 20s"
  echo "  Idle timeout: 120s"
  echo "  Max backpressure: 32MB per socket"
  echo "  High-water mark: 16MB (drop newest)"
  echo "  Compression: permessage-deflate (text only, >=128 bytes)"
  echo "  Write coalesce: 512KB / 64 frames"
  echo ""
  echo "Protocol:"
  echo "  subscribe:<topic>        - Subscribe to topic"
  echo "  unsubscribe:<topic>      - Unsubscribe from topic"
  echo "  publish:<topic>:<data>   - Publish to topic"
  echo "  broadcast:<data>         - Publish to all"
  echo "  ping                     - Keepalive ping"
  echo "  <other>                  - Echo back"
  echo ""

  runCluster(createApp, port, workers)
