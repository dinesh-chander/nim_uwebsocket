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

echo "=== H2 Settings Validation Tests ==="

echo "--- parseSettings: HEADER_TABLE_SIZE ---"
block headerTableSizeZero:
  let payload = buildSettingsPayload([(uint16(ord(siHeaderTableSize)), 0'u32)])
  let s = parseSettings(payload)
  check(s.headerTableSize == 0, "HEADER_TABLE_SIZE 0 accepted")

block headerTableSizeMax:
  let payload = buildSettingsPayload([(uint16(ord(siHeaderTableSize)), high(uint32))])
  let s = parseSettings(payload)
  check(s.headerTableSize == high(uint32), "HEADER_TABLE_SIZE max accepted")

block headerTableSizeTypical:
  let payload = buildSettingsPayload([(uint16(ord(siHeaderTableSize)), 8192'u32)])
  let s = parseSettings(payload)
  check(s.headerTableSize == 8192, "HEADER_TABLE_SIZE 8192 accepted")

echo "--- parseSettings: ENABLE_PUSH ---"
block enablePushZero:
  let payload = buildSettingsPayload([(uint16(ord(siEnablePush)), 0'u32)])
  let s = parseSettings(payload)
  check(s.enablePush == false, "ENABLE_PUSH 0 -> false")

block enablePushOne:
  let payload = buildSettingsPayload([(uint16(ord(siEnablePush)), 1'u32)])
  let s = parseSettings(payload)
  check(s.enablePush == true, "ENABLE_PUSH 1 -> true")

block enablePushTwo:
  let payload = buildSettingsPayload([(uint16(ord(siEnablePush)), 2'u32)])
  var gotError = false
  try:
    discard parseSettings(payload)
  except ValueError:
    gotError = true
  check(gotError, "ENABLE_PUSH 2 raises ValueError")

block enablePushMax:
  let payload = buildSettingsPayload([(uint16(ord(siEnablePush)), high(uint32))])
  var gotError = false
  try:
    discard parseSettings(payload)
  except ValueError:
    gotError = true
  check(gotError, "ENABLE_PUSH max uint32 raises ValueError")

echo "--- parseSettings: MAX_CONCURRENT_STREAMS ---"
block maxConcurrentStreamsZero:
  let payload = buildSettingsPayload([(uint16(ord(siMaxConcurrentStreams)), 0'u32)])
  let s = parseSettings(payload)
  check(s.maxConcurrentStreams == 0, "MAX_CONCURRENT_STREAMS 0 accepted")

block maxConcurrentStreamsMax:
  let payload = buildSettingsPayload([(uint16(ord(siMaxConcurrentStreams)), high(uint32))])
  let s = parseSettings(payload)
  check(s.maxConcurrentStreams == high(uint32), "MAX_CONCURRENT_STREAMS max accepted")

echo "--- parseSettings: INITIAL_WINDOW_SIZE ---"
block initialWindowSizeZero:
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 0'u32)])
  let s = parseSettings(payload)
  check(s.initialWindowSize == 0, "INITIAL_WINDOW_SIZE 0 accepted")

block initialWindowSizeOne:
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 1'u32)])
  let s = parseSettings(payload)
  check(s.initialWindowSize == 1, "INITIAL_WINDOW_SIZE 1 accepted")

block initialWindowSizeMax:
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 2147483647'u32)])
  let s = parseSettings(payload)
  check(s.initialWindowSize == 2147483647'u32, "INITIAL_WINDOW_SIZE 2^31-1 accepted")

block initialWindowSizeOverflow:
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 2147483648'u32)])
  var gotError = false
  try:
    discard parseSettings(payload)
  except ValueError:
    gotError = true
  check(gotError, "INITIAL_WINDOW_SIZE 2^31 raises ValueError")

block initialWindowSizeMaxUint32:
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), high(uint32))])
  var gotError = false
  try:
    discard parseSettings(payload)
  except ValueError:
    gotError = true
  check(gotError, "INITIAL_WINDOW_SIZE max uint32 raises ValueError")

echo "--- parseSettings: MAX_FRAME_SIZE ---"
block maxFrameSizeMin:
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 16384'u32)])
  let s = parseSettings(payload)
  check(s.maxFrameSize == 16384, "MAX_FRAME_SIZE 16384 (minimum) accepted")

block maxFrameSizeMax:
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 16777215'u32)])
  let s = parseSettings(payload)
  check(s.maxFrameSize == 16777215, "MAX_FRAME_SIZE 2^24-1 (maximum) accepted")

block maxFrameSizeBelowMin:
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 16383'u32)])
  var gotError = false
  try:
    discard parseSettings(payload)
  except ValueError:
    gotError = true
  check(gotError, "MAX_FRAME_SIZE 16383 raises ValueError")

block maxFrameSizeAboveMax:
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 16777216'u32)])
  var gotError = false
  try:
    discard parseSettings(payload)
  except ValueError:
    gotError = true
  check(gotError, "MAX_FRAME_SIZE 2^24 raises ValueError")

block maxFrameSizeZero:
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 0'u32)])
  var gotError = false
  try:
    discard parseSettings(payload)
  except ValueError:
    gotError = true
  check(gotError, "MAX_FRAME_SIZE 0 raises ValueError")

block maxFrameSizeJustAboveMin:
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 16385'u32)])
  let s = parseSettings(payload)
  check(s.maxFrameSize == 16385, "MAX_FRAME_SIZE 16385 accepted")

block maxFrameSizeJustBelowMax:
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 16777214'u32)])
  let s = parseSettings(payload)
  check(s.maxFrameSize == 16777214, "MAX_FRAME_SIZE 2^24-2 accepted")

echo "--- parseSettings: MAX_HEADER_LIST_SIZE ---"
block maxHeaderListSizeZero:
  let payload = buildSettingsPayload([(uint16(ord(siMaxHeaderListSize)), 0'u32)])
  let s = parseSettings(payload)
  check(s.maxHeaderListSize == 0, "MAX_HEADER_LIST_SIZE 0 accepted")

block maxHeaderListSizeMax:
  let payload = buildSettingsPayload([(uint16(ord(siMaxHeaderListSize)), high(uint32))])
  let s = parseSettings(payload)
  check(s.maxHeaderListSize == high(uint32), "MAX_HEADER_LIST_SIZE max accepted")

echo "--- parseSettings: unknown setting IDs ---"
block unknownSettingIdIgnored:
  let payload = buildSettingsPayload([(0x0F'u16, 12345'u32)])
  var gotError = false
  try:
    let s = parseSettings(payload)
    check(s.headerTableSize == 4096, "defaults preserved with unknown setting")
  except:
    gotError = true
  check(not gotError, "unknown setting ID ignored without error")

block unknownSettingIdMixed:
  let payload = buildSettingsPayload([
    (0xFF'u16, 99999'u32),
    (uint16(ord(siMaxConcurrentStreams)), 50'u32),
    (0xFE'u16, 88888'u32),
  ])
  let s = parseSettings(payload)
  check(s.maxConcurrentStreams == 50, "known setting applied among unknowns")

echo "--- parseSettings: empty and malformed ---"
block emptyPayload:
  let s = parseSettings("")
  check(s.headerTableSize == 4096, "empty payload returns defaults: headerTableSize")
  check(s.enablePush == false, "empty payload returns defaults: enablePush")
  check(s.maxConcurrentStreams == 100, "empty payload returns defaults: maxConcurrentStreams")
  check(s.initialWindowSize == 65535, "empty payload returns defaults: initialWindowSize")
  check(s.maxFrameSize == 16384, "empty payload returns defaults: maxFrameSize")

block oddLengthPayload:
  let s = parseSettings("\x00\x00\x00\x00\x00")
  check(s.headerTableSize == 4096, "odd-length payload returns defaults")

block payloadNotMultipleOf6:
  let s = parseSettings("\x00\x01\x00\x00\x20\x00\x00")
  check(s.headerTableSize == 4096, "7-byte payload returns defaults")

echo "--- parseSettings: multiple settings ---"
block multipleSettings:
  let payload = buildSettingsPayload([
    (uint16(ord(siHeaderTableSize)), 8192'u32),
    (uint16(ord(siEnablePush)), 1'u32),
    (uint16(ord(siMaxConcurrentStreams)), 256'u32),
    (uint16(ord(siInitialWindowSize)), 131072'u32),
    (uint16(ord(siMaxFrameSize)), 32768'u32),
    (uint16(ord(siMaxHeaderListSize)), 65536'u32),
  ])
  let s = parseSettings(payload)
  check(s.headerTableSize == 8192, "multi: headerTableSize")
  check(s.enablePush == true, "multi: enablePush")
  check(s.maxConcurrentStreams == 256, "multi: maxConcurrentStreams")
  check(s.initialWindowSize == 131072, "multi: initialWindowSize")
  check(s.maxFrameSize == 32768, "multi: maxFrameSize")
  check(s.maxHeaderListSize == 65536, "multi: maxHeaderListSize")

block duplicateSettingsLastWins:
  let payload = buildSettingsPayload([
    (uint16(ord(siMaxConcurrentStreams)), 100'u32),
    (uint16(ord(siMaxConcurrentStreams)), 200'u32),
    (uint16(ord(siMaxConcurrentStreams)), 300'u32),
  ])
  let s = parseSettings(payload)
  check(s.maxConcurrentStreams == 300, "duplicate settings: last value wins")

echo "--- applySettings: in-place partial update ---"
block applySettingsSingle:
  var s = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siMaxConcurrentStreams)), 42'u32)])
  applySettings(s, payload)
  check(s.maxConcurrentStreams == 42, "applySettings: maxConcurrentStreams updated")
  check(s.headerTableSize == 4096, "applySettings: headerTableSize unchanged")
  check(s.initialWindowSize == 65535, "applySettings: initialWindowSize unchanged")
  check(s.maxFrameSize == 16384, "applySettings: maxFrameSize unchanged")
  check(s.enablePush == false, "applySettings: enablePush unchanged")
  check(s.maxHeaderListSize == high(uint32), "applySettings: maxHeaderListSize unchanged")

block applySettingsMultiple:
  var s = defaultH2Settings()
  let payload = buildSettingsPayload([
    (uint16(ord(siHeaderTableSize)), 0'u32),
    (uint16(ord(siMaxFrameSize)), 65535'u32),
  ])
  applySettings(s, payload)
  check(s.headerTableSize == 0, "applySettings multi: headerTableSize set to 0")
  check(s.maxFrameSize == 65535, "applySettings multi: maxFrameSize set to 65535")
  check(s.maxConcurrentStreams == 100, "applySettings multi: maxConcurrentStreams unchanged")

block applySettingsEmpty:
  var s = defaultH2Settings()
  applySettings(s, "")
  check(s.headerTableSize == 4096, "applySettings empty: no change")

block applySettingsOddLength:
  var s = defaultH2Settings()
  applySettings(s, "\x00\x01\x00")
  check(s.headerTableSize == 4096, "applySettings odd-length: no change")

echo "--- applySettings: validation ---"
block applySettingsEnablePushValid:
  var s = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siEnablePush)), 1'u32)])
  applySettings(s, payload)
  check(s.enablePush == true, "applySettings: ENABLE_PUSH 1 accepted")

block applySettingsEnablePushInvalid:
  var s = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siEnablePush)), 2'u32)])
  var gotError = false
  try:
    applySettings(s, payload)
  except ValueError:
    gotError = true
  check(gotError, "applySettings: ENABLE_PUSH 2 raises")

block applySettingsInitialWindowSizeOverflow:
  var s = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siInitialWindowSize)), 0x80000000'u32)])
  var gotError = false
  try:
    applySettings(s, payload)
  except ValueError:
    gotError = true
  check(gotError, "applySettings: INITIAL_WINDOW_SIZE > 2^31-1 raises")

block applySettingsMaxFrameSizeTooSmall:
  var s = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 0'u32)])
  var gotError = false
  try:
    applySettings(s, payload)
  except ValueError:
    gotError = true
  check(gotError, "applySettings: MAX_FRAME_SIZE 0 raises")

block applySettingsMaxFrameSizeTooLarge:
  var s = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 16777216'u32)])
  var gotError = false
  try:
    applySettings(s, payload)
  except ValueError:
    gotError = true
  check(gotError, "applySettings: MAX_FRAME_SIZE 2^24 raises")

block applySettingsMaxFrameSizeBoundary:
  var s = defaultH2Settings()
  let payload = buildSettingsPayload([(uint16(ord(siMaxFrameSize)), 16777215'u32)])
  applySettings(s, payload)
  check(s.maxFrameSize == 16777215, "applySettings: MAX_FRAME_SIZE 2^24-1 accepted")

block applySettingsUnknownIgnored:
  var s = defaultH2Settings()
  let payload = buildSettingsPayload([(0x99'u16, 12345'u32)])
  var gotError = false
  try:
    applySettings(s, payload)
  except ValueError:
    gotError = true
  check(not gotError, "applySettings: unknown ID ignored")

echo "--- applySettings vs parseSettings comparison ---"
block applyVsParseConsistency:
  let payload = buildSettingsPayload([
    (uint16(ord(siHeaderTableSize)), 2048'u32),
    (uint16(ord(siMaxConcurrentStreams)), 75'u32),
    (uint16(ord(siInitialWindowSize)), 131072'u32),
    (uint16(ord(siMaxFrameSize)), 32768'u32),
    (uint16(ord(siMaxHeaderListSize)), 8192'u32),
  ])

  let parsed = parseSettings(payload)
  var applied = defaultH2Settings()
  applySettings(applied, payload)

  check(parsed.headerTableSize == applied.headerTableSize, "parse vs apply: headerTableSize match")
  check(parsed.maxConcurrentStreams == applied.maxConcurrentStreams, "parse vs apply: maxConcurrentStreams match")
  check(parsed.initialWindowSize == applied.initialWindowSize, "parse vs apply: initialWindowSize match")
  check(parsed.maxFrameSize == applied.maxFrameSize, "parse vs apply: maxFrameSize match")
  check(parsed.maxHeaderListSize == applied.maxHeaderListSize, "parse vs apply: maxHeaderListSize match")

echo "--- serializeSettings round-trip ---"
block serializeSettingsRoundTrip:
  let orig = H2Settings(
    headerTableSize: 2048,
    enablePush: true,
    maxConcurrentStreams: 50,
    initialWindowSize: 131072,
    maxFrameSize: 32768,
    maxHeaderListSize: 8192,
  )
  var buf = ""
  serializeSettings(orig, buf)
  var pos = 0
  let f = parseH2Frame(cast[seq[byte]](buf), pos)
  check(f.isSome, "serialized settings frame parses")
  let roundTripped = parseSettings(f.get.payload)
  check(roundTripped.headerTableSize == orig.headerTableSize, "round-trip: headerTableSize")
  check(roundTripped.enablePush == orig.enablePush, "round-trip: enablePush")
  check(roundTripped.maxConcurrentStreams == orig.maxConcurrentStreams, "round-trip: maxConcurrentStreams")
  check(roundTripped.initialWindowSize == orig.initialWindowSize, "round-trip: initialWindowSize")
  check(roundTripped.maxFrameSize == orig.maxFrameSize, "round-trip: maxFrameSize")
  check(roundTripped.maxHeaderListSize == orig.maxHeaderListSize, "round-trip: maxHeaderListSize")

echo "--- defaultH2Settings ---"
block defaultSettingsValues:
  let s = defaultH2Settings()
  check(s.headerTableSize == 4096, "default headerTableSize is 4096")
  check(s.enablePush == false, "default enablePush is false")
  check(s.maxConcurrentStreams == 100, "default maxConcurrentStreams is 100")
  check(s.initialWindowSize == 65535, "default initialWindowSize is 65535")
  check(s.maxFrameSize == 16384, "default maxFrameSize is 16384")
  check(s.maxHeaderListSize == high(uint32), "default maxHeaderListSize is max uint32")

echo "--- validateFrameLength for SETTINGS ---"
block validateSettingsEmpty:
  let f = H2Frame(length: 0, frameType: ftSettings, flags: 0, streamId: 0, payload: "")
  check(validateFrameLength(f), "SETTINGS empty payload valid (mod 6 == 0)")

block validateSettings6:
  let f = H2Frame(length: 6, frameType: ftSettings, flags: 0, streamId: 0, payload: newString(6))
  check(validateFrameLength(f), "SETTINGS 6-byte payload valid")

block validateSettings12:
  let f = H2Frame(length: 12, frameType: ftSettings, flags: 0, streamId: 0, payload: newString(12))
  check(validateFrameLength(f), "SETTINGS 12-byte payload valid")

block validateSettings36:
  let f = H2Frame(length: 36, frameType: ftSettings, flags: 0, streamId: 0, payload: newString(36))
  check(validateFrameLength(f), "SETTINGS 36-byte payload valid")

block validateSettingsOdd:
  let f = H2Frame(length: 7, frameType: ftSettings, flags: 0, streamId: 0, payload: newString(7))
  check(not validateFrameLength(f), "SETTINGS 7-byte payload invalid")

block validateSettingsAckEmpty:
  let f = H2Frame(length: 0, frameType: ftSettings, flags: FlagAck, streamId: 0, payload: "")
  check(validateFrameLength(f), "SETTINGS ACK empty valid")

block validateSettingsAckNonEmpty:
  let f = H2Frame(length: 6, frameType: ftSettings, flags: FlagAck, streamId: 0, payload: newString(6))
  check(not validateFrameLength(f), "SETTINGS ACK with payload invalid")

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
