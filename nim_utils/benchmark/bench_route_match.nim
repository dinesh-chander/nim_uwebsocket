## Route-reject compare benchmark: staticPrefix startsWith + first-segment compare.
## scalar (original Nim/byte-loop) vs simd (simdStrEquals).
import std/[monotimes, strutils]
import nim_utils/helpers/simd_str

proc pathStartsWith(path, prefix: string): bool =
  path.startsWith(prefix)
proc sliceEqScalar(path: string, s, l: int, v: string): bool =
  if l != v.len:
    return false
  for i in 0 ..< l:
    if path[s+i] != v[i]:
      return false
  true
proc sliceEqSimd(path: string, s, l: int, v: string): bool =
  if l != v.len: return false
  if l == 0: return true
  simdStrEquals(unsafeAddr path[s], unsafeAddr v[0], l)

# Build many routes with static prefixes + a literal first segment (realistic API fan-out).
var prefixes: seq[string] = @[]
var segs: seq[string] = @[]
for i in 0 ..< 200:
  prefixes.add "/api/v1/resource" & $i
  segs.add "resource" & $i
let path = "/api/v1/resource42/extra/segment"

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000
const iters = 500_000

# scalar
var t0 = nowMs(); var sink = 0
for it in 0 ..< iters:
  for r in 0 ..< prefixes.len:
    if pathStartsWith(path, prefixes[r]) and sliceEqScalar(path, 7, segs[r].len, segs[r]):
      inc sink
discard sink
let scalar = nowMs() - t0

# simd
t0 = nowMs(); sink = 0
for it in 0 ..< iters:
  for r in 0 ..< prefixes.len:
    let okP = path.len >= prefixes[r].len and
              simdStrEquals(unsafeAddr path[0], unsafeAddr prefixes[r][0], prefixes[r].len)
    if okP and sliceEqSimd(path, 7, segs[r].len, segs[r]):
      inc sink
discard sink
let simd = nowMs() - t0

echo "route reject (200 routes x prefix+segment compare):"
echo "  scalar: " & $scalar & "ms"
echo "  simd  : " & $simd & "ms"
echo "  simd/scalar = " & $((simd.float64 / scalar.float64)) & " (lower = faster)"
