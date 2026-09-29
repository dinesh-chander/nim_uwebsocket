import std/[os, strutils, times]

import nim_express/fast_hash

type
  BenchResult = object
    elapsedMs: float
    checksum: int

proc msBetween(startTs, endTs: float): float {.inline.} =
  (endTs - startTs) * 1000.0

proc buildKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n:
    result[i] = "k" & $i

proc buildVals(n: int, offset = 0): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n:
    result[i] = "v" & $(i + offset)

proc benchLookup(keys, vals: seq[string], repeats: int): BenchResult =
  let m = newFastMap[string]()
  defer: m.close()
  discard m.reserve(keys.len * 2)
  for i in 0..<keys.len:
    discard m.put(keys[i], vals[i])

  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    for i in 0..<keys.len:
      checksum += m.getLen(keys[i], 0)
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchLookupPrehashed(keys, vals: seq[string], repeats: int): BenchResult =
  let m = newFastMap[string]()
  defer: m.close()
  discard m.reserve(keys.len * 2)
  for i in 0..<keys.len:
    discard m.put(keys[i], vals[i])
  # Precompute hashes once
  var hashes = newSeq[uint64](keys.len)
  for i in 0..<keys.len:
    hashes[i] = hashKey(keys[i])

  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    for i in 0..<keys.len:
      checksum += m.getLenHashed(keys[i], hashes[i], 0)
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchInsert(keys, vals: seq[string], repeats: int): BenchResult =
  let t0 = epochTime()
  var checksum = 0
  for iter in 0..<repeats:
    let m = newFastMap[string]()
    discard m.reserve(keys.len * 2)
    for i in 0..<keys.len:
      discard m.put(keys[i], vals[(i + iter) mod vals.len])
    checksum += m.len
    m.close()
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchOverwrite(keys, valsA, valsB: seq[string], repeats: int): BenchResult =
  let m = newFastMap[string]()
  defer: m.close()
  discard m.reserve(keys.len * 2)
  for i in 0..<keys.len:
    discard m.put(keys[i], valsA[i])

  let t0 = epochTime()
  var checksum = 0
  for iter in 0..<repeats:
    let values = if (iter and 1) == 0: valsB else: valsA
    for i in 0..<keys.len:
      discard m.put(keys[i], values[i])
      checksum += values[i].len
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchErase(keys, vals: seq[string], repeats: int): BenchResult =
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    let m = newFastMap[string]()
    discard m.reserve(keys.len * 2)
    for i in 0..<keys.len:
      discard m.put(keys[i], vals[i])
    for i in countup(0, keys.len - 1, 2):
      if m.del(keys[i]):
        inc checksum
    m.close()
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchEraseOnly(keys, vals: seq[string]): BenchResult =
  let m = newFastMap[string]()
  defer: m.close()
  discard m.reserve(keys.len * 2)
  for i in 0..<keys.len:
    discard m.put(keys[i], vals[i])

  let profileReadyFile = getEnv("NX_FAST_MAP_PROFILE_READY_FILE", "")
  if profileReadyFile.len > 0:
    writeFile(profileReadyFile, "ready")

  let profileDelayMs = getEnv("NX_FAST_MAP_PROFILE_DELAY_MS", "0").parseInt
  if profileDelayMs > 0:
    sleep(profileDelayMs)

  let t0 = epochTime()
  var checksum = 0
  for i in countup(0, keys.len - 1, 2):
    if m.del(keys[i]):
      inc checksum
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchIterate(keys, vals: seq[string], repeats: int): BenchResult =
  let m = newFastMap[string]()
  defer: m.close()
  discard m.reserve(keys.len * 2)
  for i in 0..<keys.len:
    discard m.put(keys[i], vals[i])

  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    for keyView, valueView in m.pairsView():
      checksum += keyView.len + valueView.len
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc printResult(name: string, r: BenchResult) =
  echo name
  echo "  elapsed: ", formatFloat(r.elapsedMs, ffDecimal, 3), " ms"
  echo "  checksum: ", r.checksum

when isMainModule:
  var mode = "lookup"
  var n = 200_000
  var repeats = 10
  if paramCount() >= 1:
    mode = paramStr(1)
  if paramCount() >= 2:
    n = parseInt(paramStr(2))
  if paramCount() >= 3:
    repeats = parseInt(paramStr(3))
  if n <= 0 or repeats <= 0:
    quit("n and repeats must be > 0", QuitFailure)

  let keys = buildKeys(n)
  let valsA = buildVals(n)
  let valsB = buildVals(n, n)

  case mode
  of "insert":
    discard benchInsert(keys[0..<min(10_000, n)], valsA[0..<min(10_000, n)], 2)
    printResult("FastMap Hot Insert", benchInsert(keys, valsA, repeats))
  of "lookup":
    discard benchLookup(keys[0..<min(10_000, n)], valsA[0..<min(10_000, n)], 2)
    printResult("FastMap Hot Lookup", benchLookup(keys, valsA, repeats))
  of "lookup_prehashed":
    discard benchLookupPrehashed(keys[0..<min(10_000, n)], valsA[0..<min(10_000, n)], 2)
    printResult("FastMap Hot Lookup (prehashed)", benchLookupPrehashed(keys, valsA, repeats))
  of "overwrite":
    discard benchOverwrite(keys[0..<min(10_000, n)], valsA[0..<min(10_000, n)], valsB[0..<min(10_000, n)], 2)
    printResult("FastMap Hot Overwrite", benchOverwrite(keys, valsA, valsB, repeats))
  of "erase":
    discard benchErase(keys[0..<min(10_000, n)], valsA[0..<min(10_000, n)], 2)
    printResult("FastMap Hot Erase", benchErase(keys, valsA, repeats))
  of "erase_only":
    if getEnv("NX_FAST_MAP_SKIP_WARMUP", "0") != "1":
      discard benchEraseOnly(keys[0..<min(10_000, n)], valsA[0..<min(10_000, n)])
    printResult("FastMap Hot Erase Only", benchEraseOnly(keys, valsA))
  of "iterate":
    discard benchIterate(keys[0..<min(10_000, n)], valsA[0..<min(10_000, n)], 2)
    printResult("FastMap Hot Iterate", benchIterate(keys, valsA, repeats))
  else:
    quit("mode must be one of: insert, lookup, overwrite, erase, erase_only, iterate", QuitFailure)
