import std/[monotimes, os, strutils, times]
import jsony

import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

template deserialize(json: untyped, T: typedesc): untyped =
  fastJson.deserialize(json, T)

type
  EscapedTodo = object
    id: int
    title: string
    note: string
    completed: bool

  EscapedEnvelope = object
    todos: seq[EscapedTodo]
    nextCursor: string
    source: string

  BorrowedEscapedTodo = object
    id: int
    title: JsonStringView
    note: JsonStringView
    completed: bool

  BorrowedEscapedEnvelope = object
    todos: seq[BorrowedEscapedTodo]
    nextCursor: JsonStringView
    source: JsonStringView

proc escapedChunk(i: int): string =
  result = "line " & $i & "\n" &
    "quoted: \"value_" & $i & "\" " &
    "path: C:\\\\temp\\\\todo_" & $i & " " &
    "tab:\t marker"

proc buildEscapedEnvelope(count: int): EscapedEnvelope =
  result.nextCursor = "cursor_\n\"" & $count & "\""
  result.source = "source\\\\escaped\npayload"
  result.todos = newSeq[EscapedTodo](count)
  for i in 0..<count:
    result.todos[i] = EscapedTodo(
      id: i + 1,
      title: escapedChunk(i),
      note: escapedChunk(i + count),
      completed: (i and 1) == 0
    )

proc bench(name: string, iterations: int, op: proc()) =
  let start = getMonoTime()
  for _ in 0..<iterations:
    op()
  let elapsedNs = inNanoseconds(getMonoTime() - start)
  let ops = float(iterations) / (float(elapsedNs) / 1_000_000_000.0)
  echo name, ": ", formatFloat(ops, ffDecimal, 2), " ops/s"

when isMainModule:
  let iterations =
    if paramCount() > 0: parseInt(paramStr(1))
    else: 10000
  let env = buildEscapedEnvelope(32)
  let payload = jsony.toJson(env)

  bench("serialize jsony escaped", iterations, proc() =
    discard jsony.toJson(env)
  )
  bench("serialize nim_fastjson escaped", iterations, proc() =
    discard serialize(env)
  )
  bench("deserialize jsony escaped", iterations, proc() =
    discard jsony.fromJson(payload, EscapedEnvelope)
  )
  bench("deserialize nim_fastjson escaped", iterations, proc() =
    discard deserialize(payload, EscapedEnvelope)
  )
  bench("deserialize nim_fastjson borrowed escaped", iterations, proc() =
    discard deserialize(payload, BorrowedEscapedEnvelope)
  )
