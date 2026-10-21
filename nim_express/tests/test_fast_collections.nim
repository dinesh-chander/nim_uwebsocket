import std/unittest

import ../src/nim_express/fast_hash

suite "Fast collections":
  test "FastMap basic operations and overwrite":
    let map = newFastMap[string]()
    check map.len == 0
    check map.reserve(128)
    check map.put("alpha", "1")
    check map.put("beta", "2")
    check map.len == 2
    check map.contains("alpha")
    check map.get("alpha") == "1"
    check map.get("missing", "fallback") == "fallback"

    # Insert semantics replace existing key/value.
    check map.put("alpha", "3")
    check map.get("alpha") == "3"
    check map.len == 2

    check map.del("beta")
    check not map.contains("beta")
    check map.len == 1

    map["gamma"] = "9"
    check map["gamma"] == "9"

    var seenAlpha = false
    var seenGamma = false
    for k, v in map:
      if k == "alpha" and v == "3":
        seenAlpha = true
      if k == "gamma" and v == "9":
        seenGamma = true
    check seenAlpha
    check seenGamma

    map.clear()
    check map.len == 0
    map.close()

  test "FastMap[int64] basic operations and overwrite":
    let map = newFastMap[int64]()
    check map.reserve(128)
    check map.put("x", 10)
    check map.put("y", 20)
    check map.len == 2
    check map.contains("x")
    check map.get("x", -1) == 10
    check map.get("missing", -1) == -1

    var outVal: int64
    check map.tryGet("y", outVal)
    check outVal == 20

    check map.put("x", 99)
    check map.get("x", -1) == 99

    check map.del("y")
    check not map.contains("y")
    map.clear()
    check map.len == 0
    map.close()

  test "FastSet basic operations":
    let setObj = newFastSet()
    check setObj.len == 0
    check setObj.reserve(128)
    check setObj.incl("a")
    check setObj.incl("b")
    check setObj.contains("a")
    check setObj.len == 2

    # Inserting duplicate keys should keep cardinality stable.
    check setObj.incl("a")
    check setObj.len == 2

    check setObj.excl("b")
    check not setObj.contains("b")
    check setObj.len == 1

    var seenA = false
    for key in setObj:
      if key == "a":
        seenA = true
    check seenA

    setObj.clear()
    check setObj.len == 0
    setObj.close()

  test "Compatibility aliases still work":
    let mapAlias = newFastHashTable[string]()
    let setAlias = newFastHashSet()
    check mapAlias.put("k", "v")
    check mapAlias.get("k") == "v"
    check setAlias.incl("k")
    check setAlias.contains("k")
    mapAlias.close()
    setAlias.close()
