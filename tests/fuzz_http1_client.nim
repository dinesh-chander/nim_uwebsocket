import std/random
import ../nim_fasthttpclient/src/nim_fasthttpclient/http1

const
  Iterations = 10_000
  ProgressInterval = 1000

var rng = initRand(42)
var totalIterations = 0
var failures: seq[string]

proc fail(label, msg: string) =
  failures.add label & ": " & msg

proc randomBytes(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(255))

proc randomPrintable(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(93) + 33)

proc makeResponse(statusCode: int, statusText: string, headers: seq[(string, string)], body: string = ""): string =
  result = "HTTP/1.1 " & $statusCode & " " & statusText & "\r\n"
  for (k, v) in headers:
    result.add k & ": " & v & "\r\n"
  result.add "\r\n"
  result.add body

proc tryFeed(label: string, data: string) =
  try:
    var parser = initHttp1Parser()
    var consumed = 0
    discard parser.feedData(data, consumed)
  except CatchableError:
    discard
  except Defect as e:
    fail(label, "Defect: " & e.msg)

template fuzzCategory(name: string, iters: int, body: untyped) =
  echo "Category: ", name
  for i {.inject.} in 0 ..< iters:
    try:
      body
    except CatchableError:
      discard
    inc totalIterations
    if totalIterations mod ProgressInterval == 0:
      echo "  progress: ", totalIterations

echo "=== Fuzz HTTP/1.1 Client Parser ==="

fuzzCategory("Random response lines (malformed status lines)", Iterations):
  let variant = rng.rand(9)
  var raw: string
  case variant
  of 0: raw = "\r\n\r\n"
  of 1: raw = "HTTP/1.1\r\n\r\n"
  of 2: raw = "HTTP/1.1 \r\n\r\n"
  of 3: raw = "HTTP/1.1 abc OK\r\n\r\n"
  of 4: raw = randomPrintable(rng.rand(50)) & "\r\n\r\n"
  of 5: raw = "HTTP/9.9 200 OK\r\n\r\n"
  of 6: raw = "HTTP/1.1 999 " & randomPrintable(rng.rand(50)) & "\r\n\r\n"
  of 7: raw = "HTTP/1.0 200 OK\r\n\r\n"
  of 8: raw = "RTSP/1.0 200 OK\r\n\r\n"
  else: raw = randomBytes(rng.rand(100)) & "\r\n\r\n"
  tryFeed("malformed_status_" & $i, raw)

fuzzCategory("Truncated responses", Iterations):
  let full = makeResponse(200, "OK",
    @[("Content-Type", "text/html"), ("Content-Length", "13")], "Hello, World!")
  let cutPoint = rng.rand(full.len)
  tryFeed("truncated_" & $i, full[0 ..< cutPoint])

fuzzCategory("Chunked encoding edge cases", Iterations):
  let variant = rng.rand(6)
  var body: string
  case variant
  of 0:
    body = "FFFFFFFFFFF\r\ndata\r\n0\r\n\r\n"
  of 1:
    body = "-1\r\ndata\r\n0\r\n\r\n"
  of 2:
    let ext = randomPrintable(rng.rand(50))
    body = "5;" & ext & "\r\nhello\r\n0\r\n\r\n"
  of 3:
    body = "0\r\n\r\n"
  of 4:
    body = "5\r\nhello\r\n"
  of 5:
    let hexSize = randomPrintable(rng.rand(20) + 1)
    body = hexSize & "\r\ndata\r\n0\r\n\r\n"
  else:
    body = "5\r\nhello\r\n3\r\nbye\r\n0\r\n\r\n"
  let raw = makeResponse(200, "OK", @[("Transfer-Encoding", "chunked")], body)
  tryFeed("chunked_" & $i, raw)

fuzzCategory("Content-Length mismatches", Iterations):
  let clValue = rng.rand(1000)
  let bodyLen = rng.rand(200)
  let body = randomPrintable(bodyLen)
  let raw = makeResponse(200, "OK",
    @[("Content-Length", $clValue)], body)
  tryFeed("cl_mismatch_" & $i, raw)

fuzzCategory("Multiple Content-Length headers", Iterations):
  let cl1 = rng.rand(100)
  let cl2 = rng.rand(100)
  let body = randomPrintable(cl1)
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: " & $cl1 &
    "\r\nContent-Length: " & $cl2 & "\r\n\r\n" & body
  tryFeed("multi_cl_" & $i, raw)

fuzzCategory("Response splitting attempts", Iterations):
  let variant = rng.rand(3)
  var headerVal = randomPrintable(rng.rand(40) + 1)
  let injectPos = rng.rand(headerVal.high)
  let injection = case variant
    of 0: "\r\nEvil: injected\r\n"
    of 1: "\r\n\r\nHTTP/1.1 200 OK\r\n"
    of 2: "\nSet-Cookie: stolen=yes\r\n"
    else: "\r\n"
  headerVal.insert(injection, injectPos)
  let raw = makeResponse(200, "OK", @[("X-Fuzz", headerVal)])
  tryFeed("splitting_" & $i, raw)

fuzzCategory("Invalid header names/values", Iterations):
  let variant = rng.rand(4)
  var name, value: string
  case variant
  of 0:
    name = randomBytes(rng.rand(30) + 1)
    value = "ok"
  of 1:
    name = "X-Valid"
    value = randomBytes(rng.rand(100))
  of 2:
    name = ""
    value = "empty-name"
  of 3:
    name = "X-Null\0Header"
    value = "val\0ue"
  else:
    name = randomPrintable(rng.rand(50) + 1)
    value = randomPrintable(rng.rand(200))
  let raw = makeResponse(200, "OK", @[(name, value)])
  tryFeed("invalid_header_" & $i, raw)

fuzzCategory("Connection: close vs keep-alive handling", Iterations):
  let variant = rng.rand(4)
  var connVal: string
  case variant
  of 0: connVal = "close"
  of 1: connVal = "keep-alive"
  of 2: connVal = "Close"
  of 3: connVal = randomPrintable(rng.rand(20))
  else: connVal = "keep-alive, upgrade"
  let raw = makeResponse(200, "OK",
    @[("Connection", connVal), ("Content-Length", "5")], "hello")
  var parser = initHttp1Parser()
  var consumed = 0
  discard parser.feedData(raw, consumed)

fuzzCategory("Zero-length bodies", Iterations):
  let variant = rng.rand(2)
  var raw: string
  case variant
  of 0:
    raw = makeResponse(200, "OK", @[("Content-Length", "0")])
  of 1:
    raw = makeResponse(204, "No Content", @[])
  else:
    raw = makeResponse(304, "Not Modified", @[("Content-Length", "0")])
  var parser = initHttp1Parser()
  var consumed = 0
  let done = parser.feedData(raw, consumed)
  discard done

fuzzCategory("Very long header lines", Iterations):
  let headerLen = rng.rand(100_000) + 1000
  let longValue = randomPrintable(headerLen)
  let raw = makeResponse(200, "OK",
    @[("X-Long", longValue), ("Content-Length", "0")])
  tryFeed("long_header_" & $i, raw)

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All HTTP/1.1 client parser fuzz tests passed (", totalIterations, " total iterations)"
  quit(0)
