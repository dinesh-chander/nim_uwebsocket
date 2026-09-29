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

proc buildSettingsPayload(pairs: openArray[(uint16, uint32)]): string =
  var buf = ""
  for (id, val) in pairs:
    writeU16BE(buf, id)
    writeU32BE(buf, val)
  buf

echo "=== H2 Flow Control & Stream Tests ==="

echo "--- WINDOW_UPDATE: boundary values ---"
block windowUpdateIncrement1:
  var buf = ""
  serializeWindowUpdate(0, 1, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "WINDOW_UPDATE increment=1 parses")
  let inc = parseWindowUpdate(f.get.payload)
  check(inc == 1, "WINDOW_UPDATE minimum valid increment is 1")

block windowUpdateIncrementMax:
  var buf = ""
  serializeWindowUpdate(0, 0x7FFFFFFF'u32, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "WINDOW_UPDATE max increment parses")
  let inc = parseWindowUpdate(f.get.payload)
  check(inc == 0x7FFFFFFF'u32, "WINDOW_UPDATE max increment is 2^31-1")

block windowUpdateIncrementZeroError:
  var payload = ""
  writeU32BE(payload, 0'u32)
  var gotError = false
  try:
    discard parseWindowUpdate(payload)
  except ValueError:
    gotError = true
  check(gotError, "WINDOW_UPDATE increment=0 raises error")

block windowUpdateHighBitReserved:
  var payload = ""
  writeU32BE(payload, 0x80000001'u32)
  let inc = parseWindowUpdate(payload)
  check(inc == 1, "WINDOW_UPDATE high bit masked: 0x80000001 -> 1")

block windowUpdateHighBitOnlyIsZero:
  var payload = ""
  writeU32BE(payload, 0x80000000'u32)
  var gotError = false
  try:
    discard parseWindowUpdate(payload)
  except ValueError:
    gotError = true
  check(gotError, "WINDOW_UPDATE 0x80000000 (masked to 0) raises error")

echo "--- WINDOW_UPDATE: connection vs stream ---"
block windowUpdateOnConnection:
  var buf = ""
  serializeWindowUpdate(0, 65535, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "WINDOW_UPDATE on connection parses")
  check(f.get.streamId == 0, "WINDOW_UPDATE connection: stream id is 0")

block windowUpdateOnStream:
  var buf = ""
  serializeWindowUpdate(3, 32768, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "WINDOW_UPDATE on stream 3 parses")
  check(f.get.streamId == 3, "WINDOW_UPDATE stream: stream id is 3")
  let inc = parseWindowUpdate(f.get.payload)
  check(inc == 32768, "WINDOW_UPDATE stream: increment is 32768")

block windowUpdateOnHighStream:
  var buf = ""
  serializeWindowUpdate(0x7FFFFFFF'u32, 1, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "WINDOW_UPDATE on max stream id parses")
  check(f.get.streamId == 0x7FFFFFFF'u32, "WINDOW_UPDATE max stream id correct")

echo "--- Flow control window arithmetic ---"
block defaultWindowSize:
  check(DefaultWindowSize == 65535, "default window size is 65535")

block windowSizeDeltaPositive:
  let oldWin: int32 = DefaultWindowSize
  let newIWS: uint32 = 131072
  let delta = int64(newIWS) - int64(oldWin)
  check(delta == 65537, "delta positive: 131072 - 65535 = 65537")
  let currentWindow: int64 = int64(DefaultWindowSize)
  let adjusted = currentWindow + delta
  check(adjusted == 131072, "adjusted window correct")

block windowSizeDeltaNegative:
  let oldWin: int32 = DefaultWindowSize
  let newIWS: uint32 = 1000
  let delta = int64(newIWS) - int64(oldWin)
  check(delta == -64535, "delta negative: 1000 - 65535 = -64535")

block windowSizeDeltaZero:
  let oldWin: int32 = DefaultWindowSize
  let newIWS: uint32 = uint32(oldWin)
  let delta = int64(newIWS) - int64(oldWin)
  check(delta == 0, "delta zero when no change")

block windowOverflowDetection:
  let currentWindow: int64 = 2147483647
  let increment: int64 = 1
  let newWindow = currentWindow + increment
  check(newWindow > 2147483647'i64, "overflow detected: window + 1 > 2^31-1")

block windowUnderflowDetection:
  let currentWindow: int64 = -2000000000
  let delta: int64 = -200000000
  let newWindow = currentWindow + delta
  check(newWindow < -2147483648'i64, "underflow detected: negative window too large")

block windowMaxToZero:
  let oldWin: int64 = 2147483647
  let delta: int64 = -2147483647
  let newWindow = oldWin + delta
  check(newWindow == 0, "window max to 0 gives delta = -2^31+1")

block windowZeroToMax:
  let oldWin: int64 = 0
  let delta: int64 = 2147483647
  let newWindow = oldWin + delta
  check(newWindow == 2147483647, "window 0 to max")

block windowCanGoNegative:
  let currentWindow: int32 = 100
  let dataLen: int32 = 200
  let newWindow = currentWindow - dataLen
  check(newWindow == -100, "window can go negative after data send")

echo "--- INITIAL_WINDOW_SIZE delta with applySettings ---"
block applySettingsWindowDelta:
  var settings = defaultH2Settings()
  let oldIWS = settings.initialWindowSize
  check(oldIWS == 65535, "initial window size starts at 65535")

  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 131072'u32)])
  applySettings(settings, payload)
  let delta = int64(settings.initialWindowSize) - int64(oldIWS)
  check(delta == 65537, "applySettings delta is 65537")

block applySettingsWindowDeltaNegative:
  var settings = defaultH2Settings()
  let oldIWS = settings.initialWindowSize

  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 1'u32)])
  applySettings(settings, payload)
  let delta = int64(settings.initialWindowSize) - int64(oldIWS)
  check(delta == -65534, "applySettings negative delta is -65534")

block applySettingsWindowDeltaMaxToMin:
  var settings = H2Settings(
    headerTableSize: 4096, enablePush: false, maxConcurrentStreams: 100,
    initialWindowSize: 2147483647'u32, maxFrameSize: 16384,
    maxHeaderListSize: high(uint32),
  )
  let oldIWS = settings.initialWindowSize
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 0'u32)])
  applySettings(settings, payload)
  let delta = int64(settings.initialWindowSize) - int64(oldIWS)
  check(delta == -2147483647, "delta max to 0 is -2147483647")

  let currentWindow: int64 = -2000000000
  let newWindow = currentWindow + delta
  check(newWindow < -2147483648'i64, "underflow detected with int64")

echo "--- GOAWAY: various last-stream-IDs ---"
block goawayLastStreamIdZero:
  var buf = ""
  serializeGoaway(0, uint32(ord(ecNoError)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "GOAWAY last-id=0 parses")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let lastId = readU32BE(data.toOpenArray(0, 7), 0) and 0x7FFFFFFF'u32
  check(lastId == 0, "GOAWAY last-id=0: no streams processed")

block goawayLastStreamIdOdd:
  var buf = ""
  serializeGoaway(5, uint32(ord(ecNoError)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "GOAWAY last-id=5 parses")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let lastId = readU32BE(data.toOpenArray(0, 7), 0) and 0x7FFFFFFF'u32
  check(lastId == 5, "GOAWAY last-id=5 correct")

block goawayLastStreamIdEven:
  var buf = ""
  serializeGoaway(4, uint32(ord(ecNoError)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "GOAWAY last-id=4 parses (even, server-initiated)")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let lastId = readU32BE(data.toOpenArray(0, 7), 0) and 0x7FFFFFFF'u32
  check(lastId == 4, "GOAWAY last-id=4 correct")

block goawayLastStreamIdMax:
  var buf = ""
  serializeGoaway(0x7FFFFFFF'u32, uint32(ord(ecProtocolError)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "GOAWAY max last-id parses")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
  let lastId = readU32BE(data.toOpenArray(0, 7), 0) and 0x7FFFFFFF'u32
  check(lastId == 0x7FFFFFFF'u32, "GOAWAY max last-id correct")

block goawayAllErrors:
  for ec in H2ErrorCode:
    var buf = ""
    serializeGoaway(1, uint32(ord(ec)), buf)
    var pos = 0
    let f = parseH2Frame(cast[seq[byte]](buf), pos)
    check(f.isSome, "GOAWAY with " & $ec & " parses")
    let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
    let code = readU32BE(data.toOpenArray(0, 7), 4)
    check(code == uint32(ord(ec)), "GOAWAY error code " & $ec & " correct")

echo "--- GOAWAY: frame validation ---"
block goawayMinLength:
  let f = H2Frame(length: 8, frameType: ftGoaway, flags: 0, streamId: 0, payload: newString(8))
  check(validateFrameLength(f), "GOAWAY length=8 valid")

block goawayExtraDebugData:
  let f = H2Frame(length: 20, frameType: ftGoaway, flags: 0, streamId: 0, payload: newString(20))
  check(validateFrameLength(f), "GOAWAY length=20 valid (extra debug data)")

block goawayTooShort:
  let f = H2Frame(length: 7, frameType: ftGoaway, flags: 0, streamId: 0, payload: newString(7))
  check(not validateFrameLength(f), "GOAWAY length=7 invalid")

block goawayZeroLength:
  let f = H2Frame(length: 0, frameType: ftGoaway, flags: 0, streamId: 0, payload: "")
  check(not validateFrameLength(f), "GOAWAY length=0 invalid")

echo "--- Stream state enum values ---"
block streamStateValues:
  check(ord(ssIdle) == 0, "ssIdle is 0")
  check(ord(ssReservedLocal) == 1, "ssReservedLocal is 1")
  check(ord(ssReservedRemote) == 2, "ssReservedRemote is 2")
  check(ord(ssOpen) == 3, "ssOpen is 3")
  check(ord(ssHalfClosedLocal) == 4, "ssHalfClosedLocal is 4")
  check(ord(ssHalfClosedRemote) == 5, "ssHalfClosedRemote is 5")
  check(ord(ssClosed) == 6, "ssClosed is 6")

echo "--- Error code enum values ---"
block errorCodeValues:
  check(ord(ecNoError) == 0x0, "ecNoError is 0x0")
  check(ord(ecProtocolError) == 0x1, "ecProtocolError is 0x1")
  check(ord(ecInternalError) == 0x2, "ecInternalError is 0x2")
  check(ord(ecFlowControlError) == 0x3, "ecFlowControlError is 0x3")
  check(ord(ecSettingsTimeout) == 0x4, "ecSettingsTimeout is 0x4")
  check(ord(ecStreamClosed) == 0x5, "ecStreamClosed is 0x5")
  check(ord(ecFrameSizeError) == 0x6, "ecFrameSizeError is 0x6")
  check(ord(ecRefusedStream) == 0x7, "ecRefusedStream is 0x7")
  check(ord(ecCancel) == 0x8, "ecCancel is 0x8")
  check(ord(ecCompressionError) == 0x9, "ecCompressionError is 0x9")
  check(ord(ecConnectError) == 0xa, "ecConnectError is 0xa")
  check(ord(ecEnhanceYourCalm) == 0xb, "ecEnhanceYourCalm is 0xb")
  check(ord(ecInadequateSecurity) == 0xc, "ecInadequateSecurity is 0xc")
  check(ord(ecHttp11Required) == 0xd, "ecHttp11Required is 0xd")

echo "--- RST_STREAM with all error codes ---"
block rstStreamAllErrors:
  for ec in H2ErrorCode:
    var buf = ""
    serializeRstStream(1, uint32(ord(ec)), buf)
    var pos = 0
    let f = parseH2Frame(cast[seq[byte]](buf), pos)
    check(f.isSome, "RST_STREAM " & $ec & " parses")
    check(f.get.frameType == ftRstStream, "RST_STREAM " & $ec & " frame type")
    check(f.get.length == 4, "RST_STREAM " & $ec & " length")
    let data = cast[ptr UncheckedArray[byte]](unsafeAddr f.get.payload[0])
    let code = readU32BE(data.toOpenArray(0, 3), 0)
    check(code == uint32(ord(ec)), "RST_STREAM error code " & $ec & " round-trips")

echo "--- RST_STREAM on various streams ---"
block rstStreamOnStream1:
  var buf = ""
  serializeRstStream(1, uint32(ord(ecCancel)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.get.streamId == 1, "RST_STREAM on stream 1")

block rstStreamOnHighStream:
  var buf = ""
  serializeRstStream(0x7FFFFFFF'u32, uint32(ord(ecNoError)), buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.get.streamId == 0x7FFFFFFF'u32, "RST_STREAM on max stream id")

echo "--- Frame type enum values ---"
block frameTypeValues:
  check(ord(ftData) == 0x0, "ftData is 0x0")
  check(ord(ftHeaders) == 0x1, "ftHeaders is 0x1")
  check(ord(ftPriority) == 0x2, "ftPriority is 0x2")
  check(ord(ftRstStream) == 0x3, "ftRstStream is 0x3")
  check(ord(ftSettings) == 0x4, "ftSettings is 0x4")
  check(ord(ftPushPromise) == 0x5, "ftPushPromise is 0x5")
  check(ord(ftPing) == 0x6, "ftPing is 0x6")
  check(ord(ftGoaway) == 0x7, "ftGoaway is 0x7")
  check(ord(ftWindowUpdate) == 0x8, "ftWindowUpdate is 0x8")
  check(ord(ftContinuation) == 0x9, "ftContinuation is 0x9")

echo "--- Settings ID enum values ---"
block settingsIdValues:
  check(ord(siHeaderTableSize) == 0x1, "siHeaderTableSize is 0x1")
  check(ord(siEnablePush) == 0x2, "siEnablePush is 0x2")
  check(ord(siMaxConcurrentStreams) == 0x3, "siMaxConcurrentStreams is 0x3")
  check(ord(siInitialWindowSize) == 0x4, "siInitialWindowSize is 0x4")
  check(ord(siMaxFrameSize) == 0x5, "siMaxFrameSize is 0x5")
  check(ord(siMaxHeaderListSize) == 0x6, "siMaxHeaderListSize is 0x6")

echo "--- validateFrameLength: all frame types ---"
block validateDataWithinLimit:
  let f = H2Frame(length: 16384, frameType: ftData, flags: 0, streamId: 1, payload: newString(16384))
  check(validateFrameLength(f), "DATA at MAX_FRAME_SIZE valid")

block validateDataExceedsLimit:
  let f = H2Frame(length: 16385, frameType: ftData, flags: 0, streamId: 1, payload: newString(16385))
  check(not validateFrameLength(f), "DATA exceeding MAX_FRAME_SIZE invalid")

block validateDataCustomLimit:
  let f = H2Frame(length: 32768, frameType: ftData, flags: 0, streamId: 1, payload: newString(32768))
  check(validateFrameLength(f, 32768), "DATA at custom MAX_FRAME_SIZE valid")
  check(not validateFrameLength(f, 16384), "DATA exceeds default MAX_FRAME_SIZE")

block validateHeadersWithinLimit:
  let f = H2Frame(length: 16384, frameType: ftHeaders, flags: 0, streamId: 1, payload: newString(16384))
  check(validateFrameLength(f), "HEADERS at MAX_FRAME_SIZE valid")

block validateHeadersExceedsLimit:
  let f = H2Frame(length: 16385, frameType: ftHeaders, flags: 0, streamId: 1, payload: newString(16385))
  check(not validateFrameLength(f), "HEADERS exceeding MAX_FRAME_SIZE invalid")

block validatePushPromiseWithinLimit:
  let f = H2Frame(length: 16384, frameType: ftPushPromise, flags: 0, streamId: 1, payload: newString(16384))
  check(validateFrameLength(f), "PUSH_PROMISE at MAX_FRAME_SIZE valid")

block validatePushPromiseExceedsLimit:
  let f = H2Frame(length: 16385, frameType: ftPushPromise, flags: 0, streamId: 1, payload: newString(16385))
  check(not validateFrameLength(f), "PUSH_PROMISE exceeding MAX_FRAME_SIZE invalid")

block validateContinuationWithinLimit:
  let f = H2Frame(length: 16384, frameType: ftContinuation, flags: 0, streamId: 1, payload: newString(16384))
  check(validateFrameLength(f), "CONTINUATION at MAX_FRAME_SIZE valid")

block validateContinuationExceedsLimit:
  let f = H2Frame(length: 16385, frameType: ftContinuation, flags: 0, streamId: 1, payload: newString(16385))
  check(not validateFrameLength(f), "CONTINUATION exceeding MAX_FRAME_SIZE invalid")

block validatePingExact:
  let f = H2Frame(length: 8, frameType: ftPing, flags: 0, streamId: 0, payload: newString(8))
  check(validateFrameLength(f), "PING length=8 valid")

block validatePingWrong:
  let f = H2Frame(length: 9, frameType: ftPing, flags: 0, streamId: 0, payload: newString(9))
  check(not validateFrameLength(f), "PING length=9 invalid")

block validateRstStreamExact:
  let f = H2Frame(length: 4, frameType: ftRstStream, flags: 0, streamId: 1, payload: newString(4))
  check(validateFrameLength(f), "RST_STREAM length=4 valid")

block validateRstStreamWrong:
  let f = H2Frame(length: 5, frameType: ftRstStream, flags: 0, streamId: 1, payload: newString(5))
  check(not validateFrameLength(f), "RST_STREAM length=5 invalid")

block validatePriorityExact:
  let f = H2Frame(length: 5, frameType: ftPriority, flags: 0, streamId: 1, payload: newString(5))
  check(validateFrameLength(f), "PRIORITY length=5 valid")

block validatePriorityWrong:
  let f = H2Frame(length: 6, frameType: ftPriority, flags: 0, streamId: 1, payload: newString(6))
  check(not validateFrameLength(f), "PRIORITY length=6 invalid")

block validateWindowUpdateExact:
  let f = H2Frame(length: 4, frameType: ftWindowUpdate, flags: 0, streamId: 0, payload: newString(4))
  check(validateFrameLength(f), "WINDOW_UPDATE length=4 valid")

block validateWindowUpdateWrong:
  let f = H2Frame(length: 3, frameType: ftWindowUpdate, flags: 0, streamId: 0, payload: newString(3))
  check(not validateFrameLength(f), "WINDOW_UPDATE length=3 invalid")

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
