import std/[os, strutils, tables, times]

import nim_express/fast_hash

type
  PhaseResult = object
    insertMs: float
    lookupMs: float
    overwriteMs: float
    iterateMs: float
    eraseMs: float
    checksum: int64

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

proc benchStdTable(keys: seq[string]): PhaseResult =
  let n = keys.len
  var t = initTable[string, int64](n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    t[keys[i]] = int64(i)
  let t1 = epochTime()

  var checksum = 0'i64
  for i in 0..<n:
    checksum += t.getOrDefault(keys[i], -1)
  let t2 = epochTime()

  for i in 0..<n:
    t[keys[i]] = int64(i + n)
  let t3 = epochTime()

  for key, value in t:
    checksum += int64(key.len) + value
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

proc benchFastMapInt64(keys: seq[string]): PhaseResult =
  let n = keys.len
  let t = newFastMap[int64]()
  discard t.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    discard t.put(keys[i], int64(i))
  let t1 = epochTime()

  var checksum = 0'i64
  for i in 0..<n:
    checksum += t.get(keys[i], -1)
  let t2 = epochTime()

  for i in 0..<n:
    discard t.put(keys[i], int64(i + n))
  let t3 = epochTime()

  for key, value in t.pairs():
    checksum += int64(key.len) + value
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

# getPtrHashed variant: precompute hashes once, use zero-copy ptr probe in the
# hot loop.  For int64 the copy itself is free (single register move), so the
# gain comes entirely from skipping one wyhash call per lookup (~10-24% faster
# at N=200k-500k).  Use this when the same map is queried repeatedly.
proc benchFastMapInt64Hashed(keys: seq[string]): PhaseResult =
  let n = keys.len
  let t = newFastMap[int64]()
  discard t.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    discard t.put(keys[i], int64(i))
  let t1 = epochTime()

  # Precompute hashes once (amortised cost if the map is queried many times)
  var hashes = newSeq[uint64](n)
  for i in 0..<n: hashes[i] = hashKey(keys[i])

  var checksum = 0'i64
  for i in 0..<n:
    let p = t.getPtrHashed(keys[i], hashes[i])
    if p != nil: checksum += p[]
  let t2 = epochTime()

  for i in 0..<n:
    discard t.put(keys[i], int64(i + n))
  let t3 = epochTime()

  for key, value in t.pairs():
    checksum += int64(key.len) + value
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

  echo "Benchmark size N=", n
  echo "Warming up..."
  discard benchStdTable(keys[0..<min(10_000, n)])
  discard benchFastMapInt64(keys[0..<min(10_000, n)])
  discard benchFastMapInt64Hashed(keys[0..<min(10_000, n)])

  echo ""
  let stdTable = benchStdTable(keys)
  let fastMap = benchFastMapInt64(keys)
  let fastMapHashed = benchFastMapInt64Hashed(keys)

  printResult("Std Table[string,int64]", n, stdTable)
  printResult("FastMap[int64]", n, fastMap)
  printResult("FastMap[int64] getPtrHashed", n, fastMapHashed)
