import std/[os, strutils, tables, sets, times]

import nim_express/fast_hash

type
  PhaseResult = object
    insertMs: float
    lookupMs: float
    overwriteMs: float
    iterateMs: float
    eraseMs: float
    checksum: int

proc msBetween(startTs, endTs: float): float {.inline.} =
  (endTs - startTs) * 1000.0

proc opsPerSec(ops: int, ms: float): float {.inline.} =
  if ms <= 0.0: return 0.0
  ops.float * 1000.0 / ms

proc keyAt(i: int): string {.inline.} =
  "k" & $i

proc valAt(i: int): string {.inline.} =
  "v" & $i

proc benchStdTable(n: int): PhaseResult =
  var t = initTable[string, string](n * 2)
  let t0 = epochTime()
  for i in 0..<n:
    t[keyAt(i)] = valAt(i)
  let t1 = epochTime()

  var checksum = 0
  for i in 0..<n:
    checksum += t.getOrDefault(keyAt(i)).len
  let t2 = epochTime()

  for i in 0..<n:
    t[keyAt(i)] = valAt(i + n)
  let t3 = epochTime()

  for k, v in t:
    checksum += k.len + v.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2):
    t.del(keyAt(i))
  let t5 = epochTime()

  result.insertMs = msBetween(t0, t1)
  result.lookupMs = msBetween(t1, t2)
  result.overwriteMs = msBetween(t2, t3)
  result.iterateMs = msBetween(t3, t4)
  result.eraseMs = msBetween(t4, t5)
  result.checksum = checksum

proc benchFastMap(n: int): PhaseResult =
  let t = newFastMap[string]()
  discard t.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    discard t.put(keyAt(i), valAt(i))
  let t1 = epochTime()

  var checksum = 0
  for i in 0..<n:
    checksum += t.get(keyAt(i)).len
  let t2 = epochTime()

  for i in 0..<n:
    discard t.put(keyAt(i), valAt(i + n))
  let t3 = epochTime()

  for k, v in t:
    checksum += k.len + v.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2):
    discard t.del(keyAt(i))
  let t5 = epochTime()

  result.insertMs = msBetween(t0, t1)
  result.lookupMs = msBetween(t1, t2)
  result.overwriteMs = msBetween(t2, t3)
  result.iterateMs = msBetween(t3, t4)
  result.eraseMs = msBetween(t4, t5)
  result.checksum = checksum
  t.close()

proc benchStdSet(n: int): PhaseResult =
  var s = initHashSet[string](n * 2)
  let t0 = epochTime()
  for i in 0..<n:
    s.incl(keyAt(i))
  let t1 = epochTime()

  var checksum = 0
  for i in 0..<n:
    if s.contains(keyAt(i)):
      inc checksum
  let t2 = epochTime()

  for i in 0..<n:
    s.incl(keyAt(i))
  let t3 = epochTime()

  for key in s:
    checksum += key.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2):
    s.excl(keyAt(i))
  let t5 = epochTime()

  result.insertMs = msBetween(t0, t1)
  result.lookupMs = msBetween(t1, t2)
  result.overwriteMs = msBetween(t2, t3)
  result.iterateMs = msBetween(t3, t4)
  result.eraseMs = msBetween(t4, t5)
  result.checksum = checksum

proc benchFastSet(n: int): PhaseResult =
  let s = newFastSet()
  discard s.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    discard s.incl(keyAt(i))
  let t1 = epochTime()

  var checksum = 0
  for i in 0..<n:
    if s.contains(keyAt(i)):
      inc checksum
  let t2 = epochTime()

  for i in 0..<n:
    discard s.incl(keyAt(i))
  let t3 = epochTime()

  for key in s:
    checksum += key.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2):
    discard s.excl(keyAt(i))
  let t5 = epochTime()

  result.insertMs = msBetween(t0, t1)
  result.lookupMs = msBetween(t1, t2)
  result.overwriteMs = msBetween(t2, t3)
  result.iterateMs = msBetween(t3, t4)
  result.eraseMs = msBetween(t4, t5)
  result.checksum = checksum
  s.close()

proc printResult(name: string, n: int, r: PhaseResult) =
  echo name
  echo "  insert: ", formatFloat(r.insertMs, ffDecimal, 2), " ms (",
    formatFloat(opsPerSec(n, r.insertMs), ffDecimal, 0), " ops/s)"
  echo "  lookup: ", formatFloat(r.lookupMs, ffDecimal, 2), " ms (",
    formatFloat(opsPerSec(n, r.lookupMs), ffDecimal, 0), " ops/s)"
  echo "  overwrite: ", formatFloat(r.overwriteMs, ffDecimal, 2), " ms (",
    formatFloat(opsPerSec(n, r.overwriteMs), ffDecimal, 0), " ops/s)"
  echo "  iterate: ", formatFloat(r.iterateMs, ffDecimal, 2), " ms (",
    formatFloat(opsPerSec(n, r.iterateMs), ffDecimal, 0), " ops/s)"
  echo "  erase:  ", formatFloat(r.eraseMs, ffDecimal, 2), " ms (",
    formatFloat(opsPerSec((n + 1) div 2, r.eraseMs), ffDecimal, 0), " ops/s)"
  echo "  checksum: ", r.checksum

when isMainModule:
  var n = 200_000
  if paramCount() >= 1:
    n = parseInt(paramStr(1))
  if n <= 0:
    quit("N must be > 0", QuitFailure)

  echo "Benchmark size N=", n
  echo "Warming up..."
  discard benchStdTable(10_000)
  discard benchFastMap(10_000)
  discard benchStdSet(10_000)
  discard benchFastSet(10_000)

  echo ""
  let stdTable = benchStdTable(n)
  let fastMap = benchFastMap(n)
  let stdSet = benchStdSet(n)
  let fastSet = benchFastSet(n)

  printResult("Std Table[string,string]", n, stdTable)
  printResult("FastMap (pure Nim)", n, fastMap)
  echo ""
  printResult("Std HashSet[string]", n, stdSet)
  printResult("FastSet (pure Nim)", n, fastSet)
