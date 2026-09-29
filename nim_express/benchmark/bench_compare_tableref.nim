## Comprehensive comparison: FastMap (Swiss table, Nim backend) vs Nim TableRef
## Covers: string→string, string→int64, string→struct, string→map, string→seq
##
## Usage: bench_compare_tableref [n=500000]

import std/[os, strutils, tables, times, strformat]
import nim_express/fast_hash

# ── shared helpers ──────────────────────────────────────────────────────────

proc msBetween(a, b: float): float {.inline.} = (b - a) * 1000.0

proc fmtOps(n: int, ms: float): string =
  if ms <= 0.0: return "      N/A"
  let rate = n.float * 1000.0 / ms
  if rate >= 1_000_000.0:
    &"{rate / 1_000_000.0:6.1f}M/s"
  elif rate >= 1_000.0:
    &"{rate / 1_000.0:6.1f}K/s"
  else:
    &"{rate:6.0f}/s"

proc printRow(label, insert, lookup, overwrite, iterate, erase: string) =
  echo &"  {label:<14}  ins={insert}  lkp={lookup}  ovr={overwrite}  itr={iterate}  del={erase}"

proc printSep(title: string) =
  echo ""
  echo "─── ", title, " ", "─".repeat(max(0, 60 - title.len))

# ── value types for struct benchmarks ───────────────────────────────────────

type
  SmallStruct = object   ## 32 bytes, no heap — like a 3D point + id
    x, y, z: float64
    id: int32

  BigStruct = object     ## has heap-allocated members — like a config record
    name: string
    port: int
    tags: seq[string]

proc makeSmall(i: int): SmallStruct =
  SmallStruct(x: float64(i) * 0.1, y: float64(i) * 0.2, z: float64(i) * 0.3, id: int32(i))

proc makeBig(i: int): BigStruct =
  BigStruct(name: "host" & $i, port: 8000 + (i mod 1000), tags: @["a", "b", $i])

# ── benchmark: FastMap[string] string→string ────────────────────────────────

proc benchFastMapStr(n: int, lkpReps = 1): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  let m = newFastMap[string]()
  defer: m.close()
  discard m.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n: discard m.put("k" & $i, "v" & $i)
  let t1 = epochTime()

  var cs = 0
  for _ in 0..<lkpReps:
    for i in 0..<n: cs += m.getLen("k" & $i, 0)
  let t2 = epochTime()

  for _ in 0..<lkpReps:
    for i in 0..<n: discard m.put("k" & $i, "w" & $i)
  let t3 = epochTime()

  for _ in 0..<lkpReps:
    for k, v in m.pairsView(): cs += k.len + v.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): discard m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2)/float(lkpReps),
   msBetween(t2,t3)/float(lkpReps), msBetween(t3,t4)/float(lkpReps),
   msBetween(t4,t5), cs)

# ── benchmark: TableRef[string,string] ──────────────────────────────────────

proc benchTableRefStr(n: int, lkpReps = 1): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  let m = newTable[string, string](n * 2)

  let t0 = epochTime()
  for i in 0..<n: m["k" & $i] = "v" & $i
  let t1 = epochTime()

  var cs = 0
  for _ in 0..<lkpReps:
    for i in 0..<n: cs += m.getOrDefault("k" & $i).len
  let t2 = epochTime()

  for _ in 0..<lkpReps:
    for i in 0..<n: m["k" & $i] = "w" & $i
  let t3 = epochTime()

  for _ in 0..<lkpReps:
    for k, v in m: cs += k.len + v.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2)/float(lkpReps),
   msBetween(t2,t3)/float(lkpReps), msBetween(t3,t4)/float(lkpReps),
   msBetween(t4,t5), cs)

# ── benchmark: FastMap[int64] string→int64 ──────────────────────────────────

proc benchFastMapInt(n: int, lkpReps = 1): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  let m = newFastMap[int64]()
  defer: m.close()
  discard m.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n: discard m.put("k" & $i, int64(i))
  let t1 = epochTime()

  var cs = 0
  for _ in 0..<lkpReps:
    for i in 0..<n: cs += int(m.getOrDefault("k" & $i, 0))
  let t2 = epochTime()

  for _ in 0..<lkpReps:
    for i in 0..<n: discard m.put("k" & $i, int64(i + n))
  let t3 = epochTime()

  for _ in 0..<lkpReps:
    for k, v in m.pairs(): cs += k.len + int(v)
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): discard m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2)/float(lkpReps),
   msBetween(t2,t3)/float(lkpReps), msBetween(t3,t4)/float(lkpReps),
   msBetween(t4,t5), cs)

# ── benchmark: Table[string,int64] ──────────────────────────────────────────

proc benchTableInt(n: int, lkpReps = 1): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  var m = initTable[string, int64](n * 2)

  let t0 = epochTime()
  for i in 0..<n: m["k" & $i] = int64(i)
  let t1 = epochTime()

  var cs = 0
  for _ in 0..<lkpReps:
    for i in 0..<n: cs += int(m.getOrDefault("k" & $i, 0))
  let t2 = epochTime()

  for _ in 0..<lkpReps:
    for i in 0..<n: m["k" & $i] = int64(i + n)
  let t3 = epochTime()

  for _ in 0..<lkpReps:
    for k, v in m: cs += k.len + int(v)
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2)/float(lkpReps),
   msBetween(t2,t3)/float(lkpReps), msBetween(t3,t4)/float(lkpReps),
   msBetween(t4,t5), cs)

# ── benchmark: FastMap[SmallStruct] ─────────────────────────────────────────

proc benchFastMapSmallStruct(n: int, lkpReps = 1): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  let m = newFastMap[SmallStruct]()
  defer: m.close()
  discard m.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n: discard m.put("k" & $i, makeSmall(i))
  let t1 = epochTime()

  var cs = 0
  var v: SmallStruct
  for _ in 0..<lkpReps:
    for i in 0..<n:
      if m.tryGet("k" & $i, v): cs += int(v.id)
  let t2 = epochTime()

  for _ in 0..<lkpReps:
    for i in 0..<n: discard m.put("k" & $i, makeSmall(i + n))
  let t3 = epochTime()

  for _ in 0..<lkpReps:
    for k, val in m.pairs(): cs += k.len + int(val.id)
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): discard m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2)/float(lkpReps),
   msBetween(t2,t3)/float(lkpReps), msBetween(t3,t4)/float(lkpReps),
   msBetween(t4,t5), cs)

# ── benchmark: Table[string, SmallStruct] ───────────────────────────────────

proc benchTableSmallStruct(n: int, lkpReps = 1): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  var m = initTable[string, SmallStruct](n * 2)

  let t0 = epochTime()
  for i in 0..<n: m["k" & $i] = makeSmall(i)
  let t1 = epochTime()

  var cs = 0
  let miss = SmallStruct()
  for _ in 0..<lkpReps:
    for i in 0..<n: cs += int(m.getOrDefault("k" & $i, miss).id)
  let t2 = epochTime()

  for _ in 0..<lkpReps:
    for i in 0..<n: m["k" & $i] = makeSmall(i + n)
  let t3 = epochTime()

  for _ in 0..<lkpReps:
    for k, v in m: cs += k.len + int(v.id)
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2)/float(lkpReps),
   msBetween(t2,t3)/float(lkpReps), msBetween(t3,t4)/float(lkpReps),
   msBetween(t4,t5), cs)

# ── benchmark: Table[string, ref SmallStruct] ───────────────────────────────

proc benchTableRefStruct(n: int, lkpReps = 1): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  var m = initTable[string, ref SmallStruct](n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    let s = new(SmallStruct)
    s[] = makeSmall(i)
    m["k" & $i] = s
  let t1 = epochTime()

  var cs = 0
  for _ in 0..<lkpReps:
    for i in 0..<n:
      let v = m.getOrDefault("k" & $i)
      if v != nil: cs += int(v.id)
  let t2 = epochTime()

  for _ in 0..<lkpReps:
    for i in 0..<n:
      let s = new(SmallStruct)
      s[] = makeSmall(i + n)
      m["k" & $i] = s
  let t3 = epochTime()

  for _ in 0..<lkpReps:
    for k, v in m:
      if v != nil: cs += k.len + int(v.id)
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2)/float(lkpReps),
   msBetween(t2,t3)/float(lkpReps), msBetween(t3,t4)/float(lkpReps),
   msBetween(t4,t5), cs)

# ── benchmark: FastMap[BigStruct] ───────────────────────────────────────────

proc benchFastMapBigStruct(n: int, lkpReps = 1): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  let m = newFastMap[BigStruct]()
  defer: m.close()
  discard m.reserve(n * 2)

  let t0 = epochTime()
  for i in 0..<n: discard m.put("k" & $i, makeBig(i))
  let t1 = epochTime()

  var cs = 0
  var v: BigStruct
  for _ in 0..<lkpReps:
    for i in 0..<n:
      if m.tryGet("k" & $i, v): cs += v.port
  let t2 = epochTime()

  for _ in 0..<lkpReps:
    for i in 0..<n: discard m.put("k" & $i, makeBig(i + n))
  let t3 = epochTime()

  for _ in 0..<lkpReps:
    for k, val in m.pairs(): cs += k.len + val.port
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): discard m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2)/float(lkpReps),
   msBetween(t2,t3)/float(lkpReps), msBetween(t3,t4)/float(lkpReps),
   msBetween(t4,t5), cs)

# ── benchmark: Table[string, BigStruct] (heap members) ──────────────────────

proc benchTableBigStruct(n: int, lkpReps = 1): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  var m = initTable[string, BigStruct](n * 2)

  let t0 = epochTime()
  for i in 0..<n: m["k" & $i] = makeBig(i)
  let t1 = epochTime()

  var cs = 0
  let miss = BigStruct()
  for _ in 0..<lkpReps:
    for i in 0..<n: cs += m.getOrDefault("k" & $i, miss).port
  let t2 = epochTime()

  for _ in 0..<lkpReps:
    for i in 0..<n: m["k" & $i] = makeBig(i + n)
  let t3 = epochTime()

  for _ in 0..<lkpReps:
    for k, v in m: cs += k.len + v.port
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2)/float(lkpReps),
   msBetween(t2,t3)/float(lkpReps), msBetween(t3,t4)/float(lkpReps),
   msBetween(t4,t5), cs)

# ── benchmark: Table[string, Table[string,string]] (map of maps) ─────────────
# Uses n/10 outer keys × 10 inner keys to keep allocation realistic

proc benchTableOfMaps(n: int): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  let outerN = max(n div 10, 1)
  var m = initTable[string, Table[string, string]](outerN * 2)

  let t0 = epochTime()
  for i in 0..<outerN:
    var inner = initTable[string, string](16)
    for j in 0..<10:
      inner["f" & $j] = "v" & $i & "_" & $j
    m["k" & $i] = inner
  let t1 = epochTime()

  var cs = 0
  for i in 0..<outerN:
    let inner = m.getOrDefault("k" & $i)
    for j in 0..<10:
      cs += inner.getOrDefault("f" & $j).len
  let t2 = epochTime()

  for i in 0..<outerN:
    m.withValue("k" & $i, inner):
      for j in 0..<10:
        inner[][ "f" & $j] = "w" & $i & "_" & $j
  let t3 = epochTime()

  for k, inner in m:
    cs += k.len
    for ik, iv in inner: cs += ik.len + iv.len
  let t4 = epochTime()

  for i in countup(0, outerN - 1, 2): m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2), msBetween(t2,t3), msBetween(t3,t4), msBetween(t4,t5), cs)

# ── benchmark: Table[string, seq[string]] (map of lists) ────────────────────

proc benchTableOfSeqs(n: int): tuple[ins, lkp, ovr, itr, del: float, cs: int] =
  var m = initTable[string, seq[string]](n * 2)

  let t0 = epochTime()
  for i in 0..<n:
    m["k" & $i] = @["a" & $i, "b" & $i, "c" & $i, "d" & $i, "e" & $i]
  let t1 = epochTime()

  var cs = 0
  for i in 0..<n:
    let s = m.getOrDefault("k" & $i)
    cs += s.len
  let t2 = epochTime()

  for i in 0..<n:
    m["k" & $i] = @["x" & $i, "y" & $i]
  let t3 = epochTime()

  for k, v in m:
    cs += k.len
    for item in v: cs += item.len
  let t4 = epochTime()

  for i in countup(0, n - 1, 2): m.del("k" & $i)
  let t5 = epochTime()

  (msBetween(t0,t1), msBetween(t1,t2), msBetween(t2,t3), msBetween(t3,t4), msBetween(t4,t5), cs)

# ── output ───────────────────────────────────────────────────────────────────

proc row(n: int, r: tuple[ins, lkp, ovr, itr, del: float, cs: int]): string =
  let (ins, lkp, ovr, itr, del, _) = r
  &"ins={fmtOps(n,ins)}  lkp={fmtOps(n,lkp)}  ovr={fmtOps(n,ovr)}  itr={fmtOps(n,itr)}  del={fmtOps(n div 2,del)}"

proc msRow(n: int, r: tuple[ins, lkp, ovr, itr, del: float, cs: int]): string =
  let (ins, lkp, ovr, itr, del, _) = r
  &"ins={ins:6.1f}ms  lkp={lkp:6.1f}ms  ovr={ovr:6.1f}ms  itr={itr:6.1f}ms  del={del:6.1f}ms"

proc tableRow(label: string, labelW: int, n: int,
              r: tuple[ins, lkp, ovr, itr, del: float, cs: int]): string =
  let (ins, lkp, ovr, itr, del, _) = r
  "  " & alignLeft(label, labelW) &
    "  " & align(fmtOps(n,ins), 12) &
    "  " & align(fmtOps(n,lkp), 12) &
    "  " & align(fmtOps(n,ovr), 12) &
    "  " & align(fmtOps(n,itr), 12) &
    "  " & align(fmtOps(n div 2,del), 12)

when isMainModule:
  var n = 500_000
  if paramCount() >= 1:
    n = parseInt(paramStr(1))
  if n <= 0:
    quit("N must be > 0", QuitFailure)

  let SEP72  = "=".repeat(72)
  let SEP88  = "-".repeat(88)
  let SEP92  = "-".repeat(92)
  let SEP96  = "-".repeat(96)
  let mapN   = n div 10
  let cols   = "  insert        lookup     overwrite       iterate        delete"
  let hdr22  = "  " & alignLeft("implementation", 22) & "  " & cols
  let hdr26  = "  " & alignLeft("implementation", 26) & "  " & cols
  let hdr30  = "  " & alignLeft("implementation", 30) & "  " & cols

  # lkpReps: repeat lookup/overwrite/iterate phases so each measures ≥50ms at small N
  # At N=100 → 500 reps; N=1000 → 50 reps; N≥50000 → 1 rep
  let lkpReps = max(1, 50_000 div n)

  echo "Warming up (50k, lkpReps=1)..."
  discard benchFastMapStr(50_000)
  discard benchTableRefStr(50_000)
  discard benchFastMapInt(50_000)
  discard benchTableInt(50_000)
  discard benchFastMapSmallStruct(10_000)
  discard benchTableSmallStruct(10_000)
  discard benchTableRefStruct(10_000)
  discard benchFastMapBigStruct(10_000)
  discard benchTableBigStruct(10_000)
  discard benchTableOfMaps(50_000)
  discard benchTableOfSeqs(50_000)

  echo "\n" & SEP72
  echo "  Benchmark  N=" & $n & "  lkpReps=" & $lkpReps &
       "  (map of maps: N/10=" & $mapN & " x 10 inner keys)"
  echo SEP72

  # ── string → string ──────────────────────────────────────────────────────
  printSep("string -> string")
  let fm_str  = benchFastMapStr(n, lkpReps)
  let tbl_str = benchTableRefStr(n, lkpReps)
  echo hdr22
  echo "  " & SEP88
  echo tableRow("FastMap[string]",     22, n, fm_str)
  echo tableRow("Table[string,string]",22, n, tbl_str)
  echo ""
  echo "  ms breakdown:"
  echo "  " & alignLeft("FastMap[string]",     22) & "  " & msRow(n, fm_str)
  echo "  " & alignLeft("Table[string,string]",22) & "  " & msRow(n, tbl_str)

  let strIns = if tbl_str.ins > 0: fm_str.ins / tbl_str.ins else: 0.0
  let strLkp = if tbl_str.lkp > 0: fm_str.lkp / tbl_str.lkp else: 0.0
  echo ""
  echo &"  speedup vs Table:  insert={1.0/strIns:.2f}x  lookup={1.0/strLkp:.2f}x  (>1 = FastMap faster)"

  # ── string → int64 ───────────────────────────────────────────────────────
  printSep("string -> int64")
  let fm_int  = benchFastMapInt(n, lkpReps)
  let tbl_int = benchTableInt(n, lkpReps)
  echo hdr22
  echo "  " & SEP88
  echo tableRow("FastMap[int64]",      22, n, fm_int)
  echo tableRow("Table[string,int64]", 22, n, tbl_int)
  echo ""
  echo "  ms breakdown:"
  echo "  " & alignLeft("FastMap[int64]",      22) & "  " & msRow(n, fm_int)
  echo "  " & alignLeft("Table[string,int64]", 22) & "  " & msRow(n, tbl_int)

  let intIns = if tbl_int.ins > 0: fm_int.ins / tbl_int.ins else: 0.0
  let intLkp = if tbl_int.lkp > 0: fm_int.lkp / tbl_int.lkp else: 0.0
  echo ""
  echo &"  speedup vs Table:  insert={1.0/intIns:.2f}x  lookup={1.0/intLkp:.2f}x"

  # ── string → struct ───────────────────────────────────────────────────────
  printSep("string -> struct  (SmallStruct: 3xfloat64 + int32 = 28 bytes, no heap)")
  let fm_ss   = benchFastMapSmallStruct(n, lkpReps)
  let tbl_ss  = benchTableSmallStruct(n, lkpReps)
  let tbl_rs  = benchTableRefStruct(n, lkpReps)
  echo hdr30
  echo "  " & SEP96
  echo tableRow("FastMap[SmallStruct]",      30, n, fm_ss)
  echo tableRow("Table[str,SmallStruct]",    30, n, tbl_ss)
  echo tableRow("Table[str,ref SmallStruct]",30, n, tbl_rs)
  echo ""
  echo "  ms breakdown:"
  echo "  " & alignLeft("FastMap[SmallStruct]",      30) & "  " & msRow(n, fm_ss)
  echo "  " & alignLeft("Table[str,SmallStruct]",    30) & "  " & msRow(n, tbl_ss)
  echo "  " & alignLeft("Table[str,ref SmallStruct]",30) & "  " & msRow(n, tbl_rs)

  let ssIns = if tbl_ss.ins > 0: fm_ss.ins / tbl_ss.ins else: 0.0
  let ssLkp = if tbl_ss.lkp > 0: fm_ss.lkp / tbl_ss.lkp else: 0.0
  echo ""
  echo &"  speedup vs Table[SmallStruct]:  insert={1.0/ssIns:.2f}x  lookup={1.0/ssLkp:.2f}x"
  echo "  Note: ref adds GC alloc per insert; inline struct avoids alloc but bloats table buckets"

  # ── string → BigStruct ────────────────────────────────────────────────────
  printSep("string -> BigStruct  (has string + seq fields = heap-allocated members)")
  let fm_bs  = benchFastMapBigStruct(n, lkpReps)
  let tbl_bs = benchTableBigStruct(n, lkpReps)
  echo hdr30
  echo "  " & SEP96
  echo tableRow("FastMap[BigStruct]",  30, n, fm_bs)
  echo tableRow("Table[str,BigStruct]",30, n, tbl_bs)
  echo ""
  echo "  ms breakdown:"
  echo "  " & alignLeft("FastMap[BigStruct]",  30) & "  " & msRow(n, fm_bs)
  echo "  " & alignLeft("Table[str,BigStruct]",30) & "  " & msRow(n, tbl_bs)

  let bsIns = if tbl_bs.ins > 0: fm_bs.ins / tbl_bs.ins else: 0.0
  let bsLkp = if tbl_bs.lkp > 0: fm_bs.lkp / tbl_bs.lkp else: 0.0
  echo ""
  echo &"  speedup vs Table[BigStruct]:  insert={1.0/bsIns:.2f}x  lookup={1.0/bsLkp:.2f}x"

  # ── string → Table (nested map) ───────────────────────────────────────────
  printSep("string -> Table[string,string]  (nested map: " & $mapN & " outer x 10 inner keys)")
  let tbl_nm = benchTableOfMaps(n)
  echo hdr30
  echo "  " & SEP96
  echo tableRow("Table[str,Table[str,str]]", 30, mapN, tbl_nm)
  echo ""
  echo "  ms breakdown:  " & msRow(mapN, tbl_nm)
  echo "  Note: ops/s measured per outer key (each op touches 10 inner entries)"

  # ── string → seq[string] ─────────────────────────────────────────────────
  printSep("string -> seq[string]  (map of lists: " & $n & " keys x 5 items each)")
  let tbl_sq = benchTableOfSeqs(n)
  echo hdr26
  echo "  " & SEP92
  echo tableRow("Table[str,seq[str]]",26, n, tbl_sq)
  echo ""
  echo "  ms breakdown:  " & msRow(n, tbl_sq)
  echo "  Note: lookup returns seq by value (copy); overwrite reallocs new seq"

  echo ""
  echo SEP72
  echo "Checksums (verify no optimization removed actual work):"
  echo "  FastMap[string]:           " & $fm_str.cs
  echo "  Table[string,string]:      " & $tbl_str.cs
  echo "  FastMap[int64]:            " & $fm_int.cs
  echo "  Table[string,int64]:       " & $tbl_int.cs
  echo "  FastMap[SmallStruct]:      " & $fm_ss.cs
  echo "  Table[string,SmallStruct]: " & $tbl_ss.cs
  echo "  Table[string,ref Struct]:  " & $tbl_rs.cs
  echo "  FastMap[BigStruct]:        " & $fm_bs.cs
  echo "  Table[string,BigStruct]:   " & $tbl_bs.cs
  echo "  Table[string,nested map]:  " & $tbl_nm.cs
  echo "  Table[string,seq[string]]: " & $tbl_sq.cs
