import std/[strutils]
import nim_fasthttpclient/http1

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

proc buildChunked(numChunks: int): string =
  ## Builds a chunked response of `numChunks` chunks, each 9 bytes of body.
  result = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
  for i in 1 .. numChunks:
    let payload = "body-" & align($i, 4, '0')
    result.add $payload.len
    result.add "\r\n"
    result.add payload
    result.add "\r\n"
  result.add "0\r\n\r\n"

proc buildChunkedWithTrailers(numChunks: int): string =
  result = buildChunked(numChunks)
  result.setLen result.len - 2
  for i in 1 .. 3:
    result.add "X-Trailer-" & $i & ": v" & $i & "\r\n"
  result.add "\r\n"

proc feedInChunks(msg: string, compact: bool, chunkSize: int, scanned: var int,
                  entries: var int, maxBufLen: var int,
                  parser: var Http1Parser): bool =
  ## Feeds `msg` to `parser` in segments of `chunkSize` bytes over a growable
  ## buffer, mirroring the client caller: when `compact` is set the buffer drops
  ## the range reported in `consumed`. `scanned` totals the bytes presented to
  ## the parser and `maxBufLen` the largest buffer ever scanned; both are the
  ## work counters that separate linear from quadratic parsing.
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

proc parseWhole(msg: string): Http1Parser =
  result = initHttp1Parser()
  var consumed = 0
  discard result.feedData(msg, consumed)

type Work = object
  scanned: int
  entries: int
  maxBufLen: int

echo "=== HTTP/1 chunked incremental feed tests ==="
echo ""

proc testChunkedEquivalence() =
  ## A chunked response fed byte-wise and in odd segments must produce the same
  ## result as a single whole-buffer feed, with the caller's compaction policy.
  for numChunks in [1, 8, 64]:
    for segment in [1, 7, 13]:
      let msg = buildChunked(numChunks)
      let whole = parseWhole(msg)
      var scanned = 0
      var entries = 0
      var maxBufLen = 0
      var seg: Http1Parser
      let finalized = feedInChunks(msg, true, segment, scanned, entries, maxBufLen, seg)
      check(finalized, "chunked equiv: " & $numChunks & " chunks x " & $segment &
            "B segments finalizes")
      check(whole.state == psDone, "chunked equiv: whole feed reaches psDone (" &
            $numChunks & " chunks)")
      check(seg.state == psDone, "chunked equiv: segmented feed reaches psDone (" &
            $numChunks & " chunks x " & $segment & "B)")
      check(seg.response.body == whole.response.body, "chunked equiv: bodies identical (" &
            $numChunks & " chunks x " & $segment & "B)")
      check(fingerprint(seg) == fingerprint(whole), "chunked equiv: full fingerprint (" &
            $numChunks & " chunks x " & $segment & "B)")
  echo "chunked segmented equivalence: OK"

proc testTrailersEquivalence() =
  ## Trailer fields arrive split across segments, so the trailer state must keep
  ## its partial line without forcing the caller to rescan it.
  for segment in [1, 5]:
    let msg = buildChunkedWithTrailers(16)
    let whole = parseWhole(msg)
    var scanned = 0
    var entries = 0
    var maxBufLen = 0
    var seg: Http1Parser
    let finalized = feedInChunks(msg, true, segment, scanned, entries, maxBufLen, seg)
    check(finalized and seg.state == psDone, "trailers equiv: segmented feed completes (" &
          $segment & "B segments)")
    check(seg.response.body == whole.response.body, "trailers equiv: bodies identical (" &
          $segment & "B segments)")
    check(fingerprint(seg) == fingerprint(whole), "trailers equiv: fingerprint (" &
          $segment & "B segments)")
  echo "chunked trailers equivalence: OK"

proc measure(msg: string, segment: int): Work =
  var parser: Http1Parser
  discard feedInChunks(msg, true, segment, result.scanned, result.entries,
                       result.maxBufLen, parser)

proc testNoQuadraticChunkedRescan() =
  ## Work-counter evidence, not timing: with compaction working, bytes presented
  ## to the parser must stay a small constant multiple of the message size as the
  ## chunk count grows. Quadratic re-scanning instead grows that multiple with n,
  ## heading for the 1+2+..+n reference cost.
  echo "chunks   n       quadRef(n*(n+1)/2)  scanned  scanned/n  maxBufLen"
  var ratios: array[3, float]
  var idx = 0
  for numChunks in [8, 64, 512]:
    let msg = buildChunked(numChunks)
    let n = msg.len
    let quadRef = n * (n + 1) div 2
    let work = measure(msg, 1)
    let ratio = float(work.scanned) / float(n)
    ratios[idx] = ratio
    inc idx
    echo $numChunks & repeat(" ", max(1, 9 - len($numChunks))) & $n &
         repeat(" ", max(1, 8 - len($n))) & $quadRef &
         repeat(" ", max(1, 20 - len($quadRef))) & $work.scanned &
         repeat(" ", max(1, 9 - len($work.scanned))) &
         formatFloat(ratio, ffDecimal, 2) &
         repeat(" ", max(1, 11 - len($work.maxBufLen))) & $work.maxBufLen
    check(work.scanned * 4 <= quadRef, "rescan: " & $numChunks &
          " chunks scanned far below quadratic cost")
    check(work.maxBufLen <= 64, "rescan: " & $numChunks &
          " chunks buffer rescanned stays within one chunk frame")
  let growth = ratios[2] / max(ratios[0], 1e-9)
  echo "scanned/n growth 8 -> 512 chunks: " & formatFloat(growth, ffDecimal, 2) & "x"
  check(growth <= 4.0, "rescan: work per byte stays constant as chunks grow (linear)")
  echo "no quadratic chunked rescan: OK"

testChunkedEquivalence()
testTrailersEquivalence()
testNoQuadraticChunkedRescan()

echo ""
echo "passed=", passed, " failed=", failed
if failed > 0:
  quit 1
