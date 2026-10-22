## Third-wave correctness stress: hashed-API surface (the hot contract used
## by nim_usockets header handling), tombstone/rebuild triggers, nil and
## double-close safety, memory-return behavior, and view-backed keys.

{.used.}

import std/[os, osproc, random, sets, strutils, tables, unittest]
import nim_utils/helpers/fast_map
import nim_utils/helpers/fast_set

when isMainModule:
  # Invoked by the cross-process hashed-consistency test.
  if commandLineParams().len >= 1 and commandLineParams()[0] == "--print-hashed":
    let m = newFastMap[string](64)
    for i in 0 ..< 200:
      discard m.putHashed("hk-" & $i, hashKey("hk-" & $i), "hv-" & $i)
    var acc: uint64 = 0
    for i in 0 ..< 200:
      let view = m.getViewHashed("hk-" & $i, hashKey("hk-" & $i))
      acc = acc xor (cast[uint64](view.len) * 1099511628211'u64)
      acc = acc + cast[uint64](cast[ptr char](view.data)[])
    echo "hashed:", acc
    quit(0)

proc rssKb(): int =
  let data = readFile("/proc/self/statm")
  var pages = 0
  for tok in data.split:
    inc pages
    if pages == 2:
      return parseInt(tok) * 4

suite "nim_utils hashed api and lifecycle stress":
  test "hashKey overloads agree and are deterministic":
    for k in ["", "a", "content-type", "sec-websocket-key-0123456789",
        newString(64)]:
      let h = fast_map.hashKey(k)
      check fast_map.hashKey(fast_map.toFastStringView(k)) == h
      check fast_map.hashKey(k) == h

  test "cross-process hashed puts stay consistently readable":
    let probeCmd = "\"" & paramStr(0) & "\" --print-hashed"
    let a = execProcess(probeCmd)
    let b = execProcess(probeCmd)
    check a.strip == b.strip
    check a.strip.startsWith("hashed:")

  test "hashed api surface on the string backend":
    let m = newFastMap[string](64)
    var oracle = initTable[string, string]()
    var rng = initRand(int64(20261021))
    var keys: seq[string] = @[]
    for i in 0 ..< 2000:
      let kl = rng.rand(0 .. 300)
      var k = newString(kl)
      for j in 0 ..< kl: k[j] = char(97 + (i + j) mod 26)
      keys.add(k)
    var bigKey = newString(65535)
    for i in 0 ..< 65535: bigKey[i] = 'q'
    keys.add(bigKey)
    var bigVal = newString(1000)
    for i in 0 ..< 1000: bigVal[i] = 'v'
    for k in keys:
      let v = "val-" & $k.len
      let h = fast_map.hashKey(k)
      check m.putHashed(k, h, v)
      oracle[k] = v
      check $m.getViewHashed(k, h) == v
      check m.getLenHashed(k, h) == v.len
      var gotView: fast_map.FastStringView
      check m.tryGetViewHashed(k, h, gotView)
      check $gotView == v
    check m.len == oracle.len
    check m.getViewHashed("missing-key", fast_map.hashKey("missing-key")).len == 0
    check m.getLenHashed("missing-key", fast_map.hashKey("missing-key"), -1) == -1
    # Arbitrary caller hashes (NOT hashKey output): replace-by-key must keep
    # working via the key-only fallback and lookups with the same arbitrary
    # hash must hit. Pinned contract: plain get/del re-hash, so entries
    # stored under a foreign hash are legitimately invisible to them; only
    # hashed reads / putHashed with the SAME hash resolve them.
    let h1 = 0xDEAD_BEEF_CAFE_1234'u64
    check m.putHashed("hashed-x", h1, "one")
    check m.putHashed("hashed-x", h1, "two")
    check $m.getViewHashed("hashed-x", h1) == "two"
    check m.len == oracle.len + 1
    check m.get("hashed-x") == ""
    check not m.del("hashed-x")
    # There is no delHashed API, so this foreign-hash entry is permanent
    # (by pinned contract): keep it OUT of the oracle sweep below and count
    # it separately.
    let foreignExtra = 1
    # hashKey-hashed entries remain fully visible to the plain lane
    check m.putHashed("hashed-y", fast_map.hashKey("hashed-y"), "why")
    oracle["hashed-y"] = "why"
    check m.get("hashed-y") == "why"
    check m.del("hashed-y")
    oracle.del "hashed-y"
    for rep in 0 ..< 3:
      for i in 0 ..< keys.len:
        let k = keys[i]
        if rng.rand(9) == 0:
          discard m.del(k)
          oracle.del k
        else:
          let v = "w" & $rng.rand(100000)
          discard m.putHashed(k, fast_map.hashKey(k), v)
          oracle[k] = v
      if rep == 2:
        var seen = 0
        for k, v in m.pairs:
          inc seen
          if k == "hashed-x":
            check v == "two"
            continue
          check oracle.hasKey(k)
          check oracle[k] == v
        check seen == oracle.len + foreignExtra
        # getView on every remaining key
        for k in oracle.keys:
          check $m.getView(k) == oracle[k]
    m.close()

  test "tombstone storms force rebuild and rehash paths":
    let m = newFastMap[string](8)
    var oracle = initTable[string, string]()
    var rng = initRand(int64(5511))
    for round in 0 ..< 10:
      for i in 0 ..< 5000:
        let k = "t-" & $i
        discard m.put(k, "tv-" & $round)
        oracle[k] = "tv-" & $round
      check m.len == oracle.len
      for i in 0 ..< 5000:
        let k = "t-" & $i
        if rng.rand(9) < 7:
          discard m.del(k)
          if oracle.hasKey(k): oracle.del k
      check m.len == oracle.len
      for i in 0 ..< 1500:
        let k = "t-" & $i
        discard m.del(k)
        if oracle.hasKey(k): oracle.del k
      # refill with longer keys to push rebuild + arena growth
      for i in 0 ..< 3000:
        let k = "longer-round-" & $round & "-key-" & $i & "-padding-padding"
        discard m.put(k, "x" & $i)
        oracle[k] = "x" & $i
      var seen = 0
      for k, v in m.pairs:
        inc seen
        check oracle.hasKey(k)
        check oracle[k] == v
      check seen == oracle.len
    m.close()

  test "arena int64 and string maps exercise view-key overloads":
    let mi = newFastArenaMap[int64](64)
    var rng = initRand(int64(6006))
    var oracle = initTable[string, int64]()
    for op in 0 ..< 20000:
      let k = "vk-" & $rng.rand(1000)
      case rng.rand(5)
      of 0, 1:
        let v = int64(rng.rand(100_000))
        check mi.putView(fast_map.toFastStringView(k), v) == true
        oracle[k] = v
      of 2:
        var got: int64
        check mi.tryGet(k, got) == oracle.hasKey(k)
        if oracle.hasKey(k): check got == oracle[k]
      of 3:
        check mi.containsView(fast_map.toFastStringView(k)) == oracle.hasKey(k)
      of 4:
        discard mi.delView(fast_map.toFastStringView(k))
        if oracle.hasKey(k): oracle.del k
      else:
        check mi.containsC(k.cstring) == oracle.hasKey(k)
    check mi.len == oracle.len
    var sum: int64 = 0
    for k, v in mi.pairs:
      sum += v
      check oracle[k] == v
    var sumOr: int64 = 0
    for v in oracle.values: sumOr += v
    check sum == sumOr
    mi.close()

    let ms = newFastArenaMap[string](64)
    for i in 0 ..< 300:
      discard ms.putView(fast_map.toFastStringView("sk-" & $i),
          fast_map.toFastStringView("sv-" & $i))
    check ms.len == 300
    check $ms.getView(fast_map.toFastStringView("sk-7")) == "sv-7"
    for pairKV in ms.pairsView:
      let k = $pairKV[0]
      check $pairKV[1] == "sv-" & k[3 .. ^1]
    ms.close()

  test "nil maps, sets and odd inputs never crash":
    # Pinned contract (unchanged from the pre-port backend): only len and
    # close are nil-safe on an uninitialized handle; every other operation
    # requires newFastMap/newFastArenaMap/newFastSet first.
    var m: FastMap[string]
    var mi: FastMap[int64]
    var s: FastSet
    check m.len == 0
    check mi.len == 0
    check s.len == 0
    m.close()
    mi.close()
    s.close()
    s.close()
    m.close()
    # double close on initialized handles stays idempotent
    let dm = newFastMap[string](8)
    let ds = newFastSet(8)
    discard dm.put("dk", "dv")
    discard ds.incl("dk")
    dm.close()
    dm.close()
    ds.close()
    ds.close()
    # empty-view and invalid-view inputs
    let mm = newFastMap[string](8)
    check mm.put("", "e")
    let emptyView = fast_map.toFastStringView("")
    check $mm.getView(emptyView) == "e"
    let bogus = fast_map.FastStringView(data: nil, len: high(int))
    check not mm.putView(bogus, emptyView)
    check not mm.containsView(bogus)
    check $mm.getView(bogus) == ""
    mm.close()

  test "map memory is returned across lifecycles":
    proc churnOnce() =
      let m = newFastMap[string](256)
      for i in 0 ..< 4000:
        discard m.put("leak-key-" & $i, "value-payload-" & $i)
      for i in 0 ..< 2000:
        discard m.del("leak-key-" & $i)
      for i in 2000 ..< 4000:
        discard m.put("leak-key-" & $i, "more-values-and-padding-" & $i)
      m.close()
    for _ in 0 ..< 10:
      churnOnce()
    let start = rssKb()
    for _ in 0 ..< 80:
      churnOnce()
    let grown = rssKb() - start
    check grown < 32 * 1024

  test "set prefill constructor and view keys survive rehash":
    var seeds: seq[string] = @[]
    for i in 0 ..< 5000:
      seeds.add("seed-" & $i)
    let s = newFastSet(seeds)
    check s.len == 5000
    for k in seeds:
      check s.containsView(fast_set.toFastStringView(k))
    # churn past several growths with view inserts, verify via string lookups
    var rng = initRand(int64(777))
    var oracle = initHashSet[string]()
    for k in seeds: oracle.incl k
    for op in 0 ..< 30000:
      let k = "vk2-" & $rng.rand(9000)
      if rng.rand(2) == 0:
        discard s.missingOrExclView(fast_set.toFastStringView(k))
        oracle.excl k
      else:
        discard s.inclView(fast_set.toFastStringView(k))
        oracle.incl k
    check s.len == oracle.len
    var seen = 0
    for key in s.itemsView:
      inc seen
      check ($key) in oracle
    check seen == oracle.len
    let mi = newFastMap[int64](8)
    for i in 0 ..< 6000:
      discard mi.put("gk-" & $i, int64(i))
      mi["gk-" & $i] = int64(i) * 2
    check mi.len == 6000
    check mi.get("gk-5999") == 11998
    mi.close()
    s.close()
