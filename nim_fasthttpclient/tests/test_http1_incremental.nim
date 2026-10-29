import std/[strutils, times]
import nim_fasthttpclient/http1

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

proc buildResponse(): string =
  result = "HTTP/1.1 200 OK\r\n"
  for i in 1 .. 40:
    result.add "X-Hdr-" & $i & ": value-" & $i & "\r\n"
  result.add "Content-Length: 21\r\n"
  result.add "\r\n"
  result.add "hello segmented world"

proc parseWhole(msg: string): Http1Parser =
  result = initHttp1Parser()
  var consumed = 0
  discard result.feedData(msg, consumed)

proc feedInChunks(msg: string, compact: bool, chunkSize: int, scanned: var int,
                  entries: var int, maxBufLen: var int,
                  parser: var Http1Parser): bool =
  ## Feeds `msg` to `parser` in chunks of `chunkSize` bytes over a growable
  ## buffer, returning whether the parse finalized. When `compact` is set the
  ## buffer drops the range reported in `consumed`, mirroring the client caller.
  ## `scanned` totals the bytes presented to the parser, `entries` the parser
  ## entries and `maxBufLen` the largest buffer ever scanned, which is the
  ## re-scan signal: without compaction it grows with the whole header block.
  parser = initHttp1Parser()
  var buf = ""
  var i = 0
  while i < msg.len:
    let stop = min(i + chunkSize, msg.len)
    while i < stop:
      buf.add msg[i]
      inc i
    var consumed = 0
    inc entries
    scanned += buf.len
    maxBufLen = max(maxBufLen, buf.len)
    result = parser.feedData(buf, consumed)
    if compact and consumed > 0:
      if consumed < buf.len:
        buf.delete(0 .. consumed - 1)
      else:
        buf.setLen(0)
    if result:
      return

proc fingerprint(p: Http1Parser): string =
  result.add $p.response.statusCode
  result.add "|"
  result.add p.response.statusText
  result.add "|"
  for h in p.response.headers:
    result.add h.name
    result.add "="
    result.add h.value
    result.add ";"
  result.add "|"
  result.add p.response.body
  result.add "|"
  result.add $p.state
  result.add "|"
  result.add $p.keepAlive

echo "=== HTTP/1 incremental feed tests ==="
echo ""

proc testSegmentedEquivalence() =
  let msg = buildResponse()
  let whole = parseWhole(msg)
  var scanned = 0
  var entries = 0
  var maxBufLen = 0
  var seg: Http1Parser
  check(feedInChunks(msg, true, 1, scanned, entries, maxBufLen, seg),
        "segmented: byte-wise parse finalizes")
  check(whole.state == psDone, "segmented: whole-buffer parse completes")
  check(seg.state == psDone, "segmented: byte-wise parse reaches psDone")
  check(seg.response.headers.len == 41, "segmented: 41 headers parsed byte-wise")
  check(fingerprint(seg) == fingerprint(whole),
        "segmented: status, headers, body, state, keepAlive identical to whole feed")
  echo "segmented equivalence: OK"

proc testConsumedRecordsProgress() =
  var p = initHttp1Parser()
  let prefix = "HTTP/1.1 200 OK\r\nX-A: 1\r\nX-B: 2\r\nX-C: inc"
  var consumed = 0
  let done = p.feedData(prefix, consumed)
  check(done == false, "consumed: incomplete input is not done")
  check(consumed == prefix.len - 8, "consumed: stops at start of incomplete header line")
  check(p.state == psHeaders, "consumed: parser remains in psHeaders")
  var q = initHttp1Parser()
  var qConsumed = 0
  discard q.feedData("HTTP/1.1 200 incom", qConsumed)
  check(qConsumed == 0, "consumed: incomplete status line reports zero progress")
  check(q.state == psStatusLine, "consumed: parser remains in psStatusLine")
  echo "consumed progress accounting: OK"

proc testNoQuadraticRescan() =
  ## Method: direct work counters. `scanned` is the total bytes presented to the
  ## parser and `maxBufLen` the largest buffer it ever rescans from index 0. The
  ## old policy reported consumed = 0 on incomplete lines, so the caller dropped
  ## nothing and every entry rescanned the whole accumulated block: byte-wise
  ## that is the 1 + 2 + .. + n reference cost. A bounded maxBufLen plus a
  ## scanned total near n proves the rescan is gone.
  let msg = buildResponse()
  var scanned = 0
  var entries = 0
  var maxBufLen = 0
  var p: Http1Parser
  discard feedInChunks(msg, true, 1, scanned, entries, maxBufLen, p)
  let n = msg.len
  let quadraticRef = n * (n + 1) div 2
  echo "message bytes n=" & $n
  echo "byte-wise with compaction: scanned=" & $scanned & " entries=" & $entries &
       " maxBufLen=" & $maxBufLen
  echo "no-compaction reference 1+2+..+n: " & $quadraticRef & " bytes"
  echo "reference / measured scanned: " &
       $(float(quadraticRef) / max(float(scanned), 1.0))
  check(maxBufLen <= 64, "rescan: buffer rescanned per entry stays within one line")
  check(scanned * 4 <= quadraticRef, "rescan: byte count is far below quadratic cost")
  var chunkScanned = 0
  var chunkEntries = 0
  var chunkMaxBuf = 0
  var pc: Http1Parser
  check(feedInChunks(msg, true, n div 2, chunkScanned, chunkEntries, chunkMaxBuf, pc) and
        pc.state == psDone, "rescan: two-chunk feed also completes")
  echo "two-chunk feed: scanned=" & $chunkScanned & " entries=" & $chunkEntries &
       " maxBufLen=" & $chunkMaxBuf
  let byteWiseSec = cpuTime()
  var burn: Http1Parser
  for _ in 1 .. 200:
    var dummyScanned = 0
    var dummyEntries = 0
    var dummyMaxBuf = 0
    discard feedInChunks(msg, true, 1, dummyScanned, dummyEntries, dummyMaxBuf, burn)
  let byteWiseMs = cpuTime() - byteWiseSec
  echo "timing 200 byte-wise feeds: " & $(byteWiseMs * 1000.0) & " ms"
  echo "no quadratic rescan: OK"

proc testOversizedGuards() =
  var big = "HTTP/1.1 200 OK\r\nX-Big: "
  for _ in 1 .. 9000:
    big.add 'b'
  big.add "\r\n\r\n"
  var whole = initHttp1Parser()
  var wholeConsumed = 0
  discard whole.feedData(big, wholeConsumed)
  check(whole.state == psError, "guards: oversized header line errors on whole feed")
  var incremental = initHttp1Parser()
  var buf = ""
  var hitError = false
  for i in 0 ..< big.len:
    buf.add big[i]
    var consumed = 0
    discard incremental.feedData(buf, consumed)
    if consumed > 0 and consumed <= buf.len:
      buf.delete(0 .. consumed - 1)
    if incremental.state == psError:
      hitError = true
      break
  check(hitError, "guards: oversized header line errors on byte-wise feed")
  var statusLine = "HTTP/1.1 200 "
  for _ in 1 .. 1200:
    statusLine.add 'z'
  var statusParser = initHttp1Parser()
  var statusBuf = ""
  var statusError = false
  for i in 0 ..< statusLine.len:
    statusBuf.add statusLine[i]
    var consumed = 0
    discard statusParser.feedData(statusBuf, consumed)
    if consumed > 0 and consumed <= statusBuf.len:
      statusBuf.delete(0 .. consumed - 1)
    if statusParser.state == psError:
      statusError = true
      break
  check(statusError, "guards: oversized status line errors on byte-wise feed")
  echo "oversized-header guards: OK"

testSegmentedEquivalence()
testConsumedRecordsProgress()
testNoQuadraticRescan()
testOversizedGuards()

echo ""
echo "passed=", passed, " failed=", failed
if failed > 0:
  quit 1
