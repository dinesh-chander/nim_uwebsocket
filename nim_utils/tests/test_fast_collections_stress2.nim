## Second-wave correctness stress: API-matrix fuzz for `fast_set` (all
## string/cstring/view variants against a HashSet oracle), untested map
## surfaces (`pop`, `take`, `mgetOrPut`, `keys`, `pairsView`, mutating
## iterators, `[]=`), small-capacity set group-wraparound, and key-length
## boundaries for both containers.

import std/[cstrutils, tables, sets, algorithm, random, unittest, strutils]
import nim_utils/helpers/fast_map
import nim_utils/helpers/fast_set

proc mkSetKey(pool: int, i: int): string =
  "s-" & $((i mod pool) * 6151 div 5)

proc dropFrom[T](t: var Table[string, T], k: string) =
  var dum: T
  discard t.pop(k, dum)

suite "nim_utils fast_set api-matrix stress":
  test "set fuzz across string/cstring/view overloads vs HashSet oracle":
    for seed in 0 ..< 3:
      var rng = initRand(int64(700 + seed))
      let pool = 400
      let s = newFastSet(32)
      var oracle = initHashSet[string]()
      for op in 0 ..< 40000:
        let k = mkSetKey(pool, rng.rand(100_000))
        case rng.rand(8)
        of 0, 1:
          discard s.incl(k)
          oracle.incl(k)
        of 2:
          discard s.containsOrInclC(k.cstring)
          oracle.incl(k)
        of 3:
          discard s.inclView(fast_set.toFastStringView(k))
          oracle.incl(k)
        of 4:
          check s.contains(k) == (k in oracle)
        of 5:
          check s.containsC(k.cstring) == (k in oracle)
        of 6:
          check s.containsView(fast_set.toFastStringView(k)) == (k in oracle)
        of 7:
          discard s.missingOrExcl(k)
          oracle.excl(k)
        of 8:
          check s.containsOrIncl(k) == (k in oracle)
          oracle.incl(k)
        else:
          discard
        if op mod 4000 == 0:
          check s.len == oracle.len
          var seen = 0
          var seenSet = initHashSet[string]()
          for key in s.items:
            inc seen
            check key in oracle
            seenSet.incl(key)
          check seen == oracle.len
          for key in oracle:
            check seenSet.contains(key)
      check s.len == oracle.len
      var seqSorted = s.itemsSeq()
      seqSorted.sort()
      var oracleSorted: seq[string] = @[]
      for key in oracle: oracleSorted.add(key)
      oracleSorted.sort()
      check seqSorted == oracleSorted
      s.close()

  test "set small-capacity group wraparound and tombstone churn":
    for poolSize in [12, 17, 31]:
      for seed in 0 ..< 2:
        var rng = initRand(int64(9000 + poolSize * 31 + seed))
        let s = newFastSet(8)
        var oracle = initHashSet[string]()
        for op in 0 ..< 15000:
          let k = "w-" & $rng.rand(poolSize - 1)
          case rng.rand(3)
          of 0, 1:
            discard s.incl(k)
            oracle.incl(k)
          of 2:
            discard s.missingOrExcl(k)
            oracle.excl(k)
          of 3:
            let was = s.containsOrIncl(k)
            check was == (k in oracle)
            oracle.incl(k)
          else:
            discard
          check s.len == oracle.len
        var seen = 0
        for key in s.itemsView:
          inc seen
          let k = $key
          check k in oracle
        check seen == oracle.len
        s.close()

  test "set key-length boundaries and oversized views":
    let s = newFastSet()
    check s.incl("")
    check s.contains("")
    check s.containsC("".cstring)
    var k65534 = newString(65534)
    for i in 0 ..< 65534: k65534[i] = 'a'
    check s.incl(k65534)
    check s.contains(k65534)
    var k65535 = newString(65535)
    for i in 0 ..< 65535: k65535[i] = 'b'
    check s.incl(k65535)
    check s.contains(k65535)
    check not s.contains("bb")
    var huge = fast_set.FastStringView(data: nil, len: high(int) - 4096)
    check not s.containsView(huge)
    check not s.inclView(huge)
    check s.len == 3
    check not s.missingOrExcl(k65534)
    check not s.contains(k65534)
    check s.missingOrExcl(k65534)
    check s.contains(k65535)
    check not s.missingOrExcl(k65535)
    check not s.missingOrExcl("")
    check s.len == 0
    s.close()

  test "set reserve and clear reinsert rounds":
    let s = newFastArenaSet(64)
    for round in 0 ..< 5:
      var oracle = initHashSet[string]()
      for i in 0 ..< 900:
        let k = "rr-" & $i
        discard s.incl(k)
        oracle.incl(k)
      check s.len == oracle.len
      for i in 0 ..< 900:
        check s.contains("rr-" & $i)
      s.clear()
      check s.len == 0
      for i in 0 ..< 200:
        let k = "rb-" & $i
        discard s.incl(k)
        check s.contains(k)
      check s.len == 200
      s.clear()
    s.close()

  test "arena and default set backends behave identically":
    for arena in [false, true]:
      let s =
        if arena: newFastArenaSet(64)
        else: newFastSet()
      var oracle = initHashSet[string]()
      var rng = initRand(int64(4242 + (if arena: 1 else: 0)))
      for op in 0 ..< 20000:
        let k = mkSetKey(250, rng.rand(100_000))
        case rng.rand(2)
        of 0, 1:
          discard s.incl(k)
          oracle.incl(k)
        else:
          discard s.missingOrExcl(k)
          oracle.excl(k)
      check s.len == oracle.len
      var seen = 0
      for key in s.items:
        inc seen
        check key in oracle
      check seen == oracle.len
      s.close()

suite "nim_utils fast_map surface stress":
  test "string map pop take mgetOrPut setter vs Table oracle":
    for seed in 0 ..< 3:
      var rng = initRand(int64(1717 + seed))
      let m = newFastMap[string](16)
      var oracle = initTable[string, string]()
      for op in 0 ..< 30000:
        let k = mkSetKey(350, rng.rand(100_000))
        case rng.rand(8)
        of 0, 1:
          let v = "v" & $rng.rand(1000)
          discard m.put(k, v)
          oracle[k] = v
        of 2:
          var got: string
          let ok = m.pop(k, got)
          check ok == oracle.hasKey(k)
          if ok:
            check got == oracle[k]
            oracle.dropFrom(k)
        of 3:
          var got: string
          let ok = m.take(k, got)
          check ok == oracle.hasKey(k)
          if ok:
            check got == oracle[k]
            oracle.dropFrom(k)
        of 4:
          let had = oracle.hasKey(k)
          let got = m.mgetOrPut(k, "mv")
          if not had:
            check got == "mv"
            oracle[k] = "mv"
          else:
            check got == oracle[k]
        of 5:
          check m.get(k) == (if oracle.hasKey(k): oracle[k] else: "")
        of 6:
            let v = "w" & $rng.rand(1000)
            m[k] = v
            oracle[k] = v
            check m.get(k) == v
        of 7:
          discard m.del(k)
          oracle.dropFrom(k)
        of 8:
          let v = "c" & $rng.rand(100)
          let old = m.mgetOrPut(k, v)
          if not oracle.hasKey(k):
            check old == v
            oracle[k] = v
          else:
            check old == oracle[k]
        else:
          discard
        if op mod 5000 == 0:
          check m.len == oracle.len
      var seen = 0
      for k, v in m.pairs:
        inc seen
        check oracle.hasKey(k)
        check oracle[k] == v
      check seen == oracle.len
      var keySet = initHashSet[string]()
      for k in m.keys:
        keySet.incl(k)
      for k in oracle.keys:
        check keySet.contains(k)
      m.close()

  test "int64 map pop and mgetOrPut vs Table oracle":
    var rng = initRand(int64(313))
    let m = newFastMap[int64](16)
    var oracle = initTable[string, int64]()
    for op in 0 ..< 30000:
      let k = mkSetKey(300, rng.rand(100_000))
      case rng.rand(6)
      of 0, 1:
        let v = int64(rng.rand(100_000))
        discard m.put(k, v)
        oracle[k] = v
      of 2:
        var got: int64
        let ok = m.pop(k, got)
        check ok == oracle.hasKey(k)
        if ok:
          check got == oracle[k]
          oracle.dropFrom(k)
      of 3:
        let had = oracle.hasKey(k)
        let got = m.mgetOrPut(k, int64(77))
        if not had:
          check got == 77
          oracle[k] = 77
        else:
          check got == oracle[k]
      of 4:
        let had = oracle.hasKey(k)
        let got = m.mgetOrPut(k)
        if not had:
          check got == 0
          oracle[k] = 0
        else:
          check got == oracle[k]
      of 5:
        check m.get(k) == (if oracle.hasKey(k): oracle[k] else: int64(0))
      else:
        discard m.del(k)
        oracle.dropFrom(k)
    check m.len == oracle.len
    var sumFm: int64 = 0
    var sumOr: int64 = 0
    for v in m.mvalues:
      sumFm += v
    for v in oracle.values:
      sumOr += v
    check sumFm == sumOr
    m.close()

  test "pairsView matches pairs for string map":
    let m = newFastMap[string](64)
    var oracle = initTable[string, string]()
    for i in 0 ..< 5000:
      let k = "pv-" & $i
      let v = "vv-" & $(i * 7)
      discard m.put(k, v)
      oracle[k] = v
    for i in 0 ..< 1500:
      let k = "pv-" & $(i * 3)
      discard m.del(k)
      oracle.dropFrom(k)
    var seen = 0
    var got = initHashSet[string]()
    for kv in m.pairsView:
      inc seen
      let k = $kv[0]
      let v = $kv[1]
      check oracle.hasKey(k)
      check oracle[k] == v
      got.incl(k)
    check seen == oracle.len
    for k in oracle.keys:
      check got.contains(k)
    m.close()

  test "mpairs mutations visible to lookups (int64 values)":
    let m = newFastMap[int64](64)
    for i in 0 ..< 2000:
      discard m.put("mp-" & $i, int64(i))
    var touched = 0
    for k, v in m.mpairs:
      v = -int64(parseInt(k[3 .. ^1]))
      inc touched
    check touched == 2000
    for i in 0 ..< 2000:
      check m.get("mp-" & $i) == -int64(i)
    # string mpairs is documented to raise (unmanaged entry storage)
    let ms = newFastMap[string](8)
    discard ms.put("a", "b")
    var raised = false
    try:
      for k, v in ms.mpairs:
        discard k
        discard v
    except ValueError:
      raised = true
    check raised
    ms.close()
    m.close()

  test "map key-length boundaries on nimString and arena backends":
    for arena in [false, true]:
      let m =
        if arena: newFastArenaMap[string](64)
        else: newFastMap[string]()
      check m.put("", "empty")
      check m.get("") == "empty"
      var k65535 = newString(65535)
      for i in 0 ..< 65535: k65535[i] = 'x'
      check m.put(k65535, "max")
      check m.get(k65535) == "max"
      var k65536 = newString(65536)
      var tooBig = false
      try:
        discard m.put(k65536, "toobig")
      except ValueError:
        tooBig = true
      check tooBig
      check m.len == 2
      var huge = fast_map.FastStringView(data: nil, len: high(int) - 4096)
      check not m.putView(huge, fast_map.toFastStringView("nope"))
      check m.len == 2
      m.close()

  test "map small-capacity group wraparound torture (string backend)":
    for poolSize in [13, 18, 33]:
      var rng = initRand(int64(555 + poolSize))
      let m = newFastMap[string](8)
      var oracle = initTable[string, string]()
      for op in 0 ..< 15000:
        let k = "g-" & $rng.rand(poolSize - 1)
        case rng.rand(3)
        of 0, 1:
          let v = "x" & $op
          discard m.put(k, v)
          oracle[k] = v
        of 2:
          discard m.del(k)
          oracle.dropFrom(k)
        of 3:
          check m.get(k) == (if oracle.hasKey(k): oracle[k] else: "")
        else:
          discard
        check m.len == oracle.len
      var seen = 0
      for k, v in m.pairs:
        inc seen
        check oracle.hasKey(k)
        check oracle[k] == v
      check seen == oracle.len
      m.close()
