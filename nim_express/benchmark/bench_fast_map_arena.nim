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

proc benchShortLivedDefault(n, perMap: int): BenchResult =
  let t0 = epochTime()
  var checksum = 0
  for iter in 0..<n:
    let m = newFastMap[string]()
    for i in 0..<perMap:
      discard m.put(keyAt(i), valAt(iter + i))
    for i in 0..<perMap:
      checksum += m.getLen(keyAt(i), 0)
    m.close()
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchShortLivedArena(n, perMap: int): BenchResult =
  let t0 = epochTime()
  var checksum = 0
  for iter in 0..<n:
    let m = newFastArenaMap[string](1024)
    for i in 0..<perMap:
      discard m.put(keyAt(i), valAt(iter + i))
    for i in 0..<perMap:
      checksum += m.getLen(keyAt(i), 0)
    m.close()
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchReuseDefault(n, perMap: int): BenchResult =
  let m = newFastMap[string]()
  defer: m.close()
  let t0 = epochTime()
  var checksum = 0
  for iter in 0..<n:
    m.clear()
    for i in 0..<perMap:
      discard m.put(keyAt(i), valAt(iter + i))
    for i in 0..<perMap:
      checksum += m.getLen(keyAt(i), 0)
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchReuseArena(n, perMap: int): BenchResult =
  let m = newFastArenaMap[string](1024)
  defer: m.close()
  let t0 = epochTime()
  var checksum = 0
  for iter in 0..<n:
    m.clear()
    for i in 0..<perMap:
      discard m.put(keyAt(i), valAt(iter + i))
    for i in 0..<perMap:
      checksum += m.getLen(keyAt(i), 0)
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

  discard benchShortLivedDefault(10_000, perMap)
  discard benchShortLivedArena(10_000, perMap)
  discard benchReuseDefault(10_000, perMap)
  discard benchReuseArena(10_000, perMap)

  printResult("FastMap Default Short-Lived", benchShortLivedDefault(n, perMap))
  printResult("FastMap Arena Short-Lived", benchShortLivedArena(n, perMap))
  printResult("FastMap Default Reuse", benchReuseDefault(n, perMap))
  printResult("FastMap Arena Reuse", benchReuseArena(n, perMap))
