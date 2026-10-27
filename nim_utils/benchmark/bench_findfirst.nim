## Find-first-delimiter benchmark (request.nim header-token pattern):
## SSE2 (nimsimd) find-first-of {',',' ','\t'} vs scalar, on realistic header values.
import std/[monotimes]
when hostCPU == "amd64" or hostCPU == "i386":
  import nimsimd/sse2

proc findDelimScalar(s: string): int =
  for i in 0 ..< s.len:
    if s[i] == ',' or s[i] == ' ' or s[i] == '\t':
      return i
  -1

when hostCPU == "amd64" or hostCPU == "i386":
  proc findDelimSse2(s: string): int =
    var i = 0
    let n = s.len
    while i + 16 <= n:
      let v = mm_loadu_si128(cast[ptr uint64](unsafeAddr s[i]))
      let m = mm_or_si128(
        mm_or_si128(mm_cmpeq_epi8(v, mm_set1_epi8(44.uint8)),   # ,
                    mm_cmpeq_epi8(v, mm_set1_epi8(32.uint8))),  # space
                   mm_cmpeq_epi8(v, mm_set1_epi8(9.uint8)))     # tab
      var k = mm_movemask_epi8(m)
      if k != 0:
        var b = 0
        while (k and 1) == 0: k = k shr 1; inc b
        return i + b
      i += 16
    while i < n:
      if s[i] == ',' or s[i] == ' ' or s[i] == '\t': return i
      inc i
    -1

# Realistic corpus: short tokens + long multi-proxy Forwarded / Accept values.
var corpus: seq[string] = @[]
corpus.add "text/html"
corpus.add "gzip, deflate, br"
corpus.add "en-US,en;q=0.9"
corpus.add "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
for p in 1 ..< 40:
  corpus.add "for=10.0.0." & $p & ",for=10.0.1." & $p & ",for=10.0.2." & $p & ",proto=http"
var corpusLen = 0
for s in corpus: corpusLen += s.len

proc nowNs(): int64 = getMonoTime().ticks div 1000
const iters = 200_000

var t0 = nowNs(); var sink = 0
for it in 0 ..< iters:
  for s in corpus:
    sink += findDelimScalar(s)
discard sink
let scalar = nowNs() - t0

t0 = nowNs(); sink = 0
for it in 0 ..< iters:
  for s in corpus:
    sink += findDelimScalar(s)
    when hostCPU == "amd64" or hostCPU == "i386":
      sink += findDelimSse2(s)
discard sink
let both = nowNs() - t0
let simd = both - scalar  # rough: subtract scalar portion (both loop does scalar+simd)

echo "corpus: " & $corpus.len & " values, " & $corpusLen & " bytes total"
echo "  scalar find-first: " & $scalar & " ns total"
echo "  simd  find-first:  " & $simd & " ns total (approx)"
echo "  simd/scalar ~ " & $((simd.float64 / scalar.float64))
