## Typed config loader for nim_express.
## Precedence: defaults < config.json/settings.json < env vars.

import std/[json, os, strutils]
import types
import app

const
  DefaultConfigFileName* = "config.json"
  FallbackConfigFileName* = "settings.json"
  DefaultEnvHost* = "0.0.0.0"
  DefaultEnvPort* = 3000
  DefaultEnvTrustProxy* = false
  DefaultEnvAsyncPumpIntervalMs* = 1
  DefaultEnvMaxInflightAsyncRequests* = 8192
  DefaultEnvContextPoolPrewarm* = 256
  DefaultEnvRequestResponsePoolingEnabled* = false
  DefaultEnvMaxPendingBytesPerSocket* = 0

proc parseBoolValue(raw: string, defaultValue: bool): bool {.inline.} =
  case raw.toLowerAscii()
  of "1", "true", "yes", "on":
    true
  of "0", "false", "no", "off":
    false
  else:
    defaultValue

proc parseIntBounded(raw: string, defaultValue: int, minValue: int, maxValue: int): int {.inline.} =
  try:
    let parsed = parseInt(raw)
    if parsed < minValue or parsed > maxValue:
      return defaultValue
    parsed
  except ValueError:
    defaultValue

proc parseWriteCoalesceMode(raw: string, defaultValue: WriteCoalesceMode): WriteCoalesceMode {.inline.} =
  case raw.toLowerAscii()
  of "adaptive":
    wcmAdaptive
  of "latency":
    wcmLatency
  of "balanced":
    wcmBalanced
  of "throughput":
    wcmThroughput
  else:
    defaultValue

proc parseWsBackpressureAction(raw: string, defaultValue: BackpressureHighWaterAction): BackpressureHighWaterAction {.inline.} =
  case raw.toLowerAscii()
  of "drop-oldest", "drop_oldest", "oldest":
    bhwDropOldest
  of "close":
    bhwClose
  of "drop-newest", "drop_newest", "newest":
    bhwDropNewest
  else:
    defaultValue

## Returns an AppEnvConfig built from the DefaultEnv* constants and `defaultServerOptions` values.
proc defaultAppEnvConfig*(): AppEnvConfig =
  let defaults = defaultServerOptions()
  AppEnvConfig(
    profile: "",
    host: DefaultEnvHost,
    port: DefaultEnvPort,
    trustProxy: DefaultEnvTrustProxy,
    trustedProxyHops: 0,
    trustedProxyAllowlist: "",
    asyncPumpIntervalMs: DefaultEnvAsyncPumpIntervalMs,
    maxInflightAsyncRequests: DefaultEnvMaxInflightAsyncRequests,
    contextPoolPrewarm: DefaultEnvContextPoolPrewarm,
    requestResponsePoolingEnabled: DefaultEnvRequestResponsePoolingEnabled,
    maxPendingBytesPerSocket: defaults.maxPendingBytesPerSocket,
    maxBodySize: defaults.maxBodySize,
    connectionTimeoutSeconds: defaults.connectionTimeout,
    maxConnections: defaults.maxConnections,
    minimalHeaderParsing: defaults.minimalHeaderParsing,
    gracefulShutdown: defaults.gracefulShutdown,
    macosHighQos: defaults.macosHighQos,
    tlsFlattenThreshold: defaults.tlsFlattenThreshold,
    socketNoDelay: defaults.socketNoDelay,
    socketKeepAlive: defaults.socketKeepAlive,
    socketKeepAliveSeconds: defaults.socketKeepAliveSeconds,
    socketFastOpen: defaults.socketFastOpen,
    socketSendBufferBytes: defaults.socketSendBufferBytes,
    socketRecvBufferBytes: defaults.socketRecvBufferBytes,
    socketNotSentLowWaterBytes: defaults.socketNotSentLowWaterBytes,
    socketDeferAcceptSeconds: defaults.socketDeferAcceptSeconds,
    socketIncomingCpu: defaults.socketIncomingCpu,
    listenExclusivePort: defaults.listenExclusivePort,
    listenEpollExclusive: defaults.listenEpollExclusive,
    listenEpollEdgeTrigger: defaults.listenEpollEdgeTrigger,
    writeCoalesceMode: defaults.writeCoalesceMode,
    writeCoalesceMaxBytes: defaults.writeCoalesceMaxBytes,
    writeCoalesceMaxResponses: defaults.writeCoalesceMaxResponses,
    writeCoalesceThroughputMaxBytes: defaults.writeCoalesceThroughputMaxBytes,
    writeCoalesceThroughputMaxResponses: defaults.writeCoalesceThroughputMaxResponses,
    parseBudgetRequestsPerRead: defaults.parseBudgetRequestsPerRead,
    parseBudgetBytesPerRead: defaults.parseBudgetBytesPerRead,
    loopDispatchBudgetRequests: defaults.loopDispatchBudgetRequests,
    loopDispatchBudgetBytes: defaults.loopDispatchBudgetBytes,
    writeBudgetIterationsPerFlush: defaults.writeBudgetIterationsPerFlush,
    writeBudgetBytesPerFlush: defaults.writeBudgetBytesPerFlush,
    loopWriteBudgetBytes: defaults.loopWriteBudgetBytes,
    overloadMaxLoopBacklogBytes: defaults.overloadMaxLoopBacklogBytes,
    overloadMaxPendingResponses: defaults.overloadMaxPendingResponses,
    overloadCloseOnReject: defaults.overloadCloseOnReject,
    overloadAdaptiveEnabled: defaults.overloadAdaptiveEnabled,
    overloadAdaptiveMinBacklogBytes: defaults.overloadAdaptiveMinBacklogBytes,
    overloadAdaptiveMaxBacklogBytes: defaults.overloadAdaptiveMaxBacklogBytes,
    overloadAdaptiveMinPendingResponses: defaults.overloadAdaptiveMinPendingResponses,
    overloadAdaptiveMaxPendingResponses: defaults.overloadAdaptiveMaxPendingResponses,
    overloadAdaptiveTightenStepPercent: defaults.overloadAdaptiveTightenStepPercent,
    overloadAdaptiveRelaxStepPercent: defaults.overloadAdaptiveRelaxStepPercent,
    overloadAdaptiveCooldownRequests: defaults.overloadAdaptiveCooldownRequests,
    wsKeepaliveIntervalMs: defaults.wsKeepaliveInterval,
    wsIdleTimeoutSeconds: defaults.wsIdleTimeoutSeconds,
    wsMaxBackpressureBytes: defaults.wsMaxBackpressure,
    wsBackpressureHighWaterBytes: defaults.wsBackpressureHighWaterBytes,
    wsBackpressureHighWaterAction: defaults.wsBackpressureHighWaterAction,
    wsDynamicBackpressureEnabled: defaults.wsDynamicBackpressureEnabled,
    wsExpectedConnections: defaults.wsExpectedConnections,
    wsMessageBytes: defaults.wsMessageBytes,
    wsQueueBudgetBytes: defaults.wsQueueBudgetBytes,
    wsCloseOnBackpressureLimit: defaults.wsCloseOnBackpressureLimit,
    wsResetIdleTimeoutOnSend: defaults.wsResetIdleTimeoutOnSend,
    wsCompressionEnabled: defaults.wsCompressionEnabled,
    wsCompressionThresholdBytes: defaults.wsCompressionMinBytes,
    wsCompressionMinSavingsBytes: defaults.wsCompressionMinSavingsBytes,
    wsCompressionDisableForBinary: defaults.wsCompressionDisableForBinary,
    wsCompressionDisableForText: defaults.wsCompressionDisableForText,
    wsCompressionBackpressureBypassBytes: defaults.wsCompressionBackpressureBypassBytes,
    wsWriteCoalesceMaxBytes: defaults.wsWriteCoalesceMaxBytes,
    wsWriteCoalesceMaxFrames: defaults.wsWriteCoalesceMaxFrames,
    wsSocketRecvBufferBytes: defaults.wsSocketRecvBufferBytes,
    wsSocketSendBufferBytes: defaults.wsSocketSendBufferBytes,
    wsSocketNotSentLowWaterBytes: defaults.wsSocketNotSentLowWaterBytes,
    bodySpillThresholdBytes: defaults.bodySpillThreshold,
    bodySpillDir: defaults.bodySpillDir
  )

proc applyProfilePreset(cfg: var AppEnvConfig, profileRaw: string) =
  let profile = profileRaw.strip().toLowerAscii()
  if profile.len == 0:
    return
  cfg.profile = profile
  case profile
  of "linux-throughput":
    cfg.socketNoDelay = true
    cfg.socketKeepAlive = true
    cfg.socketKeepAliveSeconds = 60
    cfg.socketFastOpen = true
    cfg.socketSendBufferBytes = 1024 * 1024
    cfg.socketRecvBufferBytes = 1024 * 1024
    cfg.socketNotSentLowWaterBytes = 128 * 1024
    cfg.socketDeferAcceptSeconds = 1
    cfg.listenExclusivePort = false
    cfg.listenEpollExclusive = true
    cfg.writeCoalesceMode = wcmThroughput
    cfg.writeCoalesceMaxBytes = 128 * 1024
    cfg.writeCoalesceMaxResponses = 32
    cfg.writeCoalesceThroughputMaxBytes = 256 * 1024
    cfg.writeCoalesceThroughputMaxResponses = 48
    cfg.parseBudgetRequestsPerRead = 64
    cfg.parseBudgetBytesPerRead = 1024 * 1024
    cfg.loopDispatchBudgetRequests = 512
    cfg.loopDispatchBudgetBytes = 8 * 1024 * 1024
    cfg.writeBudgetIterationsPerFlush = 64
    cfg.writeBudgetBytesPerFlush = 1024 * 1024
    cfg.loopWriteBudgetBytes = 8 * 1024 * 1024
    cfg.maxPendingBytesPerSocket = 1024 * 1024
    cfg.overloadMaxLoopBacklogBytes = 8 * 1024 * 1024
    cfg.overloadMaxPendingResponses = 4096
    cfg.overloadCloseOnReject = false
  of "throughput":
    cfg.socketNoDelay = false
    cfg.socketKeepAlive = true
    cfg.socketKeepAliveSeconds = 60
    cfg.socketFastOpen = true
    cfg.socketSendBufferBytes = 512 * 1024
    cfg.socketRecvBufferBytes = 256 * 1024
    cfg.socketNotSentLowWaterBytes = 128 * 1024
    cfg.writeCoalesceMode = wcmThroughput
    cfg.writeCoalesceMaxBytes = 256 * 1024
    cfg.writeCoalesceMaxResponses = 128
    cfg.writeCoalesceThroughputMaxBytes = 256 * 1024
    cfg.writeCoalesceThroughputMaxResponses = 256
    cfg.parseBudgetRequestsPerRead = 512
    cfg.parseBudgetBytesPerRead = 8 * 1024 * 1024
    cfg.loopDispatchBudgetRequests = 4096
    cfg.loopDispatchBudgetBytes = 64 * 1024 * 1024
    cfg.writeBudgetIterationsPerFlush = 512
    cfg.writeBudgetBytesPerFlush = 8 * 1024 * 1024
    cfg.loopWriteBudgetBytes = 64 * 1024 * 1024
    cfg.maxPendingBytesPerSocket = 1024 * 1024
    cfg.overloadMaxLoopBacklogBytes = 64 * 1024 * 1024
    cfg.overloadMaxPendingResponses = 16384
    cfg.overloadCloseOnReject = false
    cfg.minimalHeaderParsing = true
    cfg.macosHighQos = true
    cfg.wsCompressionEnabled = false
    cfg.wsWriteCoalesceMaxBytes = 512 * 1024
    cfg.wsWriteCoalesceMaxFrames = 256
    cfg.wsSocketRecvBufferBytes = 256 * 1024
    cfg.wsSocketSendBufferBytes = 512 * 1024
    cfg.wsSocketNotSentLowWaterBytes = 128 * 1024
    cfg.wsMaxBackpressureBytes = 4 * 1024 * 1024
    cfg.wsDynamicBackpressureEnabled = true
    cfg.wsQueueBudgetBytes = 512 * 1024 * 1024
    cfg.wsBackpressureHighWaterAction = bhwDropNewest
    cfg.wsIdleTimeoutSeconds = 120
    cfg.connectionTimeoutSeconds = 120
  of "latency":
    cfg.socketNoDelay = true
    cfg.socketKeepAlive = true
    cfg.socketKeepAliveSeconds = 30
    cfg.socketFastOpen = true
    cfg.socketSendBufferBytes = 256 * 1024
    cfg.socketRecvBufferBytes = 128 * 1024
    cfg.socketNotSentLowWaterBytes = 16 * 1024
    cfg.writeCoalesceMode = wcmLatency
    cfg.writeCoalesceMaxBytes = 8 * 1024
    cfg.writeCoalesceMaxResponses = 4
    cfg.writeCoalesceThroughputMaxBytes = 16 * 1024
    cfg.writeCoalesceThroughputMaxResponses = 8
    cfg.parseBudgetRequestsPerRead = 512
    cfg.parseBudgetBytesPerRead = 8 * 1024 * 1024
    cfg.loopDispatchBudgetRequests = 4096
    cfg.loopDispatchBudgetBytes = 64 * 1024 * 1024
    cfg.writeBudgetIterationsPerFlush = 512
    cfg.writeBudgetBytesPerFlush = 8 * 1024 * 1024
    cfg.loopWriteBudgetBytes = 64 * 1024 * 1024
    cfg.maxPendingBytesPerSocket = 256 * 1024
    cfg.overloadMaxLoopBacklogBytes = 0
    cfg.overloadMaxPendingResponses = 0
    cfg.overloadCloseOnReject = false
    cfg.overloadAdaptiveEnabled = false
    cfg.minimalHeaderParsing = true
    cfg.macosHighQos = true
    cfg.wsCompressionEnabled = false
    cfg.wsWriteCoalesceMaxBytes = 64 * 1024
    cfg.wsWriteCoalesceMaxFrames = 32
    cfg.wsSocketRecvBufferBytes = 128 * 1024
    cfg.wsSocketSendBufferBytes = 256 * 1024
    cfg.wsSocketNotSentLowWaterBytes = 16 * 1024
    cfg.wsMaxBackpressureBytes = 512 * 1024
    cfg.wsIdleTimeoutSeconds = 120
    cfg.connectionTimeoutSeconds = 120
  of "websocket":
    cfg.socketNoDelay = true
    cfg.socketKeepAlive = true
    cfg.socketKeepAliveSeconds = 60
    cfg.socketFastOpen = true
    cfg.socketSendBufferBytes = 256 * 1024
    cfg.socketRecvBufferBytes = 256 * 1024
    cfg.socketNotSentLowWaterBytes = 32 * 1024
    cfg.writeCoalesceMode = wcmThroughput
    cfg.minimalHeaderParsing = true
    cfg.wsCompressionEnabled = false
    cfg.wsMaxBackpressureBytes = 2 * 1024 * 1024
    cfg.wsBackpressureHighWaterBytes = 1536 * 1024
    cfg.wsCloseOnBackpressureLimit = false
    cfg.wsWriteCoalesceMaxBytes = 128 * 1024
    cfg.wsWriteCoalesceMaxFrames = 64
    cfg.wsSocketRecvBufferBytes = 256 * 1024
    cfg.wsSocketSendBufferBytes = 256 * 1024
    cfg.wsSocketNotSentLowWaterBytes = 32 * 1024
    cfg.maxPendingBytesPerSocket = 256 * 1024
    cfg.parseBudgetRequestsPerRead = 128
    cfg.parseBudgetBytesPerRead = 2 * 1024 * 1024
    cfg.loopDispatchBudgetRequests = 1024
    cfg.loopDispatchBudgetBytes = 16 * 1024 * 1024
    cfg.writeBudgetIterationsPerFlush = 128
    cfg.writeBudgetBytesPerFlush = 2 * 1024 * 1024
    cfg.loopWriteBudgetBytes = 16 * 1024 * 1024
    cfg.connectionTimeoutSeconds = 120
  of "balanced":
    cfg.socketNoDelay = true
    cfg.socketKeepAlive = true
    cfg.socketKeepAliveSeconds = 60
    cfg.socketFastOpen = true
    cfg.socketSendBufferBytes = 256 * 1024
    cfg.socketRecvBufferBytes = 128 * 1024
    cfg.socketNotSentLowWaterBytes = 32 * 1024
    cfg.writeCoalesceMode = wcmBalanced
    cfg.writeCoalesceMaxBytes = 64 * 1024
    cfg.writeCoalesceMaxResponses = 16
    cfg.writeCoalesceThroughputMaxBytes = 128 * 1024
    cfg.writeCoalesceThroughputMaxResponses = 32
    cfg.parseBudgetRequestsPerRead = 512
    cfg.parseBudgetBytesPerRead = 8 * 1024 * 1024
    cfg.loopDispatchBudgetRequests = 4096
    cfg.loopDispatchBudgetBytes = 64 * 1024 * 1024
    cfg.writeBudgetIterationsPerFlush = 512
    cfg.writeBudgetBytesPerFlush = 8 * 1024 * 1024
    cfg.loopWriteBudgetBytes = 64 * 1024 * 1024
    cfg.maxPendingBytesPerSocket = 256 * 1024
    cfg.overloadMaxLoopBacklogBytes = 16 * 1024 * 1024
    cfg.overloadMaxPendingResponses = 4096
    cfg.overloadCloseOnReject = false
    cfg.minimalHeaderParsing = true
    cfg.macosHighQos = true
    cfg.wsCompressionEnabled = false
    cfg.wsWriteCoalesceMaxBytes = 64 * 1024
    cfg.wsWriteCoalesceMaxFrames = 32
    cfg.wsSocketRecvBufferBytes = 128 * 1024
    cfg.wsSocketSendBufferBytes = 256 * 1024
    cfg.wsSocketNotSentLowWaterBytes = 32 * 1024
    cfg.wsMaxBackpressureBytes = 1024 * 1024
    cfg.wsIdleTimeoutSeconds = 120
    cfg.connectionTimeoutSeconds = 120
  else:
    discard

proc firstSetEnv(names: openArray[string]): string {.inline.} =
  for name in names:
    let raw = getEnv(name, "").strip()
    if raw.len > 0:
      return raw
  ""

proc parseEnvBool(name: string, defaultValue: bool): bool {.inline.} =
  let raw = getEnv(name, "").strip()
  if raw.len == 0:
    return defaultValue
  parseBoolValue(raw, defaultValue)

proc parseEnvIntBounded(
  name: string,
  defaultValue: int,
  minValue: int = low(int),
  maxValue: int = high(int)
): int {.inline.} =
  let raw = getEnv(name, "").strip()
  if raw.len == 0:
    return defaultValue
  parseIntBounded(raw, defaultValue, minValue, maxValue)

proc readObj(node: JsonNode, key: string): JsonNode {.inline.} =
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return nil
  let child = node[key]
  if child.kind == JObject: child else: nil

proc readString(node: JsonNode, key: string, defaultValue: string): string {.inline.} =
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return defaultValue
  let raw = node[key]
  case raw.kind
  of JString:
    raw.getStr()
  of JInt:
    $raw.getInt()
  of JFloat:
    $raw.getFloat()
  else:
    defaultValue

proc readInt(
  node: JsonNode,
  key: string,
  defaultValue: int,
  minValue: int = low(int),
  maxValue: int = high(int)
): int {.inline.} =
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return defaultValue
  let raw = node[key]
  case raw.kind
  of JInt:
    let parsed = raw.getInt()
    if parsed < minValue or parsed > maxValue:
      defaultValue
    else:
      parsed
  of JFloat:
    let parsed = int(raw.getFloat())
    if parsed < minValue or parsed > maxValue:
      defaultValue
    else:
      parsed
  of JString:
    parseIntBounded(raw.getStr(), defaultValue, minValue, maxValue)
  else:
    defaultValue

proc readBool(node: JsonNode, key: string, defaultValue: bool): bool {.inline.} =
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return defaultValue
  let raw = node[key]
  case raw.kind
  of JBool:
    raw.getBool()
  of JInt:
    raw.getInt() != 0
  of JString:
    parseBoolValue(raw.getStr(), defaultValue)
  else:
    defaultValue

proc applyJsonConfig(cfg: var AppEnvConfig, root: JsonNode) =
  if root == nil or root.kind != JObject:
    return

  let jsonProfile = readString(root, "profile", "")
  if jsonProfile.len > 0:
    cfg.applyProfilePreset(jsonProfile)

  let server = readObj(root, "server")
  cfg.host = readString(server, "host", cfg.host)
  cfg.port = readInt(server, "port", cfg.port, 1, 65535)
  cfg.trustProxy = readBool(server, "trustProxy", cfg.trustProxy)
  cfg.trustedProxyHops = readInt(server, "trustedProxyHops", cfg.trustedProxyHops, 0)
  cfg.trustedProxyAllowlist = readString(server, "trustedProxyAllowlist", cfg.trustedProxyAllowlist)
  cfg.maxBodySize = readInt(server, "maxBodySize", cfg.maxBodySize, 1)
  cfg.connectionTimeoutSeconds = readInt(server, "connectionTimeoutSeconds", cfg.connectionTimeoutSeconds, 0)
  cfg.maxConnections = readInt(server, "maxConnections", cfg.maxConnections, 1)
  cfg.maxPendingBytesPerSocket = readInt(server, "maxPendingBytesPerSocket", cfg.maxPendingBytesPerSocket, 0)
  cfg.minimalHeaderParsing = readBool(server, "minimalHeaderParsing", cfg.minimalHeaderParsing)
  cfg.gracefulShutdown = readBool(server, "gracefulShutdown", cfg.gracefulShutdown)
  cfg.macosHighQos = readBool(server, "macosHighQos", cfg.macosHighQos)
  cfg.tlsFlattenThreshold = readInt(server, "tlsFlattenThreshold", cfg.tlsFlattenThreshold, 0)

  let runtime = readObj(root, "runtime")
  cfg.asyncPumpIntervalMs = readInt(runtime, "asyncPumpIntervalMs", cfg.asyncPumpIntervalMs, 1, 60_000)
  cfg.maxInflightAsyncRequests = readInt(runtime, "maxInflightAsyncRequests", cfg.maxInflightAsyncRequests, 0)
  cfg.contextPoolPrewarm = readInt(runtime, "contextPoolPrewarm", cfg.contextPoolPrewarm, 0)
  cfg.requestResponsePoolingEnabled = readBool(
    runtime,
    "requestResponsePoolingEnabled",
    cfg.requestResponsePoolingEnabled
  )

  let socket = readObj(root, "socket")
  cfg.socketNoDelay = readBool(socket, "noDelay", cfg.socketNoDelay)
  cfg.socketKeepAlive = readBool(socket, "keepAlive", cfg.socketKeepAlive)
  cfg.socketKeepAliveSeconds = readInt(socket, "keepAliveSeconds", cfg.socketKeepAliveSeconds, 0)
  cfg.socketFastOpen = readBool(socket, "fastOpen", cfg.socketFastOpen)
  cfg.socketSendBufferBytes = readInt(socket, "sendBufferBytes", cfg.socketSendBufferBytes, 0)
  cfg.socketRecvBufferBytes = readInt(socket, "recvBufferBytes", cfg.socketRecvBufferBytes, 0)
  cfg.socketNotSentLowWaterBytes = readInt(socket, "notSentLowWaterBytes", cfg.socketNotSentLowWaterBytes, 0)
  cfg.socketDeferAcceptSeconds = readInt(socket, "deferAcceptSeconds", cfg.socketDeferAcceptSeconds, 0)
  cfg.socketIncomingCpu = readInt(socket, "incomingCpu", cfg.socketIncomingCpu, -1)
  cfg.listenExclusivePort = readBool(socket, "exclusivePort", cfg.listenExclusivePort)
  cfg.listenEpollExclusive = readBool(socket, "epollExclusive", cfg.listenEpollExclusive)
  cfg.listenEpollEdgeTrigger = readBool(socket, "epollEdgeTrigger", cfg.listenEpollEdgeTrigger)

  let coalesce = readObj(root, "coalesce")
  cfg.writeCoalesceMode = parseWriteCoalesceMode(readString(coalesce, "mode", ""), cfg.writeCoalesceMode)
  cfg.writeCoalesceMaxBytes = readInt(coalesce, "maxBytes", cfg.writeCoalesceMaxBytes, 0)
  cfg.writeCoalesceMaxResponses = readInt(coalesce, "maxResponses", cfg.writeCoalesceMaxResponses, 0)
  cfg.writeCoalesceThroughputMaxBytes = readInt(coalesce, "throughputMaxBytes", cfg.writeCoalesceThroughputMaxBytes, 0)
  cfg.writeCoalesceThroughputMaxResponses = readInt(coalesce, "throughputMaxResponses", cfg.writeCoalesceThroughputMaxResponses, 0)

  let budgets = readObj(root, "budgets")
  cfg.parseBudgetRequestsPerRead = readInt(budgets, "parseRequestsPerRead", cfg.parseBudgetRequestsPerRead, 1)
  cfg.parseBudgetBytesPerRead = readInt(budgets, "parseBytesPerRead", cfg.parseBudgetBytesPerRead, 1)
  cfg.loopDispatchBudgetRequests = readInt(budgets, "loopRequests", cfg.loopDispatchBudgetRequests, 1)
  cfg.loopDispatchBudgetBytes = readInt(budgets, "loopBytes", cfg.loopDispatchBudgetBytes, 1)
  cfg.writeBudgetIterationsPerFlush = readInt(budgets, "writeIterations", cfg.writeBudgetIterationsPerFlush, 1)
  cfg.writeBudgetBytesPerFlush = readInt(budgets, "writeBytes", cfg.writeBudgetBytesPerFlush, 1)
  cfg.loopWriteBudgetBytes = readInt(budgets, "loopWriteBytes", cfg.loopWriteBudgetBytes, 1)

  let overload = readObj(root, "overload")
  cfg.overloadMaxLoopBacklogBytes = readInt(overload, "maxBacklogBytes", cfg.overloadMaxLoopBacklogBytes, 0)
  cfg.overloadMaxPendingResponses = readInt(overload, "maxPendingResponses", cfg.overloadMaxPendingResponses, 0)
  cfg.overloadCloseOnReject = readBool(overload, "closeOnReject", cfg.overloadCloseOnReject)
  let adaptive = readObj(overload, "adaptive")
  cfg.overloadAdaptiveEnabled = readBool(adaptive, "enabled", cfg.overloadAdaptiveEnabled)
  cfg.overloadAdaptiveMinBacklogBytes = readInt(adaptive, "minBacklogBytes", cfg.overloadAdaptiveMinBacklogBytes, 0)
  cfg.overloadAdaptiveMaxBacklogBytes = readInt(adaptive, "maxBacklogBytes", cfg.overloadAdaptiveMaxBacklogBytes, 0)
  cfg.overloadAdaptiveMinPendingResponses = readInt(adaptive, "minPendingResponses", cfg.overloadAdaptiveMinPendingResponses, 0)
  cfg.overloadAdaptiveMaxPendingResponses = readInt(adaptive, "maxPendingResponses", cfg.overloadAdaptiveMaxPendingResponses, 0)
  cfg.overloadAdaptiveTightenStepPercent = readInt(adaptive, "tightenStepPercent", cfg.overloadAdaptiveTightenStepPercent, 1, 100)
  cfg.overloadAdaptiveRelaxStepPercent = readInt(adaptive, "relaxStepPercent", cfg.overloadAdaptiveRelaxStepPercent, 1, 100)
  cfg.overloadAdaptiveCooldownRequests = readInt(adaptive, "cooldownRequests", cfg.overloadAdaptiveCooldownRequests, 1)

  let websocket = readObj(root, "websocket")
  cfg.wsKeepaliveIntervalMs = readInt(websocket, "keepaliveIntervalMs", cfg.wsKeepaliveIntervalMs, 0)
  cfg.wsIdleTimeoutSeconds = readInt(websocket, "idleTimeoutSeconds", cfg.wsIdleTimeoutSeconds, 0)
  cfg.wsMaxBackpressureBytes = readInt(websocket, "maxBackpressureBytes", cfg.wsMaxBackpressureBytes, 0)
  cfg.wsBackpressureHighWaterBytes = readInt(websocket, "backpressureHighWaterBytes", cfg.wsBackpressureHighWaterBytes, 0)
  cfg.wsBackpressureHighWaterAction = parseWsBackpressureAction(
    readString(websocket, "backpressureHighWaterAction", ""),
    cfg.wsBackpressureHighWaterAction
  )
  cfg.wsDynamicBackpressureEnabled = readBool(websocket, "dynamicBackpressureEnabled", cfg.wsDynamicBackpressureEnabled)
  cfg.wsExpectedConnections = readInt(websocket, "expectedConnections", cfg.wsExpectedConnections, 0)
  cfg.wsMessageBytes = readInt(websocket, "messageBytes", cfg.wsMessageBytes, 0)
  cfg.wsQueueBudgetBytes = readInt(websocket, "queueBudgetBytes", cfg.wsQueueBudgetBytes, 0)
  cfg.wsCloseOnBackpressureLimit = readBool(websocket, "closeOnBackpressureLimit", cfg.wsCloseOnBackpressureLimit)
  cfg.wsResetIdleTimeoutOnSend = readBool(websocket, "resetIdleTimeoutOnSend", cfg.wsResetIdleTimeoutOnSend)
  cfg.wsWriteCoalesceMaxBytes = readInt(websocket, "writeCoalesceMaxBytes", cfg.wsWriteCoalesceMaxBytes, 0)
  cfg.wsWriteCoalesceMaxFrames = readInt(websocket, "writeCoalesceMaxFrames", cfg.wsWriteCoalesceMaxFrames, 0)
  cfg.wsSocketRecvBufferBytes = readInt(websocket, "socketRecvBufferBytes", cfg.wsSocketRecvBufferBytes, 0)
  cfg.wsSocketSendBufferBytes = readInt(websocket, "socketSendBufferBytes", cfg.wsSocketSendBufferBytes, 0)
  cfg.wsSocketNotSentLowWaterBytes = readInt(websocket, "socketNotSentLowWaterBytes", cfg.wsSocketNotSentLowWaterBytes, 0)
  let wsCompression = readObj(websocket, "compression")
  cfg.wsCompressionEnabled = readBool(wsCompression, "enabled", cfg.wsCompressionEnabled)
  cfg.wsCompressionThresholdBytes = readInt(wsCompression, "thresholdBytes", cfg.wsCompressionThresholdBytes, 0)
  cfg.wsCompressionMinSavingsBytes = readInt(wsCompression, "minSavingsBytes", cfg.wsCompressionMinSavingsBytes, 0)
  cfg.wsCompressionDisableForBinary = readBool(wsCompression, "disableForBinary", cfg.wsCompressionDisableForBinary)
  cfg.wsCompressionDisableForText = readBool(wsCompression, "disableForText", cfg.wsCompressionDisableForText)
  cfg.wsCompressionBackpressureBypassBytes = readInt(wsCompression, "backpressureBypassBytes", cfg.wsCompressionBackpressureBypassBytes, 0)

  let body = readObj(root, "body")
  cfg.bodySpillThresholdBytes = readInt(body, "spillThresholdBytes", cfg.bodySpillThresholdBytes, 0)
  cfg.bodySpillDir = readString(body, "spillDir", cfg.bodySpillDir)

proc applyEnvOverrides(cfg: var AppEnvConfig) =
  let profile = getEnv("NIM_EXPRESS_PROFILE", "").strip()
  if profile.len > 0:
    cfg.applyProfilePreset(profile)

  let hostRaw = firstSetEnv(["NIM_EXPRESS_HOST", "HOST"])
  if hostRaw.len > 0:
    cfg.host = hostRaw

  let portRaw = firstSetEnv(["NIM_EXPRESS_PORT", "PORT"])
  if portRaw.len > 0:
    cfg.port = parseIntBounded(portRaw, cfg.port, 1, 65535)

  cfg.trustProxy = parseEnvBool("NIM_EXPRESS_TRUST_PROXY", cfg.trustProxy)
  cfg.trustedProxyHops = parseEnvIntBounded("NIM_EXPRESS_TRUST_PROXY_HOPS", cfg.trustedProxyHops, 0)
  let trustedProxyAllowlistRaw = getEnv("NIM_EXPRESS_TRUST_PROXY_ALLOWLIST", "").strip()
  if trustedProxyAllowlistRaw.len > 0:
    cfg.trustedProxyAllowlist = trustedProxyAllowlistRaw
  cfg.asyncPumpIntervalMs = parseEnvIntBounded("NIM_EXPRESS_ASYNC_PUMP_INTERVAL_MS", cfg.asyncPumpIntervalMs, 1, 60_000)
  cfg.maxInflightAsyncRequests = parseEnvIntBounded("NIM_EXPRESS_MAX_INFLIGHT_ASYNC_REQUESTS", cfg.maxInflightAsyncRequests, 0)
  cfg.contextPoolPrewarm = parseEnvIntBounded("NIM_EXPRESS_CONTEXT_POOL_PREWARM", cfg.contextPoolPrewarm, 0)
  cfg.requestResponsePoolingEnabled = parseEnvBool(
    "NIM_EXPRESS_REQUEST_RESPONSE_POOLING",
    cfg.requestResponsePoolingEnabled
  )
  cfg.maxPendingBytesPerSocket = parseEnvIntBounded("NIM_EXPRESS_MAX_PENDING_BYTES_PER_SOCKET", cfg.maxPendingBytesPerSocket, 0)
  cfg.maxBodySize = parseEnvIntBounded("NIM_EXPRESS_MAX_BODY_SIZE", cfg.maxBodySize, 1)
  cfg.connectionTimeoutSeconds = parseEnvIntBounded("NIM_EXPRESS_CONNECTION_TIMEOUT_SEC", cfg.connectionTimeoutSeconds, 0)
  cfg.maxConnections = parseEnvIntBounded("NIM_EXPRESS_MAX_CONNECTIONS", cfg.maxConnections, 1)
  cfg.minimalHeaderParsing = parseEnvBool("NIM_EXPRESS_MINIMAL_HEADER_PARSING", cfg.minimalHeaderParsing)
  cfg.gracefulShutdown = parseEnvBool("NIM_EXPRESS_GRACEFUL_SHUTDOWN", cfg.gracefulShutdown)
  cfg.macosHighQos = parseEnvBool("NIM_EXPRESS_MACOS_HIGH_QOS", cfg.macosHighQos)
  cfg.tlsFlattenThreshold = parseEnvIntBounded("NIM_EXPRESS_TLS_FLATTEN_THRESHOLD", cfg.tlsFlattenThreshold, 0)

  cfg.socketNoDelay = parseEnvBool("NIM_EXPRESS_SOCKET_NODELAY", cfg.socketNoDelay)
  cfg.socketKeepAlive = parseEnvBool("NIM_EXPRESS_SOCKET_KEEPALIVE", cfg.socketKeepAlive)
  cfg.socketKeepAliveSeconds = parseEnvIntBounded("NIM_EXPRESS_SOCKET_KEEPALIVE_SEC", cfg.socketKeepAliveSeconds, 0)
  cfg.socketFastOpen = parseEnvBool("NIM_EXPRESS_SOCKET_FASTOPEN", cfg.socketFastOpen)
  cfg.socketSendBufferBytes = parseEnvIntBounded("NIM_EXPRESS_SOCKET_SNDBUF", cfg.socketSendBufferBytes, 0)
  cfg.socketRecvBufferBytes = parseEnvIntBounded("NIM_EXPRESS_SOCKET_RCVBUF", cfg.socketRecvBufferBytes, 0)
  cfg.socketNotSentLowWaterBytes = parseEnvIntBounded("NIM_EXPRESS_SOCKET_NOTSENT_LOWAT", cfg.socketNotSentLowWaterBytes, 0)
  cfg.socketDeferAcceptSeconds = parseEnvIntBounded("NIM_EXPRESS_SOCKET_DEFER_ACCEPT_SEC", cfg.socketDeferAcceptSeconds, 0)
  cfg.socketIncomingCpu = parseEnvIntBounded("NIM_EXPRESS_SOCKET_INCOMING_CPU", cfg.socketIncomingCpu, -1)
  cfg.listenExclusivePort = parseEnvBool("NIM_EXPRESS_LISTEN_EXCLUSIVE_PORT", cfg.listenExclusivePort)
  cfg.listenEpollExclusive = parseEnvBool("NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE", cfg.listenEpollExclusive)
  cfg.listenEpollEdgeTrigger = parseEnvBool("NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER", cfg.listenEpollEdgeTrigger)

  cfg.writeCoalesceMode = parseWriteCoalesceMode(getEnv("NIM_EXPRESS_WRITE_COALESCE_MODE", ""), cfg.writeCoalesceMode)
  cfg.writeCoalesceMaxBytes = parseEnvIntBounded("NIM_EXPRESS_WRITE_COALESCE_MAX_BYTES", cfg.writeCoalesceMaxBytes, 0)
  cfg.writeCoalesceMaxResponses = parseEnvIntBounded("NIM_EXPRESS_WRITE_COALESCE_MAX_RESPONSES", cfg.writeCoalesceMaxResponses, 0)
  cfg.writeCoalesceThroughputMaxBytes = parseEnvIntBounded("NIM_EXPRESS_WRITE_COALESCE_TP_MAX_BYTES", cfg.writeCoalesceThroughputMaxBytes, 0)
  cfg.writeCoalesceThroughputMaxResponses = parseEnvIntBounded("NIM_EXPRESS_WRITE_COALESCE_TP_MAX_RESPONSES", cfg.writeCoalesceThroughputMaxResponses, 0)

  cfg.parseBudgetRequestsPerRead = parseEnvIntBounded("NIM_EXPRESS_PARSE_BUDGET_REQUESTS", cfg.parseBudgetRequestsPerRead, 1)
  cfg.parseBudgetBytesPerRead = parseEnvIntBounded("NIM_EXPRESS_PARSE_BUDGET_BYTES", cfg.parseBudgetBytesPerRead, 1)
  cfg.loopDispatchBudgetRequests = parseEnvIntBounded("NIM_EXPRESS_LOOP_DISPATCH_REQUESTS", cfg.loopDispatchBudgetRequests, 1)
  cfg.loopDispatchBudgetBytes = parseEnvIntBounded("NIM_EXPRESS_LOOP_DISPATCH_BYTES", cfg.loopDispatchBudgetBytes, 1)
  cfg.writeBudgetIterationsPerFlush = parseEnvIntBounded("NIM_EXPRESS_WRITE_BUDGET_ITERATIONS", cfg.writeBudgetIterationsPerFlush, 1)
  cfg.writeBudgetBytesPerFlush = parseEnvIntBounded("NIM_EXPRESS_WRITE_BUDGET_BYTES", cfg.writeBudgetBytesPerFlush, 1)
  cfg.loopWriteBudgetBytes = parseEnvIntBounded("NIM_EXPRESS_LOOP_WRITE_BUDGET_BYTES", cfg.loopWriteBudgetBytes, 1)

  cfg.overloadMaxLoopBacklogBytes = parseEnvIntBounded("NIM_EXPRESS_OVERLOAD_MAX_BACKLOG_BYTES", cfg.overloadMaxLoopBacklogBytes, 0)
  cfg.overloadMaxPendingResponses = parseEnvIntBounded("NIM_EXPRESS_OVERLOAD_MAX_PENDING_RESPONSES", cfg.overloadMaxPendingResponses, 0)
  cfg.overloadCloseOnReject = parseEnvBool("NIM_EXPRESS_OVERLOAD_CLOSE_ON_REJECT", cfg.overloadCloseOnReject)
  cfg.overloadAdaptiveEnabled = parseEnvBool("NIM_EXPRESS_OVERLOAD_ADAPTIVE", cfg.overloadAdaptiveEnabled)
  cfg.overloadAdaptiveMinBacklogBytes = parseEnvIntBounded("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MIN_BACKLOG_BYTES", cfg.overloadAdaptiveMinBacklogBytes, 0)
  cfg.overloadAdaptiveMaxBacklogBytes = parseEnvIntBounded("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MAX_BACKLOG_BYTES", cfg.overloadAdaptiveMaxBacklogBytes, 0)
  cfg.overloadAdaptiveMinPendingResponses = parseEnvIntBounded("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MIN_PENDING_RESPONSES", cfg.overloadAdaptiveMinPendingResponses, 0)
  cfg.overloadAdaptiveMaxPendingResponses = parseEnvIntBounded("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MAX_PENDING_RESPONSES", cfg.overloadAdaptiveMaxPendingResponses, 0)
  cfg.overloadAdaptiveTightenStepPercent = parseEnvIntBounded("NIM_EXPRESS_OVERLOAD_ADAPTIVE_TIGHTEN_PERCENT", cfg.overloadAdaptiveTightenStepPercent, 1, 100)
  cfg.overloadAdaptiveRelaxStepPercent = parseEnvIntBounded("NIM_EXPRESS_OVERLOAD_ADAPTIVE_RELAX_PERCENT", cfg.overloadAdaptiveRelaxStepPercent, 1, 100)
  cfg.overloadAdaptiveCooldownRequests = parseEnvIntBounded("NIM_EXPRESS_OVERLOAD_ADAPTIVE_COOLDOWN_REQUESTS", cfg.overloadAdaptiveCooldownRequests, 1)

  cfg.wsKeepaliveIntervalMs = parseEnvIntBounded("NIM_EXPRESS_WS_KEEPALIVE_INTERVAL_MS", cfg.wsKeepaliveIntervalMs, 0)
  cfg.wsIdleTimeoutSeconds = parseEnvIntBounded("NIM_EXPRESS_WS_IDLE_TIMEOUT_SEC", cfg.wsIdleTimeoutSeconds, 0)
  cfg.wsMaxBackpressureBytes = parseEnvIntBounded("NIM_EXPRESS_WS_MAX_BACKPRESSURE_BYTES", cfg.wsMaxBackpressureBytes, 0)
  cfg.wsBackpressureHighWaterBytes = parseEnvIntBounded("NIM_EXPRESS_WS_BACKPRESSURE_HIGH_WATER_BYTES", cfg.wsBackpressureHighWaterBytes, 0)
  cfg.wsBackpressureHighWaterAction = parseWsBackpressureAction(
    getEnv("NIM_EXPRESS_WS_BACKPRESSURE_HIGH_WATER_ACTION", ""),
    cfg.wsBackpressureHighWaterAction
  )
  cfg.wsDynamicBackpressureEnabled = parseEnvBool("NIM_EXPRESS_WS_DYNAMIC_BACKPRESSURE", cfg.wsDynamicBackpressureEnabled)
  cfg.wsExpectedConnections = parseEnvIntBounded("NIM_EXPRESS_WS_EXPECTED_CONNECTIONS", cfg.wsExpectedConnections, 0)
  cfg.wsMessageBytes = parseEnvIntBounded("NIM_EXPRESS_WS_MESSAGE_BYTES", cfg.wsMessageBytes, 0)
  cfg.wsQueueBudgetBytes = parseEnvIntBounded("NIM_EXPRESS_WS_QUEUE_BUDGET_BYTES", cfg.wsQueueBudgetBytes, 0)
  let wsQueueBudgetMb = getEnv("NIM_EXPRESS_WS_QUEUE_BUDGET_MB", "").strip()
  if wsQueueBudgetMb.len > 0:
    let mb = parseIntBounded(wsQueueBudgetMb, -1, 0, int.high div (1024 * 1024))
    if mb >= 0:
      cfg.wsQueueBudgetBytes = mb * 1024 * 1024
  cfg.wsCloseOnBackpressureLimit = parseEnvBool("NIM_EXPRESS_WS_CLOSE_ON_BACKPRESSURE_LIMIT", cfg.wsCloseOnBackpressureLimit)
  cfg.wsResetIdleTimeoutOnSend = parseEnvBool("NIM_EXPRESS_WS_RESET_IDLE_TIMEOUT_ON_SEND", cfg.wsResetIdleTimeoutOnSend)
  cfg.wsCompressionEnabled = parseEnvBool("NIM_EXPRESS_WS_COMPRESSION_ENABLED", cfg.wsCompressionEnabled)
  cfg.wsCompressionThresholdBytes = parseEnvIntBounded("NIM_EXPRESS_WS_COMPRESSION_THRESHOLD_BYTES", cfg.wsCompressionThresholdBytes, 0)
  cfg.wsCompressionMinSavingsBytes = parseEnvIntBounded("NIM_EXPRESS_WS_COMPRESSION_MIN_SAVINGS_BYTES", cfg.wsCompressionMinSavingsBytes, 0)
  cfg.wsCompressionDisableForBinary = parseEnvBool("NIM_EXPRESS_WS_COMPRESSION_DISABLE_FOR_BINARY", cfg.wsCompressionDisableForBinary)
  cfg.wsCompressionDisableForText = parseEnvBool("NIM_EXPRESS_WS_COMPRESSION_DISABLE_FOR_TEXT", cfg.wsCompressionDisableForText)
  cfg.wsCompressionBackpressureBypassBytes = parseEnvIntBounded("NIM_EXPRESS_WS_COMPRESSION_BACKPRESSURE_BYPASS_BYTES", cfg.wsCompressionBackpressureBypassBytes, 0)
  cfg.wsWriteCoalesceMaxBytes = parseEnvIntBounded("NIM_EXPRESS_WS_WRITE_COALESCE_MAX_BYTES", cfg.wsWriteCoalesceMaxBytes, 0)
  cfg.wsWriteCoalesceMaxFrames = parseEnvIntBounded("NIM_EXPRESS_WS_WRITE_COALESCE_MAX_FRAMES", cfg.wsWriteCoalesceMaxFrames, 0)
  cfg.wsSocketRecvBufferBytes = parseEnvIntBounded("NIM_EXPRESS_WS_RECV_BUFFER", cfg.wsSocketRecvBufferBytes, 0)
  cfg.wsSocketSendBufferBytes = parseEnvIntBounded("NIM_EXPRESS_WS_SEND_BUFFER", cfg.wsSocketSendBufferBytes, 0)
  cfg.wsSocketNotSentLowWaterBytes = parseEnvIntBounded("NIM_EXPRESS_WS_NOTSENT_LOWWATER", cfg.wsSocketNotSentLowWaterBytes, 0)

  cfg.bodySpillThresholdBytes = parseEnvIntBounded("NIM_EXPRESS_BODY_SPILL_THRESHOLD_BYTES", cfg.bodySpillThresholdBytes, 0)
  let spillDirRaw = getEnv("NIM_EXPRESS_BODY_SPILL_DIR", "").strip()
  if spillDirRaw.len > 0:
    cfg.bodySpillDir = spillDirRaw

proc resolvedConfigPath(configPath: string): string =
  let explicitPath = configPath.strip()
  if explicitPath.len > 0:
    return explicitPath
  let envPath = getEnv("NIM_EXPRESS_CONFIG", "").strip()
  if envPath.len > 0:
    return envPath
  if fileExists(DefaultConfigFileName):
    return DefaultConfigFileName
  if fileExists(FallbackConfigFileName):
    return FallbackConfigFileName
  ""

## Loads an AppEnvConfig from the defaults, the resolved JSON file, and NIM_EXPRESS env overrides.
proc loadAppEnvConfig*(configPath: string = "", strictConfig: bool = false): AppEnvConfig =
  result = defaultAppEnvConfig()
  result.strictConfig = strictConfig or parseEnvBool("NIM_EXPRESS_STRICT_CONFIG", false)

  let path = resolvedConfigPath(configPath)
  if path.len > 0 and fileExists(path):
    try:
      result.applyJsonConfig(parseFile(path))
    except CatchableError as e:
      let warning = "WARNING: Failed to parse config file '" & path & "': " & e.msg & ". Using defaults."
      result.configWarnings.add(warning)
      stderr.writeLine(warning)
      if result.strictConfig:
        raise newException(IOError, "Config parse failed in strict mode: " & e.msg)

  result.applyEnvOverrides()
  if result.trustProxy and result.trustedProxyHops <= 0 and result.trustedProxyAllowlist.len == 0:
    result.configWarnings.add(
      "trustProxy is enabled without trustedProxyHops or trustedProxyAllowlist; forwarded headers will be ignored"
    )

## Loads the resolved AppEnvConfig, applies it to the app, and returns the config.
proc loadAndApplyAppEnvConfig*(app: ExpressApp, configPath: string = "", strictConfig: bool = false): AppEnvConfig =
  ## Convenience: load config (defaults + json + env) and apply to app instance.
  result = loadAppEnvConfig(configPath, strictConfig)
  app.applyAppEnvConfig(result)
