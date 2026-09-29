## REST API example with generated OpenAPI artifact.

import std/[json, os, strutils]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

type
  Todo = object
    id: int
    title: string
    done: bool

  CreateTodoBody = object
    title: string

var
  todos: seq[Todo] = @[
    Todo(id: 1, title: "document API", done: false),
    Todo(id: 2, title: "ship first client", done: true)
  ]
  nextTodoId = 3

proc parseParamInt(req: Request, key: string): tuple[ok: bool, value: int, err: string] =
  let raw = req.param(key).strip()
  if raw.len == 0:
    return (false, 0, "missing required path parameter: " & key)
  try:
    (true, parseInt(raw), "")
  except ValueError:
    (false, 0, "invalid integer path parameter: " & key)

proc toJson(todo: Todo): JsonNode =
  %*{
    "id": todo.id,
    "title": todo.title,
    "done": todo.done
  }

proc findTodoIndex(id: int): int =
  for i, todo in todos:
    if todo.id == id:
      return i
  -1

proc buildOpenApiDocument(serverUrl: string): JsonNode =
  %*{
    "openapi": "3.1.0",
    "info": {
      "title": "nim_express REST OpenAPI example",
      "version": "1.0.0"
    },
    "servers": [{"url": serverUrl}],
    "paths": {
      "/api/todos": {
        "get": {"summary": "List todos"},
        "post": {"summary": "Create todo"}
      },
      "/api/todos/{id}": {
        "get": {"summary": "Get todo by id"},
        "delete": {"summary": "Delete todo by id"}
      }
    }
  }

proc writeOpenApiArtifact(path: string, doc: JsonNode): tuple[ok: bool, error: string] =
  try:
    writeFile(path, pretty(doc))
    (true, "")
  except CatchableError as err:
    (false, err.msg)

proc main*() =
  let app = newExpressApp()
  app.use(bodyParser())
  app.use(timeout(12_000))
  app.use(requestId())

  let port = parsePort(3000)
  let generatedDir = resolveGeneratedDir("rest_openapi")
  let openApiPath = generatedDir / "openapi.json"

  proc regenerateOpenApi() =
    let serverUrl = "http://localhost:" & $port
    let result = writeOpenApiArtifact(openApiPath, buildOpenApiDocument(serverUrl))
    if not result.ok:
      echo "failed to write OpenAPI artifact: ", result.error

  regenerateOpenApi()

  app.getAsync("/") do (_: Request, res: Response) {.async.}:
    res.json(%*{
      "name": "rest_openapi_app",
      "openapiPath": openApiPath,
      "routes": [
        "GET /api/todos",
        "POST /api/todos",
        "GET /api/todos/:id",
        "DELETE /api/todos/:id",
        "GET /openapi.json"
      ]
    })

  app.getAsync("/openapi.json") do (_: Request, res: Response) {.async.}:
    try:
      res.contentType("application/json; charset=utf-8")
      res.send(readFile(openApiPath))
    except CatchableError:
      res.serverError("failed to load generated OpenAPI artifact")

  app.postAsync("/openapi/regenerate") do (_: Request, res: Response) {.async.}:
    regenerateOpenApi()
    res.status(202).json(%*{"ok": true, "path": openApiPath})

  app.getAsync("/api/todos") do (_: Request, res: Response) {.async.}:
    var rows: seq[JsonNode] = @[]
    rows.setLen(todos.len)
    for i, todo in todos:
      rows[i] = toJson(todo)
    res.json(%*{"items": rows, "count": rows.len})

  app.getAsync("/api/todos/:id") do (req: Request, res: Response) {.async.}:
    let idRes = parseParamInt(req, "id")
    if not idRes.ok:
      res.badRequest(idRes.err)
      return
    let idx = findTodoIndex(idRes.value)
    if idx < 0:
      res.notFound()
      return
    res.json(toJson(todos[idx]))

  app.postAsync("/api/todos") do (req: Request, res: Response) {.async.}:
    let body = tryParseBody[CreateTodoBody](req)
    if not body.ok or body.value.title.strip().len == 0:
      res.badRequest("title is required")
      return
    let todo = Todo(id: nextTodoId, title: body.value.title.strip(), done: false)
    inc nextTodoId
    todos.add(todo)
    res.status(201).json(toJson(todo))

  app.deleteAsync("/api/todos/:id") do (req: Request, res: Response) {.async.}:
    let idRes = parseParamInt(req, "id")
    if not idRes.ok:
      res.badRequest(idRes.err)
      return
    let idx = findTodoIndex(idRes.value)
    if idx < 0:
      res.notFound()
      return
    let removed = todos[idx]
    todos.delete(idx)
    res.json(%*{"deleted": toJson(removed)})

  app.getAsync("/api/todos/search") do (req: Request, res: Response) {.async.}:
    req.onAbort(proc(reason: RequestCancelReason) =
      echo "[rest_openapi_app] search aborted: ", $reason
    )
    let query = req.queryParam("q", "").toLowerAscii()
    for _ in 0 ..< 20:
      if req.aborted():
        return
      await sleepAsync(20)

    var rows: seq[JsonNode] = @[]
    for todo in todos:
      if query.len == 0 or query in todo.title.toLowerAscii():
        rows.add(toJson(todo))
    if req.aborted():
      return
    res.json(%*{
      "query": query,
      "count": rows.len,
      "timeoutRemainingMs": requestTimeoutRemainingMs(req),
      "items": rows
    })

  app.listen(port) do (ok: bool):
    if ok:
      echo "rest_openapi_app listening on http://localhost:", port
      echo "OpenAPI artifact: ", openApiPath
    else:
      echo "failed to start rest_openapi_app"
      quit(1)
