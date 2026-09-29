import std/[random, strutils]
import ../nim_usockets/src/nim_usockets/http

when not defined(nimUwebsocketsTest):
  {.error: "Compile with -d:nimUwebsocketsTest".}

const
  Iterations = 10_000
  ProgressInterval = 1000

var rng = initRand(42)
var failures: seq[string]

proc hexDump(data: string): string =
  for i, c in data:
    if i > 0 and i mod 32 == 0: result.add "\n"
    result.add toHex(ord(c), 2) & " "

proc tryParse(label: string, raw: string) =
  try:
    let res = parseHttpRequestForTest(raw)
    if res.ok and res.parseError:
      failures.add label & ": ok=true but parseError=true\n" & hexDump(raw)
  except CatchableError:
    discard
  except Defect as e:
    failures.add label & ": Defect: " & e.msg & "\n" & hexDump(raw)

proc randomBytes(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(255))

proc randomPrintable(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(31) + 32)

proc randomMethod(): string =
  const methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "CONNECT", "TRACE"]
  methods[rng.rand(methods.high)]

proc randomPath(): string =
  let pathLen = rng.rand(200)
  result = "/"
  for i in 0 ..< pathLen:
    if rng.rand(10) == 0:
      result.add '/'
    else:
      result.add char(rng.rand(93) + 33)

proc makeRequest(meth, path, version: string, headers: seq[(string, string)], body: string = ""): string =
  result = meth & " " & path & " " & version & "\r\n"
  for (k, v) in headers:
    result.add k & ": " & v & "\r\n"
  result.add "\r\n"
  result.add body

echo "=== Fuzz HTTP Parser ==="

echo "--- Category 1: Random bytes as HTTP requests ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let data = randomBytes(rng.rand(2048))
  tryParse("random_bytes_" & $i, data)

echo "--- Category 2: Malformed request lines ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let variant = rng.rand(9)
  var raw: string
  case variant
  of 0: raw = "\r\n\r\n"
  of 1: raw = "GET\r\n\r\n"
  of 2: raw = "GET /\r\n\r\n"
  of 3: raw = " / HTTP/1.1\r\n\r\n"
  of 4: raw = "GET / \r\n\r\n"
  of 5: raw = randomPrintable(rng.rand(50)) & "\r\n\r\n"
  of 6: raw = "GET " & randomPrintable(rng.rand(100)) & " HTTP/1.1\r\n\r\n"
  of 7: raw = randomMethod() & " / HTTP/9.9\r\n\r\n"
  of 8: raw = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
  else: raw = "INVALID_METHOD / HTTP/1.1\r\nHost: x\r\n\r\n"
  tryParse("malformed_line_" & $i, raw)

echo "--- Category 3: CRLF injection in headers ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  var headerVal = randomPrintable(rng.rand(40) + 1)
  let injectPos = rng.rand(headerVal.high)
  let injection = case rng.rand(5)
    of 0: "\r\n"
    of 1: "\r\nEvil: injected\r\n"
    of 2: "\r\n\r\n"
    of 3: "\n"
    of 4: "\r"
    else: "\0"
  headerVal.insert(injection, injectPos)
  let raw = makeRequest("GET", "/", "HTTP/1.1",
    @[("Host", "test"), ("X-Fuzz", headerVal)])
  tryParse("crlf_inject_" & $i, raw)

echo "--- Category 4: Extremely long headers, paths, methods ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let variant = rng.rand(3)
  var raw: string
  case variant
  of 0:
    let longPath = "/" & 'A'.repeat(rng.rand(65536) + 1000)
    raw = makeRequest("GET", longPath, "HTTP/1.1", @[("Host", "x")])
  of 1:
    let longHeader = 'B'.repeat(rng.rand(65536) + 1000)
    raw = makeRequest("GET", "/", "HTTP/1.1", @[("Host", "x"), ("X-Big", longHeader)])
  of 2:
    let longMethod = 'C'.repeat(rng.rand(100) + 10)
    raw = makeRequest(longMethod, "/", "HTTP/1.1", @[("Host", "x")])
  else:
    var headers: seq[(string, string)]
    for j in 0 .. rng.rand(200) + 100:
      headers.add ("X-H-" & $j, "v" & $j)
    raw = makeRequest("GET", "/", "HTTP/1.1", headers)
  tryParse("long_" & $i, raw)

echo "--- Category 5: Content-Length edge cases ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let clValue = case rng.rand(9)
    of 0: "0"
    of 1: "-1"
    of 2: "99999999999999999999"
    of 3: "abc"
    of 4: ""
    of 5: " 5"
    of 6: "5 "
    of 7: "0x10"
    of 8: "+5"
    else: $rng.rand(10000)
  let body = 'X'.repeat(rng.rand(100))
  let raw = makeRequest("POST", "/", "HTTP/1.1",
    @[("Host", "x"), ("Content-Length", clValue)], body)
  tryParse("content_length_" & $i, raw)

echo "--- Category 6: Chunked encoding malformed ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  var body: string
  let numChunks = rng.rand(5)
  for j in 0 ..< numChunks:
    let chunkData = randomPrintable(rng.rand(100))
    let sizeStr = case rng.rand(4)
      of 0: toHex(chunkData.len)
      of 1: $chunkData.len
      of 2: "ZZZZZ"
      of 3: ""
      else: toHex(chunkData.len + rng.rand(100))
    body.add sizeStr & "\r\n" & chunkData & "\r\n"
  if rng.rand(1) == 0:
    body.add "0\r\n\r\n"
  let raw = makeRequest("POST", "/", "HTTP/1.1",
    @[("Host", "x"), ("Transfer-Encoding", "chunked")], body)
  tryParse("chunked_" & $i, raw)

echo "--- Category 7: Partial/truncated requests ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let full = makeRequest("POST", "/path?q=1", "HTTP/1.1",
    @[("Host", "example.com"), ("Content-Length", "13"), ("X-Custom", "value")],
    "Hello, World!")
  let cutPoint = rng.rand(full.len)
  let truncated = full[0 ..< cutPoint]
  tryParse("truncated_" & $i, truncated)

echo "--- Category 8: Request smuggling patterns ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let variant = rng.rand(5)
  var raw: string
  case variant
  of 0:
    raw = makeRequest("POST", "/", "HTTP/1.1",
      @[("Host", "x"), ("Content-Length", "5"), ("Transfer-Encoding", "chunked")],
      "0\r\n\r\n")
  of 1:
    raw = makeRequest("POST", "/", "HTTP/1.1",
      @[("Host", "x"), ("Content-Length", "5"), ("Content-Length", "10")],
      "hello")
  of 2:
    raw = makeRequest("POST", "/", "HTTP/1.1",
      @[("Host", "x"), ("Transfer-Encoding", "chunked"), ("Transfer-Encoding", "identity")],
      "5\r\nhello\r\n0\r\n\r\n")
  of 3:
    raw = makeRequest("POST", "/", "HTTP/1.1",
      @[("Host", "x"), ("Transfer-Encoding", " chunked")],
      "5\r\nhello\r\n0\r\n\r\n")
  of 4:
    raw = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n" &
          "Content-Length: 5\r\n\r\nGET /admin HTTP/1.1\r\nHost: x\r\n\r\n"
  else:
    raw = makeRequest("POST", "/", "HTTP/1.1",
      @[("Host", "x"), ("Content-Length", "0"), ("Transfer-Encoding", "chunked")],
      "")
  tryParse("smuggle_" & $i, raw)

echo "--- Category 9: Null bytes in headers and paths ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let variant = rng.rand(3)
  var raw: string
  case variant
  of 0:
    let path = "/foo\0bar"
    raw = makeRequest("GET", path, "HTTP/1.1", @[("Host", "x")])
  of 1:
    raw = makeRequest("GET", "/", "HTTP/1.1",
      @[("Host", "x"), ("X-Null", "val\0ue")])
  of 2:
    raw = makeRequest("GET", "/", "HTTP/1.1",
      @[("Host\0", "x")])
  else:
    raw = "GET /\0 HTTP/1.1\r\nHost: \0\r\n\r\n"
  tryParse("null_bytes_" & $i, raw)

echo "--- Category 10: Protocol confusion ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let variant = rng.rand(5)
  var raw: string
  case variant
  of 0: raw = "GET / HTTP/0.9\r\n\r\n"
  of 1: raw = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  of 2: raw = "GET / HTTP/3.0\r\n\r\n"
  of 3: raw = "GET / HTTP/1.0\r\nHost: x\r\n\r\n"
  of 4: raw = "GET / RTSP/1.0\r\n\r\n"
  else: raw = randomBytes(2) & " / HTTP/1." & $rng.rand(9) & "\r\nHost: x\r\n\r\n"
  tryParse("proto_confusion_" & $i, raw)

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All HTTP parser fuzz tests passed (", Iterations * 10, " total iterations)"
  quit(0)
