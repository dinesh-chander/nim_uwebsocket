import std/[os, strutils, times]

import nim_express/fast_hash
import nim_utils/helpers/[fast_map, fast_set]

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

proc containsHeaderTokenNoCaseLegacy(value, token: string): bool {.inline.} =
  if value.len == 0 or token.len == 0:
    return false
  var i = 0
  while i < value.len:
    while i < value.len and (value[i] == ' ' or value[i] == '\t' or value[i] == ','):
      inc i
    if i >= value.len:
      break
    let start = i
    while i < value.len and value[i] != ',':
      inc i
    var last = i - 1
    while last >= start and (value[last] == ' ' or value[last] == '\t'):
      dec last
    if last >= start and (last - start + 1) == token.len:
      var matched = true
      for j in 0..<token.len:
        if value[start + j].toLowerAscii != token[j]:
          matched = false
          break
      if matched:
        return true
  false

proc containsHeaderTokenNoCaseView(value: fast_map.FastStringView, token: string): bool {.inline.} =
  if value.len == 0 or token.len == 0 or value.data == nil:
    return false
  let chars = cast[ptr UncheckedArray[char]](value.data)
  var i = 0
  while i < value.len:
    while i < value.len and (chars[i] == ' ' or chars[i] == '\t' or chars[i] == ','):
      inc i
    if i >= value.len:
      break
    let start = i
    while i < value.len and chars[i] != ',':
      inc i
    var last = i - 1
    while last >= start and (chars[last] == ' ' or chars[last] == '\t'):
      dec last
    if last >= start and (last - start + 1) == token.len:
      var matched = true
      for j in 0..<token.len:
        var c = chars[start + j]
        if c in 'A'..'Z':
          c = chr(ord(c) + 32)
        if c != token[j]:
          matched = false
          break
      if matched:
        return true
  false

proc benchLookupOwned(n: int): BenchResult =
  let t = newFastMap[string]()
  discard t.reserve(n * 2)
  for i in 0..<n:
    discard t.put(keyAt(i), valAt(i))
  let t0 = epochTime()
  var checksum = 0
  for i in 0..<n:
    checksum += t.get(keyAt(i)).len
  let t1 = epochTime()
  t.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchLookupView(n: int): BenchResult =
  let t = newFastMap[string]()
  discard t.reserve(n * 2)
  for i in 0..<n:
    discard t.put(keyAt(i), valAt(i))
  let t0 = epochTime()
  var checksum = 0
  for i in 0..<n:
    checksum += t.getLen(keyAt(i), 0)
  let t1 = epochTime()
  t.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchIterOwned(n: int): BenchResult =
  let t = newFastMap[string]()
  discard t.reserve(n * 2)
  for i in 0..<n:
    discard t.put(keyAt(i), valAt(i))
  let t0 = epochTime()
  var checksum = 0
  for key, value in t:
    checksum += key.len + value.len
  let t1 = epochTime()
  t.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchIterView(n: int): BenchResult =
  let t = newFastMap[string]()
  discard t.reserve(n * 2)
  for i in 0..<n:
    discard t.put(keyAt(i), valAt(i))
  let t0 = epochTime()
  var checksum = 0
  for keyView, valueView in t.pairsView():
    checksum += keyView.len + valueView.len
  let t1 = epochTime()
  t.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchSetContainsOwned(n: int): BenchResult =
  let s = newFastSet()
  discard s.reserve(n * 2)
  for i in 0..<n:
    discard s.incl(keyAt(i))
  let t0 = epochTime()
  var checksum = 0
  for i in 0..<n:
    if s.contains(keyAt(i)):
      inc checksum
  let t1 = epochTime()
  s.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchSetContainsView(n: int): BenchResult =
  let s = newFastSet()
  discard s.reserve(n * 2)
  for i in 0..<n:
    discard s.incl(keyAt(i))
  let t0 = epochTime()
  var checksum = 0
  for i in 0..<n:
    if s.containsView(fast_set.toFastStringView(keyAt(i))):
      inc checksum
  let t1 = epochTime()
  s.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchSetIterOwned(n: int): BenchResult =
  let s = newFastSet()
  discard s.reserve(n * 2)
  for i in 0..<n:
    discard s.incl(keyAt(i))
  let t0 = epochTime()
  var checksum = 0
  for key in s:
    checksum += key.len
  let t1 = epochTime()
  s.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchSetIterView(n: int): BenchResult =
  let s = newFastSet()
  discard s.reserve(n * 2)
  for i in 0..<n:
    discard s.incl(keyAt(i))
  let t0 = epochTime()
  var checksum = 0
  for keyView in s.itemsView():
    checksum += keyView.len
  let t1 = epochTime()
  s.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchHeaderOwned(n: int): BenchResult =
  let headers = newFastMap[string]()
  discard headers.put("upgrade", "WebSocket")
  discard headers.put("connection", "keep-alive, Upgrade")
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    let upgrade = headers.getOrDefault("upgrade", "").toLowerAscii()
    let connection = headers.getOrDefault("connection", "")
    if upgrade == "websocket" and containsHeaderTokenNoCaseLegacy(connection, "upgrade"):
      inc checksum
  let t1 = epochTime()
  headers.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchHeaderView(n: int): BenchResult =
  let headers = newFastMap[string]()
  discard headers.put("upgrade", "WebSocket")
  discard headers.put("connection", "keep-alive, Upgrade")
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    let upgrade = headers.getView("upgrade")
    if upgrade.equalsIgnoreCaseAscii("websocket") and containsHeaderTokenNoCaseView(headers.getView("connection"), "upgrade"):
      inc checksum
  let t1 = epochTime()
  headers.close()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc printResult(name: string, r: BenchResult) =
  echo name
  echo "  elapsed: ", formatFloat(r.elapsedMs, ffDecimal, 3), " ms"
  echo "  checksum: ", r.checksum

when isMainModule:
  var n = 200_000
  if paramCount() >= 1:
    n = parseInt(paramStr(1))

  discard benchLookupOwned(10_000)
  discard benchLookupView(10_000)
  discard benchIterOwned(10_000)
  discard benchIterView(10_000)
  discard benchSetContainsOwned(10_000)
  discard benchSetContainsView(10_000)
  discard benchSetIterOwned(10_000)
  discard benchSetIterView(10_000)
  discard benchHeaderOwned(10_000)
  discard benchHeaderView(10_000)

  printResult("FastMap Lookup Owned", benchLookupOwned(n))
  printResult("FastMap Lookup View", benchLookupView(n))
  printResult("FastMap Iterate Owned", benchIterOwned(n))
  printResult("FastMap Iterate View", benchIterView(n))
  printResult("FastSet Contains Owned", benchSetContainsOwned(n))
  printResult("FastSet Contains View", benchSetContainsView(n))
  printResult("FastSet Iterate Owned", benchSetIterOwned(n))
  printResult("FastSet Iterate View", benchSetIterView(n))
  printResult("Header Probe Owned", benchHeaderOwned(n))
  printResult("Header Probe View", benchHeaderView(n))
