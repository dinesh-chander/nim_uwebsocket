## Lookup comparison for FastMap[BigStruct] — heap-allocated value type.
## BigStruct has string + seq fields; each copy triggers ORC alloc/free.
##
## Usage: bench_bigstruct_lookup_opts [n=200000] [repeats=20]

import std/[os, strutils, times, tables]
import nim_express/fast_hash

type
  BigStruct = object
    name: string
    port: int
    tags: seq[string]

proc makeBig(i: int): BigStruct =
  BigStruct(name: "host" & $i, port: 8000 + (i mod 1000), tags: @["a", "b", $i])

proc msBetween(a, b: float): float {.inline.} = (b - a) * 1000.0

proc buildKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n: result[i] = "k" & $i

# ── 1. baseline: tryGet + deep copy ──────────────────────────────────────────
proc bench1_baseline(keys: seq[string], n, reps: int): float =
  let m = newFastMap[BigStruct]()
  defer: m.close()
  discard m.reserve(n * 2)
  for i in 0..<n: discard m.put(keys[i], makeBig(i))
  var cs = 0
  var v: BigStruct
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<n:
      if m.tryGet(keys[i], v): cs += v.port
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 2. ref value: FastMap[ref BigStruct] — outer copy is a pointer bump ──────
proc bench2_ref(keys: seq[string], n, reps: int): float =
  let m = newFastMap[ref BigStruct]()
  defer: m.close()
  discard m.reserve(n * 2)
  for i in 0..<n:
    let r = new(BigStruct)
    r[] = makeBig(i)
    discard m.put(keys[i], r)
  var cs = 0
  var v: ref BigStruct
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<n:
      if m.tryGet(keys[i], v):
        if v != nil: cs += v.port
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 3. getPtrHashed: precomputed hash + zero-copy ptr ────────────────────────
proc bench3_ptrHashed(keys: seq[string], n, reps: int): float =
  let m = newFastMap[BigStruct]()
  defer: m.close()
  discard m.reserve(n * 2)
  for i in 0..<n: discard m.put(keys[i], makeBig(i))
  var hashes = newSeq[uint64](n)
  for i in 0..<n: hashes[i] = hashKey(keys[i])
  var cs = 0
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<n:
      let p = m.getPtrHashed(keys[i], hashes[i])
      if p != nil: cs += p.port
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 4. Table baseline ─────────────────────────────────────────────────────────
proc bench4_table(keys: seq[string], n, reps: int): float =
  var m = initTable[string, BigStruct](n * 2)
  for i in 0..<n: m[keys[i]] = makeBig(i)
  var cs = 0
  let miss = BigStruct()
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<n:
      cs += m.getOrDefault(keys[i], miss).port
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
  discard bench1_baseline(wk, 10_000, 2)
  discard bench2_ref(wk, 10_000, 2)
  discard bench3_ptrHashed(wk, 10_000, 2)
  discard bench4_table(wk, 10_000, 2)

  echo "Running N=", n, "  repeats=", reps
  echo ""
  echo "  " & alignLeft("approach", 42) & align("time", 10) & align("ops/s", 12) & align("vs base", 9)
  echo "  " & "-".repeat(73)

  let t1 = bench1_baseline(keys, n, reps)
  let t2 = bench2_ref(keys, n, reps)
  let t3 = bench3_ptrHashed(keys, n, reps)
  let t4 = bench4_table(keys, n, reps)

  printRow("1. FastMap tryGet (deep copy)",          t1, n, reps, t1)
  printRow("2. FastMap[ref BigStruct] tryGet",        t2, n, reps, t1)
  printRow("3. FastMap getPtrHashed (zero copy)",     t3, n, reps, t1)
  printRow("4. Table getOrDefault (baseline)",        t4, n, reps, t1)
