## SIMD string primitives for the pure-Nim `fast_map` / `fast_set` helpers.
##
## `simdStrEquals` compares two byte ranges for equality using nimsimd SSE2
## intrinsics (16-byte compare + movemask) on x86/x86_64 and a portable
## 64-bit/byte fallback elsewhere. It is a drop-in replacement for
## `equalMem` on the key-comparison hot paths of the Swiss-table maps and
## sets: identical semantics (true iff the first `n` bytes match).
##
## Measured tradeoff (release, see benchmark/bench_simd_str.nim): on the
## common short-key case (<=16 bytes) the single SSE2 lane beats the glibc
## `memcmp` call overhead (~1.4x); on long exact-match keys the already
## SIMD-tuned libc `memcmp` is faster, but that path is only reached on a
## hash+len collision with a long key, which is rare for this stack.
##
## The SSE2 path is compiled in under the same gate as the SWAR group probes
## (`swarUseSimd`) and can be forced off with `nimSimdStrPortable`.

import ./swar_group

const
  simdStrUseSse2* = swarUseSimd and not defined(nimSimdStrPortable)
    ## True when the SSE2 string primitives are compiled in; define
    ## `nimSimdStrPortable` to force the portable 64-bit path.

when simdStrUseSse2:
  import nimsimd/sse2

## Portable 64-bit + byte fallback: compare `n` bytes at `a` against `n`
## bytes at `b`, returning true only when all bytes are equal.
proc simdStrEqualsPortable*(a, b: pointer, n: int): bool {.inline.} =
  if n <= 0:
    return true
  let pa = cast[ptr UncheckedArray[uint8]](a)
  let pb = cast[ptr UncheckedArray[uint8]](b)
  var i = 0
  let full8 = (n shr 3) shl 3
  while i < full8:
    var wa, wb: uint64
    copyMem(addr wa, addr pa[i], 8)
    copyMem(addr wb, addr pb[i], 8)
    if wa != wb:
      return false
    i += 8
  while i < n:
    if pa[i] != pb[i]:
      return false
    inc i
  true

when simdStrUseSse2:
  ## SSE2 compare: 16-byte lanes via `_mm_cmpeq_epi8` + `_mm_movemask_epi8`,
  ## then a 64-bit/byte tail. Early-exits on the first mismatching lane.
  proc simdStrEqualsSse2(a, b: pointer, n: int): bool {.inline.} =
    if n <= 0:
      return true
    let pa = cast[ptr UncheckedArray[uint8]](a)
    let pb = cast[ptr UncheckedArray[uint8]](b)
    var i = 0
    let full16 = (n shr 4) shl 4
    while i < full16:
      let va = mm_loadu_si128(addr pa[i])
      let vb = mm_loadu_si128(addr pb[i])
      if mm_movemask_epi8(mm_cmpeq_epi8(va, vb)) != 0xFFFF'i32:
        return false
      i += 16
    let full8 = (n shr 3) shl 3
    while i < full8:
      var wa, wb: uint64
      copyMem(addr wa, addr pa[i], 8)
      copyMem(addr wb, addr pb[i], 8)
      if wa != wb:
        return false
      i += 8
    while i < n:
      if pa[i] != pb[i]:
        return false
      inc i
    true

## Returns true iff the `n` bytes at `a` are byte-for-byte equal to the `n`
## bytes at `b`. `n` must be non-negative and both pointers must address at
## least `n` readable bytes (or `n == 0`).
proc simdStrEquals*(a, b: pointer, n: int): bool {.inline.} =
  when simdStrUseSse2:
    simdStrEqualsSse2(a, b, n)
  else:
    simdStrEqualsPortable(a, b, n)
