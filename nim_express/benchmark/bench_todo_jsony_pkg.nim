import std/[os, strformat, strutils, times]
import jsony

import ../examples/todo_sqlite_mvc/todo_model

type
  TodoListResponse = object
    todos: seq[Todo]

  BenchResult = object
    name: string
    iterations: int
    elapsedMs: float
    checksum: int

proc msBetween(startedAt, endedAt: float): float {.inline.} =
  (endedAt - startedAt) * 1000.0

proc opsPerSec(iterations: int, elapsedMs: float): float {.inline.} =
  if elapsedMs <= 0.0:
    return 0.0
  iterations.float * 1000.0 / elapsedMs

proc printResult(result: BenchResult) =
  echo result.name
  echo "  iterations: ", result.iterations
  echo "  elapsed:    ", formatFloat(result.elapsedMs, ffDecimal, 2), " ms"
  echo "  throughput: ", formatFloat(opsPerSec(result.iterations, result.elapsedMs), ffDecimal, 0), " ops/s"
  echo "  checksum:   ", result.checksum

proc benchSingleTodo(todo: Todo, iterations: int): BenchResult =
  var checksum = 0
  let startedAt = epochTime()
  for _ in 0 ..< iterations:
    let payload = jsony.toJson(todo)
    inc checksum, payload.len
  let endedAt = epochTime()
  BenchResult(
    name: "single todo jsony pkg",
    iterations: iterations,
    elapsedMs: msBetween(startedAt, endedAt),
    checksum: checksum
  )

proc benchTodoList(todos: seq[Todo], iterations: int): BenchResult =
  var checksum = 0
  let wrapped = TodoListResponse(todos: todos)
  let startedAt = epochTime()
  for _ in 0 ..< iterations:
    let payload = jsony.toJson(wrapped)
    inc checksum, payload.len
  let endedAt = epochTime()
  BenchResult(
    name: "todo list jsony pkg",
    iterations: iterations,
    elapsedMs: msBetween(startedAt, endedAt),
    checksum: checksum
  )

when isMainModule:
  var iterations = 200_000
  if paramCount() >= 1:
    iterations = parseInt(paramStr(1))
  if iterations <= 0:
    quit("iterations must be > 0", QuitFailure)

  let todo = Todo(id: 7, title: "ship serializer", completed: true, createdAt: "2026-03-13T10:00:00Z")
  var todos = newSeqOfCap[Todo](128)
  for i in 0 ..< 128:
    todos.add(Todo(
      id: i + 1,
      title: "todo-" & $i & "-ship-serializer",
      completed: (i and 1) == 0,
      createdAt: "2026-03-13T10:00:00Z"
    ))

  echo &"Benchmark iterations={iterations}"
  echo "Warming up..."
  discard benchSingleTodo(todo, min(iterations, 10_000))
  discard benchTodoList(todos, min(iterations, 2_000))
  echo ""

  printResult(benchSingleTodo(todo, iterations))
  echo ""
  printResult(benchTodoList(todos, iterations))
