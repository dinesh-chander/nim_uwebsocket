import std/[unittest, random]
import ../src/nim_usockets/http

when not defined(nimUwebsocketsTest):
  {.error: "Compile this test with -d:nimUwebsocketsTest".}

const
  AllowedErrorStatuses = [400, 417, 431, 501, 505]
  KnownMethods = [
    "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "CONNECT", "TRACE"
  ]
  TokenAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"

proc parse(payload: string): tuple[
  ok: bool,
  req: HttpRequest,
  parseError: bool,
  parseStatusCode: int,
  totalRequestSize: int
] =
  parseHttpRequestForTest(payload, minimalHeaders = false)

proc hasKnownMethod(token: string): bool =
  for m in KnownMethods:
    if token == m:
      return true
  false

proc randomUnknownMethod(rng: var Rand): string =
  while true:
    let n = rng.rand(3..10)
    var s = newStringOfCap(n)
    for _ in 0..<n:
      s.add(TokenAlphabet[rng.rand(0..TokenAlphabet.high)])
    if not s.hasKnownMethod():
      return s

proc randomObsTextValue(rng: var Rand): string =
  let n = rng.rand(4..24)
  var s = newStringOfCap(n)
  for _ in 0..<n:
    if rng.rand(0..4) == 0:
      s.add(char(rng.rand(0x80..0xFF)))
    else:
      s.add(char(rng.rand(ord('a')..ord('z'))))
  s

suite "HTTP parser property/fuzz compliance":
  test "request-line mutators classify token-valid unknown methods as 501":
    var rng = initRand(0xA11CE)
    for i in 0..<200:
      let methodToken = rng.randomUnknownMethod()
      let payload = methodToken & " /m" & $i & " HTTP/1.1\r\nHost: example.test\r\n\r\n"
      let parsed = parse(payload)
      check parsed.ok == false
      check parsed.parseError
      check parsed.parseStatusCode == 501

  test "request-line mutators reject invalid method bytes and malformed versions":
    var rng = initRand(0xBEE1)
    for i in 0..<160:
      let kind = rng.rand(0..2)
      var payload = ""
      if kind == 0:
        payload = "G\x01T /x HTTP/1.1\r\nHost: example.test\r\n\r\n"
      elif kind == 1:
        let minor = rng.rand(2..9)
        payload = "GET /x HTTP/1." & $minor & "\r\nHost: example.test\r\n\r\n"
      else:
        payload = "GET  /x HTTP/1.1\r\nHost: example.test\r\n\r\n"

      let parsed = parse(payload)
      check parsed.ok == false
      if kind == 1:
        check parsed.parseError
        check parsed.parseStatusCode == 505
      else:
        check parsed.parseError
        check parsed.parseStatusCode in [400, 505]

  test "header mutators reject invalid field-name/value controls and accept obs-text":
    var rng = initRand(0xC0FFEE)
    for _ in 0..<120:
      let payload =
        "GET /h HTTP/1.1\r\n" &
        "Host: example.test\r\n" &
        "X-\x01Bad: 1\r\n" &
        "\r\n"
      let parsed = parse(payload)
      check parsed.ok == false
      check parsed.parseError
      check parsed.parseStatusCode == 400

    for _ in 0..<120:
      let ctl = char(rng.rand(1..8))
      let payload =
        "GET /h HTTP/1.1\r\n" &
        "Host: example.test\r\n" &
        "X-Bad: ok" & $ctl & "value\r\n" &
        "\r\n"
      let parsed = parse(payload)
      check parsed.ok == false
      check parsed.parseError
      check parsed.parseStatusCode == 400

    for _ in 0..<120:
      let obs = rng.randomObsTextValue()
      let payload =
        "GET /h HTTP/1.1\r\n" &
        "Host: example.test\r\n" &
        "X-Obs: " & obs & "\r\n" &
        "\r\n"
      let parsed = parse(payload)
      check parsed.ok
      check parsed.parseError == false
      check parsed.totalRequestSize == payload.len

  test "framing mutators enforce TE/CL and chunked grammar":
    let badFraming = [
      (
        "POST /f HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n0\r\n\r\n",
        400
      ),
      (
        "POST /f HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: gzip\r\n\r\n",
        501
      ),
      (
        "POST /f HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked, chunked\r\n\r\n",
        400
      ),
      (
        "POST /f HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n",
        400
      ),
      (
        "POST /f HTTP/1.1\r\nHost: example.test\r\nContent-Length: +10\r\n\r\nabcdefghij",
        400
      ),
      (
        "POST /f HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nABCD",
        400
      ),
      (
        "POST /f HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\nabc\r\n0\r\n\r\n",
        400
      )
    ]

    for (payload, statusCode) in badFraming:
      let parsed = parse(payload)
      check parsed.ok == false
      check parsed.parseError
      check parsed.parseStatusCode == statusCode

  test "randomized noise mutations remain safe (no crash) and bounded":
    let base = "GET /safe HTTP/1.1\r\nHost: example.test\r\n\r\n"
    var rng = initRand(0x123456)
    for _ in 0..<500:
      var payload = base
      let edits = rng.rand(1..6)
      for _ in 0..<edits:
        let pos = rng.rand(0..payload.high)
        let mode = rng.rand(0..4)
        if mode == 0:
          payload[pos] = char(rng.rand(0..255))
        elif mode == 1:
          payload[pos] = ' '
        elif mode == 2:
          payload[pos] = '\t'
        elif mode == 3:
          payload[pos] = char(rng.rand(ord('A')..ord('Z')))
        else:
          payload[pos] = char(rng.rand(ord('0')..ord('9')))

      let parsed = parse(payload)
      if parsed.ok:
        check parsed.parseError == false
        check parsed.totalRequestSize <= payload.len
        check parsed.req.httpVersion in ["HTTP/1.0", "HTTP/1.1"]
      elif parsed.parseError:
        check parsed.parseStatusCode in AllowedErrorStatuses
