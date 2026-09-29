import std/unittest

include ../src/nim_usockets/http

proc toBytes(payload: string): seq[byte] =
  result = newSeq[byte](payload.len)
  for i in 0..<payload.len:
    result[i] = byte(payload[i])

proc parseReq(payload: string, minimalHeaders = false): Option[HttpRequest] =
  let data = payload.toBytes()
  var totalRequestSize = 0
  var parseError = false
  var parseStatusCode = 400
  parseHttpRequest(
    data, 0, totalRequestSize, minimalHeaders,
    0, "", parseError, parseStatusCode
  )

proc makeWsUpgradeRequest(
  host = "example.test",
  upgrade = "websocket",
  connection = "Upgrade",
  wsKey = "dGhlIHNhbXBsZSBub25jZQ==",
  wsVersion = "13",
  includeHost = true,
  httpVersion = "HTTP/1.1",
  methodStr = "GET"
): string =
  result = methodStr & " /ws " & httpVersion & "\r\n"
  if includeHost and host.len > 0:
    result.add("Host: " & host & "\r\n")
  if upgrade.len > 0:
    result.add("Upgrade: " & upgrade & "\r\n")
  if connection.len > 0:
    result.add("Connection: " & connection & "\r\n")
  if wsKey.len > 0:
    result.add("Sec-WebSocket-Key: " & wsKey & "\r\n")
  if wsVersion.len > 0:
    result.add("Sec-WebSocket-Version: " & wsVersion & "\r\n")
  result.add("\r\n")

proc validateUpgrade(
  raw: string,
  minimalHeaders = false
): tuple[ok: bool, statusCode: int, reason: string, extraHeaders: string] =
  let reqOpt = parseReq(raw, minimalHeaders)
  if reqOpt.isNone:
    return (false, 400, "Parse Error", "")
  validateWebSocketUpgrade(reqOpt.get())

suite "Fix 1: RFC 7692 §7.1 — Server adds no_context_takeover without client offer":
  test "bare permessage-deflate negotiates when server requires no_context_takeover":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true
    options.wsCompressionServerNoContextTakeover = true
    options.wsCompressionClientNoContextTakeover = true

    let negotiated = negotiateWsCompressionHeader("permessage-deflate", options)
    check negotiated.len > 0
    check negotiated.contains("permessage-deflate")
    check negotiated.contains("server_no_context_takeover")
    check negotiated.contains("client_no_context_takeover")

  test "client offer with only server_no_context_takeover negotiates successfully":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true

    let negotiated = negotiateWsCompressionHeader(
      "permessage-deflate; server_no_context_takeover",
      options
    )
    check negotiated.len > 0
    check negotiated.contains("server_no_context_takeover")
    check negotiated.contains("client_no_context_takeover")

  test "client offer with only client_no_context_takeover negotiates successfully":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true

    let negotiated = negotiateWsCompressionHeader(
      "permessage-deflate; client_no_context_takeover",
      options
    )
    check negotiated.len > 0
    check negotiated.contains("server_no_context_takeover")
    check negotiated.contains("client_no_context_takeover")

  test "client offer with both context takeover params negotiates successfully":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true

    let negotiated = negotiateWsCompressionHeader(
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
      options
    )
    check negotiated.len > 0
    check negotiated.contains("server_no_context_takeover")
    check negotiated.contains("client_no_context_takeover")

  test "empty extensions header rejects negotiation":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true
    check negotiateWsCompressionHeader("", options).len == 0

  test "non-deflate extension rejects negotiation":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true
    check negotiateWsCompressionHeader("x-webkit-deflate-frame", options).len == 0

  test "compression disabled rejects negotiation regardless of offer":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = false
    check negotiateWsCompressionHeader(
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
      options
    ).len == 0

  test "server with context takeover opt-out disables negotiation":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true
    options.wsCompressionClientNoContextTakeover = false
    options.wsCompressionServerNoContextTakeover = true

    check negotiateWsCompressionHeader(
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
      options
    ).len == 0

suite "Fix 2: RFC 6455 §4.2.1 — Defense-in-depth validateWebSocketUpgrade":
  test "valid upgrade request passes validation":
    let raw = makeWsUpgradeRequest()
    for minimal in [false, true]:
      let v = validateUpgrade(raw, minimal)
      check v.ok
      check v.statusCode == 101

  test "nil request returns 400":
    let v = validateWebSocketUpgrade(nil)
    check not v.ok
    check v.statusCode == 400

  test "POST method is rejected":
    let raw = makeWsUpgradeRequest(methodStr = "POST")
    let v = validateUpgrade(raw)
    check not v.ok
    check v.statusCode == 400

  test "HTTP/1.0 is rejected":
    let raw = makeWsUpgradeRequest(httpVersion = "HTTP/1.0")
    let v = validateUpgrade(raw)
    check not v.ok
    check v.statusCode == 400

  test "missing Upgrade header is rejected":
    let raw = makeWsUpgradeRequest(upgrade = "")
    let v = validateUpgrade(raw)
    check not v.ok
    check v.statusCode == 400

  test "wrong Upgrade value is rejected":
    let raw = makeWsUpgradeRequest(upgrade = "h2c")
    let v = validateUpgrade(raw)
    check not v.ok
    check v.statusCode == 400

  test "missing Connection Upgrade token is rejected":
    let raw = makeWsUpgradeRequest(connection = "keep-alive")
    let v = validateUpgrade(raw)
    check not v.ok
    check v.statusCode == 400

  test "wrong WebSocket version returns 426 with version header":
    let raw = makeWsUpgradeRequest(wsVersion = "8")
    let v = validateUpgrade(raw)
    check not v.ok
    check v.statusCode == 426
    check v.extraHeaders.contains("Sec-WebSocket-Version: 13")

  test "missing Sec-WebSocket-Key is rejected":
    let raw = makeWsUpgradeRequest(wsKey = "")
    let v = validateUpgrade(raw)
    check not v.ok
    check v.statusCode == 400

  test "invalid base64 Sec-WebSocket-Key is rejected":
    let raw = makeWsUpgradeRequest(wsKey = "not-valid-base64!!!")
    let v = validateUpgrade(raw)
    check not v.ok
    check v.statusCode == 400

suite "Fix 3: RFC 6455 §7.4.1 — Invalid close code fallback to 1000":
  test "standard close codes are valid":
    for code in [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014]:
      check isValidWsCloseCode(code)

  test "private-use close codes 3000-4999 are valid":
    check isValidWsCloseCode(3000)
    check isValidWsCloseCode(3999)
    check isValidWsCloseCode(4000)
    check isValidWsCloseCode(4999)

  test "reserved close codes 1004-1006 are invalid":
    check not isValidWsCloseCode(1004)
    check not isValidWsCloseCode(1005)
    check not isValidWsCloseCode(1006)

  test "codes below 1000 are invalid":
    check not isValidWsCloseCode(0)
    check not isValidWsCloseCode(999)
    check not isValidWsCloseCode(500)

  test "unassigned codes 1015-2999 are invalid":
    check not isValidWsCloseCode(1015)
    check not isValidWsCloseCode(1016)
    check not isValidWsCloseCode(2000)
    check not isValidWsCloseCode(2999)

  test "codes above 4999 are invalid":
    check not isValidWsCloseCode(5000)
    check not isValidWsCloseCode(65535)

  test "wsClosePayload uses code directly for valid code":
    let payload = wsClosePayload(1000)
    check payload.len >= 2
    check (ord(payload[0]) shl 8 or ord(payload[1])) == 1000

  test "wsClosePayload encodes reason string":
    let payload = wsClosePayload(1001, "going away")
    check payload.len >= 2
    let code = ord(payload[0]) shl 8 or ord(payload[1])
    check code == 1001
    check payload[2..^1] == "going away"

suite "Fix 4: RFC 6455 §4.2.1 — Validate Host header presence in WebSocket upgrade":
  test "missing Host header rejects WebSocket upgrade":
    let raw = makeWsUpgradeRequest(includeHost = false)
    let v = validateUpgrade(raw)
    check not v.ok
    check v.statusCode == 400

  test "present Host header allows WebSocket upgrade":
    let raw = makeWsUpgradeRequest(host = "example.test")
    let v = validateUpgrade(raw)
    check v.ok
    check v.statusCode == 101

  test "Host header with different values allows WebSocket upgrade":
    for host in ["localhost", "example.com:8080", "192.168.1.1"]:
      let raw = makeWsUpgradeRequest(host = host)
      let v = validateUpgrade(raw)
      check v.ok
      check v.statusCode == 101
