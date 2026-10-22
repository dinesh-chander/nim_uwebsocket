## Extensive correctness stress for fast_map / fast_set pure-Nim backends.
## Deterministic seeds; oracle-comparison fuzz plus targeted group-boundary,
## tombstone, hash-inconsistency and arena-ramp scenarios.

import std/[tables, sets, algorithm, random, unittest, sequtils, strutils]
import nim_utils/helpers/fast_map
import nim_utils/helpers/fast_set

type Pair = tuple[a: int64, b: float]

proc mkKey(pool: int, i: int): string =
  "k-" & $((i mod pool) * 7919 div 7)

proc cmpMapString(map: FastMap[string], oracle: Table[string, string], label: string) =
  check map.len == oracle.len
  var seen = 0
  var keysSeen = initHashSet[string]()
  for k, v in map.pairs:
    inc seen
    check k in oracle
    check oracle[k] == v
    keysSeen.incl(k)
  check seen == oracle.len
  for k in oracle.keys:
    check keysSeen.contains(k)

proc cmpMapI64(map: FastMap[int64], oracle: Table[string, int64], label: string) =
  check map.len == oracle.len
  var seen = 0
  for k, v in map.pairs:
    inc seen
    check k in oracle
    check oracle[k] == v
  check seen == oracle.len

proc dropFrom[T](t: var Table[string, T], k: string) =
  var dum: T
  discard t.pop(k, dum)

proc iterSweep[V](seedVal: int) =
  var rng = initRand(int64(seedVal))
  let map = newFastMap[V](8)
  var oracle = initTable[string, V]()
  for i in 0 ..< 500:
    let k = "it-" & $i
    var v: V
    when V is int64: v = int64(i) else: v = (V)("s" & $i)
    discard map.put(k, v)
    oracle[k] = v
  for rep in 0 ..< 6:
    for i in 0 ..< 500:
      if rng.rand(3) == 0:
        let k = "it-" & $i
        discard map.del(k)
        dropFrom(oracle, k)
    var n = 0
    for k, v in map.pairs:
      inc n
      check oracle.hasKey(k)
      check oracle[k] == v
    check n == map.len
    for i in 0 ..< 500:
      if rng.rand(5) < 3:
        let k = "it-" & $i
        var v: V
        when V is int64: v = int64(i * 11) else: v = (V)("r" & $i)
        discard map.put(k, v)
        oracle[k] = v
  var seen = 0
  for k, v in map.pairs:
    inc seen
    check oracle.hasKey(k)
    check oracle[k] == v
  check seen == oracle.len
  map.close()

proc cmpMapPair(map: FastMap[Pair], oracle: Table[string, Pair], label: string) =
  check map.len == oracle.len
  var seen = 0
  for k, v in map.pairs:
    inc seen
    check k in oracle
    check oracle[k].a == v.a
    check oracle[k].b == v.b
  check seen == oracle.len

suite "nim_utils fast collections stress":
  test "string map backends track Table oracle under mixed ops":
    for seed in [1'i64, 2, 3]:
      var rng = initRand(seed)
      var oracle = initTable[string, string]()
      let backends = seed mod 3
      var map =
        case backends
        of 0: newFastMap[string]([0, 1, 8, 17][int(seed mod 4)])
        of 1: newFastMap[string]()
        else: newFastArenaMap[string](128)
      for op in 0 ..< 20_000:
        let i = int(rng.rand(999))
        let k = mkKey(500, i)
        case rng.rand(9)
        of 0 .. 4:
          let v = "v" & $i
          discard map.put(k, v)
          oracle[k] = v
        of 5 .. 6:
          check map.del(k) == oracle.hasKey(k)
          dropFrom(oracle, k)
        of 7:
          var got: string
          let ok = map.tryGet(k, got)
          check ok == oracle.hasKey(k)
          if ok: check got == oracle[k]
        of 8:
          check map.contains(k) == oracle.hasKey(k)
        else:
          discard
        if op mod 1000 == 999:
          cmpMapString(map, oracle, "seed " & $seed & " op " & $op)
      # delete everything
      var keys: seq[string]
      for k in oracle.keys: keys.add k
      for k in keys:
        check map.del(k)
      check map.len == 0
      map.close()

  test "int64 backend group-boundary torture at small capacities":
    for seed in [11'i64, 12, 13]:
      var rng = initRand(seed)
      var oracle = initTable[string, int64]()
      let map = newFastMap[int64](0)
      # Stay in tiny capacity (16-64 slots) with a small key pool: every group,
      # including the last group and wrap-around stride sequences, gets walked.
      for op in 0 ..< 30_000:
        let k = mkKey(24, int(rng.rand(10_000)))
        case rng.rand(7)
        of 0 .. 3:
          let v = int64(op)
          discard map.put(k, v)
          oracle[k] = v
        of 4 .. 5:
          check map.del(k) == oracle.hasKey(k)
          dropFrom(oracle, k)
        of 6:
          var got: int64
          let ok = map.tryGet(k, got)
          check ok == oracle.hasKey(k)
          if ok: check got == oracle[k]
        else:
          check map.contains(k) == oracle.hasKey(k)
        if op mod 2000 == 1999:
          cmpMapI64(map, oracle, "seed " & $seed & " op " & $op)
      cmpMapI64(map, oracle, "final " & $seed)
      map.close()

  test "tuple V generic backend tracks oracle":
    var rng = initRand(21)
    var oracle = initTable[string, Pair]()
    let map = newFastMap[Pair](2)
    for op in 0 ..< 25_000:
      let k = mkKey(48, int(rng.rand(5_000)))
      case rng.rand(7)
      of 0 .. 3:
        let v = (a: int64(op), b: float(op) / 4.0)
        discard map.put(k, v)
        oracle[k] = v
      of 4 .. 5:
        check map.del(k) == oracle.hasKey(k)
        dropFrom(oracle, k)
      of 6:
        var got: Pair
        let ok = map.tryGet(k, got)
        check ok == oracle.hasKey(k)
        if ok:
          check got.a == oracle[k].a
          check got.b == oracle[k].b
      else:
        check map.contains(k) == oracle.hasKey(k)
      if op mod 2500 == 2499:
        cmpMapPair(map, oracle, "op " & $op)
    cmpMapPair(map, oracle, "final")
    map.close()

  test "hash-inconsistent maps keep replace semantics across groups":
    ## Contract: caller-supplied hashes must be reused for lookups
    ## (tryGetViewHashed); plain get/del re-hash and only see real-hash
    ## entries. putHashed replaces by key even across hash mismatch.
    for size in [0, 8, 64]:
      let map = newFastMap[string](size)
      const hashOne = 0x1111_1111_1111_1111'u64
      const hashTwo = 0x2222_2222_2222_2222'u64
      const hashThree = 0x3333_3333_3333_3333'u64
      var view: fast_map.FastStringView
      check map.putHashed("stable", hashOne, "first")
      check map.putHashed("stable", hashTwo, "second")
      check map.len == 1
      check map.tryGetViewHashed("stable", hashOne, view)
      check $view == "second"
      check map.putHashed("stable", hashThree, "third")
      check map.len == 1
      check map.tryGetViewHashed("stable", hashThree, view)
      check $view == "third"
      # forced same-hash collisions across many groups incl. wrap-around
      const forced = 0xDEAD_BEEF_0000_0001'u64
      var names: seq[string]
      for i in 0 ..< 70:
        let n = "collide-" & $i
        names.add n
        check map.putHashed(n, forced, "val-" & $i)
      check map.len == 71
      for i, n in names:
        check map.tryGetViewHashed(n, forced, view)
        check $view == "val-" & $i
      # overwrite every 4th via the same forced hash (replace by key)
      for i in 0 ..< 70:
        if (i mod 4) == 0:
          check map.putHashed(names[i], forced, "upd-" & $i)
      check map.len == 71
      for i, n in names:
        check map.tryGetViewHashed(n, forced, view)
        if (i mod 4) == 0:
          check $view == "upd-" & $i
        else:
          check $view == "val-" & $i
      check map.tryGetViewHashed("stable", hashOne, view)
      check $view == "third"
      map.close()

  test "tombstone storm preserves data across rebuilds (string and int64)":
    for seed in [31'i64, 32]:
      var rng = initRand(seed)
      block:
        var oracle = initTable[string, string]()
        let map = newFastMap[string](16)
        for round in 0 ..< 5:
          var fresh = 0
          while fresh < 2000:
            let k = "storm-" & $(int(rng.rand(1_000_000)))
            if oracle.hasKey(k): continue
            let v = "r" & $round
            check map.put(k, v)
            oracle[k] = v
            inc fresh
          let stormKeys = toSeq(oracle.keys)
          for k in stormKeys:
            if rng.rand(9) < 6:
              check map.del(k)
              dropFrom(oracle, k)
          # deletes leave used >> count: reinsertion must ride rebuild paths
          fresh = 0
          while fresh < 500:
            let k = "post-" & $round & "-" & $fresh
            let v = "p" & $fresh
            check map.put(k, v)
            oracle[k] = v
            inc fresh
          cmpMapString(map, oracle, "storm string round " & $round)
        map.close()
      block:
        var oracle = initTable[string, int64]()
        let map = newFastMap[int64](16)
        for round in 0 ..< 5:
          var fresh = 0
          while fresh < 2000:
            let k = "storm64-" & $(int(rng.rand(1_000_000)))
            if oracle.hasKey(k): continue
            let v = int64(round * 1000 + fresh)
            check map.put(k, v)
            oracle[k] = v
            inc fresh
          let stormKeys = toSeq(oracle.keys)
          for k in stormKeys:
            if rng.rand(9) < 6:
              check map.del(k)
              dropFrom(oracle, k)
          fresh = 0
          while fresh < 500:
            let k = "post64-" & $round & "-" & $fresh
            check map.put(k, int64(fresh))
            oracle[k] = int64(fresh)
            inc fresh
          cmpMapI64(map, oracle, "storm int64 round " & $round)
        map.close()

  test "arena map and set survive clear and reinsert ramp rounds":
    block:
      var oracle = initTable[string, int64]()
      let map = newFastArenaMap[int64](64)
      for round in 0 ..< 3:
        for i in 0 ..< 900:
          let k = "ar-" & $round & "-" & $i
          check map.put(k, int64(i * 3))
          oracle[k] = int64(i * 3)
        for i in countup(0, 899, 2):
          let k = "ar-" & $round & "-" & $i
          check map.del(k)
          dropFrom(oracle, k)
        cmpMapI64(map, oracle, "arena round " & $round & " before clear")
        map.clear()
        oracle.clear()
        check map.len == 0
      map.close()
    block:
      var oracle = initHashSet[string]()
      let map = newFastArenaMap[string](64)
      for round in 0 ..< 2:
        for i in 0 ..< 400:
          let k = "as-" & $round & "-" & $i
          check map.put(k, k & "!")
          oracle.incl(k)
        for k, v in map.pairs:
          check k in oracle
          check v == k & "!"
        map.clear()
        oracle.clear()
      map.close()
    block:
      var oracle = initHashSet[string]()
      let setObj = newFastArenaSet(64)
      for round in 0 ..< 3:
        var rng2 = initRand(40 + round)
        for i in 0 ..< 1200:
          let k = "fs-" & $round & "-" & $i
          discard setObj.incl(k)
          oracle.incl(k)
        for i in 0 ..< 1200:
          let k = "fs-" & $round & "-" & $(int(rng2.rand(1199)))
          discard setObj.missingOrExcl(k)
          oracle.excl(k)
        check setObj.len == oracle.len
        var items = setObj.itemsSeq
        items.sort
        var want = toSeq(oracle)
        want.sort
        check items == want
        setObj.clear()
        oracle.clear()
      setObj.close()

  test "oversized views rejected and map stays usable":
    let map = newFastMap[string](8)
    check map.put("small", "value")
    let huge = fast_map.FastStringView(data: nil, len: high(int) - 4096)
    check not map.putView(huge, huge)
    check map.get("small", "") == "value"
    let big = strutils.repeat("x", 65535)
    check map.put(big, "max-len")
    var got: string
    check map.tryGet(big, got)
    check got == "max-len"
    check map.put("small", "value2")
    check map.get("small", "") == "value2"
    map.close()

  test "iteration walks every entry through mixed tombstone patterns":
    iterSweep[string](51)
    iterSweep[int64](51)
