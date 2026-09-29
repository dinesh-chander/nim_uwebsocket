import std/[tables, monotimes, strutils, strformat]
import ../../nim_utils/src/nim_utils/helpers/fast_map

const Scales = [10, 100, 1_000, 10_000, 100_000]

proc nowNs(): int64 {.inline.} =
  getMonoTime().ticks

proc fmtNs(ns: float): string =
  if ns < 1000:
    return fmt"{ns:.1f} ns"
  elif ns < 1_000_000:
    return fmt"{ns / 1000:.1f} µs"
  else:
    return fmt"{ns / 1_000_000:.2f} ms"

proc generateKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0 ..< n:
    result[i] = "key_" & $i & "_data"

proc generateValues(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0 ..< n:
    result[i] = "value_" & $i & "_payload_string"

proc generateMissKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0 ..< n:
    result[i] = "miss_" & $i & "_notfound"

proc repeatCount(n: int): int =
  if n <= 10: 500_000
  elif n <= 100: 100_000
  elif n <= 1_000: 10_000
  elif n <= 10_000: 1_000
  else: 100

proc benchInsert(label: string, n: int) =
  let keys = generateKeys(n)
  let values = generateValues(n)
  let reps = repeatCount(n)

  var fmTotal: int64 = 0
  for r in 0 ..< reps:
    var fm = newFastMap[string]()
    let t0 = nowNs()
    for i in 0 ..< n:
      discard fm.put(keys[i], values[i])
    fmTotal += nowNs() - t0

  var tblTotal: int64 = 0
  for r in 0 ..< reps:
    var tbl = newTable[string, string]()
    let t0 = nowNs()
    for i in 0 ..< n:
      tbl[keys[i]] = values[i]
    tblTotal += nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  echo fmt"  {label:<12} insert   n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchLookupHit(label: string, n: int) =
  let keys = generateKeys(n)
  let values = generateValues(n)
  let reps = repeatCount(n) * 2

  var fm = newFastMap[string]()
  for i in 0 ..< n:
    discard fm.put(keys[i], values[i])

  var tbl = newTable[string, string]()
  for i in 0 ..< n:
    tbl[keys[i]] = values[i]

  var fmTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard fm.get(keys[i])
    fmTotal = nowNs() - t0

  var tblTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard tbl[keys[i]]
    tblTotal = nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  echo fmt"  {label:<12} get-hit  n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchLookupHitReuse(label: string, n: int) =
  let keys = generateKeys(n)
  let values = generateValues(n)
  let reps = repeatCount(n) * 2

  var fm = newFastMap[string]()
  for i in 0 ..< n:
    discard fm.put(keys[i], values[i])

  var tbl = newTable[string, string]()
  for i in 0 ..< n:
    tbl[keys[i]] = values[i]

  var fmTotal: int64 = 0
  block:
    var buf: string
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard fm.tryGet(keys[i], buf)
    fmTotal = nowNs() - t0

  var tblTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard tbl[keys[i]]
    tblTotal = nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  echo fmt"  {label:<12} get-ruse n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchLookupView(label: string, n: int) =
  let keys = generateKeys(n)
  let values = generateValues(n)
  let reps = repeatCount(n) * 2

  var fm = newFastMap[string]()
  for i in 0 ..< n:
    discard fm.put(keys[i], values[i])

  var tbl = newTable[string, string]()
  for i in 0 ..< n:
    tbl[keys[i]] = values[i]

  var fmTotal: int64 = 0
  block:
    var view: FastStringView
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard fm.tryGetView(keys[i], view)
    fmTotal = nowNs() - t0

  var tblTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard tbl[keys[i]]
    tblTotal = nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  echo fmt"  {label:<12} getView  n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchLookupMiss(label: string, n: int) =
  let keys = generateKeys(n)
  let values = generateValues(n)
  let missKeys = generateMissKeys(n)
  let reps = repeatCount(n) * 2

  var fm = newFastMap[string]()
  for i in 0 ..< n:
    discard fm.put(keys[i], values[i])

  var tbl = newTable[string, string]()
  for i in 0 ..< n:
    tbl[keys[i]] = values[i]

  var fmTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard fm.contains(missKeys[i])
    fmTotal = nowNs() - t0

  var tblTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard tbl.hasKey(missKeys[i])
    tblTotal = nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  echo fmt"  {label:<12} get-miss n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchContains(label: string, n: int) =
  let keys = generateKeys(n)
  let values = generateValues(n)
  let reps = repeatCount(n) * 2

  var fm = newFastMap[string]()
  for i in 0 ..< n:
    discard fm.put(keys[i], values[i])

  var tbl = newTable[string, string]()
  for i in 0 ..< n:
    tbl[keys[i]] = values[i]

  var fmTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard fm.contains(keys[i])
    fmTotal = nowNs() - t0

  var tblTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard tbl.hasKey(keys[i])
    tblTotal = nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  echo fmt"  {label:<12} contains n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchDelete(label: string, n: int) =
  let keys = generateKeys(n)
  let values = generateValues(n)
  let reps = repeatCount(n)

  var fmTotal: int64 = 0
  for r in 0 ..< reps:
    var fm = newFastMap[string]()
    for i in 0 ..< n:
      discard fm.put(keys[i], values[i])
    let t0 = nowNs()
    for i in 0 ..< n:
      discard fm.del(keys[i])
    fmTotal += nowNs() - t0

  var tblTotal: int64 = 0
  for r in 0 ..< reps:
    var tbl = newTable[string, string]()
    for i in 0 ..< n:
      tbl[keys[i]] = values[i]
    let t0 = nowNs()
    for i in 0 ..< n:
      tbl.del(keys[i])
    tblTotal += nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  echo fmt"  {label:<12} delete   n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchInt64Insert(n: int) =
  let keys = generateKeys(n)
  let reps = repeatCount(n)

  var fmTotal: int64 = 0
  for r in 0 ..< reps:
    var fm = newFastMap[int64]()
    let t0 = nowNs()
    for i in 0 ..< n:
      discard fm.put(keys[i], int64(i))
    fmTotal += nowNs() - t0

  var tblTotal: int64 = 0
  for r in 0 ..< reps:
    var tbl = newTable[string, int64]()
    let t0 = nowNs()
    for i in 0 ..< n:
      tbl[keys[i]] = int64(i)
    tblTotal += nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  let lbl1 = "int64"
  echo fmt"  {lbl1:<12} insert   n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchInt64Lookup(n: int) =
  let keys = generateKeys(n)
  let reps = repeatCount(n) * 2

  var fm = newFastMap[int64]()
  for i in 0 ..< n:
    discard fm.put(keys[i], int64(i))

  var tbl = newTable[string, int64]()
  for i in 0 ..< n:
    tbl[keys[i]] = int64(i)

  var fmTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard fm.get(keys[i])
    fmTotal = nowNs() - t0

  var tblTotal: int64 = 0
  block:
    let t0 = nowNs()
    for r in 0 ..< reps:
      for i in 0 ..< n:
        discard tbl[keys[i]]
    tblTotal = nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  let lbl2 = "int64"
  echo fmt"  {lbl2:<12} get-hit  n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchMapOfMaps(n: int) =
  let keys = generateKeys(n)
  let innerKeys = @["alpha", "beta", "gamma", "delta"]
  let reps = repeatCount(n)

  var fmTotal: int64 = 0
  for r in 0 ..< reps:
    var outer = newTable[string, FastMap[string]]()
    let t0 = nowNs()
    for i in 0 ..< n:
      var inner = newFastMap[string]()
      for ik in innerKeys:
        discard inner.put(ik, keys[i])
      outer[keys[i]] = inner
    fmTotal += nowNs() - t0

  var tblTotal: int64 = 0
  for r in 0 ..< reps:
    var outer = newTable[string, TableRef[string, string]]()
    let t0 = nowNs()
    for i in 0 ..< n:
      var inner = newTable[string, string]()
      for ik in innerKeys:
        inner[ik] = keys[i]
      outer[keys[i]] = inner
    tblTotal += nowNs() - t0

  let fmNsPerOp = fmTotal.float / (reps * n).float
  let tblNsPerOp = tblTotal.float / (reps * n).float
  let speedup = tblNsPerOp / fmNsPerOp
  let lbl3 = "map-of-map"
  echo fmt"  {lbl3:<12} create   n={n:<7} FM={fmtNs(fmNsPerOp):>10}  Table={fmtNs(tblNsPerOp):>10}  speedup={speedup:.2f}x"

proc benchMapOfSeq(n: int) =
  let keys = generateKeys(n)
  let reps = repeatCount(n)

  var tblTotal: int64 = 0
  for r in 0 ..< reps:
    var tbl = newTable[string, seq[string]]()
    let t0 = nowNs()
    for i in 0 ..< n:
      tbl[keys[i]] = @[keys[i], "a", "b", "c"]
    tblTotal += nowNs() - t0

  let tblNsPerOp = tblTotal.float / (reps * n).float
  let lbl = "map-of-seq"
  echo fmt"  {lbl:<12} create   n={n:<7}                     Table={fmtNs(tblNsPerOp):>10}  (FM N/A)"

when isMainModule:
  echo "FastMap vs Table[string, V] Benchmark"
  echo "======================================"
  echo ""

  for n in Scales:
    echo fmt"--- Scale: {n} ---"
    benchInsert("string", n)
    benchLookupHit("string", n)
    benchLookupHitReuse("string", n)
    benchLookupView("string", n)
    benchLookupMiss("string", n)
    benchContains("string", n)
    benchDelete("string", n)
    benchInt64Insert(n)
    benchInt64Lookup(n)
    when not defined(skipMapOfMaps):
      benchMapOfMaps(n)
      benchMapOfSeq(n)
    echo ""
