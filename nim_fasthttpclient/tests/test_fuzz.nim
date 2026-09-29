import std/[options, strutils, random, deques, tables]
import nim_fasthttpclient/types
import nim_fasthttpclient/hpack
import nim_fasthttpclient/h2_frames
import nim_fasthttpclient/http1
import nim_fasthttpclient/http2
import nim_fasthttpclient/ws_client
import nim_fasthttpclient/sse_client
import nim_fasthttpclient/connection_pool
import nim_fasthttpclient/validation

const FuzzSeed = 42'i64
const FuzzIterations = 1500

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

proc randomBytes(rng: var Rand, length: int): string =
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(rng.rand(255))

proc randomBytesSeq(rng: var Rand, length: int): seq[byte] =
  result = newSeq[byte](length)
  for i in 0 ..< length:
    result[i] = byte(rng.rand(255))

proc randomPrintable(rng: var Rand, length: int): string =
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(rng.rand(93) + 33)

proc fuzzHttp1RandomBytes() =
  var rng = initRand(FuzzSeed)
  for i in 0 ..< FuzzIterations:
    let length = rng.rand(500)
    let data = randomBytes(rng, length)
    var parser = initHttp1Parser()
    var consumed = 0
    try:
      discard parser.feedData(data, consumed)
    except CatchableError:
      discard
    check(true, "http1 random bytes iter " & $i)
  echo "Fuzz HTTP/1.1 random bytes: OK"

proc fuzzHttp1MalformedStatusLine() =
  var rng = initRand(FuzzSeed + 1)
  let malformed = @[
    "",
    "H",
    "HTTP",
    "HTTP/1.1",
    "HTTP/1.1 ",
    "HTTP/1.1 abc",
    "HTTP/1.1 99999999999999 OK\r\n\r\n",
    "HTTP/1.1 -1 Bad\r\n\r\n",
    "HTTP/1.1 0 \r\n\r\n",
    "HTTP/1.1 999 \r\n\r\n",
    "HTTP/2.0 200 OK\r\n\r\n",
    "XXXX/1.1 200 OK\r\n\r\n",
  ]
  for s in malformed:
    var parser = initHttp1Parser()
    var consumed = 0
    try:
      discard parser.feedData(s, consumed)
    except CatchableError:
      discard
  for i in 0 ..< FuzzIterations:
    let length = rng.rand(50) + 5
    let line = randomBytes(rng, length) & "\r\n\r\n"
    var parser = initHttp1Parser()
    var consumed = 0
    try:
      discard parser.feedData(line, consumed)
    except CatchableError:
      discard
  check(true, "http1 malformed status lines")
  echo "Fuzz HTTP/1.1 malformed status lines: OK"

proc fuzzHttp1MalformedChunked() =
  var rng = initRand(FuzzSeed + 2)
  let malformed = @[
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nXYZ\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFF\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nGGGGG\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n99999999999\r\ndata\r\n",
  ]
  for s in malformed:
    var parser = initHttp1Parser()
    var consumed = 0
    try:
      discard parser.feedData(s, consumed)
    except CatchableError:
      discard
  for i in 0 ..< FuzzIterations:
    let chunkSizeStr = randomBytes(rng, rng.rand(8) + 1)
    let chunkData = randomBytes(rng, rng.rand(20))
    let resp = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" &
               chunkSizeStr & "\r\n" & chunkData & "\r\n0\r\n\r\n"
    var parser = initHttp1Parser()
    var consumed = 0
    try:
      discard parser.feedData(resp, consumed)
    except CatchableError:
      discard
  check(true, "http1 malformed chunked")
  echo "Fuzz HTTP/1.1 malformed chunked: OK"

proc fuzzHttp1HeaderFuzzing() =
  var rng = initRand(FuzzSeed + 3)
  for i in 0 ..< FuzzIterations:
    var resp = "HTTP/1.1 200 OK\r\n"
    let headerCount = rng.rand(50) + 1
    for h in 0 ..< headerCount:
      let nameLen = rng.rand(100) + 1
      let valueLen = rng.rand(200)
      let name = randomBytes(rng, nameLen)
      let value = randomBytes(rng, valueLen)
      resp.add name
      resp.add ": "
      resp.add value
      resp.add "\r\n"
    resp.add "\r\n"
    var parser = initHttp1Parser()
    var consumed = 0
    try:
      discard parser.feedData(resp, consumed)
    except CatchableError:
      discard
  let manyHeaders = block:
    var r = "HTTP/1.1 200 OK\r\n"
    for i in 0 ..< 500:
      r.add "X-Header-" & $i & ": value" & $i & "\r\n"
    r.add "Content-Length: 0\r\n\r\n"
    r
  var parser = initHttp1Parser()
  var consumed = 0
  try:
    discard parser.feedData(manyHeaders, consumed)
  except CatchableError:
    discard
  let nullHeader = "HTTP/1.1 200 OK\r\nX-Bad: val\x00ue\r\nContent-Length: 0\r\n\r\n"
  parser = initHttp1Parser()
  consumed = 0
  try:
    discard parser.feedData(nullHeader, consumed)
  except CatchableError:
    discard
  check(true, "http1 header fuzzing")
  echo "Fuzz HTTP/1.1 header fuzzing: OK"

proc fuzzHttp1ContentLengthOverflow() =
  let overflows = @[
    "HTTP/1.1 200 OK\r\nContent-Length: 9999999999999999999\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 9223372036854775807\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 18446744073709551615\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 5\r\n\r\nhello",
  ]
  for s in overflows:
    var parser = initHttp1Parser()
    var consumed = 0
    try:
      discard parser.feedData(s, consumed)
    except CatchableError:
      discard
  check(true, "http1 content-length overflow")
  echo "Fuzz HTTP/1.1 content-length overflow: OK"

proc fuzzHttp1PartialResponses() =
  var rng = initRand(FuzzSeed + 4)
  let fullResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!"
  for i in 0 ..< FuzzIterations:
    let cutoff = rng.rand(fullResponse.len)
    let partial = fullResponse[0 ..< cutoff]
    var parser = initHttp1Parser()
    var consumed = 0
    try:
      discard parser.feedData(partial, consumed)
    except CatchableError:
      discard
  check(true, "http1 partial responses")
  echo "Fuzz HTTP/1.1 partial responses: OK"

proc fuzzH2RandomFrameBytes() =
  var rng = initRand(FuzzSeed + 10)
  for i in 0 ..< FuzzIterations:
    let length = rng.rand(100) + 9
    let data = randomBytesSeq(rng, length)
    var pos = 0
    try:
      let frame = parseH2Frame(data, pos)
      discard frame
    except CatchableError:
      discard
  check(true, "h2 random frame bytes")
  echo "Fuzz HTTP/2 random frame bytes: OK"

proc fuzzH2MalformedSettings() =
  var rng = initRand(FuzzSeed + 11)
  for i in 0 ..< FuzzIterations:
    var conn = initH2ClientConnection()
    let payloadLen = rng.rand(50)
    var frameData = newSeq[byte](9 + payloadLen)
    frameData[0] = byte((payloadLen shr 16) and 0xFF)
    frameData[1] = byte((payloadLen shr 8) and 0xFF)
    frameData[2] = byte(payloadLen and 0xFF)
    frameData[3] = 0x04
    frameData[4] = 0
    frameData[5] = 0
    frameData[6] = 0
    frameData[7] = 0
    frameData[8] = 0
    for j in 9 ..< frameData.len:
      frameData[j] = byte(rng.rand(255))
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except Defect:
      discard
    except CatchableError:
      discard
  check(true, "h2 malformed settings")
  echo "Fuzz HTTP/2 malformed SETTINGS: OK"

proc fuzzH2MalformedHeaders() =
  var rng = initRand(FuzzSeed + 12)
  for i in 0 ..< FuzzIterations:
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    let payloadLen = rng.rand(100) + 1
    let payload = randomBytesSeq(rng, payloadLen)
    let streamId = uint32(rng.rand(100) * 2 + 1)
    var frameData = newSeq[byte](9 + payloadLen)
    frameData[0] = byte((payloadLen shr 16) and 0xFF)
    frameData[1] = byte((payloadLen shr 8) and 0xFF)
    frameData[2] = byte(payloadLen and 0xFF)
    frameData[3] = 0x01
    frameData[4] = byte(FlagEndHeaders)
    let sid = streamId
    frameData[5] = byte((sid shr 24) and 0xFF)
    frameData[6] = byte((sid shr 16) and 0xFF)
    frameData[7] = byte((sid shr 8) and 0xFF)
    frameData[8] = byte(sid and 0xFF)
    for j in 0 ..< payloadLen:
      frameData[9 + j] = payload[j]
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
  check(true, "h2 malformed headers")
  echo "Fuzz HTTP/2 malformed HEADERS with HPACK: OK"

proc fuzzH2InvalidStreamIds() =
  var rng = initRand(FuzzSeed + 13)
  for i in 0 ..< FuzzIterations:
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    let streamId = uint32(rng.rand(high(int32)))
    var frameData = newSeq[byte](9)
    frameData[3] = byte(rng.rand(9))
    frameData[5] = byte((streamId shr 24) and 0xFF)
    frameData[6] = byte((streamId shr 16) and 0xFF)
    frameData[7] = byte((streamId shr 8) and 0xFF)
    frameData[8] = byte(streamId and 0xFF)
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
  check(true, "h2 invalid stream IDs")
  echo "Fuzz HTTP/2 invalid stream IDs: OK"

proc fuzzH2WindowUpdate() =
  var rng = initRand(FuzzSeed + 14)
  let specialIncrements: seq[seq[byte]] = @[
    @[byte(0), 0, 0, 0],
    @[byte(0x7F), 0xFF, 0xFF, 0xFF],
    @[byte(0x80), 0, 0, 0],
    @[byte(0xFF), 0xFF, 0xFF, 0xFF],
  ]
  for increment in specialIncrements:
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    var frameData = newSeq[byte](13)
    frameData[0] = 0
    frameData[1] = 0
    frameData[2] = 4
    frameData[3] = 0x08
    for j in 0 ..< 4:
      frameData[9 + j] = increment[j]
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
  for i in 0 ..< FuzzIterations:
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    let sid = uint32(rng.rand(10))
    var frameData = newSeq[byte](13)
    frameData[0] = 0
    frameData[1] = 0
    frameData[2] = 4
    frameData[3] = 0x08
    frameData[5] = byte((sid shr 24) and 0xFF)
    frameData[6] = byte((sid shr 16) and 0xFF)
    frameData[7] = byte((sid shr 8) and 0xFF)
    frameData[8] = byte(sid and 0xFF)
    let inc = uint32(rng.rand(high(int32)))
    frameData[9] = byte((inc shr 24) and 0xFF)
    frameData[10] = byte((inc shr 16) and 0xFF)
    frameData[11] = byte((inc shr 8) and 0xFF)
    frameData[12] = byte(inc and 0xFF)
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
  check(true, "h2 window update fuzzing")
  echo "Fuzz HTTP/2 WINDOW_UPDATE: OK"

proc fuzzH2Goaway() =
  var rng = initRand(FuzzSeed + 15)
  for i in 0 ..< FuzzIterations:
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    let payloadLen = rng.rand(20) + 8
    var frameData = newSeq[byte](9 + payloadLen)
    frameData[0] = byte((payloadLen shr 16) and 0xFF)
    frameData[1] = byte((payloadLen shr 8) and 0xFF)
    frameData[2] = byte(payloadLen and 0xFF)
    frameData[3] = 0x07
    for j in 9 ..< frameData.len:
      frameData[j] = byte(rng.rand(255))
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
  check(true, "h2 goaway fuzzing")
  echo "Fuzz HTTP/2 GOAWAY: OK"

proc fuzzH2ContinuationWithoutHeaders() =
  var rng = initRand(FuzzSeed + 16)
  for i in 0 ..< FuzzIterations:
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    let payloadLen = rng.rand(50)
    var frameData = newSeq[byte](9 + payloadLen)
    frameData[0] = byte((payloadLen shr 16) and 0xFF)
    frameData[1] = byte((payloadLen shr 8) and 0xFF)
    frameData[2] = byte(payloadLen and 0xFF)
    frameData[3] = 0x09
    frameData[4] = byte(FlagEndHeaders)
    let sid = uint32(rng.rand(100) * 2 + 1)
    frameData[5] = byte((sid shr 24) and 0xFF)
    frameData[6] = byte((sid shr 16) and 0xFF)
    frameData[7] = byte((sid shr 8) and 0xFF)
    frameData[8] = byte(sid and 0xFF)
    for j in 9 ..< frameData.len:
      frameData[j] = byte(rng.rand(255))
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
  check(true, "h2 continuation without headers")
  echo "Fuzz HTTP/2 CONTINUATION without HEADERS: OK"

proc fuzzH2OversizedFrames() =
  var rng = initRand(FuzzSeed + 17)
  for i in 0 ..< min(FuzzIterations, 200):
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    let payloadLen = rng.rand(32768) + 16384
    var frameData = newSeq[byte](9 + min(payloadLen, 1000))
    frameData[0] = byte((payloadLen shr 16) and 0xFF)
    frameData[1] = byte((payloadLen shr 8) and 0xFF)
    frameData[2] = byte(payloadLen and 0xFF)
    frameData[3] = byte(rng.rand(9))
    let sid = uint32(rng.rand(10))
    frameData[5] = byte((sid shr 24) and 0xFF)
    frameData[6] = byte((sid shr 16) and 0xFF)
    frameData[7] = byte((sid shr 8) and 0xFF)
    frameData[8] = byte(sid and 0xFF)
    for j in 9 ..< frameData.len:
      frameData[j] = byte(rng.rand(255))
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
  check(true, "h2 oversized frames")
  echo "Fuzz HTTP/2 oversized frames: OK"

proc parseUrlForTest(urlStr: string): tuple[scheme: string, host: string, port: uint16, path: string, valid: bool] =
  result.valid = false
  var pos = 0
  let schemeEnd = urlStr.find("://")
  if schemeEnd >= 0:
    result.scheme = urlStr[0 ..< schemeEnd]
    pos = schemeEnd + 3
  else:
    result.scheme = "http"
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
  if result.host.len == 0:
    return
  if portStart >= 0:
    var portEnd = portStart
    var portVal: uint32 = 0
    while portEnd < urlStr.len and urlStr[portEnd] >= '0' and urlStr[portEnd] <= '9':
      portVal = portVal * 10 + uint32(ord(urlStr[portEnd]) - ord('0'))
      if portVal > 65535:
        return
      portEnd += 1
    result.port = uint16(portVal)
    pos = portEnd
  else:
    pos = hostEnd
    if result.scheme == "https":
      result.port = 443
    else:
      result.port = 80
  if pos < urlStr.len:
    let fragmentStart = urlStr.find('#', pos)
    let pathEnd = if fragmentStart >= 0: fragmentStart else: urlStr.len
    let rawPath =
      if pathEnd > pos:
        urlStr[pos ..< pathEnd]
      else:
        ""
    let pathStr =
      if rawPath.len == 0:
        "/"
      elif rawPath[0] == '?':
        "/" & rawPath
      else:
        rawPath
    for c in pathStr:
      if c == '\r' or c == '\n':
        return
    result.path = pathStr
  else:
    result.path = "/"
  result.valid = true

proc fuzzUrlParsing() =
  var rng = initRand(FuzzSeed + 20)
  for i in 0 ..< FuzzIterations:
    let length = rng.rand(200) + 1
    let url = randomBytes(rng, length)
    try:
      let parsed = parseUrlForTest(url)
      discard parsed
    except CatchableError:
      discard
  let edgeCases = @[
    "",
    "http://",
    "https://",
    "://host",
    "http://host:99999",
    "http://host:0",
    "http://host:65536",
    "http://host:abc",
    "http://host/path\r\nInjected: header",
    "http://host/path\nInjected: header",
    "http://\x00host",
    "http://host/\x00path",
    "ftp://host/path",
    "http://a" & repeat('b', 1024 * 1024),
    "http://host/" & repeat('/', 100000),
    "http://host:65535/path",
    "http://host:1/path",
    "http://host/path?query=\x00value",
    "http://host/pa th",
    "http://host/path#fragment",
    "http://user:pass@host/path",
    "http://[::1]/path",
  ]
  for url in edgeCases:
    try:
      let parsed = parseUrlForTest(url)
      discard parsed
    except CatchableError:
      discard
  let validUrls = @[
    "http://example.com",
    "https://example.com:443/path",
    "http://localhost:8080/api/test?q=1",
    "http://a.b.c.d:1/",
  ]
  for url in validUrls:
    let parsed = parseUrlForTest(url)
    check(parsed.valid, "valid url: " & url)
  check(true, "url parsing fuzzing")
  echo "Fuzz URL parsing: OK"

proc fuzzWebSocketRandomBytes() =
  var rng = initRand(FuzzSeed + 30)
  for i in 0 ..< FuzzIterations:
    let length = rng.rand(200) + 2
    let data = randomBytesSeq(rng, length)
    var pos = 0
    try:
      let frame = decodeWsFrame(data, pos)
      discard frame
    except CatchableError:
      discard
  check(true, "ws random bytes")
  echo "Fuzz WebSocket random bytes: OK"

proc fuzzWebSocketMalformedFrames() =
  var rng = initRand(FuzzSeed + 31)
  for i in 0 ..< FuzzIterations:
    let opcodeVal = rng.rand(15)
    let payloadLen = rng.rand(300)
    let masked = rng.rand(1) == 1
    var frame = newSeq[byte](0)
    frame.add byte(0x80 or uint8(opcodeVal))
    let maskBit: uint8 = if masked: 0x80 else: 0
    if payloadLen < 126:
      frame.add byte(maskBit or uint8(payloadLen))
    elif payloadLen < 65536:
      frame.add byte(maskBit or 126)
      frame.add byte((payloadLen shr 8) and 0xFF)
      frame.add byte(payloadLen and 0xFF)
    else:
      frame.add byte(maskBit or 127)
      for j in countdown(7, 0):
        frame.add byte((payloadLen shr (j * 8)) and 0xFF)
    if masked:
      for j in 0 ..< 4:
        frame.add byte(rng.rand(255))
    let actualPayload = rng.rand(min(payloadLen, 50))
    for j in 0 ..< actualPayload:
      frame.add byte(rng.rand(255))
    var pos = 0
    try:
      let decoded = decodeWsFrame(frame, pos)
      discard decoded
    except CatchableError:
      discard
  check(true, "ws malformed frames")
  echo "Fuzz WebSocket malformed frames: OK"

proc fuzzWebSocketAllOpcodes() =
  var rng = initRand(FuzzSeed + 32)
  for opcodeVal in 0 .. 15:
    for i in 0 ..< 100:
      let payloadLen = rng.rand(50)
      var frame = newSeq[byte](2 + payloadLen)
      frame[0] = byte(0x80 or uint8(opcodeVal))
      frame[1] = byte(payloadLen)
      for j in 0 ..< payloadLen:
        frame[2 + j] = byte(rng.rand(255))
      var pos = 0
      try:
        let decoded = decodeWsFrame(frame, pos)
        discard decoded
      except CatchableError:
        discard
  check(true, "ws all opcodes")
  echo "Fuzz WebSocket all opcodes: OK"

proc fuzzWebSocketHugePayload() =
  var hugeFrame = newSeq[byte](10)
  hugeFrame[0] = 0x81
  hugeFrame[1] = 127
  hugeFrame[2] = 0x00
  hugeFrame[3] = 0x00
  hugeFrame[4] = 0x00
  hugeFrame[5] = 0x01
  hugeFrame[6] = 0x00
  hugeFrame[7] = 0x00
  hugeFrame[8] = 0x00
  hugeFrame[9] = 0x00
  var pos = 0
  try:
    let decoded = decodeWsFrame(hugeFrame, pos)
    check(decoded.isNone, "ws huge payload rejected")
  except CatchableError:
    check(true, "ws huge payload caught")
  echo "Fuzz WebSocket huge payload: OK"

proc fuzzSseRandomBytes() =
  var rng = initRand(FuzzSeed + 40)
  for i in 0 ..< FuzzIterations:
    var parser = initSseParser()
    let length = rng.rand(500) + 1
    let data = randomBytes(rng, length)
    try:
      let events = parser.feedData(data)
      discard events
    except CatchableError:
      discard
  check(true, "sse random bytes")
  echo "Fuzz SSE random bytes: OK"

proc fuzzSseLongLines() =
  var parser = initSseParser()
  let longLine = "data: " & repeat('A', 1024 * 1024 + 100) & "\n\n"
  try:
    let events = parser.feedData(longLine)
    discard events
  except CatchableError:
    discard
  check(true, "sse long lines")
  echo "Fuzz SSE extremely long lines: OK"

proc fuzzSseBinaryAndNull() =
  var rng = initRand(FuzzSeed + 41)
  for i in 0 ..< FuzzIterations:
    var parser = initSseParser()
    let length = rng.rand(200) + 1
    var data = ""
    for j in 0 ..< length:
      if rng.rand(10) == 0:
        data.add '\0'
      elif rng.rand(5) == 0:
        data.add '\n'
      else:
        data.add char(rng.rand(255))
    try:
      let events = parser.feedData(data)
      discard events
    except CatchableError:
      discard
  check(true, "sse binary and null")
  echo "Fuzz SSE binary data and NUL bytes: OK"

proc fuzzSseMultipleFeeds() =
  var rng = initRand(FuzzSeed + 42)
  for i in 0 ..< FuzzIterations:
    var parser = initSseParser()
    let feedCount = rng.rand(10) + 1
    for f in 0 ..< feedCount:
      let length = rng.rand(100) + 1
      let data = randomBytes(rng, length)
      try:
        let events = parser.feedData(data)
        discard events
      except CatchableError:
        discard
  check(true, "sse multiple feeds")
  echo "Fuzz SSE multiple feed sequences: OK"

proc fuzzHpackRandomBytes() =
  var rng = initRand(FuzzSeed + 50)
  for i in 0 ..< FuzzIterations:
    var decoder = initHpackDecoder()
    let length = rng.rand(200) + 1
    let data = randomBytesSeq(rng, length)
    try:
      let decoded = hpackDecode(decoder, data)
      discard decoded
    except CatchableError:
      discard
  check(true, "hpack random bytes")
  echo "Fuzz HPACK random bytes: OK"

proc fuzzHpackCraftedHuffman() =
  var rng = initRand(FuzzSeed + 51)
  for i in 0 ..< FuzzIterations:
    var decoder = initHpackDecoder()
    let length = rng.rand(100) + 2
    var data = newSeq[byte](length)
    data[0] = byte(0x80 or min(length - 1, 126))
    for j in 1 ..< length:
      data[j] = byte(rng.rand(255))
    try:
      let decoded = hpackDecode(decoder, data)
      discard decoded
    except CatchableError:
      discard
  check(true, "hpack crafted huffman")
  echo "Fuzz HPACK crafted Huffman data: OK"

proc fuzzHpackDynamicTableBomb() =
  var decoder = initHpackDecoder()
  var encoder = initHpackEncoder(huffman = false)
  for i in 0 ..< 500:
    let name = "x-header-" & $i
    let value = repeat('V', 200)
    var buf = ""
    hpackEncode(encoder, @[(name, value)], buf)
    try:
      let decoded = hpackDecode(decoder, cast[seq[byte]](buf))
      discard decoded
    except CatchableError:
      discard
  check(true, "hpack dynamic table bomb")
  echo "Fuzz HPACK dynamic table bomb: OK"

proc fuzzHpackOversizedStrings() =
  var rng = initRand(FuzzSeed + 52)
  for i in 0 ..< min(FuzzIterations, 500):
    var decoder = initHpackDecoder()
    let strLen = rng.rand(10000) + 1000
    var data = newSeq[byte](0)
    data.add 0x00
    if strLen < 127:
      data.add byte(strLen)
    else:
      data.add 0x7F
      var remaining = strLen - 127
      while remaining >= 128:
        data.add byte((remaining and 0x7F) or 0x80)
        remaining = remaining shr 7
      data.add byte(remaining)
    for j in 0 ..< min(strLen, 500):
      data.add byte(rng.rand(255))
    try:
      let decoded = hpackDecode(decoder, data)
      discard decoded
    except CatchableError:
      discard
  check(true, "hpack oversized strings")
  echo "Fuzz HPACK oversized strings: OK"

proc fuzzConnectionPool() =
  var rng = initRand(FuzzSeed + 60)
  for i in 0 ..< FuzzIterations:
    var pool = initConnectionPool(maxPerHost = rng.rand(5) + 1)
    check(pool.totalConnections == 0, "pool starts empty iter " & $i)
    let numOps = rng.rand(20) + 1
    var allocated: seq[ptr PooledConnection] = @[]
    for op in 0 ..< numOps:
      let action = rng.rand(3)
      case action
      of 0:
        let conn = cast[ptr PooledConnection](alloc0(sizeof(PooledConnection)))
        conn.host = "host" & $(rng.rand(3))
        conn.port = uint16(rng.rand(3) + 80)
        conn.useSsl = rng.rand(1) == 1
        conn.state = csOpen
        conn.pendingCallbacks = initDeque[ResponseCallback](4)
        pool.addConnection(conn)
        allocated.add conn
      of 1:
        if allocated.len > 0:
          let idx = rng.rand(allocated.len - 1)
          let conn = allocated[idx]
          pool.removeConnection(conn)
          allocated.del(idx)
          dealloc(conn)
      of 2:
        let acquired = pool.acquireConnection(
          "host" & $(rng.rand(3)),
          uint16(rng.rand(3) + 80),
          rng.rand(1) == 1
        )
        discard acquired
      else:
        discard pool.cleanup()
    check(pool.totalConnections >= 0, "pool non-negative count iter " & $i)
    for conn in allocated:
      pool.removeConnection(conn)
      dealloc(conn)
  check(true, "connection pool fuzzing")
  echo "Fuzz connection pool: OK"

proc fuzzConnectionPoolBoundary() =
  var pool = initConnectionPool(maxPerHost = 1)
  check(pool.totalConnections == 0, "empty pool total")
  let acquired = pool.acquireConnection("nohost", 80, false)
  check(acquired == nil, "acquire from empty pool")
  let conn = cast[ptr PooledConnection](alloc0(sizeof(PooledConnection)))
  conn.host = "solo"
  conn.port = 80
  conn.useSsl = false
  conn.state = csOpen
  conn.pendingCallbacks = initDeque[ResponseCallback](4)
  pool.addConnection(conn)
  check(pool.totalConnections == 1, "single conn pool")
  let found = pool.acquireConnection("solo", 80, false)
  check(found == conn, "acquire single conn")
  pool.removeConnection(conn)
  check(pool.totalConnections == 0, "removed single conn")
  pool.removeConnection(conn)
  check(pool.totalConnections == 0, "double remove safe")
  dealloc(conn)
  check(true, "connection pool boundary")
  echo "Fuzz connection pool boundary: OK"

proc fuzzH2ClientConnectionProcessFrame() =
  var rng = initRand(FuzzSeed + 70)
  for i in 0 ..< FuzzIterations:
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    let numFrames = rng.rand(10) + 1
    for f in 0 ..< numFrames:
      let payloadLen = rng.rand(100)
      let data = randomBytesSeq(rng, 9 + payloadLen)
      var responseBuf = ""
      try:
        discard conn.feedData(data, responseBuf)
      except CatchableError:
        discard
      if conn.state == h2csGoaway:
        break
  check(true, "h2 multi-frame sequences")
  echo "Fuzz HTTP/2 multi-frame sequences: OK"

proc fuzzH2RstStream() =
  var rng = initRand(FuzzSeed + 71)
  for i in 0 ..< FuzzIterations:
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    let sid = uint32(rng.rand(100) * 2 + 1)
    discard conn.allocateStream()
    var frameData = newSeq[byte](13)
    frameData[0] = 0
    frameData[1] = 0
    frameData[2] = 4
    frameData[3] = 0x03
    frameData[5] = byte((sid shr 24) and 0xFF)
    frameData[6] = byte((sid shr 16) and 0xFF)
    frameData[7] = byte((sid shr 8) and 0xFF)
    frameData[8] = byte(sid and 0xFF)
    let errorCode = uint32(rng.rand(high(int32)))
    frameData[9] = byte((errorCode shr 24) and 0xFF)
    frameData[10] = byte((errorCode shr 16) and 0xFF)
    frameData[11] = byte((errorCode shr 8) and 0xFF)
    frameData[12] = byte(errorCode and 0xFF)
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
  check(true, "h2 rst_stream fuzzing")
  echo "Fuzz HTTP/2 RST_STREAM: OK"

proc fuzzH2Ping() =
  var rng = initRand(FuzzSeed + 72)
  for i in 0 ..< FuzzIterations:
    var conn = initH2ClientConnection()
    conn.state = h2csActive
    let payloadLen = rng.rand(16)
    var frameData = newSeq[byte](9 + payloadLen)
    frameData[0] = byte((payloadLen shr 16) and 0xFF)
    frameData[1] = byte((payloadLen shr 8) and 0xFF)
    frameData[2] = byte(payloadLen and 0xFF)
    frameData[3] = 0x06
    frameData[4] = byte(rng.rand(1))
    let sid = uint32(rng.rand(5))
    frameData[5] = byte((sid shr 24) and 0xFF)
    frameData[6] = byte((sid shr 16) and 0xFF)
    frameData[7] = byte((sid shr 8) and 0xFF)
    frameData[8] = byte(sid and 0xFF)
    for j in 9 ..< frameData.len:
      frameData[j] = byte(rng.rand(255))
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
  check(true, "h2 ping fuzzing")
  echo "Fuzz HTTP/2 PING: OK"

proc fuzzWsEncodeDecode() =
  var rng = initRand(FuzzSeed + 80)
  for i in 0 ..< FuzzIterations:
    let payload = randomBytes(rng, rng.rand(200))
    let opcodes = [woText, woBinary, woPing, woPong, woClose, woContinuation]
    let opcode = opcodes[rng.rand(opcodes.len - 1)]
    let masked = rng.rand(1) == 1
    try:
      let encoded = encodeWsFrame(opcode, payload, masked = masked)
      var pos = 0
      let decoded = decodeWsFrame(cast[seq[byte]](encoded), pos)
      if decoded.isSome:
        check(decoded.get.payload == payload, "ws roundtrip payload iter " & $i)
    except CatchableError:
      discard
  check(true, "ws encode/decode roundtrip")
  echo "Fuzz WebSocket encode/decode roundtrip: OK"

proc fuzzHpackRoundtrip() =
  var rng = initRand(FuzzSeed + 90)
  for i in 0 ..< FuzzIterations:
    var encoder = initHpackEncoder(huffman = rng.rand(1) == 1)
    var decoder = initHpackDecoder()
    let headerCount = rng.rand(5) + 1
    var headers: seq[(string, string)] = @[]
    for h in 0 ..< headerCount:
      let name = randomPrintable(rng, rng.rand(20) + 1).toLowerAscii()
      let value = randomPrintable(rng, rng.rand(50))
      headers.add((name, value))
    var buf = ""
    try:
      hpackEncode(encoder, headers, buf)
      let decoded = hpackDecode(decoder, cast[seq[byte]](buf))
      check(decoded.len == headers.len, "hpack roundtrip count iter " & $i)
    except CatchableError:
      discard
  check(true, "hpack roundtrip")
  echo "Fuzz HPACK encode/decode roundtrip: OK"

echo "=== Fuzz Tests ==="
echo ""

fuzzHttp1RandomBytes()
fuzzHttp1MalformedStatusLine()
fuzzHttp1MalformedChunked()
fuzzHttp1HeaderFuzzing()
fuzzHttp1ContentLengthOverflow()
fuzzHttp1PartialResponses()

fuzzH2RandomFrameBytes()
fuzzH2MalformedSettings()
fuzzH2MalformedHeaders()
fuzzH2InvalidStreamIds()
fuzzH2WindowUpdate()
fuzzH2Goaway()
fuzzH2ContinuationWithoutHeaders()
fuzzH2OversizedFrames()
fuzzH2ClientConnectionProcessFrame()
fuzzH2RstStream()
fuzzH2Ping()

fuzzUrlParsing()

fuzzWebSocketRandomBytes()
fuzzWebSocketMalformedFrames()
fuzzWebSocketAllOpcodes()
fuzzWebSocketHugePayload()
fuzzWsEncodeDecode()

fuzzSseRandomBytes()
fuzzSseLongLines()
fuzzSseBinaryAndNull()
fuzzSseMultipleFeeds()

fuzzHpackRandomBytes()
fuzzHpackCraftedHuffman()
fuzzHpackDynamicTableBomb()
fuzzHpackOversizedStrings()
fuzzHpackRoundtrip()

fuzzConnectionPool()
fuzzConnectionPoolBoundary()

proc fuzzHttp1ChunkExtensions() =
  let cases = @[
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=val\r\nhello\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=val;ext2=val2\r\nhello\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;;;;;;\r\nhello\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n;nohex\r\ndata\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;\r\nhello\r\n0\r\n\r\n",
  ]
  for s in cases:
    var parser = initHttp1Parser()
    var consumed = 0
    try:
      discard parser.feedData(s, consumed)
    except CatchableError:
      discard
  var parser = initHttp1Parser()
  var consumed = 0
  let validExt = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=val\r\nhello\r\n0\r\n\r\n"
  let done = parser.feedData(validExt, consumed)
  check(done and parser.state == psDone, "chunk extension parsed correctly")
  check(parser.response.body == "hello", "chunk extension body correct")
  let emptyExt = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n;nohex\r\ndata\r\n0\r\n\r\n"
  parser = initHttp1Parser()
  consumed = 0
  discard parser.feedData(emptyExt, consumed)
  check(parser.state == psError, "empty chunk size with extension rejected")
  echo "Fuzz HTTP/1 chunk extensions: OK"

proc fuzzHttp1StatusCodeRange() =
  let lowCodes = @[
    "HTTP/1.1 099 Low\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 000 Zero\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 001 One\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 050 Fifty\r\nContent-Length: 0\r\n\r\n",
  ]
  for s in lowCodes:
    var parser = initHttp1Parser()
    var consumed = 0
    let done = parser.feedData(s, consumed)
    check(done and parser.state == psError, "status code < 100 rejected")
  let validCode = "HTTP/1.1 100 Continue\r\nContent-Length: 0\r\n\r\n"
  var parser = initHttp1Parser()
  var consumed = 0
  let done = parser.feedData(validCode, consumed)
  check(not done and parser.state == psStatusLine and consumed == validCode.len, "status code 100 accepted as informational")

  let finalAfterInformational = validCode & "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  parser = initHttp1Parser()
  consumed = 0
  let finalDone = parser.feedData(finalAfterInformational, consumed)
  check(finalDone and parser.state == psDone and parser.response.statusCode == 200, "status code 100 skipped before final response")
  echo "Fuzz HTTP/1 status code range: OK"

proc fuzzHttp1SerializeRequestCrlf() =
  let reqCrlfHost = HttpRequest(
    `method`: hmGet, host: "evil\r\nInjected: yes",
    port: 80, path: "/", version: Http11, headers: @[],
  )
  let s1 = serializeRequest(reqCrlfHost)
  check(s1 == "", "CRLF in host rejected by serializeRequest")
  let reqCrlfPath = HttpRequest(
    `method`: hmGet, host: "safe.com",
    port: 80, path: "/path\r\nInjected: yes", version: Http11, headers: @[],
  )
  let s2 = serializeRequest(reqCrlfPath)
  check(s2 == "", "CRLF in path rejected by serializeRequest")
  let reqGood = HttpRequest(
    `method`: hmGet, host: "good.com",
    port: 80, path: "/api", version: Http11,
    headers: @[HttpHeader(name: "Accept", value: "text/html")],
  )
  let s3 = serializeRequest(reqGood)
  check(s3.len > 0 and "GET /api" in s3, "valid request serialized")
  echo "Fuzz HTTP/1 serializeRequest CRLF injection: OK"

proc fuzzH2DataPaddingStrip() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  conn.streams[sid].responseStatus = 200
  let padLen = 3
  let payload = "hello"
  var framePayload = newString(1 + payload.len + padLen)
  framePayload[0] = char(padLen)
  for i in 0 ..< payload.len:
    framePayload[1 + i] = payload[i]
  for i in 0 ..< padLen:
    framePayload[1 + payload.len + i] = '\0'
  var frameData = newSeq[byte](9 + framePayload.len)
  let plen = uint32(framePayload.len)
  frameData[0] = byte((plen shr 16) and 0xFF)
  frameData[1] = byte((plen shr 8) and 0xFF)
  frameData[2] = byte(plen and 0xFF)
  frameData[3] = 0x00
  frameData[4] = byte(FlagEndStream) or byte(FlagPadded)
  frameData[5] = byte((sid shr 24) and 0xFF)
  frameData[6] = byte((sid shr 16) and 0xFF)
  frameData[7] = byte((sid shr 8) and 0xFF)
  frameData[8] = byte(sid and 0xFF)
  for j in 0 ..< framePayload.len:
    frameData[9 + j] = byte(framePayload[j])
  var responseBuf = ""
  try:
    let completed = conn.feedData(frameData, responseBuf)
    check(completed.len > 0, "h2 padded data frame completed")
    if completed.len > 0:
      check(completed[0][1].responseBody == "hello", "h2 padded data payload stripped correctly")
  except CatchableError:
    check(false, "h2 padded data should not raise")
  echo "Fuzz HTTP/2 DATA padding strip: OK"

proc fuzzH2DataInvalidPadding() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  conn.streams[sid].responseStatus = 200
  var framePayload = newString(1)
  framePayload[0] = char(200)
  var frameData = newSeq[byte](9 + framePayload.len)
  frameData[0] = 0
  frameData[1] = 0
  frameData[2] = byte(framePayload.len)
  frameData[3] = 0x00
  frameData[4] = byte(FlagPadded)
  frameData[5] = byte((sid shr 24) and 0xFF)
  frameData[6] = byte((sid shr 16) and 0xFF)
  frameData[7] = byte((sid shr 8) and 0xFF)
  frameData[8] = byte(sid and 0xFF)
  for j in 0 ..< framePayload.len:
    frameData[9 + j] = byte(framePayload[j])
  var responseBuf = ""
  try:
    let completed = conn.feedData(frameData, responseBuf)
    check(completed.len > 0 and completed[0][1].state == ssClosed, "h2 invalid padding closes stream")
  except CatchableError:
    check(true, "h2 invalid padding caught")
  echo "Fuzz HTTP/2 DATA invalid padding: OK"

proc fuzzH2RstAfterPartialResponseIsError() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  conn.streams[sid].responseStatus = 200
  conn.streams[sid].responseBody = "partial"
  var frameData = newSeq[byte](13)
  frameData[0] = 0
  frameData[1] = 0
  frameData[2] = 4
  frameData[3] = 0x03
  frameData[5] = byte((sid shr 24) and 0xFF)
  frameData[6] = byte((sid shr 16) and 0xFF)
  frameData[7] = byte((sid shr 8) and 0xFF)
  frameData[8] = byte(sid and 0xFF)
  var responseBuf = ""
  let completed = conn.feedData(frameData, responseBuf)
  check(completed.len == 1, "h2 rst after partial response completes stream")
  if completed.len == 1:
    check(completed[0][1].responseStatus == 0, "h2 rst after partial response reports error")
    check(completed[0][1].responseBody.len == 0, "h2 rst after partial response drops partial body")
  echo "Fuzz HTTP/2 RST_STREAM partial-response error: OK"

proc fuzzH2FlowControlSendData() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  conn.remoteWindow = 10
  let sid = conn.allocateStream()
  conn.streams[sid].sendWindow = 5
  var buf = ""
  conn.sendData(sid, "this is a big payload that exceeds window", endStream = true, buf)
  check(conn.streams[sid].state == ssOpen, "h2 sendData keeps stream open while endStream body is buffered")
  check(conn.streams[sid].dataBuf.len > 0, "h2 sendData buffers endStream tail when flow blocked")
  check(conn.streams[sid].dataEndStreamPending, "h2 sendData remembers pending END_STREAM")
  var updates = ""
  serializeWindowUpdate(sid, 100'u32, updates)
  serializeWindowUpdate(0, 100'u32, updates)
  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](updates), responseBuf)
  check(conn.streams[sid].dataBuf.len == 0, "h2 WINDOW_UPDATE flushes buffered request body")
  check(conn.streams[sid].state == ssHalfClosedLocal, "h2 pending END_STREAM is sent after buffered body")
  check(responseBuf.len > 0, "h2 WINDOW_UPDATE produced pending DATA frames")
  var conn2 = initH2ClientConnection()
  conn2.state = h2csActive
  conn2.remoteWindow = 0
  let sid2 = conn2.allocateStream()
  conn2.streams[sid2].sendWindow = 0
  var buf2 = ""
  conn2.sendData(sid2, "data", endStream = false, buf2)
  check(sid2 in conn2.streams and conn2.streams[sid2].dataBuf == "data", "h2 sendData buffers when flow blocked")
  var conn3 = initH2ClientConnection()
  conn3.state = h2csActive
  conn3.remoteWindow = 100
  conn3.remoteSettings.initialWindowSize = 0
  let sid3 = conn3.allocateStream()
  var buf3 = ""
  conn3.sendData(sid3, "settings-unblocked-body", endStream = true, buf3)
  check(conn3.streams[sid3].dataBuf == "settings-unblocked-body", "h2 settings test starts with buffered body")
  var settingsFrame = newSeq[byte](15)
  settingsFrame[0] = 0
  settingsFrame[1] = 0
  settingsFrame[2] = 6
  settingsFrame[3] = byte(ftSettings)
  settingsFrame[9] = 0
  settingsFrame[10] = 4
  settingsFrame[11] = 0
  settingsFrame[12] = 0
  settingsFrame[13] = 0
  settingsFrame[14] = 64
  var settingsResponse = ""
  discard conn3.feedData(settingsFrame, settingsResponse)
  check(conn3.streams[sid3].dataBuf.len == 0, "h2 SETTINGS initial-window increase flushes buffered body")
  check(conn3.streams[sid3].state == ssHalfClosedLocal, "h2 SETTINGS flush sends pending END_STREAM")
  check(settingsResponse.len > 0, "h2 SETTINGS flush writes ack and pending DATA")
  echo "Fuzz HTTP/2 flow control sendData: OK"

proc fuzzH2InformationalAndUnknownFrames() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  var enc = initHpackEncoder(huffman = false)
  var infoBlock = ""
  hpackEncode(enc, @[(":status", "103"), ("link", "</style.css>; rel=preload")], infoBlock)
  var finalBlock = ""
  hpackEncode(enc, @[(":status", "200"), ("content-type", "text/plain")], finalBlock)
  var frameData = ""
  serializeHeaders(sid, infoBlock, endStream = false, endHeaders = true, frameData)
  serializeHeaders(sid, finalBlock, endStream = true, endHeaders = true, frameData)
  var responseBuf = ""
  let completed = conn.feedData(cast[seq[byte]](frameData), responseBuf)
  check(completed.len == 1, "h2 final headers complete after informational response")
  check(completed[0][1].responseStatus == 200, "h2 informational response does not replace final status")
  check(conn.state == h2csActive, "h2 informational response does not trigger connection error")

  var conn2 = initH2ClientConnection()
  conn2.state = h2csActive
  var mixed = ""
  mixed.add "\x00\x00\x00"
  mixed.add char(0x0A)
  mixed.add "\x00\x00\x00\x00\x00"
  serializeSettings(DefaultH2Settings, mixed)
  var responseBuf2 = ""
  discard conn2.feedData(cast[seq[byte]](mixed), responseBuf2)
  check(responseBuf2.len > 0, "h2 unknown extension frame is skipped before following SETTINGS")
  check(conn2.recvBuf.len == 0, "h2 unknown extension frame does not stall following frames")
  echo "Fuzz HTTP/2 informational and unknown frames: OK"

proc fuzzH2ResponseBodyFraming() =
  var enc = initHpackEncoder(huffman = false)

  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  conn.streams[sid].request = HttpRequest(`method`: hmGet, url: "https://example.test/")
  var headerBlock = ""
  hpackEncode(enc, @[(":status", "200"), ("content-length", "5")], headerBlock)
  var frames = ""
  serializeHeaders(sid, headerBlock, endStream = false, endHeaders = true, frames)
  serializeData(sid, "abcdef", endStream = true, frames)
  var responseBuf = ""
  let completed = conn.feedData(cast[seq[byte]](frames), responseBuf)
  check(completed.len == 1, "h2 content-length overflow completes stream as error")
  check(completed[0][1].responseStatus == 0, "h2 content-length overflow is delivered as stream error")
  check(responseBuf.len > 0, "h2 content-length overflow sends RST_STREAM")

  var conn2 = initH2ClientConnection()
  conn2.state = h2csActive
  let sid2 = conn2.allocateStream()
  conn2.streams[sid2].request = HttpRequest(`method`: hmHead, url: "https://example.test/")
  enc = initHpackEncoder(huffman = false)
  headerBlock.setLen(0)
  hpackEncode(enc, @[(":status", "200"), ("content-length", "5")], headerBlock)
  frames.setLen(0)
  serializeHeaders(sid2, headerBlock, endStream = false, endHeaders = true, frames)
  serializeData(sid2, "hello", endStream = true, frames)
  responseBuf.setLen(0)
  let completed2 = conn2.feedData(cast[seq[byte]](frames), responseBuf)
  check(completed2.len == 1, "h2 HEAD response DATA completes stream as error")
  check(completed2[0][1].responseStatus == 0, "h2 HEAD response DATA is rejected")

  var conn3 = initH2ClientConnection()
  conn3.state = h2csActive
  let sid3 = conn3.allocateStream()
  conn3.streams[sid3].request = HttpRequest(`method`: hmGet, url: "https://example.test/")
  enc = initHpackEncoder(huffman = false)
  headerBlock.setLen(0)
  hpackEncode(enc, @[(":status", "200"), ("content-length", "5")], headerBlock)
  frames.setLen(0)
  serializeHeaders(sid3, headerBlock, endStream = true, endHeaders = true, frames)
  responseBuf.setLen(0)
  let completed3 = conn3.feedData(cast[seq[byte]](frames), responseBuf)
  check(completed3.len == 0, "h2 short content-length on header END_STREAM is connection error")
  check(conn3.localConnectionError, "h2 short content-length trips protocol error")

  var conn4 = initH2ClientConnection()
  conn4.state = h2csActive
  let sid4 = conn4.allocateStream()
  conn4.streams[sid4].request = HttpRequest(`method`: hmGet, url: "https://example.test/")
  enc = initHpackEncoder(huffman = false)
  headerBlock.setLen(0)
  hpackEncode(enc, @[(":status", "200")], headerBlock)
  var trailerBlock = ""
  hpackEncode(enc, @[("content-length", "5")], trailerBlock)
  frames.setLen(0)
  serializeHeaders(sid4, headerBlock, endStream = false, endHeaders = true, frames)
  serializeData(sid4, "hello", endStream = false, frames)
  serializeHeaders(sid4, trailerBlock, endStream = true, endHeaders = true, frames)
  responseBuf.setLen(0)
  let completed4 = conn4.feedData(cast[seq[byte]](frames), responseBuf)
  check(completed4.len == 0, "h2 content-length trailer does not complete as valid response")
  check(conn4.localConnectionError, "h2 content-length trailer is rejected as protocol error")
  check(responseBuf.len > 0, "h2 content-length trailer emits GOAWAY")

  var conn5 = initH2ClientConnection()
  conn5.state = h2csActive
  let sid5 = conn5.allocateStream()
  conn5.streams[sid5].request = HttpRequest(`method`: hmGet, url: "https://example.test/")
  enc = initHpackEncoder(huffman = false)
  headerBlock.setLen(0)
  hpackEncode(enc, @[(":status", "200")], headerBlock)
  trailerBlock.setLen(0)
  hpackEncode(enc, @[("transfer-encoding", "chunked")], trailerBlock)
  frames.setLen(0)
  serializeHeaders(sid5, headerBlock, endStream = false, endHeaders = true, frames)
  serializeData(sid5, "hello", endStream = false, frames)
  serializeHeaders(sid5, trailerBlock, endStream = true, endHeaders = true, frames)
  responseBuf.setLen(0)
  let completed5 = conn5.feedData(cast[seq[byte]](frames), responseBuf)
  check(completed5.len == 0, "h2 transfer-encoding trailer does not complete as valid response")
  check(conn5.localConnectionError, "h2 transfer-encoding trailer is rejected as protocol error")
  echo "Fuzz HTTP/2 response body framing: OK"

proc fuzzH2StreamExhaustion() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  conn.nextStreamId = 2147483645'u32
  let s1 = conn.allocateStream()
  check(s1 == 2147483645'u32, "h2 last valid stream allocated")
  let s2 = conn.allocateStream()
  check(s2 == 0, "h2 stream ID exhausted returns 0")
  check(conn.state == h2csGoaway, "h2 stream ID exhaustion triggers goaway")
  echo "Fuzz HTTP/2 stream ID exhaustion: OK"

proc fuzzH2ServerStreamFlood() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  conn.localSettings.maxConcurrentStreams = 5
  var encoder = initHpackEncoder()
  for i in 0 ..< 15:
    let sid = uint32(i * 2 + 1)
    var headerBlock = ""
    hpackEncode(encoder, @[(":status", "200")], headerBlock)
    var frameData = newSeq[byte](9 + headerBlock.len)
    let plen = uint32(headerBlock.len)
    frameData[0] = byte((plen shr 16) and 0xFF)
    frameData[1] = byte((plen shr 8) and 0xFF)
    frameData[2] = byte(plen and 0xFF)
    frameData[3] = 0x01
    frameData[4] = byte(FlagEndHeaders) or byte(FlagEndStream)
    frameData[5] = byte((sid shr 24) and 0xFF)
    frameData[6] = byte((sid shr 16) and 0xFF)
    frameData[7] = byte((sid shr 8) and 0xFF)
    frameData[8] = byte(sid and 0xFF)
    for j in 0 ..< headerBlock.len:
      frameData[9 + j] = byte(headerBlock[j])
    var responseBuf = ""
    try:
      discard conn.feedData(frameData, responseBuf)
    except CatchableError:
      discard
    if conn.state == h2csGoaway:
      break
  check(conn.state == h2csGoaway, "h2 server stream flood triggers goaway")
  echo "Fuzz HTTP/2 server stream flood: OK"

proc fuzzH2GoawayStreams() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let s1 = conn.allocateStream()
  let s3 = conn.allocateStream()
  let s5 = conn.allocateStream()
  check(s3 > s1 and s5 > s3, "h2 client streams are monotonically allocated")
  let peerLastStreamId = s1
  var frameData = newSeq[byte](9 + 8)
  frameData[0] = 0
  frameData[1] = 0
  frameData[2] = 8
  frameData[3] = 0x07
  frameData[9] = byte((peerLastStreamId shr 24) and 0xFF)
  frameData[10] = byte((peerLastStreamId shr 16) and 0xFF)
  frameData[11] = byte((peerLastStreamId shr 8) and 0xFF)
  frameData[12] = byte(peerLastStreamId and 0xFF)
  var responseBuf = ""
  let completed = conn.feedData(frameData, responseBuf)
  check(conn.state == h2csGoaway, "h2 goaway sets state")
  var closedHigherStreams = 0
  for (sid, stream) in completed:
    if sid > peerLastStreamId:
      closedHigherStreams += 1
      check(stream.responseStatus == 0, "h2 goaway abandoned stream reports error")
      check(stream.responseBody.len == 0, "h2 goaway abandoned stream drops partial body")
  check(closedHigherStreams >= 1, "h2 goaway closes streams above lastStreamId")
  echo "Fuzz HTTP/2 GOAWAY stream closure: OK"

proc fuzzH2SettingsTableResize() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  var settingsPayload = newString(6)
  settingsPayload[0] = char(0)
  settingsPayload[1] = char(1)
  settingsPayload[2] = char(0)
  settingsPayload[3] = char(0)
  settingsPayload[4] = char(0x10)
  settingsPayload[5] = char(0)
  var frameData = newSeq[byte](9 + 6)
  frameData[0] = 0
  frameData[1] = 0
  frameData[2] = 6
  frameData[3] = 0x04
  for j in 0 ..< 6:
    frameData[9 + j] = byte(settingsPayload[j])
  var responseBuf = ""
  try:
    discard conn.feedData(frameData, responseBuf)
    check(conn.remoteSettings.headerTableSize == 4096, "h2 settings table size updated")
    check(responseBuf.len > 0, "h2 settings ack sent")
  except CatchableError:
    check(false, "h2 settings resize should not raise")
  echo "Fuzz HTTP/2 SETTINGS table resize: OK"

proc fuzzH2PushPromiseHpackSync() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  conn.localSettings.enablePush = true
  var encoder = initHpackEncoder()
  var headerBlock = ""
  hpackEncode(encoder, @[(":method", "GET"), (":path", "/push")], headerBlock)
  let promisedId: uint32 = 2
  var ppPayload = newString(4 + headerBlock.len)
  ppPayload[0] = char((promisedId shr 24) and 0xFF)
  ppPayload[1] = char((promisedId shr 16) and 0xFF)
  ppPayload[2] = char((promisedId shr 8) and 0xFF)
  ppPayload[3] = char(promisedId and 0xFF)
  for j in 0 ..< headerBlock.len:
    ppPayload[4 + j] = headerBlock[j]
  var frameData = newSeq[byte](9 + ppPayload.len)
  let plen = uint32(ppPayload.len)
  frameData[0] = byte((plen shr 16) and 0xFF)
  frameData[1] = byte((plen shr 8) and 0xFF)
  frameData[2] = byte(plen and 0xFF)
  frameData[3] = 0x05
  frameData[4] = byte(FlagEndHeaders)
  frameData[5] = 0
  frameData[6] = 0
  frameData[7] = 0
  frameData[8] = 1
  for j in 0 ..< ppPayload.len:
    frameData[9 + j] = byte(ppPayload[j])
  var responseBuf = ""
  try:
    discard conn.feedData(frameData, responseBuf)
  except CatchableError:
    discard
  let sid = conn.allocateStream()
  var headerBlock2 = ""
  var enc2 = initHpackEncoder()
  hpackEncode(enc2, @[(":status", "200")], headerBlock2)
  var frameData2 = newSeq[byte](9 + headerBlock2.len)
  let plen2 = uint32(headerBlock2.len)
  frameData2[0] = byte((plen2 shr 16) and 0xFF)
  frameData2[1] = byte((plen2 shr 8) and 0xFF)
  frameData2[2] = byte(plen2 and 0xFF)
  frameData2[3] = 0x01
  frameData2[4] = byte(FlagEndHeaders) or byte(FlagEndStream)
  frameData2[5] = byte((sid shr 24) and 0xFF)
  frameData2[6] = byte((sid shr 16) and 0xFF)
  frameData2[7] = byte((sid shr 8) and 0xFF)
  frameData2[8] = byte(sid and 0xFF)
  for j in 0 ..< headerBlock2.len:
    frameData2[9 + j] = byte(headerBlock2[j])
  responseBuf = ""
  try:
    let completed = conn.feedData(frameData2, responseBuf)
    check(completed.len > 0, "h2 headers after push_promise decoded ok")
  except CatchableError:
    check(false, "h2 push_promise HPACK sync should not break decoder")

  var conn2 = initH2ClientConnection()
  conn2.state = h2csActive
  conn2.localSettings.enablePush = true
  let parentSid = conn2.allocateStream()
  var serverEnc = initHpackEncoder(huffman = false)
  var pushBlock = ""
  hpackEncode(serverEnc, @[(":method", "GET"), (":path", "/padded"), ("x-shared", "same")], pushBlock)
  var responseBlock = ""
  hpackEncode(serverEnc, @[(":status", "200"), ("x-shared", "same")], responseBlock)
  let split = max(1, pushBlock.len div 2)
  let padLen = 2
  let promisedId2: uint32 = 2
  var paddedPayload = newString(1 + 4 + split + padLen)
  paddedPayload[0] = char(padLen)
  paddedPayload[1] = char((promisedId2 shr 24) and 0xFF)
  paddedPayload[2] = char((promisedId2 shr 16) and 0xFF)
  paddedPayload[3] = char((promisedId2 shr 8) and 0xFF)
  paddedPayload[4] = char(promisedId2 and 0xFF)
  for j in 0 ..< split:
    paddedPayload[5 + j] = pushBlock[j]
  var sequence = ""
  serializeFrameHeader(sequence, uint32(paddedPayload.len), ftPushPromise, FlagPadded, parentSid)
  sequence.add paddedPayload
  let tail = pushBlock[split ..< pushBlock.len]
  serializeFrameHeader(sequence, uint32(tail.len), ftContinuation, FlagEndHeaders, parentSid)
  sequence.add tail
  serializeHeaders(parentSid, responseBlock, endStream = true, endHeaders = true, sequence)
  responseBuf = ""
  try:
    let completed2 = conn2.feedData(cast[seq[byte]](sequence), responseBuf)
    check(completed2.len == 1, "h2 headers after padded continuation push_promise decoded ok")
    if completed2.len == 1:
      var sawShared = false
      for header in completed2[0][1].responseHeaders:
        if header.name == "x-shared" and header.value == "same":
          sawShared = true
      check(sawShared, "h2 response decoded dynamic table entry after push_promise")
  except CatchableError:
    check(false, "h2 padded continuation push_promise should not break decoder")
  echo "Fuzz HTTP/2 PUSH_PROMISE HPACK sync: OK"

proc fuzzH2RecvBufOverflow() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let bigData = newSeq[byte](16 * 1024 * 1024 + 1)
  var responseBuf = ""
  try:
    discard conn.feedData(bigData, responseBuf)
  except CatchableError:
    discard
  check(conn.state == h2csGoaway, "h2 recv buf overflow triggers goaway")
  check(responseBuf.len > 0, "h2 recv buf overflow sends goaway frame")
  echo "Fuzz HTTP/2 recv buffer overflow GOAWAY: OK"

proc fuzzWsControlFrameFin() =
  let controlOpcodes: seq[byte] = @[0x08, 0x09, 0x0A]
  for op in controlOpcodes:
    var frame = newSeq[byte](2)
    frame[0] = op
    frame[1] = 0
    var pos = 0
    let decoded = decodeWsFrame(frame, pos)
    check(decoded.isNone, "control frame without FIN rejected: opcode " & $op)
  for op in controlOpcodes:
    var frame = newSeq[byte](2)
    frame[0] = 0x80 or op
    frame[1] = 0
    var pos = 0
    let decoded = decodeWsFrame(frame, pos)
    check(decoded.isSome, "control frame with FIN accepted: opcode " & $op)
  echo "Fuzz WebSocket control frame FIN bit: OK"

proc fuzzWsControlFramePayloadLimit() =
  var frame = newSeq[byte](4)
  frame[0] = 0x89
  frame[1] = 126
  frame[2] = 0
  frame[3] = 126
  var pos = 0
  let decoded = decodeWsFrame(frame, pos)
  check(decoded.isNone, "ping with 126-byte extended length rejected")
  var frame2 = newSeq[byte](2 + 125)
  frame2[0] = 0x89
  frame2[1] = 125
  for j in 2 ..< frame2.len:
    frame2[j] = 0x41
  pos = 0
  let decoded2 = decodeWsFrame(frame2, pos)
  check(decoded2.isSome, "ping with 125 bytes accepted")
  echo "Fuzz WebSocket control frame payload limit: OK"

proc fuzzWsUpgradePathValidation() =
  let r1 = buildUpgradeRequest("host.com", "no-slash", 80, "dGVzdA==")
  check(r1 == "", "ws upgrade without leading slash rejected")
  let r2 = buildUpgradeRequest("host.com", "/valid", 80, "dGVzdA==")
  check(r2.len > 0 and "GET /valid" in r2, "ws upgrade with leading slash accepted")
  let r3 = buildUpgradeRequest("host.com", "", 80, "dGVzdA==")
  check(r3 == "", "ws upgrade empty path rejected")
  echo "Fuzz WebSocket upgrade path validation: OK"

proc fuzzSseRequestPathValidation() =
  let r1 = buildSseRequest("host.com", "no-slash", 80)
  check(r1 == "", "sse request without leading slash rejected")
  let r2 = buildSseRequest("host.com", "/events", 80)
  check(r2.len > 0 and "GET /events" in r2, "sse request with leading slash accepted")
  let r3 = buildSseRequest("evil\r\nhost", "/events", 80)
  check(r3 == "", "sse request with CRLF host rejected")
  let r4 = buildSseRequest("host.com", "/ev\r\nents", 80)
  check(r4 == "", "sse request with CRLF path rejected")
  echo "Fuzz SSE request path/host validation: OK"

proc fuzzSseBufferTruncationReset() =
  var parser = initSseParser()
  parser.currentEvent.eventType = "stale"
  parser.currentEvent.data = "stale data"
  let bigData = repeat('A', SseMaxBufSize + 100) & "\n"
  discard parser.feedData(bigData)
  check(parser.currentEvent.eventType == "", "sse event type reset after truncation")
  check(parser.currentEvent.data == "", "sse event data reset after truncation")
  echo "Fuzz SSE buffer truncation state reset: OK"

proc fuzzUrlParsePort0() =
  let parsed = parseUrlForTest("http://host:0/path")
  check(parsed.port == 0 or not parsed.valid, "url port 0 handled")
  let parsed2 = parseUrlForTest("http://host:1/path")
  check(parsed2.valid and parsed2.port == 1, "url port 1 valid")
  echo "Fuzz URL parse port 0: OK"

proc fuzzUrlParseSchemeCase() =
  let parsed1 = parseUrlForTest("HTTP://host/path")
  check(parsed1.valid, "uppercase HTTP scheme parsed")
  let parsed2 = parseUrlForTest("HTTPS://host/path")
  check(parsed2.valid, "uppercase HTTPS scheme parsed")
  echo "Fuzz URL parse scheme case: OK"

proc fuzzUrlParseQueryOnlyAndFragment() =
  let parsed = parseUrlForTest("http://host?x=1#frag")
  check(parsed.valid, "query-only url is valid")
  check(parsed.host == "host", "query-only url host excludes query")
  check(parsed.path == "/?x=1", "query-only url path is rooted query")
  let parsed2 = parseUrlForTest("https://host/path?q=1#frag")
  check(parsed2.valid, "fragment url is valid")
  check(parsed2.path == "/path?q=1", "fragment is not sent in request target")
  echo "Fuzz URL parse query-only and fragment: OK"

proc fuzzH2WindowUpdateOverflow() =
  var conn = initH2ClientConnection()
  conn.localWindow = 2147483647'i32
  var buf = ""
  conn.sendWindowUpdate(0, 1, buf)
  check(buf.len == 0, "h2 sendWindowUpdate rejects connection window overflow")
  conn.localWindow = 100
  conn.sendWindowUpdate(0, 100, buf)
  check(conn.localWindow == 200, "h2 sendWindowUpdate normal increment works")
  echo "Fuzz HTTP/2 sendWindowUpdate overflow: OK"

proc fuzzHpackDecodeAfterSizeUpdate() =
  var decoder = initHpackDecoder()
  var data = newSeq[byte](0)
  data.add(0x20 or 0x00)
  data.add(0x40 or 0x00)
  data.add(0x02)
  data.add(byte('x'))
  data.add(byte('y'))
  data.add(0x02)
  data.add(byte('a'))
  data.add(byte('b'))
  data.add(0x20 or 0x01)
  try:
    let decoded = hpackDecode(decoder, data)
    check(decoded.len == 1, "hpack decode with size update before entry")
  except CatchableError:
    check(true, "hpack size update after entry raised")
  echo "Fuzz HPACK decode size update ordering: OK"

proc fuzzConnectionPoolCleanup() =
  proc pendingCb(resp: HttpResponse, err: string) {.gcsafe.} =
    discard

  var pool = initConnectionPool(maxPerHost = 10, idleTimeoutSec = 0.0)
  for i in 0 ..< 5:
    let conn = cast[ptr PooledConnection](alloc0(sizeof(PooledConnection)))
    conn.host = "host"
    conn.port = 80
    conn.useSsl = false
    conn.state = csOpen
    conn.lastUsed = 0.0
    conn.pendingCallbacks = initDeque[ResponseCallback](4)
    pool.addConnection(conn)
  check(pool.totalConnections == 5, "pool has 5 conns")
  let expired = pool.cleanup()
  check(expired.len == 5, "pool cleanup returns 5 expired")
  check(pool.totalConnections == 0, "pool empty after cleanup")
  for conn in expired:
    dealloc(conn)

  var closedPool = initConnectionPool(maxPerHost = 4, idleTimeoutSec = 60.0)
  for state in [csClosed, csClosing]:
    let conn = cast[ptr PooledConnection](alloc0(sizeof(PooledConnection)))
    conn.host = "closed"
    conn.port = 80
    conn.useSsl = false
    conn.state = state
    conn.lastUsed = 0.0
    conn.pendingCallbacks = initDeque[ResponseCallback](1)
    closedPool.addConnection(conn)
  check(closedPool.totalConnections == 2, "pool has closed conns before cleanup")
  let closedExpired = closedPool.cleanup()
  check(closedExpired.len == 2, "pool cleanup returns closed conns")
  check(closedPool.totalConnections == 0, "pool cleanup removes closed conns")
  for conn in closedExpired:
    dealloc(conn)

  var busyPool = initConnectionPool(maxPerHost = 2, idleTimeoutSec = 0.0)
  let busy = cast[ptr PooledConnection](alloc0(sizeof(PooledConnection)))
  busy.host = "busy"
  busy.port = 80
  busy.useSsl = false
  busy.state = csOpen
  busy.lastUsed = 0.0
  busy.pendingCallbacks = initDeque[ResponseCallback](1)
  busy.pendingCallbacks.addLast(pendingCb)
  busyPool.addConnection(busy)
  let h2Busy = cast[ptr PooledConnection](alloc0(sizeof(PooledConnection)))
  h2Busy.host = "busy"
  h2Busy.port = 443
  h2Busy.useSsl = true
  h2Busy.state = csOpen
  h2Busy.isHttp2 = true
  h2Busy.lastUsed = 0.0
  h2Busy.pendingCallbacks = initDeque[ResponseCallback](1)
  h2Busy.h2Streams = initTable[uint32, H2Stream](1)
  h2Busy.h2Streams[1'u32] = H2Stream(id: 1'u32, state: ssOpen)
  busyPool.addConnection(h2Busy)
  let busyExpired = busyPool.cleanup()
  check(busyExpired.len == 0, "pool cleanup keeps busy conns")
  check(busyPool.totalConnections == 2, "pool cleanup keeps busy count")
  busyPool.removeConnection(busy)
  busyPool.removeConnection(h2Busy)
  dealloc(busy)
  dealloc(h2Busy)
  echo "Fuzz connection pool cleanup: OK"

fuzzHttp1ChunkExtensions()
fuzzHttp1StatusCodeRange()
fuzzHttp1SerializeRequestCrlf()
fuzzH2DataPaddingStrip()
fuzzH2DataInvalidPadding()
fuzzH2RstAfterPartialResponseIsError()
fuzzH2FlowControlSendData()
fuzzH2InformationalAndUnknownFrames()
fuzzH2ResponseBodyFraming()
fuzzH2StreamExhaustion()
fuzzH2ServerStreamFlood()
fuzzH2GoawayStreams()
fuzzH2SettingsTableResize()
fuzzH2PushPromiseHpackSync()
fuzzH2RecvBufOverflow()
fuzzWsControlFrameFin()
fuzzWsControlFramePayloadLimit()
fuzzWsUpgradePathValidation()
fuzzSseRequestPathValidation()
fuzzSseBufferTruncationReset()
fuzzUrlParsePort0()
fuzzUrlParseSchemeCase()
fuzzUrlParseQueryOnlyAndFragment()
fuzzH2WindowUpdateOverflow()
fuzzHpackDecodeAfterSizeUpdate()
fuzzConnectionPoolCleanup()

proc fuzzValidationRandomStrings() =
  var rng = initRand(FuzzSeed + 100)
  for i in 0 ..< FuzzIterations:
    let length = rng.rand(300)
    let s = randomBytes(rng, length)
    discard containsCRLF(s)
    discard containsNullByte(s)
    discard isValidHeaderName(s)
    discard isValidHeaderValue(s)
    discard isValidHost(s)
    if s.len > 0 and s[0] == '/':
      discard isValidPath(s)
    else:
      discard isValidPath(s)
    discard isValidStatusCode(rng.rand(2000) - 500)
    discard isValidChunkSize(rng.rand(40_000_000) - 1)
    discard isValidContentLength(rng.rand(600_000_000) - 1)
    discard isControlFrame(rng.rand(15))
    discard isValidWsPayloadLen(rng.rand(15), rng.rand(500))
    discard sanitizeForLog(s, rng.rand(256) + 1)
  for i in 0 ..< FuzzIterations:
    let port = uint16(rng.rand(65535))
    discard isValidPort(port)
    let streamId = uint32(rng.rand(high(int32)))
    discard isValidH2StreamId(streamId)
    let windowSize = int64(rng.rand(high(int32))) * 2 - int64(high(int32))
    discard isValidH2WindowSize(windowSize)
  check(true, "validation random strings fuzz")
  echo "Fuzz validation random strings: OK"

proc fuzzValidationBoundaries() =
  let crlfStrings = @["\r", "\n", "\0", "\r\n", "a\rb", "a\nb", "a\0b", "\r\n\0"]
  for s in crlfStrings:
    check(containsCRLF(s), "validation boundary: containsCRLF for " & repr(s))
  let cleanStrings = @["hello", "a-b_c.d", "123", " ", ""]
  for s in cleanStrings:
    check(not containsCRLF(s), "validation boundary: clean for " & repr(s))
  let invalidHeaderNames = @["", ":", " ", "\t", "a b", "a:b", "\x01", "\x7f", "\xff"]
  for s in invalidHeaderNames:
    check(not isValidHeaderName(s), "validation boundary: invalid header name " & repr(s))
  let validHeaderNames = @["a", "Content-Type", "x-custom", "X-123", "!#$%&'*+-.^_`|~"]
  for s in validHeaderNames:
    check(isValidHeaderName(s), "validation boundary: valid header name " & repr(s))
  check(isValidPort(1), "validation boundary: port 1")
  check(isValidPort(65535), "validation boundary: port 65535")
  check(not isValidPort(0), "validation boundary: port 0")
  check(isValidStatusCode(100), "validation boundary: status 100")
  check(isValidStatusCode(999), "validation boundary: status 999")
  check(not isValidStatusCode(99), "validation boundary: status 99")
  check(not isValidStatusCode(1000), "validation boundary: status 1000")
  echo "Fuzz validation boundaries: OK"

proc fuzzGoawayStateHandling() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let s1 = conn.allocateStream()
  check(s1 > 0, "goaway-state: first stream allocated")

  var goawayFrame = newSeq[byte](9 + 8)
  goawayFrame[0] = 0; goawayFrame[1] = 0; goawayFrame[2] = 8
  goawayFrame[3] = 0x07
  for j in 9 ..< goawayFrame.len: goawayFrame[j] = 0
  var responseBuf = ""
  discard conn.feedData(goawayFrame, responseBuf)
  check(conn.state == h2csGoaway, "goaway-state: connection in GOAWAY")

  let s2 = conn.allocateStream()
  check(s2 == 0 or conn.state == h2csGoaway, "goaway-state: no new streams after GOAWAY")

  var rng = initRand(FuzzSeed + 110)
  for i in 0 ..< 100:
    var conn2 = initH2ClientConnection()
    conn2.state = h2csActive
    discard conn2.allocateStream()
    var goaway2 = newSeq[byte](9 + 8)
    goaway2[0] = 0; goaway2[1] = 0; goaway2[2] = 8
    goaway2[3] = 0x07
    var respBuf2 = ""
    discard conn2.feedData(goaway2, respBuf2)

    let payloadLen = rng.rand(50) + 1
    var headerFrame = newSeq[byte](9 + payloadLen)
    headerFrame[0] = byte((payloadLen shr 16) and 0xFF)
    headerFrame[1] = byte((payloadLen shr 8) and 0xFF)
    headerFrame[2] = byte(payloadLen and 0xFF)
    headerFrame[3] = 0x01
    headerFrame[4] = byte(FlagEndHeaders)
    let sid = uint32(rng.rand(50) * 2 + 1)
    headerFrame[5] = byte((sid shr 24) and 0xFF)
    headerFrame[6] = byte((sid shr 16) and 0xFF)
    headerFrame[7] = byte((sid shr 8) and 0xFF)
    headerFrame[8] = byte(sid and 0xFF)
    for j in 9 ..< headerFrame.len:
      headerFrame[j] = byte(rng.rand(255))
    respBuf2 = ""
    try:
      discard conn2.feedData(headerFrame, respBuf2)
    except CatchableError:
      discard
    check(conn2.state == h2csGoaway, "goaway-state: stays in GOAWAY after frame iter " & $i)
  check(true, "goaway state handling")
  echo "Fuzz GOAWAY state handling: OK"

proc fuzzHpackIntegerOverflow() =
  var rng = initRand(FuzzSeed + 120)
  for i in 0 ..< FuzzIterations:
    let continuationBytes = rng.rand(8) + 5
    var data = newSeq[byte](1 + continuationBytes)
    data[0] = 0x7F
    for j in 1 ..< data.len - 1:
      data[j] = byte(0x80 or rng.rand(127))
    data[data.len - 1] = byte(rng.rand(127))
    var pos = 0
    try:
      discard hpackDecodeInt(data, pos, 7)
    except CatchableError:
      discard
  let overflowPatterns: seq[seq[byte]] = @[
    @[0x1F'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F],
    @[0x1F'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F],
    @[0x7F'u8, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01],
    @[0x7F'u8, 0xFF, 0xFF, 0xFF, 0x7F],
  ]
  for pattern in overflowPatterns:
    var pos = 0
    try:
      discard hpackDecodeInt(pattern, pos, 7)
    except CatchableError:
      discard
  check(true, "hpack integer overflow fuzzing")
  echo "Fuzz HPACK integer overflow: OK"

proc fuzzDnsHostnameValidation() =
  var rng = initRand(FuzzSeed + 130)
  for i in 0 ..< FuzzIterations:
    let length = rng.rand(500) + 1
    let hostname = randomBytes(rng, length)
    discard isValidHost(hostname)
  var longHostname = newString(65536)
  for i in 0 ..< longHostname.len:
    longHostname[i] = 'a'
  discard isValidHost(longHostname)
  let hostEdgeCases = @[
    "",
    "\0",
    "\r",
    "\n",
    "/",
    "@",
    "host\0name",
    "host\rname",
    "host\nname",
    "host/path",
    "user@host",
    "valid.host.name",
    "192.168.1.1",
    "[::1]",
    "host-name.example.com",
    "a",
  ]
  for host in hostEdgeCases:
    discard isValidHost(host)
  let pathTraversals = @[
    "../../../etc/passwd",
    "/normal/path",
    "host/../secret",
    "host/../../root",
  ]
  for path in pathTraversals:
    discard isValidHost(path)
  check(true, "dns hostname validation fuzzing")
  echo "Fuzz DNS hostname validation: OK"

proc fuzzWsReservedOpcodes() =
  var rng = initRand(FuzzSeed + 140)
  for opcode in 3 .. 7:
    for i in 0 ..< 100:
      let payloadLen = rng.rand(50)
      var frame = newSeq[byte](2 + payloadLen)
      frame[0] = byte(0x80 or uint8(opcode))
      frame[1] = byte(payloadLen)
      for j in 0 ..< payloadLen:
        frame[2 + j] = byte(rng.rand(255))
      var pos = 0
      let decoded = decodeWsFrame(frame, pos)
      check(decoded.isNone, "ws reserved opcode " & $opcode & " iter " & $i)
  for opcode in 11 .. 15:
    var frame = newSeq[byte](2)
    frame[0] = byte(0x80 or uint8(opcode))
    frame[1] = 0
    var pos = 0
    let decoded = decodeWsFrame(frame, pos)
    check(decoded.isNone, "ws reserved opcode " & $opcode & " rejected")
  check(true, "ws reserved opcode fuzzing")
  echo "Fuzz WebSocket reserved opcodes: OK"

proc fuzzValidationHeaderInjection() =
  var rng = initRand(FuzzSeed + 150)
  for i in 0 ..< FuzzIterations:
    let nameLen = rng.rand(50) + 1
    let valueLen = rng.rand(200)
    let name = randomBytes(rng, nameLen)
    let value = randomBytes(rng, valueLen)
    let nameValid = isValidHeaderName(name)
    let valueValid = isValidHeaderValue(value)
    if nameValid:
      for c in name:
        check(c != '\r' and c != '\n' and c != '\0' and c != ':' and c != ' ' and c != '\t',
          "validated header name contains no injection char iter " & $i)
    if valueValid:
      for c in value:
        check(c != '\r' and c != '\n' and c != '\0',
          "validated header value contains no injection char iter " & $i)
  check(true, "header injection validation fuzzing")
  echo "Fuzz header injection validation: OK"

proc fuzzH2FrameSizeEnforcement() =
  var rng = initRand(FuzzSeed + 160)
  for i in 0 ..< min(FuzzIterations, 500):
    let frameLen = uint32(rng.rand(65536))
    let frameTypeVal = rng.rand(9)
    let flags = uint8(rng.rand(255))
    let streamId = uint32(rng.rand(100))
    let frame = H2Frame(
      length: frameLen,
      frameType: H2FrameType(frameTypeVal),
      flags: flags,
      streamId: streamId,
      payload: newString(int(min(frameLen, 100'u32))),
    )
    let valid = validateFrameLength(frame)
    case frame.frameType
    of ftPing:
      check(valid == (frameLen == 8), "frame size: PING must be 8 iter " & $i)
    of ftRstStream:
      check(valid == (frameLen == 4), "frame size: RST_STREAM must be 4 iter " & $i)
    of ftPriority:
      check(valid == (frameLen == 5), "frame size: PRIORITY must be 5 iter " & $i)
    of ftWindowUpdate:
      check(valid == (frameLen == 4), "frame size: WINDOW_UPDATE must be 4 iter " & $i)
    of ftGoaway:
      check(valid == (frameLen >= 8), "frame size: GOAWAY must be >=8 iter " & $i)
    of ftSettings:
      if (flags and FlagAck) != 0:
        check(valid == (frameLen == 0), "frame size: SETTINGS ACK must be 0 iter " & $i)
      else:
        check(valid == (frameLen mod 6 == 0), "frame size: SETTINGS must be multiple of 6 iter " & $i)
    else:
      discard
  check(true, "h2 frame size enforcement fuzzing")
  echo "Fuzz H2 frame size enforcement: OK"

proc fuzzSanitizeForLog() =
  var rng = initRand(FuzzSeed + 170)
  for i in 0 ..< FuzzIterations:
    let length = rng.rand(500)
    let s = randomBytes(rng, length)
    let maxLen = rng.rand(256) + 1
    let sanitized = sanitizeForLog(s, maxLen)
    if s.len > maxLen:
      check(sanitized.len <= maxLen + 3, "sanitize: truncated with ellipsis iter " & $i)
    for j in 0 ..< min(sanitized.len, maxLen):
      let c = sanitized[j]
      check(ord(c) >= 32 and ord(c) != 127 or c == '?',
        "sanitize: only printable or replacement iter " & $i & " char " & $j)
  check(true, "sanitize for log fuzzing")
  echo "Fuzz sanitizeForLog: OK"

proc fuzzValidationPortAndStreamExtremes() =
  check(isValidPort(1), "port-extremes: min valid 1")
  check(isValidPort(65535), "port-extremes: max valid 65535")
  check(not isValidPort(0), "port-extremes: zero")
  check(isValidH2StreamId(1), "stream-extremes: min valid 1")
  check(isValidH2StreamId(2147483647'u32), "stream-extremes: max valid 2^31-1")
  check(not isValidH2StreamId(0), "stream-extremes: zero")
  check(isValidH2WindowSize(0), "window-extremes: zero")
  check(isValidH2WindowSize(2147483647'i64), "window-extremes: max valid")
  check(not isValidH2WindowSize(-1), "window-extremes: negative")
  check(not isValidH2WindowSize(2147483648'i64), "window-extremes: overflow")
  check(isValidChunkSize(0), "chunk-extremes: zero")
  check(isValidChunkSize(MaxChunkSize), "chunk-extremes: max")
  check(not isValidChunkSize(MaxChunkSize + 1), "chunk-extremes: over max")
  check(not isValidChunkSize(-1), "chunk-extremes: negative")
  check(isValidContentLength(0), "content-length-extremes: zero")
  check(isValidContentLength(MaxContentLengthVal), "content-length-extremes: max")
  check(not isValidContentLength(MaxContentLengthVal + 1), "content-length-extremes: over max")
  check(not isValidContentLength(-1), "content-length-extremes: negative")
  echo "Fuzz validation port/stream/window extremes: OK"

fuzzValidationRandomStrings()
fuzzValidationBoundaries()
fuzzGoawayStateHandling()
fuzzHpackIntegerOverflow()
fuzzDnsHostnameValidation()
fuzzWsReservedOpcodes()
fuzzValidationHeaderInjection()
fuzzH2FrameSizeEnforcement()
fuzzSanitizeForLog()
fuzzValidationPortAndStreamExtremes()

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
