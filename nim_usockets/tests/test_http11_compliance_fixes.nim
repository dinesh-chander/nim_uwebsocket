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

suite "Fix 1: RFC 9112 §7.1 — Reject leading whitespace in chunk-size (strict HEXDIG)":
  test "leading space before chunk-size hex digits is rejected":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      " 4\r\nWiki\r\n0\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "leading tab before chunk-size hex digits is rejected":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "\t4\r\nWiki\r\n0\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "valid chunk-size without leading whitespace is accepted":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4\r\nWiki\r\n0\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false
      check parsed.req.body == "Wiki"

  test "parseChunkSizeLine rejects non-HEXDIG leading characters":
    let line = " A\r\n".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, 2, chunkSize) == false

  test "parseChunkSizeLine accepts valid hex digits":
    let line = "1A".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, 2, chunkSize) == true
    check chunkSize == 0x1A

suite "Fix 2: RFC 9112 §2.2 — Reject NUL bytes in request-target":
  test "NUL byte in path is rejected":
    let payload = "GET /foo\x00bar HTTP/1.1\r\nHost: example.test\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "NUL byte at start of path is rejected":
    let payload = "GET /\x00 HTTP/1.1\r\nHost: example.test\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "clean path without NUL is accepted":
    let payload = "GET /foo/bar HTTP/1.1\r\nHost: example.test\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false

suite "Fix 3: RFC 9112 §5.2 — Reject obs-fold (obsolete header line folding) with 400":
  test "header line starting with SP (obs-fold) is rejected":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      " X-Continued: value\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "header line starting with HT (obs-fold) is rejected":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "\tX-Continued: value\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "normal header lines without folding are accepted":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-Custom: value\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false

suite "Fix 4: RFC 9112 §5.1 — Validate token chars in ALL header field names":
  test "header name with space is rejected":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Bad Header: value\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "header name with control char is rejected":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Bad\x01Name: value\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "header name with @ is rejected (not a token char)":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Bad@Name: value\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "valid token header names are accepted":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "X-Custom-Header: value\r\n" &
      "X_Another!Header: value2\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false

suite "Fix 5: RFC 9110 §9.3.8 — Reject body in TRACE requests":
  test "TRACE with Content-Length is rejected":
    let payload =
      "TRACE / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length: 5\r\n" &
      "\r\n" &
      "hello"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "TRACE with Transfer-Encoding is rejected":
    let payload =
      "TRACE / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "0\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "TRACE without body headers is accepted":
    let payload =
      "TRACE / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false
      check parsed.req.body == ""

suite "Fix 6: RFC 9110 §15.4.5 — Preserve user-set Content-Length on 304 responses":
  test "statusForbidsContentLength excludes 304":
    check statusForbidsContentLength(100) == true
    check statusForbidsContentLength(101) == true
    check statusForbidsContentLength(199) == true
    check statusForbidsContentLength(204) == true
    check statusForbidsContentLength(304) == false

  test "statusForbidsContentLength allows 200 and 304":
    check statusForbidsContentLength(200) == false
    check statusForbidsContentLength(304) == false
    check statusForbidsContentLength(301) == false

suite "Fix 7: RFC 9112 §7.1.1 — Validate chunk extension bytes (reject control chars)":
  test "chunk extension with control character is rejected":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4;foo=\x01bar\r\nWiki\r\n0\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "chunk extension with NUL byte is rejected":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4;foo=\x00\r\nWiki\r\n0\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "valid chunk extension is accepted":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4;foo=bar\r\nWiki\r\n0\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false
      check parsed.req.body == "Wiki"

  test "parseChunkSizeLine rejects extension with control char":
    let line = "4;ext=\x01val".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == false

  test "parseChunkSizeLine accepts extension with valid chars":
    let line = "4;ext=val".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == true
    check chunkSize == 4

suite "Fix 8: end() Content-Length logic for HEAD/304":
  test "responseDisallowsBody returns true for 304":
    var res = HttpResponse()
    res.statusCodeInt = 304
    res.requestMethod = hmGet
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody returns true for HEAD":
    var res = HttpResponse()
    res.statusCodeInt = 200
    res.requestMethod = hmHead
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody returns true for 204":
    var res = HttpResponse()
    res.statusCodeInt = 204
    res.requestMethod = hmGet
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody returns true for 1xx":
    var res = HttpResponse()
    res.statusCodeInt = 100
    res.requestMethod = hmGet
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody returns false for 200 GET":
    var res = HttpResponse()
    res.statusCodeInt = 200
    res.requestMethod = hmGet
    check res.responseDisallowsBody() == false

suite "Fix 9: isChunkExtByte uses ValidHeaderValueByteTable":
  test "isChunkExtByte accepts printable ASCII":
    check isChunkExtByte(byte(' ')) == true
    check isChunkExtByte(byte('a')) == true
    check isChunkExtByte(byte('Z')) == true
    check isChunkExtByte(byte('=')) == true
    check isChunkExtByte(byte(';')) == true
    check isChunkExtByte(byte('~')) == true

  test "isChunkExtByte accepts HTAB":
    check isChunkExtByte(byte('\t')) == true

  test "isChunkExtByte rejects NUL":
    check isChunkExtByte(byte(0x00)) == false

  test "isChunkExtByte rejects control characters below 0x09":
    for b in 0x00'u8 .. 0x08'u8:
      check isChunkExtByte(b) == false

  test "isChunkExtByte rejects control characters 0x0A-0x1F":
    for b in 0x0A'u8 .. 0x1F'u8:
      check isChunkExtByte(b) == false

  test "isChunkExtByte rejects DEL (0x7F)":
    check isChunkExtByte(byte(0x7F)) == false

suite "Fix 10: RFC 9112 §3 — Reject CR and LF in request-target":
  test "bare CR in path is rejected":
    let payload = "GET /foo\rbar HTTP/1.1\r\nHost: example.test\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "bare LF in path is rejected":
    let payload = "GET /foo\nbar HTTP/1.1\r\nHost: example.test\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true

  test "HTAB in path is rejected":
    let payload = "GET /foo\tbar HTTP/1.1\r\nHost: example.test\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "clean path is accepted":
    let payload = "GET /foo/bar?q=1 HTTP/1.1\r\nHost: example.test\r\n\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false

suite "Fix 11: Suppress Content-Length in buildProtocolErrorResponse for 1xx/204":
  test "buildProtocolErrorResponse for 204 omits Content-Length":
    let response = buildProtocolErrorResponse(204, "", true)
    check "content-length" notin response

  test "buildProtocolErrorResponse for 100 omits Content-Length":
    let response = buildProtocolErrorResponse(100, "", true)
    check "content-length" notin response

  test "buildProtocolErrorResponse for 101 omits Content-Length":
    let response = buildProtocolErrorResponse(101, "", true)
    check "content-length" notin response

  test "buildProtocolErrorResponse for 199 omits Content-Length":
    let response = buildProtocolErrorResponse(199, "", true)
    check "content-length" notin response

  test "buildProtocolErrorResponse for 400 includes Content-Length":
    let response = buildProtocolErrorResponse(400, "bad", true)
    check "content-length: 3" in response

  test "buildProtocolErrorResponse for 200 includes Content-Length":
    let response = buildProtocolErrorResponse(200, "", true)
    check "content-length: 0" in response

  test "buildProtocolErrorResponse for 304 includes Content-Length":
    let response = buildProtocolErrorResponse(304, "", true)
    check "content-length" in response

suite "Fix 12: RFC 9112 §7.1.2 — Validate trailer field values":
  test "trailer with control char in value is rejected":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4\r\nWiki\r\n0\r\n" &
      "X-Trailer: bad\x01value\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "trailer with NUL in value is rejected":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4\r\nWiki\r\n0\r\n" &
      "X-Trailer: \x00\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "trailer with DEL (0x7F) in value is rejected":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4\r\nWiki\r\n0\r\n" &
      "X-Trailer: bad\x7Fval\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "trailer with valid printable value is accepted":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4\r\nWiki\r\n0\r\n" &
      "X-Checksum: abc123\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false
      check parsed.req.body == "Wiki"

  test "trailer with HTAB in value is accepted":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "4\r\nWiki\r\n0\r\n" &
      "X-Trailer: val\twith\ttabs\r\n" &
      "\r\n"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false

suite "Fix 13: RFC 9110 §8.6 — Content-Length comma-separated list":
  test "single CL value accepted":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length: 5\r\n" &
      "\r\n" &
      "hello"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false
      check parsed.req.body == "hello"

  test "comma-separated identical CL values accepted":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length: 5, 5\r\n" &
      "\r\n" &
      "hello"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false
      check parsed.req.body == "hello"

  test "comma-separated CL with whitespace accepted":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length:  5 , 5 \r\n" &
      "\r\n" &
      "hello"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false
      check parsed.req.body == "hello"

  test "comma-separated differing CL values rejected":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length: 5, 6\r\n" &
      "\r\n" &
      "hello!"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok == false
      check parsed.parseError == true
      check parsed.parseStatusCode == 400

  test "triple identical CL values accepted":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Content-Length: 3,3,3\r\n" &
      "\r\n" &
      "abc"
    for minimalHeaders in [false, true]:
      let parsed = parseOutcome(payload, minimalHeaders)
      check parsed.ok
      check parsed.parseError == false
      check parsed.req.body == "abc"

suite "Fix 14: buildProtocolErrorResponse body suppression for 204/205/304":
  test "buildProtocolErrorResponse for 204 suppresses body":
    let response = buildProtocolErrorResponse(204, "should-be-ignored", true)
    check "should-be-ignored" notin response

  test "buildProtocolErrorResponse for 205 suppresses body and emits CL 0":
    let response = buildProtocolErrorResponse(205, "should-be-ignored", true)
    check "should-be-ignored" notin response
    check "content-length: 0" in response

  test "buildProtocolErrorResponse for 304 suppresses body and emits CL 0":
    let response = buildProtocolErrorResponse(304, "should-be-ignored", true)
    check "should-be-ignored" notin response
    check "content-length: 0" in response

  test "buildProtocolErrorResponse for 400 includes body":
    let response = buildProtocolErrorResponse(400, "error details", true)
    check "error details" in response

  test "buildProtocolErrorResponse for 500 includes body":
    let response = buildProtocolErrorResponse(500, "server error", true)
    check "server error" in response
