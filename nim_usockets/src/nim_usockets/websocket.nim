import std/[strutils, base64, options, sysrand, unicode]
import fast_hash
import nim_utils/helpers/fast_map
import sha1_compat
import usockets
import ws_simd
export usockets

type
  WebSocketOpcode* = enum
    wsContinuation = 0x0
    wsText = 0x1
    wsBinary = 0x2
    wsClose = 0x8
    wsPing = 0x9
    wsPong = 0xA

  WebSocketState* = enum
    wsConnecting
    wsOpen
    wsClosing
    wsClosed

  WebSocketMessage* = object
    data*: string
    opcode*: WebSocketOpcode
    isFinal*: bool

  WebSocketConnection* = ref object
    socket*: UsSocketPtr
    buffer*: string
    fragmentBuffer*: string
    ssl*: cint
    state*: WebSocketState
    fragmentOpcode*: WebSocketOpcode

  WebSocketHandler* = object
    onOpen*: proc(ws: WebSocketConnection) {.closure.}
    onMessage*: proc(ws: WebSocketConnection, message: string, isBinary: bool) {.closure.}
    onClose*: proc(ws: WebSocketConnection, code: int, reason: string) {.closure.}
    onPing*: proc(ws: WebSocketConnection, data: string) {.closure.}
    onPong*: proc(ws: WebSocketConnection, data: string) {.closure.}

const
  WebSocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

proc parseOpcode(value: int): Option[WebSocketOpcode] {.inline.} =
  case value
  of ord(wsContinuation): some(wsContinuation)
  of ord(wsText): some(wsText)
  of ord(wsBinary): some(wsBinary)
  of ord(wsClose): some(wsClose)
  of ord(wsPing): some(wsPing)
  of ord(wsPong): some(wsPong)
  else: none(WebSocketOpcode)

proc isValidCloseCode(code: int): bool {.inline.} =
  (code >= 1000 and code <= 1015 and code != 1004 and code != 1005 and code != 1006) or
    (code >= 3000 and code <= 4999)

proc isValidClosePayload(payload: string): bool {.inline.} =
  if payload.len == 0:
    return true
  if payload.len == 1 or payload.len > 125:
    return false
  let code = (ord(payload[0]) shl 8) or ord(payload[1])
  if not code.isValidCloseCode():
    return false
  payload.len == 2 or payload[2..^1].validateUtf8() == -1

proc unmaskScalarSmall(payload: ptr char, length: int, maskKey: array[4, char]) {.inline.} =
  let p = cast[ptr UncheckedArray[byte]](payload)
  let k = cast[ptr UncheckedArray[byte]](unsafeAddr maskKey[0])
  var i = 0
  when cpuEndian == littleEndian:
    let m32 = uint32(k[0]) or (uint32(k[1]) shl 8) or
              (uint32(k[2]) shl 16) or (uint32(k[3]) shl 24)
    while i + 4 <= length:
      let src = cast[ptr uint32](addr p[i])
      src[] = src[] xor m32
      i += 4
  while i < length:
    p[i] = p[i] xor k[i and 3]
    inc i

proc unmaskPayload(payload: ptr char, length: int, maskKey: array[4, char]) {.inline.} =
  if length < 16:
    unmaskScalarSmall(payload, length, maskKey)
  else:
    wsUnmaskPayload(payload, length, maskKey)

proc containsHeaderTokenNoCase(value, token: string): bool {.inline, used.} =
  if value.len == 0 or token.len == 0:
    return false
  var i = 0
  while i < value.len:
    while i < value.len and (value[i] == ' ' or value[i] == '\t' or value[i] == ','):
      inc i
    if i >= value.len:
      break

    let start = i
    while i < value.len and value[i] != ',':
      inc i
    var last = i - 1
    while last >= start and (value[last] == ' ' or value[last] == '\t'):
      dec last

    if last >= start and (last - start + 1) == token.len:
      var matched = true
      for j in 0..<token.len:
        if value[start + j].toLowerAscii != token[j]:
          matched = false
          break
      if matched:
        return true
  false

proc containsHeaderTokenNoCase(value: fast_map.FastStringView, token: string): bool {.inline.} =
  if value.len == 0 or token.len == 0 or value.data == nil:
    return false

  let chars = cast[ptr UncheckedArray[char]](value.data)
  var i = 0
  while i < value.len:
    while i < value.len and (chars[i] == ' ' or chars[i] == '\t' or chars[i] == ','):
      inc i
    if i >= value.len:
      break

    let start = i
    while i < value.len and chars[i] != ',':
      inc i
    var last = i - 1
    while last >= start and (chars[last] == ' ' or chars[last] == '\t'):
      dec last

    if last >= start and (last - start + 1) == token.len:
      var matched = true
      for j in 0..<token.len:
        var c = chars[start + j]
        if c in 'A'..'Z':
          c = chr(ord(c) + 32)
        if c != token[j]:
          matched = false
          break
      if matched:
        return true
  false

## Compute the base64 Sec-WebSocket-Accept value for a client key via SHA1.
proc generateAcceptKey*(key: string): string =
  let combined = key & WebSocketGuid
  let bytes = secureHashBytes(combined)
  result = base64.encode(bytes)

## Check whether request headers signal a WebSocket upgrade request.
proc isWebSocketUpgrade*(headers: FastMap[string]): bool =
  let upgrade = headers.getView("upgrade")
  if not upgrade.equalsIgnoreCaseAscii("websocket"):
    return false
  containsHeaderTokenNoCase(headers.getView("connection"), "upgrade")

## Extract the Sec-WebSocket-Key header value from request headers.
proc getWebSocketKey*(headers: FastMap[string]): string =
  result = headers.getOrDefault("sec-websocket-key", "")

## Build the 101 Switching Protocols handshake response for an accept key.
proc createHandshakeResponse*(acceptKey: string): string =
  result = newStringOfCap(128 + acceptKey.len)
  result.add("HTTP/1.1 101 Switching Protocols\r\n")
  result.add("Upgrade: websocket\r\n")
  result.add("Connection: Upgrade\r\n")
  result.add("Sec-WebSocket-Accept: ")
  result.add(acceptKey)
  result.add("\r\n\r\n")

## Check whether a socket write delivered the expected number of bytes.
proc wsWriteComplete*(written, expected: int): bool {.inline.} =
  expected <= 0 or written == expected

proc failClosedAfterShortWrite(ws: WebSocketConnection) =
  if ws == nil:
    return
  if ws.socket != nil:
    discard us_socket_close(ws.ssl, ws.socket, 0, nil)
    ws.socket = nil
  ws.state = wsClosed

proc writeRawChecked(ws: WebSocketConnection, data: string): bool =
  if ws == nil or ws.socket == nil or ws.state != wsOpen:
    return false
  if data.len == 0:
    return true
  let written = int(us_socket_write(ws.ssl, ws.socket, data.cstring, data.len.cint, 0))
  result = wsWriteComplete(written, data.len)
  if not result:
    ws.failClosedAfterShortWrite()

## Write raw unframed bytes directly to the underlying socket.
proc sendRaw*(ws: WebSocketConnection, data: string) =
  discard ws.writeRawChecked(data)

proc writeFrameNoCopy(ws: WebSocketConnection, opcode: WebSocketOpcode, payload: string): cint {.inline.} =
  if ws == nil or ws.socket == nil or ws.state != wsOpen:
    return 0
  if opcode in {wsClose, wsPing, wsPong} and payload.len > 125:
    return 0

  var header: array[10, char]
  var h = 0
  header[h] = char(0x80 or ord(opcode))
  inc h

  let length = payload.len
  if length < 126:
    header[h] = char(length)
    inc h
  elif length < 65536:
    header[h] = char(126)
    inc h
    header[h] = char((length shr 8) and 0xFF)
    inc h
    header[h] = char(length and 0xFF)
    inc h
  else:
    header[h] = char(127)
    inc h
    for i in countdown(7, 0):
      header[h] = char((length shr (i * 8)) and 0xFF)
      inc h

  if length == 0:
    result = us_socket_write(ws.ssl, ws.socket, cast[cstring](addr header[0]), h.cint, 0)
    if not wsWriteComplete(result.int, h):
      ws.failClosedAfterShortWrite()
    return
  result = us_socket_write2(
    ws.ssl, ws.socket,
    cast[cstring](addr header[0]), h.cint,
    payload.cstring, length.cint
  )
  if not wsWriteComplete(result.int, h + length):
    ws.failClosedAfterShortWrite()

proc wsFrameHeaderSize(length: int, mask: bool): int {.inline.} =
  result = 2
  if length >= 126 and length < 65536:
    result = 4
  elif length >= 65536:
    result = 10
  if mask:
    result += 4

## Assemble an unmasked server-side WebSocket frame for an opcode and payload.
proc buildWsFrame*(opcode: WebSocketOpcode, data: string): string {.inline.} =
  let length = data.len
  let headerSize = wsFrameHeaderSize(length, false)
  let totalSize = headerSize + length
  result = newString(totalSize)

  var h = 0
  result[h] = char(0x80 or ord(opcode))
  inc h

  if length < 126:
    result[h] = char(length)
    inc h
  elif length < 65536:
    result[h] = char(126)
    result[h + 1] = char((length shr 8) and 0xFF)
    result[h + 2] = char(length and 0xFF)
    h += 3
  else:
    result[h] = char(127)
    inc h
    for i in countdown(7, 0):
      result[h] = char((length shr (i * 8)) and 0xFF)
      inc h

  if length > 0:
    copyMem(addr result[h], unsafeAddr data[0], length)

## Encode a WebSocket frame, optionally masking the payload with a random key.
proc encodeFrame*(opcode: WebSocketOpcode, data: string, mask: bool = false): string =
  let length = data.len
  let headerSize = wsFrameHeaderSize(length, mask)
  let totalSize = headerSize + length
  result = newString(totalSize)

  var h = 0
  result[h] = char(0x80 or ord(opcode))
  inc h

  if length < 126:
    result[h] = char(if mask: 0x80 or length else: length)
    inc h
  elif length < 65536:
    result[h] = char(if mask: 0x80 or 126 else: 126)
    result[h + 1] = char((length shr 8) and 0xFF)
    result[h + 2] = char(length and 0xFF)
    h += 3
  else:
    result[h] = char(if mask: 0x80 or 127 else: 127)
    inc h
    for i in countdown(7, 0):
      result[h] = char((length shr (i * 8)) and 0xFF)
      inc h

  if mask:
    var maskBytes: array[4, byte]
    if not urandom(maskBytes):
      raise newException(IOError, "failed to generate websocket mask key")
    let maskKey = [
      char(maskBytes[0]),
      char(maskBytes[1]),
      char(maskBytes[2]),
      char(maskBytes[3])
    ]
    result[h] = maskKey[0]
    result[h + 1] = maskKey[1]
    result[h + 2] = maskKey[2]
    result[h + 3] = maskKey[3]
    h += 4

    if length > 0:
      copyMem(addr result[h], unsafeAddr data[0], length)
      unmaskPayload(cast[ptr char](addr result[h]), length, maskKey)
  else:
    if length > 0:
      copyMem(addr result[h], unsafeAddr data[0], length)

## Send a text or binary frame and report whether the write completed fully.
proc trySend*(ws: WebSocketConnection, data: string, binary: bool = false): bool =
  let opcode = if binary: wsBinary else: wsText
  let written = ws.writeFrameNoCopy(opcode, data)
  wsWriteComplete(written.int, wsFrameHeaderSize(data.len, false) + data.len)

## Send a text or binary frame, ignoring the write completion result.
proc send*(ws: WebSocketConnection, data: string, binary: bool = false) =
  discard ws.trySend(data, binary)

## Send a text frame to the peer.
proc sendText*(ws: WebSocketConnection, data: string) =
  ws.send(data, binary = false)

## Send a binary frame to the peer.
proc sendBinary*(ws: WebSocketConnection, data: string) =
  ws.send(data, binary = true)

## Send a ping control frame, using a zero-payload fast path when empty.
proc ping*(ws: WebSocketConnection, data: string = "") =
  if ws == nil or ws.socket == nil or ws.state != wsOpen:
    return
  if data.len == 0:
    var header: array[2, char]
    header[0] = char(0x80 or ord(wsPing))
    header[1] = char(0)
    let written = us_socket_write(ws.ssl, ws.socket, cast[cstring](addr header[0]), 2.cint, 0)
    if not wsWriteComplete(written.int, 2):
      ws.failClosedAfterShortWrite()
    return
  discard ws.writeFrameNoCopy(wsPing, data)

## Send a pong control frame, using a zero-payload fast path when empty.
proc pong*(ws: WebSocketConnection, data: string = "") =
  if ws == nil or ws.socket == nil or ws.state != wsOpen:
    return
  if data.len == 0:
    var header: array[2, char]
    header[0] = char(0x80 or ord(wsPong))
    header[1] = char(0)
    let written = us_socket_write(ws.ssl, ws.socket, cast[cstring](addr header[0]), 2.cint, 0)
    if not wsWriteComplete(written.int, 2):
      ws.failClosedAfterShortWrite()
    return
  discard ws.writeFrameNoCopy(wsPong, data)

proc validWsCloseReasonPrefixLen(reason: string, maxBytes: int = 123): int =
  if reason.len == 0 or maxBytes <= 0:
    return 0
  if reason.validateUtf8() != -1:
    return 0
  result = min(reason.len, maxBytes)
  if result == reason.len:
    return
  while result > 0 and reason[0 ..< result].validateUtf8() != -1:
    dec result

## Send a close frame with a code and reason, then shut down the socket.
proc close*(ws: WebSocketConnection, code: int = 1000, reason: string = "") =
  if ws == nil or ws.state != wsOpen:
    return
  ws.state = wsClosing

  var buf: array[127, char]
  let closeCode = if code.isValidCloseCode(): code else: 1000
  buf[0] = char((closeCode shr 8) and 0xFF)
  buf[1] = char(closeCode and 0xFF)
  let reasonLen = reason.validWsCloseReasonPrefixLen()
  if reasonLen > 0:
    copyMem(addr buf[2], unsafeAddr reason[0], reasonLen)
  let payloadLen = 2 + reasonLen

  var header: array[2, char]
  header[0] = char(0x80 or ord(wsClose))
  header[1] = char(payloadLen)

  if ws.socket != nil:
    let written = us_socket_write2(
      ws.ssl, ws.socket,
      cast[cstring](addr header[0]), 2.cint,
      cast[cstring](addr buf[0]), payloadLen.cint
    )
    if not wsWriteComplete(written.int, 2 + payloadLen):
      ws.failClosedAfterShortWrite()
      return
    us_socket_shutdown(ws.ssl, ws.socket)
  ws.socket = nil
  ws.state = wsClosed

## Parse a single WebSocket frame from a byte buffer.
proc decodeFrame*(
  data: string,
  requireMasked: bool = false
): Option[tuple[message: WebSocketMessage, consumed: int]] =
  if data.len < 2:
    return none(tuple[message: WebSocketMessage, consumed: int])

  var pos = 0

  let byte1 = ord(data[pos])
  if (byte1 and 0x70) != 0:
    return none(tuple[message: WebSocketMessage, consumed: int])
  let fin = (byte1 and 0x80) != 0
  let opcodeOpt = parseOpcode(byte1 and 0x0F)
  if opcodeOpt.isNone():
    return none(tuple[message: WebSocketMessage, consumed: int])
  let opcode = opcodeOpt.get()
  let isControlFrame = opcode in {wsClose, wsPing, wsPong}
  inc pos

  let byte2 = ord(data[pos])
  let masked = (byte2 and 0x80) != 0
  if requireMasked and not masked:
    return none(tuple[message: WebSocketMessage, consumed: int])
  var payloadLen = byte2 and 0x7F
  if isControlFrame and (not fin or payloadLen >= 126):
    return none(tuple[message: WebSocketMessage, consumed: int])
  inc pos

  if payloadLen == 126:
    if data.len < pos + 2:
      return none(tuple[message: WebSocketMessage, consumed: int])
    payloadLen = (ord(data[pos]) shl 8) or ord(data[pos + 1])
    if payloadLen < 126:
      return none(tuple[message: WebSocketMessage, consumed: int])
    pos += 2
  elif payloadLen == 127:
    if data.len < pos + 8:
      return none(tuple[message: WebSocketMessage, consumed: int])
    if (ord(data[pos]) and 0x80) != 0:
      return none(tuple[message: WebSocketMessage, consumed: int])
    var len64 = 0'u64
    for i in 0..<8:
      len64 = (len64 shl 8) or uint64(ord(data[pos + i]))
    if len64 < 65536'u64 or len64 > uint64(high(int32)):
      return none(tuple[message: WebSocketMessage, consumed: int])
    payloadLen = int(len64)
    pos += 8

  if isControlFrame:
    if payloadLen > 125:
      return none(tuple[message: WebSocketMessage, consumed: int])
    if opcode == wsClose and payloadLen == 1:
      return none(tuple[message: WebSocketMessage, consumed: int])

  var maskKey: array[4, char]
  if masked:
    if data.len < pos + 4:
      return none(tuple[message: WebSocketMessage, consumed: int])
    maskKey[0] = data[pos]
    maskKey[1] = data[pos + 1]
    maskKey[2] = data[pos + 2]
    maskKey[3] = data[pos + 3]
    pos += 4

  if payloadLen > data.len - pos:
    return none(tuple[message: WebSocketMessage, consumed: int])

  var payload: string
  if payloadLen == 0:
    payload = ""
  else:
    payload = newString(payloadLen)
    copyMem(addr payload[0], unsafeAddr data[pos], payloadLen)
    if masked:
      unmaskPayload(cast[ptr char](addr payload[0]), payloadLen, maskKey)

  if opcode == wsClose and not payload.isValidClosePayload():
    return none(tuple[message: WebSocketMessage, consumed: int])

  result = some((
    message: WebSocketMessage(opcode: opcode, data: payload, isFinal: fin),
    consumed: pos + payloadLen
  ))

## Parse a single WebSocket frame, reusing the provided payload buffer to avoid allocation.
proc decodeFrameInto*(
  data: string,
  buf: var string,
  requireMasked: bool = false
): Option[tuple[message: WebSocketMessage, consumed: int]] =
  if data.len < 2:
    return none(tuple[message: WebSocketMessage, consumed: int])

  var pos = 0

  let byte1 = ord(data[pos])
  if (byte1 and 0x70) != 0:
    return none(tuple[message: WebSocketMessage, consumed: int])
  let fin = (byte1 and 0x80) != 0
  let opcodeOpt = parseOpcode(byte1 and 0x0F)
  if opcodeOpt.isNone():
    return none(tuple[message: WebSocketMessage, consumed: int])
  let opcode = opcodeOpt.get()
  let isControlFrame = opcode in {wsClose, wsPing, wsPong}
  inc pos

  let byte2 = ord(data[pos])
  let masked = (byte2 and 0x80) != 0
  if requireMasked and not masked:
    return none(tuple[message: WebSocketMessage, consumed: int])
  var payloadLen = byte2 and 0x7F
  if isControlFrame and (not fin or payloadLen >= 126):
    return none(tuple[message: WebSocketMessage, consumed: int])
  inc pos

  if payloadLen == 126:
    if data.len < pos + 2:
      return none(tuple[message: WebSocketMessage, consumed: int])
    payloadLen = (ord(data[pos]) shl 8) or ord(data[pos + 1])
    if payloadLen < 126:
      return none(tuple[message: WebSocketMessage, consumed: int])
    pos += 2
  elif payloadLen == 127:
    if data.len < pos + 8:
      return none(tuple[message: WebSocketMessage, consumed: int])
    if (ord(data[pos]) and 0x80) != 0:
      return none(tuple[message: WebSocketMessage, consumed: int])
    var len64 = 0'u64
    for i in 0..<8:
      len64 = (len64 shl 8) or uint64(ord(data[pos + i]))
    if len64 < 65536'u64 or len64 > uint64(high(int32)):
      return none(tuple[message: WebSocketMessage, consumed: int])
    payloadLen = int(len64)
    pos += 8

  if isControlFrame:
    if payloadLen > 125:
      return none(tuple[message: WebSocketMessage, consumed: int])
    if opcode == wsClose and payloadLen == 1:
      return none(tuple[message: WebSocketMessage, consumed: int])

  var maskKey: array[4, char]
  if masked:
    if data.len < pos + 4:
      return none(tuple[message: WebSocketMessage, consumed: int])
    maskKey[0] = data[pos]
    maskKey[1] = data[pos + 1]
    maskKey[2] = data[pos + 2]
    maskKey[3] = data[pos + 3]
    pos += 4

  if payloadLen > data.len - pos:
    return none(tuple[message: WebSocketMessage, consumed: int])

  if payloadLen == 0:
    buf.setLen(0)
  else:
    if buf.len < payloadLen:
      buf = newString(payloadLen)
    else:
      buf.setLen(payloadLen)
    copyMem(addr buf[0], unsafeAddr data[pos], payloadLen)
    if masked:
      unmaskPayload(cast[ptr char](addr buf[0]), payloadLen, maskKey)

  if opcode == wsClose and not buf.isValidClosePayload():
    return none(tuple[message: WebSocketMessage, consumed: int])

  result = some((
    message: WebSocketMessage(opcode: opcode, data: buf, isFinal: fin),
    consumed: pos + payloadLen
  ))
