import std/times
import types
import ws_frame

export ws_frame

const
  DefaultWsPingIntervalMs* = 30000
  DefaultWsPongTimeoutMs* = 10000
  DefaultWsCloseTimeoutMs* = 5000
  DefaultWsMaxMessageSize* = 16 * 1024 * 1024
  DefaultWsMaxReconnectAttempts* = 5
  DefaultWsBaseDelayMs* = 1000
  DefaultWsMaxDelayMs* = 30000

type
  WsFrameReadStatus* = enum
    wfrNeedMore
    wfrOk
    wfrProtocolError
    wfrMessageTooLarge

  WsFrameReadResult* = object
    status*: WsFrameReadStatus
    frame*: WsFrame
    closeCode*: uint16
    error*: string

## Return the current wall-clock time in milliseconds.
proc nowWsMs*(): int64 {.inline.} =
  int64(epochTime() * 1000.0)

proc splitMix64(x: var uint64): uint64 {.inline.} =
  x += 0x9E3779B97F4A7C15'u64
  var z = x
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc reconnectJitterMs(ws: WsConnection, bound: int): int {.inline.} =
  if bound <= 0:
    return 0
  var seed = uint64(nowWsMs()) xor
    (uint64(ws.reconnectAttempts + 1) * 0x9E3779B97F4A7C15'u64) xor
    uint64(ws.baseDelayMs) xor
    cast[uint64](cast[uint](unsafeAddr ws[]))
  int(splitMix64(seed) mod uint64(bound + 1))

## Initialize `ws` with the default WebSocket client configuration.
proc initWsClientDefaults*(ws: WsConnection) =
  if ws == nil:
    return
  ws.state = csClosed
  ws.recvBuf = newStringOfCap(4096)
  ws.pingIntervalMs = DefaultWsPingIntervalMs
  ws.pongTimeoutMs = DefaultWsPongTimeoutMs
  ws.closeTimeoutMs = DefaultWsCloseTimeoutMs
  ws.maxMessageSize = DefaultWsMaxMessageSize
  ws.autoReconnect = false
  ws.reconnectAttempts = 0
  ws.maxReconnectAttempts = DefaultWsMaxReconnectAttempts
  ws.baseDelayMs = DefaultWsBaseDelayMs
  ws.maxDelayMs = DefaultWsMaxDelayMs
  ws.closeCode = 1005'u16

## Configure the heartbeat ping and pong timing for `ws`.
proc configureHeartbeat*(ws: WsConnection, pingIntervalMs: int = DefaultWsPingIntervalMs,
                         pongTimeoutMs: int = DefaultWsPongTimeoutMs) =
  if ws == nil:
    return
  ws.pingIntervalMs = max(0, pingIntervalMs)
  ws.pongTimeoutMs = max(0, pongTimeoutMs)

## Configure the automatic reconnect behavior for `ws`.
proc configureReconnect*(ws: WsConnection, autoReconnect: bool = false,
                         maxReconnectAttempts: int = DefaultWsMaxReconnectAttempts,
                         baseDelayMs: int = DefaultWsBaseDelayMs,
                         maxDelayMs: int = DefaultWsMaxDelayMs) =
  if ws == nil:
    return
  ws.autoReconnect = autoReconnect
  ws.maxReconnectAttempts = max(0, maxReconnectAttempts)
  ws.baseDelayMs = max(1, baseDelayMs)
  ws.maxDelayMs = max(ws.baseDelayMs, maxDelayMs)

## Return true when `code` indicates a close condition worth retrying.
proc isReconnectableWsCloseCode*(code: uint16): bool {.inline.} =
  code == 1005'u16 or code == 1006'u16 or
    (code >= 1011'u16 and code <= 1014'u16)

## Return true when `ws` should schedule another reconnect attempt.
proc shouldScheduleWsReconnect*(ws: WsConnection, requireLoop: bool = true): bool {.inline.} =
  if ws == nil or not ws.autoReconnect or ws.manualClose:
    return false
  if requireLoop and ws.loop == nil:
    return false
  if ws.reconnectTimer != nil:
    return false
  if ws.reconnectAttempts >= ws.maxReconnectAttempts:
    return false
  if ws.closeNotified and not isReconnectableWsCloseCode(ws.closeCode):
    return false
  true

## Return true when `code` is a valid RFC 6455 close code for the wire.
proc isValidWsCloseCode*(code: uint16): bool {.inline.} =
  (code >= 1000'u16 and code <= 1003'u16) or
    (code >= 1007'u16 and code <= 1014'u16) or
    (code >= 3000'u16 and code <= 4999'u16)

## Return true when `code` must never be sent on the wire.
proc isForbiddenWireCloseCode*(code: uint16): bool {.inline.} =
  code == 1004'u16 or code == 1005'u16 or code == 1006'u16 or code == 1015'u16

## Return `code` when it is wire-valid, otherwise the 1002 protocol error code.
proc sanitizeOutgoingCloseCode*(code: uint16): uint16 {.inline.} =
  if isValidWsCloseCode(code): code else: 1002'u16

## Reset the incremental UTF-8 validation state of `ws`.
proc resetWsUtf8*(ws: WsConnection) =
  if ws == nil:
    return
  ws.utf8Needed = 0
  ws.utf8Code = 0
  ws.utf8Min = 0
  ws.utf8Invalid = false

## Incrementally validate UTF-8 in `data`; return false on the first invalid sequence.
proc feedWsUtf8*(ws: WsConnection, data: string, final: bool): bool =
  if ws == nil:
    return false
  if ws.utf8Invalid:
    return false
  for ch in data:
    let b = ord(ch)
    if ws.utf8Needed == 0:
      if b <= 0x7F:
        discard
      elif b >= 0xC2 and b <= 0xDF:
        ws.utf8Needed = 1
        ws.utf8Code = b and 0x1F
        ws.utf8Min = 0x80
      elif b >= 0xE0 and b <= 0xEF:
        ws.utf8Needed = 2
        ws.utf8Code = b and 0x0F
        ws.utf8Min = 0x800
      elif b >= 0xF0 and b <= 0xF4:
        ws.utf8Needed = 3
        ws.utf8Code = b and 0x07
        ws.utf8Min = 0x10000
      else:
        ws.utf8Invalid = true
        return false
    else:
      if b < 0x80 or b > 0xBF:
        ws.utf8Invalid = true
        return false
      ws.utf8Code = (ws.utf8Code shl 6) or (b and 0x3F)
      dec ws.utf8Needed
      if ws.utf8Needed == 0:
        let cp = ws.utf8Code
        if cp < ws.utf8Min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
          ws.utf8Invalid = true
          return false
        ws.utf8Code = 0
        ws.utf8Min = 0
  if final and ws.utf8Needed != 0:
    ws.utf8Invalid = true
    return false
  true

## Return true when `data` is a complete, valid UTF-8 sequence.
proc isValidUtf8*(data: string): bool =
  let ws = newWsConnection()
  resetWsUtf8(ws)
  feedWsUtf8(ws, data, final = true)

## Parse a close frame `payload` into its close code and UTF-8 reason.
proc parseWsClosePayload*(payload: string): tuple[valid: bool, code: uint16, reason: string, closeCode: uint16] =
  if payload.len == 0:
    return (true, 1005'u16, "", 1005'u16)
  if payload.len == 1:
    return (false, 1002'u16, "", 1002'u16)
  let code = (uint16(ord(payload[0])) shl 8) or uint16(ord(payload[1]))
  if not isValidWsCloseCode(code):
    return (false, code, "", 1002'u16)
  let reason = if payload.len > 2: payload[2 ..< payload.len] else: ""
  if reason.len > 0 and not isValidUtf8(reason):
    return (false, code, "", 1007'u16)
  (true, code, reason, code)

## Parse a single WebSocket frame from `buf`, advancing `pos` on success.
proc readWsFrame*(buf: string, pos: var int, maxPayloadSize: int = DefaultWsMaxMessageSize,
                  requireUnmasked: bool = false): WsFrameReadResult =
  result.closeCode = 1002'u16
  if pos < 0 or pos > buf.len:
    result.status = wfrProtocolError
    result.error = "invalid websocket parse offset"
    return
  if buf.len - pos < 2:
    result.status = wfrNeedMore
    return

  let b0 = uint8(ord(buf[pos]))
  let b1 = uint8(ord(buf[pos + 1]))
  let fin = (b0 and 0x80'u8) != 0
  if (b0 and 0x70'u8) != 0:
    result.status = wfrProtocolError
    result.error = "websocket RSV bits set"
    return

  let opcodeVal = b0 and 0x0F'u8
  let isControl = opcodeVal >= 0x8'u8
  case opcodeVal
  of 0x0'u8, 0x1'u8, 0x2'u8, 0x8'u8, 0x9'u8, 0xA'u8:
    discard
  else:
    result.status = wfrProtocolError
    result.error = "invalid websocket opcode"
    return
  let opcode = case opcodeVal
    of 0x0'u8: woContinuation
    of 0x1'u8: woText
    of 0x2'u8: woBinary
    of 0x8'u8: woClose
    of 0x9'u8: woPing
    else: woPong
  if isControl and not fin:
    result.status = wfrProtocolError
    result.error = "fragmented websocket control frame"
    return

  let lenCode = b1 and 0x7F'u8
  var payloadLen = uint64(lenCode)
  var headerSize = 2
  if isControl and payloadLen > 125'u64:
    result.status = wfrProtocolError
    result.error = "websocket control payload too large"
    return
  if lenCode == 126'u8:
    if isControl:
      result.status = wfrProtocolError
      result.error = "websocket control payload too large"
      return
    if buf.len - pos < 4:
      result.status = wfrNeedMore
      return
    payloadLen = (uint64(ord(buf[pos + 2])) shl 8) or uint64(ord(buf[pos + 3]))
    if payloadLen < 126'u64:
      result.status = wfrProtocolError
      result.error = "non-canonical websocket payload length"
      return
    headerSize = 4
  elif lenCode == 127'u8:
    if isControl:
      result.status = wfrProtocolError
      result.error = "websocket control payload too large"
      return
    if buf.len - pos < 10:
      result.status = wfrNeedMore
      return
    if (ord(buf[pos + 2]) and 0x80) != 0:
      result.status = wfrProtocolError
      result.error = "websocket payload length high bit set"
      return
    payloadLen = 0
    for i in 0..7:
      payloadLen = (payloadLen shl 8) or uint64(ord(buf[pos + 2 + i]))
    if payloadLen < 65536'u64:
      result.status = wfrProtocolError
      result.error = "non-canonical websocket payload length"
      return
    headerSize = 10

  let masked = (b1 and 0x80'u8) != 0
  if requireUnmasked and masked:
    result.status = wfrProtocolError
    result.error = "masked server websocket frame"
    return
  var maskKey: array[4, byte]
  if masked:
    headerSize += 4
    if buf.len - pos < headerSize:
      result.status = wfrNeedMore
      return
    for i in 0..3:
      maskKey[i] = byte(ord(buf[pos + headerSize - 4 + i]))

  if payloadLen > uint64(max(0, maxPayloadSize)):
    result.status = wfrMessageTooLarge
    result.closeCode = 1009'u16
    result.error = "websocket message too large"
    return
  if payloadLen > uint64(high(int)):
    result.status = wfrMessageTooLarge
    result.closeCode = 1009'u16
    result.error = "websocket payload length too large"
    return
  if payloadLen > uint64(high(int) - headerSize):
    result.status = wfrMessageTooLarge
    result.closeCode = 1009'u16
    result.error = "websocket payload length too large"
    return
  let totalSize = headerSize + int(payloadLen)
  if buf.len - pos < totalSize:
    result.status = wfrNeedMore
    return

  let payloadStart = pos + headerSize
  var payload = newString(int(payloadLen))
  if payloadLen > 0:
    copyMem(addr payload[0], unsafeAddr buf[payloadStart], int(payloadLen))
    if masked:
      applyWsMask(cast[ptr byte](addr payload[0]), payload.len, maskKey)

  pos += totalSize
  result.status = wfrOk
  result.frame = WsFrame(
    fin: fin,
    opcode: opcode,
    masked: masked,
    maskKey: maskKey,
    payload: payload,
  )

## Mark `ws` as open and reset connection state as of `nowMs`.
proc markWsOpen*(ws: WsConnection, nowMs: int64 = nowWsMs()) =
  if ws == nil:
    return
  ws.state = csOpen
  ws.reconnectAttempts = 0
  ws.awaitingPong = false
  ws.lastPingAtMs = nowMs
  ws.pingSentAtMs = 0
  ws.lastPongAtMs = nowMs
  ws.lastPingPayload.setLen(0)
  ws.closeFrameSent = false
  ws.closeNotified = false
  ws.manualClose = false
  ws.peerCloseReceived = false
  ws.closeCode = 1005'u16
  ws.closeReason.setLen(0)
  ws.fragmented = false
  ws.fragmentBuf.setLen(0)
  resetWsUtf8(ws)

## Return true when the pong for the outstanding ping of `ws` is overdue.
proc shouldFailPongTimeout*(ws: WsConnection, nowMs: int64 = nowWsMs()): bool {.inline.} =
  ws != nil and ws.state == csOpen and ws.awaitingPong and ws.pongTimeoutMs > 0 and
    nowMs - ws.pingSentAtMs >= int64(ws.pongTimeoutMs)

## Build a masked ping frame for `ws` and record it for pong timeout tracking.
proc buildWsPing*(ws: WsConnection, nowMs: int64 = nowWsMs(), payload: string = ""): string =
  if ws == nil or ws.state != csOpen:
    return ""
  var pingPayload = payload
  if pingPayload.len == 0:
    pingPayload = $nowMs
  if pingPayload.len > 125:
    pingPayload.setLen(125)
  ws.awaitingPong = true
  ws.pingSentAtMs = nowMs
  ws.lastPingAtMs = nowMs
  ws.lastPingPayload = pingPayload
  encodePingFrame(pingPayload, masked = true)

## Record a pong received on `ws`, clearing the awaiting state when it matches.
proc noteWsPong*(ws: WsConnection, payload: string, nowMs: int64 = nowWsMs()) =
  if ws == nil:
    return
  if ws.awaitingPong and payload == ws.lastPingPayload:
    ws.awaitingPong = false
  ws.lastPongAtMs = nowMs

## Build a masked pong frame echoing `payload`.
proc buildWsPongResponse*(payload: string): string =
  if payload.len > 125:
    return ""
  encodePongFrame(payload, masked = true)

## Compute the next reconnect delay for `ws` with exponential backoff and jitter.
proc nextWsReconnectDelayMs*(ws: WsConnection): int =
  if ws == nil:
    return DefaultWsBaseDelayMs
  let base = max(1, ws.baseDelayMs)
  let capDelay = max(base, ws.maxDelayMs)
  var delay = base
  var shifts = max(0, ws.reconnectAttempts - 1)
  while shifts > 0 and delay < capDelay:
    delay = min(capDelay, delay * 2)
    dec shifts
  let jitter = reconnectJitterMs(ws, max(1, delay div 2))
  min(capDelay, delay + jitter)
