## Micro-benchmark: HTTP/1.1 CRLF (\r\n) finder — portable byte scan vs SSE2.
## Runtime-opaque data (random, no fold/hoist). Reports ns/KB.
import std/[monotimes]
import nimsimd/sse2

type U128 = array[2, uint64]

proc findCrLfPortable(data: string, start: int): int {.inline.} =
  var i = start
  let limit = data.len - 1
  while i < limit:
    if data[i] == '\r' and data[i + 1] == '\n':
      return i
    i += 1
  -1

proc findCrLfSse2(data: string, start: int): int {.inline.} =
  let len = data.len
  var i = start
  while i + 17 <= len:   # bytes i..i+16 all valid -> 16 pairs
    let vcr = mm_loadu_si128(cast[ptr uint64](unsafeAddr data[i]))
    let vlf = mm_loadu_si128(cast[ptr uint64](unsafeAddr data[i + 1]))
    let hit = mm_and_si128(mm_cmpeq_epi8(vcr, mm_set1_epi8(13.uint8)),
                           mm_cmpeq_epi8(vlf, mm_set1_epi8(10.uint8)))
    var m = mm_movemask_epi8(hit)
    if m != 0:
      var b = 0
      while (m and 1) == 0: m = m shr 1; inc b
      return i + b
    i += 16
  let limit = len - 1
  while i < limit:
    if data[i] == '\r' and data[i + 1] == '\n':
      return i
    i += 1
  -1

proc nowNs(): int64 = getMonoTime().ticks div 1000
var seed = uint64(getMonoTime().ticks) + 1
proc rnd(): uint64 =
  seed = seed * 6364136223846793005'u64 + 1442695040888963407'u64
  (seed shr 32)

# correctness
proc verify() =
  var fails = 0
  for trial in 0 ..< 2000:
    let n = int(rnd() mod 4096)
    var s = newStringOfCap(n)
    for i in 0 ..< n:
      let r = rnd() mod 100
      if r < 3: s.add "\r\n"
      elif r < 5: s.add '\r'
      elif r < 7: s.add '\n'
      else: s.add chr(33 + int(rnd() mod 94))
    for st in [0, 1, 2, n div 2, n-1.int]:
      if st < 0 or st >= n: continue
      let a = findCrLfPortable(s, st)
      let b = findCrLfSse2(s, st)
      if a != b:
        inc fails
        if fails < 10: echo "MISMATCH n=" & $n & " st=" & $st & " p=" & $a & " s=" & $b
  echo "verify: " & (if fails == 0: "OK" else: $fails & " FAIL")
  if fails != 0: quit 1

verify()

# throughput: header-like buffer with CRLFs scattered
const N = 1 shl 20
var buf = newStringOfCap(N)
for i in 0 ..< N:
  let r = rnd() mod 200
  if r == 0: buf.add "\r\n"
  elif r == 1: buf.add '\r'
  elif r == 2: buf.add '\n'
  else: buf.add chr(33 + int(rnd() mod 94))

const iters = 300
echo "== CRLF finder, random start, ns/KB scanned =="
for (lbl, useSse) in [("portable", false), ("sse2", true)]:
  var t0 = nowNs()
  var sink = 0
  var bytes = 0'u64
  for i in 0 ..< iters:
    let st = int(rnd() mod uint64(N - 1024))
    let e = if useSse: findCrLfSse2(buf, st) else: findCrLfPortable(buf, st)
    sink += e
    let endp = if e < 0: buf.len else: e
    bytes += uint64(endp - st)
  let ns = nowNs() - t0
  discard sink
  echo "  " & lbl & "=" & $(ns.float64 / (bytes.float64 / 1024.0)) & "ns/KB  (total " & $(ns.float64 / 1000.0) & "ms)"
