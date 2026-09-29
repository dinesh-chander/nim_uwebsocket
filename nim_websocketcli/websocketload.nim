## websocketload - WebSocket load testing (multi event-loop, uSockets + nim_fasthttpclient)
##
## Knobs are explicit: connections, duration, payload length (static or random in a range),
## optional open burst, reply-on-recv, and per-connection outbound rate from a timer.

import std/[strutils, times, monotimes, os, atomics, random, syncio]
when not (defined(macosx) and defined(LIBUS_USE_GCD)):
  import std/cpuinfo
import nim_fasthttpclient/client
import nim_fasthttpclient/types
import nim_usockets/usockets

const
  DefaultHost* = "127.0.0.1"
  DefaultPort* = 3400
  DefaultPath* = "/"
  DefaultClients* = 100
  DefaultDuration* = 10
  DefaultDrainSec* = 0
  DefaultMsgLen* = 64
  DefaultThreads* = 0
  DefaultOpenMessages* = 1
  DefaultTickMs* = 10
  ## Issue connects on the loop timer instead of blocking thousands before ``runWsClientLoop``
  ## (raw bursts corrupt internal uSockets state on Linux epoll builds).
  ConnectBatchSize = 256
  ## Nim/uSockets empirically becomes unstable beyond ~24 concurrent worker loops per process on Linux.
  MaxWorkerThreads = 24
  ## Hard cap per worker thread (batched connects still amortize work; push cautiously).
  MaxConnectionsPerWorkerThread = 30000

type
  PayloadLenMode* = enum
    plmStatic = "static"
    plmDynamic = "dynamic"

  PayloadKind* = enum
    pkAlpha = "alpha"
    pkRealtime = "realtime"

  WsClientConfig* = object
    host*: string
    port*: int
    path*: string
    concurrency*: int
    duration*: int
    drainSec*: int
    threads*: int
    lenMode*: PayloadLenMode
    msgLen*: int
    minLen*: int
    maxLen*: int
    payloadKind*: PayloadKind
    openMessages*: int
    replyOnRecv*: bool
    outMps*: float64
    opcode*: WsOpcode
    tickMs*: int
    ## Optional outbound bind IPs (round-robin) to scale past ~28k conns to one dst IP:port.
    bindHosts*: seq[string]
    ## Spread bootstrap ``connect()`` issuance per worker over this many seconds (0 = minimal delay).
    rampSec*: int
    ## After a retryable connect failure, retry up to this many times (each spaced by ``retryDelayMs``).
    connectRetries*: int
    connectRetryDelayMs*: int

  AtomicStats* = object
    openedSlots*: Atomic[int64]
    connected*: Atomic[int64]
    disconnected*: Atomic[int64]
    sent*: Atomic[int64]
    recv*: Atomic[int64]
    errors*: Atomic[int64]
    connectErrors*: Atomic[int64]

  LocalStats* = object
    openedSlots*: int64
    connected*: int64
    disconnected*: int64
    sent*: int64
    recv*: int64
    errors*: int64
    connectErrors*: int64

  WorkerContext* = object
    wsClient*: HttpClient
    clientStates*: seq[WsConnection]
    localStats*: LocalStats
    globalStats*: ptr AtomicStats
    lenMode*: PayloadLenMode
    minLen*: int
    maxLen*: int
    payloadKind*: PayloadKind
    staticPayload*: string
    rng*: Rand
    openMessages*: int
    replyOnRecv*: bool
    outMps*: float64
    rateCredit*: float64
    opcode*: WsOpcode
    tickMs*: int
    connectedCount*: int
    done*: bool
    draining*: bool
    sendingStarted*: bool
    bootstrapIx*: int
    bootstrapTimer*: UsTimerPtr
    bootstrapUrl*: string
    durationSec*: int
    drainSec*: int
    flushTimer*: UsTimerPtr
    rateTimer*: UsTimerPtr
    retrySweepTimer*: UsTimerPtr
    pendingRetries*: seq[tuple[ix: int, dueEpoch: float64]]
    retryQueued*: seq[bool]
    openedOnce*: seq[bool]
    closedOnce*: seq[bool]
    sendSeq*: seq[uint64]
    payloadScratch*: seq[string]
    seqFieldOffset*: seq[int]
    openSlots*: seq[int]
    openSlotPos*: seq[int]
    connectAttemptsIssued*: seq[int]
    retryDelayMs*: int
    maxConnectAttempts*: int
    bindHosts*: seq[string]
    bindHostBaseOffset*: int

  WorkerArgs* = object
    workerId*: int
    host*: string
    port*: int
    path*: string
    lenMode*: PayloadLenMode
    msgLen*: int
    minLen*: int
    maxLen*: int
    payloadKind*: PayloadKind
    staticPayload*: string
    openMessages*: int
    replyOnRecv*: bool
    outMps*: float64
    opcode*: WsOpcode
    tickMs*: int
    connectionsPerThread*: int
    duration*: int
    drainSec*: int
    globalStats*: ptr AtomicStats
    bindHosts*: seq[string]
    bindHostBaseOffset*: int
    rampSec*: int
    connectRetries*: int
    connectRetryDelayMs*: int

proc loopbackBindIps*(n: int): seq[string] =
  ## ``127.0.0.2`` … ``127.0.0.(n+1)`` — use with ``sudo nim_websocketcli/scripts/ws_scale_linux.sh``.
  let n2 = min(max(n, 0), 253)
  if n2 <= 0:
    return @[]
  result = newSeq[string](n2)
  for i in 0 ..< n2:
    result[i] = "127.0.0." & $(i + 2)

proc generateTestPayload*(size: int): string =
  result = newString(size)
  for i in 0..<size:
    result[i] = chr(65 + (i mod 26))

proc appendPaddedUint(dst: var string, value: uint64, width: int) {.inline.} =
  var digits: array[20, char]
  var n = value
  var pos = digits.len
  while true:
    dec pos
    digits[pos] = chr(ord('0') + int(n mod 10))
    n = n div 10
    if n == 0:
      break
  let digitCount = digits.len - pos
  var pad = width - digitCount
  while pad > 0:
    dst.add('0')
    dec pad
  for i in pos..<digits.len:
    dst.add(digits[i])

proc overwritePaddedUint(dst: var string, offset: int, value: uint64, width: int) {.inline.} =
  if offset < 0 or offset + width > dst.len:
    return
  var n = value
  var i = offset + width - 1
  while i >= offset:
    dst[i] = chr(ord('0') + int(n mod 10))
    n = n div 10
    dec i

proc generateRealtimePayload*(size, workerId, slotIx: int, seq: uint64, seqWidth: int = 0): string =
  ## JSON-shaped application event with deterministic padding. This gives the
  ## server realistic field extraction and state-update work while preserving a
  ## stable wire size for throughput comparisons.
  let room = slotIx and 255
  let x = (slotIx * 17 + int(seq mod 1009'u64)) mod 4096
  let y = (slotIx * 31 + int(seq mod 997'u64)) mod 4096
  let prefix =
    "{\"type\":\"cursor\",\"room\":" & $room &
    ",\"client\":" & $((workerId * 1_000_000) + slotIx) &
    ",\"seq\":"
  var mid = newStringOfCap(64)
  if seqWidth > 0:
    mid.appendPaddedUint(seq, seqWidth)
  else:
    mid.add($seq)
  mid.add(
    ",\"x\":" & $x &
    ",\"y\":" & $y &
    ",\"body\":\""
  )
  const suffix = "\"}"
  if size <= prefix.len + mid.len + suffix.len:
    return prefix & mid & suffix

  result = newStringOfCap(size)
  result.add(prefix)
  result.add(mid)
  let fillLen = size - prefix.len - mid.len - suffix.len
  for i in 0..<fillLen:
    result.add(chr(65 + ((i + slotIx + int(seq and 31'u64)) mod 26)))
  result.add(suffix)

proc seqOffsetInRealtimePayload*(payload: string): int {.inline.} =
  let marker = "\"seq\":"
  let p = payload.find(marker)
  if p < 0:
    -1
  else:
    p + marker.len

proc formatNum*(n: int64): string =
  let s = $n
  if s.len <= 3: return s
  result = newStringOfCap(s.len + s.len div 3)
  let offset = s.len mod 3
  for i, c in s:
    if i > 0 and (i - offset) mod 3 == 0:
      result.add ','
    result.add c

proc formatRps*(count: int64, duration: float): string =
  if duration <= 0.0: return "0"
  formatFloat(float(count) / duration, ffDecimal, 0)

proc parseLenMode*(s: string): PayloadLenMode =
  case s.toLowerAscii().strip()
  of "dynamic", "rand", "random":
    plmDynamic
  else:
    plmStatic

proc parseOpcode*(s: string): WsOpcode =
  case s.toLowerAscii().strip()
  of "binary", "bin":
    woBinary
  of "text", "txt", "":
    woText
  else:
    quit "--opcode must be text or binary"

proc parsePayloadKind*(s: string): PayloadKind =
  case s.toLowerAscii().strip()
  of "realtime", "realistic", "json", "app":
    pkRealtime
  of "alpha", "fill", "static", "":
    pkAlpha
  else:
    quit "--payload must be alpha or realtime"

proc parseBool*(s: string): bool =
  case s.toLowerAscii().strip()
  of "1", "true", "yes", "on":
    true
  of "0", "false", "no", "off":
    false
  else:
    true

proc parseCommandLine*(): WsClientConfig =
  result.host = DefaultHost
  result.port = DefaultPort
  result.path = DefaultPath
  result.concurrency = DefaultClients
  result.duration = DefaultDuration
  result.drainSec = DefaultDrainSec
  result.threads = DefaultThreads
  result.lenMode = plmStatic
  result.msgLen = DefaultMsgLen
  result.minLen = DefaultMsgLen
  result.maxLen = DefaultMsgLen
  result.payloadKind = pkAlpha
  result.openMessages = DefaultOpenMessages
  result.replyOnRecv = true
  result.outMps = 0.0
  result.opcode = woText
  result.tickMs = DefaultTickMs
  result.bindHosts = @[]
  result.rampSec = 20
  result.connectRetries = 15
  result.connectRetryDelayMs = 1000

  var bindLoopbacks = 0
  var bindIpsCsv = ""

  var i = 1
  while i <= paramCount():
    var arg = paramStr(i)
    var val = ""

    let eq = arg.find('=')
    if eq > 0:
      val = arg[eq + 1 .. ^1]
      arg = arg[0 ..< eq]

    template nv(): string =
      if val.len > 0:
        let v = val
        val = ""
        v
      elif i < paramCount():
        inc i
        paramStr(i)
      else:
        ""

    case arg
    of "-h", "--host":
      let v = nv()
      if v.len > 0: result.host = v
    of "-p", "--port":
      let v = nv()
      if v.len > 0: result.port = parseInt(v)
    of "--path":
      let v = nv()
      if v.len > 0: result.path = v
    of "-c", "--concurrency", "--clients":
      let v = nv()
      if v.len > 0: result.concurrency = parseInt(v)
    of "-d", "--duration":
      let v = nv()
      if v.len > 0: result.duration = parseInt(v)
    of "--drain-sec":
      let v = nv()
      if v.len > 0: result.drainSec = parseInt(v)
    of "-s", "--size", "--msg-len", "--length":
      let v = nv()
      if v.len > 0:
        let n = parseInt(v)
        result.msgLen = n
        result.minLen = n
        result.maxLen = n
    of "--len", "--len-mode":
      let v = nv()
      if v.len > 0: result.lenMode = parseLenMode(v)
    of "--min-len":
      let v = nv()
      if v.len > 0: result.minLen = parseInt(v)
    of "--max-len":
      let v = nv()
      if v.len > 0: result.maxLen = parseInt(v)
    of "--payload", "--payload-kind", "--payload-mode":
      let v = nv()
      result.payloadKind = parsePayloadKind(v)
    of "--open-msgs", "--open-messages":
      let v = nv()
      if v.len > 0: result.openMessages = parseInt(v)
    of "--reply-on-recv":
      let v = nv()
      if v.len > 0:
        result.replyOnRecv = parseBool(v)
      else:
        result.replyOnRecv = true
    of "--no-reply-on-recv":
      result.replyOnRecv = false
    of "--out-mps", "--mps":
      let v = nv()
      if v.len > 0: result.outMps = parseFloat(v)
    of "--opcode":
      let v = nv()
      result.opcode = parseOpcode(v)
    of "--tick-ms":
      let v = nv()
      if v.len > 0: result.tickMs = parseInt(v)
    of "--ramp-sec":
      let v = nv()
      if v.len > 0: result.rampSec = parseInt(v)
    of "--connect-retries":
      let v = nv()
      if v.len > 0: result.connectRetries = parseInt(v)
    of "--retry-delay-ms":
      let v = nv()
      if v.len > 0: result.connectRetryDelayMs = parseInt(v)
    of "-t", "--threads":
      let v = nv()
      if v.len > 0: result.threads = parseInt(v)
    of "--bind-loopbacks":
      let v = nv()
      if v.len > 0: bindLoopbacks = parseInt(v)
    of "--bind-ips":
      let v = nv()
      if v.len > 0: bindIpsCsv = v
    of "--help", "-help":
      echo "websocketload - WebSocket load tester"
      echo ""
      echo "Connection & runtime"
      echo "  -h, --host HOST       Target (default 127.0.0.1)"
      echo "  -p, --port PORT       Port (default 3400)"
      echo "  --path PATH           WS path (default /)"
      echo "  -c, --concurrency N   Total WebSocket clients (default 100)"
      echo "  -d, --duration SECS   Run time (default 10)"
      echo "  --drain-sec SECS      Stop sending, keep sockets open, then close (default 0)"
      echo "  -t, --threads N       Worker threads (0 = CPU count; capped at ", MaxWorkerThreads, ")"
      echo ""
      echo "Payload"
      echo "  -s, --size N          Message length; sets min/max in static mode (default 64)"
      echo "  --len static|dynamic  Static length vs random per send (default static)"
      echo "  --min-len N           Min bytes when --len dynamic"
      echo "  --max-len N           Max bytes when --len dynamic"
      echo "  --payload alpha|realtime"
      echo "                         alpha filler or JSON-shaped app events (default alpha)"
      echo ""
      echo "Traffic"
      echo "  --open-msgs N         Text frames sent right after handshake (default 1; 0 = none)"
      echo "  --reply-on-recv 0|1   After each data frame from server, send one frame (default 1)"
      echo "  --no-reply-on-recv    Same as --reply-on-recv 0"
      echo "  --out-mps R           Per-connection outbound msg/s from timer (0 = off; default 0)"
      echo "  --opcode text|binary  Outbound application frame opcode (default text)"
      echo "  --tick-ms MS          Timer step for --out-mps (default 10)"
      echo ""
      echo "Ramp & reconnect"
      echo "  --ramp-sec SEC        Spread bootstrap connects per worker over SEC seconds (default 20; 0 = fastest)"
      echo "  --connect-retries N   After retryable failures, reconnect up to N times (default 15)"
      echo "  --retry-delay-ms MS   Delay before each reconnect attempt (default 1000)"
      echo ""
      echo "Client bind (Linux — raises conn ceiling vs one dst IP:port)"
      echo "  --bind-loopbacks N    Use 127.0.0.2 … 127.0.0.(N+1); run scripts/ws_scale_linux.sh first"
      echo "  --bind-ips LIST       Comma-separated bind IPs (overrides --bind-loopbacks)"
      echo ""
      echo "Examples"
      echo "  # ~1M idle connections: split clients (single process caps ~", MaxConnectionsPerWorkerThread,
        " conn/thread & ~", MaxWorkerThreads, " threads)"
      echo "  bash nim_websocketcli/scripts/ws_parallel_load.sh"
      echo ""
      echo "  # 100k idle connections (no app frames)"
      echo "  websocketload -c 100000 -d 120 -t 16 --open-msgs 0 --no-reply-on-recv --bind-loopbacks 64"
      echo ""
      echo "  # Echo soak (defaults: 1 open send + reply each recv)"
      echo "  websocketload -c 1000 -d 30 -s 256"
      echo ""
      echo "  # Fixed 50 msg/s per client, static 128 B, no recv-driven replies"
      echo "  websocketload -c 500 -d 60 --out-mps 50 --no-reply-on-recv -s 128 --open-msgs 0"
      echo ""
      echo "  # Random payload 32..512 B, 10 msg/s per client + open burst 3"
      echo "  websocketload -c 200 -d 30 --len dynamic --min-len 32 --max-len 512 --out-mps 10 --open-msgs 3"
      quit(0)
    else:
      discard
    inc i

  if bindLoopbacks > 253:
    quit "--bind-loopbacks must be <= 253"

  if bindIpsCsv.len > 0:
    result.bindHosts = @[]
    for part in split(bindIpsCsv, ','):
      let h = part.strip()
      if h.len > 0:
        result.bindHosts.add h
  elif bindLoopbacks > 0:
    result.bindHosts = loopbackBindIps(bindLoopbacks)

  if result.concurrency < 1:
    quit "--concurrency must be >= 1"
  if result.duration < 1:
    quit "--duration must be >= 1"
  if result.drainSec < 0:
    quit "--drain-sec must be >= 0"
  if result.threads < 0:
    quit "--threads must be >= 0"
  if result.minLen < 0 or result.maxLen < 0:
    quit "--min-len / --max-len must be non-negative"
  if result.minLen > result.maxLen:
    quit "--min-len must be <= --max-len"
  if result.lenMode == plmStatic:
    result.minLen = result.msgLen
    result.maxLen = result.msgLen
  if result.tickMs < 1:
    quit "--tick-ms must be >= 1"
  if result.openMessages < 0:
    quit "--open-msgs must be >= 0"
  if result.outMps < 0:
    quit "--out-mps must be >= 0"
  if result.rampSec < 0:
    quit "--ramp-sec must be >= 0"
  if result.connectRetries < 0:
    quit "--connect-retries must be >= 0"
  if result.connectRetryDelayMs < 1:
    quit "--retry-delay-ms must be >= 1"

proc flushLocalStats(local: var LocalStats, global: ptr AtomicStats) {.inline.} =
  if local.openedSlots > 0:
    discard global.openedSlots.fetchAdd(local.openedSlots, moRelaxed)
    local.openedSlots = 0
  if local.sent > 0:
    discard global.sent.fetchAdd(local.sent, moRelaxed)
    local.sent = 0
  if local.recv > 0:
    discard global.recv.fetchAdd(local.recv, moRelaxed)
    local.recv = 0
  if local.connected > 0:
    discard global.connected.fetchAdd(local.connected, moRelaxed)
    local.connected = 0
  if local.disconnected > 0:
    discard global.disconnected.fetchAdd(local.disconnected, moRelaxed)
    local.disconnected = 0
  if local.errors > 0:
    discard global.errors.fetchAdd(local.errors, moRelaxed)
    local.errors = 0
  if local.connectErrors > 0:
    discard global.connectErrors.fetchAdd(local.connectErrors, moRelaxed)
    local.connectErrors = 0

var tlWorkerCtx {.threadvar.}: ptr WorkerContext

proc sendOneApp(ctx: ptr WorkerContext, state: WsConnection, slotIx: int) {.inline, gcsafe.}
proc enqueueRetry(ctx: ptr WorkerContext, ix: int) {.inline, gcsafe.}

proc bindTimerContext(timer: UsTimerPtr, ctx: ptr WorkerContext) {.inline.} =
  if timer != nil:
    cast[ptr pointer](us_timer_ext(timer))[] = cast[pointer](ctx)

proc timerContext(timer: UsTimerPtr): ptr WorkerContext {.inline.} =
  if timer != nil:
    let ext = us_timer_ext(timer)
    if ext != nil:
      let p = cast[ptr pointer](ext)[]
      if p != nil:
        return cast[ptr WorkerContext](p)
  tlWorkerCtx

proc addOpenSlot(ctx: ptr WorkerContext, ix: int) {.inline, gcsafe.} =
  if ctx == nil or ix < 0 or ix >= ctx.openSlotPos.len:
    return
  if ctx.openSlotPos[ix] >= 0:
    return
  ctx.openSlots.add ix
  ctx.openSlotPos[ix] = ctx.openSlots.len - 1

proc removeOpenSlot(ctx: ptr WorkerContext, ix: int) {.inline, gcsafe.} =
  if ctx == nil or ix < 0 or ix >= ctx.openSlotPos.len:
    return
  let pos = ctx.openSlotPos[ix]
  if pos < 0 or pos >= ctx.openSlots.len:
    ctx.openSlotPos[ix] = -1
    return
  let last = ctx.openSlots.len - 1
  if pos != last:
    let moved = ctx.openSlots[last]
    ctx.openSlots[pos] = moved
    if moved >= 0 and moved < ctx.openSlotPos.len:
      ctx.openSlotPos[moved] = pos
  ctx.openSlots.setLen(last)
  ctx.openSlotPos[ix] = -1

proc issueConnect(ctx: ptr WorkerContext, ix: int) {.inline.} =
  if ctx == nil or ctx.done:
    return
  if ix < 0 or ix >= ctx.clientStates.len:
    return
  inc ctx.connectAttemptsIssued[ix]
  let bindHost =
    if ctx.bindHosts.len > 0:
      ctx.bindHosts[(ctx.bindHostBaseOffset + ix) mod ctx.bindHosts.len]
    else:
      ""
  let ws = ctx.wsClient.ws(ctx.bootstrapUrl, bindHost = bindHost)
  ctx.clientStates[ix] = ws
  if ws == nil:
    inc ctx.localStats.connectErrors
    return

  let slotIx = ix
  ws.onOpen = proc() {.gcsafe.} =
    let c = tlWorkerCtx
    if c == nil or c.done: return
    if slotIx >= 0 and slotIx < c.openedOnce.len and not c.openedOnce[slotIx]:
      c.openedOnce[slotIx] = true
      addOpenSlot(c, slotIx)
      inc c.localStats.openedSlots
      inc c.connectedCount
      inc c.localStats.connected
    var k = c.openMessages
    while k > 0:
      sendOneApp(c, c.clientStates[slotIx], slotIx)
      dec k

  ws.onMessage = proc(data: string, opcode: WsOpcode) {.gcsafe.} =
    let c = tlWorkerCtx
    if c == nil or c.done: return
    if opcode == woText or opcode == woBinary:
      inc c.localStats.recv
      if c.replyOnRecv:
        sendOneApp(c, c.clientStates[slotIx], slotIx)

  ws.onClose = proc(code: uint16, reason: string) {.gcsafe.} =
    let c = tlWorkerCtx
    if c == nil: return
    if slotIx >= 0 and slotIx < c.closedOnce.len:
      if not c.closedOnce[slotIx] and slotIx < c.openedOnce.len and c.openedOnce[slotIx]:
        c.closedOnce[slotIx] = true
        removeOpenSlot(c, slotIx)
        if c.connectedCount > 0:
          dec c.connectedCount
        inc c.localStats.disconnected

  ws.onError = proc(err: string) {.gcsafe.} =
    let c = tlWorkerCtx
    if c == nil or c.done:
      return
    if slotIx < 0 or slotIx >= c.connectAttemptsIssued.len:
      return
    if err.startsWith("Invalid URL") or err.contains("client initialization failed"):
      inc c.localStats.connectErrors
      return
    if c.connectAttemptsIssued[slotIx] >= c.maxConnectAttempts:
      inc c.localStats.connectErrors
      return
    enqueueRetry(c, slotIx)

proc enqueueRetry(ctx: ptr WorkerContext, ix: int) {.inline, gcsafe.} =
  if ctx == nil or ctx.done:
    return
  if ix < 0 or ix >= ctx.retryQueued.len:
    return
  if ctx.retryQueued[ix]:
    return
  ctx.retryQueued[ix] = true
  ctx.pendingRetries.add((ix, epochTime() + float64(ctx.retryDelayMs) * 0.001))

proc processPendingRetries(ctx: ptr WorkerContext) {.inline.} =
  if ctx == nil or ctx.done:
    return
  let now = epochTime()
  var i = 0
  while i < ctx.pendingRetries.len:
    if ctx.pendingRetries[i].dueEpoch <= now:
      let ix = ctx.pendingRetries[i].ix
      let last = ctx.pendingRetries.len - 1
      if i != last:
        ctx.pendingRetries[i] = ctx.pendingRetries[last]
      ctx.pendingRetries.setLen(last)
      ctx.retryQueued[ix] = false
      issueConnect(ctx, ix)
      continue
    inc i

proc onRetrySweepFire(timer: UsTimerPtr) {.cdecl.} =
  let ctx = timerContext(timer)
  if ctx == nil or ctx.done:
    return
  processPendingRetries(ctx)

proc sendOneApp(ctx: ptr WorkerContext, state: WsConnection, slotIx: int) {.inline, gcsafe.} =
  if ctx == nil or ctx.done or ctx.draining: return
  if state == nil or state.state != csOpen: return
  let pl =
    case ctx.payloadKind
    of pkAlpha:
      case ctx.lenMode
      of plmStatic:
        ctx.staticPayload
      of plmDynamic:
        generateTestPayload(ctx.rng.rand(ctx.minLen .. ctx.maxLen))
    of pkRealtime:
      if slotIx >= 0 and slotIx < ctx.sendSeq.len:
        inc ctx.sendSeq[slotIx]
        if ctx.lenMode == plmStatic and
            slotIx < ctx.payloadScratch.len and
            slotIx < ctx.seqFieldOffset.len:
          ctx.payloadScratch[slotIx].overwritePaddedUint(ctx.seqFieldOffset[slotIx], ctx.sendSeq[slotIx], 12)
          ctx.payloadScratch[slotIx]
        else:
          let size =
            case ctx.lenMode
            of plmStatic: ctx.maxLen
            of plmDynamic: ctx.rng.rand(ctx.minLen .. ctx.maxLen)
          generateRealtimePayload(size, ctx.bindHostBaseOffset, slotIx, ctx.sendSeq[slotIx])
      else:
        ctx.staticPayload
  send(state, pl, ctx.opcode)
  inc ctx.localStats.sent

proc onRateTimerFire(timer: UsTimerPtr) {.cdecl.} =
  let ctx = timerContext(timer)
  if ctx == nil or ctx.done: return
  if not ctx.sendingStarted: return
  if ctx.outMps <= 0: return
  let dt = float64(ctx.tickMs) / 1000.0
  let inc = ctx.outMps * dt
  ctx.rateCredit += inc
  if ctx.rateCredit < 1.0:
    return
  let sendBursts = int(ctx.rateCredit)
  ctx.rateCredit -= float64(sendBursts)
  for i in 0 ..< ctx.openSlots.len:
    let slotIx = ctx.openSlots[i]
    if slotIx < 0 or slotIx >= ctx.clientStates.len:
      continue
    let state = ctx.clientStates[slotIx]
    if state == nil or state.state != csOpen:
      continue
    var k = sendBursts
    while k > 0:
      sendOneApp(ctx, state, slotIx)
      dec k

proc onLoopStopTimerFire(timer: UsTimerPtr) {.cdecl.} =
  let ctx = timerContext(timer)
  if ctx != nil:
    stopLoop(ctx.wsClient)
  us_timer_close(timer)

proc onWorkerTimerFire(timer: UsTimerPtr) {.cdecl.} =
  let ctx = timerContext(timer)
  if ctx == nil: return
  ctx.done = true
  flushLocalStats(ctx.localStats, ctx.globalStats)
  if ctx.retrySweepTimer != nil:
    us_timer_close(ctx.retrySweepTimer)
    ctx.retrySweepTimer = nil
  if ctx.bootstrapTimer != nil:
    us_timer_close(ctx.bootstrapTimer)
    ctx.bootstrapTimer = nil
  if ctx.rateTimer != nil:
    us_timer_close(ctx.rateTimer)
    ctx.rateTimer = nil
  if ctx.flushTimer != nil:
    us_timer_close(ctx.flushTimer)
    ctx.flushTimer = nil
  for i in 0 ..< ctx.clientStates.len:
    let state = ctx.clientStates[i]
    if state != nil and state.state != csClosed and state.socket != nil:
      state.manualClose = true
      if i < ctx.openedOnce.len and ctx.openedOnce[i] and
         i < ctx.closedOnce.len and not ctx.closedOnce[i]:
        ctx.closedOnce[i] = true
        removeOpenSlot(ctx, i)
        if ctx.connectedCount > 0:
          dec ctx.connectedCount
        inc ctx.localStats.disconnected
      discard us_socket_close(if state.useSsl: 1 else: 0, state.socket, 0, nil)
  let loopStopTimer = us_create_timer(ctx.wsClient.loop, 0, cuint(sizeof(pointer)))
  if loopStopTimer != nil:
    bindTimerContext(loopStopTimer, ctx)
    us_timer_set(loopStopTimer, onLoopStopTimerFire, 250, 0)
  else:
    stopLoop(ctx.wsClient)
  us_timer_close(timer)

proc onDrainStartTimerFire(timer: UsTimerPtr) {.cdecl.} =
  let ctx = timerContext(timer)
  if ctx == nil:
    us_timer_close(timer)
    return
  ctx.draining = true
  if ctx.rateTimer != nil:
    us_timer_close(ctx.rateTimer)
    ctx.rateTimer = nil
  flushLocalStats(ctx.localStats, ctx.globalStats)
  us_timer_set(timer, onWorkerTimerFire, cint(max(0, ctx.drainSec) * 1000), 0)

proc onBootstrapTimerFire(timer: UsTimerPtr) {.cdecl.} =
  let ctx = timerContext(timer)
  if ctx == nil or ctx.done:
    return
  ## Repeat timers may queue an extra dispatch around teardown under io_uring; skip duplicates.
  if ctx.bootstrapIx >= ctx.clientStates.len:
    return
  var n = 0
  while ctx.bootstrapIx < ctx.clientStates.len and n < ConnectBatchSize:
    issueConnect(ctx, ctx.bootstrapIx)
    inc ctx.bootstrapIx
    inc n
  if ctx.bootstrapIx >= ctx.clientStates.len:
    ctx.bootstrapTimer = nil
    us_timer_close(timer)
    ctx.sendingStarted = true
    let stopTimer = us_create_timer(ctx.wsClient.loop, 0, cuint(sizeof(pointer)))
    if stopTimer == nil:
      inc ctx.localStats.errors
      ctx.done = true
      stopLoop(ctx.wsClient)
      return
    bindTimerContext(stopTimer, ctx)
    let finalCallback = if ctx.drainSec > 0: onDrainStartTimerFire else: onWorkerTimerFire
    us_timer_set(stopTimer, finalCallback, cint(ctx.durationSec * 1000), 0)

proc onFlushTimerFire(timer: UsTimerPtr) {.cdecl.} =
  let ctx = timerContext(timer)
  if ctx == nil: return
  flushLocalStats(ctx.localStats, ctx.globalStats)

proc workerThread(args: WorkerArgs) {.thread.} =
  {.cast(gcsafe).}:
    var ctx: WorkerContext
    ctx.globalStats = args.globalStats
    ctx.lenMode = args.lenMode
    ctx.minLen = args.minLen
    ctx.maxLen = args.maxLen
    ctx.payloadKind = args.payloadKind
    ctx.staticPayload = args.staticPayload
    ctx.openMessages = args.openMessages
    ctx.replyOnRecv = args.replyOnRecv
    ctx.outMps = args.outMps
    ctx.rateCredit = 0.0
    ctx.opcode = args.opcode
    ctx.tickMs = args.tickMs
    ctx.connectedCount = 0
    ctx.done = false
    ctx.draining = false
    ctx.sendingStarted = false
    ctx.bootstrapIx = 0
    ctx.bootstrapTimer = nil
    ctx.bootstrapUrl = ""
    ctx.durationSec = 0
    ctx.drainSec = 0
    ctx.rateTimer = nil
    ctx.retrySweepTimer = nil
    ctx.rng = initRand(0x9E3779B97F4A7C15'i64 xor int64(args.workerId))

    ctx.wsClient = newHttpClient(maxConnsPerHost = max(1, args.connectionsPerThread))
    initClient(ctx.wsClient, false)
    if ctx.wsClient.loop == nil or ctx.wsClient.ctx == nil:
      tlWorkerCtx = nil
      return

    tlWorkerCtx = addr ctx
    let url = "ws://" & args.host & ":" & $args.port & args.path
    ctx.bootstrapUrl = url
    ctx.durationSec = args.duration
    ctx.drainSec = args.drainSec

    ctx.clientStates = newSeq[WsConnection](args.connectionsPerThread)
    ctx.pendingRetries = @[]
    ctx.retryQueued = newSeq[bool](args.connectionsPerThread)
    ctx.openedOnce = newSeq[bool](args.connectionsPerThread)
    ctx.closedOnce = newSeq[bool](args.connectionsPerThread)
    ctx.sendSeq = newSeq[uint64](args.connectionsPerThread)
    if args.payloadKind == pkRealtime and args.lenMode == plmStatic:
      ctx.payloadScratch = newSeq[string](args.connectionsPerThread)
      ctx.seqFieldOffset = newSeq[int](args.connectionsPerThread)
      for i in 0..<args.connectionsPerThread:
        ctx.payloadScratch[i] = generateRealtimePayload(args.maxLen, args.workerId, i, 0'u64, 12)
        ctx.seqFieldOffset[i] = seqOffsetInRealtimePayload(ctx.payloadScratch[i])
    ctx.openSlots = @[]
    ctx.openSlotPos = newSeq[int](args.connectionsPerThread)
    for i in 0 ..< ctx.openSlotPos.len:
      ctx.openSlotPos[i] = -1
    ctx.connectAttemptsIssued = newSeq[int](args.connectionsPerThread)
    ctx.retryDelayMs = args.connectRetryDelayMs
    ctx.maxConnectAttempts = 1 + args.connectRetries
    ctx.bindHosts = args.bindHosts
    ctx.bindHostBaseOffset = args.bindHostBaseOffset

    let batches = max(1, (args.connectionsPerThread + ConnectBatchSize - 1) div ConnectBatchSize)
    let bootstrapRepeatMs =
      if args.rampSec <= 0:
        2.cint
      else:
        max(1.cint, cint((args.rampSec * 1000) div batches))

    ctx.bootstrapTimer = us_create_timer(ctx.wsClient.loop, 0, cuint(sizeof(pointer)))
    if ctx.bootstrapTimer == nil:
      inc ctx.localStats.errors
      close(ctx.wsClient)
      tlWorkerCtx = nil
      return
    bindTimerContext(ctx.bootstrapTimer, addr ctx)
    us_timer_set(ctx.bootstrapTimer, onBootstrapTimerFire, 1, bootstrapRepeatMs)

    ctx.retrySweepTimer = us_create_timer(ctx.wsClient.loop, 0, cuint(sizeof(pointer)))
    if ctx.retrySweepTimer == nil:
      inc ctx.localStats.errors
      close(ctx.wsClient)
      tlWorkerCtx = nil
      return
    bindTimerContext(ctx.retrySweepTimer, addr ctx)
    us_timer_set(ctx.retrySweepTimer, onRetrySweepFire, 50, 50)

    ctx.flushTimer = us_create_timer(ctx.wsClient.loop, 0, cuint(sizeof(pointer)))
    if ctx.flushTimer == nil:
      inc ctx.localStats.errors
      close(ctx.wsClient)
      tlWorkerCtx = nil
      return
    bindTimerContext(ctx.flushTimer, addr ctx)
    us_timer_set(ctx.flushTimer, onFlushTimerFire, 100, 100)

    if ctx.outMps > 0:
      ctx.rateTimer = us_create_timer(ctx.wsClient.loop, 0, cuint(sizeof(pointer)))
      if ctx.rateTimer == nil:
        inc ctx.localStats.errors
        close(ctx.wsClient)
        tlWorkerCtx = nil
        return
      bindTimerContext(ctx.rateTimer, addr ctx)
      us_timer_set(ctx.rateTimer, onRateTimerFire, cint(ctx.tickMs), cint(ctx.tickMs))

    run(ctx.wsClient)

    flushLocalStats(ctx.localStats, ctx.globalStats)
    close(ctx.wsClient)

    tlWorkerCtx = nil

proc detectBackend(): string =
  when defined(macosx):
    "gcd"
  elif defined(linux):
    when defined(LIBUS_USE_IO_URING):
      "io_uring"
    else:
      "epoll"
  elif defined(windows):
    "IOCP (via libuv)"
  else:
    "unknown"

proc worstThread0Load*(n, t: int): int {.inline.} =
  ## Matches worker distribution: thread 0 owns ``remainder`` extra sockets.
  if t <= 0:
    return n
  (n div t) + (n mod t)

when isMainModule:
  let config = parseCommandLine()

  var threadCount = config.threads
  when defined(macosx) and defined(LIBUS_USE_GCD):
    if threadCount > 1:
      stderr.writeLine "[websocketload] macOS GCD backend supports one main-thread load loop only; use Linux epoll/io_uring for multi-thread high-traffic generation."
      quit 1
    threadCount = 1
  else:
    if threadCount <= 0:
      threadCount = countProcessors()
      if threadCount <= 0: threadCount = 4

  if threadCount > config.concurrency:
    threadCount = config.concurrency

  if threadCount > MaxWorkerThreads:
    stderr.writeLine "[websocketload] Capping worker threads from ", threadCount, " to ", MaxWorkerThreads, " (stability on Linux)."
    threadCount = MaxWorkerThreads

  while threadCount < MaxWorkerThreads and config.concurrency > 0 and
      worstThread0Load(config.concurrency, threadCount) > MaxConnectionsPerWorkerThread:
    inc threadCount

  if worstThread0Load(config.concurrency, threadCount) > MaxConnectionsPerWorkerThread:
    stderr.writeLine "[websocketload] Hottest worker would hold ",
      worstThread0Load(config.concurrency, threadCount),
      " connections (limit ",
      MaxConnectionsPerWorkerThread,
      "). Raise ``-t`` or split clients. Example for ~1M: ``WORKERS=6 CHUNK=180000 THREADS=24 bash nim_websocketcli/scripts/ws_parallel_load.sh``"
    quit 1

  let connectionsPerThread = config.concurrency div threadCount
  let remainder = config.concurrency mod threadCount

  let staticPayload = generateTestPayload(config.msgLen)

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║      websocketload - WebSocket Load Tester   ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  echo "  Target:       ws://", config.host, ":", config.port, config.path
  echo "  Connections:  ", formatNum(int64(config.concurrency))
  echo "  Duration:     ", config.duration, "s"
  echo "  Drain:        ", config.drainSec, "s"
  echo "  Len mode:     ", config.lenMode
  if config.lenMode == plmStatic:
    echo "  Message len:  ", config.msgLen, " B"
  else:
    echo "  Message len:  ", config.minLen, "..", config.maxLen, " B (uniform)"
  echo "  Open msgs:    ", config.openMessages
  echo "  Payload:      ", config.payloadKind
  echo "  Reply recv:   ", config.replyOnRecv
  echo "  Out mps/conn: ", config.outMps
  echo "  Opcode:       ", config.opcode
  echo "  Rate tick:    ", config.tickMs, " ms"
  echo "  Ramp:         ", config.rampSec, " s/worker bootstrap spread (0 = fastest)"
  echo "  Retries:      ", config.connectRetries, " × ", config.connectRetryDelayMs, " ms delay"
  if config.bindHosts.len > 0:
    echo "  Bind sources: ", config.bindHosts.len, " IPs (e.g. ", config.bindHosts[0], " …)"
  echo "  Threads:      ", threadCount
  echo "  Per-thread:   ", connectionsPerThread
  if remainder > 0:
    echo "  (thread 0 gets ", remainder, " extra)"
  echo "  Backend:      ", detectBackend()
  echo "  Platform:     ", hostOS, "/", hostCPU
  echo ""

  var stats: AtomicStats
  stats.connected.store(0, moRelaxed)
  stats.openedSlots.store(0, moRelaxed)
  stats.disconnected.store(0, moRelaxed)
  stats.sent.store(0, moRelaxed)
  stats.recv.store(0, moRelaxed)
  stats.errors.store(0, moRelaxed)
  stats.connectErrors.store(0, moRelaxed)

  when defined(macosx) and defined(LIBUS_USE_GCD):
    echo "Starting 1 main-thread worker..."
  else:
    echo "Starting ", threadCount, " worker threads..."
  let startTime = getMonoTime()

  when defined(macosx) and defined(LIBUS_USE_GCD):
    let args = WorkerArgs(
      workerId: 0,
      host: config.host,
      port: config.port,
      path: config.path,
      lenMode: config.lenMode,
      msgLen: config.msgLen,
      minLen: config.minLen,
      maxLen: config.maxLen,
      payloadKind: config.payloadKind,
      staticPayload: staticPayload,
      openMessages: config.openMessages,
      replyOnRecv: config.replyOnRecv,
      outMps: config.outMps,
      opcode: config.opcode,
      tickMs: config.tickMs,
      connectionsPerThread: connectionsPerThread + remainder,
      duration: config.duration,
      drainSec: config.drainSec,
      globalStats: addr stats,
      bindHosts: config.bindHosts,
      bindHostBaseOffset: 0,
      rampSec: config.rampSec,
      connectRetries: config.connectRetries,
      connectRetryDelayMs: config.connectRetryDelayMs,
    )
    workerThread(args)
  else:
    var bindOff = 0
    var threads = newSeq[Thread[WorkerArgs]](threadCount)
    for i in 0 ..< threadCount:
      let extra = if i == 0: remainder else: 0
      let cpt = connectionsPerThread + extra
      let args = WorkerArgs(
        workerId: i,
        host: config.host,
        port: config.port,
        path: config.path,
        lenMode: config.lenMode,
        msgLen: config.msgLen,
        minLen: config.minLen,
        maxLen: config.maxLen,
        payloadKind: config.payloadKind,
        staticPayload: staticPayload,
        openMessages: config.openMessages,
        replyOnRecv: config.replyOnRecv,
        outMps: config.outMps,
        opcode: config.opcode,
        tickMs: config.tickMs,
        connectionsPerThread: cpt,
        duration: config.duration,
        drainSec: config.drainSec,
        globalStats: addr stats,
        bindHosts: config.bindHosts,
        bindHostBaseOffset: bindOff,
        rampSec: config.rampSec,
        connectRetries: config.connectRetries,
        connectRetryDelayMs: config.connectRetryDelayMs,
      )
      bindOff += cpt
      createThread(threads[i], workerThread, args)
    for i in 0 ..< threadCount:
      joinThread(threads[i])

  let elapsed = getMonoTime() - startTime
  let elapsedSec = float(elapsed.inMilliseconds()) / 1000.0

  let totalSent = stats.sent.load(moRelaxed)
  let totalRecv = stats.recv.load(moRelaxed)
  let totalOpenedSlots = stats.openedSlots.load(moRelaxed)
  let totalConnected = stats.connected.load(moRelaxed)
  let totalDisconnected = stats.disconnected.load(moRelaxed)
  let totalErrors = stats.errors.load(moRelaxed)
  let totalConnectErrorsRaw = stats.connectErrors.load(moRelaxed)
  let stillOpen = max(0'i64, totalConnected - totalDisconnected)
  let missingOpens = max(0'i64, config.concurrency.int64 - min(totalOpenedSlots, config.concurrency.int64))
  let totalConnectErrorsOut =
    max(totalConnectErrorsRaw, missingOpens)

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║                  Results                     ║"
  echo "╠══════════════════════════════════════════════╣"
  echo "║  Duration:       ", formatFloat(elapsedSec, ffDecimal, 2).alignLeft(27), "║"
  echo "║  Connected:      ", formatNum(totalConnected).alignLeft(27), "║"
  echo "║  Opened slots:   ", formatNum(totalOpenedSlots).alignLeft(27), "║"
  echo "║  Still open:     ", formatNum(stillOpen).alignLeft(27), "║"
  echo "║  Disconnected:   ", formatNum(totalDisconnected).alignLeft(27), "║"
  echo "║  Connect Errors: ", formatNum(totalConnectErrorsOut).alignLeft(27), "║"
  echo "║  Errors:         ", formatNum(totalErrors).alignLeft(27), "║"
  echo "║  Messages sent:  ", formatNum(totalSent).alignLeft(27), "║"
  echo "║  Messages recv:  ", formatNum(totalRecv).alignLeft(27), "║"
  echo "╠══════════════════════════════════════════════╣"
  echo "║  Send rate:      ", (formatRps(totalSent, elapsedSec) & " msg/s").alignLeft(27), "║"
  echo "║  Recv rate:      ", (formatRps(totalRecv, elapsedSec) & " msg/s").alignLeft(27), "║"
  echo "╚══════════════════════════════════════════════╝"
