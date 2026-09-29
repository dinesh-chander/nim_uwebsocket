import std/[random, times]
import ../nim_express/src/nim_express
import ../nim_express/src/nim_express/config
import ../nim_usockets/src/nim_usockets/http as usocketsHttp

type
  ClientEntry = object
    ws: WebSocket
    nextSendMs: float
    sendCount: int64
    idx: int

var
  clients: seq[ClientEntry]
  totalSent: int64
  totalConnections: int
  totalDisconnections: int
  lastStatTime: float
  lastStatSent: int64
  sendErrors: int
  timerTicks: int64
  msgTemplate: string
  sendingEnabled: bool = true
  sendStartThreshold: int = 0

const
  MinDelayMs = 1000.0
  MaxDelayMs = 3000.0
  PayloadSize = 256
  MaxSendsPerTick = 5000

proc pickNextDelay(): float =
  MinDelayMs + rand(MaxDelayMs - MinDelayMs)

proc initMsgTemplate() =
  msgTemplate = newString(PayloadSize)
  for i in 0 ..< PayloadSize:
    msgTemplate[i] = chr(65 + (i mod 26))

proc makeUniqueMessage(clientIdx: int, sendCount: int64): string =
  result = msgTemplate
  let idxStr = $clientIdx
  let seqStr = $sendCount
  var pos = 0
  for c in idxStr:
    if pos < result.len:
      result[pos] = c
      inc pos
  if pos < result.len:
    result[pos] = ':'
    inc pos
  for c in seqStr:
    if pos < result.len:
      result[pos] = c
      inc pos
  if pos < result.len:
    result[pos] = ':'
    inc pos

proc sendRound() =
  inc timerTicks
  let n = clients.len
  if n == 0:
    return

  if sendingEnabled:
    let nowMs = epochTime() * 1000.0
    var sent = 0
    for i in 0 ..< n:
      if sent >= MaxSendsPerTick:
        break
      if clients[i].ws == nil or not clients[i].ws.isOpen or clients[i].ws.socket == nil:
        continue
      if nowMs < clients[i].nextSendMs:
        continue
      let msg = makeUniqueMessage(clients[i].idx, clients[i].sendCount)
      try:
        clients[i].ws.send(msg, binary = false)
        inc clients[i].sendCount
        inc totalSent
        inc sent
      except CatchableError:
        inc sendErrors
      clients[i].nextSendMs = nowMs + pickNextDelay()

  let now = epochTime()
  if now - lastStatTime >= 5.0:
    let dt = now - lastStatTime
    let msgInInterval = totalSent - lastStatSent
    let rate = if dt > 0: float(msgInInterval) / dt else: 0.0
    let tickRate = if dt > 0: float(timerTicks) / dt else: 0.0
    echo "clients=", n, " sent=", totalSent,
      " rate=", int(rate), " msg/sec",
      " errors=", sendErrors,
      " tick/s=", int(tickRate),
      " sending=", sendingEnabled
    lastStatTime = now
    lastStatSent = totalSent
    timerTicks = 0

proc removeClient(ws: WebSocket) =
  for i in 0 ..< clients.len:
    if clients[i].ws == ws:
      clients[i] = clients[^1]
      clients.setLen(clients.len - 1)
      return

proc main() =
  randomize()
  initMsgTemplate()
  lastStatTime = epochTime()

  let app = newExpressApp()
  var cfg = loadAppEnvConfig()
  if cfg.port == DefaultEnvPort:
    cfg.port = 3100
  cfg.maxConnections = 120000
  app.applyAppEnvConfig(cfg)

  app.get("/stats") do (req: Request, res: Response):
    let stats = "connected=" & $clients.len &
      " totalConnected=" & $totalConnections &
      " totalDisconnected=" & $totalDisconnections &
      " totalSent=" & $totalSent &
      " sendErrors=" & $sendErrors &
      " sending=" & $sendingEnabled
    res.text(stats)

  app.get("/start-sending") do (req: Request, res: Response):
    sendingEnabled = true
    let nowMs = epochTime() * 1000.0
    for i in 0 ..< clients.len:
      clients[i].nextSendMs = nowMs + pickNextDelay()
    res.text("sending enabled for " & $clients.len & " clients")

  app.get("/stop-sending") do (req: Request, res: Response):
    sendingEnabled = false
    res.text("sending disabled")

  app.onWsOpen proc(ws: WebSocket) =
    let nowMs = epochTime() * 1000.0
    inc totalConnections
    clients.add(ClientEntry(
      ws: ws,
      nextSendMs: nowMs + pickNextDelay(),
      sendCount: 0,
      idx: totalConnections
    ))
    if totalConnections mod 10000 == 0:
      echo "connections: ", clients.len, " (total opened: ", totalConnections, ")"
    if sendStartThreshold > 0 and clients.len >= sendStartThreshold and not sendingEnabled:
      sendingEnabled = true
      echo "auto-enabled sending at ", clients.len, " connections"

  app.onWsClose proc(ws: WebSocket) =
    inc totalDisconnections
    removeClient(ws)

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    discard

  app.listen(cfg.port) do (ok: bool):
    if ok:
      echo "ws_broadcast_server listening on http://localhost:", cfg.port
      echo "per-connection unique messages, interval: ", int(MinDelayMs), "-", int(MaxDelayMs), "ms random"
      echo "max connections target: 100k+"
      echo "sending disabled until /start-sending is called or threshold reached"
      if cfg.profile.len > 0:
        echo "profile: ", cfg.profile

      app.setInterval(proc() =
        sendRound()
      , 25)
    else:
      echo "failed to listen on port ", cfg.port
      quit(1)

when isMainModule:
  main()
