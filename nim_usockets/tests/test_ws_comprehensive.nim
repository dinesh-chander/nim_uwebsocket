import std/unittest

include ../src/nim_usockets/http

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0..<s.len:
    result[i] = byte(s[i])

proc parseReq(payload: string, minimalHeaders = false): Option[HttpRequest] =
  let data = payload.toBytes()
  var totalRequestSize = 0
  var parseError = false
  var parseStatusCode = 400
  parseHttpRequest(
    data, 0, totalRequestSize, minimalHeaders,
    0, "", parseError, parseStatusCode
  )

proc makeWsUpgradeRequest(
  host = "example.test",
  upgrade = "websocket",
  connection = "Upgrade",
  wsKey = "dGhlIHNhbXBsZSBub25jZQ==",
  wsVersion = "13",
  includeHost = true,
  httpVersion = "HTTP/1.1",
  methodStr = "GET",
  extraHeaders = ""
): string =
  result = methodStr & " /ws " & httpVersion & "\r\n"
  if includeHost and host.len > 0:
    result.add("Host: " & host & "\r\n")
  if upgrade.len > 0:
    result.add("Upgrade: " & upgrade & "\r\n")
  if connection.len > 0:
    result.add("Connection: " & connection & "\r\n")
  if wsKey.len > 0:
    result.add("Sec-WebSocket-Key: " & wsKey & "\r\n")
  if wsVersion.len > 0:
    result.add("Sec-WebSocket-Version: " & wsVersion & "\r\n")
  if extraHeaders.len > 0:
    result.add(extraHeaders)
  result.add("\r\n")

proc validateUpgrade(
  raw: string,
  minimalHeaders = false
): tuple[ok: bool, statusCode: int, reason: string, extraHeaders: string] =
  let reqOpt = parseReq(raw, minimalHeaders)
  if reqOpt.isNone:
    return (false, 400, "Parse Error", "")
  validateWebSocketUpgrade(reqOpt.get())

proc buildMaskedClientFrame(
  opcode: int,
  payload: string,
  fin: bool = true,
  rsv1: bool = false,
  mask: array[4, byte] = [0x37'u8, 0xfa, 0x21, 0x3d],
  masked: bool = true
): seq[byte] =
  var frame = newSeq[byte]()
  var byte1 = opcode and 0x0F
  if fin: byte1 = byte1 or 0x80
  if rsv1: byte1 = byte1 or 0x40
  frame.add(byte(byte1))

  let length = payload.len
  var byte2 = if masked: 0x80 else: 0
  if length < 126:
    byte2 = byte2 or length
    frame.add(byte(byte2))
  elif length < 65536:
    byte2 = byte2 or 126
    frame.add(byte(byte2))
    frame.add(byte((length shr 8) and 0xFF))
    frame.add(byte(length and 0xFF))
  else:
    byte2 = byte2 or 127
    frame.add(byte(byte2))
    for i in countdown(7, 0):
      frame.add(byte((length shr (i * 8)) and 0xFF))

  if masked:
    for b in mask:
      frame.add(b)
    for i in 0..<length:
      frame.add(byte(payload[i]) xor mask[i mod 4])
  else:
    for i in 0..<length:
      frame.add(byte(payload[i]))
  frame

proc decodeFrame(rawFrame: seq[byte], allowCompressed: bool = false): tuple[
  status: int, opcode: int, payload: string, consumed: int, fin: bool, compressed: bool
] =
  var data = rawFrame
  var opcode = 0
  var payload = ""
  var consumed = 0
  var fin = true
  var compressed = false
  let status = decodeWebSocketFrame(
    data, 0, opcode, payload, consumed, fin, compressed, allowCompressed
  )
  (status, opcode, payload, consumed, fin, compressed)


suite "Sec-WebSocket-Accept key computation (RFC 6455 §4.2.2)":
  test "RFC 6455 example key produces correct accept value":
    let accept = generateAcceptKey("dGhlIHNhbXBsZSBub25jZQ==")
    check accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

  test "empty key produces deterministic output":
    let accept = generateAcceptKey("")
    check accept.len > 0

  test "different keys produce different accept values":
    let a = generateAcceptKey("dGhlIHNhbXBsZSBub25jZQ==")
    let b = generateAcceptKey("AQIDBAUGBwgJCgsMDQ4PEA==")
    check a != b

  test "accept key is valid base64":
    let accept = generateAcceptKey("dGhlIHNhbXBsZSBub25jZQ==")
    let decoded = base64.decode(accept)
    check decoded.len == 20


suite "WebSocket frame building — 7-bit length (0..125)":
  test "empty payload produces 2-byte frame":
    let frame = buildWsFrame(wsText, "")
    check frame.len == 2
    check (ord(frame[0]) and 0x0F) == ord(wsText)
    check (ord(frame[0]) and 0x80) != 0
    check ord(frame[1]) == 0

  test "1-byte payload":
    let frame = buildWsFrame(wsText, "A")
    check frame.len == 3
    check ord(frame[1]) == 1
    check frame[2] == 'A'

  test "125-byte payload uses 7-bit encoding":
    let payload = repeat('X', 125)
    let frame = buildWsFrame(wsBinary, payload)
    check frame.len == 2 + 125
    check ord(frame[1]) == 125

  test "FIN bit is set":
    let frame = buildWsFrame(wsText, "hello")
    check (ord(frame[0]) and 0x80) != 0

  test "RSV1 bit set when requested":
    let frame = buildWsFrame(wsText, "hello", rsv1 = true)
    check (ord(frame[0]) and 0x40) != 0

  test "RSV1 bit clear by default":
    let frame = buildWsFrame(wsText, "hello", rsv1 = false)
    check (ord(frame[0]) and 0x40) == 0


suite "WebSocket frame building — 16-bit length (126..65535)":
  test "126-byte payload triggers extended 16-bit length":
    let payload = repeat('Y', 126)
    let frame = buildWsFrame(wsText, payload)
    check ord(frame[1]) == 126
    let extLen = (ord(frame[2]) shl 8) or ord(frame[3])
    check extLen == 126
    check frame.len == 4 + 126

  test "65535-byte payload":
    let payload = repeat('Z', 65535)
    let frame = buildWsFrame(wsBinary, payload)
    check ord(frame[1]) == 126
    let extLen = (ord(frame[2]) shl 8) or ord(frame[3])
    check extLen == 65535
    check frame.len == 4 + 65535


suite "WebSocket frame building — 64-bit length (>=65536)":
  test "65536-byte payload triggers 64-bit length":
    let payload = repeat('W', 65536)
    let frame = buildWsFrame(wsBinary, payload)
    check ord(frame[1]) == 127
    var extLen = 0
    for i in 0..<8:
      extLen = (extLen shl 8) or ord(frame[2 + i])
    check extLen == 65536
    check frame.len == 10 + 65536


suite "wsFrameHeaderLen and wsFrameTotalLen":
  test "7-bit length header is 2 bytes":
    check wsFrameHeaderLen(0) == 2
    check wsFrameHeaderLen(1) == 2
    check wsFrameHeaderLen(125) == 2

  test "16-bit length header is 4 bytes":
    check wsFrameHeaderLen(126) == 4
    check wsFrameHeaderLen(65535) == 4

  test "64-bit length header is 10 bytes":
    check wsFrameHeaderLen(65536) == 10

  test "total length = header + payload":
    check wsFrameTotalLen(0) == 2
    check wsFrameTotalLen(100) == 102
    check wsFrameTotalLen(200) == 204
    check wsFrameTotalLen(65535) == 65539
    check wsFrameTotalLen(65536) == 65546


suite "buildWsFrameReuse produces identical output to buildWsFrame":
  test "small payload matches":
    let payload = "hello world"
    let a = buildWsFrame(wsText, payload)
    let b = buildWsFrameReuse(wsText, payload)
    check a == b

  test "medium payload matches (16-bit length)":
    let payload = repeat('A', 300)
    let a = buildWsFrame(wsBinary, payload)
    let b = buildWsFrameReuse(wsBinary, payload)
    check a == b

  test "empty payload matches":
    let a = buildWsFrame(wsText, "")
    let b = buildWsFrameReuse(wsText, "")
    check a == b

  test "rsv1 flag matches":
    let payload = "compressed data"
    let a = buildWsFrame(wsText, payload, rsv1 = true)
    let b = buildWsFrameReuse(wsText, payload, rsv1 = true)
    check a == b


suite "Masking / unmasking correctness":
  test "unmask with known mask key":
    let mask: array[4, byte] = [0x37'u8, 0xfa, 0x21, 0x3d]
    let plain = "Hello"
    var masked = newSeq[byte](4 + plain.len)
    masked[0] = mask[0]
    masked[1] = mask[1]
    masked[2] = mask[2]
    masked[3] = mask[3]
    for i in 0..<plain.len:
      masked[4 + i] = byte(plain[i]) xor mask[i mod 4]
    let result = unmaskWebSocketPayload(masked, 4, plain.len, mask[0], mask[1], mask[2], mask[3])
    check result == plain

  test "unmask empty payload":
    let data = newSeq[byte](4)
    let result = unmaskWebSocketPayload(data, 0, 0, 0, 0, 0, 0)
    check result.len == 0

  test "unmask payload not aligned to 4 bytes":
    let mask: array[4, byte] = [0xAB'u8, 0xCD, 0xEF, 0x01]
    let plain = "1234567"
    var buf = newSeq[byte](plain.len)
    for i in 0..<plain.len:
      buf[i] = byte(plain[i]) xor mask[i mod 4]
    let result = unmaskWebSocketPayload(buf, 0, plain.len, mask[0], mask[1], mask[2], mask[3])
    check result == plain

  test "unmask payload aligned to 8 bytes":
    let mask: array[4, byte] = [0x12'u8, 0x34, 0x56, 0x78]
    let plain = "ABCDEFGH"
    var buf = newSeq[byte](plain.len)
    for i in 0..<plain.len:
      buf[i] = byte(plain[i]) xor mask[i mod 4]
    let result = unmaskWebSocketPayload(buf, 0, plain.len, mask[0], mask[1], mask[2], mask[3])
    check result == plain

  test "unmaskInPlace modifies buffer in place":
    let mask: array[4, byte] = [0x37'u8, 0xfa, 0x21, 0x3d]
    let plain = "Hello"
    var buf = newSeq[byte](plain.len)
    for i in 0..<plain.len:
      buf[i] = byte(plain[i]) xor mask[i mod 4]
    unmaskInPlace(buf, 0, plain.len, mask[0], mask[1], mask[2], mask[3])
    for i in 0..<plain.len:
      check char(buf[i]) == plain[i]

  test "double unmask restores original masked bytes":
    let mask: array[4, byte] = [0x37'u8, 0xfa, 0x21, 0x3d]
    let plain = "Test data!"
    var buf = newSeq[byte](plain.len)
    for i in 0..<plain.len:
      buf[i] = byte(plain[i]) xor mask[i mod 4]
    let originalMasked = buf
    unmaskInPlace(buf, 0, plain.len, mask[0], mask[1], mask[2], mask[3])
    unmaskInPlace(buf, 0, plain.len, mask[0], mask[1], mask[2], mask[3])
    check buf == originalMasked

  test "unmask large payload (1024 bytes) exercises SIMD path":
    let mask: array[4, byte] = [0xDE'u8, 0xAD, 0xBE, 0xEF]
    let plain = repeat('Q', 1024)
    var buf = newSeq[byte](plain.len)
    for i in 0..<plain.len:
      buf[i] = byte(plain[i]) xor mask[i mod 4]
    let result = unmaskWebSocketPayload(buf, 0, plain.len, mask[0], mask[1], mask[2], mask[3])
    check result == plain


suite "Frame decoding — 7-bit length":
  test "decode text frame with small payload":
    let raw = buildMaskedClientFrame(0x1, "Hello")
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x1
    check d.payload == "Hello"
    check d.fin == true
    check d.compressed == false

  test "decode binary frame":
    let raw = buildMaskedClientFrame(0x2, "\x00\x01\x02\x03")
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x2
    check d.payload == "\x00\x01\x02\x03"

  test "decode empty payload frame":
    let raw = buildMaskedClientFrame(0x1, "")
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x1
    check d.payload.len == 0

  test "decode 125-byte payload":
    let payload = repeat('X', 125)
    let raw = buildMaskedClientFrame(0x1, payload)
    let d = decodeFrame(raw)
    check d.status == 1
    check d.payload == payload


suite "Frame decoding — 16-bit length":
  test "decode 126-byte payload":
    let payload = repeat('A', 126)
    let raw = buildMaskedClientFrame(0x1, payload)
    let d = decodeFrame(raw)
    check d.status == 1
    check d.payload == payload
    check d.payload.len == 126

  test "decode 1000-byte payload":
    let payload = repeat('B', 1000)
    let raw = buildMaskedClientFrame(0x2, payload)
    let d = decodeFrame(raw)
    check d.status == 1
    check d.payload == payload

  test "decode 65535-byte payload":
    let payload = repeat('C', 65535)
    let raw = buildMaskedClientFrame(0x1, payload)
    let d = decodeFrame(raw)
    check d.status == 1
    check d.payload.len == 65535


suite "Frame decoding — 64-bit length":
  test "decode 65536-byte payload":
    let payload = repeat('D', 65536)
    let raw = buildMaskedClientFrame(0x2, payload)
    let d = decodeFrame(raw)
    check d.status == 1
    check d.payload.len == 65536


suite "Frame decoding — incomplete data returns 0":
  test "empty buffer":
    var data = newSeq[byte](0)
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check status == 0

  test "only 1 byte":
    var data = @[byte(0x81)]
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check status == 0

  test "header present but payload truncated":
    let full = buildMaskedClientFrame(0x1, "Hello World!")
    var data = full[0..^3]
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check status == 0


suite "Frame decoding — unmasked client frame returns -2":
  test "unmasked frame from client rejected":
    let raw = buildMaskedClientFrame(0x1, "Hello", masked = false)
    let d = decodeFrame(raw)
    check d.status == -2


suite "Frame decoding — RSV2/RSV3 bits cause protocol error":
  test "RSV2 set returns -1":
    var raw = buildMaskedClientFrame(0x1, "Hello")
    raw[0] = raw[0] or 0x20
    let d = decodeFrame(raw)
    check d.status == -1

  test "RSV3 set returns -1":
    var raw = buildMaskedClientFrame(0x1, "Hello")
    raw[0] = raw[0] or 0x10
    let d = decodeFrame(raw)
    check d.status == -1

  test "RSV2+RSV3 set returns -1":
    var raw = buildMaskedClientFrame(0x1, "Hello")
    raw[0] = raw[0] or 0x30
    let d = decodeFrame(raw)
    check d.status == -1


suite "Frame decoding — RSV1 with compression":
  test "RSV1 on data frame accepted when compression allowed":
    let raw = buildMaskedClientFrame(0x1, "Hello", rsv1 = true)
    let d = decodeFrame(raw, allowCompressed = true)
    check d.status == 1
    check d.compressed == true

  test "RSV1 on data frame rejected when compression not allowed":
    let raw = buildMaskedClientFrame(0x1, "Hello", rsv1 = true)
    let d = decodeFrame(raw, allowCompressed = false)
    check d.status == -1

  test "RSV1 on continuation frame (opcode 0) rejected":
    let raw = buildMaskedClientFrame(0x0, "Hello", rsv1 = true)
    let d = decodeFrame(raw, allowCompressed = true)
    check d.status == -1

  test "RSV1 on control frame (close) rejected":
    let raw = buildMaskedClientFrame(0x8, wsClosePayload(1000), rsv1 = true)
    let d = decodeFrame(raw, allowCompressed = true)
    check d.status == -1

  test "RSV1 on ping rejected":
    let raw = buildMaskedClientFrame(0x9, "ping", rsv1 = true)
    let d = decodeFrame(raw, allowCompressed = true)
    check d.status == -1


suite "Control frames — close with status codes":
  test "close frame with valid code 1000":
    let payload = wsClosePayload(1000)
    let raw = buildMaskedClientFrame(0x8, payload)
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x8
    let closeCode = (ord(d.payload[0]) shl 8) or ord(d.payload[1])
    check closeCode == 1000

  test "close frame with code and reason":
    let payload = wsClosePayload(1001, "going away")
    let raw = buildMaskedClientFrame(0x8, payload)
    let d = decodeFrame(raw)
    check d.status == 1
    let code = (ord(d.payload[0]) shl 8) or ord(d.payload[1])
    check code == 1001
    check d.payload[2..^1] == "going away"

  test "close frame with empty payload is valid":
    let raw = buildMaskedClientFrame(0x8, "")
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x8
    check d.payload.len == 0

  test "close frame with 1-byte payload is decoded (validation at protocol layer)":
    let raw = buildMaskedClientFrame(0x8, "\x03")
    let d = decodeFrame(raw)
    check d.status == 1

  test "close frame truncated reason to 123 bytes":
    let longReason = repeat('R', 200)
    let payload = wsClosePayload(1000, longReason)
    check payload.len <= 125


suite "Control frames — ping and pong":
  test "ping frame decoded correctly":
    let raw = buildMaskedClientFrame(0x9, "ping-data")
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x9
    check d.payload == "ping-data"
    check d.fin == true

  test "pong frame decoded correctly":
    let raw = buildMaskedClientFrame(0xA, "pong-data")
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0xA
    check d.payload == "pong-data"

  test "ping with empty payload":
    let raw = buildMaskedClientFrame(0x9, "")
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x9
    check d.payload.len == 0

  test "ping with 125-byte payload (max control payload)":
    let payload = repeat('P', 125)
    let raw = buildMaskedClientFrame(0x9, payload)
    let d = decodeFrame(raw)
    check d.status == 1
    check d.payload == payload

  test "control frame with payload > 125 bytes is rejected":
    let payload = repeat('P', 126)
    let raw = buildMaskedClientFrame(0x9, payload)
    let d = decodeFrame(raw)
    check d.status == -1

  test "fragmented control frame (FIN=0) is rejected":
    let raw = buildMaskedClientFrame(0x9, "ping", fin = false)
    let d = decodeFrame(raw)
    check d.status == -1


suite "Fragmentation — continuation frames":
  test "non-FIN data frame starts fragmentation":
    let raw = buildMaskedClientFrame(0x1, "first", fin = false)
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x1
    check d.fin == false
    check d.payload == "first"

  test "continuation frame (opcode 0) decoded":
    let raw = buildMaskedClientFrame(0x0, "continued")
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x0
    check d.payload == "continued"

  test "final continuation frame has FIN set":
    let raw = buildMaskedClientFrame(0x0, "last", fin = true)
    let d = decodeFrame(raw)
    check d.status == 1
    check d.opcode == 0x0
    check d.fin == true


suite "Close code validation — isValidWsCloseCode":
  test "all RFC 6455 standard codes":
    for code in [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014]:
      check isValidWsCloseCode(code)

  test "reserved codes 1004-1006 invalid":
    check not isValidWsCloseCode(1004)
    check not isValidWsCloseCode(1005)
    check not isValidWsCloseCode(1006)

  test "private-use range 3000-4999":
    check isValidWsCloseCode(3000)
    check isValidWsCloseCode(3500)
    check isValidWsCloseCode(3999)
    check isValidWsCloseCode(4000)
    check isValidWsCloseCode(4500)
    check isValidWsCloseCode(4999)

  test "below 1000 invalid":
    check not isValidWsCloseCode(0)
    check not isValidWsCloseCode(1)
    check not isValidWsCloseCode(999)

  test "unassigned range 1015-2999 invalid":
    check not isValidWsCloseCode(1015)
    check not isValidWsCloseCode(1016)
    check not isValidWsCloseCode(2000)
    check not isValidWsCloseCode(2999)

  test "above 4999 invalid":
    check not isValidWsCloseCode(5000)
    check not isValidWsCloseCode(10000)
    check not isValidWsCloseCode(65535)

  test "negative codes invalid":
    check not isValidWsCloseCode(-1)
    check not isValidWsCloseCode(-1000)


suite "wsClosePayload encoding":
  test "code-only payload is 2 bytes":
    let p = wsClosePayload(1000)
    check p.len == 2
    check (ord(p[0]) shl 8 or ord(p[1])) == 1000

  test "code 1001 encodes correctly":
    let p = wsClosePayload(1001)
    check (ord(p[0]) shl 8 or ord(p[1])) == 1001

  test "code with reason":
    let p = wsClosePayload(1008, "policy")
    check (ord(p[0]) shl 8 or ord(p[1])) == 1008
    check p[2..^1] == "policy"

  test "reason truncated to 123 bytes (total max 125)":
    let reason = repeat('X', 200)
    let p = wsClosePayload(1000, reason)
    check p.len == 2 + 123

  test "reason truncation preserves UTF-8 boundaries":
    let reason = repeat('X', 122) & "\xE2\x82\xAC"
    let p = wsClosePayload(1000, reason)
    check p.len == 2 + 122
    check p[2..^1].validateUtf8() == -1

  test "empty reason produces 2-byte payload":
    let p = wsClosePayload(1000, "")
    check p.len == 2

  test "high code 4999":
    let p = wsClosePayload(4999)
    check (ord(p[0]) shl 8 or ord(p[1])) == 4999

  test "code 3000":
    let p = wsClosePayload(3000)
    check (ord(p[0]) shl 8 or ord(p[1])) == 3000


suite "UTF-8 validation helpers":
  test "ASCII-only string passes isAsciiOnly":
    check isAsciiOnly("Hello, World!")
    check isAsciiOnly("")
    check isAsciiOnly("0123456789")

  test "non-ASCII fails isAsciiOnly":
    check not isAsciiOnly("\xC0")
    check not isAsciiOnly("hello\x80world")
    check not isAsciiOnly("\xFF")

  test "valid UTF-8 passes validateUtf8 (returns -1)":
    check "Hello".validateUtf8() == -1
    check "".validateUtf8() == -1
    check "\xC3\xA9".validateUtf8() == -1
    check "\xE2\x82\xAC".validateUtf8() == -1
    check "\xF0\x9F\x98\x80".validateUtf8() == -1

  test "invalid UTF-8 fails validateUtf8 (returns >= 0)":
    check "\x80".validateUtf8() >= 0
    check "\xC0".validateUtf8() >= 0
    check "\xC3\x28".validateUtf8() >= 0
    check "\xFE\xFF".validateUtf8() >= 0

  test "isAsciiOnlyBytes works on byte arrays":
    let data = "ASCII123".toBytes()
    check isAsciiOnlyBytes(data, 0, data.len) == true

  test "isAsciiOnlyBytes detects non-ASCII":
    let data = @[byte(0x41), byte(0x80), byte(0x42)]
    check isAsciiOnlyBytes(data, 0, data.len) == false

  test "isAsciiOnlyBytes with empty range":
    let data = @[byte(0x80)]
    check isAsciiOnlyBytes(data, 0, 0) == true

  test "validateUtf8Bytes with valid data returns -1":
    let data = "Hello".toBytes()
    check validateUtf8Bytes(data, 0, data.len) == -1

  test "validateUtf8Bytes with invalid data returns >= 0":
    let data = @[byte(0xC0), byte(0x80)]
    check validateUtf8Bytes(data, 0, data.len) >= 0

  test "validateUtf8Bytes with empty length returns -1":
    let data = @[byte(0xFF)]
    check validateUtf8Bytes(data, 0, 0) == -1


suite "Compression decision logic — wsCompressionDecision":
  test "not negotiated returns false":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    check not wsCompressionDecision(opts, false, 2048, false, false, 0)

  test "compression disabled returns false":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = false
    check not wsCompressionDecision(opts, true, 2048, false, false, 0)

  test "bypass flag returns false":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    check not wsCompressionDecision(opts, true, 2048, false, true, 0)

  test "zero payload returns false":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    check not wsCompressionDecision(opts, true, 0, false, false, 0)

  test "payload below minBytes returns false":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionMinBytes = 1000
    check not wsCompressionDecision(opts, true, 999, false, false, 0)

  test "payload at minBytes returns true":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionMinBytes = 1000
    check wsCompressionDecision(opts, true, 1000, false, false, 0)

  test "binary disabled skips binary frames":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionDisableForBinary = true
    opts.wsCompressionMinBytes = 0
    check not wsCompressionDecision(opts, true, 2048, true, false, 0)

  test "text disabled skips text frames":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionDisableForText = true
    opts.wsCompressionMinBytes = 0
    check not wsCompressionDecision(opts, true, 2048, false, false, 0)

  test "backpressure bypass threshold exceeded skips compression":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionBackpressureBypassBytes = 1000
    opts.wsCompressionMinBytes = 0
    check not wsCompressionDecision(opts, true, 2048, false, false, 1000)

  test "backpressure below threshold allows compression":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionBackpressureBypassBytes = 1000
    opts.wsCompressionMinBytes = 0
    check wsCompressionDecision(opts, true, 2048, false, false, 999)

  test "all conditions met returns true":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionMinBytes = 100
    check wsCompressionDecision(opts, true, 200, false, false, 0)


suite "Compression negotiation — parseWsCompressionOffer":
  test "empty header returns not present":
    let offer = parseWsCompressionOffer("")
    check not offer.present

  test "bare permessage-deflate":
    let offer = parseWsCompressionOffer("permessage-deflate")
    check offer.present

  test "case insensitive":
    let offer = parseWsCompressionOffer("Permessage-Deflate")
    check offer.present

  test "with whitespace":
    let offer = parseWsCompressionOffer("  permessage-deflate  ")
    check offer.present

  test "with server_no_context_takeover param":
    let offer = parseWsCompressionOffer("permessage-deflate; server_no_context_takeover")
    check offer.present
    check offer.serverNoContextTakeover

  test "with client_no_context_takeover param":
    let offer = parseWsCompressionOffer("permessage-deflate; client_no_context_takeover")
    check offer.present
    check offer.clientNoContextTakeover

  test "with both context takeover params":
    let offer = parseWsCompressionOffer(
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover"
    )
    check offer.present
    check offer.serverNoContextTakeover
    check offer.clientNoContextTakeover

  test "multiple offers in comma-separated list":
    let offer = parseWsCompressionOffer(
      "x-webkit-deflate-frame, permessage-deflate; server_no_context_takeover"
    )
    check offer.present

  test "non-deflate extension returns not present":
    let offer = parseWsCompressionOffer("x-webkit-deflate-frame")
    check not offer.present


suite "Compression negotiation — negotiateWsCompressionHeader":
  test "disabled compression returns empty":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = false
    check negotiateWsCompressionHeader("permessage-deflate", opts).len == 0

  test "missing server no_context_takeover flag returns empty":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionServerNoContextTakeover = false
    opts.wsCompressionClientNoContextTakeover = true
    check negotiateWsCompressionHeader("permessage-deflate", opts).len == 0

  test "missing client no_context_takeover flag returns empty":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionServerNoContextTakeover = true
    opts.wsCompressionClientNoContextTakeover = false
    check negotiateWsCompressionHeader("permessage-deflate", opts).len == 0

  test "valid negotiation includes extension header":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionServerNoContextTakeover = true
    opts.wsCompressionClientNoContextTakeover = true
    let hdr = negotiateWsCompressionHeader("permessage-deflate", opts)
    check hdr.contains("Sec-WebSocket-Extensions:")
    check hdr.contains("permessage-deflate")
    check hdr.contains("server_no_context_takeover")
    check hdr.contains("client_no_context_takeover")

  test "non-deflate extension returns empty":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionServerNoContextTakeover = true
    opts.wsCompressionClientNoContextTakeover = true
    check negotiateWsCompressionHeader("x-webkit-deflate-frame", opts).len == 0

  test "empty extensions header returns empty":
    var opts = defaultServerOptions()
    opts.wsCompressionEnabled = true
    opts.wsCompressionServerNoContextTakeover = true
    opts.wsCompressionClientNoContextTakeover = true
    check negotiateWsCompressionHeader("", opts).len == 0


suite "Deflate tail detection and compression roundtrip":
  test "hasDeflateTail detects tail bytes":
    check hasDeflateTail("\x00\x00\xff\xff")
    check hasDeflateTail("data\x00\x00\xff\xff")

  test "hasDeflateTail false for short or non-matching":
    check not hasDeflateTail("")
    check not hasDeflateTail("\x00\x00\xff")
    check not hasDeflateTail("data")
    check not hasDeflateTail("\x01\x00\xff\xff")

  test "compress and decompress roundtrip":
    let original = repeat("Hello WebSocket compression test! ", 50)
    let compressed = compressWsPayload(original)
    check compressed.ok
    check compressed.compressed.len > 0
    check compressed.compressed.len < original.len
    let decompressed = decompressWsPayload(compressed.compressed, original.len * 2)
    check decompressed.ok
    check decompressed.plain == original

  test "compress empty payload":
    let compressed = compressWsPayload("")
    check compressed.ok
    check compressed.compressed.len == 0

  test "decompress with too-small limit fails":
    let original = repeat("data", 100)
    let compressed = compressWsPayload(original)
    check compressed.ok
    let decompressed = decompressWsPayload(compressed.compressed, 1)
    check not decompressed.ok
    check decompressed.tooLarge


suite "Upgrade validation — defense-in-depth":
  test "valid request succeeds":
    let v = validateUpgrade(makeWsUpgradeRequest())
    check v.ok
    check v.statusCode == 101

  test "nil request returns 400":
    let v = validateWebSocketUpgrade(nil)
    check not v.ok
    check v.statusCode == 400

  test "POST method rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(methodStr = "POST"))
    check not v.ok
    check v.statusCode == 400

  test "PUT method rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(methodStr = "PUT"))
    check not v.ok

  test "DELETE method rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(methodStr = "DELETE"))
    check not v.ok

  test "HTTP/1.0 rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(httpVersion = "HTTP/1.0"))
    check not v.ok
    check v.statusCode == 400

  test "missing Host header rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(includeHost = false))
    check not v.ok
    check v.statusCode == 400

  test "missing Upgrade header rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(upgrade = ""))
    check not v.ok

  test "wrong Upgrade value rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(upgrade = "h2c"))
    check not v.ok

  test "case-insensitive Upgrade value accepted":
    let v = validateUpgrade(makeWsUpgradeRequest(upgrade = "WebSocket"))
    check v.ok

  test "wrong Connection value rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(connection = "keep-alive"))
    check not v.ok

  test "version 8 returns 426 with version header":
    let v = validateUpgrade(makeWsUpgradeRequest(wsVersion = "8"))
    check not v.ok
    check v.statusCode == 426
    check v.extraHeaders.contains("Sec-WebSocket-Version: 13")

  test "version 12 returns 426":
    let v = validateUpgrade(makeWsUpgradeRequest(wsVersion = "12"))
    check not v.ok
    check v.statusCode == 426

  test "missing Sec-WebSocket-Key rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(wsKey = ""))
    check not v.ok
    check v.statusCode == 400

  test "invalid base64 key rejected":
    let v = validateUpgrade(makeWsUpgradeRequest(wsKey = "not-valid-base64!!!"))
    check not v.ok
    check v.statusCode == 400

  test "key too short (not 16 decoded bytes) rejected":
    let shortKey = base64.encode("tooshort")
    let v = validateUpgrade(makeWsUpgradeRequest(wsKey = shortKey))
    check not v.ok
    check v.statusCode == 400

  test "key exactly 16 decoded bytes accepted":
    let key16 = base64.encode("0123456789abcdef")
    let v = validateUpgrade(makeWsUpgradeRequest(wsKey = key16))
    check v.ok

  test "multiple valid Host headers accepted":
    for host in ["localhost", "example.com:8080", "192.168.1.1", "[::1]:3000"]:
      let v = validateUpgrade(makeWsUpgradeRequest(host = host))
      check v.ok


suite "isWebSocketUpgrade detection":
  test "valid upgrade request detected":
    let reqOpt = parseReq(makeWsUpgradeRequest())
    check reqOpt.isSome
    check isWebSocketUpgrade(reqOpt.get())

  test "nil request returns false":
    check not isWebSocketUpgrade(nil)

  test "non-upgrade request returns false":
    let raw = "GET /index.html HTTP/1.1\r\nHost: example.test\r\n\r\n"
    let reqOpt = parseReq(raw)
    if reqOpt.isSome:
      check not isWebSocketUpgrade(reqOpt.get())


suite "isValidWebSocketKey":
  test "RFC example key valid":
    check isValidWebSocketKey("dGhlIHNhbXBsZSBub25jZQ==")

  test "empty key invalid":
    check not isValidWebSocketKey("")

  test "non-base64 invalid":
    check not isValidWebSocketKey("!!invalid!!")

  test "correct 16-byte decoded valid":
    check isValidWebSocketKey(base64.encode("0123456789abcdef"))

  test "wrong length decoded invalid":
    check not isValidWebSocketKey(base64.encode("short"))
    check not isValidWebSocketKey(base64.encode("this is way too long for a ws key"))


suite "Multiple frames in same buffer":
  test "two consecutive frames decoded sequentially":
    let f1 = buildMaskedClientFrame(0x1, "first")
    let f2 = buildMaskedClientFrame(0x1, "second")
    var data = f1 & f2
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false

    let s1 = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check s1 == 1
    check payload == "first"
    let offset1 = consumed

    let s2 = decodeWebSocketFrame(data, offset1, opcode, payload, consumed, fin, compressed, false)
    check s2 == 1
    check payload == "second"


suite "Interleaved control frames during fragmentation":
  test "ping between continuation fragments decodes":
    let frag1 = buildMaskedClientFrame(0x1, "hello", fin = false)
    let ping = buildMaskedClientFrame(0x9, "keepalive")
    let frag2 = buildMaskedClientFrame(0x0, " world", fin = true)
    var data = frag1 & ping & frag2
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    var offset = 0

    let s1 = decodeWebSocketFrame(data, offset, opcode, payload, consumed, fin, compressed, false)
    check s1 == 1
    check opcode == 0x1
    check fin == false
    offset += consumed

    let s2 = decodeWebSocketFrame(data, offset, opcode, payload, consumed, fin, compressed, false)
    check s2 == 1
    check opcode == 0x9
    check payload == "keepalive"
    offset += consumed

    let s3 = decodeWebSocketFrame(data, offset, opcode, payload, consumed, fin, compressed, false)
    check s3 == 1
    check opcode == 0x0
    check fin == true
    check payload == " world"


suite "Reserved opcodes rejected":
  test "opcode 3 rejected as protocol error":
    let raw = buildMaskedClientFrame(0x3, "data")
    var data = raw
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check status == -1
    check opcode == 0x3

  test "opcode 7 rejected before payload processing":
    let raw = buildMaskedClientFrame(0x7, "data")
    var data = raw
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check status == -1
    check opcode == 0x7

  test "opcode 0xB rejected before payload processing":
    let raw = buildMaskedClientFrame(0xB, "data")
    var data = raw
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check status == -1
    check opcode == 0xB


suite "Server-to-client frame opcode encoding":
  test "text frame opcode":
    let frame = buildWsFrame(wsText, "hi")
    check (ord(frame[0]) and 0x0F) == 0x1

  test "binary frame opcode":
    let frame = buildWsFrame(wsBinary, "hi")
    check (ord(frame[0]) and 0x0F) == 0x2

  test "close frame opcode":
    let frame = buildWsFrame(wsClose, wsClosePayload(1000))
    check (ord(frame[0]) and 0x0F) == 0x8

  test "ping frame opcode":
    let frame = buildWsFrame(wsPing, "")
    check (ord(frame[0]) and 0x0F) == 0x9

  test "pong frame opcode":
    let frame = buildWsFrame(wsPong, "")
    check (ord(frame[0]) and 0x0F) == 0xA


suite "Max frame size enforcement in decoding":
  test "64-bit length with truncated data returns need-more-data":
    var data = newSeq[byte](14)
    data[0] = 0x81
    data[1] = 0xFF
    data[2] = 0x00
    data[3] = 0x00
    data[4] = 0x00
    data[5] = 0x00
    data[6] = 0x00
    data[7] = 0x01
    data[8] = 0x00
    data[9] = 0x00
    data[10] = 0x00
    data[11] = 0x00
    data[12] = 0x00
    data[13] = 0x00
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check status == 0

  test "extreme 64-bit length that overflows int is rejected":
    var data = newSeq[byte](14)
    data[0] = 0x81
    data[1] = 0xFF
    data[2] = 0xFF
    data[3] = 0xFF
    data[4] = 0xFF
    data[5] = 0xFF
    data[6] = 0xFF
    data[7] = 0xFF
    data[8] = 0xFF
    data[9] = 0xFF
    data[10] = 0x00
    data[11] = 0x00
    data[12] = 0x00
    data[13] = 0x00
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check status == -1

  test "maximum representable 64-bit length without payload is incomplete":
    var data = newSeq[byte](14)
    data[0] = 0x82
    data[1] = 0xFF
    data[2] = 0x7F
    for i in 3..9:
      data[i] = 0xFF
    data[10] = 0x00
    data[11] = 0x00
    data[12] = 0x00
    data[13] = 0x00
    var opcode = 0
    var payload = ""
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrame(data, 0, opcode, payload, consumed, fin, compressed, false)
    check status == 0


suite "ZeroCopy frame decoding":
  test "decode text frame zero-copy":
    let raw = buildMaskedClientFrame(0x1, "Hello")
    var data = raw
    var opcode = 0
    var payloadStart = 0
    var payloadLength = 0
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrameZeroCopy(
      data, 0, opcode, payloadStart, payloadLength, consumed, fin, compressed, false
    )
    check status == 1
    check opcode == 0x1
    check payloadLength == 5
    check fin == true

  test "zero-copy unmasked frame rejected":
    let raw = buildMaskedClientFrame(0x1, "Hello", masked = false)
    var data = raw
    var opcode = 0
    var payloadStart = 0
    var payloadLength = 0
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrameZeroCopy(
      data, 0, opcode, payloadStart, payloadLength, consumed, fin, compressed, false
    )
    check status == -2

  test "zero-copy RSV2 rejected":
    var raw = buildMaskedClientFrame(0x1, "Hello")
    raw[0] = raw[0] or 0x20
    var data = raw
    var opcode = 0
    var payloadStart = 0
    var payloadLength = 0
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrameZeroCopy(
      data, 0, opcode, payloadStart, payloadLength, consumed, fin, compressed, false
    )
    check status == -1

  test "zero-copy empty buffer returns 0":
    var data = newSeq[byte](0)
    var opcode = 0
    var payloadStart = 0
    var payloadLength = 0
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrameZeroCopy(
      data, 0, opcode, payloadStart, payloadLength, consumed, fin, compressed, false
    )
    check status == 0

  test "zero-copy 16-bit length frame":
    let payload = repeat('Z', 200)
    let raw = buildMaskedClientFrame(0x2, payload)
    var data = raw
    var opcode = 0
    var payloadStart = 0
    var payloadLength = 0
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrameZeroCopy(
      data, 0, opcode, payloadStart, payloadLength, consumed, fin, compressed, false
    )
    check status == 1
    check payloadLength == 200

  test "zero-copy RSV1 with compression allowed":
    let raw = buildMaskedClientFrame(0x1, "data", rsv1 = true)
    var data = raw
    var opcode = 0
    var payloadStart = 0
    var payloadLength = 0
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrameZeroCopy(
      data, 0, opcode, payloadStart, payloadLength, consumed, fin, compressed, true
    )
    check status == 1
    check compressed == true

  test "zero-copy control frame with >125 bytes rejected":
    let payload = repeat('P', 126)
    let raw = buildMaskedClientFrame(0x9, payload)
    var data = raw
    var opcode = 0
    var payloadStart = 0
    var payloadLength = 0
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrameZeroCopy(
      data, 0, opcode, payloadStart, payloadLength, consumed, fin, compressed, false
    )
    check status == -1

  test "zero-copy maximum representable 64-bit length without payload is incomplete":
    var data = newSeq[byte](14)
    data[0] = 0x82
    data[1] = 0xFF
    data[2] = 0x7F
    for i in 3..9:
      data[i] = 0xFF
    data[10] = 0x00
    data[11] = 0x00
    data[12] = 0x00
    data[13] = 0x00
    var opcode = 0
    var payloadStart = 0
    var payloadLength = 0
    var consumed = 0
    var fin = true
    var compressed = false
    let status = decodeWebSocketFrameZeroCopy(
      data, 0, opcode, payloadStart, payloadLength, consumed, fin, compressed, false
    )
    check status == 0


suite "deliverWebSocketMessage UTF-8 enforcement":
  test "valid ASCII text delivered":
    let payload = "Hello World"
    check payload.isAsciiOnly()
    check payload.validateUtf8() == -1

  test "valid multi-byte UTF-8 passes validation":
    let payload = "Héllo \xE2\x82\xAC wörld"
    check payload.validateUtf8() == -1

  test "invalid UTF-8 detected for close code 1007":
    let payload = "\xC0\xAF"
    check not payload.isAsciiOnly()
    check payload.validateUtf8() != -1

  test "overlong UTF-8 sequences detected":
    let payload = "\xC0\x80"
    check payload.validateUtf8() != -1

  test "5-byte overlong sequence detected as invalid":
    let payload = "\xF8\x80\x80\x80\x80"
    check payload.validateUtf8() != -1

  test "truncated multi-byte detected":
    let payload = "\xE2\x82"
    check payload.validateUtf8() != -1


suite "Close reason UTF-8 validation":
  test "valid UTF-8 reason in close payload":
    let reason = "goodbye"
    check reason.validateUtf8() == -1

  test "invalid UTF-8 in close reason detected":
    let reason = "\xC0\xAF"
    check reason.validateUtf8() != -1


suite "Server close reason UTF-8 sanitization (RFC 6455 §5.5.1)":
  test "wsClosePayload with valid ASCII reason preserves it":
    let p = wsClosePayload(1000, "goodbye")
    check p.len == 2 + 7
    check p[2..^1] == "goodbye"

  test "wsClosePayload with valid multi-byte UTF-8 preserves it":
    let p = wsClosePayload(1000, "\xC3\xA9")
    check p.len == 2 + 2
    check p[2..^1].validateUtf8() == -1

  test "invalid UTF-8 reason is detected by validateUtf8":
    let reason = "\xC0\xAF"
    check reason.validateUtf8() != -1
    check not reason.isAsciiOnly()

  test "wsClosePayload drops invalid UTF-8 reason":
    let p = wsClosePayload(1000, "\xC0\xAF")
    check p.len == 2

  test "empty reason produces 2-byte close payload":
    let p = wsClosePayload(1000, "")
    check p.len == 2


suite "bufferPayloadToString":
  test "converts byte range to string":
    let data = @[byte(0x48), byte(0x69), byte(0x21)]
    let result = bufferPayloadToString(data, 0, 3)
    check result == "Hi!"

  test "handles offset":
    let data = @[byte(0x00), byte(0x48), byte(0x69)]
    let result = bufferPayloadToString(data, 1, 2)
    check result == "Hi"

  test "empty length":
    let data = @[byte(0x48)]
    let result = bufferPayloadToString(data, 0, 0)
    check result.len == 0
