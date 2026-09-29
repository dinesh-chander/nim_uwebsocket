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

proc testFrameRoundtrip() =
  var buf = ""
  let frame = H2Frame(
    length: 5,
    frameType: ftData,
    flags: FlagEndStream,
    streamId: 1,
    payload: "hello",
  )
  serializeH2Frame(frame, buf)

  check(buf.len == H2FrameHeaderSize + 5, "data frame total size")

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "data frame parsed")
  let f = parsed.get
  check(f.frameType == ftData, "data frame type")
  check(f.flags == FlagEndStream, "data frame flags")
  check(f.streamId == 1, "data frame stream id")
  check(f.payload == "hello", "data frame payload")
  check(f.length == 5, "data frame length")
  echo "Frame roundtrip: OK"

proc testSettingsFrame() =
  var buf = ""
  let settings = H2Settings(
    headerTableSize: 4096,
    enablePush: false,
    maxConcurrentStreams: 128,
    initialWindowSize: 65535,
    maxFrameSize: 16384,
    maxHeaderListSize: high(uint32),
  )
  serializeSettings(settings, buf)

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "settings frame parsed")
  let f = parsed.get
  check(f.frameType == ftSettings, "settings frame type")
  check(f.streamId == 0, "settings frame stream 0")
  check(f.length == 36, "settings payload 36 bytes (6 params * 6)")

  let s = parseSettings(f.payload)
  check(s.headerTableSize == 4096, "settings header table size")
  check(s.enablePush == false, "settings enable push")
  check(s.maxConcurrentStreams == 128, "settings max concurrent")
  check(s.initialWindowSize == 65535, "settings initial window")
  check(s.maxFrameSize == 16384, "settings max frame size")
  check(s.maxHeaderListSize == high(uint32), "settings max header list")
  echo "Settings frame: OK"

proc testSettingsAck() =
  var buf = ""
  serializeSettingsAck(buf)
  check(buf.len == H2FrameHeaderSize, "settings ack size")

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "settings ack parsed")
  let f = parsed.get
  check(f.frameType == ftSettings, "settings ack type")
  check(f.hasFlag(FlagAck), "settings ack flag")
  check(f.length == 0, "settings ack empty payload")
  echo "Settings ACK: OK"

proc testPingFrame() =
  let pingData: array[8, byte] = [1'u8, 2, 3, 4, 5, 6, 7, 8]
  var buf = ""
  serializePing(pingData, false, buf)
  check(buf.len == H2FrameHeaderSize + 8, "ping frame size")

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "ping parsed")
  let f = parsed.get
  check(f.frameType == ftPing, "ping type")
  check(not f.hasFlag(FlagAck), "ping no ack")
  check(f.payload.len == 8, "ping payload 8 bytes")
  for i in 0..7:
    check(byte(f.payload[i]) == pingData[i], "ping byte " & $i)

  var bufAck = ""
  serializePing(pingData, true, bufAck)
  pos = 0
  let parsedAck = parseH2Frame(cast[seq[byte]](bufAck), pos)
  check(parsedAck.isSome, "ping ack parsed")
  check(parsedAck.get.hasFlag(FlagAck), "ping ack flag")
  echo "Ping frame: OK"

proc testGoawayFrame() =
  var buf = ""
  serializeGoaway(42, uint32(ord(ecNoError)), buf)
  check(buf.len == H2FrameHeaderSize + 8, "goaway frame size")

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "goaway parsed")
  let f = parsed.get
  check(f.frameType == ftGoaway, "goaway type")
  check(f.streamId == 0, "goaway stream 0")

  let payBytes = cast[ptr UncheckedArray[byte]](unsafeAddr f.payload[0])
  let lastId = readU32BE(payBytes.toOpenArray(0, 7), 0) and 0x7FFFFFFF'u32
  let errCode = readU32BE(payBytes.toOpenArray(0, 7), 4)
  check(lastId == 42, "goaway last stream id")
  check(errCode == 0, "goaway error code")
  echo "Goaway frame: OK"

proc testWindowUpdateFrame() =
  var buf = ""
  serializeWindowUpdate(1, 32768, buf)
  check(buf.len == H2FrameHeaderSize + 4, "window update size")

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "window update parsed")
  let f = parsed.get
  check(f.frameType == ftWindowUpdate, "window update type")
  check(f.streamId == 1, "window update stream id")
  let payBytes = cast[ptr UncheckedArray[byte]](unsafeAddr f.payload[0])
  let increment = readU32BE(payBytes.toOpenArray(0, 3), 0) and 0x7FFFFFFF'u32
  check(increment == 32768, "window update increment")
  echo "Window update frame: OK"

proc testRstStreamFrame() =
  var buf = ""
  serializeRstStream(3, uint32(ord(ecCancel)), buf)
  check(buf.len == H2FrameHeaderSize + 4, "rst stream size")

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "rst stream parsed")
  let f = parsed.get
  check(f.frameType == ftRstStream, "rst stream type")
  check(f.streamId == 3, "rst stream id")
  let payBytes = cast[ptr UncheckedArray[byte]](unsafeAddr f.payload[0])
  let errCode = readU32BE(payBytes.toOpenArray(0, 3), 0)
  check(errCode == uint32(ord(ecCancel)), "rst error code cancel")
  echo "RST_STREAM frame: OK"

proc testHeadersFrame() =
  var buf = ""
  serializeHeaders(1, "compressed-headers-here", endStream = false, endHeaders = true, buf)

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "headers frame parsed")
  let f = parsed.get
  check(f.frameType == ftHeaders, "headers type")
  check(f.streamId == 1, "headers stream id")
  check(f.hasFlag(FlagEndHeaders), "headers end headers")
  check(not f.hasFlag(FlagEndStream), "headers no end stream")
  check(f.payload == "compressed-headers-here", "headers payload")
  echo "Headers frame: OK"

proc testDataFrame() =
  var buf = ""
  serializeData(3, "response body content", endStream = true, buf)

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "data frame parsed")
  let f = parsed.get
  check(f.frameType == ftData, "data type")
  check(f.streamId == 3, "data stream id")
  check(f.hasFlag(FlagEndStream), "data end stream")
  check(f.payload == "response body content", "data payload")
  echo "Data frame: OK"

proc testPartialFrame() =
  var buf = ""
  serializeData(1, "hello", endStream = true, buf)

  let partial = cast[seq[byte]](buf[0..5])
  var pos = 0
  let parsed = parseH2Frame(partial, pos)
  check(parsed.isNone, "partial frame returns none")
  check(pos == 0, "partial frame pos unchanged")
  echo "Partial frame: OK"

proc testMultipleFrames() =
  var buf = ""
  serializeSettingsAck(buf)
  serializePing([0'u8, 0, 0, 0, 0, 0, 0, 1], false, buf)
  serializeData(1, "body", endStream = true, buf)

  let data = cast[seq[byte]](buf)
  var pos = 0

  let f1 = parseH2Frame(data, pos)
  check(f1.isSome, "multi frame 1 parsed")
  check(f1.get.frameType == ftSettings, "multi frame 1 settings")

  let f2 = parseH2Frame(data, pos)
  check(f2.isSome, "multi frame 2 parsed")
  check(f2.get.frameType == ftPing, "multi frame 2 ping")

  let f3 = parseH2Frame(data, pos)
  check(f3.isSome, "multi frame 3 parsed")
  check(f3.get.frameType == ftData, "multi frame 3 data")
  check(f3.get.payload == "body", "multi frame 3 payload")

  let f4 = parseH2Frame(data, pos)
  check(f4.isNone, "multi frame 4 none (end of data)")
  echo "Multiple frames: OK"

proc testConnectionPreface() =
  check(H2ConnectionPreface == "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", "connection preface value")
  check(H2ConnectionPreface.len == 24, "connection preface length")
  echo "Connection preface: OK"

proc testStreamIdReservedBit() =
  var buf = ""
  let frame = H2Frame(
    length: 0,
    frameType: ftHeaders,
    flags: FlagEndHeaders,
    streamId: 0x80000001'u32,
    payload: "",
  )
  serializeH2Frame(frame, buf)

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "reserved bit frame parsed")
  check(parsed.get.streamId == 1, "reserved bit masked off")
  echo "Stream ID reserved bit: OK"

proc testTrailersFrame() =
  var buf = ""
  serializeTrailers(1, "trailer-header-block", buf)

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "trailers frame parsed")
  let f = parsed.get
  check(f.frameType == ftHeaders, "trailers frame type is HEADERS")
  check(f.streamId == 1, "trailers stream id")
  check(f.hasFlag(FlagEndStream), "trailers has END_STREAM")
  check(f.hasFlag(FlagEndHeaders), "trailers has END_HEADERS")
  check(f.payload == "trailer-header-block", "trailers payload")
  echo "Trailers frame: OK"

proc testPushPromiseFrame() =
  var buf = ""
  serializePushPromise(1, 2, "push-headers", buf)

  var pos = 0
  let parsed = parseH2Frame(cast[seq[byte]](buf), pos)
  check(parsed.isSome, "push promise frame parsed")
  let f = parsed.get
  check(f.frameType == ftPushPromise, "push promise frame type")
  check(f.streamId == 1, "push promise stream id")
  check(f.hasFlag(FlagEndHeaders), "push promise end headers")
  check(f.payload.len == 4 + "push-headers".len, "push promise payload size")
  let payBytes = cast[ptr UncheckedArray[byte]](unsafeAddr f.payload[0])
  let promisedId = readU32BE(payBytes.toOpenArray(0, 3), 0) and 0x7FFFFFFF'u32
  check(promisedId == 2, "push promise promised stream id")
  let headerBlock = f.payload[4 ..< f.payload.len]
  check(headerBlock == "push-headers", "push promise header block")
  echo "Push promise frame: OK"

testFrameRoundtrip()
testSettingsFrame()
testSettingsAck()
testPingFrame()
testGoawayFrame()
testWindowUpdateFrame()
testRstStreamFrame()
testHeadersFrame()
testDataFrame()
testPartialFrame()
testMultipleFrames()
testConnectionPreface()
testStreamIdReservedBit()
testTrailersFrame()
testPushPromiseFrame()

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
