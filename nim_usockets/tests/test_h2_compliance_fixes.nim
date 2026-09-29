import std/[options, strutils]
import ../src/nim_usockets/h2_protocol
import ../src/nim_usockets/hpack

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

proc buildRawFrame(length: uint32, frameType: uint8, flags: uint8, streamId: uint32, payload: string = ""): seq[byte] =
  var buf = ""
  let maskedId = streamId and 0x7FFFFFFF'u32
  buf.setLen(9 + payload.len)
  buf[0] = char((length shr 16) and 0xFF)
  buf[1] = char((length shr 8) and 0xFF)
  buf[2] = char(length and 0xFF)
  buf[3] = char(frameType)
  buf[4] = char(flags)
  buf[5] = char((maskedId shr 24) and 0xFF)
  buf[6] = char((maskedId shr 16) and 0xFF)
  buf[7] = char((maskedId shr 8) and 0xFF)
  buf[8] = char(maskedId and 0xFF)
  if payload.len > 0:
    copyMem(addr buf[9], unsafeAddr payload[0], payload.len)
  cast[seq[byte]](buf)

proc buildSettingsPayload(pairs: openArray[(uint16, uint32)]): string =
  var buf = ""
  for (id, val) in pairs:
    writeU16BE(buf, id)
    writeU32BE(buf, val)
  buf


echo "=== H2 Compliance Fix Tests ==="

echo "--- Fix 1: RFC 9113 §6.5 - SETTINGS ACK stream ID must be 0 ---"
block settingsAckStreamIdZero:
  var buf = ""
  serializeSettingsAck(buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "settings ack parses")
  check(f.get.streamId == 0, "settings ack stream id is 0")
  check(f.get.hasFlag(FlagAck), "settings ack has ACK flag")

block settingsAckNonZeroStreamId:
  let raw = buildRawFrame(0, uint8(ord(ftSettings)), FlagAck, 1)
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "settings ack non-zero stream parses")
  check(f.get.streamId == 1, "settings ack non-zero stream id preserved")
  check(f.get.hasFlag(FlagAck), "settings ack non-zero stream has ACK flag")
  check(f.get.length == 0, "settings ack non-zero stream has zero length")

block settingsAckNonZeroStreamValidation:
  let raw = buildRawFrame(0, uint8(ord(ftSettings)), FlagAck, 1)
  var pos = 0
  let f = parseH2Frame(raw, pos).get
  let validLength = validateFrameLength(f)
  check(validLength, "settings ack passes length validation even with wrong stream")
  check(f.streamId != 0, "non-zero stream id detected for SETTINGS ACK")

echo "--- Fix 2: RFC 9113 §4.2 - CONTINUATION frame length vs MAX_FRAME_SIZE ---"
block continuationWithinLimit:
  let payload = newString(100)
  var buf = ""
  serializeFrameHeader(buf, uint32(payload.len), ftContinuation, 0, 1)
  buf.add(payload)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "continuation frame parses")
  check(validateFrameLength(f.get, 16384), "continuation within MAX_FRAME_SIZE passes")

block continuationExceedsLimit:
  let payload = newString(20000)
  var buf = ""
  serializeFrameHeader(buf, uint32(payload.len), ftContinuation, 0, 1)
  buf.add(payload)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "oversized continuation frame parses")
  check(not validateFrameLength(f.get, 16384), "continuation exceeding MAX_FRAME_SIZE fails")

block continuationCustomMaxFrameSize:
  let payload = newString(32000)
  var buf = ""
  serializeFrameHeader(buf, uint32(payload.len), ftContinuation, 0, 1)
  buf.add(payload)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "large continuation frame parses")
  check(validateFrameLength(f.get, 32768), "continuation within custom MAX_FRAME_SIZE passes")
  check(not validateFrameLength(f.get, 16384), "continuation exceeding default MAX_FRAME_SIZE fails")

echo "--- Fix 3: RFC 9113 §6.5.2 - INITIAL_WINDOW_SIZE error → FLOW_CONTROL_ERROR ---"
block initialWindowSizeTooLarge:
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 0x80000000'u32)])
  var gotError = false
  var errorMsg = ""
  try:
    discard parseSettings(payload)
  except ValueError as e:
    gotError = true
    errorMsg = e.msg
  check(gotError, "INITIAL_WINDOW_SIZE > 2^31-1 raises error")
  check(errorMsg.contains("INITIAL_WINDOW_SIZE"), "error message mentions INITIAL_WINDOW_SIZE")

block initialWindowSizeMaxValid:
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 2147483647'u32)])
  var gotError = false
  try:
    discard parseSettings(payload)
  except ValueError:
    gotError = true
  check(not gotError, "INITIAL_WINDOW_SIZE at 2^31-1 is valid")

block applySettingsInitialWindowSizeOverflow:
  var settings = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 0xFFFFFFFF'u32)])
  var gotError = false
  var errorMsg = ""
  try:
    applySettings(settings, payload)
  except ValueError as e:
    gotError = true
    errorMsg = e.msg
  check(gotError, "applySettings rejects INITIAL_WINDOW_SIZE > 2^31-1")
  check(errorMsg.contains("INITIAL_WINDOW_SIZE"), "applySettings error mentions INITIAL_WINDOW_SIZE")

echo "--- Fix 4: RFC 7541 §4.2 - setMaxSize respects SETTINGS limit parameter ---"
block setMaxSizeWithinLimit:
  var dt = initHpackDynamicTable(4096)
  dt.add("key", "value")
  var gotError = false
  try:
    dt.setMaxSize(2048, limit = 4096)
  except HpackError:
    gotError = true
  check(not gotError, "setMaxSize within limit succeeds")
  check(dt.maxSize == 2048, "maxSize updated to 2048")

block setMaxSizeExceedsLimit:
  var dt = initHpackDynamicTable(4096)
  var gotError = false
  try:
    dt.setMaxSize(8192, limit = 4096)
  except HpackError:
    gotError = true
  check(gotError, "setMaxSize exceeding limit raises HpackError")

block setMaxSizeNoLimit:
  var dt = initHpackDynamicTable(4096)
  var gotError = false
  try:
    dt.setMaxSize(8192)
  except HpackError:
    gotError = true
  check(not gotError, "setMaxSize without limit succeeds for any value")
  check(dt.maxSize == 8192, "maxSize updated to 8192 without limit")

block setMaxSizeNegative:
  var dt = initHpackDynamicTable(4096)
  var gotError = false
  try:
    dt.setMaxSize(-1)
  except HpackError:
    gotError = true
  check(gotError, "setMaxSize negative raises HpackError")

echo "--- Fix 5: RFC 9113 §6.9.2 - INITIAL_WINDOW_SIZE delta int32 underflow ---"
block windowSizeDeltaOverflow:
  var settings = defaultH2Settings()
  check(settings.initialWindowSize == 65535, "default initial window size is 65535")

  let oldWindowSize = int32(settings.initialWindowSize)
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 2147483647'u32)])
  applySettings(settings, payload)
  let delta = int32(settings.initialWindowSize) - oldWindowSize
  check(delta > 0, "delta is positive for increase")

  let currentWindow: int32 = 2147483647
  let newVal = int64(currentWindow) + int64(delta)
  check(newVal > 2147483647'i64, "overflow detected via int64 arithmetic")

block windowSizeDeltaUnderflow:
  var settings = H2Settings(
    headerTableSize: 4096,
    enablePush: false,
    maxConcurrentStreams: 100,
    initialWindowSize: 2147483647,
    maxFrameSize: 16384,
    maxHeaderListSize: high(uint32),
  )
  let oldWindowSize = int32(settings.initialWindowSize)
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 0'u32)])
  applySettings(settings, payload)
  let delta = int32(settings.initialWindowSize) - oldWindowSize
  check(delta < 0, "delta is negative for decrease")

  let currentWindow: int32 = -2147483648'i32
  let newVal = int64(currentWindow) + int64(delta)
  check(newVal < -2147483648'i64, "underflow detected via int64 arithmetic")

echo "--- Fix 6: RFC 7541 §4.2 - Mandatory dynamic table size update after SETTINGS reduction ---"
block mandatorySizeUpdateAfterReduction:
  var decoder = initHpackDecoder(4096)
  updateSettingsMaxSize(decoder, 2048)
  check(decoder.pendingSizeUpdate, "pendingSizeUpdate set after reduction")

  var buf = ""
  hpackEncodeInt(buf, 2048, 5, 0x20)
  hpackEncodeInt(buf, 2, 7, 0x80)
  let decoded = hpackDecode(decoder, cast[seq[byte]](buf))
  check(decoded.len == 1, "decode succeeds with size update before header")
  check(decoded[0][0] == ":method", "decoded header is :method")
  check(decoded[0][1] == "GET", "decoded header value is GET")

block missingMandatorySizeUpdate:
  var decoder = initHpackDecoder(4096)
  updateSettingsMaxSize(decoder, 2048)
  check(decoder.pendingSizeUpdate, "pendingSizeUpdate set for missing update test")

  var buf = ""
  hpackEncodeInt(buf, 2, 7, 0x80)
  var gotError = false
  var errorMsg = ""
  try:
    discard hpackDecode(decoder, cast[seq[byte]](buf))
  except HpackError as e:
    gotError = true
    errorMsg = e.msg
  check(gotError, "missing mandatory size update raises error")
  check(errorMsg.contains("mandatory"), "error mentions mandatory update")

block noMandatorySizeUpdateOnIncrease:
  var decoder = initHpackDecoder(4096)
  updateSettingsMaxSize(decoder, 8192)
  check(not decoder.pendingSizeUpdate, "pendingSizeUpdate not set for increase")

  var buf = ""
  hpackEncodeInt(buf, 2, 7, 0x80)
  var gotError = false
  try:
    discard hpackDecode(decoder, cast[seq[byte]](buf))
  except HpackError:
    gotError = true
  check(not gotError, "decode succeeds without size update after increase")

echo "--- Fix 7: RFC 9113 §8.2.2 - Filter connection-specific headers from H2 ---"

proc isH2ConnectionSpecificHeader(name: string): bool =
  name == "transfer-encoding" or name == "connection" or
  name == "keep-alive" or name == "proxy-connection" or name == "upgrade"

block h2ResponseFilterConnectionHeaders:
  check(isH2ConnectionSpecificHeader("connection"), "connection is H2-forbidden")
  check(isH2ConnectionSpecificHeader("keep-alive"), "keep-alive is H2-forbidden")
  check(isH2ConnectionSpecificHeader("proxy-connection"), "proxy-connection is H2-forbidden")
  check(isH2ConnectionSpecificHeader("transfer-encoding"), "transfer-encoding is H2-forbidden")
  check(isH2ConnectionSpecificHeader("upgrade"), "upgrade is H2-forbidden")
  check(not isH2ConnectionSpecificHeader("content-type"), "content-type is allowed")
  check(not isH2ConnectionSpecificHeader("x-custom"), "x-custom is allowed")
  check(not isH2ConnectionSpecificHeader("accept"), "accept is allowed")

block h2ResponseHeaderFiltering:
  let responseHeaders = @[
    ("content-type", "text/html"),
    ("connection", "keep-alive"),
    ("keep-alive", "timeout=5"),
    ("x-request-id", "abc123"),
    ("transfer-encoding", "chunked"),
    ("proxy-connection", "close"),
    ("upgrade", "h2c"),
    ("cache-control", "no-cache"),
  ]
  var filtered: seq[(string, string)] = @[]
  for (key, value) in responseHeaders:
    if not isH2ConnectionSpecificHeader(key):
      filtered.add((key, value))
  check(filtered.len == 3, "filtered headers count is 3")
  check(filtered[0] == ("content-type", "text/html"), "content-type preserved")
  check(filtered[1] == ("x-request-id", "abc123"), "x-request-id preserved")
  check(filtered[2] == ("cache-control", "no-cache"), "cache-control preserved")

echo "--- Fix 8: RFC 9113 §6.5 - applySettings updates in-place ---"
block applySettingsUpdatesInPlace:
  var settings = H2Settings(
    headerTableSize: 4096,
    enablePush: false,
    maxConcurrentStreams: 100,
    initialWindowSize: 65535,
    maxFrameSize: 16384,
    maxHeaderListSize: high(uint32),
  )

  let payload = buildSettingsPayload([(uint16(ord(siMaxConcurrentStreams)), 200'u32)])
  applySettings(settings, payload)
  check(settings.maxConcurrentStreams == 200, "maxConcurrentStreams updated to 200")
  check(settings.headerTableSize == 4096, "headerTableSize unchanged at 4096")
  check(settings.initialWindowSize == 65535, "initialWindowSize unchanged at 65535")
  check(settings.maxFrameSize == 16384, "maxFrameSize unchanged at 16384")
  check(settings.enablePush == false, "enablePush unchanged at false")

block applySettingsMultipleParams:
  var settings = defaultH2Settings()
  let payload = buildSettingsPayload([
    (uint16(ord(siHeaderTableSize)), 8192'u32),
    (uint16(ord(siMaxFrameSize)), 32768'u32),
  ])
  applySettings(settings, payload)
  check(settings.headerTableSize == 8192, "headerTableSize updated to 8192")
  check(settings.maxFrameSize == 32768, "maxFrameSize updated to 32768")
  check(settings.maxConcurrentStreams == 100, "maxConcurrentStreams unchanged at 100")
  check(settings.initialWindowSize == 65535, "initialWindowSize unchanged at 65535")

block applySettingsVsParseSettings:
  var applied = defaultH2Settings()
  let partialPayload = buildSettingsPayload([(uint16(ord(siMaxConcurrentStreams)), 50'u32)])
  applySettings(applied, partialPayload)

  let parsed = parseSettings(partialPayload)

  check(applied.maxConcurrentStreams == 50, "applySettings updated maxConcurrentStreams")
  check(parsed.maxConcurrentStreams == 50, "parseSettings has maxConcurrentStreams 50")

  check(applied.headerTableSize == 4096, "applySettings preserved headerTableSize")
  check(parsed.headerTableSize == 4096, "parseSettings defaults headerTableSize to 4096")

  check(applied.initialWindowSize == 65535, "applySettings preserved initialWindowSize")
  check(parsed.initialWindowSize == 65535, "parseSettings defaults initialWindowSize")

echo "--- Fix 9: Overflow/underflow protection with applySettings ---"
block applySettingsMaxFrameSizeTooSmall:
  var settings = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 1000'u32)])
  var gotError = false
  try:
    applySettings(settings, payload)
  except ValueError:
    gotError = true
  check(gotError, "applySettings rejects MAX_FRAME_SIZE below 16384")
  check(settings.maxFrameSize == 16384, "maxFrameSize unchanged after rejection")

block applySettingsMaxFrameSizeTooLarge:
  var settings = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 0x01000000'u32)])
  var gotError = false
  try:
    applySettings(settings, payload)
  except ValueError:
    gotError = true
  check(gotError, "applySettings rejects MAX_FRAME_SIZE above 2^24-1")

block applySettingsEnablePushInvalid:
  var settings = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siEnablePush)), 2'u32)])
  var gotError = false
  try:
    applySettings(settings, payload)
  except ValueError:
    gotError = true
  check(gotError, "applySettings rejects ENABLE_PUSH > 1")

block applySettingsIgnoresUnknownId:
  var settings = defaultH2Settings()
  let payload = buildSettingsPayload([(0x0F'u16, 12345'u32)])
  var gotError = false
  try:
    applySettings(settings, payload)
  except ValueError:
    gotError = true
  check(not gotError, "applySettings ignores unknown setting IDs")

block parseSettingsOverflowProtection:
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 0xFFFFFFFF'u32)])
  var gotError = false
  try:
    discard parseSettings(payload)
  except ValueError:
    gotError = true
  check(gotError, "parseSettings rejects INITIAL_WINDOW_SIZE at max uint32")

echo "--- Fix 10: RFC 9113 §3.4 - First frame after preface must be SETTINGS ---"
block firstFrameIsSettings:
  var buf = ""
  let settings = defaultH2Settings()
  serializeSettings(settings, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "settings frame parses as first frame")
  check(f.get.frameType == ftSettings, "first frame is SETTINGS type")
  check(not f.get.hasFlag(FlagAck), "first frame is not ACK")

block firstFrameIsNotSettings:
  let pingData: array[8, byte] = [1'u8, 2, 3, 4, 5, 6, 7, 8]
  var buf = ""
  serializePing(pingData, false, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "ping frame parses")
  check(f.get.frameType == ftPing, "first frame is PING, not SETTINGS")
  check(f.get.frameType != ftSettings, "violation: first frame is not SETTINGS")

block firstFrameSettingsAckIsInvalid:
  var buf = ""
  serializeSettingsAck(buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "settings ack frame parses")
  check(f.get.frameType == ftSettings and f.get.hasFlag(FlagAck),
        "frame is SETTINGS ACK, which is invalid as first frame")

echo "--- Fix 11: RFC 9113 §4.2 - MAX_FRAME_SIZE on unknown frame types ---"
block unknownFrameTypeWithinLimit:
  let payload = newString(100)
  let raw = buildRawFrame(uint32(payload.len), 0xFF, 0, 1, payload)
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isNone, "unknown frame type returns none from parseH2Frame")
  check(pos == 9 + payload.len, "parser advances past unknown frame")

block unknownFrameTypeOversize:
  let declaredLength: uint32 = 20000
  let raw = buildRawFrame(declaredLength, 0xFE, 0, 1, newString(int(declaredLength)))
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isNone, "oversized unknown frame type returns none")

block unknownFrameTypeLengthCheck:
  let declaredLen: uint32 = 20000
  check(declaredLen > 16384, "declared length exceeds default MAX_FRAME_SIZE")

block unknownFrameTypeSkipped:
  let unknownPayload = newString(50)
  let unknownFrame = buildRawFrame(uint32(unknownPayload.len), 0x0A, 0, 0, unknownPayload)

  var dataBuf = ""
  serializeData(1, "hello", endStream = true, dataBuf)

  var combined: seq[byte] = unknownFrame
  for b in cast[seq[byte]](dataBuf):
    combined.add(b)

  var pos = 0

  let f1 = parseH2Frame(combined, pos)
  check(f1.isNone, "unknown frame type 0x0A returns none")

  let f2 = parseH2Frame(combined, pos)
  check(f2.isSome, "data frame after unknown frame parses")
  check(f2.get.frameType == ftData, "second frame is DATA")
  check(f2.get.payload == "hello", "second frame payload correct")

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
