import std/[monotimes, os, strutils, times]

import ../../nim_fastjson
import ../direct_engine
import ../simdjson as simdjson

let fastJson = initFastJson()

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

  BorrowedLargeTextTodo = object
    id: int
    title: nim_fastjson.JsonStringView
    note: nim_fastjson.JsonStringView
    completed: bool

  BorrowedLargeTextEnvelope = object
    todos: seq[BorrowedLargeTextTodo]
    nextCursor: nim_fastjson.JsonStringView
    source: nim_fastjson.JsonStringView

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

proc escapedChunk(i: int): string =
  result = "line " & $i & "\n" &
    "quoted: \"value_" & $i & "\" " &
    "path: C:\\\\temp\\\\todo_" & $i & " " &
    "tab:\t marker"

proc jsonEscape(value: string): string =
  result.add('"')
  for c in value:
    case c
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(c)
  result.add('"')

proc buildBorrowedLargeText(count: int): string =
  var payload = """{"todos":["""
  for i in 0..<count:
    if i > 0:
      payload.add(',')
    payload.add("""{"id":""")
    payload.add($ (i + 1))
    payload.add(""","title":""")
    payload.add(jsonEscape(escapedChunk(i)))
    payload.add(""","note":""")
    payload.add(jsonEscape(escapedChunk(i + count)))
    payload.add(""","completed":""")
    payload.add(if (i and 1) == 0: "true" else: "false")
    payload.add('}')
  payload.add("""],"nextCursor":""")
  payload.add(jsonEscape("cursor_\n\"" & $count & "\""))
  payload.add(""","source":""")
  payload.add(jsonEscape("source\\\\escaped\npayload"))
  payload.add("""}""")
  payload

proc bench(name: string, iterations: int, op: proc()) =
  let start = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let ops = float(iterations) / (float(elapsedNs) / 1_000_000_000.0)
  echo name, ": ", formatFloat(ops, ffDecimal, 2), " ops/s"

template runScenario(label: string, value: typed, iterations: int) =
  block:
    let payload = fastJson.serialize(value)
    echo "scenario=", label, " bytes=", payload.len
    bench(label & " deserialize direct", iterations, proc() =
      discard deserializeDirect(payload, typeof(value))
    )
    bench(label & " deserialize simdjson", iterations, proc() =
      discard simdjson.deserialize(payload, typeof(value))
    )
    echo ""

when isMainModule:
  let iterations =
    if paramCount() > 0: parseInt(paramStr(1))
    else: 10000

  runScenario("small", buildSmall(), iterations)
  runScenario("medium", buildMedium(32), iterations)
  runScenario("nested", buildNested(8, 4, 3), iterations)
  runScenario("large_nested", buildNested(64, 8, 6), iterations)
  let borrowedPayload = buildBorrowedLargeText(64)
  echo "scenario=borrowed_large_text bytes=", borrowedPayload.len
  bench("borrowed_large_text deserialize nim_fastjson", iterations, proc() =
    discard fastJson.deserialize(borrowedPayload, BorrowedLargeTextEnvelope)
  )
  bench("borrowed_large_text deserialize simdjson", iterations, proc() =
    discard simdjson.deserialize(borrowedPayload, BorrowedLargeTextEnvelope)
  )
  echo ""
