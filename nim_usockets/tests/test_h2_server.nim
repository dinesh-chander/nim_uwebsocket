import std/options
import ../src/nim_usockets/hpack as hpackMod
import ../src/nim_usockets/h2_protocol as h2p

var passed = 0
var failed = 0

template check(label: string, cond: bool) =
  if cond:
    inc passed
  else:
    inc failed
    echo "FAIL: ", label

echo "=== H2 Server Integration Tests ==="

block h2PrefaceDetection:
  echo "--- H2 Preface Detection ---"
  let preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  check("preface length", preface.len == 24)
  check("preface starts with PRI", preface[0..2] == "PRI")

block h2SettingsSerialization:
  echo "--- H2 Settings ---"
  let settings = h2p.defaultH2Settings()
  var buf = ""
  h2p.serializeSettings(settings, buf)
  check("settings non-empty", buf.len > 0)

  var ackBuf = ""
  h2p.serializeSettingsAck(ackBuf)
  check("settings ack", ackBuf.len == h2p.H2FrameHeaderSize)

block h2HeadersEncodeDecode:
  echo "--- HPACK in Server Context ---"
  var encoder = hpackMod.initHpackEncoder(huffman = true)
  var decoder = hpackMod.initHpackDecoder()

  var headerBlock = ""
  let reqHeaders = [
    (":method", "GET"),
    (":path", "/"),
    (":scheme", "https"),
    (":authority", "localhost"),
    ("accept", "*/*"),
  ]
  hpackMod.hpackEncode(encoder, reqHeaders, headerBlock)
  check("header block non-empty", headerBlock.len > 0)

  let decoded = hpackMod.hpackDecode(decoder, cast[seq[byte]](headerBlock))
  check("decoded 5 headers", decoded.len == 5)
  check("method GET", decoded[0] == (":method", "GET"))
  check("path /", decoded[1] == (":path", "/"))

block h2ResponseFrame:
  echo "--- H2 Response Frame Construction ---"
  var encoder = hpackMod.initHpackEncoder(huffman = true)

  var headerBlock = ""
  let respHeaders = [
    (":status", "200"),
    ("content-type", "text/plain"),
    ("content-length", "5"),
  ]
  hpackMod.hpackEncode(encoder, respHeaders, headerBlock)

  var buf = ""
  h2p.serializeHeaders(1, headerBlock, false, true, buf)
  check("resp headers frame", buf.len > 0)

  h2p.serializeData(1, "hello", true, buf)
  check("resp with data", buf.len > headerBlock.len + h2p.H2FrameHeaderSize * 2)

block h2FullExchange:
  echo "--- Full H2 Frame Exchange ---"
  var clientEncoder = hpackMod.initHpackEncoder(huffman = true)
  var serverDecoder = hpackMod.initHpackDecoder()

  var reqBuf = ""
  var reqHeaderBlock = ""
  hpackMod.hpackEncode(clientEncoder, [
    (":method", "POST"),
    (":path", "/api/data"),
    (":scheme", "https"),
    (":authority", "localhost"),
    ("content-type", "application/json"),
  ], reqHeaderBlock)
  h2p.serializeHeaders(1, reqHeaderBlock, false, true, reqBuf)
  h2p.serializeData(1, "{\"key\":\"value\"}", true, reqBuf)

  var pos = 0
  let dataBytes = cast[seq[byte]](reqBuf)

  let headersFrame = h2p.parseH2Frame(dataBytes, pos)
  check("parse headers frame", headersFrame.isSome)
  check("headers type", headersFrame.get().frameType == h2p.ftHeaders)
  check("headers stream 1", headersFrame.get().streamId == 1)

  let decodedHeaders = hpackMod.hpackDecode(serverDecoder, cast[seq[byte]](headersFrame.get().payload))
  check("decoded method", decodedHeaders[0] == (":method", "POST"))
  check("decoded path", decodedHeaders[1] == (":path", "/api/data"))

  let dataFrame = h2p.parseH2Frame(dataBytes, pos)
  check("parse data frame", dataFrame.isSome)
  check("data type", dataFrame.get().frameType == h2p.ftData)
  check("data endStream", h2p.hasFlag(dataFrame.get(), h2p.FlagEndStream))
  check("data payload", dataFrame.get().payload == "{\"key\":\"value\"}")

block h2PingPong:
  echo "--- Ping/Pong ---"
  var pingBuf = ""
  h2p.serializePing([1'u8, 2, 3, 4, 5, 6, 7, 8], false, pingBuf)
  var pos = 0
  let pingFrame = h2p.parseH2Frame(cast[seq[byte]](pingBuf), pos)
  check("ping parsed", pingFrame.isSome)
  check("ping type", pingFrame.get().frameType == h2p.ftPing)
  check("ping no ack", not h2p.hasFlag(pingFrame.get(), h2p.FlagAck))

  var pongBuf = ""
  var pingData: array[8, byte]
  copyMem(addr pingData[0], unsafeAddr pingFrame.get().payload[0], 8)
  h2p.serializePing(pingData, true, pongBuf)
  pos = 0
  let pongFrame = h2p.parseH2Frame(cast[seq[byte]](pongBuf), pos)
  check("pong ack", h2p.hasFlag(pongFrame.get(), h2p.FlagAck))

block h2ResponseHeadersHpackEncoded:
  echo "--- H2 Response HEADERS Frame HPACK Encoding ---"
  var encoder = hpackMod.initHpackEncoder(huffman = true)
  var decoder = hpackMod.initHpackDecoder()

  var headerBlock = ""
  let respHeaders = [
    (":status", "200"),
    ("content-type", "application/json"),
    ("content-length", "13"),
  ]
  hpackMod.hpackEncode(encoder, respHeaders, headerBlock)
  check("resp header block non-empty", headerBlock.len > 0)

  var buf = ""
  h2p.serializeHeaders(1, headerBlock, false, true, buf)

  var pos = 0
  let frame = h2p.parseH2Frame(cast[seq[byte]](buf), pos)
  check("resp HEADERS parsed", frame.isSome)
  check("resp HEADERS type", frame.get().frameType == h2p.ftHeaders)
  check("resp HEADERS stream 1", frame.get().streamId == 1)
  check("resp HEADERS endHeaders flag", h2p.hasFlag(frame.get(), h2p.FlagEndHeaders))
  check("resp HEADERS no endStream", not h2p.hasFlag(frame.get(), h2p.FlagEndStream))

  let decoded = hpackMod.hpackDecode(decoder, cast[seq[byte]](frame.get().payload))
  check("decoded resp 3 headers", decoded.len == 3)
  check("decoded resp status", decoded[0] == (":status", "200"))
  check("decoded resp content-type", decoded[1] == ("content-type", "application/json"))
  check("decoded resp content-length", decoded[2] == ("content-length", "13"))

block h2ResponseDataFrame:
  echo "--- H2 Response DATA Frame ---"
  let body = "Hello, World!"
  var buf = ""
  h2p.serializeData(1, body, true, buf)

  var pos = 0
  let frame = h2p.parseH2Frame(cast[seq[byte]](buf), pos)
  check("DATA frame parsed", frame.isSome)
  check("DATA frame type", frame.get().frameType == h2p.ftData)
  check("DATA frame stream 1", frame.get().streamId == 1)
  check("DATA frame endStream", h2p.hasFlag(frame.get(), h2p.FlagEndStream))
  check("DATA frame payload", frame.get().payload == body)

block h2EndStreamOnHeaders:
  echo "--- END_STREAM on HEADERS (no body) ---"
  var encoder = hpackMod.initHpackEncoder(huffman = true)

  var headerBlock = ""
  hpackMod.hpackEncode(encoder, [(":status", "204")], headerBlock)

  var buf = ""
  h2p.serializeHeaders(1, headerBlock, endStream = true, endHeaders = true, buf)

  var pos = 0
  let frame = h2p.parseH2Frame(cast[seq[byte]](buf), pos)
  check("no-body HEADERS parsed", frame.isSome)
  check("no-body endStream set", h2p.hasFlag(frame.get(), h2p.FlagEndStream))
  check("no-body endHeaders set", h2p.hasFlag(frame.get(), h2p.FlagEndHeaders))

block h2EndStreamOnLastData:
  echo "--- END_STREAM on Last DATA (with body) ---"
  var encoder = hpackMod.initHpackEncoder(huffman = true)

  var headerBlock = ""
  hpackMod.hpackEncode(encoder, [(":status", "200"), ("content-length", "5")], headerBlock)

  var buf = ""
  h2p.serializeHeaders(1, headerBlock, endStream = false, endHeaders = true, buf)
  h2p.serializeData(1, "hello", endStream = true, buf)

  var pos = 0
  let headersFrame = h2p.parseH2Frame(cast[seq[byte]](buf), pos)
  check("body HEADERS parsed", headersFrame.isSome)
  check("body HEADERS no endStream", not h2p.hasFlag(headersFrame.get(), h2p.FlagEndStream))
  check("body HEADERS endHeaders", h2p.hasFlag(headersFrame.get(), h2p.FlagEndHeaders))

  let dataFrame = h2p.parseH2Frame(cast[seq[byte]](buf), pos)
  check("body DATA parsed", dataFrame.isSome)
  check("body DATA endStream", h2p.hasFlag(dataFrame.get(), h2p.FlagEndStream))
  check("body DATA payload", dataFrame.get().payload == "hello")

block h2ConcurrentStreams:
  echo "--- Multiple Concurrent Streams ---"
  var encoder = hpackMod.initHpackEncoder(huffman = true)
  var decoder = hpackMod.initHpackDecoder()

  var buf = ""
  for streamId in [uint32(1), uint32(3), uint32(5)]:
    var headerBlock = ""
    hpackMod.hpackEncode(encoder, [(":status", "200"), ("x-stream", $streamId)], headerBlock)
    h2p.serializeHeaders(streamId, headerBlock, endStream = false, endHeaders = true, buf)
    h2p.serializeData(streamId, "body" & $streamId, endStream = true, buf)

  var pos = 0
  let data = cast[seq[byte]](buf)
  for streamId in [uint32(1), uint32(3), uint32(5)]:
    let hf = h2p.parseH2Frame(data, pos)
    check("stream " & $streamId & " HEADERS", hf.isSome and hf.get().streamId == streamId)
    let decoded = hpackMod.hpackDecode(decoder, cast[seq[byte]](hf.get().payload))
    check("stream " & $streamId & " status", decoded[0] == (":status", "200"))
    check("stream " & $streamId & " x-stream", decoded[1] == ("x-stream", $streamId))

    let df = h2p.parseH2Frame(data, pos)
    check("stream " & $streamId & " DATA", df.isSome and df.get().streamId == streamId)
    check("stream " & $streamId & " payload", df.get().payload == "body" & $streamId)
    check("stream " & $streamId & " endStream", h2p.hasFlag(df.get(), h2p.FlagEndStream))

block h2LargeBodySplit:
  echo "--- Large Body Split Into Multiple DATA Frames ---"
  let maxFrameSize = 16384
  let bodySize = maxFrameSize * 2 + 100
  var largeBody = newString(bodySize)
  for i in 0 ..< bodySize:
    largeBody[i] = char(ord('A') + (i mod 26))

  var buf = ""
  var pos = 0
  var remaining = bodySize
  while remaining > 0:
    let chunkLen = min(remaining, maxFrameSize)
    let chunk = largeBody[pos ..< pos + chunkLen]
    let isLast = pos + chunkLen >= bodySize
    h2p.serializeData(1, chunk, endStream = isLast, buf)
    pos += chunkLen
    remaining -= chunkLen

  var parsePos = 0
  let data = cast[seq[byte]](buf)
  var reconstructed = ""
  var frameCount = 0
  var lastEndStream = false
  while parsePos < data.len:
    let f = h2p.parseH2Frame(data, parsePos)
    check("large body frame " & $frameCount & " parsed", f.isSome)
    if f.isSome:
      check("large body frame type", f.get().frameType == h2p.ftData)
      check("large body frame stream", f.get().streamId == 1)
      check("large body frame size <= maxFrameSize", f.get().payload.len <= maxFrameSize)
      reconstructed.add f.get().payload
      lastEndStream = h2p.hasFlag(f.get(), h2p.FlagEndStream)
    inc frameCount

  check("large body 3 frames", frameCount == 3)
  check("large body last endStream", lastEndStream)
  check("large body reconstructed matches", reconstructed == largeBody)

block h2SetCookieHeaders:
  echo "--- H2 Set-Cookie Headers ---"
  var encoder = hpackMod.initHpackEncoder(huffman = true)
  var decoder = hpackMod.initHpackDecoder()

  var headerBlock = ""
  let respHeaders = @[
    (":status", "200"),
    ("content-type", "text/html"),
    ("set-cookie", "session=abc123; Path=/"),
    ("set-cookie", "theme=dark; Path=/"),
  ]
  hpackMod.hpackEncode(encoder, respHeaders, headerBlock)

  var buf = ""
  h2p.serializeHeaders(1, headerBlock, endStream = true, endHeaders = true, buf)

  var pos = 0
  let frame = h2p.parseH2Frame(cast[seq[byte]](buf), pos)
  check("set-cookie HEADERS parsed", frame.isSome)
  let decoded = hpackMod.hpackDecode(decoder, cast[seq[byte]](frame.get().payload))
  check("set-cookie 4 headers", decoded.len == 4)
  check("set-cookie first", decoded[2] == ("set-cookie", "session=abc123; Path=/"))
  check("set-cookie second", decoded[3] == ("set-cookie", "theme=dark; Path=/"))

block h2TrailersFrame:
  echo "--- H2 Trailers Frame ---"
  var encoder = hpackMod.initHpackEncoder(huffman = true)
  var decoder = hpackMod.initHpackDecoder()

  var headerBlock = ""
  hpackMod.hpackEncode(encoder, [(":status", "200"), ("content-type", "text/plain")], headerBlock)
  var buf = ""
  h2p.serializeHeaders(1, headerBlock, endStream = false, endHeaders = true, buf)
  h2p.serializeData(1, "hello", endStream = false, buf)

  var trailerBlock = ""
  hpackMod.hpackEncode(encoder, [("grpc-status", "0"), ("grpc-message", "OK")], trailerBlock)
  h2p.serializeTrailers(1, trailerBlock, buf)

  var pos = 0
  let data = cast[seq[byte]](buf)
  let hf = h2p.parseH2Frame(data, pos)
  check("trailers: HEADERS parsed", hf.isSome)
  check("trailers: no endStream on headers", not h2p.hasFlag(hf.get(), h2p.FlagEndStream))

  let df = h2p.parseH2Frame(data, pos)
  check("trailers: DATA parsed", df.isSome)
  check("trailers: no endStream on data", not h2p.hasFlag(df.get(), h2p.FlagEndStream))

  let tf = h2p.parseH2Frame(data, pos)
  check("trailers: trailer frame parsed", tf.isSome)
  check("trailers: trailer type HEADERS", tf.get().frameType == h2p.ftHeaders)
  check("trailers: trailer endStream", h2p.hasFlag(tf.get(), h2p.FlagEndStream))
  check("trailers: trailer endHeaders", h2p.hasFlag(tf.get(), h2p.FlagEndHeaders))
  check("trailers: trailer stream 1", tf.get().streamId == 1)

  let decodedTrailers = hpackMod.hpackDecode(decoder, cast[seq[byte]](tf.get().payload))
  check("trailers: decoded 2 headers", decodedTrailers.len == 2)
  check("trailers: grpc-status", decodedTrailers[0] == ("grpc-status", "0"))
  check("trailers: grpc-message", decodedTrailers[1] == ("grpc-message", "OK"))

block h2PushPromiseFrame:
  echo "--- H2 Push Promise Frame ---"
  var encoder = hpackMod.initHpackEncoder(huffman = true)
  var decoder = hpackMod.initHpackDecoder()

  var promiseBlock = ""
  hpackMod.hpackEncode(encoder, [
    (":method", "GET"),
    (":path", "/style.css"),
    (":scheme", "https"),
    (":authority", "example.com"),
  ], promiseBlock)

  var buf = ""
  h2p.serializePushPromise(1, 2, promiseBlock, buf)

  var pos = 0
  let ppFrame = h2p.parseH2Frame(cast[seq[byte]](buf), pos)
  check("push: PUSH_PROMISE parsed", ppFrame.isSome)
  check("push: frame type", ppFrame.get().frameType == h2p.ftPushPromise)
  check("push: stream 1", ppFrame.get().streamId == 1)
  check("push: endHeaders", h2p.hasFlag(ppFrame.get(), h2p.FlagEndHeaders))

  let payload = ppFrame.get().payload
  check("push: payload >= 4", payload.len >= 4)
  let payBytes = cast[ptr UncheckedArray[byte]](unsafeAddr payload[0])
  let promisedId = h2p.readU32BE(payBytes.toOpenArray(0, 3), 0) and 0x7FFFFFFF'u32
  check("push: promised stream 2", promisedId == 2)

  let hdrBlock = payload[4 ..< payload.len]
  let decoded = hpackMod.hpackDecode(decoder, cast[seq[byte]](hdrBlock))
  check("push: decoded 4 headers", decoded.len == 4)
  check("push: method GET", decoded[0] == (":method", "GET"))
  check("push: path /style.css", decoded[1] == (":path", "/style.css"))

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
else:
  quit(0)
