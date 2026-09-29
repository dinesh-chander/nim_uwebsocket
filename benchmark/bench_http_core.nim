import std/[monotimes, times, strutils, strformat]
import ../nim_usockets/src/nim_usockets/http

const MinDurationNs = 1_000_000_000'i64
const MinIterations = 100_000

type BenchResult = object
  name: string
  iterations: int
  totalNs: int64
  nsPerOp: float64
  opsPerSec: float64

proc bench(name: string, body: proc()): BenchResult =
  for _ in 0 ..< 5000:
    body()

  var iterations = 0
  let start = getMonoTime()
  var elapsed: int64 = 0
  while elapsed < MinDurationNs or iterations < MinIterations:
    body()
    inc iterations
    elapsed = (getMonoTime() - start).inNanoseconds
  let nsOp = float64(elapsed) / float64(iterations)
  BenchResult(
    name: name,
    iterations: iterations,
    totalNs: elapsed,
    nsPerOp: nsOp,
    opsPerSec: 1e9 / nsOp
  )

proc formatOps(ops: float64): string =
  if ops >= 1e6:
    fmt"{ops / 1e6:.2f}M"
  elif ops >= 1e3:
    fmt"{ops / 1e3:.2f}K"
  else:
    fmt"{ops:.2f}"

proc report(r: BenchResult) =
  let padded = r.name & ":"
  echo fmt"  {padded:<45s} {formatOps(r.opsPerSec):>10s} ops/sec  ({r.nsPerOp:.1f} ns/op)  [{r.iterations} iters]"

const
  TokenCharTable: array[256, bool] = block:
    var arr: array[256, bool]
    for c in byte('0')..byte('9'):
      arr[c] = true
    for c in byte('A')..byte('Z'):
      arr[c] = true
    for c in byte('a')..byte('z'):
      arr[c] = true
    for ch in "!#$%&'*+-.^_`|~":
      arr[byte(ch)] = true
    arr

  ValidHeaderValueByteTable: array[256, bool] = block:
    var t: array[256, bool]
    t[0x09] = true
    for i in 0x20..0x7E: t[i] = true
    for i in 0x80..0xFF: t[i] = true
    t

  DigitPairs: array[200, char] = block:
    var arr: array[200, char]
    for i in 0..99:
      arr[i * 2] = char(ord('0') + i div 10)
      arr[i * 2 + 1] = char(ord('0') + i mod 10)
    arr

  DayAbbrevs = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  MonAbbrevs = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

proc fastIntToStr(n: int, buf: var string) {.inline.} =
  if n == 0:
    buf.add('0')
    return
  var num = n.int64
  if num < 0:
    buf.add('-')
    if num == low(int64):
      buf.add("9223372036854775808")
      return
    num = -num
  var tmp: array[24, char]
  var p = 24
  while num >= 100:
    let idx = int(num mod 100) * 2
    num = num div 100
    dec p; tmp[p] = DigitPairs[idx + 1]
    dec p; tmp[p] = DigitPairs[idx]
  if num >= 10:
    let idx = int(num) * 2
    dec p; tmp[p] = DigitPairs[idx + 1]
    dec p; tmp[p] = DigitPairs[idx]
  else:
    dec p; tmp[p] = char(ord('0') + int(num))
  let count = 24 - p
  let at = buf.len
  buf.setLen(at + count)
  copyMem(addr buf[at], addr tmp[p], count)

proc stdlibIntToStr(n: int, buf: var string) {.inline, noinline.} =
  buf.add($n)

proc formatDateHeaderLine(epochSec: int64): string =
  let dt = fromUnix(epochSec).utc
  result = newStringOfCap(44)
  result.add("date: ")
  result.add(DayAbbrevs[ord(dt.weekday)])
  result.add(", ")
  let d = dt.monthday
  result.add(char(ord('0') + d div 10))
  result.add(char(ord('0') + d mod 10))
  result.add(' ')
  result.add(MonAbbrevs[ord(dt.month) - 1])
  result.add(' ')
  let y = dt.year
  result.add(char(ord('0') + y div 1000))
  result.add(char(ord('0') + (y div 100) mod 10))
  result.add(char(ord('0') + (y div 10) mod 10))
  result.add(char(ord('0') + y mod 10))
  result.add(' ')
  let h = dt.hour
  result.add(char(ord('0') + h div 10))
  result.add(char(ord('0') + h mod 10))
  result.add(':')
  let m = dt.minute
  result.add(char(ord('0') + m div 10))
  result.add(char(ord('0') + m mod 10))
  result.add(':')
  let sec = dt.second
  result.add(char(ord('0') + sec div 10))
  result.add(char(ord('0') + sec mod 10))
  result.add(" GMT\r\n")

proc hasValidHeaderName(key: string): bool {.inline.} =
  if key.len == 0:
    return false
  var i = 0
  while i < key.len:
    if not TokenCharTable[byte(key[i])]:
      return false
    inc i
  true

proc hasValidHeaderValueBytes(data: openArray[byte], startPos: int, endPos: int): bool {.inline.} =
  var i = startPos
  while i < endPos:
    if not ValidHeaderValueByteTable[data[i]]:
      return false
    inc i
  true

proc swarHasZeroByte(v: uint64): bool {.inline.} =
  ((v - 0x0101010101010101'u64) and (not v) and 0x8080808080808080'u64) != 0

proc swarHasByte(v: uint64, needle: byte): bool {.inline.} =
  let broadcast = needle.uint64 * 0x0101010101010101'u64
  swarHasZeroByte(v xor broadcast)

proc swarFindByte(data: openArray[byte], startPos, endPos: int, needle: byte): int {.inline.} =
  var i = startPos
  when sizeof(pointer) >= 8:
    let baseAddr = cast[uint](unsafeAddr data[0])
    while i + 8 <= endPos:
      var word: uint64
      copyMem(addr word, cast[pointer](baseAddr + uint(i)), 8)
      if swarHasByte(word, needle):
        for j in 0 .. 7:
          if i + j < endPos and data[i + j] == needle:
            return i + j
      i += 8
  while i < endPos:
    if data[i] == needle:
      return i
    inc i
  -1

proc naiveFindByte(data: openArray[byte], startPos, endPos: int, needle: byte): int {.inline.} =
  var i = startPos
  while i < endPos:
    if data[i] == needle:
      return i
    inc i
  -1

proc parseSingleContentLengthValue(data: openArray[byte], startPos, endPos: int, contentLength: var int): bool {.inline.} =
  var i = startPos
  while i < endPos and (data[i] == byte(' ') or data[i] == byte('\t')):
    inc i
  if i >= endPos:
    return false
  var last = endPos - 1
  while last >= i and (data[last] == byte(' ') or data[last] == byte('\t')):
    dec last
  if last < i:
    return false
  let digitCount = last - i + 1
  if digitCount > 18:
    return false
  var parsed = 0
  var idx = i
  while idx <= last:
    let d = int(data[idx]) - ord('0')
    if d < 0 or d > 9:
      return false
    parsed = parsed * 10 + d
    inc idx
  if parsed < 0:
    return false
  contentLength = parsed
  true

proc parseContentLengthBytes(data: openArray[byte], startPos, endPos: int, contentLength: var int): bool {.inline.} =
  var firstValue = -1
  var pos = startPos
  while pos < endPos:
    var elemEnd = pos
    while elemEnd < endPos and data[elemEnd] != byte(','):
      inc elemEnd
    var parsed = 0
    if not parseSingleContentLengthValue(data, pos, elemEnd, parsed):
      return false
    if firstValue < 0:
      firstValue = parsed
    elif parsed != firstValue:
      return false
    pos = elemEnd + 1
  if firstValue < 0:
    return false
  contentLength = firstValue
  true

proc parseChunkSizeLine(data: openArray[byte], startPos, endPos: int, chunkSize: var int): bool {.inline.} =
  var i = startPos
  if i >= endPos:
    return false
  var hexEnd = i
  while hexEnd < endPos and data[hexEnd] != byte(';'):
    inc hexEnd
  var last = hexEnd - 1
  while last >= i and (data[last] == byte(' ') or data[last] == byte('\t')):
    dec last
  if last < i:
    return false
  var parsed = 0
  var idx = i
  while idx <= last:
    let c = char(data[idx])
    var digit = -1
    if c >= '0' and c <= '9':
      digit = ord(c) - ord('0')
    elif c >= 'a' and c <= 'f':
      digit = ord(c) - ord('a') + 10
    elif c >= 'A' and c <= 'F':
      digit = ord(c) - ord('A') + 10
    else:
      return false
    if parsed > (high(int) - digit) div 16:
      return false
    parsed = parsed * 16 + digit
    inc idx
  chunkSize = parsed
  true

proc buildProtocolErrorResponse(statusCode: int, body: string, closeConnection: bool): string =
  let safeStatus =
    if statusCode >= 100 and statusCode <= 999:
      statusCode
    else:
      400
  result = newStringOfCap(200 + body.len)
  result.add("HTTP/1.1 ")
  fastIntToStr(safeStatus, result)
  result.add(" ")
  case safeStatus
  of 200: result.add("OK")
  of 400: result.add("Bad Request")
  of 404: result.add("Not Found")
  of 500: result.add("Internal Server Error")
  else: result.add("Unknown")
  result.add("\r\n")
  result.add(formatDateHeaderLine(getTime().toUnix))
  if safeStatus != 204:
    result.add("content-length: ")
    fastIntToStr(body.len, result)
    result.add("\r\n")
  if closeConnection:
    result.add("connection: close\r\n")
  else:
    result.add("connection: keep-alive\r\n")
  result.add("\r\n")
  if body.len > 0 and safeStatus >= 200:
    result.add(body)

const
  GetRequest = "GET /api/v1/users/12345 HTTP/1.1\r\nHost: example.com\r\nAccept: application/json\r\nAccept-Encoding: gzip, deflate\r\nConnection: keep-alive\r\nUser-Agent: BenchClient/1.0\r\n\r\n"
  PostRequest = "POST /api/v1/data HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\nContent-Length: 27\r\nAccept: application/json\r\nConnection: keep-alive\r\n\r\n{\"key\":\"value\",\"count\":42}"

  HeaderNameGood = "x-custom-request-id"
  HeaderNameBad = "x-custom request-id"
  HeaderValueGood = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
  HeaderValueBad = "some\x00value"

  ContentLengthSimple = "1842"
  ContentLengthMulti = "1842, 1842, 1842"

  ChunkSizeSmall = "1a"
  ChunkSizeLarge = "1fff;ext=val"

  SwarHaystack128 = "This is a test string that is moderately long for SWAR byte-search benchmarking purposes. We want at least 128 bytes of data!!"
  SwarHaystack256 = SwarHaystack128 & SwarHaystack128

var getReqBytes: seq[byte]
var postReqBytes: seq[byte]
var clSimpleBytes: seq[byte]
var clMultiBytes: seq[byte]
var chunkSmallBytes: seq[byte]
var chunkLargeBytes: seq[byte]
var swarBytes128: seq[byte]
var swarBytes256: seq[byte]
var headerValGoodBytes: seq[byte]
var headerValBadBytes: seq[byte]

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

getReqBytes = toBytes(GetRequest)
postReqBytes = toBytes(PostRequest)
clSimpleBytes = toBytes(ContentLengthSimple)
clMultiBytes = toBytes(ContentLengthMulti)
chunkSmallBytes = toBytes(ChunkSizeSmall)
chunkLargeBytes = toBytes(ChunkSizeLarge)
swarBytes128 = toBytes(SwarHaystack128)
swarBytes256 = toBytes(SwarHaystack256)
headerValGoodBytes = toBytes(HeaderValueGood)
headerValBadBytes = toBytes(HeaderValueBad)

echo ""
echo "HTTP Core Benchmarks"
echo "===================="
echo fmt"  Platform: macOS ARM64 | Nim {NimVersion}"
echo fmt"  Min duration: {MinDurationNs div 1_000_000}ms | Min iterations: {MinIterations}"
echo ""

echo "--- Integer to String (digit-pair table) ---"

report bench("fastIntToStr (200)", proc() =
  var buf = newStringOfCap(16)
  fastIntToStr(200, buf)
)

report bench("fastIntToStr (12345)", proc() =
  var buf = newStringOfCap(16)
  fastIntToStr(12345, buf)
)

report bench("fastIntToStr (1234567890)", proc() =
  var buf = newStringOfCap(16)
  fastIntToStr(1234567890, buf)
)

report bench("stdlib $int (200)", proc() =
  var buf = newStringOfCap(16)
  stdlibIntToStr(200, buf)
)

report bench("stdlib $int (12345)", proc() =
  var buf = newStringOfCap(16)
  stdlibIntToStr(12345, buf)
)

report bench("stdlib $int (1234567890)", proc() =
  var buf = newStringOfCap(16)
  stdlibIntToStr(1234567890, buf)
)

echo ""
echo "--- Date Header Formatting ---"

let nowEpoch = getTime().toUnix

report bench("formatDateHeaderLine", proc() =
  discard formatDateHeaderLine(nowEpoch)
)

report bench("formatDateHeaderLine (varying)", proc() =
  var ts {.global.} = getTime().toUnix
  discard formatDateHeaderLine(ts)
  inc ts
)

echo ""
echo "--- HTTP Request Parsing (full pipeline) ---"

report bench("parseHttpRequestForTest (GET 5hdr)", proc() =
  discard parseHttpRequestForTest(GetRequest)
)

report bench("parseHttpRequestForTest (POST 5hdr)", proc() =
  discard parseHttpRequestForTest(PostRequest)
)

echo ""
echo "--- Header Name Validation (TokenCharTable) ---"

report bench("tokenCharValidation valid (19B)", proc() =
  discard hasValidHeaderName(HeaderNameGood)
)

report bench("tokenCharValidation invalid (19B)", proc() =
  discard hasValidHeaderName(HeaderNameBad)
)

echo ""
echo "--- Header Value Validation (ValidHeaderValueByteTable) ---"

report bench("headerValueValidation valid (67B)", proc() =
  discard hasValidHeaderValueBytes(headerValGoodBytes, 0, headerValGoodBytes.len)
)

report bench("headerValueValidation invalid (10B)", proc() =
  discard hasValidHeaderValueBytes(headerValBadBytes, 0, headerValBadBytes.len)
)

echo ""
echo "--- Content-Length Parsing ---"

report bench("parseContentLength simple (1842)", proc() =
  var cl = 0
  discard parseContentLengthBytes(clSimpleBytes, 0, clSimpleBytes.len, cl)
)

report bench("parseContentLength multi (1842,1842,1842)", proc() =
  var cl = 0
  discard parseContentLengthBytes(clMultiBytes, 0, clMultiBytes.len, cl)
)

echo ""
echo "--- Chunk Size Parsing ---"

report bench("parseChunkSizeLine small (1a)", proc() =
  var cs = 0
  discard parseChunkSizeLine(chunkSmallBytes, 0, chunkSmallBytes.len, cs)
)

report bench("parseChunkSizeLine large+ext (1fff;ext=val)", proc() =
  var cs = 0
  discard parseChunkSizeLine(chunkLargeBytes, 0, chunkLargeBytes.len, cs)
)

echo ""
echo "--- Response Building ---"

report bench("buildProtocolErrorResponse (200 OK)", proc() =
  discard buildProtocolErrorResponse(200, "", false)
)

report bench("buildProtocolErrorResponse (400+body)", proc() =
  discard buildProtocolErrorResponse(400, "Bad Request", true)
)

echo ""
echo "--- SWAR Byte Search ---"

report bench("swarFindByte 128B (found@end)", proc() =
  discard swarFindByte(swarBytes128, 0, swarBytes128.len, byte('!'))
)

report bench("swarFindByte 256B (found@end)", proc() =
  discard swarFindByte(swarBytes256, 0, swarBytes256.len, byte('!'))
)

report bench("swarFindByte 128B (not found)", proc() =
  discard swarFindByte(swarBytes128, 0, swarBytes128.len, byte('@'))
)

report bench("naiveFindByte 128B (found@end)", proc() =
  discard naiveFindByte(swarBytes128, 0, swarBytes128.len, byte('!'))
)

report bench("naiveFindByte 256B (found@end)", proc() =
  discard naiveFindByte(swarBytes256, 0, swarBytes256.len, byte('!'))
)

report bench("naiveFindByte 128B (not found)", proc() =
  discard naiveFindByte(swarBytes128, 0, swarBytes128.len, byte('@'))
)

echo ""
echo "Done."
