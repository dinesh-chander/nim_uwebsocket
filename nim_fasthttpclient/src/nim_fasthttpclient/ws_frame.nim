import std/[base64, options, strutils, sysrand, unicode]
import checksums/sha1
import types
import validation

# Optional SSE2 WebSocket payload mask/unmask (nimsimd): XOR 16 payload bytes per
# vector against the repeating 4-byte mask key. Portable scalar fallback (and the
# default under -d:nimWsFramePortable).
const wsFrameUseSse2* =
  (hostCPU == "amd64" or hostCPU == "i386") and
  (defined(gcc) or defined(clang)) and
  not defined(js) and not defined(nimWsFramePortable)

when wsFrameUseSse2:
  import nimsimd/sse2

proc fillWsRandom(buf: var openArray[byte]) {.inline.} =
  if not urandom(buf):
    raise newException(OSError, "secure random source unavailable")

proc applyWsMask*(buf: ptr byte, n: int, key: array[4, byte]) {.inline.} =
  ## XOR `buf[0..n)` in place with the repeating 4-byte WebSocket mask key.
  ## SSE2 (nimsimd) processes 16 bytes per vector; a scalar tail handles the rest.
  let p = cast[ptr byte](buf)
  when wsFrameUseSse2:
    var k16: array[16, byte]
    for r in 0 .. 3:
      k16[r*4+0] = key[0]
      k16[r*4+1] = key[1]
      k16[r*4+2] = key[2]
      k16[r*4+3] = key[3]
    let vk = mm_loadu_si128(cast[ptr uint64](unsafeAddr k16[0]))
    var i = 0
    while i + 16 <= n:
      let off = cast[uint](p) + uint(i)
      let v = mm_loadu_si128(cast[ptr uint64](off))
      mm_storeu_si128(cast[ptr uint64](off), mm_xor_si128(v, vk))
      i += 16
    while i < n:
      let q = cast[ptr byte](cast[uint](p) + uint(i))
      q[] = q[] xor key[i mod 4]
      inc i
  else:
    var i = 0
    while i < n:
      let q = cast[ptr byte](cast[uint](p) + uint(i))
      q[] = q[] xor key[i mod 4]
      inc i

type
  WsFrameParser* = object
    state*: WsParseState
    frame*: WsFrame
    payloadRead*: int
    headerBuf*: array[14, byte]
    headerRead*: int
    headerNeeded*: int
    payloadLen*: uint64

  WsParseState* = enum
    wpsHeader
    wpsPayload
    wpsDone

## Create a fresh incremental WebSocket frame parser in the header state.
proc initWsFrameParser*(): WsFrameParser {.inline.} =
  result.state = wpsHeader
  result.headerNeeded = 2

## Generate a random base64-encoded client Sec-WebSocket-Key.
proc generateWebSocketKey*(): string =
  var buf: array[16, byte]
  fillWsRandom(buf)
  base64.encode(buf)

## Compute the Sec-WebSocket-Accept value for a client key using the WebSocket GUID.
proc webSocketAccept*(clientKey: string): string =
  const Guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  let digest = Sha1Digest(secureHash(clientKey & Guid))
  var raw = newString(digest.len)
  for i in 0 ..< digest.len:
    raw[i] = char(digest[i])
  base64.encode(raw)

## Parse a ws or wss URL into scheme, host, port, and path components.
proc parseWsUrl*(urlStr: string): tuple[scheme: string, host: string, port: uint16, path: string, valid: bool] =
  result.valid = false
  var pos = 0
  let schemeEnd = urlStr.find("://")
  if schemeEnd >= 0:
    var rawScheme = urlStr[0 ..< schemeEnd]
    for i in 0 ..< rawScheme.len:
      let c = rawScheme[i]
      if c >= 'A' and c <= 'Z':
        rawScheme[i] = chr(ord(c) + 32)
    result.scheme = rawScheme
    pos = schemeEnd + 3
  else:
    result.scheme = "ws"

  if result.scheme != "ws" and result.scheme != "wss":
    return

  let hostStart = pos
  var hostEnd = hostStart
  var portStart = -1
  while hostEnd < urlStr.len:
    let c = urlStr[hostEnd]
    if c == ':':
      portStart = hostEnd + 1
      hostEnd += 1
      break
    elif c == '/' or c == '?' or c == '#':
      break
    hostEnd += 1
  result.host = urlStr[hostStart ..< hostEnd - (if portStart >= 0: 1 else: 0)]
  if not isValidHost(result.host):
    return

  if portStart >= 0:
    var portEnd = portStart
    var portVal: uint32 = 0
    var sawDigit = false
    while portEnd < urlStr.len and urlStr[portEnd] >= '0' and urlStr[portEnd] <= '9':
      sawDigit = true
      portVal = portVal * 10 + uint32(ord(urlStr[portEnd]) - ord('0'))
      if portVal > 65535:
        return
      portEnd += 1
    if not sawDigit or not isValidPort(uint16(portVal)):
      return
    result.port = uint16(portVal)
    pos = portEnd
  else:
    pos = hostEnd
    result.port = if result.scheme == "wss": 443'u16 else: 80'u16

  if pos < urlStr.len:
    let fragmentStart = urlStr.find('#', pos)
    let pathEnd = if fragmentStart >= 0: fragmentStart else: urlStr.len
    let rawPath =
      if pathEnd > pos:
        urlStr[pos ..< pathEnd]
      else:
        ""
    result.path =
      if rawPath.len == 0:
        "/"
      elif rawPath[0] == '?':
        "/" & rawPath
      else:
        rawPath
  else:
    result.path = "/"
  if containsCRLF(result.path) or not isValidPath(result.path):
    return

  result.valid = true

proc isForbiddenWsHeader(name: string): bool {.inline.} =
  let lower = name.toLowerAscii()
  lower == "host" or lower == "upgrade" or lower == "connection" or
    lower == "sec-websocket-key" or lower == "sec-websocket-version" or
    lower == "sec-websocket-protocol"

## Build a validated HTTP/1.1 WebSocket upgrade request message.
proc buildUpgradeRequest*(host: string, path: string, port: uint16, key: string,
                          subprotocols: openArray[string] = [],
                          headers: openArray[(string, string)] = [],
                          useSsl: bool = false): string =
  if containsCRLF(host) or containsCRLF(key):
    return ""
  if not isValidHost(host) or not isValidPath(path):
    return ""
  if key.len == 0:
    return ""
  for protocol in subprotocols:
    if protocol.len == 0 or containsCRLF(protocol) or not isValidHeaderValue(protocol):
      return ""
  for h in headers:
    if isForbiddenWsHeader(h[0]) or not isValidHeaderName(h[0]) or not isValidHeaderValue(h[1]):
      return ""

  result = newStringOfCap(512)
  result.add "GET "
  result.add path
  result.add " HTTP/1.1\r\n"
  result.add "Host: "
  result.add authorityForRequest(host, port, useSsl)
  result.add "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: "
  result.add key
  result.add "\r\nSec-WebSocket-Version: 13\r\n"
  if subprotocols.len > 0:
    result.add "Sec-WebSocket-Protocol: "
    for i, protocol in subprotocols:
      if i > 0:
        result.add ", "
      result.add protocol
    result.add "\r\n"
  for h in headers:
    result.add h[0]
    result.add ": "
    result.add h[1]
    result.add "\r\n"
  result.add "\r\n"

## Encode a WebSocket frame with an optional fin flag and payload masking.
proc encodeWsFrame*(opcode: WsOpcode, payload: string, fin: bool = true, masked: bool = true): string =
  result = newStringOfCap(14 + payload.len)
  var b0 = uint8(ord(opcode))
  if fin:
    b0 = b0 or 0x80
  result.add char(b0)

  let maskBit: uint8 = if masked: 0x80 else: 0
  if payload.len < 126:
    result.add char(maskBit or uint8(payload.len))
  elif payload.len < 65536:
    result.add char(maskBit or 126'u8)
    result.add char(uint8((payload.len shr 8) and 0xFF))
    result.add char(uint8(payload.len and 0xFF))
  else:
    result.add char(maskBit or 127'u8)
    for i in countdown(7, 0):
      result.add char(uint8((payload.len shr (i * 8)) and 0xFF))

  if masked:
    var maskKey: array[4, byte]
    fillWsRandom(maskKey)
    for b in maskKey:
      result.add char(b)
    var maskedPayload = newString(payload.len)
    if payload.len > 0:
      copyMem(addr maskedPayload[0], unsafeAddr payload[0], payload.len)
      applyWsMask(cast[ptr byte](addr maskedPayload[0]), payload.len, maskKey)
    result.add maskedPayload
  else:
    result.add payload

proc validCloseReasonPrefixLen(reason: string, maxBytes: int): int {.inline.} =
  result = min(reason.len, maxBytes)
  while result > 0:
    if reason[0 ..< result].validateUtf8() == -1:
      return
    dec result

## Encode a close frame carrying a close code and optional reason.
proc encodeCloseFrame*(code: uint16 = 1000, reason: string = "", masked: bool = true): string =
  const MaxCloseReasonLen = 123
  let reasonLen = validCloseReasonPrefixLen(reason, MaxCloseReasonLen)
  var payload = newStringOfCap(2 + reasonLen)
  payload.add char(uint8(code shr 8))
  payload.add char(uint8(code and 0xFF))
  if reasonLen > 0:
    payload.add reason[0 ..< reasonLen]
  encodeWsFrame(woClose, payload, masked = masked)

## Encode a ping control frame with an optional payload.
proc encodePingFrame*(payload: string = "", masked: bool = true): string =
  encodeWsFrame(woPing, payload, masked = masked)

## Encode a pong control frame with an optional payload.
proc encodePongFrame*(payload: string = "", masked: bool = true): string =
  encodeWsFrame(woPong, payload, masked = masked)

## Decode one complete WebSocket frame from a byte buffer, advancing the position.
proc decodeWsFrame*(data: openArray[byte], pos: var int): Option[WsFrame] =
  if data.len - pos < 2:
    return none(WsFrame)

  let b0 = data[pos]
  let b1 = data[pos + 1]
  let fin = (b0 and 0x80) != 0
  if (b0 and 0x70) != 0:
    return none(WsFrame)
  let opcodeVal = b0 and 0x0F
  let opcode = case opcodeVal
    of 0: woContinuation
    of 1: woText
    of 2: woBinary
    of 8: woClose
    of 9: woPing
    of 0xA: woPong
    else: return none(WsFrame)
  if isControlFrame(int(opcodeVal)) and not fin:
    return none(WsFrame)
  let masked = (b1 and 0x80) != 0
  let lenCode = b1 and 0x7F
  var payloadLen = uint64(lenCode)
  var headerSize = 2

  if not isValidWsPayloadLen(int(opcodeVal), int(payloadLen)):
    return none(WsFrame)

  if lenCode == 126:
    if data.len - pos < 4:
      return none(WsFrame)
    payloadLen = (uint64(data[pos + 2]) shl 8) or uint64(data[pos + 3])
    if payloadLen < 126'u64:
      return none(WsFrame)
    headerSize = 4
  elif lenCode == 127:
    if data.len - pos < 10:
      return none(WsFrame)
    if (data[pos + 2] and 0x80'u8) != 0:
      return none(WsFrame)
    payloadLen = 0
    for i in 0..7:
      payloadLen = (payloadLen shl 8) or uint64(data[pos + 2 + i])
    if payloadLen < 65536'u64:
      return none(WsFrame)
    headerSize = 10

  if payloadLen > 134217728'u64:
    return none(WsFrame)

  var maskKey: array[4, byte]
  if masked:
    if data.len - pos < headerSize + 4:
      return none(WsFrame)
    for i in 0..3:
      maskKey[i] = data[pos + headerSize + i]
    headerSize += 4

  let totalSize = headerSize + int(payloadLen)
  if data.len - pos < totalSize:
    return none(WsFrame)

  var payload = newString(int(payloadLen))
  if payloadLen > 0:
    copyMem(addr payload[0], unsafeAddr data[pos + headerSize], int(payloadLen))
    if masked:
      applyWsMask(cast[ptr byte](addr payload[0]), int(payloadLen), maskKey)

  pos += totalSize
  some(WsFrame(fin: fin, opcode: opcode, masked: masked, maskKey: maskKey, payload: payload))

proc headerValue(headers: string, name: string): string =
  let expected = name.toLowerAscii()
  var start = 0
  while start < headers.len:
    let eol = headers.find("\r\n", start)
    if eol < 0:
      break
    let line = headers[start ..< eol]
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].toLowerAscii() == expected:
      return line[colon + 1 ..< line.len].strip()
    start = eol + 2
  ""

proc connectionHasUpgrade(value: string): bool =
  for part in value.split(','):
    if part.strip().toLowerAscii() == "upgrade":
      return true
  false

## Verify a 101 upgrade response and that its Sec-WebSocket-Accept matches the client key.
proc validateUpgradeResponse*(response: string, clientKey: string): bool =
  let firstLineEnd = response.find("\r\n")
  if firstLineEnd <= 0:
    return false
  let statusLine = response[0 ..< firstLineEnd]
  let statusParts = statusLine.split(' ')
  if not statusLine.startsWith("HTTP/") or statusParts.len < 2 or statusParts[1] != "101":
    return false
  let upgrade = headerValue(response, "Upgrade").toLowerAscii()
  if upgrade != "websocket":
    return false
  if not connectionHasUpgrade(headerValue(response, "Connection")):
    return false
  headerValue(response, "Sec-WebSocket-Accept") == webSocketAccept(clientKey)

## Verify a 101 upgrade response without checking the accept key.
proc validateUpgradeResponse*(response: string): bool =
  let firstLineEnd = response.find("\r\n")
  if firstLineEnd <= 0:
    return false
  let statusLine = response[0 ..< firstLineEnd]
  let statusParts = statusLine.split(' ')
  if not statusLine.startsWith("HTTP/") or statusParts.len < 2 or statusParts[1] != "101":
    return false
  if headerValue(response, "Upgrade").toLowerAscii() != "websocket":
    return false
  connectionHasUpgrade(headerValue(response, "Connection"))

## Extract the server-selected Sec-WebSocket-Protocol value from a response.
proc selectedSubprotocol*(response: string): string =
  headerValue(response, "Sec-WebSocket-Protocol")
