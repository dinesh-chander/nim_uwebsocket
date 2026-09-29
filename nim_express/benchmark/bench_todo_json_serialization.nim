import std/[json, os, strformat, strutils, times]
import ./vendor/jsony_local/jsony as jsony_local

import ../examples/todo_sqlite_mvc/todo_model
import ../examples/todo_sqlite_mvc/todo_view
import ../src/nim_express/json_builder

type
  SerializerKind = enum
    skJsonNode
    skJsonyLocal
    skJsonyLocalPrepared
    skJsonyLocalRows
    skDirect

  BenchScope = enum
    bsAll
    bsSingle
    bsList

  TodoListResponse = object
    todos: seq[Todo]

  PreparedTodo = object
    id: jsony_local.RawJson
    title: jsony_local.RawJson
    completed: jsony_local.RawJson
    createdAt: jsony_local.RawJson

  PreparedTodoListResponse = object
    todos: seq[PreparedTodo]

  RawTodoRowsResponse = object
    todos: seq[jsony_local.RawJson]

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

proc parseSerializerKind(value: string): SerializerKind =
  case value.normalize
  of "jsonnode", "json-node", "node":
    skJsonNode
  of "jsony", "jsony-local", "local":
    skJsonyLocal
  of "jsony-prepared", "prepared":
    skJsonyLocalPrepared
  of "jsony-rows", "rows", "materialized":
    skJsonyLocalRows
  of "direct":
    skDirect
  else:
    quit("unknown serializer: " & value, QuitFailure)

proc parseBenchScope(value: string): BenchScope =
  case value.normalize
  of "all":
    bsAll
  of "single":
    bsSingle
  of "list":
    bsList
  else:
    quit("unknown scope: " & value, QuitFailure)

proc todoJsonNode(todo: Todo): JsonNode =
  %*{
    "id": todo.id,
    "title": todo.title,
    "completed": todo.completed,
    "createdAt": todo.createdAt
  }

proc todosJsonNode(todos: seq[Todo]): JsonNode =
  var data = newJArray()
  for todo in todos:
    data.add(todoJsonNode(todo))
  %*{"todos": data}

proc rawJsonString(value: string): jsony_local.RawJson =
  jsony_local.RawJson(value)

proc encodeJsonString(value: string): jsony_local.RawJson =
  var builder = initJsonBuilder(value.len + 8)
  builder.addEscaped(value)
  jsony_local.RawJson(builder.finish())

proc encodeJsonBool(value: bool): jsony_local.RawJson =
  jsony_local.RawJson(if value: "true" else: "false")

proc encodeJsonInt(value: int): jsony_local.RawJson =
  var s = newStringOfCap(12)
  fastIntToStr(value, s)
  jsony_local.RawJson(s)

proc buildPreparedTodo(todo: Todo): PreparedTodo =
  PreparedTodo(
    id: encodeJsonInt(todo.id),
    title: encodeJsonString(todo.title),
    completed: encodeJsonBool(todo.completed),
    createdAt: encodeJsonString(todo.createdAt)
  )

proc buildPreparedTodoList(todos: seq[Todo]): PreparedTodoListResponse =
  result.todos = newSeqOfCap[PreparedTodo](todos.len)
  for todo in todos:
    result.todos.add(buildPreparedTodo(todo))

proc buildRawTodoRows(todos: seq[Todo]): RawTodoRowsResponse =
  result.todos = newSeqOfCap[jsony_local.RawJson](todos.len)
  for todo in todos:
    result.todos.add(rawJsonString(todo_view.todoJson(todo)))

proc benchSingleTodo(
  todo: Todo,
  preparedTodo: PreparedTodo,
  rawTodoRow: jsony_local.RawJson,
  iterations: int,
  kind: SerializerKind
): BenchResult =
  var checksum = 0
  let startedAt = epochTime()
  for _ in 0 ..< iterations:
    let payload = case kind
      of skJsonNode:
        $todoJsonNode(todo)
      of skJsonyLocal:
        jsony_local.toJson(todo)
      of skJsonyLocalPrepared:
        jsony_local.toJson(preparedTodo)
      of skJsonyLocalRows:
        jsony_local.toJson(rawTodoRow)
      of skDirect:
        todo_view.todoJson(todo)
    inc checksum, payload.len
  let endedAt = epochTime()
  BenchResult(
    name: case kind
      of skJsonNode: "single todo JsonNode"
      of skJsonyLocal: "single todo jsony local"
      of skJsonyLocalPrepared: "single todo jsony local prepared"
      of skJsonyLocalRows: "single todo jsony local rows"
      of skDirect: "single todo direct",
    iterations: iterations,
    elapsedMs: msBetween(startedAt, endedAt),
    checksum: checksum
  )

proc benchTodoList(
  todos: seq[Todo],
  preparedTodos: PreparedTodoListResponse,
  rawTodoRows: RawTodoRowsResponse,
  iterations: int,
  kind: SerializerKind
): BenchResult =
  var checksum = 0
  let startedAt = epochTime()
  let wrapped = TodoListResponse(todos: todos)
  for _ in 0 ..< iterations:
    let payload = case kind
      of skJsonNode:
        $todosJsonNode(todos)
      of skJsonyLocal:
        jsony_local.toJson(wrapped)
      of skJsonyLocalPrepared:
        jsony_local.toJson(preparedTodos)
      of skJsonyLocalRows:
        jsony_local.toJson(rawTodoRows)
      of skDirect:
        todo_view.todosJson(todos)
    inc checksum, payload.len
  let endedAt = epochTime()
  BenchResult(
    name: case kind
      of skJsonNode: "todo list JsonNode"
      of skJsonyLocal: "todo list jsony local"
      of skJsonyLocalPrepared: "todo list jsony local prepared"
      of skJsonyLocalRows: "todo list jsony local rows"
      of skDirect: "todo list direct",
    iterations: iterations,
    elapsedMs: msBetween(startedAt, endedAt),
    checksum: checksum
  )

when isMainModule:
  var iterations = 200_000
  var scope = bsAll
  var serializerFilter = ""
  if paramCount() >= 1:
    iterations = parseInt(paramStr(1))
  if paramCount() >= 2:
    scope = parseBenchScope(paramStr(2))
  if paramCount() >= 3:
    serializerFilter = paramStr(3)
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
  let preparedTodo = buildPreparedTodo(todo)
  let rawTodoRow = rawJsonString(todo_view.todoJson(todo))
  let preparedTodos = buildPreparedTodoList(todos)
  let rawTodoRows = buildRawTodoRows(todos)

  let kinds =
    if serializerFilter.len == 0:
      @[skJsonNode, skJsonyLocal, skJsonyLocalPrepared, skJsonyLocalRows, skDirect]
    else:
      @[parseSerializerKind(serializerFilter)]
  let serializerLabel =
    if serializerFilter.len == 0: "all" else: serializerFilter

  echo &"Benchmark iterations={iterations} scope={scope} serializer={serializerLabel}"
  echo "Warming up..."
  if scope in {bsAll, bsSingle}:
    for kind in kinds:
      discard benchSingleTodo(todo, preparedTodo, rawTodoRow, min(iterations, 10_000), kind)
  if scope in {bsAll, bsList}:
    for kind in kinds:
      discard benchTodoList(todos, preparedTodos, rawTodoRows, min(iterations, 2_000), kind)
  echo ""

  if scope in {bsAll, bsSingle}:
    for kind in kinds:
      printResult(benchSingleTodo(todo, preparedTodo, rawTodoRow, iterations, kind))
    if scope == bsAll:
      echo ""
  if scope in {bsAll, bsList}:
    for kind in kinds:
      printResult(benchTodoList(todos, preparedTodos, rawTodoRows, iterations, kind))
