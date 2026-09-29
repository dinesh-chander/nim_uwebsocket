import std/[os, strutils, tables]
import ../nim_express/src/nim_express

type
  WsBenchScenario = enum
    wbsEcho
    wbsRealtime

  RealtimeConnState = object
    messageCount: int64
    lastSeq: int64
    room: int
    checksum: uint32

  WsBenchConfig = object
    port: int
    threads: int
    scenario: WsBenchScenario
    expectedClients: int
    messageBytes: int
    dynamicBackpressure: bool
    wsQueueBudgetMb: int
    wsKeepaliveMs: int
    wsIdleTimeoutSec: int
    wsMaxBackpressureBytes: int
    wsBackpressureHighWaterBytes: int
    wsBackpressureAction: BackpressureHighWaterAction
    wsCloseOnBackpressureLimit: bool
    wsWriteCoalesceMaxBytes: int
    wsWriteCoalesceMaxFrames: int
    wsRecvBufferBytes: int
    wsSendBufferBytes: int
    wsNotSentLowWaterBytes: int

proc parseEnvIntOr(key: string, default: int): int =
  let raw = getEnv(key, "")
  if raw.len == 0:
    return default
  try:
    parseInt(raw)
  except ValueError:
    default

proc parseEnvBoolOr(key: string, default: bool): bool =
  let raw = getEnv(key, "")
  if raw.len == 0:
    return default
  case raw.toLowerAscii().strip()
  of "1", "true", "yes", "on":
    true
  of "0", "false", "no", "off":
    false
  else:
    default

proc parseHighWaterAction(raw: string, default: BackpressureHighWaterAction): BackpressureHighWaterAction =
  case raw.toLowerAscii().strip()
  of "drop-oldest", "drop_oldest", "oldest":
    bhwDropOldest
  of "close":
    bhwClose
  of "drop-newest", "drop_newest", "newest", "":
    bhwDropNewest
  else:
    default

proc parseScenario(raw: string): WsBenchScenario =
  case raw.toLowerAscii().strip()
  of "realtime", "realistic", "app":
    wbsRealtime
  else:
    wbsEcho

proc readConfig(): WsBenchConfig =
  result.port = parseEnvIntOr("PORT", 3400)
  result.threads = parseEnvIntOr("THREADS", 0)
  result.scenario = parseScenario(getEnv("WS_BENCH_SCENARIO", "echo"))
  result.expectedClients = parseEnvIntOr("WS_BENCH_EXPECTED_CLIENTS", 0)
  result.messageBytes = parseEnvIntOr("WS_BENCH_MESSAGE_BYTES", 0)
  result.dynamicBackpressure = parseEnvBoolOr("WS_BENCH_DYNAMIC_BACKPRESSURE", false)
  result.wsQueueBudgetMb = parseEnvIntOr("WS_BENCH_WS_QUEUE_BUDGET_MB", 512)
  result.wsKeepaliveMs = parseEnvIntOr("NIM_EXPRESS_WS_KEEPALIVE_INTERVAL_MS", 0)
  result.wsIdleTimeoutSec = parseEnvIntOr("NIM_EXPRESS_WS_IDLE_TIMEOUT_SEC", 0)
  result.wsMaxBackpressureBytes = parseEnvIntOr("NIM_EXPRESS_WS_MAX_BACKPRESSURE_BYTES", 128 * 1024)
  result.wsBackpressureHighWaterBytes = parseEnvIntOr("NIM_EXPRESS_WS_BACKPRESSURE_HIGH_WATER_BYTES", 0)
  result.wsBackpressureAction = parseHighWaterAction(getEnv("NIM_EXPRESS_WS_BACKPRESSURE_HIGH_WATER_ACTION", ""), bhwDropNewest)
  result.wsCloseOnBackpressureLimit = parseEnvBoolOr("NIM_EXPRESS_WS_CLOSE_ON_BACKPRESSURE_LIMIT", false)
  result.wsWriteCoalesceMaxBytes = parseEnvIntOr("NIM_EXPRESS_WS_WRITE_COALESCE_MAX_BYTES", 64 * 1024)
  result.wsWriteCoalesceMaxFrames = parseEnvIntOr("NIM_EXPRESS_WS_WRITE_COALESCE_MAX_FRAMES", 1)
  result.wsRecvBufferBytes = parseEnvIntOr("NIM_EXPRESS_WS_RECV_BUFFER", 0)
  result.wsSendBufferBytes = parseEnvIntOr("NIM_EXPRESS_WS_SEND_BUFFER", 0)
  result.wsNotSentLowWaterBytes = parseEnvIntOr("NIM_EXPRESS_WS_NOTSENT_LOWWATER", 0)
  if result.dynamicBackpressure and
      getEnv("NIM_EXPRESS_WS_BACKPRESSURE_HIGH_WATER_BYTES", "").len == 0 and
      result.expectedClients > 0 and result.wsQueueBudgetMb > 0:
    let budgetBytes = result.wsQueueBudgetMb * 1024 * 1024
    let perClientBudget = max(1024, budgetBytes div result.expectedClients)
    let minBurstBudget =
      if result.messageBytes > 0:
        max(4 * (result.messageBytes + 32), 16 * 1024)
      else:
        16 * 1024
    result.wsBackpressureHighWaterBytes =
      min(result.wsMaxBackpressureBytes, max(minBurstBudget, perClientBudget))
  if result.dynamicBackpressure and result.wsBackpressureHighWaterBytes > 0 and
      getEnv("NIM_EXPRESS_WS_CLOSE_ON_BACKPRESSURE_LIMIT", "").len == 0:
    result.wsCloseOnBackpressureLimit = true

proc echoConfig(cfg: WsBenchConfig) =
  echo "ws_echo_bench config:"
  echo "  port=", cfg.port
  echo "  threads=", cfg.threads
  echo "  scenario=", cfg.scenario
  echo "  expected_clients=", cfg.expectedClients
  echo "  message_bytes=", cfg.messageBytes
  echo "  dynamic_backpressure=", cfg.dynamicBackpressure
  echo "  ws_queue_budget_mb=", cfg.wsQueueBudgetMb
  echo "  ws_keepalive_ms=", cfg.wsKeepaliveMs
  echo "  ws_idle_timeout_sec=", cfg.wsIdleTimeoutSec
  echo "  ws_max_backpressure_bytes=", cfg.wsMaxBackpressureBytes
  echo "  ws_backpressure_high_water_bytes=", cfg.wsBackpressureHighWaterBytes
  echo "  ws_backpressure_action=", cfg.wsBackpressureAction
  echo "  ws_close_on_backpressure_limit=", cfg.wsCloseOnBackpressureLimit
  echo "  ws_write_coalesce_max_bytes=", cfg.wsWriteCoalesceMaxBytes
  echo "  ws_write_coalesce_max_frames=", cfg.wsWriteCoalesceMaxFrames
  echo "  ws_recv_buffer_bytes=", cfg.wsRecvBufferBytes
  echo "  ws_send_buffer_bytes=", cfg.wsSendBufferBytes
  echo "  ws_notsent_lowwater_bytes=", cfg.wsNotSentLowWaterBytes

proc wsSocketKey(ws: WebSocket): uint64 {.inline.} =
  if ws == nil or ws.socket == nil:
    0'u64
  else:
    cast[uint64](cast[uint](ws.socket))

proc rawCharAt(data: pointer, offset: int): char {.inline.} =
  cast[ptr UncheckedArray[char]](data)[offset]

proc rawFind(data: pointer, dataLen: int, needle: string): int {.inline.} =
  if data == nil or dataLen <= 0 or needle.len == 0 or needle.len > dataLen:
    return -1
  let lastStart = dataLen - needle.len
  var i = 0
  while i <= lastStart:
    if data.rawCharAt(i) == needle[0]:
      var j = 1
      while j < needle.len and data.rawCharAt(i + j) == needle[j]:
        inc j
      if j == needle.len:
        return i
    inc i
  -1

proc parsePositiveField(data: pointer, dataLen: int, field: string): int64 {.inline.} =
  let p = rawFind(data, dataLen, field)
  if p < 0:
    return 0
  var i = p + field.len
  while i < dataLen and (data.rawCharAt(i) == ' ' or data.rawCharAt(i) == ':'):
    inc i
  var value = 0'i64
  while i < dataLen:
    let c = data.rawCharAt(i)
    if c notin {'0'..'9'}:
      break
    value = value * 10 + int64(ord(c) - ord('0'))
    inc i
  value

proc sampledChecksum(data: pointer, dataLen: int): uint32 {.inline.} =
  ## Touch the full payload without making the synthetic parser more expensive
  ## than a typical JSON decode plus validation path.
  var h = uint32(2166136261'u32)
  var i = 0
  while i < dataLen:
    h = (h xor uint32(byte(data.rawCharAt(i)))) * 16777619'u32
    inc i, 32
  if dataLen > 0:
    h = (h xor uint32(byte(data.rawCharAt(dataLen - 1)))) * 16777619'u32
  h

proc appendIntField(dst: var string, name: string, value: int64, comma: bool = true) {.inline.} =
  dst.add('"')
  dst.add(name)
  dst.add("\":")
  dst.add($value)
  if comma:
    dst.add(',')

proc buildRealtimeAck(state: RealtimeConnState): string {.inline.} =
  result = newStringOfCap(112)
  result.add("{\"type\":\"ack\",")
  result.appendIntField("seq", state.lastSeq)
  result.appendIntField("count", state.messageCount)
  result.appendIntField("room", state.room.int64)
  result.appendIntField("checksum", state.checksum.int64, comma = false)
  result.add('}')

proc createApp(cfg: WsBenchConfig): ExpressApp {.gcsafe.} =
  let app = newExpressApp()
  app.setWsKeepaliveInterval(cfg.wsKeepaliveMs)
  app.setWsIdleTimeout(cfg.wsIdleTimeoutSec)
  app.setWsMaxBackpressure(cfg.wsMaxBackpressureBytes)
  app.setWsBackpressureHighWater(cfg.wsBackpressureHighWaterBytes)
  app.setWsBackpressureHighWaterAction(cfg.wsBackpressureAction)
  app.setWsCloseOnBackpressureLimit(cfg.wsCloseOnBackpressureLimit)
  if cfg.dynamicBackpressure and cfg.expectedClients > 0 and cfg.wsQueueBudgetMb > 0:
    app.setWsDynamicBackpressure(
      enabled = true,
      expectedConnections = cfg.expectedClients,
      messageBytes = cfg.messageBytes,
      queueBudgetBytes = cfg.wsQueueBudgetMb * 1024 * 1024,
      action = cfg.wsBackpressureAction,
      closeOnBackpressureLimit = cfg.wsCloseOnBackpressureLimit
    )
  app.setWsWriteCoalesceLimits(cfg.wsWriteCoalesceMaxBytes, cfg.wsWriteCoalesceMaxFrames)
  app.setWsSocketTunables(
    cfg.wsRecvBufferBytes,
    cfg.wsSendBufferBytes,
    cfg.wsNotSentLowWaterBytes
  )
  ## Allow multi‑million concurrent sockets when probing limits (Linux FD/RAM bounded).
  app.setMaxConnections(5_000_000)

  app.get("/health") do (req: Request, res: Response):
    res.text("ok")

  app.get("/metrics") do (req: Request, res: Response):
    res.jsonRaw(app.optimizationMetricsJson())

  case cfg.scenario
  of wbsEcho:
    app.wsRaw proc(ws: WebSocket, data: pointer, dataLen: int, isBinary: bool) =
      ws.sendPtr(data, dataLen, binary = isBinary)
  of wbsRealtime:
    var states = initTable[uint64, RealtimeConnState](4096)

    app.onWsOpen proc(ws: WebSocket) =
      let key = ws.wsSocketKey()
      if key != 0:
        states[key] = RealtimeConnState()

    app.onWsClose proc(ws: WebSocket) =
      let key = ws.wsSocketKey()
      if key != 0:
        states.del(key)

    app.wsRaw proc(ws: WebSocket, data: pointer, dataLen: int, isBinary: bool) =
      let key = ws.wsSocketKey()
      if key == 0:
        return

      var state = states.getOrDefault(key)
      state.lastSeq = parsePositiveField(data, dataLen, "\"seq\"")
      state.room = int(parsePositiveField(data, dataLen, "\"room\""))
      state.checksum = sampledChecksum(data, dataLen)
      inc state.messageCount
      states[key] = state

      let ack = buildRealtimeAck(state)
      if isBinary:
        ws.sendBinary(ack)
      else:
        ws.sendText(ack)

  app

when isMainModule:
  let cfg = readConfig()
  echoConfig(cfg)
  ## ``THREADS>0``: ``runThreaded`` — one event loop per thread, same TCP port (SO_REUSEPORT).
  ## Omit or ``0``: single-process listener (backward compatible).
  if cfg.threads > 0:
    runThreaded(proc(): ExpressApp {.gcsafe.} = createApp(cfg), cfg.port, cfg.threads)
  else:
    let app = createApp(cfg)
    app.listen(cfg.port) do (ok: bool):
      if not ok:
        quit(1)
