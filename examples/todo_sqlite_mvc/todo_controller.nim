## Controller layer (C in MVC) for async todo routes.

import std/[json, options, strutils, asyncdispatch, os]
import ../../nim_express/src/nim_express
import ./todo_model
import ./todo_view
import ./todo_templates

const
  ItemsRangeUnit = "items"
  MaxFragmentWindowItems = 256
  DefaultFragmentWindowItems = 64
  DefaultFullFragmentMaxItems* = 4096
  MaxFullFragmentMaxItems* = 100_000
  FullFragmentDisabledMessage* = "full todo fragment mode is disabled"
  FullFragmentLimitMessage* = "full todo fragment exceeds configured item limit"
  # Larger page size reduces fragment segment count and write syscalls.
  TodoFragmentPageSize = 256 * 1024

type
  TodoWindowFragmentResult = object
    content: string
    rowCount: int
    remaining: int

  TodoController* = ref object
    client*: AsyncTodoClient
    listSegs: tuple[prefix: string, middle: string, suffix: string]
    itemTemplate: FastTemplate
    itemPlan: TodoItemRenderPlan
    countTemplate: FastTemplate
    indexHtml: string
    autoWindowByDefault: bool
    allowFullFragmentOverride: bool
    fullFragmentMaxItems: int

proc parseBoolEnv(name: string, defaultValue: bool): bool =
  let raw = getEnv(name, if defaultValue: "1" else: "0").toLowerAscii()
  raw in ["1", "true", "yes", "on"]

proc parseBoundedIntEnv(name: string, defaultValue, minValue, maxValue: int): int =
  let raw = getEnv(name, $defaultValue).strip()
  try:
    result = parseInt(raw)
  except ValueError:
    result = defaultValue
  result = min(max(result, minValue), maxValue)

proc newTodoController*(client: AsyncTodoClient): TodoController =
  var locals = newFastMap[string]()
  discard locals.put("title", "Todo MVC + SQLite")
  let itemTemplate = getFastItemTemplate(TodoItemTemplate)
  TodoController(
    client: client,
    listSegs: listTemplateSegments(TodoListTemplate),
    itemTemplate: itemTemplate,
    itemPlan: getTodoItemRenderPlan(itemTemplate),
    countTemplate: getFastCountTemplate(TodoCountTemplate),
    indexHtml: bindTemplate(TodoIndexTemplate, locals),
    autoWindowByDefault: parseBoolEnv("TODO_AUTO_WINDOW_DEFAULT", true),
    allowFullFragmentOverride: parseBoolEnv("TODO_ALLOW_FULL_FRAGMENT", false),
    fullFragmentMaxItems: parseBoundedIntEnv(
      "TODO_MAX_FULL_FRAGMENT_ITEMS",
      DefaultFullFragmentMaxItems,
      1,
      MaxFullFragmentMaxItems
    )
  )

proc parseTodoId(req: Request): tuple[ok: bool, value: int, err: string] =
  try:
    result.value = parseInt(req.param("id"))
    if result.value <= 0:
      result.err = "id must be a positive integer"
      return
    result.ok = true
  except ValueError:
    result.err = "invalid todo id"

proc parseBoolText(raw: string): tuple[ok: bool, value: bool] =
  case raw.toLowerAscii()
  of "1", "true", "yes", "on":
    (true, true)
  of "0", "false", "no", "off":
    (true, false)
  else:
    (false, false)

proc parseCompletedField(node: JsonNode): tuple[ok: bool, value: bool] =
  case node.kind
  of JBool:
    (true, node.getBool())
  of JInt:
    (true, node.getInt() != 0)
  of JString:
    parseBoolText(node.getStr())
  else:
    (false, false)

proc parseTitleFromRequest(req: Request): tuple[ok: bool, value: string, err: string] =
  var title = req.locals.getOrDefault("form_title", "").strip()
  if title.len == 0:
    let body = req.jsonBody()
    if body != nil and body.kind == JObject and body.hasKey("title") and body["title"].kind == JString:
      title = body["title"].getStr().strip()
  if title.len == 0:
    return (false, "", "title is required")
  (true, title, "")

proc hasExplicitFullListOverride(
  req: Request,
  modeParam: string = "mode",
  windowParam: string = "window"
): bool {.inline.} =
  let mode = req.queryParam(modeParam, "").strip()
  if mode.cmpIgnoreCase("full") == 0 or mode.cmpIgnoreCase("all") == 0:
    return true
  let windowRaw = req.queryParam(windowParam, "").strip()
  if windowRaw.len == 0:
    return false
  windowRaw.cmpIgnoreCase("false") == 0 or
    windowRaw.cmpIgnoreCase("0") == 0 or
    windowRaw.cmpIgnoreCase("no") == 0 or
    windowRaw.cmpIgnoreCase("off") == 0

proc shouldUseWindowing(req: Request, autoWindowByDefault: bool): bool {.inline.} =
  req.hasWindowSemantics() or
    (autoWindowByDefault and not req.hasExplicitFullListOverride())

proc renderError(controller: TodoController, res: Response, message: string, statusCode = 500): Future[void] {.async.} =
  res.status(statusCode).html(renderErrorFragment(TodoErrorTemplate, message))

proc sendFragmentContent(controller: TodoController, res: Response, content: var PageBuffer) =
  let policy = throughputPageBufferSendPolicy()
  discard res.sendPageBuffer(content, "text/html; charset=utf-8", policy)

proc sendEmptyTodoListFragment(controller: TodoController, res: Response) =
  var content = initPageBuffer(TodoFragmentPageSize)
  content.add(controller.listSegs.prefix)
  content.add(TodoEmptyItemTemplate)
  content.add(controller.listSegs.middle)
  content.appendTodoCountFromRemainingFast(controller.countTemplate, 0, true)
  content.add(controller.listSegs.suffix)
  discard res.status(200)
  controller.sendFragmentContent(res, content)

proc renderTodoListFragmentOffThread(dbPath: string, maxItems: int): string {.gcsafe, stackTrace: off.} =
  let client = offloadReadClientFor(dbPath)
  let segs = listTemplateSegments(TodoListTemplate)
  let itemTemplate = getFastItemTemplate(TodoItemTemplate)
  let itemPlan = getTodoItemRenderPlan(itemTemplate)
  let countTemplate = getFastCountTemplate(TodoCountTemplate)

  var content = newStringOfCap(max(TodoListTemplate.len + 8192, 256 * 1024))
  content.add(segs.prefix)
  var rowCount = 0
  var overLimit = false

  let remaining = streamTodosFragmentBlocking(
    client,
    proc(id: int, titlePtr: pointer, titleLen: int, completed: bool): bool =
      if rowCount >= maxItems:
        overLimit = true
        return false
      content.appendTodoItemPlannedFast(itemPlan, itemTemplate, id, titlePtr, titleLen, completed)
      inc rowCount
      true
  )
  if overLimit:
    raise newException(ValueError, FullFragmentLimitMessage & " (" & $maxItems & " items)")

  if rowCount == 0:
    content.add(TodoEmptyItemTemplate)
  content.add(segs.middle)
  content.appendTodoCountFromRemainingFast(countTemplate, remaining, true)
  content.add(segs.suffix)
  result = move(content)

proc renderTodoCountFragmentOffThread(dbPath: string, oob: bool): string {.gcsafe, stackTrace: off.} =
  let client = offloadReadClientFor(dbPath)
  let remaining = countRemainingBlocking(client)
  renderTodoCountFromRemaining(TodoCountTemplate, remaining, oob)

proc countTodosOffThread(dbPath: string): int {.gcsafe, stackTrace: off.} =
  countTodosBlocking(offloadReadClientFor(dbPath))

proc renderTodoListFragmentWindowOffThread(
  dbPath: string,
  offset: int,
  limit: int
): TodoWindowFragmentResult {.gcsafe, stackTrace: off.} =
  let client = offloadReadClientFor(dbPath)
  let segs = listTemplateSegments(TodoListTemplate)
  let itemTemplate = getFastItemTemplate(TodoItemTemplate)
  let itemPlan = getTodoItemRenderPlan(itemTemplate)
  let countTemplate = getFastCountTemplate(TodoCountTemplate)

  var content = newStringOfCap(max(TodoListTemplate.len + limit * 256, 64 * 1024))
  content.add(segs.prefix)
  let rowCount = streamTodosFragmentWindowBlocking(
    client,
    offset,
    limit,
    proc(id: int, titlePtr: pointer, titleLen: int, completed: bool): bool =
      content.appendTodoItemPlannedFast(itemPlan, itemTemplate, id, titlePtr, titleLen, completed)
      true
  )
  if rowCount > 0:
    let remaining = countRemainingBlocking(client)
    content.add(segs.middle)
    content.appendTodoCountFromRemainingFast(countTemplate, remaining, true)
    content.add(segs.suffix)
    return TodoWindowFragmentResult(content: move(content), rowCount: rowCount, remaining: remaining)

  TodoWindowFragmentResult(content: "", rowCount: 0, remaining: 0)

proc respondTodoListFragment(controller: TodoController, res: Response): Future[void] {.async, stackTrace: off.} =
  try:
    let content = await runOffload(renderTodoListFragmentOffThread(controller.client.dbPath, controller.fullFragmentMaxItems))
    res.html(content)
  except CatchableError as err:
    if err.msg.contains(FullFragmentLimitMessage):
      await controller.renderError(res, err.msg, 413)
    else:
      raise

proc respondTodoListFragmentWindow(controller: TodoController, req: Request, res: Response): Future[void] {.async, stackTrace: off.} =
  let explicitWindowRequest = req.hasWindowSemantics()
  let requestedRange = req.resolveWindowRangeHeader(
    unit = ItemsRangeUnit,
    defaultOffset = 0,
    defaultLimit = DefaultFragmentWindowItems,
    minOffset = 0,
    minLimit = 1,
    maxLimit = MaxFragmentWindowItems
  )
  if not requestedRange.ok:
    await controller.renderError(res, requestedRange.error, 400)
    return

  let total = await runOffload(countTodosOffThread(controller.client.dbPath))
  if total == 0 and not explicitWindowRequest:
    controller.sendEmptyTodoListFragment(res)
    return

  let windowDecision = resolveWindowedItemsRange(
    requestedRange.value,
    total,
    maxWindowItems = MaxFragmentWindowItems
  )
  if windowDecision.statusCode == 400:
    await controller.renderError(res, windowDecision.error, 400)
    return
  if windowDecision.statusCode == 416:
    discard res.applyWindowedItemsDecision(windowDecision, ItemsRangeUnit)
    await controller.renderError(res, "requested todo window is out of range", 416)
    return
  discard res.applyWindowedItemsDecision(windowDecision, ItemsRangeUnit)

  let rendered = await runOffload(renderTodoListFragmentWindowOffThread(
    controller.client.dbPath,
    windowDecision.start,
    windowDecision.limit
  ))

  if rendered.rowCount == 0:
    let latestTotal = await runOffload(countTodosOffThread(controller.client.dbPath))
    discard res.status(416).contentRangeUnsatisfied(ItemsRangeUnit, latestTotal)
    await controller.renderError(res, "requested todo window is out of range", 416)
    return

  let actualEnd = windowDecision.start + rendered.rowCount - 1
  discard res.status(206)
    .contentRange(ItemsRangeUnit, windowDecision.start, actualEnd, total)
  res.html(rendered.content)

proc respondTodoCountFragment(controller: TodoController, res: Response): Future[void] {.async.} =
  let content = await runOffload(renderTodoCountFragmentOffThread(controller.client.dbPath, false))
  res.html(content)

proc respondTodoCountOob(controller: TodoController, res: Response): Future[void] {.async.} =
  let content = await runOffload(renderTodoCountFragmentOffThread(controller.client.dbPath, true))
  res.html(content)

proc home*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  res.html(controller.indexHtml)

# -----------------------------
# HTMX routes (HTML fragments)
# -----------------------------
proc listTodosHtmx*(controller: TodoController, req: Request, res: Response): Future[void] {.async, stackTrace: off.} =
  try:
    if req.hasExplicitFullListOverride() and not controller.allowFullFragmentOverride:
      await controller.renderError(res, FullFragmentDisabledMessage, 403)
      return
    let shouldWindow = req.shouldUseWindowing(controller.autoWindowByDefault)
    if shouldWindow:
      await controller.respondTodoListFragmentWindow(req, res)
    else:
      await controller.respondTodoListFragment(res)
  except TodoDbError as e:
    await controller.renderError(res, e.msg)
  except CatchableError as e:
    await controller.renderError(res, e.msg)

proc todoCountHtmx*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  try:
    await controller.respondTodoCountFragment(res)
  except TodoDbError as e:
    await controller.renderError(res, e.msg)

proc createTodoHtmx*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  let parsed = parseTitleFromRequest(req)
  if not parsed.ok:
    await controller.renderError(res, parsed.err, 400)
    return

  try:
    let created = await controller.client.createTodo(parsed.value, false)
    let remaining = await controller.client.countRemaining()
    let itemHtml = renderTodoItem(TodoItemTemplate, created)
    let countOob = renderTodoCountFromRemaining(TodoCountTemplate, remaining, true)
    res.html(itemHtml & countOob)
  except TodoDbError as e:
    await controller.renderError(res, e.msg)

proc toggleTodoHtmx*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  let id = parseTodoId(req)
  if not id.ok:
    await controller.renderError(res, id.err, 400)
    return

  try:
    let current = await controller.client.getTodo(id.value)
    if current.isNone:
      await controller.renderError(res, "todo not found", 404)
      return

    let updated = await controller.client.updateTodo(id.value, none(string), some(not current.get().completed))
    if updated.isNone:
      await controller.renderError(res, "todo not found", 404)
      return
    let remaining = await controller.client.countRemaining()
    let itemHtml = renderTodoItem(TodoItemTemplate, updated.get())
    let countOob = renderTodoCountFromRemaining(TodoCountTemplate, remaining, true)
    res.html(itemHtml & countOob)
  except TodoDbError as e:
    await controller.renderError(res, e.msg)

proc deleteTodoHtmx*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  let id = parseTodoId(req)
  if not id.ok:
    await controller.renderError(res, id.err, 400)
    return

  try:
    let removed = await controller.client.deleteTodo(id.value)
    if not removed:
      await controller.renderError(res, "todo not found", 404)
      return
    await controller.respondTodoCountOob(res)
  except TodoDbError as e:
    await controller.renderError(res, e.msg)

# -----------------------------
# JSON API routes
# -----------------------------
proc listTodosApi*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  try:
    let completedFilter = req.queryParam("completed", "")
    var onlyCompleted = none(bool)
    if completedFilter.len > 0:
      let parsed = parseBoolText(completedFilter)
      if not parsed.ok:
        res.status(400).json(todoErrorJson("invalid completed filter; expected true/false"))
        return
      onlyCompleted = some(parsed.value)

    let todos = await controller.client.listTodos(onlyCompleted)
    res.json(todosJson(todos))
  except TodoDbError as e:
    res.status(500).json(todoErrorJson(e.msg))

proc getTodoApi*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  let id = parseTodoId(req)
  if not id.ok:
    res.status(400).json(todoErrorJson(id.err))
    return

  try:
    let maybeTodo = await controller.client.getTodo(id.value)
    if maybeTodo.isNone:
      res.status(404).json(todoErrorJson("todo not found"))
      return
    res.json(todoJson(maybeTodo.get()))
  except TodoDbError as e:
    res.status(500).json(todoErrorJson(e.msg))

proc createTodoApi*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  let body = req.jsonBody()
  if body == nil or body.kind != JObject:
    res.status(400).json(todoErrorJson("expected JSON object body"))
    return

  if not body.hasKey("title") or body["title"].kind != JString:
    res.status(400).json(todoErrorJson("title (string) is required"))
    return

  let title = body["title"].getStr().strip()
  if title.len == 0:
    res.status(400).json(todoErrorJson("title cannot be empty"))
    return

  var completed = false
  if body.hasKey("completed"):
    let parsed = parseCompletedField(body["completed"])
    if not parsed.ok:
      res.status(400).json(todoErrorJson("completed must be bool-like"))
      return
    completed = parsed.value

  try:
    let todo = await controller.client.createTodo(title, completed)
    res.status(201).json(todoJson(todo))
  except TodoDbError as e:
    res.status(500).json(todoErrorJson(e.msg))

proc updateTodoApi*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  let id = parseTodoId(req)
  if not id.ok:
    res.status(400).json(todoErrorJson(id.err))
    return

  let body = req.jsonBody()
  if body == nil or body.kind != JObject:
    res.status(400).json(todoErrorJson("expected JSON object body"))
    return

  var title = none(string)
  var completed = none(bool)

  if body.hasKey("title"):
    if body["title"].kind != JString:
      res.status(400).json(todoErrorJson("title must be a string"))
      return
    let nextTitle = body["title"].getStr().strip()
    if nextTitle.len == 0:
      res.status(400).json(todoErrorJson("title cannot be empty"))
      return
    title = some(nextTitle)

  if body.hasKey("completed"):
    let parsed = parseCompletedField(body["completed"])
    if not parsed.ok:
      res.status(400).json(todoErrorJson("completed must be bool-like"))
      return
    completed = some(parsed.value)

  if title.isNone and completed.isNone:
    res.status(400).json(todoErrorJson("provide at least one field: title or completed"))
    return

  try:
    let maybeTodo = await controller.client.updateTodo(id.value, title, completed)
    if maybeTodo.isNone:
      res.status(404).json(todoErrorJson("todo not found"))
      return
    res.json(todoJson(maybeTodo.get()))
  except TodoDbError as e:
    res.status(500).json(todoErrorJson(e.msg))

proc deleteTodoApi*(controller: TodoController, req: Request, res: Response): Future[void] {.async.} =
  let id = parseTodoId(req)
  if not id.ok:
    res.status(400).json(todoErrorJson(id.err))
    return

  try:
    if not await controller.client.deleteTodo(id.value):
      res.status(404).json(todoErrorJson("todo not found"))
      return
    res.json(todoMessageJson("todo deleted"))
  except TodoDbError as e:
    res.status(500).json(todoErrorJson(e.msg))
