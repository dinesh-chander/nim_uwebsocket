import std/[monotimes, times, strutils, strformat]
import ../nim_usockets/src/nim_usockets/hpack

const MinDurationNs = 1_000_000_000'i64
const MinIterations = 100_000

type BenchResult = object
  name: string
  iterations: int
  totalNs: int64
  nsPerOp: float64
  opsPerSec: float64

proc bench(name: string, body: proc()) : BenchResult =
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
  echo fmt"  {padded:<40s} {formatOps(r.opsPerSec):>10s} ops/sec  ({r.nsPerOp:.1f} ns/op)  [{r.iterations} iters]"

let requestHeaders = @[
  (":method", "GET"),
  (":path", "/api/v2/users/12345/profile"),
  (":scheme", "https"),
  (":authority", "api.example.com"),
  ("accept", "application/json"),
  ("accept-encoding", "gzip, deflate, br"),
  ("accept-language", "en-US,en;q=0.9"),
  ("authorization", "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"),
  ("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"),
  ("cookie", "session=abc123def456; tracking=xyz789"),
]

let responseHeaders = @[
  (":status", "200"),
  ("content-type", "application/json; charset=utf-8"),
  ("content-length", "1842"),
  ("cache-control", "private, max-age=0, no-cache"),
  ("etag", "\"W/5d4a2f8b\""),
  ("x-request-id", "req-a1b2c3d4-e5f6-7890"),
  ("strict-transport-security", "max-age=31536000; includeSubDomains"),
  ("server", "nim-uwebsocket/1.0"),
  ("date", "Sat, 11 Apr 2026 12:00:00 GMT"),
  ("vary", "Accept-Encoding"),
]

let shortStr = "localhost"
let mediumStr = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)"
let longStr = "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWV9.signature_data_here_padding_to_reach_256_chars_" & "x".repeat(60)

var encodedReqBlock: string
var encodedRespBlock: string
block:
  var enc = initHpackEncoder(huffman = true)
  encodedReqBlock = newStringOfCap(512)
  enc.hpackEncode(requestHeaders, encodedReqBlock)
block:
  var enc = initHpackEncoder(huffman = true)
  encodedRespBlock = newStringOfCap(512)
  enc.hpackEncode(responseHeaders, encodedRespBlock)

let encodedShort = huffmanEncodeStr(shortStr)
let encodedMedium = huffmanEncodeStr(mediumStr)
let encodedLong = huffmanEncodeStr(longStr)

echo ""
echo "HPACK Micro-Benchmarks"
echo "======================"
echo fmt"  Platform: macOS ARM64 | Nim {NimVersion}"
echo fmt"  Min duration: {MinDurationNs div 1_000_000}ms | Min iterations: {MinIterations}"
echo ""

echo "--- Full HPACK Encode ---"

report bench("hpackEncode req (10 headers)", proc() =
  var enc = initHpackEncoder(huffman = true)
  var buf = newStringOfCap(256)
  enc.hpackEncode(requestHeaders, buf)
)

report bench("hpackEncode resp (10 headers)", proc() =
  var enc = initHpackEncoder(huffman = true)
  var buf = newStringOfCap(256)
  enc.hpackEncode(responseHeaders, buf)
)

report bench("hpackEncode req reuse encoder", proc() =
  var enc {.global.} = initHpackEncoder(huffman = true)
  var buf = newStringOfCap(256)
  enc.hpackEncode(requestHeaders, buf)
)

echo ""
echo "--- Full HPACK Decode ---"

let reqBytes = cast[seq[byte]](encodedReqBlock)
let respBytes = cast[seq[byte]](encodedRespBlock)

report bench("hpackDecode req (10 headers)", proc() =
  var dec = initHpackDecoder()
  discard dec.hpackDecode(reqBytes)
)

report bench("hpackDecode resp (10 headers)", proc() =
  var dec = initHpackDecoder()
  discard dec.hpackDecode(respBytes)
)

echo ""
echo "--- Huffman String Encode ---"

let shortBytes = cast[seq[byte]](shortStr)
let mediumBytes = cast[seq[byte]](mediumStr)
let longBytes = cast[seq[byte]](longStr)

report bench(fmt"huffmanEncode short ({shortStr.len}B)", proc() =
  var buf = newStringOfCap(shortStr.len)
  huffmanEncode(shortBytes, buf)
)

report bench(fmt"huffmanEncode medium ({mediumStr.len}B)", proc() =
  var buf = newStringOfCap(mediumStr.len)
  huffmanEncode(mediumBytes, buf)
)

report bench(fmt"huffmanEncode long ({longStr.len}B)", proc() =
  var buf = newStringOfCap(longStr.len)
  huffmanEncode(longBytes, buf)
)

echo ""
echo "--- Huffman String Decode ---"

let encShortBytes = cast[seq[byte]](encodedShort)
let encMediumBytes = cast[seq[byte]](encodedMedium)
let encLongBytes = cast[seq[byte]](encodedLong)

report bench(fmt"huffmanDecode short ({encodedShort.len}B->{ shortStr.len}B)", proc() =
  var buf = newStringOfCap(shortStr.len)
  huffmanDecode(encShortBytes, buf)
)

report bench(fmt"huffmanDecode medium ({encodedMedium.len}B->{mediumStr.len}B)", proc() =
  var buf = newStringOfCap(mediumStr.len)
  huffmanDecode(encMediumBytes, buf)
)

report bench(fmt"huffmanDecode long ({encodedLong.len}B->{longStr.len}B)", proc() =
  var buf = newStringOfCap(longStr.len)
  huffmanDecode(encLongBytes, buf)
)

echo ""
echo "--- hpackEncodeString (Huffman path) ---"

report bench(fmt"hpackEncodeString short ({shortStr.len}B)", proc() =
  var buf = newStringOfCap(32)
  hpackEncodeString(buf, shortStr, true)
)

report bench(fmt"hpackEncodeString medium ({mediumStr.len}B)", proc() =
  var buf = newStringOfCap(128)
  hpackEncodeString(buf, mediumStr, true)
)

report bench(fmt"hpackEncodeString long ({longStr.len}B)", proc() =
  var buf = newStringOfCap(256)
  hpackEncodeString(buf, longStr, true)
)

echo ""
echo "--- Dynamic Table Insert + Eviction ---"

report bench("dynTable insert (no eviction)", proc() =
  var dt = initHpackDynamicTable(4096)
  dt.add("x-custom-header", "some-value")
)

report bench("dynTable 20 inserts + evictions", proc() =
  var dt = initHpackDynamicTable(256)
  for i in 0 ..< 20:
    dt.add("x-header-" & $i, "value-" & $i)
)

report bench("dynTable lookup (16 entries)", proc() =
  var dt {.global.} = initHpackDynamicTable(4096)
  var populated {.global.} = false
  if not populated:
    for i in 0 ..< 16:
      dt.add("x-header-" & $i, "value-" & $i)
    populated = true
  discard dt.lookup("x-header-8", "value-8")
)

echo ""
echo "--- Integer Encoding/Decoding ---"

report bench("hpackEncodeInt (small, 7-bit)", proc() =
  var buf = newStringOfCap(8)
  hpackEncodeInt(buf, 42, 7, 0x00)
)

report bench("hpackEncodeInt (large, 7-bit)", proc() =
  var buf = newStringOfCap(8)
  hpackEncodeInt(buf, 100000, 7, 0x00)
)

let smallIntBuf = block:
  var b = newStringOfCap(8)
  hpackEncodeInt(b, 42, 7, 0x00)
  cast[seq[byte]](b)

let largeIntBuf = block:
  var b = newStringOfCap(8)
  hpackEncodeInt(b, 100000, 7, 0x00)
  cast[seq[byte]](b)

report bench("hpackDecodeInt (small, 7-bit)", proc() =
  var pos = 0
  discard hpackDecodeInt(smallIntBuf, pos, 7)
)

report bench("hpackDecodeInt (large, 7-bit)", proc() =
  var pos = 0
  discard hpackDecodeInt(largeIntBuf, pos, 7)
)

echo ""
echo "--- Static Table Lookup ---"

report bench("lookupStatic (exact match)", proc() =
  discard lookupStatic(":method", "GET")
)

report bench("lookupStatic (name-only match)", proc() =
  discard lookupStatic("content-type", "text/html")
)

report bench("lookupStatic (miss)", proc() =
  discard lookupStatic("x-custom-header", "value")
)

echo ""
echo "Done."
