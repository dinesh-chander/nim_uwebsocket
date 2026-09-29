## Profile where time goes in large_nested serialize
import std/[monotimes, times, formatfloat, strutils]
import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

type
  Metric = object
    kind: string
    value: float64

  ChildNode = object
    id: int
    name: string
    tags: seq[string]
    metrics: seq[Metric]
    completed: bool

  NestedEnvelope = object
    version: int
    requestId: string
    children: seq[ChildNode]
    nextCursor: string

proc buildNested(childCount, tagCount, metricCount: int): NestedEnvelope =
  result.version = 3
  result.requestId = "req_" & $childCount & "_" & $tagCount & "_" & $metricCount
  result.nextCursor = "next_" & $childCount
  result.children = newSeq[ChildNode](childCount)
  for i in 0..<childCount:
    result.children[i].id = i + 1
    result.children[i].name = "child_" & $i
    result.children[i].completed = (i and 1) == 0
    result.children[i].tags = newSeq[string](tagCount)
    for tagIdx in 0..<tagCount:
      result.children[i].tags[tagIdx] = "tag_" & $tagIdx & "_" & $i
    result.children[i].metrics = newSeq[Metric](metricCount)
    for metricIdx in 0..<metricCount:
      result.children[i].metrics[metricIdx] = Metric(
        kind: "metric_" & $metricIdx,
        value: float64((i + 1) * (metricIdx + 3)) / 7.0
      )

proc bench(name: string, iterations: int, op: proc()): float =
  let start = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let ops = float(iterations) / (float(elapsedNs) / 1_000_000_000.0)
  echo name, ": ", formatFloat(ops, ffDecimal, 2), " ops/s"
  result = float(elapsedNs) / float(iterations)

when isMainModule:
  let n = buildNested(64, 8, 6)
  let iters = 10000

  echo "--- Full serialize ---"
  let fullNs = bench("full large_nested", iters, proc() =
    discard serialize(n)
  )

  echo "\n--- Component isolation ---"

  # Count objects: 64 children, each has 8 tags, 6 metrics
  # Total strings to quote: 64*(1 name + 8 tags + 6 metric kinds) + 2 top-level = 962
  # Total floats: 64*6 = 384
  # Total ints: 64 ids + 1 version = 65

  # Isolate: float serialization
  var floatBuf = newStringOfCap(8192)
  let floatNs = bench("384 float addFloat", iters, proc() =
    floatBuf.setLen(0)
    for i in 0..<64:
      for m in 0..<6:
        floatBuf.addFloat(float64((i + 1) * (m + 3)) / 7.0)
  )

  # Isolate: string quoting (short safe strings)
  var strBuf = newStringOfCap(16384)
  let allStrings = block:
    var s: seq[string]
    s.add(n.requestId)
    s.add(n.nextCursor)
    for c in n.children:
      s.add(c.name)
      for t in c.tags:
        s.add(t)
      for m in c.metrics:
        s.add(m.kind)
    s

  let strNs = bench($(allStrings.len) & " string quotes", iters, proc() =
    strBuf.setLen(0)
    for s in allStrings:
      strBuf.add('"')
      strBuf.add(s)
      strBuf.add('"')
  )

  # Isolate: string quoting through appendJsonEscaped path
  let escNs = bench($(allStrings.len) & " string appendJsonEscaped", iters, proc() =
    strBuf.setLen(0)
    for s in allStrings:
      discard serialize(s)  # goes through appendJsonEscaped
  )

  # Isolate: int serialization
  let intNs = bench("65 ints", iters, proc() =
    strBuf.setLen(0)
    for i in 0..<65:
      strBuf.add($i)
  )

  # Isolate: structural overhead (braces, commas, field names)
  let structNs = bench("structural chars only", iters, proc() =
    strBuf.setLen(0)
    strBuf.add('{')
    strBuf.add("\"version\":")
    strBuf.add("\"requestId\":")
    strBuf.add("\"children\":[")
    for i in 0..<64:
      if i > 0: strBuf.add(',')
      strBuf.add('{')
      strBuf.add("\"id\":")
      strBuf.add(",\"name\":")
      strBuf.add(",\"tags\":[")
      for j in 0..<8:
        if j > 0: strBuf.add(',')
      strBuf.add(']')
      strBuf.add(",\"metrics\":[")
      for j in 0..<6:
        if j > 0: strBuf.add(',')
        strBuf.add('{')
        strBuf.add("\"kind\":")
        strBuf.add(",\"value\":")
        strBuf.add('}')
      strBuf.add(']')
      strBuf.add(",\"completed\":")
      strBuf.add('}')
    strBuf.add(']')
    strBuf.add(",\"nextCursor\":")
    strBuf.add('}')
  )

  echo "\n--- Time breakdown (ns per call) ---"
  echo "full:        ", formatFloat(fullNs, ffDecimal, 0), " ns"
  echo "floats:      ", formatFloat(floatNs, ffDecimal, 0), " ns"
  echo "str escape:  ", formatFloat(escNs, ffDecimal, 0), " ns"
  echo "str direct:  ", formatFloat(strNs, ffDecimal, 0), " ns"
  echo "ints:        ", formatFloat(intNs, ffDecimal, 0), " ns"
  echo "structural:  ", formatFloat(structNs, ffDecimal, 0), " ns"
  echo "sum parts:   ", formatFloat(floatNs + escNs + intNs + structNs, ffDecimal, 0), " ns"
  echo ""
  echo "float %:     ", formatFloat(floatNs / fullNs * 100, ffDecimal, 1), "%"
  echo "str esc %:   ", formatFloat(escNs / fullNs * 100, ffDecimal, 1), "%"
  echo "str raw %:   ", formatFloat(strNs / fullNs * 100, ffDecimal, 1), "%"
  echo "int %:       ", formatFloat(intNs / fullNs * 100, ffDecimal, 1), "%"
  echo "struct %:    ", formatFloat(structNs / fullNs * 100, ffDecimal, 1), "%"
