import std/[random, options, tables]
import ../nim_fasthttpclient/src/nim_fasthttpclient/types
import ../nim_fasthttpclient/src/nim_fasthttpclient/http2
import ../nim_usockets/src/nim_usockets/h2_protocol
import ../nim_usockets/src/nim_usockets/hpack

const
  Iterations = 10_000
  ProgressInterval = 1000

var rng = initRand(42)
var totalIterations = 0
var failures: seq[string]

proc fail(label, msg: string) =
  failures.add label & ": " & msg

proc randomBytes(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(255))

proc makeResponseHeaders(statusCode: int, extra: seq[(string, string)] = @[]): string =
  var encoder = initHpackEncoder()
  var headers = @[(":status", $statusCode)]
  for (k, v) in extra:
    headers.add((k, v))
  var buf = ""
  hpackEncode(encoder, headers, buf)
  result = buf

template fuzzCategory(name: string, iters: int, body: untyped) =
  echo "Category: ", name
  for i {.inject.} in 0 ..< iters:
    try:
      body
    except CatchableError:
      discard
    inc totalIterations
    if totalIterations mod ProgressInterval == 0:
      echo "  progress: ", totalIterations

echo "=== Fuzz H2 Client Connection ==="

fuzzCategory("SETTINGS + SETTINGS ACK exchange", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  var serverBuf = ""
  var settings = DefaultH2Settings
  settings.initialWindowSize = uint32(rng.rand(65535) + 1)
  settings.maxConcurrentStreams = uint32(rng.rand(100) + 1)
  serializeSettings(settings, serverBuf)
  serializeSettingsAck(serverBuf)
  var responseBuf = ""
  let data = cast[seq[byte]](serverBuf)
  discard conn.feedData(data, responseBuf)
  if conn.state == h2csClosed:
    fail("settings_exchange_" & $i, "connection closed unexpectedly")

fuzzCategory("HEADERS response with various status codes", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  let statusCodes = [200, 204, 301, 302, 400, 401, 403, 404, 500, 502, 503]
  let status = statusCodes[rng.rand(statusCodes.high)]
  var serverBuf = ""
  let headerBlock = makeResponseHeaders(status, @[("content-type", "text/html")])
  serializeHeaders(sid, headerBlock, endStream = true, endHeaders = true, serverBuf)
  var responseBuf = ""
  let completed = conn.feedData(cast[seq[byte]](serverBuf), responseBuf)
  if completed.len != 1:
    fail("status_response_" & $i, "expected 1 completed stream, got " & $completed.len)
  elif completed[0][1].responseStatus != status:
    fail("status_response_" & $i, "status mismatch: expected " & $status & " got " & $completed[0][1].responseStatus)

fuzzCategory("DATA response with and without END_STREAM", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  var serverBuf = ""
  let headerBlock = makeResponseHeaders(200)
  serializeHeaders(sid, headerBlock, endStream = false, endHeaders = true, serverBuf)
  let body = randomBytes(rng.rand(500) + 1)
  let endStream = rng.rand(1) == 1
  serializeData(sid, body, endStream = endStream, serverBuf)
  var responseBuf = ""
  let completed = conn.feedData(cast[seq[byte]](serverBuf), responseBuf)
  if endStream:
    if completed.len != 1:
      fail("data_response_" & $i, "expected 1 completed stream")
    elif completed[0][1].responseBody != body:
      fail("data_response_" & $i, "body mismatch")

fuzzCategory("WINDOW_UPDATE on connection (stream 0) and on streams", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  let initialConnWindow = conn.remoteWindow
  let initialStreamWindow = conn.streams[sid].sendWindow
  var serverBuf = ""
  let connIncrement = uint32(rng.rand(32767) + 1)
  serializeWindowUpdate(0, connIncrement, serverBuf)
  let streamIncrement = uint32(rng.rand(32767) + 1)
  serializeWindowUpdate(sid, streamIncrement, serverBuf)
  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](serverBuf), responseBuf)
  if conn.remoteWindow != initialConnWindow + int32(connIncrement):
    fail("window_update_" & $i, "connection window mismatch")
  if sid in conn.streams and conn.streams[sid].sendWindow != initialStreamWindow + int32(streamIncrement):
    fail("window_update_" & $i, "stream window mismatch")

fuzzCategory("GOAWAY from server", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  discard conn.allocateStream()
  discard conn.allocateStream()
  var serverBuf = ""
  let lastStreamId = uint32(rng.rand(5))
  let errorCode = uint32(rng.rand(13))
  serializeGoaway(lastStreamId, errorCode, serverBuf)
  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](serverBuf), responseBuf)
  if conn.state != h2csGoaway:
    fail("goaway_" & $i, "expected GOAWAY state")

fuzzCategory("RST_STREAM from server", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  var serverBuf = ""
  let errorCode = uint32(rng.rand(13))
  serializeRstStream(sid, errorCode, serverBuf)
  var responseBuf = ""
  let completed = conn.feedData(cast[seq[byte]](serverBuf), responseBuf)
  if completed.len != 1:
    fail("rst_stream_" & $i, "expected 1 completed (closed) stream")
  elif completed[0][1].state != ssClosed:
    fail("rst_stream_" & $i, "stream should be closed")

fuzzCategory("PING/PONG exchange", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  var pingData: array[8, byte]
  for j in 0 ..< 8:
    pingData[j] = byte(rng.rand(255))
  var serverBuf = ""
  serializePing(pingData, ack = false, serverBuf)
  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](serverBuf), responseBuf)
  if responseBuf.len == 0:
    fail("ping_pong_" & $i, "expected PONG response")
  else:
    let respBytes = cast[seq[byte]](responseBuf)
    var pos = 0
    let pongFrame = parseH2Frame(respBytes, pos)
    if pongFrame.isNone:
      fail("ping_pong_" & $i, "failed to parse PONG frame")
    elif pongFrame.get().frameType != ftPing:
      fail("ping_pong_" & $i, "expected PING frame type for PONG")
    elif not hasFlag(pongFrame.get(), FlagAck):
      fail("ping_pong_" & $i, "PONG missing ACK flag")

fuzzCategory("Flow control: WINDOW_UPDATE overflow (window > 2^31-1)", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  var serverBuf = ""
  let hugeIncrement = uint32(2147483647)
  serializeWindowUpdate(0, hugeIncrement, serverBuf)
  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](serverBuf), responseBuf)
  var serverBuf2 = ""
  serializeWindowUpdate(sid, hugeIncrement, serverBuf2)
  var responseBuf2 = ""
  discard conn.feedData(cast[seq[byte]](serverBuf2), responseBuf2)

fuzzCategory("Invalid SETTINGS values", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  var payload = ""
  let variant = rng.rand(3)
  case variant
  of 0:
    writeU16BE(payload, uint16(0x4))
    writeU32BE(payload, uint32(high(uint32)))
  of 1:
    writeU16BE(payload, uint16(0x5))
    writeU32BE(payload, 100)
  of 2:
    writeU16BE(payload, uint16(0x2))
    writeU32BE(payload, 5)
  else:
    writeU16BE(payload, uint16(0x5))
    writeU32BE(payload, uint32(20_000_000))
  var serverBuf = ""
  serializeFrameHeader(serverBuf, uint32(payload.len), ftSettings, 0, 0)
  serverBuf.add payload
  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](serverBuf), responseBuf)

fuzzCategory("HEADERS without END_HEADERS + CONTINUATION", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  var encoder = initHpackEncoder()
  let headers = @[(":status", "200"), ("content-type", "text/html"), ("x-custom", "value-" & $i)]
  var headerBlock = ""
  hpackEncode(encoder, headers, headerBlock)
  var serverBuf = ""
  if headerBlock.len > 1:
    let splitPoint = rng.rand(headerBlock.len - 1) + 1
    let part1 = headerBlock[0 ..< splitPoint]
    let part2 = headerBlock[splitPoint ..< headerBlock.len]
    serializeFrameHeader(serverBuf, uint32(part1.len), ftHeaders, 0, sid)
    serverBuf.add part1
    serializeFrameHeader(serverBuf, uint32(part2.len), ftContinuation, FlagEndHeaders or FlagEndStream, sid)
    serverBuf.add part2
  else:
    serializeHeaders(sid, headerBlock, endStream = true, endHeaders = true, serverBuf)
  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](serverBuf), responseBuf)

fuzzCategory("Unknown frame types (should be skipped)", Iterations):
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  var serverBuf = ""
  let unknownPayload = randomBytes(rng.rand(50))
  writeU24BE(serverBuf, uint32(unknownPayload.len))
  serverBuf.add char(uint8(rng.rand(245) + 10))
  serverBuf.add char(0'u8)
  writeU32BE(serverBuf, 0'u32)
  serverBuf.add unknownPayload
  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](serverBuf), responseBuf)
  if conn.state == h2csClosed:
    fail("unknown_frame_" & $i, "connection closed on unknown frame type")
  let headerBlock = makeResponseHeaders(200)
  var headerBuf = ""
  serializeHeaders(sid, headerBlock, endStream = true, endHeaders = true, headerBuf)
  var responseBuf2 = ""
  let completed = conn.feedData(cast[seq[byte]](headerBuf), responseBuf2)
  if completed.len != 1:
    fail("unknown_frame_" & $i, "known frame not processed after unknown frame")

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All H2 client fuzz tests passed (", totalIterations, " total iterations)"
  quit(0)
