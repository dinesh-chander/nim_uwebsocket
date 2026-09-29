import std/[asyncdispatch, os, strutils, unittest]

import ../src/nim_express/[types, request, response]
import ../../examples/todo_sqlite_mvc/[todo_controller, todo_model]

proc newReq(rawQuery: string): Request =
  var native: HttpRequest
  new(native)
  native.methodKind = hmGet
  native.path = "/todos/fragment"
  native.queryStringRaw = rawQuery
  newRequest(native)

proc newRes(): Response =
  var native: HttpResponse
  new(native)
  native.requestMethod = hmGet
  native.connectionClose = false
  newResponse(native)

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

suite "Todo SQLite example production bounds":
  test "explicit full fragment is disabled by default":
    let oldAllow = getEnv("TODO_ALLOW_FULL_FRAGMENT", "")
    delEnv("TODO_ALLOW_FULL_FRAGMENT")
    let dbPath = getTempDir() / ("todo_sqlite_disabled_" & $getCurrentProcessId() & ".db")
    removeIfExists(dbPath)
    removeIfExists(dbPath & "-wal")
    removeIfExists(dbPath & "-shm")
    let client = initAsyncTodoClient(dbPath)
    defer:
      client.close()
      removeIfExists(dbPath)
      removeIfExists(dbPath & "-wal")
      removeIfExists(dbPath & "-shm")
      if oldAllow.len > 0:
        putEnv("TODO_ALLOW_FULL_FRAGMENT", oldAllow)
      else:
        delEnv("TODO_ALLOW_FULL_FRAGMENT")

    let controller = newTodoController(client)
    let req = newReq("mode=full")
    let res = newRes()
    waitFor controller.listTodosHtmx(req, res)

    check res.statusCode == 403
    check res.native.capturedBody.contains(FullFragmentDisabledMessage)

  test "explicit full fragment is rejected above configured item cap when enabled":
    let oldAllow = getEnv("TODO_ALLOW_FULL_FRAGMENT", "")
    let oldCap = getEnv("TODO_MAX_FULL_FRAGMENT_ITEMS", "")
    putEnv("TODO_ALLOW_FULL_FRAGMENT", "1")
    putEnv("TODO_MAX_FULL_FRAGMENT_ITEMS", "2")
    let dbPath = getTempDir() / ("todo_sqlite_limit_" & $getCurrentProcessId() & ".db")
    removeIfExists(dbPath)
    removeIfExists(dbPath & "-wal")
    removeIfExists(dbPath & "-shm")
    let client = initAsyncTodoClient(dbPath)
    defer:
      client.close()
      removeIfExists(dbPath)
      removeIfExists(dbPath & "-wal")
      removeIfExists(dbPath & "-shm")
      if oldAllow.len > 0:
        putEnv("TODO_ALLOW_FULL_FRAGMENT", oldAllow)
      else:
        delEnv("TODO_ALLOW_FULL_FRAGMENT")
      if oldCap.len > 0:
        putEnv("TODO_MAX_FULL_FRAGMENT_ITEMS", oldCap)
      else:
        delEnv("TODO_MAX_FULL_FRAGMENT_ITEMS")

    discard waitFor client.createTodo("one", false)
    discard waitFor client.createTodo("two", false)
    discard waitFor client.createTodo("three", false)

    let controller = newTodoController(client)
    let req = newReq("mode=full")
    let res = newRes()
    waitFor controller.listTodosHtmx(req, res)

    check res.statusCode == 413
    check res.native.capturedBody.contains(FullFragmentLimitMessage)
