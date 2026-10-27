## Micro-benchmark: nimsimd SSE2 `simdStrEquals` vs the stdlib `equalMem`
## (C `memcmp`) on the key-comparison path of `fast_map` / `fast_set`.
##
## Build:
##   nim c -d:release --opt:speed --hints:off \
##     --path:nim_utils/src --path:vendor/nimsimd/src \
##     -o:/tmp/bench_simd_str nim_utils/benchmark/bench_simd_str.nim
##
## The SSE2 path early-exits on the first differing 16-byte lane, so it wins
## most on long keys and long near-misses; it is comparable or better on
## long exact matches.

import std/[monotimes, strformat, strutils]

import ../src/nim_utils/helpers/simd_str

proc nowNs(): int64 {.inline.} =
  getMonoTime().ticks

proc bench(label: string, n: int, iters: int, f: proc(a, b: pointer, n: int): bool): float =
  let a = "a".repeat(n)
  let mid = n div 2
  let b = "a".repeat(mid) & "b" & "a".repeat(n - mid - 1)   # single-byte near-miss
  # Warmup
  var sink = 0
  for _ in 0..<1000:
    if f(addr a[0], addr b[0], n): inc sink
  let t0 = nowNs()
  for _ in 0..<iters:
    if f(addr a[0], addr b[0], n): inc sink
  let dt = (nowNs() - t0)
  echo fmt"{label:<28} len={n:<6} {dt / iters:8.1f} ns/compare (trueCount={sink})"
  dt / iters

proc benchMatch(label: string, n: int, iters: int, f: proc(a, b: pointer, n: int): bool): float =
  let a = "a".repeat(n)
  var sink = 0
  for _ in 0..<1000:
    if f(addr a[0], addr a[0], n): inc sink
  let t0 = nowNs()
  for _ in 0..<iters:
    if f(addr a[0], addr a[0], n): inc sink
  let dt = nowNs() - t0
  echo fmt"{label:<28} len={n:<6} {dt / iters:8.1f} ns/compare (exact, trueCount={sink})"
  dt / iters

const Iters = 2_000_000
let lengths = @[16, 64, 128, 256, 1024]

echo "== near-miss (first differing byte decides) =="
for n in lengths:
  let m = bench("equalMem (memcmp)", n, Iters, proc(a,b:pointer;n:int):bool = equalMem(a,b,n))
  let s = bench("simdStrEquals (SSE2)", n, Iters, proc(a,b:pointer;n:int):bool = simdStrEquals(a,b,n))
  echo fmt"   speedup: {m / s:.2f}x"

echo ""
echo "== exact match (full scan required) =="
for n in lengths:
  let m = benchMatch("equalMem (memcmp)", n, Iters, proc(a,b:pointer;n:int):bool = equalMem(a,b,n))
  let s = benchMatch("simdStrEquals (SSE2)", n, Iters, proc(a,b:pointer;n:int):bool = simdStrEquals(a,b,n))
  echo fmt"   speedup: {m / s:.2f}x"
