# Benchmark: long-key hash for FastMap/FastSet.
#
# Compares the current scalar wyhash long-key path (nimWyHash as used by
# hashBytes) against two nimsimd SSE2 variants:
#   * simdMix16  - one 64x64->128 mix per 16-byte vector load (structural analog)
#   * simdWide   - XOR-accumulate 16-byte loads, remix every 128 bytes, strong tail
#
# Measures ns/hash across long sizes and a distribution check (collision count
# + 8-bit bucket balance). Investigative only - not wired into fastmap.

import std/[monotimes], tables
when defined(amd64) or defined(i386):
  import nimsimd/sse2

const useMulhi = defined(amd64) and (defined(gcc) or defined(clang))
const useSse2  = defined(amd64) or defined(i386)

proc nowNs(): int64 {.inline.} =
  getMonoTime().ticks

proc mulhi(a, b: uint64): uint64 {.inline.} =
  when useMulhi:
    var r: uint64
    {.emit: "uint64_t hx_a = `a`, hx_b = `b`; `r` = (uint64_t)((__uint128_t)hx_a * hx_b >> 64);".}
    r
  else:
    let ha = a shr 32; let la = a and 0xFFFF_FFFF'u64
    let hb = b shr 32; let lb = b and 0xFFFF_FFFF'u64
    let rm0 = ha * lb; let rm1 = hb * la
    let t = (la * lb) + (rm0 shl 32)
    var carry = (if t < (la * lb): 1'u64 else: 0'u64)
    let loCheck = t + (rm1 shl 32)
    if loCheck < t: inc carry
    (ha * hb) + (rm0 shr 32) + (rm1 shr 32) + carry

proc mum(a, b: var uint64) {.inline.} =
  when useMulhi:
    let lo = a * b
    let hi = mulhi(a, b)
    a = lo; b = hi
  else:
    let ha = a shr 32; let la = a and 0xFFFF_FFFF'u64
    let hb = b shr 32; let lb = b and 0xFFFF_FFFF'u64
    let rl = la * lb; let t = rl + ((ha * lb) shl 32)
    var carry = (if t < rl: 1'u64 else: 0'u64)
    let lo = t + ((hb * la) shl 32)
    if lo < t: inc carry
    a = lo
    b = (ha * hb) + ((ha * lb) shr 32) + ((hb * la) shr 32) + carry

proc mix(a, b: uint64): uint64 {.inline.} =
  var x = a; var y = b
  mum(x, y)
  x xor y

proc r8(p: pointer): uint64 {.inline.} =
  var v: uint64
  copyMem(addr v, p, 8)
  v

const Seed0 = 0x1234_5678_9abc_def0'u64

# --- Baseline: exact copy of nimWyHash long path (fast_map.nim:99) ---
proc wyScalar(key: pointer, n: int): uint64 =
  let p = cast[ptr UncheckedArray[uint8]](key)
  var seed = Seed0 xor 0xca813bf4c7abf0a9'u64
  var a, b: uint64
  if n <= 16:
    a = if n >= 8: r8(p) else: 0
    b = if n >= 8: r8(addr p[n-8]) else: 0
  else:
    var i = n
    var pp = cast[ptr UncheckedArray[uint8]](p)
    if i >= 48:
      var see1 = seed; var see2 = seed
      while true:
        seed = mix(r8(addr pp[0]) xor 0x8bb84b93962eacc9'u64, r8(addr pp[8]) xor seed)
        see1 = mix(r8(addr pp[16]) xor 0x4b33a62ed433d4a3'u64, r8(addr pp[24]) xor see1)
        see2 = mix(r8(addr pp[32]) xor 0x4d5a2da51de1aa47'u64, r8(addr pp[40]) xor see2)
        pp = cast[ptr UncheckedArray[uint8]](cast[uint](pp) + 48)
        i -= 48
        if i < 48: break
      seed = seed xor see1 xor see2
    while i > 16:
      seed = mix(r8(addr pp[0]) xor 0x8bb84b93962eacc9'u64, r8(addr pp[8]) xor seed)
      i -= 16
      pp = cast[ptr UncheckedArray[uint8]](cast[uint](pp) + 16)
    a = r8(addr pp[i - 16])
    b = r8(addr pp[i - 8])
  a = a xor 0x8bb84b93962eacc9'u64
  b = b xor seed
  mum(a, b)
  mix(a xor 0x2d358dccaa6c78a5'u64 xor uint64(n), b xor 0x8bb84b93962eacc9'u64)

when useSse2:
  proc loadLoHi(p: pointer, lo, hi: var uint64) {.inline.} =
    let v = mm_loadu_si128(p)
    lo = uint64(mm_cvtsi128_si64(v))
    hi = uint64(mm_cvtsi128_si64(mm_srli_si128(v, 8)))

  # One mix per 16-byte vector load.
  proc wySimdMix16(key: pointer, n: int): uint64 =
    let p = cast[ptr UncheckedArray[uint8]](key)
    var seed = Seed0 xor 0xca813bf4c7abf0a9'u64
    if n <= 16:
      return wyScalar(key, n)
    var off = 0
    while off + 16 <= n:
      var lo, hi: uint64
      loadLoHi(addr p[off], lo, hi)
      seed = mix(lo xor 0x8bb84b93962eacc9'u64, hi xor seed)
      off += 16
    let a = r8(addr p[n - 8])
    let b = r8(addr p[n - 16])
    var x = a xor 0x8bb84b93962eacc9'u64
    var y = b xor seed
    mum(x, y)
    mix(x xor 0x2d358dccaa6c78a5'u64 xor uint64(n), y xor 0x8bb84b93962eacc9'u64)

  # XOR-accumulate 16-byte loads, remix every 128 bytes, strong finalizer.
  proc wySimdWide(key: pointer, n: int): uint64 =
    let p = cast[ptr UncheckedArray[uint8]](key)
    if n <= 16:
      return wyScalar(key, n)
    var a = Seed0
    var b = 0xca813bf4c7abf0a9'u64
    let chunks = n shr 4
    for c in 0..<chunks:
      var lo, hi: uint64
      loadLoHi(addr p[c * 16], lo, hi)
      a = a xor lo
      b = b xor hi
      if (c and 7) == 7:
        a = mix(a, b); b = mix(b, a)
    a = a xor uint64(n)
    b = mix(b, a)
    a = mix(a, b)
    b = mix(b, a)
    a

type Hf = proc(key: pointer, n: int): uint64

proc bench(label: string, n: int, iters: int, f: Hf): float =
  var buf = newSeq[uint8](n)
  # deterministic fill
  var s: uint64 = 0x9e3779b97f4a7c15'u64
  for i in 0..<n:
    s = s * 6364136223846793005'u64 + 1442695040888963407'u64
    buf[i] = uint8(s shr 56)
  var acc: uint64 = 0
  for _ in 0..<100:
    acc = acc * 0x9e3779b97f4a7c15'u64 + f(addr buf[0], n)
  let t0 = nowNs()
  for j in 0..<iters:
    buf[0] = uint8(j)   # defeat loop-invariant hoisting of f(buf,n)
    acc = acc * 0x9e3779b97f4a7c15'u64 + f(addr buf[0], n)
  let dt = nowNs() - t0
  echo label & "\tlen=" & $n & "\t" & $(dt / iters) & " ns/hash  (acc=" & $acc & ")"
  dt / iters

proc distribution(label: string, n: int, keys: int, f: Hf) =
  var buf = newSeq[uint8](n)
  var seen = initTable[string, int]()
  var top8 = newSeq[int](256)
  var s: uint64 = 0x2545f4914f6cdd1d'u64
  for k in 0..<keys:
    for i in 0..<n:
      s = s * 6364136223846793005'u64 + 1442695040888963407'u64
      buf[i] = uint8(s shr 56)
    let h = f(addr buf[0], n)
    seen[$h] = seen.getOrDefault($h, 0) + 1
    inc top8[int(h shr 56)]
  # collisions
  var coll = 0
  for v in seen.values:
    if v > 1: coll += v - 1
  # bucket balance: min/max of top-8-bit histogram
  var mn = high(int); var mx = 0
  for v in top8:
    if v < mn: mn = v
    if v > mx: mx = v
  echo label & "\tlen=" & $n & "\tkeys=" & $keys & "\tdistinct=" & $seen.len & "\tcollisions=" & $coll & "\ttop8 min=" & $mn & " max=" & $mx & " ratio=" & $(mx / max(mn,1))

when useSse2:
  echo "=== throughput (ns/hash, deterministic long buffer) ==="
  for n in [256, 1024, 4096, 65536]:
    let it = if n >= 65536: 20000 else: 200000 div (n div 256)
    discard bench("wyScalar", n, it, wyScalar)
    discard bench("simdMix16", n, it, wySimdMix16)
    discard bench("simdWide", n, it, wySimdWide)
    echo ""

  echo "=== distribution (random long keys) ==="
  distribution("wyScalar", 512, 200000, wyScalar)
  distribution("simdMix16", 512, 200000, wySimdMix16)
  distribution("simdWide", 512, 200000, wySimdWide)
else:
  echo "SSE2 unavailable; baseline only"
  for n in [256, 1024, 4096, 65536]:
    discard bench("wyScalar", n, 200000 div (n div 256), wyScalar)
