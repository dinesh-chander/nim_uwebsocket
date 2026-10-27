## End-to-end HTTP/1.1 parse benchmark: feedData over a realistic response,
## SSE2 findCrLf (default) vs portable (-d:nimHttp1CrlfPortable).
import std/[monotimes]
import nim_fasthttpclient/http1

# Build a realistic chunked JSON-ish response.
proc buildResponse(): string =
  result = "HTTP/1.1 200 OK\r\n"
  result.add "Content-Type: application/json\r\n"
  result.add "Transfer-Encoding: chunked\r\n"
  result.add "X-Request-Id: 0123456789abcdef\r\n"
  result.add "Connection: keep-alive\r\n"
  result.add "\r\n"
  # a few chunks
  for c in 0 ..< 8:
    result.add "1a2\r\n"
    result.add "{\"key" & $c & "\":\"value with some text \" & $c & \"\", \"n\":123}\r\n"
  result.add "0\r\n\r\n"

let resp = buildResponse()
const respLen = 0  # computed below

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

# warmup + correctness
var p = initHttp1Parser()
var consumed = 0
let done = p.feedData(resp, consumed)
doAssert(done, "parser should finish")
echo "parsed OK, body len=" & $p.response.body.len & " headers=" & $p.response.headers.len

const iters = 200_000
var t0 = nowMs()
var sink = 0
for i in 0 ..< iters:
  var pr = initHttp1Parser()
  var c = 0
  let d = pr.feedData(resp, c)
  if not d: raise newException(Exception, "parse failed")
  sink += pr.response.body.len
discard sink
let ns = nowMs() - t0
echo "http1 feedData: " & $iters & " parses in " & $ns & "ms  (" &
     $(ns.float64 * 1000.0 / iters.float64) & " us/parse)"
