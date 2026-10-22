import std/[sets, monotimes, strutils, strformat]
import ../../nim_utils/src/nim_utils/helpers/fast_set

const Scales = [10, 100, 1_000, 10_000, 100_000]

proc nowNs(): int64 {.inline.} =
  getMonoTime().ticks

proc fmtNs(ns: float): string =
  if ns < 1000:
    return fmt"{ns:.1f} ns"
  elif ns < 1_000_000:
    return fmt"{ns / 1000:.1f} µs"
  else:
    return fmt"{ns / 1_000_000:.2f} ms"

proc generateKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0 ..< n:
    result[i] = "key_" & $i & "_data"

proc generateMissKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0 ..< n:
    result[i] = "miss_" & $i & "_notfound"

proc repeatCount(n: int): int =
  if n <= 10: 500_000
  elif n <= 100: 100_000
  elif n <= 1_000: 10_000
  elif n <= 10_000: 1_000
  else: 100

proc buildSet(keys: seq[string]): FastSet =
  result = newFastSet(keys.len)
  for k in keys:
    discard result.incl(k)

proc benchInsert(n: int) =
  let keys = generateKeys(n)
  let reps = repeatCount(n)

  var fsTotal: int64 = 0
  for r in 0 ..< reps:
    let s = newFastSet(n)
    let t0 = nowNs()
    for i in 0 ..< n:
      discard s.incl(keys[i])
    fsTotal += nowNs() - t0

  var hsTotal: int64 = 0
  for r in 0 ..< reps:
    var hs = initHashSet[string]()
    let t0 = nowNs()
    for i in 0 ..< n:
      hs.incl(keys[i])
    hsTotal += nowNs() - t0

  let fsNs = fsTotal.float / (reps * n).float
  let hsNs = hsTotal.float / (reps * n).float
  echo fmt"  insert        n={n:<7} FS={fmtNs(fsNs):>10}  HashSet={fmtNs(hsNs):>10}  speedup={hsNs / fsNs:.2f}x"

proc benchLookup(n: int) =
  let keys = generateKeys(n)
  let misses = generateMissKeys(n)
  let reps = repeatCount(n) * 2
  let s = buildSet(keys)
  var hs = initHashSet[string]()
  for k in keys:
    hs.incl(k)

  var hitTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard s.contains(keys[i])
    hitTotal = nowNs() - t0

  var hitHsTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard keys[i] in hs
    hitHsTotal = nowNs() - t0

  var missTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard s.contains(misses[i])
    missTotal = nowNs() - t0

  var missHsTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard misses[i] in hs
    missHsTotal = nowNs() - t0

  let hits = (reps * n).float
  echo fmt"  contains-hit  n={n:<7} FS={fmtNs(hitTotal.float / hits):>10}  HashSet={fmtNs(hitHsTotal.float / hits):>10}  speedup={(hitHsTotal.float / hits) / (hitTotal.float / hits):.2f}x"
  echo fmt"  contains-miss n={n:<7} FS={fmtNs(missTotal.float / hits):>10}  HashSet={fmtNs(missHsTotal.float / hits):>10}  speedup={(missHsTotal.float / hits) / (missTotal.float / hits):.2f}x"

proc benchInclDup(n: int) =
  let keys = generateKeys(n)
  let reps = repeatCount(n)
  let s = buildSet(keys)

  var dupTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard s.incl(keys[i])
    dupTotal = nowNs() - t0

  let ops = (reps * n).float
  echo fmt"  incl-dup      n={n:<7} FS={fmtNs(dupTotal.float / ops):>10}"

proc benchContainsOrInclNew(n: int) =
  let keys = generateKeys(n)
  let misses = generateMissKeys(n)
  let reps = repeatCount(n)

  var coiTotal: int64 = 0
  for r in 0 ..< reps:
    let s = buildSet(keys)
    let t0 = nowNs()
    for i in 0 ..< n:
      discard s.containsOrIncl(misses[i])
    coiTotal += nowNs() - t0
    if s.len != 2 * n:
      echo "FAIL: containsOrIncl len mismatch"

  let ops = (reps * n).float
  echo fmt"  coi-new       n={n:<7} FS={fmtNs(coiTotal.float / ops):>10}"

proc benchExcl(n: int) =
  let keys = generateKeys(n)
  let misses = generateMissKeys(n)
  let reps = max(1, repeatCount(n) div 10)

  var hitTotal: int64 = 0
  for r in 0 ..< reps:
    let s = buildSet(keys)
    let t0 = nowNs()
    for i in 0 ..< n:
      discard s.excl(keys[i])
    hitTotal += nowNs() - t0
    if s.len != 0:
      echo "FAIL: excl len mismatch"

  var missTotal: int64 = 0
  for r in 0 ..< reps:
    let s = buildSet(keys)
    let t0 = nowNs()
    for i in 0 ..< n:
      discard s.excl(misses[i])
    missTotal += nowNs() - t0
    if s.len != n:
      echo "FAIL: excl-miss len mismatch"

  let ops = (reps * n).float
  echo fmt"  excl-hit      n={n:<7} FS={fmtNs(hitTotal.float / ops):>10}"
  echo fmt"  excl-miss     n={n:<7} FS={fmtNs(missTotal.float / ops):>10}"

proc benchChurn(n: int) =
  # mixed incl/excl/contains workload on a stable-size set
  let keys = generateKeys(n)
  let misses = generateMissKeys(n)
  let reps = repeatCount(n) div 2

  var fsTotal: int64 = 0
  for r in 0 ..< reps:
    let s = buildSet(keys)
    let t0 = nowNs()
    for i in 0 ..< n:
      discard s.excl(keys[i mod n])
      discard s.incl(misses[i mod n])
      discard s.contains(keys[(i + 1) mod n])
    fsTotal += nowNs() - t0

  var hsTotal: int64 = 0
  for r in 0 ..< reps:
    var hs = initHashSet[string]()
    for k in keys:
      hs.incl(k)
    let t0 = nowNs()
    for i in 0 ..< n:
      hs.excl(keys[i mod n])
      hs.incl(misses[i mod n])
      discard keys[(i + 1) mod n] in hs
    hsTotal += nowNs() - t0

  let ops = (reps * n * 3).float
  let fsNs = fsTotal.float / ops
  let hsNs = hsTotal.float / ops
  echo fmt"  churn/op      n={n:<7} FS={fmtNs(fsNs):>10}  HashSet={fmtNs(hsNs):>10}  speedup={hsNs / fsNs:.2f}x"

when isMainModule:
  for n in Scales:
    echo "--- Scale: ", n, " ---"
    benchInsert(n)
    benchLookup(n)
    benchInclDup(n)
    benchContainsOrInclNew(n)
    benchExcl(n)
    benchChurn(n)
    echo ""
