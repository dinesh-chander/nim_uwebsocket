import std/[os, strutils, times]

import nim_express/fast_hash

type
  BenchResult = object
    elapsedMs: float
    checksum: int

proc msBetween(startTs, endTs: float): float {.inline.} =
  (endTs - startTs) * 1000.0

proc keyAt(i: int): string {.inline.} =
  "k" & $i

proc valAt(i: int): string {.inline.} =
  "v" & $i

proc benchSmallFastMap(n, perMap: int): BenchResult =
  let t0 = epochTime()
  var checksum = 0
  for iter in 0..<n:
    let m = newFastMap[string]()
    for i in 0..<perMap:
      discard m.put(keyAt(i), valAt(iter + i))
    for i in 0..<perMap:
      checksum += m.getLen(keyAt(i), 0)
    for k, v in m:
      checksum += k.len + v.len
    m.close()
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchSmallFastSet(n, perSet: int): BenchResult =
  let t0 = epochTime()
  var checksum = 0
  for iter in 0..<n:
    let s = newFastSet()
    for i in 0..<perSet:
      discard s.incl(keyAt(iter + i))
    for i in 0..<perSet:
      if s.contains(keyAt(iter + i)):
        inc checksum
    for item in s:
      checksum += item.len
    s.close()
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc printResult(name: string, r: BenchResult) =
  echo name
  echo "  elapsed: ", formatFloat(r.elapsedMs, ffDecimal, 3), " ms"
  echo "  checksum: ", r.checksum

when isMainModule:
  var n = 200_000
  var perMap = 6
  if paramCount() >= 1:
    n = parseInt(paramStr(1))
  if paramCount() >= 2:
    perMap = parseInt(paramStr(2))

  discard benchSmallFastMap(10_000, perMap)
  discard benchSmallFastSet(10_000, perMap)

  printResult("FastMap Small Lifecycle", benchSmallFastMap(n, perMap))
  printResult("FastSet Small Lifecycle", benchSmallFastSet(n, perMap))
