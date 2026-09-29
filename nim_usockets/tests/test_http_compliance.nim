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

proc parseOutcome(
  payload: string,
  minimalHeaders: bool,
  startPos = 0,
  maxHeaderBytes: int = DefaultMaxHeaderBytes,
  maxHeaderCount: int = DefaultMaxHeaderCount,
  maxHeaderLineBytes: int = DefaultMaxHeaderLineBytes,
  maxRequestUriBytes: int = DefaultMaxRequestUriBytes,
  maxBodySize: int = DefaultMaxBodySize,
  expectContinueMode: ExpectContinueMode = ecmStrictReject
): ParseOutcome =
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
    parseStatusCode,
    maxHeaderBytes = maxHeaderBytes,
    maxHeaderCount = maxHeaderCount,
    maxHeaderLineBytes = maxHeaderLineBytes,
    maxRequestUriBytes = maxRequestUriBytes,
    maxBodySize = maxBodySize,
    expectContinueMode = expectContinueMode
  )
  result.ok = reqOpt.isSome
  result.parseError = parseError
  result.parseStatusCode = parseStatusCode
  result.totalRequestSize = totalRequestSize
  if reqOpt.isSome:
    result.req = reqOpt.get()

# ---------------------------------------------------------------------------
# Suite 1: Request Line Edge Cases
# ---------------------------------------------------------------------------
suite "Request line — method parsing":
  test "all standard methods are accepted":
    for m in ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "CONNECT", "TRACE"]:
      let payload = m & " / HTTP/1.1\r\nHost: h\r\n\r\n"
      let p = parseOutcome(payload, false)
      check p.ok
      check p.parseError == false

  test "unknown method token returns 501":
    let payload = "PURGE / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 501

  test "empty method is rejected":
    let payload = " / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "lowercase method is rejected as unknown":
    let payload = "get / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 501

  test "method with non-token char is rejected":
    let payload = "G\x01T / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

suite "Request line — URI parsing":
  test "maximum length URI at limit is accepted":
    let longPath = "/" & repeat('a', 8190)
    let payload = "GET " & longPath & " HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false, maxRequestUriBytes = 8192)
    check p.ok
    check p.parseError == false

  test "URI exceeding max length returns 414":
    let longPath = "/" & repeat('a', 8193)
    let payload = "GET " & longPath & " HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false, maxRequestUriBytes = 8192)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 414

  test "URI with query string is parsed correctly":
    let payload = "GET /path?key=value&foo=bar HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.path == "/path"
    check p.req.queryStringRaw == "key=value&foo=bar"

  test "URI with only query marker has empty query":
    let payload = "GET /path? HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.path == "/path"

  test "root path is accepted":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.path == "/"

  test "asterisk-form path is accepted":
    let payload = "OPTIONS * HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.path == "*"

  test "path with percent-encoded chars is accepted":
    let payload = "GET /foo%20bar%2Fbaz HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.path == "/foo%20bar%2Fbaz"

  test "missing path is rejected":
    let payload = "GET  HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

suite "Request line — HTTP version":
  test "HTTP/1.1 is accepted with correct version fields":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.httpVersion == "HTTP/1.1"
    check p.req.httpMajor == 1
    check p.req.httpMinor == 1

  test "HTTP/1.0 is accepted with correct version fields":
    let payload = "GET / HTTP/1.0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.httpVersion == "HTTP/1.0"
    check p.req.httpMajor == 1
    check p.req.httpMinor == 0

  test "HTTP/2.0 is rejected with 505":
    let payload = "GET / HTTP/2.0\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 505

  test "HTTP/0.9 is rejected with 505":
    let payload = "GET / HTTP/0.9\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 505

  test "missing version is rejected":
    let payload = "GET /\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "truncated version is rejected":
    let payload = "GET / HTTP/1.\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 505

  test "HTTP/1.0 does not require Host header":
    let payload = "GET / HTTP/1.0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

  test "HTTP/1.1 requires Host header":
    let payload = "GET / HTTP/1.1\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

# ---------------------------------------------------------------------------
# Suite 2: Header Parsing Edge Cases
# ---------------------------------------------------------------------------
suite "Header parsing — empty and whitespace values":
  test "header with empty value is accepted":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-Empty:\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

  test "header with whitespace-only value is accepted (trimmed to empty)":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-Ws:   \r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

  test "header with tab in value is accepted":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-Tab: val\tue\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

suite "Header parsing — limits":
  test "header count at max is accepted":
    var payload = "GET / HTTP/1.1\r\nHost: h\r\n"
    for i in 1..99:
      payload.add("X-H" & $i & ": v\r\n")
    payload.add("\r\n")
    let p = parseOutcome(payload, false, maxHeaderCount = 100)
    check p.ok
    check p.parseError == false

  test "header count exceeding max returns 431":
    var payload = "GET / HTTP/1.1\r\nHost: h\r\n"
    for i in 1..5:
      payload.add("X-H" & $i & ": v\r\n")
    payload.add("\r\n")
    let p = parseOutcome(payload, false, maxHeaderCount = 3)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 431

  test "oversized header section returns 431":
    let bigValue = repeat('x', 200)
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-Big: " & bigValue & "\r\n\r\n"
    let p = parseOutcome(payload, false, maxHeaderBytes = 50)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 431

  test "oversized single header line returns 431":
    let bigValue = repeat('x', 9000)
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-Big: " & bigValue & "\r\n\r\n"
    let p = parseOutcome(payload, false, maxHeaderLineBytes = 8192)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 431

suite "Header parsing — malformed headers":
  test "header without colon is rejected":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nNoColonHere\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "header with empty name (colon first) is rejected":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\n: value\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "duplicate Host headers are rejected for HTTP/1.1":
    let payload = "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "Host header with empty value is rejected for HTTP/1.1":
    let payload = "GET / HTTP/1.1\r\nHost:\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "header value with NUL byte is rejected":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-Bad: val\x00ue\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "header value with control character is rejected":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-Bad: val\x01ue\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "header name with high-bit byte is rejected":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-B\x80d: val\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "header value with high-bit byte (obs-text) is accepted":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-Ok: val\x80ue\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

# ---------------------------------------------------------------------------
# Suite 3: Content-Length Body Parsing
# ---------------------------------------------------------------------------
suite "Content-Length body parsing":
  test "exact Content-Length body is parsed":
    let payload = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "hello"
    check p.totalRequestSize == payload.len

  test "Content-Length: 0 yields empty body":
    let payload = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == ""

  test "no Content-Length and no TE yields empty body":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == ""

  test "insufficient body data returns incomplete (not error)":
    let payload = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\nshort"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == false

  test "non-numeric Content-Length is rejected":
    let payload = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: abc\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "negative Content-Length is rejected":
    let payload = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: -1\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "duplicate Content-Length with same value is accepted":
    let payload = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "abc"

  test "duplicate Content-Length with different values is rejected":
    let payload = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nContent-Length: 5\r\n\r\nabc"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "Content-Length with leading whitespace is accepted":
    let payload = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length:  5\r\n\r\nhello"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "hello"

# ---------------------------------------------------------------------------
# Suite 4: Chunked Transfer Encoding
# ---------------------------------------------------------------------------
suite "Chunked body parsing":
  test "single chunk is decoded correctly":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "5\r\nhello\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "hello"

  test "multiple chunks are concatenated":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "hello world"

  test "zero-length chunk terminates body":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == ""

  test "hex chunk size with uppercase letters":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "A\r\n0123456789\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "0123456789"

  test "hex chunk size with lowercase letters":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "a\r\n0123456789\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "0123456789"

  test "chunk with valid extension is accepted":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "5;name=value\r\nhello\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "hello"

  test "chunk data not followed by CRLF is rejected":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "5\r\nhelloX\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "incomplete chunked body returns incomplete (not error)":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "5\r\nhel"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == false

suite "Chunked body — trailers":
  test "valid trailers after terminal chunk are accepted":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "5\r\nhello\r\n0\r\n" &
      "X-Checksum: abc123\r\n" &
      "\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "hello"

  test "multiple trailers are accepted":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "3\r\nabc\r\n0\r\n" &
      "X-A: 1\r\n" &
      "X-B: 2\r\n" &
      "\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "abc"

  test "trailer with invalid token name is rejected":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "3\r\nabc\r\n0\r\n" &
      "Bad Header: v\r\n" &
      "\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "trailer without colon is rejected":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "3\r\nabc\r\n0\r\n" &
      "NoColonLine\r\n" &
      "\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

# ---------------------------------------------------------------------------
# Suite 5: Transfer-Encoding validation
# ---------------------------------------------------------------------------
suite "Transfer-Encoding validation":
  test "TE: chunked is accepted":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

  test "TE + Content-Length is rejected (smuggling prevention)":
    let payload =
      "POST / HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "Content-Length: 5\r\n" &
      "\r\n" &
      "5\r\nhello\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 400

  test "TE with HTTP/1.0 is rejected":
    let payload =
      "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 400

  test "TE with unsupported coding only returns 501":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\nbody"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "TE: gzip, chunked is rejected (unsupported coding before chunked)":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 501

  test "TE: chunked, gzip (chunked not final) is rejected":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked, gzip\r\n\r\ndata"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "TE: chunked, chunked (duplicate) is rejected":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "TE: empty value is rejected":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "TE case-insensitive: CHUNKED is accepted":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: CHUNKED\r\n\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

# ---------------------------------------------------------------------------
# Suite 6: Connection Management
# ---------------------------------------------------------------------------
suite "Connection management — keep-alive and close":
  test "HTTP/1.1 defaults to keep-alive":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.connectionClose == false

  test "HTTP/1.1 with Connection: close sets close":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.connectionClose == true

  test "HTTP/1.0 defaults to close":
    let payload = "GET / HTTP/1.0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.connectionClose == true

  test "HTTP/1.0 with Connection: keep-alive stays open":
    let payload = "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.connectionClose == false

  test "HTTP/1.0 with both close and keep-alive => close wins":
    let payload = "GET / HTTP/1.0\r\nConnection: keep-alive, close\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.connectionClose == true

  test "HTTP/1.1 Connection: keep-alive is redundant but accepted":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nConnection: keep-alive\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.connectionClose == false

  test "Connection: upgrade is tracked":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nConnection: upgrade\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.connectionHasUpgrade == true

  test "Connection header case insensitive":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nConnection: CLOSE\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.connectionClose == true

# ---------------------------------------------------------------------------
# Suite 7: Expect: 100-Continue
# ---------------------------------------------------------------------------
suite "Expect: 100-continue mechanism":
  test "Expect: 100-continue is rejected in strict mode":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\nhello"
    let p = parseOutcome(payload, false, expectContinueMode = ecmStrictReject)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 417

  test "Expect: 100-continue is accepted in allow mode":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\nhello"
    let p = parseOutcome(payload, false, expectContinueMode = ecmAllow100Continue)
    check p.ok
    check p.parseError == false

  test "unsupported expectation returns 417":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nExpect: 200-ok\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true
    check p.parseStatusCode == 417

  test "Expect: 100-CONTINUE (case insensitive) is handled":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nExpect: 100-CONTINUE\r\n\r\nhello"
    let p = parseOutcome(payload, false, expectContinueMode = ecmAllow100Continue)
    check p.ok
    check p.parseError == false

# ---------------------------------------------------------------------------
# Suite 8: TRACE body rejection
# ---------------------------------------------------------------------------
suite "TRACE body rejection":
  test "TRACE with Content-Length is rejected":
    let payload =
      "TRACE / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "TRACE with Transfer-Encoding is rejected":
    let payload =
      "TRACE / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "TRACE without body is accepted":
    let payload = "TRACE / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == ""

# ---------------------------------------------------------------------------
# Suite 9: Obs-fold rejection
# ---------------------------------------------------------------------------
suite "Obs-fold rejection":
  test "continuation with SP after first header is rejected":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.com\r\n" &
      " continuation\r\n" &
      "\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "continuation with HT after first header is rejected":
    let payload =
      "GET / HTTP/1.1\r\n" &
      "Host: example.com\r\n" &
      "\tcontinuation\r\n" &
      "\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

# ---------------------------------------------------------------------------
# Suite 10: NUL byte rejection in request-target
# ---------------------------------------------------------------------------
suite "NUL and control byte rejection in request-target":
  test "NUL in middle of path":
    let payload = "GET /a\x00b HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "HTAB in path":
    let payload = "GET /a\tb HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "bare CR in path":
    let payload = "GET /a\rb HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "bare LF in path":
    let payload = "GET /a\nb HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

# ---------------------------------------------------------------------------
# Suite 11: Token char validation in header names
# ---------------------------------------------------------------------------
suite "Token char validation in header names":
  test "header name with bracket is rejected":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nBad[Name: v\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "header name with backslash is rejected":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nBad\\Name: v\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "header name with double quote is rejected":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nBad\"Name: v\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "header name with allowed special chars is accepted":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nX-My_Header!#$%&'*+-.^`|~: v\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

  test "header name validation in minimal headers mode":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nBad Name: v\r\n\r\n"
    let p = parseOutcome(payload, true)
    check p.ok == false
    check p.parseError == true

# ---------------------------------------------------------------------------
# Suite 12: 304 Content-Length preservation
# ---------------------------------------------------------------------------
suite "304 Content-Length preservation":
  test "statusForbidsContentLength returns false for 304":
    check statusForbidsContentLength(304) == false

  test "statusForbidsContentLength returns true for 204":
    check statusForbidsContentLength(204) == true

  test "statusForbidsContentLength returns true for 1xx":
    check statusForbidsContentLength(100) == true
    check statusForbidsContentLength(101) == true
    check statusForbidsContentLength(199) == true

  test "statusForbidsContentLength returns false for 200":
    check statusForbidsContentLength(200) == false

  test "statusForbidsContentLength returns false for 301":
    check statusForbidsContentLength(301) == false

# ---------------------------------------------------------------------------
# Suite 13: Chunk extension validation
# ---------------------------------------------------------------------------
suite "Chunk extension validation":
  test "extension with control char 0x01 is rejected":
    let line = "4;ext=\x01val".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == false

  test "extension with NUL is rejected":
    let line = "4;ext=\x00val".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == false

  test "extension with DEL (0x7F) is rejected":
    let line = "4;ext=\x7Fval".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == false

  test "extension with valid printable ASCII is accepted":
    let line = "4;ext=val".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == true
    check chunkSize == 4

  test "extension with HTAB is accepted":
    let line = "4;ext=\tval".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == true
    check chunkSize == 4

  test "extension with quoted string is accepted":
    let line = "4;ext=\"quoted value\"".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == true
    check chunkSize == 4

# ---------------------------------------------------------------------------
# Suite 14: Pipelining
# ---------------------------------------------------------------------------
suite "Pipelining — sequential request parsing":
  test "two pipelined GET requests are parsed with correct boundaries":
    let req1 = "GET /first HTTP/1.1\r\nHost: h\r\n\r\n"
    let req2 = "GET /second HTTP/1.1\r\nHost: h\r\n\r\n"
    let combined = req1 & req2

    let p1 = parseOutcome(combined, false, startPos = 0)
    check p1.ok
    check p1.req.path == "/first"
    check p1.totalRequestSize == req1.len

    let p2 = parseOutcome(combined, false, startPos = p1.totalRequestSize)
    check p2.ok
    check p2.req.path == "/second"
    check p2.totalRequestSize == req2.len

  test "pipelined POST followed by GET":
    let req1 = "POST /data HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nabc"
    let req2 = "GET /next HTTP/1.1\r\nHost: h\r\n\r\n"
    let combined = req1 & req2

    let p1 = parseOutcome(combined, false, startPos = 0)
    check p1.ok
    check p1.req.path == "/data"
    check p1.req.body == "abc"
    check p1.totalRequestSize == req1.len

    let p2 = parseOutcome(combined, false, startPos = p1.totalRequestSize)
    check p2.ok
    check p2.req.path == "/next"

  test "pipelined chunked POST followed by GET":
    let req1 =
      "POST /upload HTTP/1.1\r\n" &
      "Host: h\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "3\r\nabc\r\n0\r\n\r\n"
    let req2 = "GET /done HTTP/1.1\r\nHost: h\r\n\r\n"
    let combined = req1 & req2

    let p1 = parseOutcome(combined, false, startPos = 0)
    check p1.ok
    check p1.req.body == "abc"
    check p1.totalRequestSize == req1.len

    let p2 = parseOutcome(combined, false, startPos = p1.totalRequestSize)
    check p2.ok
    check p2.req.path == "/done"

# ---------------------------------------------------------------------------
# Suite 15: HEAD response body suppression
# ---------------------------------------------------------------------------
suite "HEAD response body suppression":
  test "responseDisallowsBody is true for HEAD request":
    var res = HttpResponse()
    res.statusCodeInt = 200
    res.requestMethod = hmHead
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody is true for 204":
    var res = HttpResponse()
    res.statusCodeInt = 204
    res.requestMethod = hmGet
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody is true for 205":
    var res = HttpResponse()
    res.statusCodeInt = 205
    res.requestMethod = hmGet
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody is true for 304":
    var res = HttpResponse()
    res.statusCodeInt = 304
    res.requestMethod = hmGet
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody is true for 1xx":
    var res = HttpResponse()
    res.statusCodeInt = 100
    res.requestMethod = hmGet
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody is false for 200 GET":
    var res = HttpResponse()
    res.statusCodeInt = 200
    res.requestMethod = hmGet
    check res.responseDisallowsBody() == false

  test "responseDisallowsBody is false for 201 POST":
    var res = HttpResponse()
    res.statusCodeInt = 201
    res.requestMethod = hmPost
    check res.responseDisallowsBody() == false

  test "responseDisallowsBody is true for 2xx CONNECT success":
    var res = HttpResponse()
    res.statusCodeInt = 200
    res.requestMethod = hmConnect
    check res.responseDisallowsBody() == true

  test "responseDisallowsBody is false for nil response":
    let res: HttpResponse = nil
    check responseDisallowsBody(res) == false

# ---------------------------------------------------------------------------
# Suite 16: Response generation — buildProtocolErrorResponse
# ---------------------------------------------------------------------------
suite "buildProtocolErrorResponse":
  test "400 generates proper response with Content-Length":
    let resp = buildProtocolErrorResponse(400, "bad request", true)
    check resp.startsWith("HTTP/1.1 400 Bad Request\r\n")
    check "content-length: 11\r\n" in resp
    check "connection: close\r\n" in resp
    check resp.endsWith("bad request")

  test "204 omits Content-Length":
    let resp = buildProtocolErrorResponse(204, "", true)
    check resp.startsWith("HTTP/1.1 204")
    check "content-length" notin resp

  test "304 includes Content-Length":
    let resp = buildProtocolErrorResponse(304, "", true)
    check "content-length" in resp

  test "1xx omits Content-Length":
    let resp = buildProtocolErrorResponse(100, "", true)
    check "content-length" notin resp
    let resp2 = buildProtocolErrorResponse(101, "", true)
    check "content-length" notin resp2

  test "keep-alive connection header":
    let resp = buildProtocolErrorResponse(200, "", false)
    check "connection: keep-alive\r\n" in resp

  test "close connection header":
    let resp = buildProtocolErrorResponse(200, "", true)
    check "connection: close\r\n" in resp

  test "date header is included":
    let resp = buildProtocolErrorResponse(200, "", true)
    check "date: " in resp

  test "body not included for status < 200":
    let resp = buildProtocolErrorResponse(100, "should not appear", true)
    check "should not appear" notin resp

  test "body included for status >= 200":
    let resp = buildProtocolErrorResponse(500, "error body", true)
    check resp.endsWith("error body")

  test "invalid status code is clamped to 400":
    let resp = buildProtocolErrorResponse(50, "", true)
    check "HTTP/1.1 400" in resp

  test "status code > 999 is clamped to 400":
    let resp = buildProtocolErrorResponse(1000, "", true)
    check "HTTP/1.1 400" in resp

# ---------------------------------------------------------------------------
# Suite 17: Security — CRLF injection prevention in response headers
# ---------------------------------------------------------------------------
suite "CRLF injection prevention":
  test "hasValidHeaderName rejects empty string":
    check hasValidHeaderName("") == false

  test "hasValidHeaderName rejects name with space":
    check hasValidHeaderName("Bad Name") == false

  test "hasValidHeaderName rejects name with colon":
    check hasValidHeaderName("Bad:Name") == false

  test "hasValidHeaderName rejects name with CR":
    check hasValidHeaderName("Bad\rName") == false

  test "hasValidHeaderName rejects name with LF":
    check hasValidHeaderName("Bad\nName") == false

  test "hasValidHeaderName accepts valid token":
    check hasValidHeaderName("X-Custom-Header") == true
    check hasValidHeaderName("Content-Type") == true

  test "hasUnsafeHeaderValueBytes detects CR":
    check hasUnsafeHeaderValueBytes("val\rue") == true

  test "hasUnsafeHeaderValueBytes detects LF":
    check hasUnsafeHeaderValueBytes("val\nue") == true

  test "hasUnsafeHeaderValueBytes detects NUL":
    check hasUnsafeHeaderValueBytes("val\x00ue") == true

  test "hasUnsafeHeaderValueBytes accepts clean value":
    check hasUnsafeHeaderValueBytes("clean value") == false

  test "hasUnsafeHeaderValueBytes accepts HTAB":
    check hasUnsafeHeaderValueBytes("val\tue") == false

# ---------------------------------------------------------------------------
# Suite 18: isTokenCharByte / TokenCharTable
# ---------------------------------------------------------------------------
suite "isTokenCharByte / TokenCharTable correctness":
  test "alphanumeric chars are token chars":
    for c in 'a'..'z':
      check TokenCharTable[byte(c)] == true
    for c in 'A'..'Z':
      check TokenCharTable[byte(c)] == true
    for c in '0'..'9':
      check TokenCharTable[byte(c)] == true

  test "allowed special chars are token chars":
    for ch in "!#$%&'*+-.^_`|~":
      check TokenCharTable[byte(ch)] == true

  test "separators are not token chars":
    for ch in "()/<>@,;:\\\"{}[]?= \t":
      check TokenCharTable[byte(ch)] == false

  test "control chars are not token chars":
    for b in 0x00'u8..0x1F'u8:
      check TokenCharTable[b] == false
    check TokenCharTable[0x7F'u8] == false

# ---------------------------------------------------------------------------
# Suite 19: ValidHeaderValueByteTable correctness
# ---------------------------------------------------------------------------
suite "ValidHeaderValueByteTable correctness":
  test "HTAB (0x09) is valid":
    check ValidHeaderValueByteTable[0x09] == true

  test "printable ASCII (0x20-0x7E) is valid":
    for b in 0x20'u8..0x7E'u8:
      check ValidHeaderValueByteTable[b] == true

  test "obs-text (0x80-0xFF) is valid":
    for b in 0x80'u8..0xFF'u8:
      check ValidHeaderValueByteTable[b] == true

  test "NUL is invalid":
    check ValidHeaderValueByteTable[0x00] == false

  test "control chars below HTAB are invalid":
    for b in 0x01'u8..0x08'u8:
      check ValidHeaderValueByteTable[b] == false

  test "control chars 0x0A-0x1F are invalid":
    for b in 0x0A'u8..0x1F'u8:
      check ValidHeaderValueByteTable[b] == false

  test "DEL (0x7F) is invalid":
    check ValidHeaderValueByteTable[0x7F] == false

# ---------------------------------------------------------------------------
# Suite 20: Minimal headers mode
# ---------------------------------------------------------------------------
suite "Minimal headers mode parity":
  test "valid request parses in both modes":
    let payload = "GET /test HTTP/1.1\r\nHost: example.com\r\nX-Custom: val\r\n\r\n"
    let full = parseOutcome(payload, false)
    let minimal = parseOutcome(payload, true)
    check full.ok
    check minimal.ok
    check full.req.path == minimal.req.path
    check full.req.methodKind == minimal.req.methodKind

  test "invalid header name is rejected in both modes":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nBad Name: v\r\n\r\n"
    let full = parseOutcome(payload, false)
    let minimal = parseOutcome(payload, true)
    check full.ok == false
    check full.parseError == true
    check minimal.ok == false
    check minimal.parseError == true

  test "obs-fold is rejected in both modes":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\n continuation\r\n\r\n"
    let full = parseOutcome(payload, false)
    let minimal = parseOutcome(payload, true)
    check full.ok == false
    check minimal.ok == false

  test "chunked body parsed in both modes":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n" &
      "3\r\nabc\r\n0\r\n\r\n"
    let full = parseOutcome(payload, false)
    let minimal = parseOutcome(payload, true)
    check full.ok
    check minimal.ok
    check full.req.body == "abc"
    check minimal.req.body == "abc"

  test "TE+CL smuggling rejected in both modes":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\n" &
      "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello"
    let full = parseOutcome(payload, false)
    let minimal = parseOutcome(payload, true)
    check full.ok == false
    check full.parseError == true
    check minimal.ok == false
    check minimal.parseError == true

# ---------------------------------------------------------------------------
# Suite 21: parseChunkSizeLine edge cases
# ---------------------------------------------------------------------------
suite "parseChunkSizeLine edge cases":
  test "empty line is rejected":
    let line: seq[byte] = @[]
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, 0, chunkSize) == false

  test "zero chunk size":
    let line = "0".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == true
    check chunkSize == 0

  test "large hex value":
    let line = "FFFFFF".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == true
    check chunkSize == 0xFFFFFF

  test "mixed case hex":
    let line = "aB".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == true
    check chunkSize == 0xAB

  test "trailing whitespace before semicolon is trimmed":
    let line = "A  ;ext".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == true
    check chunkSize == 0xA

  test "non-hex character is rejected":
    let line = "GG".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == false

  test "only whitespace is rejected":
    let line = "  ".toBytes()
    var chunkSize = 0
    check parseChunkSizeLine(line, 0, line.len, chunkSize) == false

# ---------------------------------------------------------------------------
# Suite 22: Content-Length parsing edge cases
# ---------------------------------------------------------------------------
suite "parseContentLengthBytes edge cases":
  test "valid integer":
    let data = "42".toBytes()
    var cl = 0
    check parseContentLengthBytes(data, 0, data.len, cl) == true
    check cl == 42

  test "zero":
    let data = "0".toBytes()
    var cl = 0
    check parseContentLengthBytes(data, 0, data.len, cl) == true
    check cl == 0

  test "leading whitespace is skipped":
    let data = "  10".toBytes()
    var cl = 0
    check parseContentLengthBytes(data, 0, data.len, cl) == true
    check cl == 10

  test "trailing whitespace is skipped":
    let data = "10  ".toBytes()
    var cl = 0
    check parseContentLengthBytes(data, 0, data.len, cl) == true
    check cl == 10

  test "non-digit character is rejected":
    let data = "12x4".toBytes()
    var cl = 0
    check parseContentLengthBytes(data, 0, data.len, cl) == false

  test "empty value is rejected":
    let data = "".toBytes()
    var cl = 0
    check parseContentLengthBytes(data, 0, data.len, cl) == false

  test "only whitespace is rejected":
    let data = "   ".toBytes()
    var cl = 0
    check parseContentLengthBytes(data, 0, data.len, cl) == false

  test "hex digits are rejected":
    let data = "FF".toBytes()
    var cl = 0
    check parseContentLengthBytes(data, 0, data.len, cl) == false

# ---------------------------------------------------------------------------
# Suite 23: formatDateHeaderLine
# ---------------------------------------------------------------------------
suite "formatDateHeaderLine":
  test "generates valid date header line":
    let line = formatDateHeaderLine(0)
    check line.startsWith("date: ")
    check line.endsWith(" GMT\r\n")
    check "1970" in line

  test "recent epoch generates reasonable date":
    let line = formatDateHeaderLine(1700000000)
    check "2023" in line
    check line.endsWith(" GMT\r\n")

# ---------------------------------------------------------------------------
# Suite 24: decodeChunkedBody max size enforcement
# ---------------------------------------------------------------------------
suite "Chunked body max size enforcement":
  test "chunk exceeding max body size is rejected":
    let largeChunk = repeat('X', 100)
    let chunkedPayload = "64\r\n" & largeChunk & "\r\n0\r\n\r\n"
    let data = chunkedPayload.toBytes()
    var decodedBody = ""
    var consumed = 0
    var parseError = false
    let ok = decodeChunkedBody(data, 0, data.len, decodedBody, consumed, parseError, maxBodySize = 50)
    check ok == false
    check parseError == true

  test "chunk within max body size is accepted":
    let smallChunk = repeat('X', 10)
    let chunkedPayload = "a\r\n" & smallChunk & "\r\n0\r\n\r\n"
    let data = chunkedPayload.toBytes()
    var decodedBody = ""
    var consumed = 0
    var parseError = false
    let ok = decodeChunkedBody(data, 0, data.len, decodedBody, consumed, parseError, maxBodySize = 50)
    check ok == true
    check parseError == false
    check decodedBody == smallChunk

  test "HTTP parser enforces configured max body size for chunked requests":
    let payload =
      "POST /upload HTTP/1.1\r\n" &
      "Host: example.test\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "\r\n" &
      "6\r\nabcdef\r\n0\r\n\r\n"

    let tooSmall = parseOutcome(payload, false, maxBodySize = 5)
    check tooSmall.ok == false
    check tooSmall.parseError == true

    let accepted = parseOutcome(payload, false, maxBodySize = 6)
    check accepted.ok == true
    check accepted.req.body == "abcdef"

# ---------------------------------------------------------------------------
# Suite 25: Host header requirements
# ---------------------------------------------------------------------------
suite "Host header requirements":
  test "HTTP/1.1 with no Host is rejected":
    let payload = "GET / HTTP/1.1\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "HTTP/1.1 with exactly one Host is accepted":
    let payload = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

  test "HTTP/1.1 with duplicate Host is rejected":
    let payload = "GET / HTTP/1.1\r\nHost: a.com\r\nHost: b.com\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "HTTP/1.1 with empty Host value is rejected":
    let payload = "GET / HTTP/1.1\r\nHost:\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == true

  test "HTTP/1.0 without Host is accepted":
    let payload = "GET / HTTP/1.0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

  test "HTTP/1.0 with Host is also accepted":
    let payload = "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.parseError == false

# ---------------------------------------------------------------------------
# Suite 26: Total request size calculation
# ---------------------------------------------------------------------------
suite "Total request size calculation":
  test "GET request size equals raw payload length":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.totalRequestSize == payload.len

  test "POST with Content-Length includes body in total size":
    let payload = "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.totalRequestSize == payload.len

  test "POST with chunked includes chunk framing in total size":
    let payload =
      "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n" &
      "5\r\nhello\r\n0\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.totalRequestSize == payload.len

  test "pipelined request size does not include second request":
    let req1 = "GET /a HTTP/1.1\r\nHost: h\r\n\r\n"
    let req2 = "GET /b HTTP/1.1\r\nHost: h\r\n\r\n"
    let combined = req1 & req2
    let p = parseOutcome(combined, false, startPos = 0)
    check p.ok
    check p.totalRequestSize == req1.len

# ---------------------------------------------------------------------------
# Suite 27: Method-specific parsing
# ---------------------------------------------------------------------------
suite "Method-specific parsing":
  test "GET with body (Content-Length) is accepted":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nabc"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "abc"

  test "HEAD without body is accepted":
    let payload = "HEAD / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.methodKind == hmHead
    check p.req.body == ""

  test "OPTIONS without body is accepted":
    let payload = "OPTIONS / HTTP/1.1\r\nHost: h\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.methodKind == hmOptions

  test "DELETE with body is accepted":
    let payload = "DELETE /resource HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nok"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "ok"

  test "PATCH with body is accepted":
    let payload = "PATCH /item HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\ndata"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.body == "data"

  test "CONNECT is accepted":
    let payload = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"
    let p = parseOutcome(payload, false)
    check p.ok
    check p.req.methodKind == hmConnect

# ---------------------------------------------------------------------------
# Suite 28: Case-insensitive header recognition
# ---------------------------------------------------------------------------
suite "Case-insensitive header name recognition":
  test "Content-Length in various cases":
    for clName in ["Content-Length", "content-length", "CONTENT-LENGTH", "Content-length"]:
      let payload = "POST / HTTP/1.1\r\nHost: h\r\n" & clName & ": 3\r\n\r\nabc"
      let p = parseOutcome(payload, false)
      check p.ok
      check p.req.body == "abc"

  test "Transfer-Encoding in various cases":
    for teName in ["Transfer-Encoding", "transfer-encoding", "TRANSFER-ENCODING"]:
      let payload = "POST / HTTP/1.1\r\nHost: h\r\n" & teName & ": chunked\r\n\r\n0\r\n\r\n"
      let p = parseOutcome(payload, false)
      check p.ok

  test "Host in various cases":
    for hostName in ["Host", "host", "HOST"]:
      let payload = "GET / HTTP/1.1\r\n" & hostName & ": h\r\n\r\n"
      let p = parseOutcome(payload, false)
      check p.ok

  test "Connection in various cases":
    for connName in ["Connection", "connection", "CONNECTION"]:
      let payload = "GET / HTTP/1.1\r\nHost: h\r\n" & connName & ": close\r\n\r\n"
      let p = parseOutcome(payload, false)
      check p.ok
      check p.req.connectionClose == true

# ---------------------------------------------------------------------------
# Suite 29: isChunkExtByte boundary checks
# ---------------------------------------------------------------------------
suite "isChunkExtByte boundary checks":
  test "space (0x20) is valid":
    check isChunkExtByte(0x20'u8) == true

  test "tilde (0x7E) is valid (highest printable ASCII)":
    check isChunkExtByte(0x7E'u8) == true

  test "HTAB (0x09) is valid":
    check isChunkExtByte(0x09'u8) == true

  test "byte 0x08 is invalid":
    check isChunkExtByte(0x08'u8) == false

  test "byte 0x0A (LF) is invalid":
    check isChunkExtByte(0x0A'u8) == false

  test "byte 0x0D (CR) is invalid":
    check isChunkExtByte(0x0D'u8) == false

  test "DEL (0x7F) is invalid":
    check isChunkExtByte(0x7F'u8) == false

  test "obs-text bytes (0x80+) are valid":
    check isChunkExtByte(0x80'u8) == true
    check isChunkExtByte(0xFF'u8) == true

# ---------------------------------------------------------------------------
# Suite 30: Incomplete / partial requests
# ---------------------------------------------------------------------------
suite "Incomplete / partial request handling":
  test "only method is incomplete":
    let payload = "GET "
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == false

  test "missing header terminator is incomplete":
    let payload = "GET / HTTP/1.1\r\nHost: h\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == false

  test "empty input is incomplete":
    let payload = ""
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == false

  test "just CRLF is incomplete":
    let payload = "\r\n"
    let p = parseOutcome(payload, false)
    check p.ok == false
    check p.parseError == false
