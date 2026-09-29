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

echo "=== Fuzz H2 Protocol ==="

fuzzCategory("Random bytes fed to parseH2Frame", Iterations):
  let data = randomBytes(rng.rand(512) + 1)
  let dataBytes = cast[seq[byte]](data)
  var pos = 0
  discard parseH2Frame(dataBytes, pos)

fuzzCategory("Frame roundtrip: serialize -> parse -> verify", Iterations):
  let frameTypes = [ftData, ftHeaders, ftPriority, ftRstStream, ftSettings,
                    ftPushPromise, ftPing, ftGoaway, ftWindowUpdate, ftContinuation]
  let ft = frameTypes[rng.rand(frameTypes.high)]
  let flags = uint8(rng.rand(255))
  let streamId = uint32(rng.rand(int(high(int32))))
  let payloadLen = rng.rand(256)
  let payload = randomBytes(payloadLen)

  let frame = H2Frame(
    length: uint32(payloadLen),
    frameType: ft,
    flags: flags,
    streamId: streamId,
    payload: payload,
  )
  var buf = ""
  serializeH2Frame(frame, buf)
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let parsed = parseH2Frame(bufBytes, pos)
  if parsed.isNone:
    fail("roundtrip_" & $i, "failed to parse serialized frame")
  else:
    let p = parsed.get()
    if p.payload != payload:
      fail("roundtrip_" & $i, "payload mismatch")
    if p.streamId != (streamId and 0x7FFFFFFF'u32):
      fail("roundtrip_" & $i, "streamId mismatch")

fuzzCategory("Oversized frame lengths (> 16MB)", Iterations):
  var buf = ""
  let hugeLen = uint32(rng.rand(16777215) + 100)
  writeU24BE(buf, hugeLen)
  buf.add char(0x00)
  buf.add char(0x00)
  writeU32BE(buf, 1)
  buf.add randomBytes(rng.rand(100))
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  discard parseH2Frame(bufBytes, pos)

fuzzCategory("Invalid frame types (0xFF etc)", Iterations):
  var buf = ""
  let payloadLen = rng.rand(50)
  let payload = randomBytes(payloadLen)
  writeU24BE(buf, uint32(payloadLen))
  buf.add char(uint8(rng.rand(245) + 10))
  buf.add char(uint8(rng.rand(255)))
  writeU32BE(buf, uint32(rng.rand(100)))
  buf.add payload
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  discard parseH2Frame(bufBytes, pos)

fuzzCategory("Truncated frames", Iterations):
  let payloadData = randomBytes(rng.rand(100) + 10)
  let frame = H2Frame(
    length: uint32(payloadData.len),
    frameType: ftHeaders,
    flags: FlagEndHeaders,
    streamId: 1,
    payload: payloadData,
  )
  var buf = ""
  serializeH2Frame(frame, buf)
  let fullLen = H2FrameHeaderSize + payloadData.len
  let cutPoint = rng.rand(fullLen - 1)
  let truncated = buf[0 ..< cutPoint]
  let truncBytes = cast[seq[byte]](truncated)
  var pos = 0
  let parsed = parseH2Frame(truncBytes, pos)
  if parsed.isSome:
    fail("truncated_" & $i, "parsed frame from " & $cutPoint & "/" & $fullLen & " bytes")

fuzzCategory("Settings with invalid values", Iterations):
  var payload = ""
  let variant = rng.rand(4)
  case variant
  of 0:
    writeU16BE(payload, uint16(ord(siInitialWindowSize)))
    writeU32BE(payload, uint32(high(uint32)))
  of 1:
    writeU16BE(payload, uint16(ord(siMaxFrameSize)))
    writeU32BE(payload, 100)
  of 2:
    writeU16BE(payload, uint16(ord(siMaxFrameSize)))
    writeU32BE(payload, uint32(20_000_000))
  of 3:
    writeU16BE(payload, uint16(ord(siEnablePush)))
    writeU32BE(payload, 5)
  else:
    writeU16BE(payload, uint16(rng.rand(65535)))
    writeU32BE(payload, uint32(rng.rand(int(high(int32)))))
  let settings = parseSettings(payload)
  discard settings

fuzzCategory("GOAWAY with short payloads", Iterations):
  var buf = ""
  let payloadLen = rng.rand(20)
  let payload = randomBytes(payloadLen)
  serializeFrameHeader(buf, uint32(payloadLen), ftGoaway, 0, 0)
  buf.add payload
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let parsed = parseH2Frame(bufBytes, pos)
  if parsed.isSome and payloadLen >= 8:
    discard parsed.get()

fuzzCategory("WINDOW_UPDATE with zero increment", Iterations):
  var buf = ""
  serializeWindowUpdate(uint32(rng.rand(100)), 0, buf)
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let parsed = parseH2Frame(bufBytes, pos)
  if parsed.isSome:
    let inc = parseWindowUpdate(parsed.get().payload)
    if inc != 0:
      fail("zero_window_" & $i, "expected zero increment")

fuzzCategory("RST_STREAM with wrong payload lengths", Iterations):
  var buf = ""
  let wrongLen = rng.rand(20)
  let payload = randomBytes(wrongLen)
  serializeFrameHeader(buf, uint32(wrongLen), ftRstStream, 0, uint32(rng.rand(100) + 1))
  buf.add payload
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  discard parseH2Frame(bufBytes, pos)

fuzzCategory("Multiple frames concatenated in buffer", Iterations):
  var buf = ""
  let numFrames = rng.rand(10) + 2
  for j in 0 ..< numFrames:
    let payload = randomBytes(rng.rand(50))
    let frame = H2Frame(
      length: uint32(payload.len),
      frameType: [ftData, ftHeaders, ftPing, ftSettings][rng.rand(3)],
      flags: uint8(rng.rand(255)),
      streamId: uint32(rng.rand(100)),
      payload: payload,
    )
    serializeH2Frame(frame, buf)
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  var parsed = 0
  while true:
    let frame = parseH2Frame(bufBytes, pos)
    if frame.isNone: break
    parsed += 1
  if parsed != numFrames:
    fail("concat_" & $i, "expected " & $numFrames & " frames, got " & $parsed)

fuzzCategory("Priority with dependency cycles (self-reference)", Iterations):
  let streamId = uint32(rng.rand(100) + 1)
  var payload = ""
  writeU32BE(payload, streamId)
  payload.add char(uint8(rng.rand(255)))
  var buf = ""
  serializeFrameHeader(buf, uint32(payload.len), ftPriority, 0, streamId)
  buf.add payload
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let parsed = parseH2Frame(bufBytes, pos)
  if parsed.isSome:
    let p = parsed.get()
    if p.payload.len >= 4:
      let depStreamRaw = cast[ptr UncheckedArray[byte]](unsafeAddr p.payload[0])
      let depStream = readU32BE(depStreamRaw.toOpenArray(0, 3), 0) and 0x7FFFFFFF'u32
      discard depStream

fuzzCategory("CONTINUATION frame assembly (HEADERS + CONTINUATION)", Iterations):
  var encoder = initHpackEncoder()
  let headers = @[("x-test", "value-" & $i), (":method", "GET"), (":path", "/")]
  var headerBlock = ""
  hpackEncode(encoder, headers, headerBlock)
  var buf = ""
  let splitPoint = if headerBlock.len > 1: rng.rand(headerBlock.len - 1) + 1 else: headerBlock.len
  let part1 = headerBlock[0 ..< splitPoint]
  let part2 = if splitPoint < headerBlock.len: headerBlock[splitPoint ..< headerBlock.len] else: ""
  serializeFrameHeader(buf, uint32(part1.len), ftHeaders, FlagEndStream, 1)
  buf.add part1
  serializeFrameHeader(buf, uint32(part2.len), ftContinuation, FlagEndHeaders, 1)
  buf.add part2
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let frame1 = parseH2Frame(bufBytes, pos)
  let frame2 = parseH2Frame(bufBytes, pos)
  if frame1.isSome and frame2.isSome:
    let f1 = frame1.get()
    let f2 = frame2.get()
    if f1.frameType != ftHeaders:
      fail("continuation_" & $i, "expected HEADERS frame")
    if f2.frameType != ftContinuation:
      fail("continuation_" & $i, "expected CONTINUATION frame")

fuzzCategory("Frame with padding equal to payload length", Iterations):
  let payloadLen = rng.rand(200) + 1
  let padLen = payloadLen - 1
  var payload = newString(payloadLen)
  payload[0] = char(uint8(padLen))
  for j in 1 ..< payloadLen:
    payload[j] = char(rng.rand(255))
  var buf = ""
  serializeFrameHeader(buf, uint32(payloadLen), ftData, FlagPadded, 1)
  buf.add payload
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let parsed = parseH2Frame(bufBytes, pos)
  if parsed.isSome:
    let stripped = stripPadding(parsed.get())
    discard stripped

fuzzCategory("SETTINGS frame with duplicate setting IDs", Iterations):
  var payload = ""
  let settingId = uint16(rng.rand(5) + 1)
  let numDups = rng.rand(5) + 2
  for j in 0 ..< numDups:
    writeU16BE(payload, settingId)
    writeU32BE(payload, uint32(rng.rand(65535)))
  let settings = parseSettings(payload)
  discard settings

fuzzCategory("GOAWAY with non-zero debug data", Iterations):
  var payload = ""
  let lastStreamId = uint32(rng.rand(100))
  let errorCode = uint32(rng.rand(13))
  writeU32BE(payload, lastStreamId)
  writeU32BE(payload, errorCode)
  let debugLen = rng.rand(200) + 1
  payload.add randomBytes(debugLen)
  var buf = ""
  serializeFrameHeader(buf, uint32(payload.len), ftGoaway, 0, 0)
  buf.add payload
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let parsed = parseH2Frame(bufBytes, pos)
  if parsed.isSome:
    let p = parsed.get()
    if p.payload.len < 8:
      fail("goaway_debug_" & $i, "payload too short for GOAWAY")

fuzzCategory("PUSH_PROMISE frames (graceful handling)", Iterations):
  var payload = ""
  writeU32BE(payload, uint32(rng.rand(100) + 2))
  payload.add randomBytes(rng.rand(50))
  var buf = ""
  serializeFrameHeader(buf, uint32(payload.len), ftPushPromise, FlagEndHeaders, uint32(rng.rand(100) + 1))
  buf.add payload
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let parsed = parseH2Frame(bufBytes, pos)
  if parsed.isSome:
    discard parsed.get()

fuzzCategory("DATA frame with END_STREAM on stream 0 (protocol error)", Iterations):
  var buf = ""
  let payload = randomBytes(rng.rand(50))
  serializeData(0, payload, endStream = true, buf)
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let parsed = parseH2Frame(bufBytes, pos)
  if parsed.isSome:
    let f = parsed.get()
    if f.streamId != 0:
      fail("data_stream0_" & $i, "expected stream 0")

fuzzCategory("WINDOW_UPDATE with increment 0 (protocol error)", Iterations):
  var buf = ""
  serializeWindowUpdate(uint32(rng.rand(100)), 0, buf)
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let parsed = parseH2Frame(bufBytes, pos)
  if parsed.isSome:
    discard parseWindowUpdate(parsed.get().payload)

fuzzCategory("Multiple rapid SETTINGS frames (settings flood)", Iterations div 10):
  var buf = ""
  let numSettings = rng.rand(100) + 50
  for j in 0 ..< numSettings:
    var settings = DefaultH2Settings
    settings.initialWindowSize = uint32(rng.rand(65535))
    settings.maxFrameSize = uint32(rng.rand(16777215 - 16384) + 16384)
    serializeSettings(settings, buf)
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  var parsed = 0
  while true:
    let frame = parseH2Frame(bufBytes, pos)
    if frame.isNone: break
    let s = parseSettings(frame.get().payload)
    discard s
    parsed += 1
  if parsed != numSettings:
    fail("settings_flood_" & $i, "expected " & $numSettings & " got " & $parsed)

fuzzCategory("Unknown frame types (> 9) should be skipped", Iterations):
  var buf = ""
  let payload = randomBytes(rng.rand(50))
  writeU24BE(buf, uint32(payload.len))
  buf.add char(uint8(rng.rand(245) + 10))
  buf.add char(0'u8)
  writeU32BE(buf, uint32(rng.rand(100)))
  buf.add payload
  let knownPayload = randomBytes(rng.rand(50))
  let knownFrame = H2Frame(
    length: uint32(knownPayload.len),
    frameType: ftPing,
    flags: 0,
    streamId: 0,
    payload: knownPayload,
  )
  serializeH2Frame(knownFrame, buf)
  let bufBytes = cast[seq[byte]](buf)
  var pos = 0
  let first = parseH2Frame(bufBytes, pos)
  if first.isSome:
    fail("unknown_type_" & $i, "unknown frame type should return none")
  let second = parseH2Frame(bufBytes, pos)
  if second.isNone:
    fail("unknown_type_after_" & $i, "should parse known frame after unknown")

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All H2 protocol fuzz tests passed (", totalIterations, " total iterations)"
  quit(0)
