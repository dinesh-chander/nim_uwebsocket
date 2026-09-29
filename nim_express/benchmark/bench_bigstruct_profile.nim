## Focused profiling target: FastMap[BigStruct] vs Table[string,BigStruct]
## Run with `sample` to capture CPU hotspots.
## Usage: bench_bigstruct_profile [mode=fastmap|table] [n=200000]

import std/[os, strutils, times, tables]
import nim_express/fast_hash

type
  BigStruct = object
    name: string
    port: int
    tags: seq[string]

proc makeBig(i: int): BigStruct =
  BigStruct(name: "host" & $i, port: 8000 + (i mod 1000), tags: @["a", "b", $i])

proc runFastMap(n, repeats: int) =
  let m = newFastMap[BigStruct]()
  defer: m.close()
  discard m.reserve(n * 2)
  for i in 0..<n: discard m.put("k" & $i, makeBig(i))

  var cs = 0
  var v: BigStruct
  for _ in 0..<repeats:
    for i in 0..<n:
      if m.tryGet("k" & $i, v): cs += v.port
  echo "FastMap checksum: ", cs

proc runTable(n, repeats: int) =
  var m = initTable[string, BigStruct](n * 2)
  for i in 0..<n: m["k" & $i] = makeBig(i)

  var cs = 0
  let miss = BigStruct()
  for _ in 0..<repeats:
    for i in 0..<n:
      cs += m.getOrDefault("k" & $i, miss).port
  echo "Table checksum: ", cs

when isMainModule:
  var mode    = "fastmap"
  var n       = 200_000
  var repeats = 5
  if paramCount() >= 1: mode    = paramStr(1)
  if paramCount() >= 2: n       = parseInt(paramStr(2))
  if paramCount() >= 3: repeats = parseInt(paramStr(3))

  echo "mode=", mode, "  n=", n, "  repeats=", repeats
  let t0 = epochTime()
  case mode
  of "fastmap": runFastMap(n, repeats)
  of "table":   runTable(n, repeats)
  else: quit("mode must be fastmap or table")
  echo "total: ", formatFloat((epochTime() - t0) * 1000.0, ffDecimal, 1), "ms"
