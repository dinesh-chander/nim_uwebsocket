## Lookup optimization comparison for FastMap[int64].
## int64 is a value type — copy is a single register move.
##
## Complements bench_bigstruct_lookup_opts.nim (heap-alloc type).
##
## Usage: bench_int64_lookup_opts [n=200000] [repeats=20]

import std/[os, strutils, times, tables]
import nim_express/fast_hash

proc msBetween(a, b: float): float {.inline.} = (b - a) * 1000.0

proc buildKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n: result[i] = "k" & $i

# ── 1. baseline: get (return copy) ───────────────────────────────────────────
proc bench1_get(keys: seq[string], n, reps: int): float =
  let m = newFastMap[int64]()
  defer: m.close()
  discard m.reserve(n * 2)
  for i in 0..<n: discard m.put(keys[i], int64(i))
  var cs = 0'i64
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<n:
      cs += m.get(keys[i], -1)
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 2. getPtrHashed (precomputed hash + zero copy) ────────────────────────────
proc bench2_ptrHashed(keys: seq[string], n, reps: int): float =
  let m = newFastMap[int64]()
  defer: m.close()
  discard m.reserve(n * 2)
  for i in 0..<n: discard m.put(keys[i], int64(i))
  var hashes = newSeq[uint64](n)
  for i in 0..<n: hashes[i] = hashKey(keys[i])
  var cs = 0'i64
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<n:
      let p = m.getPtrHashed(keys[i], hashes[i])
      if p != nil: cs += p[]
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 3. Table baseline ─────────────────────────────────────────────────────────
proc bench3_table(keys: seq[string], n, reps: int): float =
  var m = initTable[string, int64](n * 2)
  for i in 0..<n: m[keys[i]] = int64(i)
  var cs = 0'i64
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<n:
      cs += m.getOrDefault(keys[i], -1)
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── output ────────────────────────────────────────────────────────────────────

proc printRow(label: string, ms: float, n, reps: int, baseline: float) =
  let ops     = float(n) * float(reps) * 1000.0 / ms / 1_000_000.0
  let speedup = baseline / ms
  echo "  " & alignLeft(label, 38) &
    align($int(ms) & "ms", 10) &
    align($int(ops * 10) & "." & $(int(ops * 100) mod 10) & "M/s", 12) &
    align($int(speedup * 100) & "%", 9)

when isMainModule:
  var n    = 200_000
  var reps = 20
  if paramCount() >= 1: n    = parseInt(paramStr(1))
  if paramCount() >= 2: reps = parseInt(paramStr(2))

  echo "Building keys..."
  let keys = buildKeys(n)

  let wk = buildKeys(10_000)
  discard bench1_get(wk, 10_000, 2)
  discard bench2_ptrHashed(wk, 10_000, 2)
  discard bench3_table(wk, 10_000, 2)

  echo "Running N=", n, "  repeats=", reps
  echo ""
  echo "  " & alignLeft("approach", 42) & align("time", 10) & align("ops/s", 12) & align("vs base", 9)
  echo "  " & "-".repeat(73)

  let t1 = bench1_get(keys, n, reps)
  let t2 = bench2_ptrHashed(keys, n, reps)
  let t3 = bench3_table(keys, n, reps)

  printRow("1. FastMap get (baseline)",              t1, n, reps, t1)
  printRow("2. FastMap getPtrHashed (zero copy)",    t2, n, reps, t1)
  printRow("3. Table getOrDefault",                  t3, n, reps, t1)
