import std/[monotimes, os, strutils, times]
import jsony

import ../../nim_fastjson

let fastJson = initFastJson()

template serialize(value: untyped): untyped =
  fastJson.serialize(value)

template deserialize(json: untyped, T: typedesc): untyped =
  fastJson.deserialize(json, T)

type
  Todo = object
    id: int
    title: string
    completed: bool

  Envelope = object
    todos: seq[Todo]
    nextCursor: string

proc sampleEnvelope(count: int): Envelope =
  result.nextCursor = "cursor_" & $count
  result.todos = newSeq[Todo](count)
  for i in 0..<count:
    result.todos[i] = Todo(
      id: i + 1,
      title: "todo_" & $i,
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
  let env = sampleEnvelope(32)
  let payload = jsony.toJson(env)

  bench("serialize jsony", iterations, proc() =
    discard jsony.toJson(env)
  )
  bench("serialize nim_fastjson", iterations, proc() =
    discard serialize(env)
  )
  bench("deserialize jsony", iterations, proc() =
    discard jsony.fromJson(payload, Envelope)
  )
  bench("deserialize nim_fastjson", iterations, proc() =
    discard deserialize(payload, Envelope)
  )
