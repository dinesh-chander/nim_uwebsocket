## fastjson serialization scan A/B: SSE2 (default) vs portable (-d:nimFastjsonPortable).
## Matrix over string length x escape density, plus a correctness round-trip check.
import std/[monotimes]
import nim_utils/nim_fastjson as fjm

let fj = fjm.initFastJson()

const BS = char(92)  # backslash

proc mkString(len, escapeEvery: int): string =
  # escapeEvery<=0 -> no escapes; else a backslash every escapeEvery bytes.
  result = newStringOfCap(len + 64)
  for i in 0 ..< len:
    if escapeEvery > 0 and i mod escapeEvery == 0:
      result.add(BS)
    result.add('a')

proc nowNs(): int64 = getMonoTime().ticks

# ---- correctness: both builds must emit identical, valid JSON ----
for s in [mkString(1000, 7), mkString(333, 0), ""]:
  let ser = fj.serialize(s)
  let back: string = fj.deserialize(ser, string)
  doAssert(back == s, "round-trip mismatch len=" & $s.len)
echo "correctness OK"

# ---- perf matrix: serialize ops/s ----
proc benchOne(s: string, iters: int): float =
  var sink = 0
  var t0 = nowNs()
  for i in 0 ..< iters:
    sink += fj.serialize(s).len
  let dt = nowNs() - t0
  discard sink
  result = iters.float64 / (dt.float64 / 1e9)

echo "len     density        ops/s"
for len in [32, 256, 4096, 65536]:
  for (dn, every) in [("none", 0), ("sparse/1KB", 1024), ("dense/8B", 8)]:
    let s = mkString(len, every)
    let iters = if len >= 4096: 2000 else: 40000
    echo $len & "     " & dn & "        " & $benchOne(s, iters).int
