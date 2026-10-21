import std/[random, sets, strutils, tables, unittest]

import nim_utils/helpers/[fast_map, fast_set]

proc makeKey(rng: var Rand, i: int): string =
  case rng.rand(3)
  of 0: "k-" & $i
  of 1: "prefix/with/some/more/bytes-" & $i
  of 2: ($i)
  else: ""
  # all keys stay within the inline string cap

proc randIdx(rng: var Rand): int = rng.rand(498)

suite "fast collections fuzz":
  test "fast_map string values match Table oracle":
    for seed in 1 .. 6:
      var rng = initRand(seed * 7919)
      var oracle = initTable[string, string]()
      var map = newFastMap[string](16)
      var keys: seq[string]
      for i in 0 ..< 499:
        keys.add makeKey(rng, i)
      var ops = 0
      while ops < 200_000:
        inc ops
        let k = keys[randIdx(rng)]
        case rng.rand(9)
        of 0 .. 5:
          let v = "v-" & $rng.rand(1_000_000)
          check map.put(k, v)
          oracle[k] = v
        of 6:
          let removed = map.del(k)
          check removed == oracle.hasKey(k)
          if removed:
            oracle.del(k)
        of 7:
          var got: string
          let hit = map.tryGet(k, got)
          check hit == oracle.hasKey(k)
          if hit:
            check got == oracle[k]
        of 8:
          check map.contains(k) == oracle.hasKey(k)
        else:
          discard
        if ops mod 97 == 0:
          check map.len == oracle.len
      check map.len == oracle.len
      map.close()

  test "fast_map int64 values match Table oracle":
    for seed in 1 .. 6:
      var rng = initRand(seed * 104729)
      var oracle = initTable[string, int64]()
      var map = newFastMap[int64](16)
      var keys: seq[string]
      for i in 0 ..< 499:
        keys.add makeKey(rng, i)
      var ops = 0
      while ops < 200_000:
        inc ops
        let k = keys[randIdx(rng)]
        case rng.rand(9)
        of 0 .. 5:
          let v = int64(rng.rand(1_000_000)) - 500_000
          discard map.put(k, v)
          oracle[k] = v
        of 6:
          let removed = map.del(k)
          check removed == oracle.hasKey(k)
          if removed:
            oracle.del(k)
        of 7:
          var got: int64
          let hit = map.tryGet(k, got)
          check hit == oracle.hasKey(k)
          if hit:
            check got == oracle[k]
        of 8:
          check map.contains(k) == oracle.hasKey(k)
        else:
          discard
        if ops mod 97 == 0:
          check map.len == oracle.len
      check map.len == oracle.len
      map.close()

  test "fast_set matches HashSet oracle":
    for seed in 1 .. 6:
      var rng = initRand(seed * 15485863)
      var oracle = initHashSet[string]()
      var setObj = newFastSet(16)
      var keys: seq[string]
      for i in 0 ..< 499:
        keys.add makeKey(rng, i)
      var ops = 0
      while ops < 200_000:
        inc ops
        let k = keys[randIdx(rng)]
        case rng.rand(9)
        of 0 .. 4:
          discard setObj.incl(k)
          oracle.incl(k)
        of 5:
          check setObj.excl(k) == oracle.contains(k)
          oracle.excl(k)
        of 6:
          check setObj.containsOrIncl(k) == oracle.contains(k)
          oracle.incl(k)
        of 7:
          check setObj.contains(k) == oracle.contains(k)
        of 8:
          discard setObj.missingOrExcl(k)
          oracle.excl(k)
        else:
          discard
        if ops mod 97 == 0:
          check setObj.len == len(oracle)
      check setObj.len == len(oracle)
      setObj.close()
