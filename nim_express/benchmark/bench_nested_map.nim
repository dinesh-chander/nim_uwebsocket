## Nested map benchmark: outer[string] → inner[string, string]
##
## Outer key size: 50 chars
## Inner key size: 25 chars, inner value size: 50 chars
## Inner map population: 75 entries per outer key (midpoint of 50-100)
##
## Variants:
##   1. FastMap[FastMap[string]] tryGet
##   1b. FastMap[FastMap[string]] getPtrHashed outer + tryGet inner
##   1c. FastMap[FastMap[string]] getPtrHashed both levels
##   2. Table[Table[string,string]]   — stdlib baseline
##   3. FastMap[Table[string,string]] — fast outer, stdlib inner
##   4. Table[FastMap[string]]        — stdlib outer, fast inner
##
## Usage: bench_nested_map [outerN=10000] [innerN=75] [repeats=100]

import std/[os, strutils, times, tables]
import nim_express/fast_hash

const
  OuterKeyLen = 50
  InnerKeyLen = 25
  InnerValLen = 50

proc msBetween(a, b: float): float {.inline.} = (b - a) * 1000.0

proc makeKey(prefix: string, i: int, targetLen: int): string =
  let base = prefix & $i
  if base.len >= targetLen: base[0..<targetLen]
  else: base & repeat('x', targetLen - base.len)

proc buildOuterKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n: result[i] = makeKey("ok", i, OuterKeyLen)

proc buildInnerKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n: result[i] = makeKey("ik", i, InnerKeyLen)

proc buildInnerVals(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n: result[i] = makeKey("iv", i, InnerValLen)

# ── 1. FastMap[FastMap[string]] tryGet ────────────────────────────────────────

proc bench1_build(outerKeys, innerKeys, innerVals: seq[string],
                  outerN, innerN: int): FastMap[FastMap[string]] =
  result = newFastMap[FastMap[string]]()
  discard result.reserve(outerN * 2)
  for i in 0..<outerN:
    let inner = newFastMap[string]()
    discard inner.reserve(innerN * 2)
    for j in 0..<innerN:
      discard inner.put(innerKeys[j], innerVals[j])
    discard result.put(outerKeys[i], inner)

proc bench1_lookup(outer: FastMap[FastMap[string]],
                   outerKeys, innerKeys: seq[string],
                   outerN, innerN, reps: int): float =
  var cs = 0
  var innerRef: FastMap[string]
  var v: string
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<outerN:
      if outer.tryGet(outerKeys[i], innerRef):
        if innerRef.tryGet(innerKeys[i mod innerN], v):
          cs += v.len
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 1b. getPtrHashed outer + tryGet inner ─────────────────────────────────────

proc bench1b_lookup(outer: FastMap[FastMap[string]],
                    outerKeys, innerKeys: seq[string],
                    outerN, innerN, reps: int): float =
  var outerHashes = newSeq[uint64](outerN)
  for i in 0..<outerN: outerHashes[i] = hashKey(outerKeys[i])
  var cs = 0
  var v: string
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<outerN:
      let pInner = outer.getPtrHashed(outerKeys[i], outerHashes[i])
      if pInner != nil:
        if pInner[].tryGet(innerKeys[i mod innerN], v):
          cs += v.len
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 1c. getPtrHashed outer + getLenHashed inner (both prehashed) ──────────────

proc bench1c_lookup(outer: FastMap[FastMap[string]],
                    outerKeys, innerKeys: seq[string],
                    outerN, innerN, reps: int): float =
  var outerHashes = newSeq[uint64](outerN)
  for i in 0..<outerN: outerHashes[i] = hashKey(outerKeys[i])
  var innerHashes = newSeq[uint64](innerN)
  for i in 0..<innerN: innerHashes[i] = hashKey(innerKeys[i])
  var cs = 0
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<outerN:
      let pInner = outer.getPtrHashed(outerKeys[i], outerHashes[i])
      if pInner != nil:
        cs += pInner[].getLenHashed(innerKeys[i mod innerN],
                                    innerHashes[i mod innerN], 0)
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 2. Table[string, Table[string, string]] ───────────────────────────────────

proc bench2_build(outerKeys, innerKeys, innerVals: seq[string],
                  outerN, innerN: int): Table[string, Table[string, string]] =
  result = initTable[string, Table[string, string]](outerN * 2)
  for i in 0..<outerN:
    var inner = initTable[string, string](innerN * 2)
    for j in 0..<innerN: inner[innerKeys[j]] = innerVals[j]
    result[outerKeys[i]] = inner

proc bench2_lookup(outer: Table[string, Table[string, string]],
                   outerKeys, innerKeys: seq[string],
                   outerN, innerN, reps: int): float =
  let emptyInner = initTable[string, string]()
  let emptyVal = ""
  var cs = 0
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<outerN:
      cs += outer.getOrDefault(outerKeys[i], emptyInner)
                 .getOrDefault(innerKeys[i mod innerN], emptyVal).len
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 3. FastMap[Table[string, string]] ─────────────────────────────────────────

proc bench3_build(outerKeys, innerKeys, innerVals: seq[string],
                  outerN, innerN: int): FastMap[Table[string, string]] =
  result = newFastMap[Table[string, string]]()
  discard result.reserve(outerN * 2)
  for i in 0..<outerN:
    var inner = initTable[string, string](innerN * 2)
    for j in 0..<innerN: inner[innerKeys[j]] = innerVals[j]
    discard result.put(outerKeys[i], inner)

proc bench3_lookup(outer: FastMap[Table[string, string]],
                   outerKeys, innerKeys: seq[string],
                   outerN, innerN, reps: int): float =
  var outerHashes = newSeq[uint64](outerN)
  for i in 0..<outerN: outerHashes[i] = hashKey(outerKeys[i])
  let emptyVal = ""
  var cs = 0
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<outerN:
      let pInner = outer.getPtrHashed(outerKeys[i], outerHashes[i])
      if pInner != nil:
        cs += pInner[].getOrDefault(innerKeys[i mod innerN], emptyVal).len
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── 4. Table[string, FastMap[string]] ─────────────────────────────────────────

proc bench4_build(outerKeys, innerKeys, innerVals: seq[string],
                  outerN, innerN: int): Table[string, FastMap[string]] =
  result = initTable[string, FastMap[string]](outerN * 2)
  for i in 0..<outerN:
    let inner = newFastMap[string]()
    discard inner.reserve(innerN * 2)
    for j in 0..<innerN: discard inner.put(innerKeys[j], innerVals[j])
    result[outerKeys[i]] = inner

proc bench4_lookup(outer: Table[string, FastMap[string]],
                   outerKeys, innerKeys: seq[string],
                   outerN, innerN, reps: int): float =
  var v: string
  var cs = 0
  let t0 = epochTime()
  for _ in 0..<reps:
    for i in 0..<outerN:
      let inner = outer.getOrDefault(outerKeys[i], nil)
      if inner != nil:
        if inner.tryGet(innerKeys[i mod innerN], v):
          cs += v.len
  let t1 = epochTime()
  doAssert cs > 0
  msBetween(t0, t1)

# ── output ────────────────────────────────────────────────────────────────────

proc printRow(label: string, buildMs, lookupMs: float, outerN, reps: int,
              baseline: float) =
  let ops     = float(outerN) * float(reps) * 1000.0 / lookupMs / 1_000_000.0
  let speedup = baseline / lookupMs
  echo "  " & alignLeft(label, 46) &
    align($int(buildMs) & "ms", 9) &
    align($int(lookupMs) & "ms", 9) &
    align($int(ops * 10) & "." & $(int(ops * 100) mod 10) & "M/s", 12) &
    align($int(speedup * 100) & "%", 8)

proc printLookupRow(label: string, lookupMs: float, outerN, reps: int,
                    baseline: float) =
  let ops     = float(outerN) * float(reps) * 1000.0 / lookupMs / 1_000_000.0
  let speedup = baseline / lookupMs
  echo "  " & alignLeft(label, 46) &
    align("—", 9) &
    align($int(lookupMs) & "ms", 9) &
    align($int(ops * 10) & "." & $(int(ops * 100) mod 10) & "M/s", 12) &
    align($int(speedup * 100) & "%", 8)

when isMainModule:
  var outerN = 10_000
  var innerN = 75
  var reps   = 100
  if paramCount() >= 1: outerN = parseInt(paramStr(1))
  if paramCount() >= 2: innerN = parseInt(paramStr(2))
  if paramCount() >= 3: reps   = parseInt(paramStr(3))

  echo "Building keys (outer=", outerN, " inner=", innerN, " reps=", reps, ")..."
  let outerKeys = buildOuterKeys(outerN)
  let innerKeys = buildInnerKeys(innerN)
  let innerVals = buildInnerVals(innerN)

  let wk     = buildOuterKeys(500)
  let wInner = buildInnerKeys(innerN)
  let wVals  = buildInnerVals(innerN)
  block:
    let wm1 = bench1_build(wk, wInner, wVals, 500, innerN)
    discard bench1_lookup(wm1, wk, wInner, 500, innerN, 2)
    discard bench1b_lookup(wm1, wk, wInner, 500, innerN, 2)
    discard bench1c_lookup(wm1, wk, wInner, 500, innerN, 2)
    var wm2 = bench2_build(wk, wInner, wVals, 500, innerN)
    discard bench2_lookup(wm2, wk, wInner, 500, innerN, 2)
    let wm3 = bench3_build(wk, wInner, wVals, 500, innerN)
    discard bench3_lookup(wm3, wk, wInner, 500, innerN, 2)
    var wm4 = bench4_build(wk, wInner, wVals, 500, innerN)
    discard bench4_lookup(wm4, wk, wInner, 500, innerN, 2)

  echo "Building maps..."
  let t0b = epochTime(); let outer1 = bench1_build(outerKeys, innerKeys, innerVals, outerN, innerN); let b1ms = msBetween(t0b, epochTime())
  let t1b = epochTime(); var outer2 = bench2_build(outerKeys, innerKeys, innerVals, outerN, innerN); let b2ms = msBetween(t1b, epochTime())
  let t2b = epochTime(); let outer3 = bench3_build(outerKeys, innerKeys, innerVals, outerN, innerN); let b3ms = msBetween(t2b, epochTime())
  let t3b = epochTime(); var outer4 = bench4_build(outerKeys, innerKeys, innerVals, outerN, innerN); let b4ms = msBetween(t3b, epochTime())

  echo "Running lookups..."
  let l1  = bench1_lookup(outer1, outerKeys, innerKeys, outerN, innerN, reps)
  let l1b = bench1b_lookup(outer1, outerKeys, innerKeys, outerN, innerN, reps)
  let l1c = bench1c_lookup(outer1, outerKeys, innerKeys, outerN, innerN, reps)
  let l2  = bench2_lookup(outer2, outerKeys, innerKeys, outerN, innerN, reps)
  let l3  = bench3_lookup(outer3, outerKeys, innerKeys, outerN, innerN, reps)
  let l4  = bench4_lookup(outer4, outerKeys, innerKeys, outerN, innerN, reps)

  echo ""
  echo "  outerKeyLen=", OuterKeyLen, "  innerKeyLen=", InnerKeyLen,
       "  innerValLen=", InnerValLen
  echo "  outer entries=", outerN, "  inner entries/map=", innerN,
       "  total lookups=", outerN * reps
  echo ""
  echo "  " & alignLeft("variant", 50) & align("build", 9) &
    align("lookup", 9) & align("ops/s", 12) & align("vs base", 8)
  echo "  " & "-".repeat(88)

  printRow("1.  FastMap[FastMap[string]] tryGet",          b1ms, l1,  outerN, reps, l2)
  printLookupRow("1b. FastMap[FastMap[string]] getPtrHashed outer", l1b, outerN, reps, l2)
  printLookupRow("1c. FastMap both levels getPtrHashed",       l1c, outerN, reps, l2)
  printRow("2.  Table[Table[string,string]] (baseline)",   b2ms, l2,  outerN, reps, l2)
  printRow("3.  FastMap[Table[string,string]] getPtrHashed", b3ms, l3, outerN, reps, l2)
  printRow("4.  Table[FastMap[string]]",                   b4ms, l4,  outerN, reps, l2)
