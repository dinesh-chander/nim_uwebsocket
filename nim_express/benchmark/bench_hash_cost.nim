import std/[os, strutils, times]
import nim_express/fast_hash

proc buildKeys(n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0..<n: result[i] = "k" & $i

proc benchTouchOnly(keys: seq[string], repeats: int): float =
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    for k in keys: checksum += k.len
  let t1 = epochTime()
  discard checksum
  (t1 - t0) * 1000.0

proc benchLookup(keys: seq[string], repeats: int): float =
  let m = newFastMap[string]()
  defer: m.close()
  discard m.reserve(keys.len * 2)
  for i in 0..<keys.len: discard m.put(keys[i], "v" & $i)
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<repeats:
    for k in keys: checksum += m.getLen(k, 0)
  let t1 = epochTime()
  discard checksum
  (t1 - t0) * 1000.0

when isMainModule:
  let n = 200_000
  let reps = 10
  let keys = buildKeys(n)
  discard benchTouchOnly(keys[0..<10_000], 2)
  discard benchLookup(keys[0..<10_000], 2)
  let touchMs = benchTouchOnly(keys, reps)
  let lookupMs = benchLookup(keys, reps)
  let nsPerOp = proc(ms: float): float = (ms / float(n * reps)) * 1e6
  echo "Key-touch (seq traversal): ", touchMs, " ms  (", nsPerOp(touchMs), " ns/op)"
  echo "Full map lookup:           ", lookupMs, " ms  (", nsPerOp(lookupMs), " ns/op)"
  echo "Map overhead above touch:  ", lookupMs - touchMs, " ms"
