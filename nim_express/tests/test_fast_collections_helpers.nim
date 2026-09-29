import std/[algorithm, os, strutils, unittest]

import ../../nim_utils/src/nim_utils/helpers/[fast_map, fast_set]

suite "nim_express helper fast collections":
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  let fastMapSource = readFile(repoRoot / "nim_utils/src/nim_utils/helpers/fast_map.nim")
  let fastSetSource = readFile(repoRoot / "nim_utils/src/nim_utils/helpers/fast_set.nim")

  test "fast_map helper supports string and int64 values":
    let strMap = newFastMap[string]()
    check strMap.reserve(32)
    check strMap.put("a", "1")
    check strMap.put("b", "2")
    check strMap.get("a", "") == "1"
    check strMap.len == 2
    check strMap.del("b")
    check strMap.len == 1
    strMap.close()

    let i64Map = newFastMap[int64]()
    check i64Map.reserve(32)
    check i64Map.put("x", 10)
    check i64Map.get("x", -1) == 10
    var outVal: int64
    check i64Map.tryGet("x", outVal)
    check outVal == 10
    i64Map.close()

  test "fast_set helper supports include and iterate":
    let setObj = newFastSet()
    check setObj.reserve(32)
    check setObj.incl("alpha")
    check setObj.incl("beta")
    check setObj.contains("alpha")
    check setObj.len == 2
    check setObj.excl("beta")
    check setObj.len == 1
    var seen = false
    for item in setObj:
      if item == "alpha":
        seen = true
    check seen
    setObj.close()

  test "borrowed view APIs avoid eager string materialization":
    let strMap = newFastMap[string]()
    check strMap.put("alpha", "one")
    check strMap.put("beta", "two")
    check strMap.put("xhr", "XMLHttpRequest")
    check strMap.put("ctype", "application/json; charset=utf-8")
    check strMap.put("htmx", "true")

    var view: fast_map.FastStringView
    check strMap.tryGetView("alpha", view)
    check view.len == 3
    check $view == "one"
    check strMap.getLen("beta", -1) == 3
    check strMap.getView("xhr").equalsIgnoreCaseAscii("xmlhttprequest")
    check strMap.getView("ctype").containsAscii("application/json")
    check strMap.getView("ctype").containsIgnoreCaseAscii("APPLICATION/JSON")
    check strMap.getView("htmx").equalsAscii("true")
    check strMap.containsC("alpha".cstring)
    check strMap.getLen("beta".cstring, -1) == 3
    check strMap.getView("alpha".cstring).equalsAscii("one")
    var alphaKey: fast_map.FastStringView
    for keyView, _ in strMap.pairsView():
      if $keyView == "alpha":
        alphaKey = keyView
        break
    check strMap.containsView(alphaKey)
    check strMap.getLen(alphaKey, -1) == 3

    var seenPairs: seq[(string, string)]
    for keyView, valueView in strMap.pairsView():
      seenPairs.add(($keyView, $valueView))
    seenPairs.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
    check seenPairs == @[
      ("alpha", "one"),
      ("beta", "two"),
      ("ctype", "application/json; charset=utf-8"),
      ("htmx", "true"),
      ("xhr", "XMLHttpRequest")
    ]
    strMap.close()

    let setObj = newFastSet()
    check setObj.incl("alpha")
    check setObj.incl("beta")
    check setObj.containsC("alpha".cstring)
    var alphaSetView: fast_set.FastStringView
    for itemView in setObj.itemsView():
      if $itemView == "alpha":
        alphaSetView = itemView
        break
    check setObj.containsView(alphaSetView)
    check setObj.exclView(alphaSetView)
    check not setObj.contains("alpha")
    check setObj.inclC("alpha".cstring)
    check setObj.containsOrInclC("beta".cstring)
    check not setObj.containsOrInclView(fast_set.toFastStringView("gamma"))
    check setObj.contains("gamma")
    check setObj.missingOrExclView(fast_set.toFastStringView("missing"))
    check not setObj.missingOrExclC("beta".cstring)
    var seenItems: seq[string]
    for itemView in setObj.itemsView():
      seenItems.add($itemView)
    seenItems.sort()
    check seenItems == @["alpha", "gamma"]
    setObj.close()

  test "constructors centralize native storage allocation":
    check fastMapSource.contains("proc releaseFastMapStorage(storage: var FastMapStorageObj)")
    check fastMapSource.contains("proc `=destroy`(storage: var FastMapStorageObj)")
    check fastSetSource.contains("proc releaseFastSetStorage(storage: var FastSetStorageObj)")
    check fastSetSource.contains("proc `=destroy`(storage: var FastSetStorageObj)")
    check not fastMapSource.contains("FastMapStorage = ref FastMapStorageObj")

  test "fast_map and fast_set sequence helpers preserve visible contents":
    let strMap = newFastMap[string]()
    check strMap.put("alpha", "1")
    check strMap.put("beta", "2")
    check strMap.put("alpha", "3")
    var pairs = strMap.pairsSeq()
    pairs.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
    check pairs == @[("alpha", "3"), ("beta", "2")]
    var iterPairs: seq[(string, string)]
    for key, value in strMap:
      iterPairs.add((key, value))
    iterPairs.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
    check iterPairs == pairs

    let setObj = newFastSet()
    check setObj.incl("beta")
    check setObj.incl("alpha")
    check setObj.incl("alpha")
    var items = setObj.itemsSeq()
    items.sort()
    check items == @["alpha", "beta"]

    strMap.close()
    setObj.close()

  test "fast_map arena mode preserves visible behavior":
    let arenaMap = newFastArenaMap[string](512)
    check arenaMap.put("alpha", "1")
    check arenaMap.put("beta", "2")
    check arenaMap.put("alpha", "3")
    check arenaMap.get("alpha", "") == "3"
    check arenaMap.contains("beta")
    check arenaMap.del("beta")
    check not arenaMap.contains("beta")
    check arenaMap.put("gamma", "xyz")
    check arenaMap.getLen("gamma", -1) == 3
    arenaMap.clear()
    check arenaMap.len == 0
    check arenaMap.put("delta", "4")
    check arenaMap.get("delta", "") == "4"
    arenaMap.close()

    let arenaI64 = newFastArenaMap[int64](512)
    check arenaI64.put("count", 7)
    check arenaI64.get("count", -1) == 7
    arenaI64.close()

  test "fast_set arena mode preserves visible behavior":
    let arenaSet = newFastArenaSet(512)
    check arenaSet.incl("alpha")
    check arenaSet.incl("beta")
    check arenaSet.incl("alpha")
    check arenaSet.contains("alpha")
    check arenaSet.containsC("beta".cstring)
    check arenaSet.len == 2
    check arenaSet.excl("beta")
    check not arenaSet.contains("beta")
    arenaSet.clear()
    check arenaSet.len == 0
    check arenaSet.incl("gamma")
    check arenaSet.contains("gamma")
    arenaSet.close()

  test "fast_set exposes std-set-style convenience helpers":
    let setObj = newFastSet(["alpha", "beta", "alpha"])
    check setObj.len == 2
    check setObj.containsOrIncl("alpha")
    check not setObj.containsOrIncl("gamma")
    check setObj.contains("gamma")
    check setObj.missingOrExcl("missing")
    check not setObj.missingOrExcl("beta")
    check not setObj.contains("beta")

    let reserved = newFastHashSet(8)
    check reserved.incl("delta")
    check reserved.contains("delta")

    let arenaSet = newFastArenaHashSet(["one", "two"], 512)
    check arenaSet.contains("one")
    check arenaSet.contains("two")

    let setCopy = newFastSet(["gamma", "alpha"])
    check setObj == setCopy
    check $setObj in [
      "{\"alpha\", \"gamma\"}",
      "{\"gamma\", \"alpha\"}"
    ]

    arenaSet.close()
    reserved.close()
    setCopy.close()
    setObj.close()

  test "fast_map exposes nim-table-style convenience methods":
    let strMap = newFastMap[string]([("alpha", "1"), ("beta", "2")])
    check strMap.getOrDefault("alpha") == "1"
    check strMap.getOrDefault("missing") == ""
    check strMap["alpha"] == "1"
    expect KeyError:
      discard strMap["missing"]
    check strMap.hasKeyOrPut("alpha", "9")
    check not strMap.hasKeyOrPut("gamma", "3")
    check strMap["gamma"] == "3"
    strMap["alpha"] = "uno"
    discard strMap.mgetOrPut("delta", "4")
    strMap["delta"] = strMap["delta"] & "!"
    check strMap["alpha"] == "uno"
    check strMap["delta"] == "4!"

    var popped = ""
    check strMap.pop("beta", popped)
    check popped == "2"
    check not strMap.hasKey("beta")
    check not strMap.pop("missing", popped)

    var keysSeen: seq[string]
    var valuesSeen: seq[string]
    for key in strMap.keys():
      keysSeen.add(key)
    for value in strMap.values():
      valuesSeen.add(value)
    # mvalues/mpairs return copies with raw pointer storage;
    # use pairsView + put for mutation
    for kv, vv in strMap.pairsView():
      if $vv == "3":
        strMap[$kv] = "tres"
    for kv, vv in strMap.pairsView():
      if $kv == "delta":
        strMap["delta"] = $vv & "?"
    keysSeen.sort()
    valuesSeen.sort()
    check keysSeen == @["alpha", "delta", "gamma"]
    check valuesSeen == @["3", "4!", "uno"]
    check strMap["gamma"] == "tres"
    check strMap["delta"] == "4!?"

    let strMapCopy = newFastTable[string]([("gamma", "tres"), ("alpha", "uno"), ("delta", "4!?")])
    check strMap == strMapCopy
    strMap.close()
    strMapCopy.close()

    let i64Map = newFastMap[int64]([("one", 1'i64), ("two", 2'i64)])
    check i64Map.getOrDefault("one") == 1
    check i64Map.getOrDefault("missing") == 0
    check i64Map["one"] == 1
    expect KeyError:
      discard i64Map["missing"]
    check i64Map.hasKeyOrPut("one", 9)
    check not i64Map.hasKeyOrPut("three", 3)
    i64Map["one"] = 11
    check i64Map["one"] == 11
    i64Map.mgetOrPut("counter", 5).inc
    check i64Map["counter"] == 6
    i64Map.mgetOrPut("counter").inc
    check i64Map["counter"] == 7

    var intPairs: seq[(string, int64)]
    var intValues: seq[int64]
    for key, value in i64Map.pairs():
      intPairs.add((key, value))
    for value in i64Map.values():
      intValues.add(value)
    intPairs.sort(proc (a, b: (string, int64)): int = cmp(a[0], b[0]))
    intValues.sort()
    check intPairs == @[("counter", 7'i64), ("one", 11'i64), ("three", 3'i64), ("two", 2'i64)]
    check intValues == @[2'i64, 3'i64, 7'i64, 11'i64]

    for value in i64Map.mvalues():
      value.inc
    check i64Map["one"] == 12
    check i64Map["counter"] == 8

    for key, value in i64Map.mpairs():
      if key == "three":
        value = 30
    check i64Map["three"] == 30

    var taken: int64
    check i64Map.take("two", taken)
    check taken == 3
    check not i64Map.hasKey("two")

    let i64MapCopy = newFastMap[int64]([("counter", 8'i64), ("three", 30'i64), ("one", 12'i64)])
    check i64Map == i64MapCopy
    i64Map.close()
    i64MapCopy.close()

  test "fast_map supports constructor helpers and backend capability gating":
    let words = @["alpha", "beta", "gamma"]
    let wordMap = newFastMapFrom(words, proc(x: string): string = x)
    check wordMap["alpha"] == "alpha"
    check wordMap["gamma"] == "gamma"

    let reservedMap = newFastMap[string](8)
    reservedMap["delta"] = "four"
    check reservedMap["delta"] == "four"
    check $reservedMap == "{\"delta\": \"four\"}"

    let nums = @[10'i64, 20'i64]
    let numMap = newFastTableFrom(nums, proc(x: int64): string = $x)
    check numMap["10"] == 10
    check numMap["20"] == 20
    check $numMap in ["{\"10\": 10, \"20\": 20}", "{\"20\": 20, \"10\": 10}"]
    reservedMap.close()
    wordMap.close()
    numMap.close()

    check compiles((block:
      let m = newFastMap[int64]()
      discard m.mgetOrPut("a", 1)
    ))
    check compiles((block:
      let m = newFastMap[string]()
      discard m.mgetOrPut("a", "x")
    ))
    check compiles((block:
      let m = newFastMap[int64]([("a", 1'i64)])
      for _, value in m.mpairs():
        value = value + 1
    ))
    check compiles((block:
      let m = newFastMap[string]([("a", "x")])
      for _, value in m.mpairs():
        value.add("y")
    ))
    check compiles((block:
      let m = newFastMap[int64]([("a", 1'i64)])
      for value in m.mvalues():
        value = value + 1
    ))
    check compiles((block:
      let m = newFastMap[string]([("a", "x")])
      for value in m.mvalues():
        value.add("y")
    ))
    check compiles((block:
      {.warning[Deprecated]: off.}
      let m = newFastMap[int64](4)
      m.add("a", 1)
      check m["a"] == 1
    ))
