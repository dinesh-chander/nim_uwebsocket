## SQLite-backed Todo model layer (M in MVC)
## Exposes an async client API over SQLite operations.

import std/[options, asyncdispatch]

when defined(macosx) or defined(linux):
  {.passL: "-lsqlite3".}

const
  SQLITE_OK = 0
  SQLITE_ROW = 100
  SQLITE_DONE = 101
  SQLITE_TRANSIENT = cast[pointer](-1)

type
  Sqlite3 {.importc: "sqlite3", header: "<sqlite3.h>", incompleteStruct.} = object
  Sqlite3Stmt {.importc: "sqlite3_stmt", header: "<sqlite3.h>", incompleteStruct.} = object
  DbHandle = ptr Sqlite3
  StmtHandle = ptr Sqlite3Stmt

  TodoDbError* = object of CatchableError

  Todo* = object
    id*: int
    title*: string
    completed*: bool
    createdAt*: string

  TodoRepo = ref object
    db: DbHandle

  AsyncTodoClient* = ref object
    dbPath*: string
    repo: TodoRepo
    stmtListAll: StmtHandle
    stmtListFragment: StmtHandle
    stmtListFragmentWindow: StmtHandle
    stmtListCompleted: StmtHandle
    stmtCountTodos: StmtHandle
    stmtCountRemaining: StmtHandle
    stmtGetById: StmtHandle
    stmtInsert: StmtHandle
    stmtUpdate: StmtHandle
    stmtDelete: StmtHandle

  TodoFragmentRowHandler* = proc(
    id: int,
    titlePtr: pointer,
    titleLen: int,
    completed: bool
  ): bool {.closure, gcsafe.}

when defined(singleThread):
  var offloadReadClient: AsyncTodoClient
  var offloadReadClientPath: string
else:
  var offloadReadClient {.threadvar.}: AsyncTodoClient
  var offloadReadClientPath {.threadvar.}: string

proc close*(client: AsyncTodoClient) {.gcsafe.}

proc sqlite3_open(filename: cstring, ppDb: ptr DbHandle): cint
  {.cdecl, importc: "sqlite3_open", header: "<sqlite3.h>".}
proc sqlite3_close(db: DbHandle): cint
  {.cdecl, importc: "sqlite3_close", header: "<sqlite3.h>".}
proc sqlite3_errmsg(db: DbHandle): cstring
  {.cdecl, importc: "sqlite3_errmsg", header: "<sqlite3.h>".}
proc sqlite3_exec(
  db: DbHandle,
  sql: cstring,
  callback: pointer,
  arg: pointer,
  errmsg: ptr cstring
): cint {.cdecl, importc: "sqlite3_exec", header: "<sqlite3.h>".}
proc sqlite3_free(p: pointer)
  {.cdecl, importc: "sqlite3_free", header: "<sqlite3.h>".}
proc sqlite3_prepare_v2(
  db: DbHandle,
  zSql: cstring,
  nByte: cint,
  ppStmt: ptr StmtHandle,
  pzTail: pointer
): cint {.cdecl, importc: "sqlite3_prepare_v2", header: "<sqlite3.h>".}
proc sqlite3_finalize(stmt: StmtHandle): cint
  {.cdecl, importc: "sqlite3_finalize", header: "<sqlite3.h>".}
proc sqlite3_step(stmt: StmtHandle): cint
  {.cdecl, importc: "sqlite3_step", header: "<sqlite3.h>".}
proc sqlite3_bind_int(stmt: StmtHandle, idx: cint, value: cint): cint
  {.cdecl, importc: "sqlite3_bind_int", header: "<sqlite3.h>".}
proc sqlite3_bind_text(
  stmt: StmtHandle,
  idx: cint,
  value: cstring,
  n: cint,
  destructor: pointer
): cint {.cdecl, importc: "sqlite3_bind_text", header: "<sqlite3.h>".}
proc sqlite3_column_int(stmt: StmtHandle, col: cint): cint
  {.cdecl, importc: "sqlite3_column_int", header: "<sqlite3.h>".}
proc sqlite3_column_text(stmt: StmtHandle, col: cint): cstring
  {.cdecl, importc: "sqlite3_column_text", header: "<sqlite3.h>".}
proc sqlite3_column_bytes(stmt: StmtHandle, col: cint): cint
  {.cdecl, importc: "sqlite3_column_bytes", header: "<sqlite3.h>".}
proc sqlite3_last_insert_rowid(db: DbHandle): int64
  {.cdecl, importc: "sqlite3_last_insert_rowid", header: "<sqlite3.h>".}
proc sqlite3_reset(stmt: StmtHandle): cint
  {.cdecl, importc: "sqlite3_reset", header: "<sqlite3.h>".}
proc sqlite3_clear_bindings(stmt: StmtHandle): cint
  {.cdecl, importc: "sqlite3_clear_bindings", header: "<sqlite3.h>".}
proc sqlite3_bind_null(stmt: StmtHandle, idx: cint): cint
  {.cdecl, importc: "sqlite3_bind_null", header: "<sqlite3.h>".}
proc sqlite3_busy_timeout(db: DbHandle, ms: cint): cint
  {.cdecl, importc: "sqlite3_busy_timeout", header: "<sqlite3.h>".}

proc boolToInt(value: bool): cint {.inline.} =
  if value: 1 else: 0

proc colText(stmt: StmtHandle, col: cint): string =
  let ptrValue = sqlite3_column_text(stmt, col)
  if ptrValue == nil:
    return ""
  $ptrValue

proc raiseDb(db: DbHandle, context: string) =
  let msg =
    if db == nil: "sqlite error"
    else: $sqlite3_errmsg(db)
  raise newException(TodoDbError, context & ": " & msg)

proc checkOk(code: cint, db: DbHandle, context: string) =
  if code != SQLITE_OK:
    raiseDb(db, context)

proc execSql(repo: TodoRepo, statement: string) =
  var errMsg: cstring = nil
  let rc = sqlite3_exec(repo.db, statement.cstring, nil, nil, addr errMsg)
  if rc != SQLITE_OK:
    let msg = if errMsg != nil: $errMsg else: "sqlite exec failed"
    if errMsg != nil:
      sqlite3_free(cast[pointer](errMsg))
    raise newException(TodoDbError, msg)

proc prepare(repo: TodoRepo, query: string): StmtHandle =
  var stmt: StmtHandle = nil
  let rc = sqlite3_prepare_v2(repo.db, query.cstring, -1, addr stmt, nil)
  checkOk(rc, repo.db, "failed to prepare statement")
  result = stmt

proc resetStmt(stmt: StmtHandle, db: DbHandle, context: string) =
  if stmt == nil:
    raise newException(TodoDbError, context & ": statement not initialized")
  let rc = sqlite3_reset(stmt)
  if rc notin {SQLITE_OK, SQLITE_DONE, SQLITE_ROW}:
    raiseDb(db, context)
  checkOk(sqlite3_clear_bindings(stmt), db, context)

proc finalizeStmt(stmt: var StmtHandle) =
  if stmt != nil:
    discard sqlite3_finalize(stmt)
    stmt = nil

proc todoFromStmt(stmt: StmtHandle): Todo =
  Todo(
    id: sqlite3_column_int(stmt, 0).int,
    title: colText(stmt, 1),
    completed: sqlite3_column_int(stmt, 2) != 0,
    createdAt: colText(stmt, 3)
  )

proc initTodoRepo(dbPath: string): TodoRepo =
  new(result)
  var db: DbHandle = nil
  let rc = sqlite3_open(dbPath.cstring, addr db)
  if rc != SQLITE_OK:
    raise newException(TodoDbError, "failed to open sqlite database at " & dbPath)
  result.db = db

proc close(repo: TodoRepo) =
  if repo != nil and repo.db != nil:
    discard sqlite3_close(repo.db)
    repo.db = nil

proc ensureSchema(repo: TodoRepo) =
  repo.execSql("PRAGMA journal_mode=WAL;")
  repo.execSql("PRAGMA synchronous=NORMAL;")
  # SQLite tuning for read-heavy local workloads.
  repo.execSql("PRAGMA temp_store=MEMORY;")
  repo.execSql("PRAGMA cache_size=-64000;")
  repo.execSql("PRAGMA mmap_size=268435456;")
  repo.execSql("PRAGMA journal_size_limit=67108864;")
  repo.execSql("PRAGMA wal_autocheckpoint=1000;")
  repo.execSql("PRAGMA optimize;")
  repo.execSql("""
    CREATE TABLE IF NOT EXISTS todos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      completed INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  """)
  repo.execSql("CREATE INDEX IF NOT EXISTS idx_todos_completed ON todos(completed);")

proc listTodosBlocking(client: AsyncTodoClient, onlyCompleted: Option[bool]): seq[Todo] =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")

  let stmt =
    if onlyCompleted.isSome: client.stmtListCompleted
    else: client.stmtListAll
  resetStmt(stmt, client.repo.db, "failed to reset list todos statement")
  defer:
    discard sqlite3_reset(stmt)

  if onlyCompleted.isSome:
    checkOk(sqlite3_bind_int(stmt, 1, boolToInt(onlyCompleted.get())), client.repo.db, "failed to bind completed filter")

  while true:
    let stepRc = sqlite3_step(stmt)
    if stepRc == SQLITE_ROW:
      result.add(todoFromStmt(stmt))
    elif stepRc == SQLITE_DONE:
      break
    else:
      raiseDb(client.repo.db, "failed to read todo rows")

proc listTodosFragmentBlocking(client: AsyncTodoClient): seq[Todo] =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")

  let stmt = client.stmtListFragment
  resetStmt(stmt, client.repo.db, "failed to reset list fragment statement")
  defer:
    discard sqlite3_reset(stmt)

  while true:
    let stepRc = sqlite3_step(stmt)
    if stepRc == SQLITE_ROW:
      result.add(Todo(
        id: sqlite3_column_int(stmt, 0).int,
        title: colText(stmt, 1),
        completed: sqlite3_column_int(stmt, 2) != 0,
        createdAt: ""
      ))
    elif stepRc == SQLITE_DONE:
      break
    else:
      raiseDb(client.repo.db, "failed to read todo fragment rows")

proc countRemainingBlocking*(client: AsyncTodoClient): int =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")

  let stmt = client.stmtCountRemaining
  resetStmt(stmt, client.repo.db, "failed to reset remaining count statement")
  defer:
    discard sqlite3_reset(stmt)

  let stepRc = sqlite3_step(stmt)
  if stepRc == SQLITE_ROW:
    return sqlite3_column_int(stmt, 0).int
  if stepRc == SQLITE_DONE:
    return 0
  raiseDb(client.repo.db, "failed to read remaining count")

proc countTodosBlocking*(client: AsyncTodoClient): int =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")

  let stmt = client.stmtCountTodos
  resetStmt(stmt, client.repo.db, "failed to reset todo count statement")
  defer:
    discard sqlite3_reset(stmt)

  let stepRc = sqlite3_step(stmt)
  if stepRc == SQLITE_ROW:
    return sqlite3_column_int(stmt, 0).int
  if stepRc == SQLITE_DONE:
    return 0
  raiseDb(client.repo.db, "failed to read total todo count")

proc streamTodosFragmentBlocking*(client: AsyncTodoClient, onRow: TodoFragmentRowHandler): int {.stackTrace: off.} =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")

  let stmt = client.stmtListFragment
  resetStmt(stmt, client.repo.db, "failed to reset stream fragment statement")
  defer:
    discard sqlite3_reset(stmt)

  while true:
    let stepRc = sqlite3_step(stmt)
    if stepRc == SQLITE_ROW:
      let id = sqlite3_column_int(stmt, 0).int
      let titleText = sqlite3_column_text(stmt, 1)
      let titleLen = sqlite3_column_bytes(stmt, 1).int
      let titlePtr =
        if titleText == nil or titleLen <= 0:
          nil
        else:
          cast[pointer](titleText)
      let completed = sqlite3_column_int(stmt, 2) != 0
      if not completed:
        inc result
      if onRow != nil and not onRow(id, titlePtr, titleLen, completed):
        break
    elif stepRc == SQLITE_DONE:
      break
    else:
      raiseDb(client.repo.db, "failed to stream todo fragment rows")

proc streamTodosFragmentWindowBlocking*(
  client: AsyncTodoClient,
  offset: int,
  limit: int,
  onRow: TodoFragmentRowHandler
): int {.stackTrace: off.} =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")
  if offset < 0 or limit <= 0:
    return 0

  let stmt = client.stmtListFragmentWindow
  resetStmt(stmt, client.repo.db, "failed to reset windowed stream fragment statement")
  defer:
    discard sqlite3_reset(stmt)

  checkOk(sqlite3_bind_int(stmt, 1, limit.cint), client.repo.db, "failed to bind window limit")
  checkOk(sqlite3_bind_int(stmt, 2, offset.cint), client.repo.db, "failed to bind window offset")

  while true:
    let stepRc = sqlite3_step(stmt)
    if stepRc == SQLITE_ROW:
      let id = sqlite3_column_int(stmt, 0).int
      let titleText = sqlite3_column_text(stmt, 1)
      let titleLen = sqlite3_column_bytes(stmt, 1).int
      let titlePtr =
        if titleText == nil or titleLen <= 0:
          nil
        else:
          cast[pointer](titleText)
      let completed = sqlite3_column_int(stmt, 2) != 0
      inc result
      if onRow != nil and not onRow(id, titlePtr, titleLen, completed):
        break
    elif stepRc == SQLITE_DONE:
      break
    else:
      raiseDb(client.repo.db, "failed to stream windowed todo fragment rows")

proc getTodoBlocking(client: AsyncTodoClient, id: int): Option[Todo] =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")

  let stmt = client.stmtGetById
  resetStmt(stmt, client.repo.db, "failed to reset get todo statement")
  defer:
    discard sqlite3_reset(stmt)

  checkOk(sqlite3_bind_int(stmt, 1, id.cint), client.repo.db, "failed to bind todo id")

  let stepRc = sqlite3_step(stmt)
  if stepRc == SQLITE_ROW:
    return some(todoFromStmt(stmt))
  if stepRc == SQLITE_DONE:
    return none(Todo)
  raiseDb(client.repo.db, "failed to read todo row")

proc createTodoBlocking(client: AsyncTodoClient, title: string, completed: bool): Todo =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")

  let stmt = client.stmtInsert
  resetStmt(stmt, client.repo.db, "failed to reset insert todo statement")
  defer:
    discard sqlite3_reset(stmt)

  checkOk(sqlite3_bind_text(stmt, 1, title.cstring, -1, SQLITE_TRANSIENT), client.repo.db, "failed to bind title")
  checkOk(sqlite3_bind_int(stmt, 2, boolToInt(completed)), client.repo.db, "failed to bind completed")

  let stepRc = sqlite3_step(stmt)
  if stepRc == SQLITE_ROW:
    return todoFromStmt(stmt)
  if stepRc != SQLITE_DONE:
    raiseDb(client.repo.db, "failed to insert todo")

  # Fallback for SQLite builds without RETURNING support.
  let newId = sqlite3_last_insert_rowid(client.repo.db).int
  let maybeTodo = getTodoBlocking(client, newId)
  if maybeTodo.isNone:
    raise newException(TodoDbError, "failed to load created todo")
  maybeTodo.get()

proc updateTodoBlocking(
  client: AsyncTodoClient,
  id: int,
  title: Option[string],
  completed: Option[bool]
): Option[Todo] =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")

  let stmt = client.stmtUpdate
  resetStmt(stmt, client.repo.db, "failed to reset update todo statement")
  defer:
    discard sqlite3_reset(stmt)

  if title.isSome:
    checkOk(sqlite3_bind_text(stmt, 1, title.get().cstring, -1, SQLITE_TRANSIENT), client.repo.db, "failed to bind updated title")
  else:
    checkOk(sqlite3_bind_null(stmt, 1), client.repo.db, "failed to bind null title")

  if completed.isSome:
    checkOk(sqlite3_bind_int(stmt, 2, boolToInt(completed.get())), client.repo.db, "failed to bind updated completed")
  else:
    checkOk(sqlite3_bind_null(stmt, 2), client.repo.db, "failed to bind null completed")

  checkOk(sqlite3_bind_int(stmt, 3, id.cint), client.repo.db, "failed to bind updated id")

  let stepRc = sqlite3_step(stmt)
  if stepRc == SQLITE_ROW:
    return some(todoFromStmt(stmt))
  if stepRc == SQLITE_DONE:
    return none(Todo)
  raiseDb(client.repo.db, "failed to update todo")

proc deleteTodoBlocking(client: AsyncTodoClient, id: int): bool =
  if client == nil or client.repo == nil:
    raise newException(TodoDbError, "database client is closed")

  let stmt = client.stmtDelete
  resetStmt(stmt, client.repo.db, "failed to reset delete todo statement")
  defer:
    discard sqlite3_reset(stmt)

  checkOk(sqlite3_bind_int(stmt, 1, id.cint), client.repo.db, "failed to bind delete id")
  let stepRc = sqlite3_step(stmt)
  if stepRc == SQLITE_ROW:
    return true
  if stepRc == SQLITE_DONE:
    return false
  raiseDb(client.repo.db, "failed to delete todo")

proc initAsyncTodoClient*(dbPath: string): AsyncTodoClient {.gcsafe.} =
  let repo = initTodoRepo(dbPath)
  ensureSchema(repo)

  new(result)
  result.dbPath = dbPath
  result.repo = repo

  checkOk(sqlite3_busy_timeout(repo.db, 2000), repo.db, "failed to set busy timeout")

  result.stmtListAll = repo.prepare("SELECT id, title, completed, created_at FROM todos ORDER BY id DESC")
  result.stmtListFragment = repo.prepare("SELECT id, title, completed FROM todos ORDER BY id DESC")
  result.stmtListFragmentWindow = repo.prepare("SELECT id, title, completed FROM todos ORDER BY id DESC LIMIT ? OFFSET ?")
  result.stmtListCompleted = repo.prepare("SELECT id, title, completed, created_at FROM todos WHERE completed = ? ORDER BY id DESC")
  result.stmtCountTodos = repo.prepare("SELECT COUNT(*) FROM todos")
  result.stmtCountRemaining = repo.prepare("SELECT COUNT(*) FROM todos WHERE completed = 0")
  result.stmtGetById = repo.prepare("SELECT id, title, completed, created_at FROM todos WHERE id = ?")
  result.stmtInsert = repo.prepare("INSERT INTO todos(title, completed) VALUES(?, ?) RETURNING id, title, completed, created_at")
  result.stmtUpdate = repo.prepare("UPDATE todos SET title = COALESCE(?, title), completed = COALESCE(?, completed) WHERE id = ? RETURNING id, title, completed, created_at")
  result.stmtDelete = repo.prepare("DELETE FROM todos WHERE id = ? RETURNING id")

proc offloadReadClientFor*(dbPath: string): AsyncTodoClient {.gcsafe.} =
  if offloadReadClient == nil or offloadReadClientPath != dbPath:
    if offloadReadClient != nil:
      offloadReadClient.close()
    offloadReadClient = initAsyncTodoClient(dbPath)
    offloadReadClientPath = dbPath
  offloadReadClient

proc close*(client: AsyncTodoClient) {.gcsafe.} =
  if client == nil:
    return
  finalizeStmt(client.stmtListAll)
  finalizeStmt(client.stmtListFragment)
  finalizeStmt(client.stmtListFragmentWindow)
  finalizeStmt(client.stmtListCompleted)
  finalizeStmt(client.stmtCountTodos)
  finalizeStmt(client.stmtCountRemaining)
  finalizeStmt(client.stmtGetById)
  finalizeStmt(client.stmtInsert)
  finalizeStmt(client.stmtUpdate)
  finalizeStmt(client.stmtDelete)
  if client.repo != nil:
    client.repo.close()
    client.repo = nil

proc listTodos*(client: AsyncTodoClient, onlyCompleted: Option[bool] = none(bool)): Future[seq[Todo]] {.async.} =
  result = listTodosBlocking(client, onlyCompleted)

proc listTodosFragment*(client: AsyncTodoClient): Future[seq[Todo]] {.async.} =
  result = listTodosFragmentBlocking(client)

proc countRemaining*(client: AsyncTodoClient): Future[int] {.async.} =
  result = countRemainingBlocking(client)

proc countTodos*(client: AsyncTodoClient): Future[int] {.async.} =
  result = countTodosBlocking(client)

proc streamTodosFragment*(client: AsyncTodoClient, onRow: TodoFragmentRowHandler): Future[int] {.async.} =
  result = streamTodosFragmentBlocking(client, onRow)

proc streamTodosFragmentWindow*(
  client: AsyncTodoClient,
  offset: int,
  limit: int,
  onRow: TodoFragmentRowHandler
): Future[int] {.async.} =
  result = streamTodosFragmentWindowBlocking(client, offset, limit, onRow)

proc getTodo*(client: AsyncTodoClient, id: int): Future[Option[Todo]] {.async.} =
  result = getTodoBlocking(client, id)

proc createTodo*(client: AsyncTodoClient, title: string, completed: bool): Future[Todo] {.async.} =
  result = createTodoBlocking(client, title, completed)

proc updateTodo*(
  client: AsyncTodoClient,
  id: int,
  title: Option[string],
  completed: Option[bool]
): Future[Option[Todo]] {.async.} =
  result = updateTodoBlocking(client, id, title, completed)

proc deleteTodo*(client: AsyncTodoClient, id: int): Future[bool] {.async.} =
  result = deleteTodoBlocking(client, id)
