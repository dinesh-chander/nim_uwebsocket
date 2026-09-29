import std/unittest

include ../src/nim_usockets/http

type
  ParseOutcome = object
    ok: bool
    parseError: bool
    parseStatusCode: int
    totalRequestSize: int
    req: HttpRequest

proc toBytes(payload: string): seq[byte] =
  result = newSeq[byte](payload.len)
  for i in 0..<payload.len:
    result[i] = byte(payload[i])

proc parseOutcome(payload: string, minimalHeaders: bool, startPos = 0): ParseOutcome =
  let data = payload.toBytes()
  var totalRequestSize = 0
  var parseError = false
  var parseStatusCode = 400
  let reqOpt = parseHttpRequest(
    data,
    startPos,
    totalRequestSize,
    minimalHeaders,
    0,
    "",
    parseError,
    parseStatusCode
  )
  result.ok = reqOpt.isSome
  result.parseError = parseError
  result.parseStatusCode = parseStatusCode
  result.totalRequestSize = totalRequestSize
  if reqOpt.isSome:
    result.req = reqOpt.get()

suite "HTTP parser framing compliance":
  test "request-line parsing rejects malformed spacing and version tokens (RFC 9112 section 3)" :
    let malformedCases = [
      ("GET/ HTTP/1.1\r\nHost: example.test\r\n\r\n", 400, true),
      ("GET  HTTP/1.1\r\nHost: example.test\r\n\r\n", 400, true),
      ("GET / HTTP/9.9\r\nHost: example.test\r\n\r\n", 505, true),
      # LF-only separators are treated as incomplete (no CRLF terminator found).
      ("GET / HTTP/1.1\nHost: example.test\n\n", 400, false)
    ]
    for (payload, expectedStatus, expectParseError) in malformedCases:
      for minimalHeaders in [false, true]:
        let parsed = parseOutcome(payload, minimalHeaders)
        check parsed.ok == false
        check parsed.parseError == expectParseError
        check parsed.parseStatusCode == expectedStatus

  test "method token strictness is case-sensitive token grammar (RFC 9110 section 9, RFC 9112 section 3.1)" :
    let methodCases = [
      ("get", 501),   # valid token but unknown method => Not Implemented
      ("PRI*", 501),  # token-valid extension method still mapped to 501
      ("B@D", 400),   # invalid token byte
      ("GE\tT", 400)  # control separator inside method token
    ]
    for (methodToken, expectedStatus) in methodCases:
      let payload = methodToken & " / HTTP/1.1\r\nHost: example.test\r\n\r\n"
      for minimalHeaders in [false, true]:
        let parsed = parseOutcome(payload, minimalHeaders)
        check parsed.ok == false
        check parsed.parseError == true
        check parsed.parseStatusCode == expectedStatus

  test "duplicate Content-Length must agree; invalid or overflow values are rejected (RFC 9112 section 6.2/6.3)" :
    let validDuplicate =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length: 4\r\n" &
      "Content-Length: 4\r\n" &
      "\r\n" &
      "ABCD"
    let invalidCases = [
      "POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nABCD",
      "POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: +10\r\n\r\nabcdefghij",
      "POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: \r\n\r\n",
      "POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 999999999999999999999999\r\n\r\n"
    ]

    for minimalHeaders in [false, true]:
      let parsedOk = parseOutcome(validDuplicate, minimalHeaders)
      check parsedOk.ok
      check parsedOk.parseError == false
      check parsedOk.req.body == "ABCD"
      check parsedOk.totalRequestSize == validDuplicate.len

      for payload in invalidCases:
        let parsedBad = parseOutcome(payload, minimalHeaders)
        check parsedBad.ok == false
        check parsedBad.parseError == true
        check parsedBad.parseStatusCode == 400

  test "header folding and Host rules follow RFC requirements" :
    let foldedHeader =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      " X-Folded: bad\r\n" &
      "\r\n"
    let duplicateHostHttp11 =
      "GET / HTTP/1.1\r\n" &
      "Host: first.example\r\n" &
      "Host: second.example\r\n" &
      "\r\n"
    let duplicateHostHttp10 =
      "GET / HTTP/1.0\r\n" &
      "Host: first.example\r\n" &
      "Host: second.example\r\n" &
      "\r\n"

    for minimalHeaders in [false, true]:
      let folded = parseOutcome(foldedHeader, minimalHeaders)
      check folded.ok == false
      check folded.parseError == true
      check folded.parseStatusCode == 400

      let dup11 = parseOutcome(duplicateHostHttp11, minimalHeaders)
      check dup11.ok == false
      check dup11.parseError == true
      check dup11.parseStatusCode == 400

      # HTTP/1.0 does not require exactly one Host field.
      let dup10 = parseOutcome(duplicateHostHttp10, minimalHeaders)
      check dup10.ok
      check dup10.parseError == false

  test "duplicate Host in HTTP/1.1 is rejected with 400":
    let payload = "GET / HTTP/1.1\r\nHost: first.example\r\nHost: second.example\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "TE plus CL ambiguity is rejected with 400":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "Content-Length: 4\r\n" &
      "\r\n" &
      "0\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "unsupported transfer coding is deterministically 501":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: gzip\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 501

  test "transfer coding order and final chunked requirement are enforced":
    let chunkedThenGzip =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked, gzip\r\n" &
      "\r\n"
    let gzipThenChunked =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: gzip, chunked\r\n" &
      "\r\n" &
      "0\r\n\r\n"

    for minimalHeaders in [false, true]:
      let first = parseOutcome(chunkedThenGzip, minimalHeaders)
      check first.ok == false
      check first.parseError == true
      check first.parseStatusCode == 400

      let second = parseOutcome(gzipThenChunked, minimalHeaders)
      check second.ok == false
      check second.parseError == true
      check second.parseStatusCode == 501

  test "malformed chunk-size framing is rejected with 400":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "ZZ\r\n" &
      "abc\r\n" &
      "0\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "oversized chunk length line remains non-crashing and incomplete":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "7fffffffffffffff\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == false
      check parsed.parseStatusCode == 400

  test "valid chunked framing with extension and trailer decodes and preserves boundaries":
    let firstReq =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4;foo=bar\r\nWiki\r\n" &
      "5\r\npedia\r\n" &
      "0\r\nX-Trailer: ok\r\n\r\n"
    let secondReq = "GET /next HTTP/1.1\r\nHost: example.test\r\n\r\n"
    let pipelined = firstReq & secondReq

    for minimalHeaders in [false, true]:
      let first = parseOutcome(pipelined, minimalHeaders)
      check first.ok
      check first.parseError == false
      check first.req.body == "Wikipedia"
      check first.totalRequestSize == firstReq.len

      let second = parseOutcome(pipelined, minimalHeaders, first.totalRequestSize)
      check second.ok
      check second.parseError == false
      check second.req.path == "/next"
      check second.totalRequestSize == secondReq.len

  test "truncated chunk framing is incomplete without false hard-error":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4\r\nWiki\r\n" &
      "5\r\nped"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == false

  test "declared Content-Length body excludes pipelined bytes":
    let firstReq =
      "POST /one HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length: 4\r\n" &
      "\r\n" &
      "ABCD"
    let secondReq = "GET /two HTTP/1.1\r\nHost: example.test\r\n\r\n"
    let pipelined = firstReq & secondReq

    for minimalHeaders in [false, true]:
      let first = parseOutcome(pipelined, minimalHeaders)
      check first.ok
      check first.parseError == false
      check first.req.body == "ABCD"
      check first.totalRequestSize == firstReq.len

      let second = parseOutcome(pipelined, minimalHeaders, first.totalRequestSize)
      check second.ok
      check second.parseError == false
      check second.req.path == "/two"
      check second.totalRequestSize == secondReq.len

  test "HTTP-layer WebSocket handshake edge validation returns deterministic status":
    let valid =
      "GET /ws HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: keep-alive, Upgrade\r\n" &
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Version: 13\r\n" &
      "\r\n"
    let badVersion =
      "GET /ws HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: Upgrade\r\n" &
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Version: 12\r\n" &
      "\r\n"
    let badKey =
      "GET /ws HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: Upgrade\r\n" &
      "Sec-WebSocket-Key: not-base64@@@\r\n" &
      "Sec-WebSocket-Version: 13\r\n" &
      "\r\n"
    let missingConnUpgrade =
      "GET /ws HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: keep-alive\r\n" &
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Version: 13\r\n" &
      "\r\n"

    let parsedValid = parseOutcome(valid, minimalHeaders = false)
    check parsedValid.ok
    check parsedValid.req.isWebSocketUpgrade()
    let validResult = validateWebSocketUpgrade(parsedValid.req)
    check validResult.ok
    check validResult.statusCode == 101

    let parsedBadVersion = parseOutcome(badVersion, minimalHeaders = false)
    check parsedBadVersion.ok
    check parsedBadVersion.req.isWebSocketUpgrade()
    let badVersionResult = validateWebSocketUpgrade(parsedBadVersion.req)
    check badVersionResult.ok == false
    check badVersionResult.statusCode == 426
    check badVersionResult.extraHeaders.contains("Sec-WebSocket-Version: 13")

    let parsedBadKey = parseOutcome(badKey, minimalHeaders = false)
    check parsedBadKey.ok
    check parsedBadKey.req.isWebSocketUpgrade()
    let badKeyResult = validateWebSocketUpgrade(parsedBadKey.req)
    check badKeyResult.ok == false
    check badKeyResult.statusCode == 400

    let parsedMissingConn = parseOutcome(missingConnUpgrade, minimalHeaders = false)
    check parsedMissingConn.ok
    check parsedMissingConn.req.isWebSocketUpgrade() == false
