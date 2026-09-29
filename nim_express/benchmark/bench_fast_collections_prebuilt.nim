import std/[os, sets, strutils, tables, times]

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
  if ms <= 0.0:
    return 0.0
  ops.float * 1000.0 / ms

proc buildKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n:
    result[i] = "k" & $i

proc buildVals(n: int, offset = 0): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n:
    result[i] = "v" & $(i + offset)

proc benchStdTable(keys, vals, overwriteVals: seq[string]): PhaseResult =
  let n = keys.len
  var t = initTable[string, string](n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    t[keys[i]] = vals[i]
  let t1 = epochTime()

  var checksum = 0
  for i in 0..<n:
    checksum += t.getOrDefault(keys[i]).len
  let t2 = epochTime()

  for i in 0..<n:
    t[keys[i]] = overwriteVals[i]
  let t3 = epochTime()

  for k, v in t:
    checksum += k.len + v.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2):
    t.del(keys[i])
  let t5 = epochTime()

  result.insertMs = msBetween(t0, t1)
  result.lookupMs = msBetween(t1, t2)
  result.overwriteMs = msBetween(t2, t3)
  result.iterateMs = msBetween(t3, t4)
  result.eraseMs = msBetween(t4, t5)
  result.checksum = checksum

proc benchFastMap(keys, vals, overwriteVals: seq[string]): PhaseResult =
  let n = keys.len
  let t = newFastMap[string]()
  discard t.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    discard t.put(keys[i], vals[i])
  let t1 = epochTime()

  var checksum = 0
  for i in 0..<n:
    checksum += t.getLen(keys[i], 0)
  let t2 = epochTime()

  for i in 0..<n:
    discard t.put(keys[i], overwriteVals[i])
  let t3 = epochTime()

  for keyView, valueView in t.pairsView():
    checksum += keyView.len + valueView.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2):
    discard t.del(keys[i])
  let t5 = epochTime()

  result.insertMs = msBetween(t0, t1)
  result.lookupMs = msBetween(t1, t2)
  result.overwriteMs = msBetween(t2, t3)
  result.iterateMs = msBetween(t3, t4)
  result.eraseMs = msBetween(t4, t5)
  result.checksum = checksum
  t.close()

proc benchStdSet(keys: seq[string]): PhaseResult =
  let n = keys.len
  var s = initHashSet[string](n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    s.incl(keys[i])
  let t1 = epochTime()

  var checksum = 0
  for i in 0..<n:
    if s.contains(keys[i]):
      inc checksum
  let t2 = epochTime()

  for i in 0..<n:
    s.incl(keys[i])
  let t3 = epochTime()

  for key in s:
    checksum += key.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2):
    s.excl(keys[i])
  let t5 = epochTime()

  result.insertMs = msBetween(t0, t1)
  result.lookupMs = msBetween(t1, t2)
  result.overwriteMs = msBetween(t2, t3)
  result.iterateMs = msBetween(t3, t4)
  result.eraseMs = msBetween(t4, t5)
  result.checksum = checksum

proc benchFastSet(keys: seq[string]): PhaseResult =
  let n = keys.len
  let s = newFastSet()
  discard s.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    discard s.incl(keys[i])
  let t1 = epochTime()

  var checksum = 0
  for i in 0..<n:
    if s.contains(keys[i]):
      inc checksum
  let t2 = epochTime()

  for i in 0..<n:
    discard s.incl(keys[i])
  let t3 = epochTime()

  for keyView in s.itemsView():
    checksum += keyView.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2):
    discard s.excl(keys[i])
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

  let keys = buildKeys(n)
  let vals = buildVals(n)
  let overwriteVals = buildVals(n, n)

  echo "Benchmark size N=", n
  echo "Warming up..."
  discard benchStdTable(keys[0..<min(10_000, n)], vals[0..<min(10_000, n)], overwriteVals[0..<min(10_000, n)])
  discard benchFastMap(keys[0..<min(10_000, n)], vals[0..<min(10_000, n)], overwriteVals[0..<min(10_000, n)])
  discard benchStdSet(keys[0..<min(10_000, n)])
  discard benchFastSet(keys[0..<min(10_000, n)])

  echo ""
  let stdTable = benchStdTable(keys, vals, overwriteVals)
  let fastMap = benchFastMap(keys, vals, overwriteVals)
  let stdSet = benchStdSet(keys)
  let fastSet = benchFastSet(keys)

  printResult("Std Table[string,string] Prebuilt", n, stdTable)
  printResult("FastMap FFI (Verstable C) Prebuilt", n, fastMap)
  echo ""
  printResult("Std HashSet[string] Prebuilt", n, stdSet)
  printResult("FastSet FFI (Verstable C) Prebuilt", n, fastSet)
