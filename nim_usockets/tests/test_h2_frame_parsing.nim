import std/options
import ../src/nim_usockets/h2_protocol

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

echo "=== H2 Frame Parsing Tests ==="

echo "--- DATA frame (0x0) ---"
block dataFrameRoundTrip:
  var buf = ""
  serializeData(1, "hello world", endStream = false, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "DATA frame parses")
  check(f.get.frameType == ftData, "DATA frame type correct")
  check(f.get.streamId == 1, "DATA stream id correct")
  check(f.get.payload == "hello world", "DATA payload correct")
  check(not f.get.hasFlag(FlagEndStream), "DATA no END_STREAM flag")
  check(f.get.length == 11, "DATA length correct")

block dataFrameEndStream:
  var buf = ""
  serializeData(3, "bye", endStream = true, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "DATA with END_STREAM parses")
  check(f.get.hasFlag(FlagEndStream), "DATA END_STREAM flag set")
  check(f.get.payload == "bye", "DATA payload with END_STREAM correct")

block dataFrameEmpty:
  var buf = ""
  serializeData(1, "", endStream = true, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "empty DATA frame parses")
  check(f.get.length == 0, "empty DATA length is 0")
  check(f.get.payload == "", "empty DATA payload is empty")
  check(f.get.hasFlag(FlagEndStream), "empty DATA END_STREAM set")

block dataFramePadded:
  var frame = H2Frame(
    length: 0,
    frameType: ftData,
    flags: FlagPadded,
    streamId: 1,
    payload: "\x03abc\x00\x00\x00"
  )
  frame.length = uint32(frame.payload.len)
  let stripped = stripPadding(frame)
  check(stripped == "abc", "DATA padded: stripped payload correct")

block dataFramePaddedInvalidPadLen:
  var frame = H2Frame(
    length: 2,
    frameType: ftData,
    flags: FlagPadded,
    streamId: 1,
    payload: "\xFF\x01"
  )
  var gotError = false
  try:
    discard stripPadding(frame)
  except ValueError:
    gotError = true
  check(gotError, "DATA padded with pad_len > payload raises error")

block dataViewRoundTrip:
  var buf = ""
  let data = "view data test"
  serializeDataView(5, data.toOpenArray(0, data.len - 1), endStream = false, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "DATA view frame parses")
  check(f.get.payload == "view data test", "DATA view payload correct")
  check(f.get.streamId == 5, "DATA view stream id correct")

echo "--- HEADERS frame (0x1) ---"
block headersFrameRoundTrip:
  var buf = ""
  serializeHeaders(1, "headerblock", endStream = false, endHeaders = true, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "HEADERS frame parses")
  check(f.get.frameType == ftHeaders, "HEADERS frame type correct")
  check(f.get.streamId == 1, "HEADERS stream id correct")
  check(f.get.hasFlag(FlagEndHeaders), "HEADERS END_HEADERS set")
  check(not f.get.hasFlag(FlagEndStream), "HEADERS no END_STREAM")
  check(extractHeaderBlock(f.get) == "headerblock", "HEADERS payload extracted")

block headersFrameBothFlags:
  var buf = ""
  serializeHeaders(3, "hdr", endStream = true, endHeaders = true, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "HEADERS with both flags parses")
  check(f.get.hasFlag(FlagEndStream), "HEADERS END_STREAM set")
  check(f.get.hasFlag(FlagEndHeaders), "HEADERS END_HEADERS set")

block headersFrameNoFlags:
  var buf = ""
  serializeHeaders(5, "partial", endStream = false, endHeaders = false, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "HEADERS no flags parses")
  check(not f.get.hasFlag(FlagEndStream), "HEADERS no END_STREAM when not set")
  check(not f.get.hasFlag(FlagEndHeaders), "HEADERS no END_HEADERS when not set")

block headersWithPriority:
  var frame = H2Frame(
    length: 16,
    frameType: ftHeaders,
    flags: FlagPriority,
    streamId: 1,
    payload: "\x00\x00\x00\x00\x10headerblock"
  )
  let block1 = extractHeaderBlock(frame)
  check(block1 == "headerblock", "HEADERS with PRIORITY: header block extracted after 5-byte priority")

block headersWithPriorityTooShort:
  var frame = H2Frame(
    length: 3,
    frameType: ftHeaders,
    flags: FlagPriority,
    streamId: 1,
    payload: "\x00\x00\x00"
  )
  var gotError = false
  try:
    discard extractHeaderBlock(frame)
  except ValueError:
    gotError = true
  check(gotError, "HEADERS PRIORITY too short raises error")

block headersWithPaddingAndPriority:
  var frame = H2Frame(
    length: 0,
    frameType: ftHeaders,
    flags: FlagPadded or FlagPriority,
    streamId: 1,
    payload: "\x02\x00\x00\x00\x00\x10hdr\x00\x00"
  )
  frame.length = uint32(frame.payload.len)
  let block1 = extractHeaderBlock(frame)
  check(block1 == "hdr", "HEADERS padded+priority: header block extracted")

block headersWithPaddingOnly:
  var frame = H2Frame(
    length: 0,
    frameType: ftHeaders,
    flags: FlagPadded,
    streamId: 1,
    payload: "\x03data\x00\x00\x00"
  )
  frame.length = uint32(frame.payload.len)
  let block1 = extractHeaderBlock(frame)
  check(block1 == "data", "HEADERS padded: header block extracted")

block headersInvalidPadding:
  var frame = H2Frame(
    length: 2,
    frameType: ftHeaders,
    flags: FlagPadded,
    streamId: 1,
    payload: "\xFF\x01"
  )
  var gotError = false
  try:
    discard extractHeaderBlock(frame)
  except ValueError:
    gotError = true
  check(gotError, "HEADERS invalid padding raises error")

echo "--- PRIORITY frame (0x2) ---"
block priorityFrameParse:
  let payload = "\x80\x00\x00\x03\x0F"
  let raw = buildRawFrame(5, uint8(ord(ftPriority)), 0, 1, payload)
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "PRIORITY frame parses")
  check(f.get.frameType == ftPriority, "PRIORITY frame type correct")
  check(f.get.length == 5, "PRIORITY length is 5")
  check(f.get.streamId == 1, "PRIORITY stream id correct")
  check(validateFrameLength(f.get), "PRIORITY passes length validation")

block priorityFrameInvalidLength:
  let raw = buildRawFrame(4, uint8(ord(ftPriority)), 0, 1, "\x00\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "PRIORITY with length 4 parses")
  check(not validateFrameLength(f.get), "PRIORITY with length 4 fails validation")

block priorityFrameTooLong:
  let raw = buildRawFrame(6, uint8(ord(ftPriority)), 0, 1, "\x00\x00\x00\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "PRIORITY with length 6 parses")
  check(not validateFrameLength(f.get), "PRIORITY with length 6 fails validation")

echo "--- RST_STREAM frame (0x3) ---"
block rstStreamRoundTrip:
  var buf = ""
  serializeRstStream(1, uint32(ord(ecCancel)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "RST_STREAM frame parses")
  check(f.get.frameType == ftRstStream, "RST_STREAM frame type correct")
  check(f.get.streamId == 1, "RST_STREAM stream id correct")
  check(f.get.length == 4, "RST_STREAM length is 4")
  check(validateFrameLength(f.get), "RST_STREAM passes length validation")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let errorCode = readU32BE(data.toOpenArray(0, 3), 0)
  check(errorCode == uint32(ord(ecCancel)), "RST_STREAM error code is CANCEL")

block rstStreamAllErrorCodes:
  for ec in H2ErrorCode:
    var buf = ""
    serializeRstStream(1, uint32(ord(ec)), buf)
    var pos = 0
    let f = parseH2Frame(cast[seq[byte]](buf), pos)
    check(f.isSome, "RST_STREAM with " & $ec & " parses")
    let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
    let code = readU32BE(data.toOpenArray(0, 3), 0)
    check(code == uint32(ord(ec)), "RST_STREAM error code matches " & $ec)

block rstStreamInvalidLength:
  let raw = buildRawFrame(3, uint8(ord(ftRstStream)), 0, 1, "\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "RST_STREAM with length 3 parses")
  check(not validateFrameLength(f.get), "RST_STREAM with length 3 fails validation")

echo "--- SETTINGS frame (0x4) ---"
block settingsFrameRoundTrip:
  var buf = ""
  let s = defaultH2Settings()
  serializeSettings(s, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "SETTINGS frame parses")
  check(f.get.frameType == ftSettings, "SETTINGS frame type correct")
  check(f.get.streamId == 0, "SETTINGS stream id is 0")
  check(f.get.length == 36, "SETTINGS length is 36 (6 params * 6 bytes)")
  check(not f.get.hasFlag(FlagAck), "SETTINGS no ACK flag")
  check(validateFrameLength(f.get), "SETTINGS passes length validation")

block settingsAckFrame:
  var buf = ""
  serializeSettingsAck(buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "SETTINGS ACK parses")
  check(f.get.frameType == ftSettings, "SETTINGS ACK frame type")
  check(f.get.hasFlag(FlagAck), "SETTINGS ACK flag set")
  check(f.get.length == 0, "SETTINGS ACK length is 0")
  check(f.get.streamId == 0, "SETTINGS ACK stream id is 0")
  check(validateFrameLength(f.get), "SETTINGS ACK passes validation")

block settingsAckWithPayloadInvalid:
  let raw = buildRawFrame(6, uint8(ord(ftSettings)), FlagAck, 0, "\x00\x00\x00\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "SETTINGS ACK with payload parses")
  check(not validateFrameLength(f.get), "SETTINGS ACK with payload fails validation")

block settingsOddPayloadLength:
  let raw = buildRawFrame(7, uint8(ord(ftSettings)), 0, 0, "\x00\x00\x00\x00\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "SETTINGS odd-length parses")
  check(not validateFrameLength(f.get), "SETTINGS odd-length fails validation")

echo "--- PUSH_PROMISE frame (0x5) ---"
block pushPromiseRoundTrip:
  var buf = ""
  serializePushPromise(1, 2, "headerblock", buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "PUSH_PROMISE frame parses")
  check(f.get.frameType == ftPushPromise, "PUSH_PROMISE frame type correct")
  check(f.get.streamId == 1, "PUSH_PROMISE stream id correct")
  check(f.get.hasFlag(FlagEndHeaders), "PUSH_PROMISE END_HEADERS set")
  check(f.get.length == uint32(4 + "headerblock".len), "PUSH_PROMISE length correct")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let promisedId = readU32BE(data.toOpenArray(0, 3), 0) and 0x7FFFFFFF'u32
  check(promisedId == 2, "PUSH_PROMISE promised stream id correct")

block pushPromiseHighBitMasked:
  var buf = ""
  serializePushPromise(1, 0x80000002'u32, "hdr", buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "PUSH_PROMISE high bit masked parses")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let promisedId = readU32BE(data.toOpenArray(0, 3), 0) and 0x7FFFFFFF'u32
  check(promisedId == 2, "PUSH_PROMISE high bit masked to 2")

echo "--- PING frame (0x6) ---"
block pingFrameRoundTrip:
  let pingData: array[8, byte] = [1'u8, 2, 3, 4, 5, 6, 7, 8]
  var buf = ""
  serializePing(pingData, false, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "PING frame parses")
  check(f.get.frameType == ftPing, "PING frame type correct")
  check(f.get.streamId == 0, "PING stream id is 0")
  check(f.get.length == 8, "PING length is 8")
  check(not f.get.hasFlag(FlagAck), "PING no ACK flag")
  check(validateFrameLength(f.get), "PING passes validation")
  for i in 0..7:
    check(byte(f.get.payload[i]) == pingData[i], "PING payload byte " & $i & " correct")

block pingAckRoundTrip:
  let pingData: array[8, byte] = [0xFF'u8, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8]
  var buf = ""
  serializePing(pingData, true, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "PING ACK parses")
  check(f.get.hasFlag(FlagAck), "PING ACK flag set")

block pingInvalidLength:
  let raw = buildRawFrame(7, uint8(ord(ftPing)), 0, 0, "\x00\x00\x00\x00\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "PING with length 7 parses")
  check(not validateFrameLength(f.get), "PING with length 7 fails validation")

block pingTooLong:
  let raw = buildRawFrame(9, uint8(ord(ftPing)), 0, 0, "\x00\x00\x00\x00\x00\x00\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "PING with length 9 parses")
  check(not validateFrameLength(f.get), "PING with length 9 fails validation")

echo "--- GOAWAY frame (0x7) ---"
block goawayRoundTrip:
  var buf = ""
  serializeGoaway(1, uint32(ord(ecNoError)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "GOAWAY frame parses")
  check(f.get.frameType == ftGoaway, "GOAWAY frame type correct")
  check(f.get.streamId == 0, "GOAWAY stream id is 0")
  check(f.get.length == 8, "GOAWAY length is 8")
  check(validateFrameLength(f.get), "GOAWAY passes validation")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let lastId = readU32BE(data.toOpenArray(0, 7), 0) and 0x7FFFFFFF'u32
  let errorCode = readU32BE(data.toOpenArray(0, 7), 4)
  check(lastId == 1, "GOAWAY last stream id correct")
  check(errorCode == uint32(ord(ecNoError)), "GOAWAY error code correct")

block goawayLastStreamIdZero:
  var buf = ""
  serializeGoaway(0, uint32(ord(ecNoError)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "GOAWAY last-stream-id=0 parses")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let lastId = readU32BE(data.toOpenArray(0, 7), 0) and 0x7FFFFFFF'u32
  check(lastId == 0, "GOAWAY last-stream-id is 0")

block goawayLastStreamIdMax:
  var buf = ""
  serializeGoaway(0x7FFFFFFF'u32, uint32(ord(ecProtocolError)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "GOAWAY max last-stream-id parses")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let lastId = readU32BE(data.toOpenArray(0, 7), 0) and 0x7FFFFFFF'u32
  check(lastId == 0x7FFFFFFF'u32, "GOAWAY max last-stream-id correct")

block goawayHighBitMasked:
  var buf = ""
  serializeGoaway(0xFFFFFFFF'u32, uint32(ord(ecNoError)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "GOAWAY high-bit-masked parses")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let lastId = readU32BE(data.toOpenArray(0, 7), 0) and 0x7FFFFFFF'u32
  check(lastId == 0x7FFFFFFF'u32, "GOAWAY high bit masked correctly")

block goawayAllErrorCodes:
  for ec in H2ErrorCode:
    var buf = ""
    serializeGoaway(0, uint32(ord(ec)), buf)
    var pos = 0
    let f = parseH2Frame(cast[seq[byte]](buf), pos)
    check(f.isSome, "GOAWAY with " & $ec & " parses")
    let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
    let code = readU32BE(data.toOpenArray(0, 7), 4)
    check(code == uint32(ord(ec)), "GOAWAY error code matches " & $ec)

block goawayTooShort:
  let raw = buildRawFrame(7, uint8(ord(ftGoaway)), 0, 0, "\x00\x00\x00\x00\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "GOAWAY too short parses")
  check(not validateFrameLength(f.get), "GOAWAY too short fails validation")

echo "--- WINDOW_UPDATE frame (0x8) ---"
block windowUpdateRoundTrip:
  var buf = ""
  serializeWindowUpdate(0, 1000, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "WINDOW_UPDATE frame parses")
  check(f.get.frameType == ftWindowUpdate, "WINDOW_UPDATE frame type correct")
  check(f.get.streamId == 0, "WINDOW_UPDATE stream id is 0")
  check(f.get.length == 4, "WINDOW_UPDATE length is 4")
  check(validateFrameLength(f.get), "WINDOW_UPDATE passes validation")
  let inc = parseWindowUpdate(f.get.payload)
  check(inc == 1000, "WINDOW_UPDATE increment is 1000")

block windowUpdateOnStream:
  var buf = ""
  serializeWindowUpdate(1, 32768, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "WINDOW_UPDATE on stream parses")
  check(f.get.streamId == 1, "WINDOW_UPDATE stream id is 1")
  let inc = parseWindowUpdate(f.get.payload)
  check(inc == 32768, "WINDOW_UPDATE increment is 32768")

block windowUpdateMaxIncrement:
  var buf = ""
  serializeWindowUpdate(0, 0x7FFFFFFF'u32, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "WINDOW_UPDATE max increment parses")
  let inc = parseWindowUpdate(f.get.payload)
  check(inc == 0x7FFFFFFF'u32, "WINDOW_UPDATE max increment correct")

block windowUpdateHighBitMasked:
  var buf = ""
  serializeWindowUpdate(0, 0xFFFFFFFF'u32, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "WINDOW_UPDATE high bit masked parses")
  let inc = parseWindowUpdate(f.get.payload)
  check(inc == 0x7FFFFFFF'u32, "WINDOW_UPDATE high bit masked correctly")

block windowUpdateZeroIncrement:
  var payload = ""
  writeU32BE(payload, 0)
  var gotError = false
  try:
    discard parseWindowUpdate(payload)
  except ValueError:
    gotError = true
  check(gotError, "WINDOW_UPDATE zero increment raises error")

block windowUpdateTooShort:
  var gotError = false
  try:
    discard parseWindowUpdate("\x00\x00\x00")
  except ValueError:
    gotError = true
  check(gotError, "WINDOW_UPDATE too short raises error")

block windowUpdateInvalidFrameLength:
  let raw = buildRawFrame(3, uint8(ord(ftWindowUpdate)), 0, 0, "\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "WINDOW_UPDATE length 3 parses")
  check(not validateFrameLength(f.get), "WINDOW_UPDATE length 3 fails validation")

echo "--- CONTINUATION frame (0x9) ---"
block continuationFrame:
  var buf = ""
  serializeFrameHeader(buf, 10, ftContinuation, FlagEndHeaders, 1)
  buf.add(newString(10))
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "CONTINUATION frame parses")
  check(f.get.frameType == ftContinuation, "CONTINUATION frame type correct")
  check(f.get.streamId == 1, "CONTINUATION stream id correct")
  check(f.get.hasFlag(FlagEndHeaders), "CONTINUATION END_HEADERS set")
  check(validateFrameLength(f.get), "CONTINUATION passes validation")

block continuationNoEndHeaders:
  var buf = ""
  serializeFrameHeader(buf, 5, ftContinuation, 0, 3)
  buf.add(newString(5))
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "CONTINUATION without END_HEADERS parses")
  check(not f.get.hasFlag(FlagEndHeaders), "CONTINUATION no END_HEADERS flag")

echo "--- TRAILERS ---"
block trailersRoundTrip:
  var buf = ""
  serializeTrailers(1, "trailerblock", buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "trailers frame parses")
  check(f.get.frameType == ftHeaders, "trailers is HEADERS type")
  check(f.get.hasFlag(FlagEndStream), "trailers has END_STREAM")
  check(f.get.hasFlag(FlagEndHeaders), "trailers has END_HEADERS")
  check(f.get.payload == "trailerblock", "trailers payload correct")

echo "--- Serialization round-trip fidelity ---"
block serializeParseRoundTrip:
  var orig = H2Frame(
    length: 5,
    frameType: ftData,
    flags: FlagEndStream or FlagPadded,
    streamId: 42,
    payload: "hello",
  )
  var buf = ""
  serializeH2Frame(orig, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "round-trip: frame parses")
  check(f.get.frameType == orig.frameType, "round-trip: frameType matches")
  check(f.get.flags == orig.flags, "round-trip: flags match")
  check(f.get.streamId == orig.streamId, "round-trip: streamId matches")
  check(f.get.payload == orig.payload, "round-trip: payload matches")
  check(f.get.length == uint32(orig.payload.len), "round-trip: length matches payload")

echo "--- Stream ID high-bit masking ---"
block streamIdHighBitMasked:
  let raw = buildRawFrame(0, uint8(ord(ftData)), 0, 0xFFFFFFFF'u32)
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "frame with high-bit stream id parses")
  check(f.get.streamId == 0x7FFFFFFF'u32, "stream id high bit masked: got " & $f.get.streamId)

block streamIdZero:
  let raw = buildRawFrame(0, uint8(ord(ftData)), 0, 0)
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isSome, "frame with stream id 0 parses")
  check(f.get.streamId == 0, "stream id 0 preserved")

echo "--- Incomplete frames ---"
block incompleteHeader:
  let data = cast[seq[byte]]("\x00\x00\x00\x00\x00\x00\x00\x00")
  var pos = 0
  let f = parseH2Frame(data, pos)
  check(f.isNone, "8-byte data returns none (need 9 for header)")
  check(pos == 0, "pos unchanged on incomplete header")

block incompletePayload:
  let raw = buildRawFrame(100, uint8(ord(ftData)), 0, 1, newString(50))
  var pos = 0
  let f = parseH2Frame(raw, pos)
  check(f.isNone, "incomplete payload returns none")
  check(pos == 0, "pos unchanged on incomplete payload")

block emptyData:
  let data: seq[byte] = @[]
  var pos = 0
  let f = parseH2Frame(data, pos)
  check(f.isNone, "empty data returns none")

echo "--- Multiple frames in one buffer ---"
block multipleFrames:
  var buf = ""
  serializeData(1, "first", endStream = false, buf)
  serializeData(1, "second", endStream = false, buf)
  serializeData(1, "third", endStream = true, buf)

  var pos = 0
  let data = cast[seq[byte]](buf)
  let f1 = parseH2Frame(data, pos)
  check(f1.isSome, "multi: first frame parses")
  check(f1.get.payload == "first", "multi: first payload correct")

  let f2 = parseH2Frame(data, pos)
  check(f2.isSome, "multi: second frame parses")
  check(f2.get.payload == "second", "multi: second payload correct")

  let f3 = parseH2Frame(data, pos)
  check(f3.isSome, "multi: third frame parses")
  check(f3.get.payload == "third", "multi: third payload correct")
  check(f3.get.hasFlag(FlagEndStream), "multi: third has END_STREAM")

  let f4 = parseH2Frame(data, pos)
  check(f4.isNone, "multi: no more frames")

echo "--- U24/U32/U16 byte order helpers ---"
block writeReadU24:
  var buf = ""
  writeU24BE(buf, 0x123456'u32)
  let data = cast[seq[byte]](buf)
  check(readU24BE(data, 0) == 0x123456'u32, "U24 round-trip correct")

block writeReadU24Zero:
  var buf = ""
  writeU24BE(buf, 0)
  let data = cast[seq[byte]](buf)
  check(readU24BE(data, 0) == 0, "U24 zero round-trip")

block writeReadU24Max:
  var buf = ""
  writeU24BE(buf, 0xFFFFFF'u32)
  let data = cast[seq[byte]](buf)
  check(readU24BE(data, 0) == 0xFFFFFF'u32, "U24 max round-trip")

block writeReadU32:
  var buf = ""
  writeU32BE(buf, 0xDEADBEEF'u32)
  let data = cast[seq[byte]](buf)
  check(readU32BE(data, 0) == 0xDEADBEEF'u32, "U32 round-trip correct")

block writeReadU32Zero:
  var buf = ""
  writeU32BE(buf, 0)
  let data = cast[seq[byte]](buf)
  check(readU32BE(data, 0) == 0, "U32 zero round-trip")

block writeReadU32Max:
  var buf = ""
  writeU32BE(buf, 0xFFFFFFFF'u32)
  let data = cast[seq[byte]](buf)
  check(readU32BE(data, 0) == 0xFFFFFFFF'u32, "U32 max round-trip")

block writeReadU16:
  var buf = ""
  writeU16BE(buf, 0xABCD'u16)
  let data = cast[seq[byte]](buf)
  check(readU16BE(data, 0) == 0xABCD'u16, "U16 round-trip correct")

block writeReadU16Zero:
  var buf = ""
  writeU16BE(buf, 0)
  let data = cast[seq[byte]](buf)
  check(readU16BE(data, 0) == 0, "U16 zero round-trip")

block writeReadU16Max:
  var buf = ""
  writeU16BE(buf, 0xFFFF'u16)
  let data = cast[seq[byte]](buf)
  check(readU16BE(data, 0) == 0xFFFF'u16, "U16 max round-trip")

echo "--- Constants ---"
block constantValues:
  check(H2FrameHeaderSize == 9, "H2FrameHeaderSize is 9")
  check(H2ConnectionPreface == "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", "H2ConnectionPreface correct")
  check(DefaultWindowSize == 65535, "DefaultWindowSize is 65535")
  check(FlagEndStream == 0x1, "FlagEndStream is 0x1")
  check(FlagAck == 0x1, "FlagAck is 0x1")
  check(FlagEndHeaders == 0x4, "FlagEndHeaders is 0x4")
  check(FlagPadded == 0x8, "FlagPadded is 0x8")
  check(FlagPriority == 0x20, "FlagPriority is 0x20")

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
