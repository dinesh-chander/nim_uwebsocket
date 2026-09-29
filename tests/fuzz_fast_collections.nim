import std/[random, strutils, tables, sets, hashes]
import ../nim_utils/src/nim_utils/helpers/fast_map
import ../nim_utils/src/nim_utils/helpers/fast_set

const
  Iterations = 10_000
  ProgressInterval = 1000

var rng = initRand(42)
var failures: seq[string]

proc fail(label, msg: string) =
  failures.add label & ": " & msg

proc randomKey(maxLen: int = 100): string =
  let keyLen = rng.rand(maxLen)
  result = newString(keyLen)
  for i in 0 ..< keyLen:
    result[i] = char(rng.rand(255))

proc randomPrintableKey(maxLen: int = 50): string =
  let keyLen = rng.rand(maxLen) + 1
  result = newString(keyLen)
  for i in 0 ..< keyLen:
    result[i] = char(rng.rand(93) + 33)

proc collidingKey(base: int): string =
  result = "collision_prefix_" & $base & "_" & repeat('A', base mod 10)

echo "=== Fuzz Fast Collections ==="

echo "--- Category 1: FastMap random insert/delete/lookup vs Table ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fm = newFastMap[string]()
  var reference = initTable[string, string]()
  let ops = rng.rand(200) + 10
  for j in 0 ..< ops:
    let op = rng.rand(4)
    let key = randomPrintableKey(30)
    let val = randomPrintableKey(30)
    case op
    of 0, 1:
      discard fm.put(key, val)
      reference[key] = val
    of 2:
      let fmHas = fm.contains(key)
      let refHas = key in reference
      if fmHas != refHas:
        fail("map_random_" & $i, "contains mismatch for key " & key.repr)
    of 3:
      let fmVal = fm.get(key, "")
      let refVal = reference.getOrDefault(key, "")
      if fmVal != refVal:
        fail("map_random_" & $i, "get mismatch for key " & key.repr & ": fm=" & fmVal.repr & " ref=" & refVal.repr)
    else:
      let fmDel = fm.del(key)
      let refHad = key in reference
      if refHad:
        reference.del(key)
      if fmDel != refHad:
        fail("map_random_" & $i, "del mismatch for key " & key.repr)
  if fm.len != reference.len:
    fail("map_random_" & $i, "len mismatch: fm=" & $fm.len & " ref=" & $reference.len)
  for k, v in reference:
    let fmVal = fm.get(k, "")
    if fmVal != v:
      fail("map_random_" & $i, "final check mismatch for " & k.repr)
  fm.close()

echo "--- Category 2: FastMap[int64] random ops vs Table ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fm = newFastMap[int64]()
  var reference = initTable[string, int64]()
  let ops = rng.rand(200) + 10
  for j in 0 ..< ops:
    let op = rng.rand(4)
    let key = randomPrintableKey(20)
    let val = int64(rng.rand(int.high))
    case op
    of 0, 1:
      discard fm.put(key, val)
      reference[key] = val
    of 2:
      if fm.contains(key) != (key in reference):
        fail("map_int64_" & $i, "contains mismatch")
    of 3:
      if fm.get(key, -1'i64) != reference.getOrDefault(key, -1'i64):
        fail("map_int64_" & $i, "get mismatch for " & key.repr)
    else:
      let fmDel = fm.del(key)
      let refHad = key in reference
      if refHad: reference.del(key)
      if fmDel != refHad:
        fail("map_int64_" & $i, "del mismatch")
  if fm.len != reference.len:
    fail("map_int64_" & $i, "len mismatch: fm=" & $fm.len & " ref=" & $reference.len)
  fm.close()

echo "--- Category 3: FastSet random ops vs HashSet ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fs = newFastSet()
  var reference = initHashSet[string]()
  let ops = rng.rand(200) + 10
  for j in 0 ..< ops:
    let op = rng.rand(3)
    let key = randomPrintableKey(30)
    case op
    of 0, 1:
      discard fs.incl(key)
      reference.incl(key)
    of 2:
      if fs.contains(key) != (key in reference):
        fail("set_random_" & $i, "contains mismatch for " & key.repr)
    else:
      let fsDel = fs.excl(key)
      let refHad = key in reference
      if refHad: reference.excl(key)
      if fsDel != refHad:
        fail("set_random_" & $i, "excl mismatch for " & key.repr)
  if fs.len != reference.len:
    fail("set_random_" & $i, "len mismatch: fs=" & $fs.len & " ref=" & $reference.len)
  fs.close()

echo "--- Category 4: Hash collision stress ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fm = newFastMap[string]()
  var reference = initTable[string, string]()
  let numKeys = rng.rand(100) + 20
  for j in 0 ..< numKeys:
    let key = collidingKey(j)
    let val = $j
    discard fm.put(key, val)
    reference[key] = val
  for k, v in reference:
    let fmVal = fm.get(k, "")
    if fmVal != v:
      fail("collision_" & $i, "get mismatch after collision keys for " & k.repr)
  for j in 0 ..< numKeys:
    if rng.rand(1) == 0:
      let key = collidingKey(j)
      discard fm.del(key)
      reference.del(key)
  if fm.len != reference.len:
    fail("collision_" & $i, "len mismatch after partial delete")
  fm.close()

echo "--- Category 5: Very long keys and values ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fm = newFastMap[string]()
  let keyLen = rng.rand(10_000) + 1000
  let valLen = rng.rand(10_000) + 1000
  let key = 'K'.repeat(keyLen) & $i
  let val = 'V'.repeat(valLen)
  try:
    discard fm.put(key, val)
    let retrieved = fm.get(key, "")
    if retrieved != val:
      fail("long_kv_" & $i, "value mismatch for key length " & $keyLen)
  except CatchableError as e:
    discard
  except Defect as e:
    fail("long_kv_" & $i, "Defect: " & e.msg)
  fm.close()

echo "--- Category 6: Empty keys and values ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fm = newFastMap[string]()
  try:
    discard fm.put("", "empty_key_val")
    discard fm.put("nonempty", "")
    discard fm.put("", "overwrite")
    let v1 = fm.get("", "default")
    if v1 != "overwrite":
      fail("empty_key_" & $i, "empty key get mismatch: " & v1.repr)
    let v2 = fm.get("nonempty", "default")
    if v2 != "":
      fail("empty_val_" & $i, "empty val get mismatch: " & v2.repr)
  except CatchableError:
    discard
  except Defect as e:
    fail("empty_kv_" & $i, "Defect: " & e.msg)
  fm.close()

echo "--- Category 7: Rapid grow/shrink cycles ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fm = newFastMap[string]()
  var reference = initTable[string, string]()
  let cycles = rng.rand(10) + 3
  for c in 0 ..< cycles:
    let growCount = rng.rand(200) + 50
    for j in 0 ..< growCount:
      let key = "cycle_" & $c & "_" & $j
      discard fm.put(key, $j)
      reference[key] = $j
    let shrinkCount = rng.rand(growCount)
    var deleted = 0
    for j in 0 ..< growCount:
      if deleted >= shrinkCount: break
      let key = "cycle_" & $c & "_" & $j
      if rng.rand(1) == 0:
        discard fm.del(key)
        reference.del(key)
        inc deleted
  if fm.len != reference.len:
    fail("grow_shrink_" & $i, "len mismatch: fm=" & $fm.len & " ref=" & $reference.len)
  for k, v in reference:
    if fm.get(k, "") != v:
      fail("grow_shrink_" & $i, "value mismatch for " & k.repr)
  fm.close()

echo "--- Category 8: Interleaved map and set operations ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fm = newFastMap[string]()
  let fs = newFastSet()
  let ops = rng.rand(300) + 50
  for j in 0 ..< ops:
    let key = randomPrintableKey(20)
    let op = rng.rand(5)
    try:
      case op
      of 0:
        discard fm.put(key, key)
        discard fs.incl(key)
      of 1:
        discard fm.del(key)
        discard fs.excl(key)
      of 2:
        discard fm.contains(key)
        discard fs.contains(key)
      of 3:
        discard fm.get(key, "")
      of 4:
        discard fm.hasKeyOrPut(key, "new_" & key)
        discard fs.containsOrIncl(key)
      else:
        fm.clear()
        fs.clear()
    except CatchableError:
      discard
    except Defect as e:
      fail("interleaved_" & $i, "Defect at op " & $j & ": " & e.msg)
  fm.close()
  fs.close()

echo "--- Category 9: Operator and iterator consistency ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fm = newFastMap[string]()
  let numInserts = rng.rand(100) + 10
  var insertedKeys = initHashSet[string]()
  for j in 0 ..< numInserts:
    let key = "iter_" & $j
    fm[key] = "val_" & $j
    insertedKeys.incl key
  var seenKeys = initHashSet[string]()
  for k, v in fm:
    seenKeys.incl k
  if seenKeys != insertedKeys:
    fail("iter_" & $i, "iterator missed or added keys")
  var keyCount = 0
  for k in fm.keys:
    inc keyCount
  if keyCount != fm.len:
    fail("iter_keys_" & $i, "keys iterator count mismatch")
  fm.close()

echo "--- Category 10: FastSet containsOrIncl/missingOrExcl ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let fs = newFastSet()
  var reference = initHashSet[string]()
  let ops = rng.rand(100) + 20
  for j in 0 ..< ops:
    let key = randomPrintableKey(15)
    let op = rng.rand(2)
    case op
    of 0:
      let wasPresent = fs.containsOrIncl(key)
      let refPresent = key in reference
      reference.incl key
      if wasPresent != refPresent:
        fail("containsOrIncl_" & $i, "mismatch for " & key.repr)
    of 1:
      let wasMissing = fs.missingOrExcl(key)
      let refMissing = key notin reference
      reference.excl key
      if wasMissing != refMissing:
        fail("missingOrExcl_" & $i, "mismatch for " & key.repr)
    else:
      if fs.contains(key) != (key in reference):
        fail("set_contains_" & $i, "mismatch for " & key.repr)
  if fs.len != reference.len:
    fail("set_ops_" & $i, "len mismatch: fs=" & $fs.len & " ref=" & $reference.len)
  fs.close()

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All fast collections fuzz tests passed (", Iterations * 10, " total iterations)"
  quit(0)
