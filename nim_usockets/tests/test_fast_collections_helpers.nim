import std/[unittest, os, strutils]

import ../src/nim_usockets/fast_hash

suite "nim_usockets helper fast collections":
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  let fastMapSource = readFile(repoRoot / "nim_utils/src/nim_utils/helpers/fast_map.nim")
  let fastSetSource = readFile(repoRoot / "nim_utils/src/nim_utils/helpers/fast_set.nim")

  test "fast_map helper supports string and int64 values":
    let strMap = newFastMap[string]()
    check strMap.reserve(32)
    check strMap.put("k1", "v1")
    check strMap.put("k2", "v2")
    check strMap.get("k1", "") == "v1"
    check strMap.contains("k2")
    check strMap.del("k2")
    strMap.close()

    let i64Map = newFastMap[int64]()
    check i64Map.reserve(32)
    check i64Map.put("n", 42)
    check i64Map.get("n", -1) == 42
    i64Map.close()

  test "fast_set helper supports include/exclude":
    let setObj = newFastSet()
    check setObj.reserve(32)
    check setObj.incl("x")
    check setObj.incl("y")
    check setObj.contains("x")
    check setObj.excl("y")
    check not setObj.contains("y")
    setObj.close()

  test "streaming iterators avoid seq materialization wrappers":
    let strMap = newFastMap[string]()
    discard strMap.put("a", "1")
    discard strMap.put("b", "2")
    var seenPairs = 0
    for key, value in strMap.pairs:
      check key.len == 1
      check value.len == 1
      inc seenPairs
    check seenPairs == 2
    strMap.close()

    let setObj = newFastSet()
    discard setObj.incl("x")
    discard setObj.incl("y")
    var seenItems = 0
    for key in setObj.items:
      check key in ["x", "y"]
      inc seenItems
    check seenItems == 2
    setObj.close()

  test "constructors bind native finalizers":
    check fastMapSource.contains("proc releaseFastMapStorage(storage: var FastMapStorageObj)")
    check fastMapSource.contains("proc `=destroy`(storage: var FastMapStorageObj)")
    check fastSetSource.contains("proc releaseFastSetStorage(storage: var FastSetStorageObj)")
    check fastSetSource.contains("proc `=destroy`(storage: var FastSetStorageObj)")
    check not fastMapSource.contains("FastMapStorage = ref FastMapStorageObj")
    check not fastMapSource.contains("let items = map.pairsSeq()")
    check not fastSetSource.contains("let keys = setObj.itemsSeq()")

  test "arena map constructor is available":
    let arenaMap = newFastArenaMap[string](512)
    check arenaMap.put("a", "1")
    check arenaMap.get("a", "") == "1"
    arenaMap.close()

  test "arena set constructor is available":
    let arenaSet = newFastArenaSet(512)
    check arenaSet.incl("a")
    check arenaSet.contains("a")
    arenaSet.close()

  test "fast_set convenience constructors compile and behave":
    let setObj = newFastSet(["a", "b", "a"])
    check setObj.len == 2
    check setObj.containsOrIncl("a")
    check not setObj.containsOrIncl("c")
    check setObj.contains("c")
    check setObj.missingOrExcl("missing")
    check not setObj.missingOrExcl("b")
    check not setObj.containsOrInclC("b".cstring)
    check setObj.contains("b")
    check not setObj.containsOrInclView(fast_set.toFastStringView("d"))
    check setObj.contains("d")
    check setObj.missingOrExclView(fast_set.toFastStringView("absent"))
    check not setObj.missingOrExclC("a".cstring)

    let arenaSet = newFastArenaHashSet(["x", "y"], 512)
    check arenaSet.contains("x")
    check arenaSet.contains("y")
    let setCopy = newFastHashSet(["b", "c", "d"])
    check setObj == setCopy
    setObj.close()
    arenaSet.close()
    setCopy.close()
