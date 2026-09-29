import std/[options, strutils, tables]
import nim_fasthttpclient/types
import nim_fasthttpclient/hpack
import nim_fasthttpclient/h2_frames
import nim_fasthttpclient/http1
import nim_fasthttpclient/http2
import nim_fasthttpclient/ws_client
import nim_fasthttpclient/sse_client
import nim_fasthttpclient/connection_pool
import nim_fasthttpclient/client
import nim_usockets/usockets

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

proc testHttp1Serialization() =
  let req = HttpRequest(
    `method`: hmGet,
    host: "example.com",
    port: 80,
    path: "/api/test",
    version: Http11,
    headers: @[HttpHeader(name: "Accept", value: "application/json")],
  )
  let serialized = serializeRequest(req)
  check("GET /api/test HTTP/1.1\r\n" in serialized, "http1 request line")
  check("Host: example.com\r\n" in serialized, "http1 host header")
  check("Accept: application/json\r\n" in serialized, "http1 custom header")

  var httpOn443 = req
  httpOn443.port = 443
  httpOn443.useSsl = false
  check("Host: example.com:443\r\n" in serializeRequest(httpOn443), "http1 includes explicit non-default http port 443")

  var httpsOn443 = req
  httpsOn443.port = 443
  httpsOn443.useSsl = true
  check("Host: example.com\r\n" in serializeRequest(httpsOn443), "http1 omits default https port 443")

  var httpsOn80 = req
  httpsOn80.port = 80
  httpsOn80.useSsl = true
  check("Host: example.com:80\r\n" in serializeRequest(httpsOn80), "http1 includes explicit non-default https port 80")
  echo "HTTP/1.1 serialization: OK"

proc testHttp1Parsing() =
  let rawResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
  var parser = initHttp1Parser()
  var consumed = 0
  let done = parser.feedData(rawResponse, consumed)
  check(done, "http1 parse complete")
  check(parser.response.statusCode == 200, "http1 status 200")
  check(parser.response.statusText == "OK", "http1 status text")
  check(parser.response.body == "hello", "http1 body")
  check(parser.keepAlive, "http1 keepalive")

  parser = initHttp1Parser()
  consumed = 0
  let malformedStatus = parser.feedData("HTTP/1.1 200OK\r\n\r\n", consumed)
  check(malformedStatus, "malformed http1 status line terminates parser")
  check(parser.state == psError, "http1 status line requires space after exactly three digits")

  parser = initHttp1Parser()
  consumed = 0
  let overlongStatus = parser.feedData("HTTP/1.1 " & repeat("2", MaxHttp1StatusLineLen + 1), consumed)
  check(overlongStatus, "overlong unterminated http1 status line terminates parser")
  check(parser.state == psError, "http1 status line length is capped")

  parser = initHttp1Parser()
  consumed = 0
  let overlongHeader = parser.feedData(
    "HTTP/1.1 200 OK\r\nX-Long: " & repeat("a", MaxHttp1HeaderLineLen + 1),
    consumed
  )
  check(overlongHeader, "overlong unterminated http1 header line terminates parser")
  check(parser.state == psError, "http1 header line length is capped")

  parser = initHttp1Parser()
  consumed = 0
  var aggregateHeaders = "HTTP/1.1 200 OK\r\n"
  for i in 0 ..< 10:
    aggregateHeaders.add("X-Header-" & $i & ": " & repeat("b", MaxHttp1HeaderLineLen - 32) & "\r\n")
  let overAggregate = parser.feedData(aggregateHeaders, consumed)
  check(overAggregate, "oversized aggregate http1 headers terminate parser")
  check(parser.state == psError, "http1 aggregate header bytes are capped")
  echo "HTTP/1.1 parsing: OK"

proc testHttp1Chunked() =
  let rawResponse = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
  var parser = initHttp1Parser()
  var consumed = 0
  let done = parser.feedData(rawResponse, consumed)
  check(done, "chunked parse complete")
  check(parser.response.body == "hello world", "chunked body")
  echo "HTTP/1.1 chunked: OK"

proc testHttp1PartialBodyConsumption() =
  var parser = initHttp1Parser()
  var consumed = 0
  let first = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhe"
  var done = parser.feedData(first, consumed)
  check(not done, "partial content-length body waits for more data")
  check(consumed == first.len, "partial content-length body reports consumed bytes")
  check(parser.response.body == "he", "partial content-length body stored once")

  done = parser.feedData("llo", consumed)
  check(done, "partial content-length body completes on next chunk")
  check(parser.response.body == "hello", "partial content-length body not duplicated")
  echo "HTTP/1.1 partial body consumption: OK"

proc testHttp1InformationalResponseSkip() =
  let rawResponse = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  var parser = initHttp1Parser()
  var consumed = 0
  let done = parser.feedData(rawResponse, consumed)
  check(done, "informational response skipped to final response")
  check(parser.response.statusCode == 200, "final response status after informational")
  check(parser.response.body == "ok", "final response body after informational")
  echo "HTTP/1.1 informational response skip: OK"

proc testHttp1NoBodyFramingCloses() =
  var parser = initHttp1Parser()
  var consumed = 0
  let rawResponse = "HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\nabcde"
  let done = parser.feedData(rawResponse, consumed)
  check(done, "204 with content-length completes at headers")
  check(parser.state == psDone, "204 with content-length is done")
  check(consumed == rawResponse.find("\r\n\r\n") + 4, "204 consumes only header block")
  check(not parser.keepAlive, "204 with body framing disables keepalive")

  parser = initHttp1Parser()
  parser.noBodyExpected = true
  consumed = 0
  let headResponse = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"
  let headDone = parser.feedData(headResponse, consumed)
  check(headDone, "HEAD response with content-length completes at headers")
  check(parser.keepAlive, "HEAD content-length alone preserves keepalive")
  echo "HTTP/1.1 no-body framing hardening: OK"

proc testHttp1TransferEncodingContentLengthRejected() =
  var parser = initHttp1Parser()
  var consumed = 0
  let rawResponse = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n"
  let done = parser.feedData(rawResponse, consumed)
  check(done, "te plus content-length completes as terminal parser state")
  check(parser.state == psError, "te plus content-length rejected as parse error")

  parser = initHttp1Parser()
  consumed = 0
  let reverseOrder = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
  discard parser.feedData(reverseOrder, consumed)
  check(parser.state == psError, "content-length plus te rejected in reverse order")
  echo "HTTP/1.1 TE+CL rejection: OK"

proc testHpackReexport() =
  var encoder = initHpackEncoder(huffman = false)
  var decoder = initHpackDecoder()
  var buf = ""
  hpackEncode(encoder, @[(":method", "GET"), (":path", "/")], buf)
  let decoded = hpackDecode(decoder, cast[seq[byte]](buf))
  check(decoded.len == 2, "hpack reexport works")
  check(decoded[0] == (":method", "GET"), "hpack decode :method")
  echo "HPACK re-export: OK"

proc testH2FramesReexport() =
  var buf = ""
  serializeSettingsAck(buf)
  var pos = 0
  let frame = parseH2Frame(cast[seq[byte]](buf), pos)
  check(frame.isSome, "h2 frames reexport works")
  check(frame.get.frameType == ftSettings, "h2 settings type")
  echo "H2 frames re-export: OK"

proc testH2Connection() =
  var conn = initH2ClientConnection()
  var buf = ""
  conn.writeConnectionPreface(buf)
  check(buf.startsWith(H2ConnectionPreface), "h2 preface starts correct")
  check(buf.len > H2ConnectionPreface.len, "h2 preface includes settings")

  let streamId = conn.allocateStream()
  check(streamId == 1, "h2 first stream id")
  check(conn.nextStreamId == 3, "h2 next stream id")

  var headerBuf = ""
  conn.sendHeaders(streamId, @[(":method", "GET"), (":path", "/"), (":scheme", "https"), (":authority", "example.com")], endStream = true, headerBuf)
  check(headerBuf.len > 0, "h2 send headers produces output")
  echo "HTTP/2 connection: OK"

proc h2FrameLength(buf: string, offset: int): int =
  (ord(buf[offset]) shl 16) or (ord(buf[offset + 1]) shl 8) or ord(buf[offset + 2])

proc addRawH2FrameHeader(buf: var string, length: uint32, frameType: uint8, flags: uint8, streamId: uint32) =
  let maskedId = streamId and 0x7FFFFFFF'u32
  buf.add char((length shr 16) and 0xFF)
  buf.add char((length shr 8) and 0xFF)
  buf.add char(length and 0xFF)
  buf.add char(frameType)
  buf.add char(flags)
  buf.add char((maskedId shr 24) and 0xFF)
  buf.add char((maskedId shr 16) and 0xFF)
  buf.add char((maskedId shr 8) and 0xFF)
  buf.add char(maskedId and 0xFF)

proc testH2HeadersFragmentation() =
  var conn = initH2ClientConnection()
  conn.remoteSettings.maxFrameSize = 16_384'u32
  var buf = ""
  conn.sendHeaders(
    1'u32,
    @[
      (":method", "GET"),
      (":path", "/"),
      (":scheme", "https"),
      (":authority", "example.test"),
      ("cookie", repeat("a", 70_000))
    ],
    endStream = true,
    buf
  )

  var offset = 0
  var frameCount = 0
  while offset < buf.len:
    check(buf.len - offset >= 9, "h2 frame header present")
    let frameLen = h2FrameLength(buf, offset)
    let frameType = ord(buf[offset + 3])
    let flags = ord(buf[offset + 4])
    let isLast = offset + 9 + frameLen == buf.len
    check(frameLen <= 16_384, "h2 header block fragment respects peer max frame size")
    if frameCount == 0:
      check(frameType == 0x1, "h2 first header fragment is HEADERS")
      check((flags and 0x1) != 0, "h2 first HEADERS carries END_STREAM")
      check((flags and 0x4) == 0, "h2 first HEADERS omits END_HEADERS when continuations follow")
    else:
      check(frameType == 0x9, "h2 subsequent header fragments are CONTINUATION")
    if isLast:
      check((flags and 0x4) != 0, "h2 final header fragment carries END_HEADERS")
    else:
      check((flags and 0x4) == 0, "h2 non-final header fragments omit END_HEADERS")
    offset += 9 + frameLen
    inc frameCount

  check(frameCount > 1, "h2 large request headers are split")
  echo "HTTP/2 HEADERS fragmentation: OK"

proc testH2HeaderTableSizeUpdate() =
  var conn = initH2ClientConnection()
  var settings = ""
  serializeFrameHeader(settings, 6, ftSettings, 0, 0)
  settings.add char(0)
  settings.add char(1)
  settings.add "\0\0\0\0"

  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](settings), responseBuf)
  check(conn.remoteSettings.headerTableSize == 0'u32, "h2 applies peer header table size setting")

  var buf = ""
  conn.sendHeaders(
    1'u32,
    @[(":method", "GET"), (":path", "/"), (":scheme", "https"), (":authority", "example.test")],
    endStream = true,
    buf
  )
  check(buf.len > 9, "h2 headers frame has payload")
  check((ord(buf[9]) and 0xE0) == 0x20, "h2 next header block starts with HPACK table size update")
  echo "HTTP/2 HPACK table-size update: OK"

proc testH2UnknownFrameDuringContinuation() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()

  var headerBlock = ""
  var enc = initHpackEncoder(huffman = false)
  hpackEncode(enc, @[(":status", "200")], headerBlock)

  var batch = ""
  serializeHeaders(sid, headerBlock, endStream = false, endHeaders = false, batch)
  addRawH2FrameHeader(batch, 0'u32, 0xAu8, 0'u8, sid)

  var responseBuf = ""
  discard conn.feedData(cast[seq[byte]](batch), responseBuf)
  check(conn.state == h2csGoaway, "h2 unknown extension frame during header block closes connection")
  check(conn.localConnectionError, "h2 unknown extension frame marks local connection error")
  check(responseBuf.len > 0, "h2 unknown extension frame emits GOAWAY")
  echo "HTTP/2 continuation extension-frame ordering: OK"

proc testH2ErroredDataConsumesWindow() =
  var conn = initH2ClientConnection()
  conn.state = h2csActive
  let sid = conn.allocateStream()
  let beforeLocal = conn.localWindow
  let beforeStream = conn.streams[sid].recvWindow

  var dataFrame = ""
  serializeData(sid, "abcde", endStream = false, dataFrame)

  var responseBuf = ""
  let completed = conn.feedData(cast[seq[byte]](dataFrame), responseBuf)
  check(conn.state == h2csActive, "h2 DATA before response headers stays stream-scoped")
  check(completed.len == 1, "h2 errored DATA completes the failed stream")
  check(conn.streams[sid].state == ssClosed, "h2 DATA before response headers closes stream")
  check(conn.localWindow == beforeLocal - 5, "h2 errored DATA debits connection window")
  check(conn.streams[sid].recvWindow == beforeStream - 5, "h2 errored DATA debits stream window")
  check(responseBuf.len > 0, "h2 errored DATA emits RST_STREAM")
  echo "HTTP/2 errored DATA flow-control accounting: OK"

proc testWebSocketFrame() =
  let frame = encodeWsFrame(woText, "Hello, WebSocket!", masked = true)
  check(frame.len > 0, "ws encode non-empty")

  var pos = 0
  let decoded = decodeWsFrame(cast[seq[byte]](frame), pos)
  check(decoded.isSome, "ws decode success")
  let f = decoded.get
  check(f.fin, "ws frame fin")
  check(f.opcode == woText, "ws frame text opcode")
  check(f.payload == "Hello, WebSocket!", "ws frame payload")
  echo "WebSocket frame: OK"

proc testWebSocketClose() =
  let frame = encodeCloseFrame(1000, "normal", masked = true)
  var pos = 0
  let decoded = decodeWsFrame(cast[seq[byte]](frame), pos)
  check(decoded.isSome, "ws close decode")
  let f = decoded.get
  check(f.opcode == woClose, "ws close opcode")
  let code = (uint16(f.payload[0]) shl 8) or uint16(f.payload[1])
  check(code == 1000, "ws close code 1000")
  echo "WebSocket close: OK"

proc testWebSocketUpgrade() =
  let key = generateWebSocketKey()
  check(key.len > 0, "ws key generated")
  let req = buildUpgradeRequest("example.com", "/ws", 80, key)
  check("Upgrade: websocket" in req, "ws upgrade header")
  check("Sec-WebSocket-Key: " & key in req, "ws key in request")
  let secureOn80 = buildUpgradeRequest("example.com", "/ws", 80, key, useSsl = true)
  check("Host: example.com:80\r\n" in secureOn80, "wss host includes explicit non-default port 80")
  echo "WebSocket upgrade: OK"

proc testSseParsing() =
  var parser = initSseParser()
  let data = "event: message\ndata: hello\ndata: world\nid: 1\n\n"
  let events = parser.feedData(data)
  check(events.len == 1, "sse one event")
  check(events[0].eventType == "message", "sse event type")
  check(events[0].data == "hello\nworld", "sse data multiline")
  check(events[0].id == "1", "sse event id")
  check(parser.lastEventId == "1", "sse last event id")
  echo "SSE parsing: OK"

proc testSseRetry() =
  var parser = initSseParser()
  let data = "retry: 5000\ndata: test\n\n"
  let events = parser.feedData(data)
  check(events.len == 1, "sse retry event")
  check(parser.retryMs == 5000, "sse retry value")
  echo "SSE retry: OK"

proc testSseIdOnlyUpdatesResume() =
  var parser = initSseParser()
  let events = parser.feedData("id: 42\n\n")
  check(events.len == 0, "sse id-only field does not dispatch event")
  check(parser.lastEventId == "42", "sse id-only field updates resume id")
  echo "SSE id-only resume: OK"

proc testSseAuthorityPorts() =
  let httpDefault = buildSseRequest("example.com", "/events", 80)
  check("Host: example.com\r\n" in httpDefault, "sse omits default http port")
  let httpOn443 = buildSseRequest("example.com", "/events", 443)
  check("Host: example.com:443\r\n" in httpOn443, "sse includes explicit non-default http port 443")
  let httpsDefault = buildSseRequest("example.com", "/events", 443, useSsl = true)
  check("Host: example.com\r\n" in httpsDefault, "sse omits default https port")
  let httpsOn80 = buildSseRequest("example.com", "/events", 80, useSsl = true)
  check("Host: example.com:80\r\n" in httpsOn80, "sse includes explicit non-default https port 80")
  echo "SSE authority ports: OK"

proc testSseBareCrLines() =
  var parser = initSseParser()
  let events = parser.feedData("event: message\rdata: hello\rid: 9\r\r")
  check(events.len == 1, "sse bare CR event")
  if events.len == 1:
    check(events[0].eventType == "message", "sse bare CR event type")
    check(events[0].data == "hello", "sse bare CR data")
    check(parser.lastEventId == "9", "sse bare CR id")
  echo "SSE bare CR parsing: OK"

proc testSseOversizedEventDiscard() =
  var parser = initSseParser()
  let events = parser.feedData("data: " & repeat('x', SseMaxEventSize + 1) & "\n\n")
  check(events.len == 0, "oversized sse event is not dispatched")
  check(parser.currentEvent.data.len == 0, "oversized sse event data is cleared")
  check(not parser.discardingEvent, "oversized sse event discard state resets at boundary")
  echo "SSE oversized event discard: OK"

proc testWebSocketSubprotocolSelection() =
  check(wsSubprotocolAllowed("", ["chat"]), "ws empty selected subprotocol allowed")
  check(wsSubprotocolAllowed("chat", ["chat", "superchat"]), "ws requested subprotocol allowed")
  check(not wsSubprotocolAllowed("admin", ["chat", "superchat"]), "ws unrequested subprotocol rejected")
  echo "WebSocket subprotocol validation: OK"

proc testH2StateValidation() =
  var prefaceConn = initH2ClientConnection()
  let prefaceSid = prefaceConn.allocateStream()
  var prefaceHeaders = ""
  var prefaceEnc = initHpackEncoder(huffman = false)
  hpackEncode(prefaceEnc, @[(":status", "200")], prefaceHeaders)
  var prefaceFrame = ""
  serializeHeaders(prefaceSid, prefaceHeaders, endStream = true, endHeaders = true, prefaceFrame)
  var prefaceResp = ""
  discard prefaceConn.feedData(cast[seq[byte]](prefaceFrame), prefaceResp)
  check(prefaceConn.state == h2csGoaway, "h2 rejects HEADERS before server SETTINGS")
  check(prefaceResp.len > 0, "h2 preface violation emits GOAWAY")

  var settingsConn = initH2ClientConnection()
  var settingsFrame = ""
  serializeSettings(DefaultH2Settings, settingsFrame)
  var settingsResp = ""
  discard settingsConn.feedData(cast[seq[byte]](settingsFrame), settingsResp)
  check(settingsConn.state == h2csActive, "h2 server SETTINGS activates connection")
  check(settingsResp.len > 0, "h2 server SETTINGS is acknowledged")

  var conn = initH2ClientConnection()
  conn.state = h2csActive
  var responseBuf = ""
  var dataFrame = ""
  serializeData(1'u32, "hello", endStream = true, dataFrame)
  discard conn.feedData(cast[seq[byte]](dataFrame), responseBuf)
  check(conn.state == h2csGoaway, "h2 DATA on idle stream triggers connection error")
  check(responseBuf.len > 0, "h2 idle DATA emits GOAWAY")

  var conn2 = initH2ClientConnection()
  conn2.state = h2csActive
  let sid = conn2.allocateStream()
  var trailerBlock = ""
  var enc = initHpackEncoder(huffman = false)
  hpackEncode(enc, @[("x-trailer", "value")], trailerBlock)
  conn2.streams[sid].responseStatus = 200
  var trailerFrame = ""
  serializeHeaders(sid, trailerBlock, endStream = false, endHeaders = true, trailerFrame)
  responseBuf = ""
  discard conn2.feedData(cast[seq[byte]](trailerFrame), responseBuf)
  check(conn2.state == h2csGoaway, "h2 trailing headers without END_STREAM rejected")
  check(responseBuf.len > 0, "h2 invalid trailers emit GOAWAY")

  var conn3 = initH2ClientConnection()
  conn3.state = h2csActive
  let closedSid = conn3.allocateStream()
  var responseHeaders = ""
  var enc2 = initHpackEncoder(huffman = false)
  hpackEncode(enc2, @[(":status", "200")], responseHeaders)
  var closedBatch = ""
  serializeHeaders(closedSid, responseHeaders, endStream = true, endHeaders = true, closedBatch)
  serializeData(closedSid, "late", endStream = true, closedBatch)
  responseBuf = ""
  let completed = conn3.feedData(cast[seq[byte]](closedBatch), responseBuf)
  check(completed.len == 1, "h2 completed closed stream once in a read batch")
  check(completed[0][1].responseBody.len == 0, "h2 DATA after closed HEADERS is ignored")
  check(responseBuf.len > 0, "h2 DATA on closed stream emits RST_STREAM")

  var conn4 = initH2ClientConnection()
  conn4.state = h2csActive
  let windowSid = conn4.allocateStream()
  conn4.streams[windowSid].sendWindow = 10
  var shrinkSettings = DefaultH2Settings
  shrinkSettings.initialWindowSize = 0
  var shrinkFrame = ""
  serializeSettings(shrinkSettings, shrinkFrame)
  responseBuf = ""
  discard conn4.feedData(cast[seq[byte]](shrinkFrame), responseBuf)
  check(conn4.state == h2csActive, "h2 SETTINGS_INITIAL_WINDOW_SIZE shrink can make stream window negative")
  check(conn4.streams[windowSid].sendWindow < 0, "h2 stream send window allows legal negative value")
  echo "HTTP/2 state validation: OK"

proc testConnectionPool() =
  var pool = initConnectionPool(maxPerHost = 2)
  check(pool.totalConnections == 0, "pool starts empty")
  let key = poolKey("example.com", 443, true)
  check("s:example.com:443" == key, "pool key format")
  echo "Connection pool: OK"

proc testClientApi() =
  var client = newHttpClient()
  check(client.defaultTimeoutMs == 30000, "client default timeout")
  check(client.connectTimeoutMs == 5000, "client default connect timeout")
  check(client.defaultFollowRedirects, "client default redirects")
  check(client.defaultMaxRedirects == 10, "client default max redirects")
  check(not client.initialized, "client not initialized before first request")
  check(client.pendingRequests == 0, "client starts with no pending requests")
  let onEvent = proc(event: SseEvent) {.gcsafe.} =
    discard event
  let onOpen = proc() {.gcsafe.} =
    discard
  var sseErrors = 0
  var sseErrorMessage = ""
  let onError = proc(err: string) {.gcsafe.} =
    inc sseErrors
    sseErrorMessage = err
  client.sse("not-a-valid-url", "", onEvent, onOpen, onError)
  check(client.pendingRequests == 0, "sse overload with lifecycle callbacks does not enqueue invalid URL")
  check(sseErrors == 1, "sse invalid URL invokes onError")
  check(sseErrorMessage.len > 0, "sse invalid URL reports error reason")

  var movedGuard = newHttpClient()
  movedGuard.initialized = true
  movedGuard.ownerAddress = cast[pointer](1)
  var rejectedMovedClient = false
  try:
    close(movedGuard)
  except ValueError:
    rejectedMovedClient = true
  movedGuard.initialized = false
  check(rejectedMovedClient, "initialized HttpClient rejects operations from non-owner address")
  echo "Client API: OK"

proc testClientTlsOptionsApi() =
  let tlsOpts = UsSocketContextOptions(
    certFileName: cstring("client.pem"),
    keyFileName: cstring("client-key.pem"),
    caFileName: cstring("ca-bundle.crt"),
    sslCiphers: cstring("TLS_AES_128_GCM_SHA256"),
    sslPreferLowMemoryUsage: 1
  )
  var client = newHttpClient(tlsOptions = tlsOpts)
  check($client.tlsOptions.certFileName == "client.pem", "newHttpClient stores TLS cert option")
  check($client.tlsOptions.keyFileName == "client-key.pem", "newHttpClient stores TLS key option")
  check($client.tlsOptions.caFileName == "ca-bundle.crt", "newHttpClient stores TLS CA option")
  check($client.tlsOptions.sslCiphers == "TLS_AES_128_GCM_SHA256", "newHttpClient stores TLS cipher option")
  check(client.tlsOptions.sslPreferLowMemoryUsage == 1, "newHttpClient stores TLS memory option")

  var cfg = defaultHttpClientConfig()
  cfg.tlsOptions = tlsOpts
  let configured = newHttpClientFromConfig(cfg)
  check($configured.tlsOptions.caFileName == "ca-bundle.crt", "newHttpClientFromConfig stores TLS option")
  echo "Client TLS options API: OK"

proc testRedirectHeaderSanitization() =
  let headers = @[
    HttpHeader(name: "Authorization", value: "Bearer secret"),
    HttpHeader(name: "Cookie", value: "sid=secret"),
    HttpHeader(name: "Proxy-Authorization", value: "Basic secret"),
    HttpHeader(name: "X-Request-ID", value: "abc"),
  ]
  let sanitized = stripSensitiveRedirectHeaders(headers)
  check(sanitized.len == 1, "cross-origin redirect strips credential headers")
  check(sanitized[0].name == "X-Request-ID", "cross-origin redirect keeps non-sensitive headers")
  check(isSensitiveRedirectHeader("authorization"), "authorization is sensitive")
  check(isSensitiveRedirectHeader("COOKIE"), "cookie is sensitive case-insensitively")
  echo "Redirect header sanitization: OK"

proc testRedirectMethodAndBody() =
  let head302 = redirectMethodAndBody(302, hmHead, "ignored")
  check(head302.`method` == hmHead, "redirect preserves HEAD on 302")
  check(head302.body.len == 0, "redirect drops HEAD body")
  let head303 = redirectMethodAndBody(303, hmHead, "ignored")
  check(head303.`method` == hmHead, "redirect preserves HEAD on 303")
  let post301 = redirectMethodAndBody(301, hmPost, "payload")
  check(post301.`method` == hmGet, "redirect rewrites POST to GET on 301")
  check(post301.body.len == 0, "redirect drops rewritten POST body")
  let post303 = redirectMethodAndBody(303, hmPost, "payload")
  check(post303.`method` == hmGet, "redirect rewrites POST to GET on 303")
  check(post303.body.len == 0, "redirect drops 303 POST body")
  let put302 = redirectMethodAndBody(302, hmPut, "payload")
  check(put302.`method` == hmPut, "redirect preserves PUT on 302")
  check(put302.body == "payload", "redirect preserves PUT body on 302")
  let patch307 = redirectMethodAndBody(307, hmPatch, "patch")
  check(patch307.`method` == hmPatch, "redirect preserves PATCH on 307")
  check(patch307.body == "patch", "redirect preserves PATCH body on 307")
  let delete308 = redirectMethodAndBody(308, hmDelete, "delete")
  check(delete308.`method` == hmDelete, "redirect preserves DELETE on 308")
  check(delete308.body == "delete", "redirect preserves DELETE body on 308")
  echo "Redirect method/body: OK"

when defined(nimFastHttpClientTest):
  proc testQueuedWriteBackpressureGuard() =
    var conn = PooledConnection(
      state: csConnecting,
      sendBuf: newString(16 * 1024 * 1024 - 2),
      sendBufPos: 0,
    )
    check(clientCanQueueSocketWriteForTest(addr conn, 2), "queued write fits exactly at send buffer limit")
    check(not clientCanQueueSocketWriteForTest(addr conn, 3), "queued write rejects bytes over send buffer limit")
    check(not clientCanQueueSocketWriteForTest(addr conn, 16 * 1024 * 1024 + 1), "single huge queued write rejected")
    echo "Queued write backpressure guard: OK"

  proc testH2TimeoutIsolation() =
    let state = clientH2TimeoutIsolationForTest()
    check(state.pendingRequests == 1, "only expired H2 stream decrements pending request count")
    check(state.remainingStreams == 1, "non-expired H2 stream remains active")
    check(state.connState == csOpen, "H2 connection remains open after stream timeout")
    check(clientH1PipelinedTailTimeoutForTest(), "H1 timeout scan checks pipelined tail requests")
    echo "HTTP/2 timeout isolation: OK"

  proc testH2ConnectionErrorCallbackOrdering() =
    let state = clientH2ConnectionErrorCallbackOrderingForTest()
    check(state.localConnectionError, "h2 malformed connection frame marks local connection error")
    check(state.completedCalls == 1, "h2 completed stream callback fires once")
    check(state.completedStatus == 200, "h2 completed stream receives response status")
    check(state.completedErrLen == 0, "h2 completed stream does not receive connection error")
    check(state.completedVersion == ord(Http20), "h2 completed stream response version")
    check(state.failedCalls == 1, "h2 connection error fails only remaining stream")
    check(state.failedStatus == 0, "h2 remaining stream receives error response")
    check(state.failedErrLen > 0, "h2 remaining stream receives connection error")
    check(state.completedOrder == 1, "h2 completed callback delivered before connection error callbacks")
    check(state.failedOrder == 2, "h2 remaining stream failed after completed callback")
    check(state.pendingRequests == 0, "h2 connection error drains pending request count")
    check(state.remainingStreams == 0, "h2 connection error leaves no active H2 streams")
    check(state.connStreams == 0, "h2 connection error clears pooled H2 stream mirror")
    check(state.connState == csClosing, "h2 connection error closes pooled connection")
    check(state.completedCbConnState == csClosing, "h2 completed callback sees retired connection after protocol error")
    check(state.completedCbPoolCount == 0, "h2 completed callback cannot reacquire protocol-error connection")
    echo "HTTP/2 connection-error callback ordering: OK"

  proc testH2CallbackCloseStopsQueueDrain() =
    let state = clientH2CallbackCloseStopsQueueDrainForTest()
    check(state.calls == 1, "h2 completed callback fired once")
    check(not state.initialized, "h2 callback closed client")
    check(state.queuedStreams == 1, "h2 callback close stops queued stream drain")
    check(state.activeStreams == 0, "h2 completed stream was removed before callback")
    check(state.sendBufLen == 0, "h2 callback close avoids writing queued request bytes")
    echo "HTTP/2 callback close stops queue drain: OK"

  proc testH1ParseErrorRetiresBeforeCallback() =
    let state = clientH1ParseErrorRetiresBeforeCallbackForTest()
    check(state.parserState == psError, "h1 TE+CL response enters parse-error state")
    check(state.connState == csClosing, "h1 parse error marks connection closing")
    check(state.poolCount == 0, "h1 parse error removes connection from pool")
    check(state.pendingRequests == 0, "h1 parse error decrements pending request")
    check(state.cbCalls == 1, "h1 parse error callback fires once")
    check(state.cbState == csClosing, "h1 parse-error callback sees closing connection")
    check(state.cbPoolCount == 0, "h1 parse-error callback cannot reacquire failed connection")
    check(state.cbErrLen > 0, "h1 parse-error callback receives error")
    echo "HTTP/1.1 parse-error pool retirement: OK"

  proc testH1CallbackCloseStopsPostCallbackAccess() =
    let state = clientH1CallbackCloseStopsPostCallbackAccessForTest()
    check(state.calls == 1, "h1 callback fired once")
    check(not state.initialized, "h1 callback closed client")
    check(state.stopped, "h1 callback close stops post-callback processing")
    check(state.pendingRequests == 0, "h1 callback close decrements pending request")
    check(state.poolCount == 1, "h1 success path released connection before callback")
    echo "HTTP/1.1 callback close guard: OK"

  proc testAlpnH2RejectsWssAndSse() =
    let state = clientAlpnH2RejectsIncompatibleForTest()
    check(state.wsConnState == csClosing, "wss h2 ALPN marks connection closing")
    check(state.wsPoolCount == 0, "wss h2 ALPN removes connection from pool")
    check(state.wsErrorCount == 1, "wss h2 ALPN notifies error")
    check(state.wsManualClose, "wss h2 ALPN does not silently reconnect")
    check(state.sseConnState == csClosing, "sse h2 ALPN marks connection closing")
    check(state.ssePoolCount == 0, "sse h2 ALPN removes connection from pool")
    check(state.sseErrorCount == 1, "sse h2 ALPN notifies error")
    check(state.sseDoneCount == 1, "sse h2 ALPN drains pending callback")
    check(state.ssePendingRequests == 0, "sse h2 ALPN decrements pending request")
    echo "ALPN h2 WSS/SSE rejection: OK"

  proc testTlsContextFailureIsClean() =
    var opts = defaultSocketContextOptions()
    opts.caFileName = cstring("/tmp/nim_fasthttpclient_missing_ca_for_test.pem")
    var client = newHttpClient(tlsOptions = opts)
    initClient(client, ssl = true)
    if client.initialized:
      check(client.ctx != nil, "successful TLS initialization has a context")
      close(client)
    else:
      check(client.ctx == nil, "TLS context creation failure leaves nil context")
      check(client.loop == nil, "TLS context creation failure frees owned loop")
    echo "TLS context failure handling: OK"

  proc testRetryDelayTimer() =
    let state = clientRetryDelaySchedulesForTest(30)
    check(state.scheduled, "retry delay schedules a one-shot timer")
    check(state.timersBeforeClose == 1, "retry delay timer is tracked by client")
    check(state.timersAfterClose == 0, "retry delay timer is cancelled on client close")
    echo "Retry delay timer: OK"

  proc testWsReconnectTimerClose() =
    let state = clientWsReconnectTimerCancelledForTest()
    check(state.scheduled, "websocket reconnect schedules a one-shot timer")
    check(state.activeBeforeClose == 1, "websocket reconnect is tracked by the client")
    check(state.activeAfterClose == 0, "client close clears websocket tracking")
    check(not state.timerAfterClose, "client close cancels websocket reconnect timer")
    check(state.manualClose, "client close marks websocket as manual close")
    echo "WebSocket reconnect timer close: OK"

  proc testWsFailedOpenUntracks() =
    let state = clientWsFailedOpenUntracksForTest()
    check(state.wsState == csClosed, "failed websocket open is closed")
    check(state.activeWs == 0, "failed websocket open is not pinned in active list")
    check(not state.initialized, "failed websocket open before connect does not initialize the loop")
    echo "WebSocket failed open tracking: OK"

  proc testWsPongTimeoutReconnectableClose() =
    let ws = newWsConnection()
    initWsClientDefaults(ws)
    configureReconnect(ws, autoReconnect = true, maxReconnectAttempts = 3)
    ws.closeNotified = true
    ws.closeCode = 1011'u16
    check(isReconnectableWsCloseCode(1011'u16), "1011 is reconnectable after heartbeat timeout")
    check(shouldScheduleWsReconnect(ws, requireLoop = false), "pong timeout close code permits reconnect")
    ws.closeCode = 1002'u16
    check(not shouldScheduleWsReconnect(ws, requireLoop = false), "protocol close still does not reconnect")
    echo "WebSocket pong timeout reconnectability: OK"

  proc testWsCloseStopsBufferedDelivery() =
    let state = clientWsCloseStopsBufferedDeliveryForTest()
    check(state.delivered == 1, "websocket onMessage close stops buffered data delivery")
    check(state.state == csClosing, "websocket close from onMessage enters closing state")
    check(state.remaining == 0, "websocket buffered frames are discarded after callback close")
    echo "WebSocket callback close stops buffered delivery: OK"

  proc testSseStreamingIncremental() =
    let state = clientSseStreamingIncrementalForTest()
    check(not state.doneAfterFirst, "sse unknown-length response stays open after first event")
    check(state.openedAfterFirst, "sse stream opens after event-stream headers")
    check(state.eventCountAfterFirst == 1, "sse first event delivered before connection close")
    check(state.bodyAfterFirst == 0, "sse streamed response body buffer is drained")
    check(state.eventCountAfterSecond == 2, "sse second event delivered incrementally")
    check(state.firstData == "one", "sse first data")
    check(state.secondData == "two", "sse second data")
    check(state.lastEventId == "1", "sse last-event-id preserved across events")
    check(state.retryMs == 25, "sse retry field preserved")
    check(state.parserBufLen == 0, "sse parser buffer drained after complete events")
    check(state.responseBodyLen == 0, "sse response body remains drained")
    echo "SSE streaming incremental: OK"

  proc testSseDisconnectErrorCallback() =
    let state = clientSseDisconnectNotifiesForTest()
    check(state.directCount == 1, "sse active disconnect notifies error callback")
    check(state.pendingCount == 2, "sse pending disconnect notifies error callback")
    check(state.lastError == "SSE connection closed", "sse disconnect error message")
    echo "SSE disconnect error callback: OK"

  proc testSseCallbackCloseStopsMetadataWrite() =
    let state = clientSseCallbackCloseStopsMetadataWriteForTest()
    check(state.eventCount == 1, "sse event callback fired once")
    check(not state.initialized, "sse event callback closed client")
    check(not state.openedStored, "sse callback close stops metadata write-back")
    check(state.lastEventId.len == 0, "sse callback close does not persist parser metadata")
    check(state.parserBufLen == 0, "sse callback close leaves parser buffer unchanged")
    echo "SSE callback close stops metadata write-back: OK"


  proc testH2GoawayRetiresPoolConnection() =
    let state = clientH2GoawayRetiresPoolConnectionForTest()
    check(state.h2State == h2csGoaway, "h2 GOAWAY updates connection state")
    check(state.connState == csClosed, "h2 GOAWAY closes idle socket without live handle")
    check(state.poolCount == 0, "h2 GOAWAY removes connection from reusable pool")
    check(state.pendingRequests == 0, "h2 GOAWAY does not underflow pending requests")
    echo "HTTP/2 GOAWAY pool retirement: OK"

testHttp1Serialization()
testHttp1Parsing()
testHttp1Chunked()
testHttp1PartialBodyConsumption()
testHttp1InformationalResponseSkip()
testHttp1NoBodyFramingCloses()
testHttp1TransferEncodingContentLengthRejected()
testHpackReexport()
testH2FramesReexport()
testH2Connection()
testH2HeadersFragmentation()
testH2HeaderTableSizeUpdate()
testH2UnknownFrameDuringContinuation()
testH2ErroredDataConsumesWindow()
testWebSocketFrame()
testWebSocketClose()
testWebSocketUpgrade()
testSseParsing()
testSseRetry()
testSseIdOnlyUpdatesResume()
testSseAuthorityPorts()
testSseBareCrLines()
testSseOversizedEventDiscard()
testWebSocketSubprotocolSelection()
testH2StateValidation()
testConnectionPool()
testClientApi()
testClientTlsOptionsApi()
testRedirectHeaderSanitization()
testRedirectMethodAndBody()
when defined(nimFastHttpClientTest):
  testQueuedWriteBackpressureGuard()
  testH2TimeoutIsolation()
  let timeoutDrainState = clientH2TimeoutDrainsQueueForTest()
  check(timeoutDrainState.pendingRequests == 1, "H2 timeout drain keeps queued request pending")
  check(timeoutDrainState.remainingStreams == 1, "H2 timeout drain starts queued stream")
  check(timeoutDrainState.queuedStreams == 0, "H2 timeout drain removes started queued request")
  check(timeoutDrainState.sendBufLen > 0, "H2 timeout drain queues request bytes without a live test socket")
  check(timeoutDrainState.connState == csOpen, "H2 timeout drain keeps connection open")
  testH2ConnectionErrorCallbackOrdering()
  testH2CallbackCloseStopsQueueDrain()
  testH1ParseErrorRetiresBeforeCallback()
  testH1CallbackCloseStopsPostCallbackAccess()
  testAlpnH2RejectsWssAndSse()
  testTlsContextFailureIsClean()
  testRetryDelayTimer()
  testWsReconnectTimerClose()
  testWsFailedOpenUntracks()
  testWsPongTimeoutReconnectableClose()
  testWsCloseStopsBufferedDelivery()
  testSseStreamingIncremental()
  testSseDisconnectErrorCallback()
  testSseCallbackCloseStopsMetadataWrite()
  testH2GoawayRetiresPoolConnection()

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
