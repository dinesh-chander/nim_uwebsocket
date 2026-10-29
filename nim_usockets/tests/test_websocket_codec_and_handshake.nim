import std/[unittest, options, strutils]

import ../src/nim_usockets/[websocket, fast_hash]

proc toHeaders(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    discard result.put(k, v)

suite "WebSocket codec and handshake helpers":
  test "accept key generation matches RFC sample":
    let acceptKey = generateAcceptKey("dGhlIHNhbXBsZSBub25jZQ==")
    check acceptKey == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

  test "upgrade detection validates required tokens":
    let okHeaders = toHeaders([
      ("upgrade", "websocket"),
      ("connection", "keep-alive, Upgrade")
    ])
    check isWebSocketUpgrade(okHeaders)

    let badUpgrade = toHeaders([
      ("upgrade", "h2c"),
      ("connection", "upgrade")
    ])
    check not isWebSocketUpgrade(badUpgrade)

    let badConnection = toHeaders([
      ("upgrade", "websocket"),
      ("connection", "keep-alive")
    ])
    check not isWebSocketUpgrade(badConnection)

  test "handshake helpers surface key and response framing":
    let headers = toHeaders([("sec-websocket-key", "abc123==")])
    check getWebSocketKey(headers) == "abc123=="

    let response = createHandshakeResponse("accept-token")
    check response.startsWith("HTTP/1.1 101 Switching Protocols")
    check "Upgrade: websocket\r\n" in response
    check "Connection: Upgrade\r\n" in response
    check "Sec-WebSocket-Accept: accept-token\r\n" in response
    check response.endsWith("\r\n\r\n")

  test "encode/decode frame roundtrip handles text and ping":
    let textFrame = encodeFrame(wsText, "hello")
    let decodedText = decodeFrame(textFrame)
    check decodedText.isSome
    check decodedText.get().message.opcode == wsText
    check decodedText.get().message.data == "hello"
    check decodedText.get().message.isFinal

    let pingFrame = encodeFrame(wsPing, "")
    let decodedPing = decodeFrame(pingFrame)
    check decodedPing.isSome
    check decodedPing.get().message.opcode == wsPing
    check decodedPing.get().message.data.len == 0

    let maskedFrame = encodeFrame(wsText, "client", mask = true)
    let decodedMasked = decodeFrame(maskedFrame)
    check decodedMasked.isSome
    check decodedMasked.get().message.opcode == wsText
    check decodedMasked.get().message.data == "client"

  test "server-side decode option rejects unmasked client frames":
    let unmaskedFrame = encodeFrame(wsText, "client")
    check decodeFrame(unmaskedFrame, requireMasked = true).isNone

    var scratch = ""
    check decodeFrameInto(unmaskedFrame, scratch, requireMasked = true).isNone

    let maskedFrame = encodeFrame(wsText, "client", mask = true)
    check decodeFrame(maskedFrame, requireMasked = true).isSome
    check decodeFrameInto(maskedFrame, scratch, requireMasked = true).isSome

  test "decodeFrame returns none for incomplete payloads":
    check decodeFrame("").isNone
    let partial = encodeFrame(wsBinary, "abcdef")[0 .. 2]
    check decodeFrame(partial).isNone

  test "decodeFrame rejects invalid RSV and control-frame violations":
    let invalidRsv = $char(0xC1) & $char(0x00)
    check decodeFrame(invalidRsv).isNone

    let fragmentedPing = $char(0x09) & $char(0x00)
    check decodeFrame(fragmentedPing).isNone

    let oversizedPing = $char(0x89) & $char(126) & $char(0) & $char(126)
    check decodeFrame(oversizedPing).isNone

    let badClose = $char(0x88) & $char(0x01) & $char(0x00)
    check decodeFrame(badClose).isNone

when isMainModule:
  from ../src/nim_usockets/http import isAsciiOnlyForTest, isAsciiOnlyBytesForTest
  import system

  proc groundTruthAscii(data: openArray[byte], start, length: int): bool =
    for j in 0 ..< length:
      if data[start + j] >= 0x80: return false
    true

  var wsAsciiChecks = 0
  template wsAsciiCheck(cond: untyped) =
    if not cond:
      echo "ws ascii check failed"
      quit(1)
    inc wsAsciiChecks

  for n in 0 .. 80:
    var s0 = newStringOfCap(n)
    s0.setLen(n)
    for j in 0 ..< n: s0[j] = 'A'
    var b0 = newSeq[byte](n)
    for j in 0 ..< n: b0[j] = 65
    wsAsciiCheck isAsciiOnlyForTest(s0)
    wsAsciiCheck isAsciiOnlyBytesForTest(b0, 0, n)
    wsAsciiCheck groundTruthAscii(b0, 0, n)

  for n in 0 .. 80:
    for pos in 0 ..< n:
      for v in [0x80, 0xFF]:
        var s1 = newStringOfCap(n)
        s1.setLen(n)
        for j in 0 ..< n: s1[j] = 'A'
        s1[pos] = char(v)
        var b1 = newSeq[byte](n)
        for j in 0 ..< n: b1[j] = 65
        b1[pos] = byte(v)
        wsAsciiCheck not isAsciiOnlyForTest(s1)
        wsAsciiCheck not isAsciiOnlyBytesForTest(b1, 0, n)
        wsAsciiCheck not groundTruthAscii(b1, 0, n)

  var startBuf = newSeq[byte](16)
  for j in 0 ..< 16: startBuf[j] = 65
  startBuf[0] = 0x80
  wsAsciiCheck isAsciiOnlyBytesForTest(startBuf, 8, 8)
  wsAsciiCheck groundTruthAscii(startBuf, 8, 8)
  startBuf[8] = 0xFF
  wsAsciiCheck not isAsciiOnlyBytesForTest(startBuf, 8, 8)
  wsAsciiCheck not groundTruthAscii(startBuf, 8, 8)

  for n in 0 .. 80:
    var s2 = newStringOfCap(n)
    s2.setLen(n)
    var b2 = newSeq[byte](n)
    for j in 0 ..< n:
      let bv = byte(j mod 256)
      s2[j] = char(bv)
      b2[j] = bv
    wsAsciiCheck isAsciiOnlyForTest(s2) == isAsciiOnlyBytesForTest(b2, 0, n)
    wsAsciiCheck isAsciiOnlyForTest(s2) == groundTruthAscii(b2, 0, n)

  wsAsciiCheck wsAsciiChecks == 19849
  echo "ws ascii SSE2 regression checks: ", wsAsciiChecks
