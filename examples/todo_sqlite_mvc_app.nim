## Todo example using MVC + async endpoints + SQLite model + HTMX views

import std/[os, strutils]
import ../nim_express/src/nim_express
import ./todo_sqlite_mvc/[todo_model, todo_controller]

proc configureViews(app: ExpressApp) =
  # Resolve templates robustly from binary location and cwd.
  let appDir = getAppDir()
  let candidates = [
    joinPath(appDir, "../examples/views"),            # examples/bin -> examples/views
    joinPath(appDir, "examples/views"),               # binary launched from repo root
    joinPath(appDir, "../views"),                     # generic sibling layout
    "examples/views",                                 # repo root cwd
    "views"                                           # generic fallback
  ]

  for candidate in candidates:
    let resolved = absolutePath(candidate)
    if dirExists(resolved):
      app.setViewsDir(resolved)
      return

proc main() =
  let app = newExpressApp()

  configureViews(app)

  let enableRequestLog = getEnv("TODO_LOG", "0").toLowerAscii() in ["1", "true", "yes", "on"]
  if enableRequestLog:
    app.use(logger(llInfo))
    app.onErrorHook(proc(message: string) =
      stderr.writeLine("[error] " & message)
    )
  app.use(cors())
  app.use(bodyParser())
  app.use(helmet())
  # Fragment endpoints can emit large HTML responses as the list grows.
  # Raise per-socket pending budget to avoid premature close on partial writes.
  app.setMaxPendingBytesPerSocket(8 * 1024 * 1024)

  let perfProfile = getEnv("NIM_EXPRESS_PROFILE", "").toLowerAscii()
  if perfProfile == "linux-throughput":
    app.applyLinuxThroughputProfile()

  let dbPath = getEnv("TODO_DB_PATH", "todos.db")
  var port = 3000
  try:
    port = parseInt(getEnv("PORT", "3000"))
  except ValueError:
    port = 3000
  let client = initAsyncTodoClient(dbPath)
  let controller = newTodoController(client)

  app.onShutdown proc() =
    client.close()

  # HTMX UI routes
  app.getAsync("/") do (req: Request, res: Response) {.async.}:
    await controller.home(req, res)

  app.getAsync("/todos/fragment") do (req: Request, res: Response) {.async.}:
    await controller.listTodosHtmx(req, res)

  app.getAsync("/todos/count") do (req: Request, res: Response) {.async.}:
    await controller.todoCountHtmx(req, res)

  app.getAsync("/metrics") do (req: Request, res: Response) {.async.}:
    res.contentType("application/json; charset=utf-8")
    res.send(app.optimizationMetricsJson())

  app.postAsync("/todos") do (req: Request, res: Response) {.async.}:
    await controller.createTodoHtmx(req, res)

  app.postAsync("/todos/:id/toggle") do (req: Request, res: Response) {.async.}:
    await controller.toggleTodoHtmx(req, res)

  app.deleteAsync("/todos/:id") do (req: Request, res: Response) {.async.}:
    await controller.deleteTodoHtmx(req, res)

  # JSON API routes
  app.getAsync("/api/todos") do (req: Request, res: Response) {.async.}:
    await controller.listTodosApi(req, res)

  app.getAsync("/api/todos/:id") do (req: Request, res: Response) {.async.}:
    await controller.getTodoApi(req, res)

  app.postAsync("/api/todos") do (req: Request, res: Response) {.async.}:
    await controller.createTodoApi(req, res)

  app.putAsync("/api/todos/:id") do (req: Request, res: Response) {.async.}:
    await controller.updateTodoApi(req, res)

  app.deleteAsync("/api/todos/:id") do (req: Request, res: Response) {.async.}:
    await controller.deleteTodoApi(req, res)

  echo "Starting Todo MVC + SQLite + HTMX example..."
  echo "Database: ", dbPath
  app.listen(port) do (ok: bool):
    if ok:
      echo "Server running at http://localhost:", port
    else:
      echo "Failed to start server!"
      quit(1)

when isMainModule:
  main()
