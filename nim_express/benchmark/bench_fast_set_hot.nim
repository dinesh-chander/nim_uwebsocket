import std/[os, strutils, times]

import ../../nim_utils/src/nim_utils/helpers/fast_set

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

proc benchLookup(keys: seq[string], repeats: int): BenchResult =
  let s = newFastSet()
  defer: s.close()
  discard s.reserve(keys.len * 2)
  for key in keys:
    discard s.incl(key)

  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    for key in keys:
      if s.contains(key):
        inc checksum
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchLookupPrehashed(keys: seq[string], repeats: int): BenchResult =
  let s = newFastSet()
  defer: s.close()
  discard s.reserve(keys.len * 2)
  for key in keys:
    discard s.incl(key)

  var views = newSeq[FastStringView](keys.len)
  for i, key in keys:
    views[i] = toFastStringView(key)

  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    for view in views:
      if s.containsView(view):
        inc checksum
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchInsert(keys: seq[string], repeats: int): BenchResult =
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    let s = newFastSet()
    discard s.reserve(keys.len * 2)
    for key in keys:
      discard s.incl(key)
    checksum += s.len
    s.close()
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchOverwrite(keys: seq[string], repeats: int): BenchResult =
  let s = newFastSet()
  defer: s.close()
  discard s.reserve(keys.len * 2)
  for key in keys:
    discard s.incl(key)

  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    for key in keys:
      if s.incl(key):
        inc checksum
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchErase(keys: seq[string], repeats: int): BenchResult =
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    let s = newFastSet()
    discard s.reserve(keys.len * 2)
    for key in keys:
      discard s.incl(key)
    for i in countup(0, keys.len - 1, 2):
      if s.excl(keys[i]):
        inc checksum
    s.close()
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchEraseOnly(keys: seq[string]): BenchResult =
  let s = newFastSet()
  defer: s.close()
  discard s.reserve(keys.len * 2)
  for key in keys:
    discard s.incl(key)

  let profileReadyFile = getEnv("NX_FAST_SET_PROFILE_READY_FILE", "")
  if profileReadyFile.len > 0:
    writeFile(profileReadyFile, "ready")

  let profileDelayMs = getEnv("NX_FAST_SET_PROFILE_DELAY_MS", "0").parseInt
  if profileDelayMs > 0:
    sleep(profileDelayMs)

  let t0 = epochTime()
  var checksum = 0
  for i in countup(0, keys.len - 1, 2):
    if s.excl(keys[i]):
      inc checksum
  let t1 = epochTime()
  BenchResult(elapsedMs: msBetween(t0, t1), checksum: checksum)

proc benchIterate(keys: seq[string], repeats: int): BenchResult =
  let s = newFastSet()
  defer: s.close()
  discard s.reserve(keys.len * 2)
  for key in keys:
    discard s.incl(key)

  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    for keyView in s.itemsView():
      checksum += keyView.len
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

  case mode
  of "insert":
    discard benchInsert(keys[0..<min(10_000, n)], 2)
    printResult("FastSet Hot Insert", benchInsert(keys, repeats))
  of "lookup":
    discard benchLookup(keys[0..<min(10_000, n)], 2)
    printResult("FastSet Hot Lookup", benchLookup(keys, repeats))
  of "lookup_view":
    discard benchLookupPrehashed(keys[0..<min(10_000, n)], 2)
    printResult("FastSet Hot Lookup (view)", benchLookupPrehashed(keys, repeats))
  of "overwrite":
    discard benchOverwrite(keys[0..<min(10_000, n)], 2)
    printResult("FastSet Hot Overwrite", benchOverwrite(keys, repeats))
  of "erase":
    discard benchErase(keys[0..<min(10_000, n)], 2)
    printResult("FastSet Hot Erase", benchErase(keys, repeats))
  of "erase_only":
    if getEnv("NX_FAST_SET_SKIP_WARMUP", "0") != "1":
      discard benchEraseOnly(keys[0..<min(10_000, n)])
    printResult("FastSet Hot Erase Only", benchEraseOnly(keys))
  of "iterate":
    discard benchIterate(keys[0..<min(10_000, n)], 2)
    printResult("FastSet Hot Iterate", benchIterate(keys, repeats))
  else:
    quit("mode must be one of: insert, lookup, lookup_view, overwrite, erase, erase_only, iterate", QuitFailure)
