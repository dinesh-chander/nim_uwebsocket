import std/[options, strutils]
import ../src/nim_usockets/h2_protocol as h2p
import ../src/nim_usockets/hpack as hpackMod
import ../src/nim_usockets/websocket

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

echo "=== RFC Conformance Tests ==="
echo ""

echo "--- RFC 7540 §4.2: Frame Size Enforcement ---"

proc testFrameSizeValidation() =
  let dataFrame = H2Frame(length: 16384, frameType: ftData, flags: 0, streamId: 1, payload: newString(16384))
  check(validateFrameLength(dataFrame, 16384), "rfc7540-4.2: DATA at MAX_FRAME_SIZE accepted")

  let oversizedData = H2Frame(length: 16385, frameType: ftData, flags: 0, streamId: 1, payload: newString(16385))
  check(not validateFrameLength(oversizedData, 16384), "rfc7540-4.2: DATA exceeding MAX_FRAME_SIZE rejected")

  let headersFrame = H2Frame(length: 16384, frameType: ftHeaders, flags: 0, streamId: 1, payload: newString(16384))
  check(validateFrameLength(headersFrame, 16384), "rfc7540-4.2: HEADERS at MAX_FRAME_SIZE accepted")

  let oversizedHeaders = H2Frame(length: 16385, frameType: ftHeaders, flags: 0, streamId: 1, payload: newString(16385))
  check(not validateFrameLength(oversizedHeaders, 16384), "rfc7540-4.2: HEADERS exceeding MAX_FRAME_SIZE rejected")

  let contFrame = H2Frame(length: 16384, frameType: ftContinuation, flags: 0, streamId: 1, payload: newString(16384))
  check(validateFrameLength(contFrame, 16384), "rfc7540-4.2: CONTINUATION at MAX_FRAME_SIZE accepted")

  let oversizedCont = H2Frame(length: 16385, frameType: ftContinuation, flags: 0, streamId: 1, payload: newString(16385))
  check(not validateFrameLength(oversizedCont, 16384), "rfc7540-4.2: CONTINUATION exceeding MAX_FRAME_SIZE rejected")

  let customMax = H2Frame(length: 32768, frameType: ftData, flags: 0, streamId: 1, payload: newString(32768))
  check(validateFrameLength(customMax, 32768), "rfc7540-4.2: DATA at custom MAX_FRAME_SIZE accepted")
  check(not validateFrameLength(customMax, 16384), "rfc7540-4.2: DATA exceeding default MAX_FRAME_SIZE rejected")
  echo "RFC 7540 §4.2 Frame Size: OK"

testFrameSizeValidation()

echo ""
echo "--- RFC 7540 §6.1: DATA Frame Padding ---"

proc testDataFramePadding() =
  var paddedPayload = newString(1 + 5 + 3)
  paddedPayload[0] = char(3)
  for i in 0..<5: paddedPayload[1 + i] = char(ord('A') + i)
  for i in 0..<3: paddedPayload[1 + 5 + i] = '\0'
  let paddedFrame = H2Frame(length: uint32(paddedPayload.len), frameType: ftData, flags: FlagPadded, streamId: 1, payload: paddedPayload)
  let stripped = stripPadding(paddedFrame)
  check(stripped == "ABCDE", "rfc7540-6.1: DATA padding stripped correctly")

  var invalidPadPayload = newString(1)
  invalidPadPayload[0] = char(200)
  let invalidPadFrame = H2Frame(length: 1, frameType: ftData, flags: FlagPadded, streamId: 1, payload: invalidPadPayload)
  var padRaised = false
  try:
    discard stripPadding(invalidPadFrame)
  except ValueError:
    padRaised = true
  check(padRaised, "rfc7540-6.1: DATA invalid padding raises ValueError")

  let unpaddedFrame = H2Frame(length: 5, frameType: ftData, flags: 0, streamId: 1, payload: "hello")
  check(stripPadding(unpaddedFrame) == "hello", "rfc7540-6.1: DATA without PADDED flag returns raw payload")
  echo "RFC 7540 §6.1 DATA Padding: OK"

testDataFramePadding()

echo ""
echo "--- RFC 7540 §6.5: SETTINGS Frame Validation ---"

proc testSettingsValidation() =
  let settingsFrame = H2Frame(length: 12, frameType: ftSettings, flags: 0, streamId: 0, payload: newString(12))
  check(validateFrameLength(settingsFrame), "rfc7540-6.5: SETTINGS with valid payload length accepted")

  let oddSettings = H2Frame(length: 7, frameType: ftSettings, flags: 0, streamId: 0, payload: newString(7))
  check(not validateFrameLength(oddSettings), "rfc7540-6.5: SETTINGS with non-multiple-of-6 rejected")

  let settingsAck = H2Frame(length: 0, frameType: ftSettings, flags: FlagAck, streamId: 0, payload: "")
  check(validateFrameLength(settingsAck), "rfc7540-6.5: SETTINGS ACK with 0 length accepted")

  let settingsAckBad = H2Frame(length: 6, frameType: ftSettings, flags: FlagAck, streamId: 0, payload: newString(6))
  check(not validateFrameLength(settingsAckBad), "rfc7540-6.5: SETTINGS ACK with non-zero length rejected")

  var enablePush0 = newString(6)
  enablePush0[0] = '\0'; enablePush0[1] = '\x02'
  enablePush0[2] = '\0'; enablePush0[3] = '\0'; enablePush0[4] = '\0'; enablePush0[5] = '\0'
  let settings0 = parseSettings(enablePush0)
  check(settings0.enablePush == false, "rfc7540-6.5: ENABLE_PUSH=0 accepted")

  var enablePush1 = newString(6)
  enablePush1[0] = '\0'; enablePush1[1] = '\x02'
  enablePush1[2] = '\0'; enablePush1[3] = '\0'; enablePush1[4] = '\0'; enablePush1[5] = '\x01'
  let settings1 = parseSettings(enablePush1)
  check(settings1.enablePush == true, "rfc7540-6.5: ENABLE_PUSH=1 accepted")

  var enablePush2 = newString(6)
  enablePush2[0] = '\0'; enablePush2[1] = '\x02'
  enablePush2[2] = '\0'; enablePush2[3] = '\0'; enablePush2[4] = '\0'; enablePush2[5] = '\x02'
  var pushRaised = false
  try:
    discard parseSettings(enablePush2)
  except ValueError:
    pushRaised = true
  check(pushRaised, "rfc7540-6.5: ENABLE_PUSH=2 raises error")

  var unknownSetting = newString(6)
  unknownSetting[0] = '\0'; unknownSetting[1] = '\xFF'
  unknownSetting[2] = '\0'; unknownSetting[3] = '\0'; unknownSetting[4] = '\0'; unknownSetting[5] = '\x01'
  let unknownParsed = parseSettings(unknownSetting)
  check(unknownParsed.headerTableSize == DefaultH2Settings.headerTableSize, "rfc7540-6.5: unknown setting ID ignored")

  var windowTooLarge = newString(6)
  windowTooLarge[0] = '\0'; windowTooLarge[1] = '\x04'
  windowTooLarge[2] = '\x80'; windowTooLarge[3] = '\0'; windowTooLarge[4] = '\0'; windowTooLarge[5] = '\0'
  var windowRaised = false
  try:
    discard parseSettings(windowTooLarge)
  except ValueError:
    windowRaised = true
  check(windowRaised, "rfc7540-6.5: INITIAL_WINDOW_SIZE > 2^31-1 raises error")

  var frameSizeLow = newString(6)
  frameSizeLow[0] = '\0'; frameSizeLow[1] = '\x05'
  frameSizeLow[2] = '\0'; frameSizeLow[3] = '\0'; frameSizeLow[4] = '\x3F'; frameSizeLow[5] = '\xFF'
  var fsRaised = false
  try:
    discard parseSettings(frameSizeLow)
  except ValueError:
    fsRaised = true
  check(fsRaised, "rfc7540-6.5: MAX_FRAME_SIZE below 16384 raises error")
  echo "RFC 7540 §6.5 SETTINGS: OK"

testSettingsValidation()

echo ""
echo "--- RFC 7540 §6.7: PING Frame ---"

proc testPingFrame() =
  let pingValid = H2Frame(length: 8, frameType: ftPing, flags: 0, streamId: 0, payload: "12345678")
  check(validateFrameLength(pingValid), "rfc7540-6.7: PING with 8 bytes accepted")

  let pingShort = H2Frame(length: 7, frameType: ftPing, flags: 0, streamId: 0, payload: "1234567")
  check(not validateFrameLength(pingShort), "rfc7540-6.7: PING with 7 bytes rejected")

  let pingLong = H2Frame(length: 9, frameType: ftPing, flags: 0, streamId: 0, payload: "123456789")
  check(not validateFrameLength(pingLong), "rfc7540-6.7: PING with 9 bytes rejected")

  let pingAck = H2Frame(length: 8, frameType: ftPing, flags: FlagAck, streamId: 0, payload: "12345678")
  check(validateFrameLength(pingAck), "rfc7540-6.7: PING ACK with 8 bytes accepted")

  var buf = ""
  var pingData: array[8, byte]
  for i in 0..7: pingData[i] = byte(i + 1)
  serializePing(pingData, ack = false, buf)
  check(buf.len == H2FrameHeaderSize + 8, "rfc7540-6.7: serialized PING correct size")

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "rfc7540-6.7: serialized PING parseable")
  let f = parsed.get
  check(f.frameType == ftPing, "rfc7540-6.7: parsed PING type correct")
  check(f.streamId == 0, "rfc7540-6.7: PING stream ID is 0")
  check(f.length == 8, "rfc7540-6.7: PING length is 8")
  check(not hasFlag(f, FlagAck), "rfc7540-6.7: PING not ACK")
  echo "RFC 7540 §6.7 PING: OK"

testPingFrame()

echo ""
echo "--- RFC 7540 §6.8: GOAWAY Frame ---"

proc testGoawayFrame() =
  var buf = ""
  serializeGoaway(7, uint32(ecNoError), buf)
  check(buf.len == H2FrameHeaderSize + 8, "rfc7540-6.8: GOAWAY frame correct size")

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "rfc7540-6.8: GOAWAY parseable")
  let f = parsed.get
  check(f.frameType == ftGoaway, "rfc7540-6.8: parsed GOAWAY type")
  check(f.streamId == 0, "rfc7540-6.8: GOAWAY on stream 0")
  check(f.length >= 8, "rfc7540-6.8: GOAWAY min payload 8")

  let goawayValid = H2Frame(length: 8, frameType: ftGoaway, flags: 0, streamId: 0, payload: newString(8))
  check(validateFrameLength(goawayValid), "rfc7540-6.8: GOAWAY with 8 bytes accepted")

  let goawayShort = H2Frame(length: 7, frameType: ftGoaway, flags: 0, streamId: 0, payload: newString(7))
  check(not validateFrameLength(goawayShort), "rfc7540-6.8: GOAWAY with <8 bytes rejected")

  let goawayWithDebug = H2Frame(length: 16, frameType: ftGoaway, flags: 0, streamId: 0, payload: newString(16))
  check(validateFrameLength(goawayWithDebug), "rfc7540-6.8: GOAWAY with debug data accepted")
  echo "RFC 7540 §6.8 GOAWAY: OK"

testGoawayFrame()

echo ""
echo "--- RFC 7540 §6.9: WINDOW_UPDATE ---"

proc testWindowUpdate() =
  let wuValid = H2Frame(length: 4, frameType: ftWindowUpdate, flags: 0, streamId: 0, payload: newString(4))
  check(validateFrameLength(wuValid), "rfc7540-6.9: WINDOW_UPDATE with 4 bytes accepted")

  let wuShort = H2Frame(length: 3, frameType: ftWindowUpdate, flags: 0, streamId: 0, payload: newString(3))
  check(not validateFrameLength(wuShort), "rfc7540-6.9: WINDOW_UPDATE with <4 bytes rejected")

  let wuLong = H2Frame(length: 5, frameType: ftWindowUpdate, flags: 0, streamId: 0, payload: newString(5))
  check(not validateFrameLength(wuLong), "rfc7540-6.9: WINDOW_UPDATE with >4 bytes rejected")

  var zeroPayload = newString(4)
  zeroPayload[0] = '\0'; zeroPayload[1] = '\0'; zeroPayload[2] = '\0'; zeroPayload[3] = '\0'
  var zeroRaised = false
  try:
    discard parseWindowUpdate(zeroPayload)
  except ValueError:
    zeroRaised = true
  check(zeroRaised, "rfc7540-6.9: WINDOW_UPDATE increment=0 raises error")

  var onePayload = newString(4)
  onePayload[0] = '\0'; onePayload[1] = '\0'; onePayload[2] = '\0'; onePayload[3] = '\x01'
  let inc1 = parseWindowUpdate(onePayload)
  check(inc1 == 1, "rfc7540-6.9: WINDOW_UPDATE increment=1 accepted")

  var maxPayload = newString(4)
  maxPayload[0] = '\x7F'; maxPayload[1] = '\xFF'; maxPayload[2] = '\xFF'; maxPayload[3] = '\xFF'
  let incMax = parseWindowUpdate(maxPayload)
  check(incMax == 2147483647'u32, "rfc7540-6.9: WINDOW_UPDATE increment=2^31-1 accepted")

  var reservedBit = newString(4)
  reservedBit[0] = '\x80'; reservedBit[1] = '\0'; reservedBit[2] = '\0'; reservedBit[3] = '\x01'
  let incReserved = parseWindowUpdate(reservedBit)
  check(incReserved == 1, "rfc7540-6.9: WINDOW_UPDATE reserved bit ignored")
  echo "RFC 7540 §6.9 WINDOW_UPDATE: OK"

testWindowUpdate()

echo ""
echo "--- RFC 7540 §6.3/6.4: PRIORITY and RST_STREAM Size ---"

proc testFixedLengthFrames() =
  let priorityGood = H2Frame(length: 5, frameType: ftPriority, flags: 0, streamId: 1, payload: newString(5))
  check(validateFrameLength(priorityGood), "rfc7540-6.3: PRIORITY with 5 bytes accepted")

  let priorityBad = H2Frame(length: 4, frameType: ftPriority, flags: 0, streamId: 1, payload: newString(4))
  check(not validateFrameLength(priorityBad), "rfc7540-6.3: PRIORITY with !=5 bytes rejected")

  let rstGood = H2Frame(length: 4, frameType: ftRstStream, flags: 0, streamId: 1, payload: newString(4))
  check(validateFrameLength(rstGood), "rfc7540-6.4: RST_STREAM with 4 bytes accepted")

  let rstBad = H2Frame(length: 5, frameType: ftRstStream, flags: 0, streamId: 1, payload: newString(5))
  check(not validateFrameLength(rstBad), "rfc7540-6.4: RST_STREAM with !=4 bytes rejected")
  echo "RFC 7540 §6.3/6.4 Fixed-Length Frames: OK"

testFixedLengthFrames()

echo ""
echo "--- RFC 7540: Frame Serialization/Parsing Roundtrip ---"

proc testFrameRoundtrip() =
  var buf = ""
  serializeData(3, "hello", endStream = true, buf)
  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "rfc7540: DATA roundtrip parse")
  let f = parsed.get
  check(f.frameType == ftData, "rfc7540: DATA roundtrip type")
  check(f.streamId == 3, "rfc7540: DATA roundtrip stream ID")
  check(hasFlag(f, FlagEndStream), "rfc7540: DATA roundtrip END_STREAM")
  check(f.payload == "hello", "rfc7540: DATA roundtrip payload")

  buf = ""
  serializeRstStream(5, uint32(ecCancel), buf)
  pos = 0
  let rstParsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(rstParsed.isSome, "rfc7540: RST_STREAM roundtrip parse")
  let rst = rstParsed.get
  check(rst.frameType == ftRstStream, "rfc7540: RST_STREAM roundtrip type")
  check(rst.streamId == 5, "rfc7540: RST_STREAM roundtrip stream ID")
  check(rst.length == 4, "rfc7540: RST_STREAM roundtrip length")

  buf = ""
  serializeWindowUpdate(7, 1000, buf)
  pos = 0
  let wuParsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(wuParsed.isSome, "rfc7540: WINDOW_UPDATE roundtrip parse")
  let wu = wuParsed.get
  check(wu.frameType == ftWindowUpdate, "rfc7540: WINDOW_UPDATE roundtrip type")
  check(wu.streamId == 7, "rfc7540: WINDOW_UPDATE roundtrip stream ID")
  let wuInc = parseWindowUpdate(wu.payload)
  check(wuInc == 1000, "rfc7540: WINDOW_UPDATE roundtrip increment")
  echo "RFC 7540 Frame Roundtrip: OK"

testFrameRoundtrip()

echo ""
echo "--- RFC 7540: Unknown Frame Type ---"

proc testUnknownFrameType() =
  var frameData = newSeq[byte](9 + 4)
  frameData[0] = 0; frameData[1] = 0; frameData[2] = 4
  frameData[3] = 0xFF
  frameData[4] = 0
  frameData[5] = 0; frameData[6] = 0; frameData[7] = 0; frameData[8] = 0
  var pos = 0
  let parsed = parseH2Frame(frameData, pos)
  check(parsed.isNone, "rfc7540: unknown frame type 0xFF returns none")
  check(pos == 13, "rfc7540: unknown frame type skips entire frame")
  echo "RFC 7540 Unknown Frame Type: OK"

testUnknownFrameType()

echo ""
echo "--- RFC 7541 §4.1: HPACK Integer Encoding ---"

proc testHpackIntegerEncoding() =
  var buf = ""
  hpackEncodeInt(buf, 0, 5, 0x00)
  check(buf.len == 1, "rfc7541-4.1: encode 0 prefix 5")
  check(ord(buf[0]) == 0, "rfc7541-4.1: encode 0 value")

  buf = ""
  hpackEncodeInt(buf, 30, 5, 0x00)
  check(buf.len == 1, "rfc7541-4.1: encode 30 prefix 5 single byte")

  buf = ""
  hpackEncodeInt(buf, 31, 5, 0x00)
  check(buf.len == 2, "rfc7541-4.1: encode 31 prefix 5 needs 2 bytes")
  check(ord(buf[0]) == 0x1F, "rfc7541-4.1: encode 31 first byte")

  buf = ""
  hpackEncodeInt(buf, 127, 7, 0x00)
  check(buf.len == 2, "rfc7541-4.1: encode 127 prefix 7 needs 2 bytes")

  buf = ""
  hpackEncodeInt(buf, 128, 7, 0x00)
  check(buf.len == 2, "rfc7541-4.1: encode 128 prefix 7 needs 2 bytes")

  buf = ""
  hpackEncodeInt(buf, 16383, 7, 0x00)
  var pos = 0
  let decoded = hpackDecodeInt(cast[seq[byte]](buf), pos, 7)
  check(decoded == 16383, "rfc7541-4.1: roundtrip 16383 prefix 7")

  buf = ""
  hpackEncodeInt(buf, 16384, 7, 0x00)
  pos = 0
  let decoded2 = hpackDecodeInt(cast[seq[byte]](buf), pos, 7)
  check(decoded2 == 16384, "rfc7541-4.1: roundtrip 16384 prefix 7")

  buf = ""
  hpackEncodeInt(buf, 0, 7, 0x80)
  check((ord(buf[0]) and 0x80) != 0, "rfc7541-4.1: prefix byte preserved")

  let boundaries = [0, 1, 30, 31, 126, 127, 128, 255, 256, 16383, 16384, 65535]
  for val in boundaries:
    for prefix in [4, 5, 6, 7]:
      buf = ""
      hpackEncodeInt(buf, val, prefix, 0x00)
      pos = 0
      let rt = hpackDecodeInt(cast[seq[byte]](buf), pos, prefix)
      check(rt == val, "rfc7541-4.1: roundtrip " & $val & " prefix " & $prefix)
  echo "RFC 7541 §4.1 Integer Encoding: OK"

testHpackIntegerEncoding()

echo ""
echo "--- RFC 7541 §4.1: HPACK Integer Overflow ---"

proc testHpackIntegerOverflow() =
  var overflowData = newSeq[byte](7)
  overflowData[0] = 0x7F
  overflowData[1] = 0xFF
  overflowData[2] = 0xFF
  overflowData[3] = 0xFF
  overflowData[4] = 0xFF
  overflowData[5] = 0xFF
  overflowData[6] = 0x0F
  var pos = 0
  var overflowRaised = false
  try:
    discard hpackDecodeInt(overflowData, pos, 7)
  except HpackError:
    overflowRaised = true
  check(overflowRaised, "rfc7541-4.1: integer overflow detected")

  var truncData = newSeq[byte](2)
  truncData[0] = 0x1F
  truncData[1] = 0x80
  pos = 0
  var truncRaised = false
  try:
    discard hpackDecodeInt(truncData, pos, 5)
  except HpackError:
    truncRaised = true
  check(truncRaised, "rfc7541-4.1: truncated integer detected")

  var emptyData = newSeq[byte](0)
  pos = 0
  var emptyRaised = false
  try:
    discard hpackDecodeInt(emptyData, pos, 5)
  except HpackError:
    emptyRaised = true
  check(emptyRaised, "rfc7541-4.1: empty data raises error")
  echo "RFC 7541 §4.1 Integer Overflow: OK"

testHpackIntegerOverflow()

echo ""
echo "--- RFC 7541 §4.2: HPACK String Encoding ---"

proc testHpackStringEncoding() =
  var buf = ""
  hpackEncodeString(buf, "hello", false)
  var pos = 0
  let raw = hpackDecodeString(cast[seq[byte]](buf), pos)
  check(raw == "hello", "rfc7541-4.2: raw string roundtrip")

  buf = ""
  hpackEncodeString(buf, "hello", true)
  pos = 0
  let huff = hpackDecodeString(cast[seq[byte]](buf), pos)
  check(huff == "hello", "rfc7541-4.2: Huffman string roundtrip")

  buf = ""
  hpackEncodeString(buf, "", false)
  pos = 0
  let empty = hpackDecodeString(cast[seq[byte]](buf), pos)
  check(empty == "", "rfc7541-4.2: empty string roundtrip")

  buf = ""
  hpackEncodeString(buf, "www.example.com", true)
  pos = 0
  let domain = hpackDecodeString(cast[seq[byte]](buf), pos)
  check(domain == "www.example.com", "rfc7541-4.2: domain Huffman roundtrip")
  echo "RFC 7541 §4.2 String Encoding: OK"

testHpackStringEncoding()

echo ""
echo "--- RFC 7541 §4.3: Dynamic Table Size Updates ---"

proc testHpackDynamicTableSizeUpdate() =
  var dt = initHpackDynamicTable(4096)
  check(dt.maxSize == 4096, "rfc7541-4.3: initial max size 4096")

  dt.setMaxSize(2048)
  check(dt.maxSize == 2048, "rfc7541-4.3: resize to 2048")

  dt.setMaxSize(0)
  check(dt.maxSize == 0, "rfc7541-4.3: resize to 0")
  check(dt.len == 0, "rfc7541-4.3: empty table after resize to 0")

  dt.setMaxSize(4096)
  dt.add("x-test", "value")
  check(dt.len == 1, "rfc7541-4.3: entry added")
  dt.setMaxSize(0)
  check(dt.len == 0, "rfc7541-4.3: entry evicted on resize to 0")

  var sizeExceedRaised = false
  try:
    dt.setMaxSize(70000)
  except HpackError:
    sizeExceedRaised = true
  check(sizeExceedRaised, "rfc7541-4.3: size update exceeding limit rejected")

  var negRaised = false
  try:
    dt.setMaxSize(-1)
  except HpackError:
    negRaised = true
  check(negRaised, "rfc7541-4.3: negative size update rejected")
  echo "RFC 7541 §4.3 Dynamic Table Size: OK"

testHpackDynamicTableSizeUpdate()

echo ""
echo "--- RFC 7541: HPACK Dynamic Table Index Bounds ---"

proc testHpackDynamicTableIndexBounds() =
  var dt = initHpackDynamicTable(4096)
  dt.add("x-first", "one")
  dt.add("x-second", "two")

  let entry0 = dt.getEntry(62)
  check(entry0.name == "x-second", "rfc7541: dynamic table index 62 is most recent")

  let entry1 = dt.getEntry(63)
  check(entry1.name == "x-first", "rfc7541: dynamic table index 63 is second")

  var outOfBoundsRaised = false
  try:
    discard dt.getEntry(64)
  except HpackError:
    outOfBoundsRaised = true
  check(outOfBoundsRaised, "rfc7541: dynamic table index 64 out of range")

  var zeroIdxRaised = false
  try:
    discard dt.getEntry(0)
  except HpackError:
    zeroIdxRaised = true
  check(zeroIdxRaised, "rfc7541: index 0 raises error")

  let staticEntry = dt.getEntry(2)
  check(staticEntry.name == ":method" and staticEntry.value == "GET", "rfc7541: static table entry 2")
  echo "RFC 7541 Dynamic Table Index Bounds: OK"

testHpackDynamicTableIndexBounds()

echo ""
echo "--- RFC 7541: HPACK Encode/Decode Full Headers ---"

proc testHpackFullRoundtrip() =
  var encoder = initHpackEncoder(huffman = true)
  var decoder = initHpackDecoder()

  let reqHeaders = @[
    (":method", "GET"),
    (":path", "/"),
    (":scheme", "https"),
    (":authority", "www.example.com"),
    ("accept", "*/*"),
  ]

  var buf = ""
  hpackEncode(encoder, reqHeaders, buf)
  check(buf.len > 0, "rfc7541: headers encoded")

  let decoded = hpackDecode(decoder, cast[seq[byte]](buf))
  check(decoded.len == reqHeaders.len, "rfc7541: decoded count matches")
  for i in 0..<decoded.len:
    check(decoded[i][0] == reqHeaders[i][0], "rfc7541: header name " & $i)
    check(decoded[i][1] == reqHeaders[i][1], "rfc7541: header value " & $i)

  var encoder2 = initHpackEncoder(huffman = false)
  var decoder2 = initHpackDecoder()
  buf = ""
  hpackEncode(encoder2, reqHeaders, buf)
  let decoded2 = hpackDecode(decoder2, cast[seq[byte]](buf))
  check(decoded2.len == reqHeaders.len, "rfc7541: raw string decoded count matches")
  echo "RFC 7541 Full Roundtrip: OK"

testHpackFullRoundtrip()

echo ""
echo "--- RFC 7541: HPACK Size Update Ordering ---"

proc testHpackSizeUpdateOrdering() =
  var decoder = initHpackDecoder()

  var data = newSeq[byte](0)
  data.add(0x40 or 0x00)
  data.add(0x02)
  data.add(byte('x'))
  data.add(byte('y'))
  data.add(0x02)
  data.add(byte('a'))
  data.add(byte('b'))
  let decoded = hpackDecode(decoder, data)
  check(decoded.len == 1, "rfc7541: header before size update ok")
  check(decoded[0][0] == "xy" and decoded[0][1] == "ab", "rfc7541: header values correct")

  data = @[]
  data.add(0x20 or 0x1F)
  data.add(0x01)
  var sizeUpdateRaised = false
  try:
    data.add(0x40 or 0x00)
    data.add(0x02)
    data.add(byte('a'))
    data.add(byte('b'))
    data.add(0x02)
    data.add(byte('c'))
    data.add(byte('d'))
    discard hpackDecode(decoder, data)
    data = @[]
    data.add(0x40 or 0x00)
    data.add(0x02)
    data.add(byte('e'))
    data.add(byte('f'))
    data.add(0x02)
    data.add(byte('g'))
    data.add(byte('h'))
    data.add(0x20 or 0x00)
    discard hpackDecode(decoder, data)
  except HpackError:
    sizeUpdateRaised = true
  check(sizeUpdateRaised, "rfc7541: size update after header entry rejected")
  echo "RFC 7541 Size Update Ordering: OK"

testHpackSizeUpdateOrdering()

echo ""
echo "--- RFC 7541: Huffman Decode Safety ---"

proc testHuffmanDecodeSafety() =
  var buf = ""
  huffmanEncode(cast[seq[byte]]("hello world"), buf)
  var decoded = ""
  huffmanDecode(cast[seq[byte]](buf), decoded)
  check(decoded == "hello world", "rfc7541-huffman: basic roundtrip")

  buf = ""
  decoded = ""
  huffmanEncode(cast[seq[byte]](""), buf)
  huffmanDecode(cast[seq[byte]](buf), decoded)
  check(decoded == "", "rfc7541-huffman: empty roundtrip")

  var invalidHuff: seq[byte] = @[0xFF'u8, 0xFF, 0xFF, 0xFF]
  var invalidRaised = false
  try:
    var out1 = ""
    huffmanDecode(invalidHuff, out1)
  except HpackError:
    invalidRaised = true
  check(invalidRaised, "rfc7541-huffman: invalid Huffman sequence rejected")

  var emptyDecoded = ""
  huffmanDecode(newSeq[byte](0), emptyDecoded)
  check(emptyDecoded == "", "rfc7541-huffman: empty input ok")
  echo "RFC 7541 Huffman Decode Safety: OK"

testHuffmanDecodeSafety()

echo ""
echo "--- RFC 6455 §5.2: Reserved Opcodes ---"

proc testWsReservedOpcodes() =
  let reservedOpcodes = [3, 4, 5, 6, 7]
  for op in reservedOpcodes:
    var frame = newSeq[byte](6)
    frame[0] = byte(0x80 or op)
    frame[1] = 0x80
    frame[2] = 0; frame[3] = 0; frame[4] = 0; frame[5] = 0
    let decoded = decodeFrame(cast[string](frame))
    check(decoded.isNone, "rfc6455-5.2: reserved opcode " & $op & " rejected")
  echo "RFC 6455 §5.2 Reserved Opcodes: OK"

testWsReservedOpcodes()

echo ""
echo "--- RFC 6455 §5.4: Control Frame Fragmentation ---"

proc testWsControlFragmentation() =
  let controlOpcodes: seq[byte] = @[0x08, 0x09, 0x0A]
  for op in controlOpcodes:
    var frame = cast[string](newSeq[byte](6))
    frame[0] = char(op)
    frame[1] = char(0x80)
    frame[2] = '\0'; frame[3] = '\0'; frame[4] = '\0'; frame[5] = '\0'
    let decoded = decodeFrame(frame)
    check(decoded.isNone, "rfc6455-5.4: control frame without FIN rejected: opcode " & $op)

  for op in controlOpcodes:
    var frame = cast[string](newSeq[byte](6))
    frame[0] = char(0x80 or op)
    frame[1] = char(0x80)
    frame[2] = '\0'; frame[3] = '\0'; frame[4] = '\0'; frame[5] = '\0'
    let decoded = decodeFrame(frame)
    check(decoded.isSome, "rfc6455-5.4: control frame with FIN accepted: opcode " & $op)
  echo "RFC 6455 §5.4 Control Fragmentation: OK"

testWsControlFragmentation()

echo ""
echo "--- RFC 6455 §5.5: Control Frame Payload Limit ---"

proc testWsControlPayloadLimit() =
  var validPing = newString(6 + 125)
  validPing[0] = char(0x80 or 0x09)
  validPing[1] = char(0x80 or 125)
  validPing[2] = '\0'; validPing[3] = '\0'; validPing[4] = '\0'; validPing[5] = '\0'
  for i in 6..<validPing.len: validPing[i] = 'A'
  let validResult = decodeFrame(validPing)
  check(validResult.isSome, "rfc6455-5.5: ping with 125 bytes accepted")

  var tooLargePing = newString(8 + 126)
  tooLargePing[0] = char(0x80 or 0x09)
  tooLargePing[1] = char(0x80 or 126)
  tooLargePing[2] = '\0'
  tooLargePing[3] = char(126)
  tooLargePing[4] = '\0'; tooLargePing[5] = '\0'; tooLargePing[6] = '\0'; tooLargePing[7] = '\0'
  for i in 8..<tooLargePing.len: tooLargePing[i] = 'A'
  let tooLargeResult = decodeFrame(tooLargePing)
  check(tooLargeResult.isNone, "rfc6455-5.5: ping with 126-byte extended length rejected")

  var validClose = newString(8)
  validClose[0] = char(0x80 or 0x08)
  validClose[1] = char(0x80 or 2)
  validClose[2] = '\0'; validClose[3] = '\0'; validClose[4] = '\0'; validClose[5] = '\0'
  validClose[6] = '\x03'; validClose[7] = '\xE8'
  let closeResult = decodeFrame(validClose)
  check(closeResult.isSome, "rfc6455-5.5: close with 2-byte code accepted")

  var oneByteClose = newString(7)
  oneByteClose[0] = char(0x80 or 0x08)
  oneByteClose[1] = char(0x80 or 1)
  oneByteClose[2] = '\0'; oneByteClose[3] = '\0'; oneByteClose[4] = '\0'; oneByteClose[5] = '\0'
  oneByteClose[6] = '\x03'
  let oneByteResult = decodeFrame(oneByteClose)
  check(oneByteResult.isNone, "rfc6455-5.5: close with 1-byte payload rejected")
  echo "RFC 6455 §5.5 Control Payload Limit: OK"

testWsControlPayloadLimit()

echo ""
echo "--- RFC 6455 §7.1.1: Close Frame ---"

proc testWsCloseFrame() =
  var closeFrame = newString(8)
  closeFrame[0] = char(0x80 or 0x08)
  closeFrame[1] = char(0x80 or 2)
  closeFrame[2] = '\0'; closeFrame[3] = '\0'; closeFrame[4] = '\0'; closeFrame[5] = '\0'
  closeFrame[6] = '\x03'; closeFrame[7] = '\xE8'
  let result = decodeFrame(closeFrame)
  check(result.isSome, "rfc6455-7.1.1: close frame parsed")
  if result.isSome:
    check(result.get.message.opcode == wsClose, "rfc6455-7.1.1: close opcode")
    check(result.get.message.isFinal, "rfc6455-7.1.1: close is final")

  var emptyClose = newString(6)
  emptyClose[0] = char(0x80 or 0x08)
  emptyClose[1] = char(0x80)
  emptyClose[2] = '\0'; emptyClose[3] = '\0'; emptyClose[4] = '\0'; emptyClose[5] = '\0'
  let emptyResult = decodeFrame(emptyClose)
  check(emptyResult.isSome, "rfc6455-7.1.1: empty close frame accepted")
  echo "RFC 6455 §7.1.1 Close Frame: OK"

testWsCloseFrame()

echo ""
echo "--- RFC 6455: WebSocket Accept Key ---"

proc testWsAcceptKey() =
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let accept = generateAcceptKey(key)
  check(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "rfc6455: accept key for RFC example")
  echo "RFC 6455 Accept Key: OK"

testWsAcceptKey()

echo ""
echo "--- RFC 6455: Reserved RSV Bits ---"

proc testWsRsvBits() =
  var rsvFrame = newString(6)
  rsvFrame[0] = char(0x80 or 0x10 or 0x01)
  rsvFrame[1] = char(0x80)
  rsvFrame[2] = '\0'; rsvFrame[3] = '\0'; rsvFrame[4] = '\0'; rsvFrame[5] = '\0'
  let rsvResult = decodeFrame(rsvFrame)
  check(rsvResult.isNone, "rfc6455: RSV1 bit set without extension rejected")

  var rsv2Frame = newString(6)
  rsv2Frame[0] = char(0x80 or 0x20 or 0x01)
  rsv2Frame[1] = char(0x80)
  rsv2Frame[2] = '\0'; rsv2Frame[3] = '\0'; rsv2Frame[4] = '\0'; rsv2Frame[5] = '\0'
  let rsv2Result = decodeFrame(rsv2Frame)
  check(rsv2Result.isNone, "rfc6455: RSV2 bit set rejected")

  var rsv3Frame = newString(6)
  rsv3Frame[0] = char(0x80 or 0x40 or 0x01)
  rsv3Frame[1] = char(0x80)
  rsv3Frame[2] = '\0'; rsv3Frame[3] = '\0'; rsv3Frame[4] = '\0'; rsv3Frame[5] = '\0'
  let rsv3Result = decodeFrame(rsv3Frame)
  check(rsv3Result.isNone, "rfc6455: RSV3 bit set rejected")
  echo "RFC 6455 RSV Bits: OK"

testWsRsvBits()

echo ""
echo "--- RFC 6455: Server Frame Encoding ---"

proc testWsServerFrameEncoding() =
  let textFrame = encodeFrame(wsText, "hello", mask = false)
  check(textFrame.len == 2 + 5, "rfc6455: server text frame size")
  check(ord(textFrame[0]) == (0x80 or 0x01), "rfc6455: server text FIN+opcode")
  check(ord(textFrame[1]) == 5, "rfc6455: server text payload length")
  check(textFrame[2..6] == "hello", "rfc6455: server text payload")

  let maskedFrame = encodeFrame(wsText, "hi", mask = true)
  check(maskedFrame.len == 2 + 4 + 2, "rfc6455: masked frame size")
  check((ord(maskedFrame[1]) and 0x80) != 0, "rfc6455: masked frame mask bit set")

  let emptyFrame = encodeFrame(wsText, "", mask = false)
  check(emptyFrame.len == 2, "rfc6455: empty text frame size")
  check(ord(emptyFrame[1]) == 0, "rfc6455: empty text payload length")
  echo "RFC 6455 Server Frame Encoding: OK"

testWsServerFrameEncoding()

echo ""
echo "--- RFC 6455: WebSocket Handshake Response ---"

proc testWsHandshake() =
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let acceptKey = generateAcceptKey(key)
  let response = createHandshakeResponse(acceptKey)
  check("101" in response, "rfc6455: handshake has 101 status")
  check("Upgrade: websocket" in response, "rfc6455: handshake has Upgrade header")
  check("Connection: Upgrade" in response, "rfc6455: handshake has Connection header")
  check("Sec-WebSocket-Accept: " in response, "rfc6455: handshake has Accept header")
  check(response.endsWith("\r\n\r\n"), "rfc6455: handshake ends with CRLF CRLF")
  echo "RFC 6455 Handshake: OK"

testWsHandshake()

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
