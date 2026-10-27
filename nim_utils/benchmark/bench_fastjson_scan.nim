## Micro-benchmark: fastjson "find first byte needing JSON escape" scan.
##
## Portable SWAR (8 bytes/iter, current direct_engine implementation) vs an
## SSE2 kernel built on nimsimd (16 bytes/iter). Confirms whether re-adding the
## SSE2 scan (removed earlier to keep the package pure Nim) is worth it now that
## we build with clang + nimsimd.
##
## Build (from repo root, with the nimsimd path):
##   nim c -d:release --opt:speed --mm:arc --cc:clang \
##     --path:nim_utils/src --path:vendor/nimsimd/src \
##     -o:/tmp/bfj_scan nim_utils/benchmark/bench_fastjson_scan.nim
##   /tmp/bfj_scan

import std/monotimes
when defined(nimsimdScanPortable):
  # force portable even on sse2 machines, for an apples-to-apples reference
  echo "[forced-portable mode]"
else:
  import nimsimd/sse2

type
  U128 = array[2, uint64]

const
  ByteHighBits = 0x8080808080808080'u64
  ByteLowMask  = 0x0101010101010101'u64
  ControlFloor = 0x2020202020202020'u64
  QuoteMask    = 0x2222222222222222'u64
  SlashMask    = 0x5c5c5c5c5c5c5c5c'u64

proc hasZeroByte(word: uint64): bool {.inline.} =
  ((word - ByteLowMask) and (not word) and ByteHighBits) != 0

template escChunkHit(chunk: uint64): bool =
  hasZeroByte(chunk xor QuoteMask) or
  hasZeroByte(chunk xor SlashMask) or
  ((chunk - ControlFloor) and (not chunk) and ByteHighBits) != 0'u64

const NeedsEscape: array[256, bool] = block:
  var t: array[256, bool]
  for i in 0..31: t[i] = true
  t[ord('"')] = true
  t[ord('\\')] = true
  t

# --- portable (current) ---
proc scanPortable(value: string, start: int): int {.inline.} =
  let vlen = value.len
  if vlen == 0: return 0
  var idx = start
  while idx + 8 <= vlen:
    var chunk: uint64
    copyMem(addr chunk, unsafeAddr value[idx], 8)
    if escChunkHit(chunk): break
    idx += 8
  while idx < vlen:
    if NeedsEscape[ord(value[idx])]: return idx
    inc idx
  vlen

# --- SSE2 (nimsimd) ---
proc scanSse2(value: string, start: int): int {.inline.} =
  when defined(nimsimdScanPortable):
    return scanPortable(value, start)
  else:
    let vlen = value.len
    if vlen == 0: return 0
    var idx = start
    while idx + 16 <= vlen:
      let v = mm_loadu_si128(cast[ptr uint64](unsafeAddr value[idx]))
      let eqQ = mm_cmpeq_epi8(v, mm_set1_epi8(0x22.uint8))
      let eqS = mm_cmpeq_epi8(v, mm_set1_epi8(0x5c.uint8))
      let ctl = mm_cmpeq_epi8(mm_and_si128(v, mm_set1_epi8(0xE0.uint8)), mm_setzero_si128())
      let m = mm_or_si128(mm_or_si128(eqQ, eqS), ctl)
      if mm_movemask_epi8(m) != 0:
        while idx < vlen and not NeedsEscape[ord(value[idx])]: inc idx
        return idx
      idx += 16
    while idx < vlen:
      if NeedsEscape[ord(value[idx])]: return idx
      inc idx
    vlen

proc nowNs(): int64 = getMonoTime().ticks div 1000

proc makeSafe(n: int): string =
  result = newStringOfCap(n)
  for i in 0 ..< n:
    result.add chr(ord('a') + (i mod 26))

proc verify() =
  # correctness: portable vs sse2 agree on many inputs
  var fails = 0
  for n in [0,1,7,8,15,16,17,31,32,100,255,256,1000,4096, 65536]:
    var s = makeSafe(n)
    # inject escapes at various positions
    if n > 0: s[n div 3] = '"'
    if n > 1: s[n div 2] = '\\'
    if n > 2 and n > 40: s[40] = chr(0x01)
    let a = scanPortable(s, 0)
    let b = scanSse2(s, 0)
    if a != b:
      inc fails
      echo "MISMATCH n=" & $n & " portable=" & $a & " sse2=" & $b
    # random start offsets
    for st in [0, 1, 5, 8, 16, n-1.int]:
      if st < 0 or st > n: continue
      if scanPortable(s, st) != scanSse2(s, st):
        inc fails
        echo "MISMATCH(n=$n,start=$st)"
  # pure safe (no escape)
  for n in [16, 1024, 65536]:
    let s = makeSafe(n)
    if scanPortable(s,0) != n or scanSse2(s,0) != n:
      inc fails; echo "SAFE MISMATCH n=$n"
  echo "verify: " & (if fails == 0: "OK (portable==sse2 everywhere)" else: $fails & " FAILURES")
  if fails != 0: quit 1

echo "== correctness =="
verify()

# Runtime-opaque safe buffer (compiler cannot constant-fold or hoist).
var seed = uint64(getMonoTime().ticks) + 1
proc rnd(): uint64 =
  seed = seed * 6364136223846793005'u64 + 1442695040888963407'u64
  (seed shr 32)

const bigN = 1 shl 20   # 1 MiB
var big = newStringOfCap(bigN)
for i in 0 ..< bigN: big.add chr(33 + int(rnd() mod 94))   # printable safe, no escape

let iters = 400
let span = bigN - 256

template measure(buf: string, useSse2: bool, iters, span: int): tuple[ns:int64, kb:float64] =
  var t0 = nowNs()
  var sink = 0
  var bytes = 0'u64
  for i in 0 ..< iters:
    let st = int(rnd() mod uint64(span))
    let e = if useSse2: scanSse2(buf, st) else: scanPortable(buf, st)
    sink += e
    bytes += uint64(e - st)
  (nowNs() - t0, bytes.float64 / 1024.0)

echo "== safe 1MiB buffer, random start, ns/KB scanned =="
let a = measure(big, false, iters, span)
let b = measure(big, true, iters, span)
echo "  portable=" & $(a[0].float64 / a[1]) & "ns/KB   sse2=" & $(b[0].float64 / b[1]) & "ns/KB   speedup=" & $(a[0].float64 / b[0].float64) & "x"

for off in [512, 4096, 100000]:
  var eb = big
  eb[off] = '"'
  let sa = measure(eb, false, iters, off)
  let sb = measure(eb, true, iters, off)
  echo "  escape@" & $off & "  portable=" & $(sa[0].float64 / sa[1]) & "ns/KB  sse2=" & $(sb[0].float64 / sb[1]) & "ns/KB  speedup=" & $(sa[0].float64 / sb[0].float64) & "x"
