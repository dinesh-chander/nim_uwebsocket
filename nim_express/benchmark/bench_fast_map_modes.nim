import std/[os, strutils, times]

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

proc keyAt(i: int): string {.inline.} =
  "k" & $i

proc valAt(i: int): string {.inline.} =
  "v" & $i

proc benchFastMapDefault(n: int): PhaseResult =
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

proc benchFastMapArena(n: int): PhaseResult =
  let t = newFastArenaMap[string](64 * 1024)
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

proc printResult(name: string, r: PhaseResult) =
  echo name
  echo "  erase: ", formatFloat(r.eraseMs, ffDecimal, 3), " ms"
  echo "  insert: ", formatFloat(r.insertMs, ffDecimal, 3), " ms"
  echo "  iterate: ", formatFloat(r.iterateMs, ffDecimal, 3), " ms"
  echo "  lookup: ", formatFloat(r.lookupMs, ffDecimal, 3), " ms"
  echo "  overwrite: ", formatFloat(r.overwriteMs, ffDecimal, 3), " ms"
  echo "  checksum: ", r.checksum

when isMainModule:
  var n = 50_000
  if paramCount() >= 1:
    n = parseInt(paramStr(1))

  discard benchFastMapDefault(10_000)
  discard benchFastMapArena(10_000)

  printResult("FastMap Default", benchFastMapDefault(n))
  printResult("FastMap Arena", benchFastMapArena(n))
