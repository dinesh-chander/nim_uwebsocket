## Full-stack todo + multipart upload example.

import std/[json, os, strutils]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

type
  Attachment = object
    originalName: string
    storedPath: string
    sizeBytes: int

  Todo = object
    id: int
    title: string
    done: bool
    attachments: seq[Attachment]

var
  todos: seq[Todo] = @[
    Todo(id: 1, title: "design route model", done: false, attachments: @[]),
    Todo(id: 2, title: "wire multipart upload", done: false, attachments: @[])
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

proc findTodoIndex(id: int): int =
  for i, todo in todos:
    if todo.id == id:
      return i
  -1

proc attachmentSummary(todo: Todo): string =
  if todo.attachments.len == 0:
    return "No attachments"
  var parts: seq[string] = @[]
  for a in todo.attachments:
    parts.add(a.originalName & " (" & $a.sizeBytes & " bytes)")
  parts.join(", ")

proc renderTodoItem(todo: Todo, tpl: CompiledTemplate): string =
  var locals = newFastMap[string]()
  discard locals.reserve(8)
  discard locals.put("id", $todo.id)
  discard locals.put("title", todo.title)
  discard locals.put("done_class", if todo.done: "done" else: "")
  discard locals.put("attachments", attachmentSummary(todo))
  renderTemplate(tpl, locals)

proc renderTodoList(tpl: CompiledTemplate): string =
  var rendered = newStringOfCap(max(64, todos.len * 180))
  for todo in todos:
    rendered.add(renderTodoItem(todo, tpl))
  rendered

proc toJson(todo: Todo): JsonNode =
  var files: seq[JsonNode] = @[]
  for a in todo.attachments:
    files.add(%*{
      "name": a.originalName,
      "path": a.storedPath,
      "sizeBytes": a.sizeBytes
    })
  %*{
    "id": todo.id,
    "title": todo.title,
    "done": todo.done,
    "attachments": files
  }

proc main*() =
  let app = newExpressApp()
  let viewsDir = resolveViewsDir("fullstack_todo_upload")
  if viewsDir.len == 0:
    echo "fullstack_todo_upload views not found"
    quit(1)
  app.setViewsDir(viewsDir)

  let uploadsDir = resolveGeneratedDir("uploads")

  var mp = defaultMultipartOptions()
  mp.maxBodyBytes = 16 * 1024 * 1024
  mp.uploadDir = uploadsDir

  app.use(bodyParser())
  app.use(multipart(mp))
  app.use(htmx())
  app.use(timeout(20_000))
  app.use(serveStatic(uploadsDir, "/uploads"))

  let itemTplPath = viewsDir / "item.html"
  let itemTplLoad = compileTemplateFile(itemTplPath)
  if not itemTplLoad.ok:
    echo "failed to compile item template: ", itemTplLoad.error
    quit(1)
  let itemTpl = itemTplLoad.compiled

  app.getAsync("/") do (_: Request, res: Response) {.async.}:
    var locals = newFastMap[string]()
    discard locals.reserve(4)
    discard locals.put("title", "Todo + Upload")
    discard locals.put("subtitle", "HTMX + SSR + multipart form-data upload")
    discard locals.put("todos_html", renderTodoList(itemTpl))
    res.render("index", locals)

  app.postAsync("/todos") do (req: Request, res: Response) {.async.}:
    let title = req.form("title").strip()
    if title.len == 0:
      res.badRequest("title is required")
      return
    let todo = Todo(id: nextTodoId, title: title, done: false, attachments: @[])
    inc nextTodoId
    todos.add(todo)
    res.contentType("text/html; charset=utf-8")
    res.send(renderTodoItem(todo, itemTpl))

  app.postAsync("/todos/:id/toggle") do (req: Request, res: Response) {.async.}:
    let idRes = parseParamInt(req, "id")
    if not idRes.ok:
      res.badRequest(idRes.err)
      return
    let idx = findTodoIndex(idRes.value)
    if idx < 0:
      res.notFound()
      return
    todos[idx].done = not todos[idx].done
    res.contentType("text/html; charset=utf-8")
    res.send(renderTodoItem(todos[idx], itemTpl))

  app.deleteAsync("/todos/:id") do (req: Request, res: Response) {.async.}:
    let idRes = parseParamInt(req, "id")
    if not idRes.ok:
      res.badRequest(idRes.err)
      return
    let idx = findTodoIndex(idRes.value)
    if idx < 0:
      res.notFound()
      return
    todos.delete(idx)
    res.status(204).send("")

  app.postAsync("/todos/:id/upload") do (req: Request, res: Response) {.async.}:
    let idRes = parseParamInt(req, "id")
    if not idRes.ok:
      res.badRequest(idRes.err)
      return
    let idx = findTodoIndex(idRes.value)
    if idx < 0:
      res.notFound()
      return

    let originalName = req.local("file_attachment_name")
    let storedPath = req.local("file_attachment_path")
    let sizeRaw = req.local("file_attachment_size", "0")
    if originalName.len == 0 or storedPath.len == 0:
      res.badRequest("attachment is required")
      return

    var sizeBytes = 0
    try:
      sizeBytes = parseInt(sizeRaw)
    except ValueError:
      sizeBytes = 0

    todos[idx].attachments.add(Attachment(
      originalName: originalName,
      storedPath: storedPath,
      sizeBytes: max(0, sizeBytes)
    ))
    res.contentType("text/html; charset=utf-8")
    res.send(renderTodoItem(todos[idx], itemTpl))

  app.getAsync("/api/todos") do (_: Request, res: Response) {.async.}:
    var rows: seq[JsonNode] = @[]
    for todo in todos:
      rows.add(toJson(todo))
    res.json(%*{"items": rows, "count": rows.len})

  app.getAsync("/api/todos/export") do (req: Request, res: Response) {.async.}:
    req.onAbort(proc(reason: RequestCancelReason) =
      echo "[fullstack_todo_upload_app] export aborted: ", $reason
    )
    for _ in 0 ..< 25:
      if req.aborted():
        return
      await sleepAsync(25)

    var rows: seq[JsonNode] = @[]
    for todo in todos:
      rows.add(toJson(todo))
    if req.aborted():
      return
    res.json(%*{
      "exported": rows.len,
      "timeoutRemainingMs": requestTimeoutRemainingMs(req),
      "items": rows
    })

  let port = parsePort(3000)
  app.listen(port) do (ok: bool):
    if ok:
      echo "fullstack_todo_upload_app listening on http://localhost:", port
      echo "uploads dir: ", uploadsDir
    else:
      echo "failed to start fullstack_todo_upload_app"
      quit(1)
