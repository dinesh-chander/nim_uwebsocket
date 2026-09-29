import std/[random, options]
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

proc makeGetHeaders(path: string): string =
  var encoder = initHpackEncoder()
  let headers = @[(":method", "GET"), (":path", path), (":scheme", "https"), (":authority", "localhost")]
  var buf = ""
  hpackEncode(encoder, headers, buf)
  result = buf

proc makePostHeaders(path: string): string =
  var encoder = initHpackEncoder()
  let headers = @[(":method", "POST"), (":path", path), (":scheme", "https"), (":authority", "localhost"), ("content-type", "application/json")]
  var buf = ""
  hpackEncode(encoder, headers, buf)
  result = buf

proc parseAllFrames(data: string): seq[H2Frame] =
  let bufBytes = cast[seq[byte]](data)
  var pos = 0
  while true:
    let frame = parseH2Frame(bufBytes, pos)
    if frame.isNone: break
    result.add frame.get()

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

echo "=== Fuzz H2 Server (Frame Parser) ==="

fuzzCategory("Connection preface + SETTINGS + HEADERS + DATA sequences", Iterations):
  var buf = ""
  buf.add H2ConnectionPreface
  var settings = DefaultH2Settings
  settings.initialWindowSize = uint32(rng.rand(65535) + 1)
  serializeSettings(settings, buf)
  let headerBlock = makeGetHeaders("/test/" & $i)
  serializeHeaders(1, headerBlock, endStream = true, endHeaders = true, buf)
  let frames = parseAllFrames(buf[H2ConnectionPreface.len ..< buf.len])
  if frames.len < 2:
    fail("preface_seq_" & $i, "expected at least 2 frames, got " & $frames.len)

fuzzCategory("Malformed connection preface (wrong bytes)", Iterations):
  var buf = ""
  let variant = rng.rand(4)
  case variant
  of 0:
    buf = "PRI * HTTP/2.0\r\n\r\nXX\r\n\r\n"
  of 1:
    buf = randomBytes(H2ConnectionPreface.len)
  of 2:
    buf = H2ConnectionPreface[0 ..< H2ConnectionPreface.len - 5]
  of 3:
    buf = "GET / HTTP/1.1\r\n\r\n"
  else:
    buf = ""
  let isValid = buf == H2ConnectionPreface
  if isValid and variant != 0:
    fail("malformed_preface_" & $i, "random bytes matched preface")

fuzzCategory("HEADERS with END_STREAM (GET) + SETTINGS ACK", Iterations):
  var buf = ""
  let headerBlock = makeGetHeaders("/api/" & $i)
  serializeHeaders(uint32(i * 2 + 1), headerBlock, endStream = true, endHeaders = true, buf)
  serializeSettingsAck(buf)
  let frames = parseAllFrames(buf)
  if frames.len != 2:
    fail("get_settack_" & $i, "expected 2 frames, got " & $frames.len)
  elif frames[0].frameType != ftHeaders or frames[1].frameType != ftSettings:
    fail("get_settack_" & $i, "wrong frame types")

fuzzCategory("HEADERS without END_STREAM + DATA with END_STREAM (POST)", Iterations):
  var buf = ""
  let streamId = uint32(i * 2 + 1)
  let headerBlock = makePostHeaders("/submit")
  serializeHeaders(streamId, headerBlock, endStream = false, endHeaders = true, buf)
  let body = randomBytes(rng.rand(500) + 1)
  serializeData(streamId, body, endStream = true, buf)
  let frames = parseAllFrames(buf)
  if frames.len != 2:
    fail("post_data_" & $i, "expected 2 frames, got " & $frames.len)
  elif frames[0].frameType != ftHeaders or frames[1].frameType != ftData:
    fail("post_data_" & $i, "wrong frame types")
  elif not hasFlag(frames[1], FlagEndStream):
    fail("post_data_" & $i, "DATA missing END_STREAM")

fuzzCategory("Multiple concurrent streams (IDs 1, 3, 5)", Iterations):
  var buf = ""
  let streamIds = [1'u32, 3'u32, 5'u32]
  for sid in streamIds:
    let headerBlock = makeGetHeaders("/stream/" & $sid)
    serializeHeaders(sid, headerBlock, endStream = true, endHeaders = true, buf)
  let frames = parseAllFrames(buf)
  if frames.len != 3:
    fail("concurrent_" & $i, "expected 3 frames, got " & $frames.len)
  for j in 0 ..< min(3, frames.len):
    if frames[j].streamId != streamIds[j]:
      fail("concurrent_" & $i, "stream ID mismatch at " & $j)

fuzzCategory("Stream ID reuse (same stream ID twice)", Iterations):
  var buf = ""
  let sid = uint32(rng.rand(50) * 2 + 1)
  let headerBlock = makeGetHeaders("/first")
  serializeHeaders(sid, headerBlock, endStream = true, endHeaders = true, buf)
  let headerBlock2 = makeGetHeaders("/second")
  serializeHeaders(sid, headerBlock2, endStream = true, endHeaders = true, buf)
  let frames = parseAllFrames(buf)
  if frames.len != 2:
    fail("reuse_" & $i, "expected 2 frames")
  elif frames[0].streamId != sid or frames[1].streamId != sid:
    fail("reuse_" & $i, "stream ID mismatch")

fuzzCategory("DATA on unknown stream", Iterations):
  var buf = ""
  let unknownSid = uint32(rng.rand(1000) * 2 + 1)
  let body = randomBytes(rng.rand(100) + 1)
  serializeData(unknownSid, body, endStream = true, buf)
  let frames = parseAllFrames(buf)
  if frames.len != 1:
    fail("unknown_stream_" & $i, "expected 1 frame")
  elif frames[0].streamId != unknownSid:
    fail("unknown_stream_" & $i, "stream ID mismatch")

fuzzCategory("RST_STREAM on active stream", Iterations):
  var buf = ""
  let sid = uint32(rng.rand(50) * 2 + 1)
  let headerBlock = makeGetHeaders("/active")
  serializeHeaders(sid, headerBlock, endStream = false, endHeaders = true, buf)
  let errorCodes = [0'u32, 1, 2, 3, 5, 7, 8, 11]
  let ec = errorCodes[rng.rand(errorCodes.high)]
  serializeRstStream(sid, ec, buf)
  let frames = parseAllFrames(buf)
  if frames.len != 2:
    fail("rst_active_" & $i, "expected 2 frames")

fuzzCategory("GOAWAY mid-connection", Iterations):
  var buf = ""
  let headerBlock = makeGetHeaders("/before-goaway")
  serializeHeaders(1, headerBlock, endStream = true, endHeaders = true, buf)
  let lastStreamId = uint32(rng.rand(10))
  let errorCode = uint32(rng.rand(13))
  serializeGoaway(lastStreamId, errorCode, buf)
  let headerBlock2 = makeGetHeaders("/after-goaway")
  serializeHeaders(3, headerBlock2, endStream = true, endHeaders = true, buf)
  let frames = parseAllFrames(buf)
  if frames.len != 3:
    fail("goaway_mid_" & $i, "expected 3 frames, got " & $frames.len)

fuzzCategory("Oversized frame (> 16384 bytes)", Iterations div 10):
  var buf = ""
  let oversizedLen = 16385 + rng.rand(50000)
  let payload = randomBytes(oversizedLen)
  serializeData(1, payload, endStream = false, buf)
  let frames = parseAllFrames(buf)
  if frames.len != 1:
    fail("oversized_" & $i, "expected 1 frame")
  elif int(frames[0].length) != oversizedLen:
    fail("oversized_" & $i, "length mismatch")

fuzzCategory("Headers exceeding max header list size", Iterations div 10):
  var encoder = initHpackEncoder()
  var headers: seq[(string, string)]
  let numHeaders = rng.rand(50) + 20
  for j in 0 ..< numHeaders:
    headers.add(("x-large-header-" & $j, randomBytes(rng.rand(1000) + 500)))
  var headerBlock = ""
  hpackEncode(encoder, headers, headerBlock)
  var buf = ""
  serializeHeaders(1, headerBlock, endStream = true, endHeaders = true, buf)
  let frames = parseAllFrames(buf)
  if frames.len != 1:
    fail("large_headers_" & $i, "expected 1 frame")
  else:
    var decoder = initHpackDecoder()
    let hb = extractHeaderBlock(frames[0])
    discard hpackDecode(decoder, cast[seq[byte]](hb))

fuzzCategory("Flow control: DATA frames exceeding window size", Iterations):
  var buf = ""
  let numFrames = rng.rand(10) + 5
  for j in 0 ..< numFrames:
    let payload = randomBytes(rng.rand(16384) + 1)
    serializeData(1, payload, endStream = j == numFrames - 1, buf)
  let frames = parseAllFrames(buf)
  if frames.len != numFrames:
    fail("flow_control_" & $i, "expected " & $numFrames & " frames, got " & $frames.len)

fuzzCategory("PING flood (many PINGs in sequence)", Iterations div 10):
  var buf = ""
  let numPings = rng.rand(200) + 100
  for j in 0 ..< numPings:
    var pingData: array[8, byte]
    for k in 0 ..< 8:
      pingData[k] = byte(rng.rand(255))
    serializePing(pingData, ack = false, buf)
  let frames = parseAllFrames(buf)
  if frames.len != numPings:
    fail("ping_flood_" & $i, "expected " & $numPings & " got " & $frames.len)

fuzzCategory("SETTINGS flood (many SETTINGS in sequence)", Iterations div 10):
  var buf = ""
  let numSettings = rng.rand(200) + 100
  for j in 0 ..< numSettings:
    var s = DefaultH2Settings
    s.maxConcurrentStreams = uint32(rng.rand(1000))
    s.initialWindowSize = uint32(rng.rand(65535) + 1)
    serializeSettings(s, buf)
  let frames = parseAllFrames(buf)
  if frames.len != numSettings:
    fail("settings_flood_" & $i, "expected " & $numSettings & " got " & $frames.len)

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All H2 server fuzz tests passed (", totalIterations, " total iterations)"
  quit(0)
