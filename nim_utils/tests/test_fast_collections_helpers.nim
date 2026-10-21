import std/[algorithm, os, osproc, strutils, unittest]

import ../src/nim_utils/helpers/[fast_map, fast_set]

const F6ProbeKey = "nim-utils-f6-probe"

when isMainModule:
  # Invoked by the F6 cross-process test to sample the per-process hash seed.
  if paramCount() >= 2 and paramStr(1) == "--print-hash":
    echo $fast_map.hashKey(F6ProbeKey)
    quit(0)

suite "nim_utils fast collections helpers":
  when defined(nimUtilsHashSeedTest):
    test "fast_map and fast_set use process-seeded string hashes":
      check fast_map.fastMapHashSeedForTest() != 0'u64
      let h1 = fast_map.hashKey("content-type")
      let h2 = fast_map.hashKey("content-type")
      check h1 == h2
      check fast_set.fastSetHashForTest("content-type") == h1

      let map = newFastMap[string](8)
      check map.put("content-type", "text/plain")
      check map.get("content-type", "") == "text/plain"

      let setObj = newFastSet(8)
      check setObj.incl("content-type")
      check setObj.contains("content-type")
      setObj.close()
      map.close()

    test "F6: hash keys with the per-process seed, not the fixed wyhash seed":
      # Pure-Nim backends hash via hashKey with the per-process seed; a fixed
      # public seed would make every process agree on one value forever.
      let nimHash = fast_map.hashKey(F6ProbeKey)
      # Historical fixed-seed wyhash outputs for this key; a fixed public
      # seed would return exactly one of these.
      check nimHash != 0x11bc7f8ac023241c'u64 # wyhash(key, 0xca813bf4c7abf0a9)
      check nimHash != 0x5b206422c55c4179'u64 # wyhash(key, 0)
      # The seed is per-process random: two fresh runs hash the same key
      # differently (the old code produced one stable value forever).
      let probeCmd = "\"" & paramStr(0) & "\" --print-hash"
      let run1 = execCmdEx(probeCmd).output
      let run2 = execCmdEx(probeCmd).output
      check run1 != ""
      check run2 != ""
      check run1 != run2

  test "fast_map survives high load insert delete and resize":
    let map = newFastMap[string](8)
    for i in 0 ..< 2048:
      check map.put("key-" & align($i, 4, '0'), "value-" & $i)
    check map.len == 2048

    for i in countup(0, 2047, 3):
      check map.del("key-" & align($i, 4, '0'))
    for i in countup(0, 2047, 3):
      check not map.contains("key-" & align($i, 4, '0'))

    for i in 2048 ..< 4096:
      check map.put("key-" & align($i, 4, '0'), "value-" & $i)
    for i in 1 ..< 4096:
      if i mod 3 != 0 or i >= 2048:
        let key = "key-" & align($i, 4, '0')
        check map.get(key, "") == "value-" & $i
    map.close()

  test "fast_map reuses Swiss-table tombstones":
    let map = newFastMap[int64](16)
    for i in 0 ..< 256:
      check map.put("slot-" & $i, int64(i))
    for i in 0 ..< 256:
      if (i and 1) == 0:
        check map.del("slot-" & $i)
    for i in 0 ..< 256:
      if (i and 1) == 0:
        check map.put("reuse-" & $i, int64(i * 10))
    for i in 0 ..< 256:
      if (i and 1) == 0:
        check map.get("reuse-" & $i, -1) == int64(i * 10)
      else:
        check map.get("slot-" & $i, -1) == int64(i)
    map.close()

  test "fast_map handles same-hash probe groups with precomputed hash API":
    let map = newFastMap[string](32)
    const forcedHash = 0x1234_5678_9ABC_DEF0'u64
    let keys = @["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
    for key in keys:
      check map.putHashed(key, forcedHash, key.toUpperAscii())

    var seen: seq[string]
    for key in keys:
      var value: fast_map.FastStringView
      check map.tryGetViewHashed(key, forcedHash, value)
      check $value == key.toUpperAscii()
      seen.add($value)
    seen.sort()
    check seen == @["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT", "GOLF", "HOTEL"]
    map.close()

  test "fast_map putHashed updates identical key across caller hash mismatch":
    let map = newFastMap[string](8)
    const hashOne = 0x1111_2222_3333_4444'u64
    const hashTwo = 0x9999_AAAA_BBBB_CCCC'u64
    check map.putHashed("stable", hashOne, "first")
    check map.putHashed("stable", hashTwo, "second")
    check map.len == 1

    var value: fast_map.FastStringView
    check map.tryGetViewHashed("stable", hashOne, value)
    check $value == "second"
    check map.tryGetViewHashed("stable", hashTwo, value)
    check $value == "second"
    map.close()

  test "fast_map rejects oversized keys before Swiss-table byte comparison":
    let map = newFastMap[string](8)
    const forcedHash = 0xA5A5_A5A5_A5A5_A5A5'u64
    let maxKey = repeat("a", 65535)
    let overKey = maxKey & "b"

    check map.put(maxKey, "max")
    check map.get(maxKey, "") == "max"
    check map.putHashed("", forcedHash, "empty")

    var value: fast_map.FastStringView
    check not map.tryGetViewHashed(overKey, forcedHash, value)
    check not map.contains(overKey)
    expect ValueError:
      discard map.put(overKey, "too-long")
    expect ValueError:
      discard map.putHashed(overKey, forcedHash, "too-long")
    map.close()

  test "fast_map rejects impossible reserve before allocation":
    let map = newFastMap[string](8)
    expect OverflowDefect:
      discard map.reserve(high(int))
    check map.len == 0
    check map.put("after-overflow", "still-usable")
    check map.get("after-overflow", "") == "still-usable"
    map.close()

  test "fast_map invalid borrowed views do not match or delete empty keys":
    let stringMap = newFastMap[string](8)
    check stringMap.put("", "empty")
    let badView = fast_map.FastStringView(data: nil, len: 1)
    check not stringMap.containsView(badView)
    check not stringMap.delView(badView)
    check stringMap.contains("")
    check stringMap.get("", "") == "empty"
    stringMap.close()

    let intMap = newFastMap[int64](8)
    check intMap.put("", 42'i64)
    check not intMap.containsView(badView)
    check not intMap.delView(badView)
    check intMap.contains("")
    check intMap.get("", -1) == 42'i64
    intMap.close()

  test "fast_map pointer-key lookups match string-key insert ordering":
    let map = newFastMap[string](32)
    var keys = @["Content-Type", "X-Request-Id", "Accept", "Authorization", "User-Agent"]
    for key in keys:
      check map.put(key, key.toLowerAscii())
    for key in keys:
      let ckey = key.cstring
      check map.containsC(ckey)
      check map.getView(ckey).equalsAscii(key.toLowerAscii())
    map.close()

  when sizeof(int) >= 8:
    test "fast_map failed oversized update preserves old value":
      let map = newFastMap[string](64)
      check map.put("stable", "old-value")
      var before: fast_map.FastStringView
      check map.tryGetView("stable", before)
      check $before == "old-value"

      let hugeValue = repeat("x", 65536)
      expect ValueError:
        discard map.put("stable", hugeValue)

      var after: fast_map.FastStringView
      check map.tryGetView("stable", after)
      check $after == "old-value"
      map.close()

    test "fast_map remains stable after overwrite/delete arena churn":
      let map = newFastMap[string](64)
      for cycle in 0 ..< 200:
        let growValue = repeat("x", 512 + cycle)
        check map.put("stable", growValue)
        check map.get("stable", "") == growValue
        check map.put("temp-" & $cycle, repeat("y", 256))
        check map.del("temp-" & $cycle)
      check map.len == 1
      check map.get("stable", "").len == 711
      map.close()

    test "fast arena map failed oversized update preserves old value":
      let map = newFastArenaMap[string](64)
      check map.put("stable", "old-value")
      var before: fast_map.FastStringView
      check map.tryGetView("stable", before)
      check $before == "old-value"

      var byteSource = "x"
      let hugeValue = fast_map.FastStringView(
        data: cast[pointer](unsafeAddr byteSource[0]),
        len: high(int) - 4096
      )
      check not map.putView(fast_map.toFastStringView("stable"), hugeValue)

      var after: fast_map.FastStringView
      check map.tryGetView("stable", after)
      check after.data == before.data
      check $after == "old-value"
      map.close()

  test "fast arena int64 map supports put, lookup, delete and iteration":
    let map = newFastArenaMap[int64](64)
    for i in 0 ..< 512:
      check map.put("key-" & $i, int64(i) * 3)
    var got: int64
    check map.tryGet("key-42", got)
    check got == int64(42) * 3
    check map.contains("key-511")
    check not map.contains("key-512")
    check map.len == 512

    check map["key-7"] == int64(7) * 3
    map["key-7"] = -99
    check map.tryGet("key-7", got) and got == -99

    var pairSum: int64 = 0
    var pairCount = 0
    for k, v in map.pairs:
      check k.startsWith("key-")
      pairSum += v
      inc pairCount
    check pairCount == 512
    # Sum of i*3 for i in 0..511 is 392448; key-7 holds -99 instead of 21.
    check pairSum == int64(392448) - int64(21) - int64(99)
    var valueSum: int64 = 0
    for v in map.mvalues:
      valueSum += v
    check valueSum == pairSum
    var mutableCount = 0
    for k, v in map.mpairs:
      check v != 0 or k == "key-0"
      inc mutableCount
    check mutableCount == 512

    check map.del("key-42")
    check not map.contains("key-42")
    check map.len == 511
    check not map.del("key-42")
    map.clear()
    check map.len == 0
    check not map.tryGet("key-0", got)
    map.close()

  test "fast arena string map iteration walks all entries":
    let map = newFastArenaMap[string](64)
    for i in 0 ..< 256:
      check map.put("s-" & $i, "v-" & $i)
    var seen = 0
    for k, v in map.pairs:
      check v == "v-" & k[2..^1]
      inc seen
    check seen == 256
    var keyCount = 0
    for k in map.keys:
      check k.startsWith("s-")
      inc keyCount
    check keyCount == 256
    check map.len == 256
    map.close()

  test "fast arena set supports incl, lookup, delete and iteration":
    let setObj = newFastArenaSet(64)
    for i in 0 ..< 512:
      check setObj.incl("k-" & $i)
    # incl returns true on success, including re-inserting an existing key
    # (matches the historical C backend contract).
    check setObj.incl("k-0")
    check setObj.contains("k-0")
    check setObj.containsC(cstring("k-1"))
    check setObj.containsView(fast_set.toFastStringView("k-2"))
    check not setObj.contains("k-512")
    check not setObj.containsOrIncl("k-512")
    check setObj.containsOrIncl("k-512")
    check setObj.len == 513
    check setObj.excl("k-42")
    check not setObj.excl("k-42")
    check setObj.missingOrExcl("k-42")
    check not setObj.missingOrExcl("k-0")
    discard setObj.incl("k-0")
    check setObj.len == 512
    var seen = 0
    for k in setObj.items:
      check k.startsWith("k-")
      inc seen
    check seen == 512
    var viewSeen = 0
    for k in setObj.itemsView():
      check k.len > 0
      inc viewSeen
    check viewSeen == 512
    let seq = setObj.itemsSeq()
    check seq.len == 512
    setObj.clear()
    check setObj.len == 0
    setObj.close()
    check setObj.len == 0

  test "fast arena set prefill constructor inserts all keys":
    let keys = @[
      "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"
    ]
    let setObj = newFastArenaSet(keys, 64)
    check setObj.len == 8
    for k in keys:
      check setObj.contains(k)
    setObj.close()

  test "fast_map pop and take return generic values":
    type Payload = object
      id: int
      tags: seq[string]

    let objectMap = newFastMap[Payload](4)
    check objectMap.put("payload", Payload(id: 7, tags: @["a", "b"]))
    var payload: Payload
    check objectMap.pop("payload", payload)
    check payload.id == 7
    check payload.tags == @["a", "b"]
    check not objectMap.contains("payload")
    check not objectMap.pop("payload", payload)
    objectMap.close()

    let seqMap = newFastMap[seq[int]](4)
    check seqMap.put("numbers", @[1, 2, 3])
    var numbers: seq[int]
    check seqMap.take("numbers", numbers)
    check numbers == @[1, 2, 3]
    check not seqMap.contains("numbers")
    seqMap.close()

  test "fast_set membership remains stable across mutation cycles":
    let setObj = newFastSet(8)
    for i in 0 ..< 1024:
      check setObj.incl("member-" & $i)
    for i in countup(0, 1023, 4):
      check setObj.excl("member-" & $i)
    for i in 1024 ..< 1536:
      check setObj.incl("member-" & $i)
    for i in 0 ..< 1536:
      let present = setObj.contains("member-" & $i)
      if i < 1024 and i mod 4 == 0:
        check not present
      else:
        check present

    check setObj.containsOrIncl("member-1")
    check not setObj.containsOrIncl("member-new")
    check setObj.contains("member-new")
    setObj.close()

  test "fast_set remains stable after delete arena churn":
    let setObj = newFastSet(64)
    check setObj.incl("stable")
    for cycle in 0 ..< 400:
      let key = "temp-" & $cycle & "-" & repeat("x", 256 + (cycle mod 32))
      check setObj.incl(key)
      check setObj.contains(key)
      check setObj.excl(key)
      check not setObj.contains(key)
      check setObj.contains("stable")
    check setObj.len == 1
    check setObj.contains("stable")
    setObj.close()

  test "fast_set rejects oversized keys before Swiss-table byte comparison":
    let setObj = newFastSet(8)
    let maxKey = repeat("s", 65535)
    let overKey = maxKey & "t"

    check setObj.incl(maxKey)
    check setObj.contains(maxKey)
    check not setObj.contains(overKey)
    check not setObj.excl(overKey)
    expect ValueError:
      discard setObj.incl(overKey)
    expect ValueError:
      discard setObj.containsOrIncl(overKey)
    setObj.close()

  test "fast_set rejects impossible reserve before allocation":
    let setObj = newFastSet(8)
    expect OverflowDefect:
      discard setObj.reserve(high(int))
    check setObj.len == 0
    check setObj.incl("after-overflow")
    check setObj.contains("after-overflow")
    setObj.close()
