import std/[monotimes, os, strutils, times]
import jsony

import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

template deserialize(json: untyped, T: typedesc): untyped =
  fastJson.deserialize(json, T)

template serializeInto(buf: untyped, value: untyped): untyped =
  fastJson.serializeInto(buf, value)

type
  SmallTodo = object
    id: int
    title: string
    completed: bool

  MediumEnvelope = object
    todos: seq[SmallTodo]
    nextCursor: string
    totalCount: int
    source: string

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

proc buildSmall(): SmallTodo =
  SmallTodo(id: 7, title: "ship", completed: true)

proc buildMedium(count: int): MediumEnvelope =
  result.nextCursor = "cursor_" & $count
  result.totalCount = count
  result.source = "nim_fastjson_bench"
  result.todos = newSeq[SmallTodo](count)
  for i in 0..<count:
    result.todos[i] = SmallTodo(
      id: i + 1,
      title: "todo_" & $i,
      completed: (i and 1) == 0
    )

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

proc bench(name: string, iterations: int, op: proc()) =
  if iterations < 0:
    while true:
      op()
  let start = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let ops = float(iterations) / (float(elapsedNs) / 1_000_000_000.0)
  echo name, ": ", formatFloat(ops, ffDecimal, 2), " ops/s"

template runScenario(label: string, value: typed, iterations: int) =
  block:
    let encodedJsony = jsony.toJson(value)
    echo "scenario=", label, " bytes=", encodedJsony.len
    if phaseFilter == "all" or phaseFilter == "serialize":
      if engineFilter == "all" or engineFilter == "jsony":
        bench(label & " serialize jsony", iterations, proc() =
          discard jsony.toJson(value)
        )
      if engineFilter == "all" or engineFilter == "nim_fastjson":
        bench(label & " serialize nim_fastjson", iterations, proc() =
          discard serialize(value)
        )
        var reuseBuf = newStringOfCap(32768)
        bench(label & " serialize nim_fastjson (reuse)", iterations, proc() =
          serializeInto(reuseBuf, value)
        )
    if phaseFilter == "all" or phaseFilter == "deserialize":
      if engineFilter == "all" or engineFilter == "jsony":
        bench(label & " deserialize jsony", iterations, proc() =
          discard jsony.fromJson(encodedJsony, typeof(value))
        )
      if engineFilter == "all" or engineFilter == "nim_fastjson":
        bench(label & " deserialize nim_fastjson", iterations, proc() =
          discard deserialize(encodedJsony, typeof(value))
        )
    echo ""

when isMainModule:
  let iterations =
    if paramCount() > 0: parseInt(paramStr(1))
    else: 10000
  let scenarioFilter =
    if paramCount() > 1: paramStr(2)
    else: "all"
  let phaseFilter =
    if paramCount() > 2: paramStr(3)
    else: "all"
  let engineFilter =
    if paramCount() > 3: paramStr(4)
    else: "all"

  let small = buildSmall()
  let medium = buildMedium(32)
  let nested = buildNested(8, 4, 3)
  let largeNested = buildNested(64, 8, 6)

  if scenarioFilter == "all" or scenarioFilter == "small":
    runScenario("small", small, iterations)
  if scenarioFilter == "all" or scenarioFilter == "medium":
    runScenario("medium", medium, iterations)
  if scenarioFilter == "all" or scenarioFilter == "nested":
    runScenario("nested", nested, iterations)
  if scenarioFilter == "all" or scenarioFilter == "large_nested":
    runScenario("large_nested", largeNested, iterations)
