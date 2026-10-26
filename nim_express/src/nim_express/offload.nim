## Thread-pool offload helpers for blocking/CPU-heavy tasks.
## Uses `malebolgia` instead of the deprecated std/threadpool module.

import std/[asyncdispatch, atomics, isolation, macros, locks]
import malebolgia
import types
export isolation

const DefaultOffloadTimeoutMs* = 30_000
const NimExpressOffloadQueueLimit* {.intdefine.} = 15

type
  OffloadCompletionProc = proc(payload: pointer) {.gcsafe.}
  OffloadCompletionEntry = object
    targetServer: pointer
    payload: pointer
    runner: OffloadCompletionProc

  OffloadCompletionNode = object
    next: ptr OffloadCompletionNode
    entry: OffloadCompletionEntry

  OffloadSharedState[T] = object
    refs: Atomic[int]
    done: Atomic[bool]
    failed: Atomic[bool]
    completed: Atomic[bool]
    result: T
    errorMsg: string
    completionFuture: Future[T]
    dispatchServerPtr: pointer

var offloadInFlight: Atomic[int]

proc offloadAdmissionLimit(): int {.inline.} =
  max(1, NimExpressOffloadQueueLimit)

proc acquireOffloadAdmission(): bool {.inline.} =
  let previous = offloadInFlight.fetchAdd(1, moAcquireRelease)
  if previous >= offloadAdmissionLimit():
    discard offloadInFlight.fetchSub(1, moAcquireRelease)
    return false
  true

proc releaseOffloadAdmission() {.inline.} =
  discard offloadInFlight.fetchSub(1, moAcquireRelease)

when defined(nimExpressOffloadTest):
  ## Returns the number of offload tasks currently holding an admission slot.
  proc offloadInFlightForTest*(): int =
    offloadInFlight.load(moAcquire)

  ## Returns the effective admission limit for offload queue slots.
  proc offloadAdmissionLimitForTest*(): int =
    offloadAdmissionLimit()

when compileOption("threads"):
  var offloadDispatchServer {.threadvar.}: HttpServer

  ## Records the server whose event loop runs queued offload completions.
  proc setOffloadDispatchServer*(server: HttpServer) {.inline.} =
    offloadDispatchServer = server

  proc currentOffloadDispatchServer(): HttpServer {.inline.} =
    offloadDispatchServer
else:
  var offloadDispatchServer: HttpServer

  ## Records the server that runs queued offload completions.
  proc setOffloadDispatchServer*(server: HttpServer) {.inline.} =
    offloadDispatchServer = server

  proc currentOffloadDispatchServer(): HttpServer {.inline.} =
    offloadDispatchServer

proc decRefOffloadSharedState[T](state: ptr OffloadSharedState[T]) {.inline.}

proc incRefOffloadSharedState[T](state: ptr OffloadSharedState[T]) {.inline.} =
  if state != nil:
    discard state[].refs.fetchAdd(1, moAcquireRelease)

proc tryCompleteOffloadSharedState[T](state: ptr OffloadSharedState[T]): bool {.gcsafe.} =
  if state == nil:
    return false
  var expected = false
  if not state[].completed.compareExchange(expected, true, moAcquireRelease, moAcquire):
    return false
  let fut = state[].completionFuture
  if fut != nil and not fut.finished:
    if state[].failed.load(moAcquire):
      let errMsg = move(state[].errorMsg)
      fut.fail(newException(ValueError, errMsg))
    else:
      let value = move(state[].result)
      fut.complete(value)
  state[].completionFuture = nil
  true

when compileOption("threads"):
  var offloadCompletionLock: Lock
  var offloadCompletionHead: ptr OffloadCompletionNode
  var offloadCompletionTail: ptr OffloadCompletionNode

  initLock(offloadCompletionLock)
  offloadCompletionHead = nil
  offloadCompletionTail = nil

proc completeOffloadOnLoop[T](payload: pointer) {.gcsafe.} =
  let state = cast[ptr OffloadSharedState[T]](payload)
  if state == nil:
    return
  discard tryCompleteOffloadSharedState(state)
  decRefOffloadSharedState(state)

when compileOption("threads"):
  proc drainQueuedOffloadCompletions() {.gcsafe.} =
    let server = currentOffloadDispatchServer()
    if server == nil:
      return

    let targetServer = cast[pointer](server)
    var readyHead: ptr OffloadCompletionNode = nil
    var readyTail: ptr OffloadCompletionNode = nil
    var remainingHead: ptr OffloadCompletionNode = nil
    var remainingTail: ptr OffloadCompletionNode = nil
    withLock(offloadCompletionLock):
      if offloadCompletionHead == nil:
        return
      var node = offloadCompletionHead
      offloadCompletionHead = nil
      offloadCompletionTail = nil
      while node != nil:
        let nextNode = node.next
        node.next = nil
        if node.entry.targetServer == targetServer:
          if readyTail == nil:
            readyHead = node
          else:
            readyTail.next = node
          readyTail = node
        else:
          if remainingTail == nil:
            remainingHead = node
          else:
            remainingTail.next = node
          remainingTail = node
        node = nextNode
      offloadCompletionHead = remainingHead
      offloadCompletionTail = remainingTail

    var node = readyHead
    while node != nil:
      let nextNode = node.next
      if node.entry.runner != nil:
        try:
          node.entry.runner(node.entry.payload)
        except CatchableError:
          discard
        except Defect:
          discard
      deallocShared(node)
      node = nextNode

  proc removeQueuedOffloadCompletion(
    targetServer: pointer,
    runner: OffloadCompletionProc,
    payload: pointer
  ): bool {.gcsafe.} =
    if targetServer == nil or runner == nil or payload == nil:
      return false
    var removed: ptr OffloadCompletionNode = nil
    withLock(offloadCompletionLock):
      var prev: ptr OffloadCompletionNode = nil
      var node = offloadCompletionHead
      while node != nil:
        let nextNode = node.next
        if node.entry.targetServer == targetServer and
            node.entry.runner == runner and
            node.entry.payload == payload:
          if prev == nil:
            offloadCompletionHead = nextNode
          else:
            prev.next = nextNode
          if offloadCompletionTail == node:
            offloadCompletionTail = prev
          node.next = nil
          removed = node
          break
        prev = node
        node = nextNode
    if removed != nil:
      deallocShared(removed)
      return true
    false

  proc enqueueOffloadCompletion(
    targetServer: pointer,
    runner: OffloadCompletionProc,
    payload: pointer
  ): bool {.gcsafe.} =
    if targetServer == nil or runner == nil or payload == nil:
      return false
    let node = cast[ptr OffloadCompletionNode](allocShared0(sizeof(OffloadCompletionNode)))
    if node == nil:
      return false
    node[].next = nil
    node[].entry.targetServer = targetServer
    node[].entry.payload = payload
    node[].entry.runner = runner
    withLock(offloadCompletionLock):
      if offloadCompletionTail == nil:
        offloadCompletionHead = node
      else:
        offloadCompletionTail.next = node
      offloadCompletionTail = node
    if cast[HttpServer](targetServer).tryQueueDeferredPreFromAnyThread(drainQueuedOffloadCompletions):
      return true
    if removeQueuedOffloadCompletion(targetServer, runner, payload):
      return false
    # A previously scheduled drain raced with the failed admission and already
    # took this node; the completion callback now owns the extra state ref.
    true
else:
  proc removeQueuedOffloadCompletion(
    targetServer: pointer,
    runner: OffloadCompletionProc,
    payload: pointer
  ): bool {.gcsafe.} =
    discard targetServer
    discard runner
    discard payload
    false

  proc enqueueOffloadCompletion(
    targetServer: pointer,
    runner: OffloadCompletionProc,
    payload: pointer
  ): bool {.gcsafe.} =
    discard targetServer
    if runner != nil:
      runner(payload)
      return true
    false

proc allocOffloadSharedState[T](): ptr OffloadSharedState[T] =
  result = cast[ptr OffloadSharedState[T]](allocShared0(sizeof(OffloadSharedState[T])))
  if result == nil:
    raise newException(OutOfMemDefect, "could not allocate offload shared state")
  result[].refs.store(2, moRelaxed)
  result[].done.store(false, moRelaxed)
  result[].failed.store(false, moRelaxed)
  result[].completed.store(false, moRelaxed)

proc decRefOffloadSharedState[T](state: ptr OffloadSharedState[T]) {.inline.} =
  if state == nil:
    return
  if state[].refs.fetchSub(1, moAcquireRelease) == 1:
    `=destroy`(state[])
    deallocShared(state)

## One malebolgia master per thread, created on first use and kept for the
## lifetime of the process. A worker thread still touches the master's lock
## (`taskCompleted`) after the task body has run, so freeing the master as soon
## as the task result is published destroys a mutex that is still in use and
## aborts inside glibc (`pthread_mutex_lock ... __owner == 0`, or the robust
## `e != ESRCH || !robust` variant).
var offloadMasterForThread {.threadvar.}: ptr Master

proc currentOffloadMaster(): ptr Master =
  result = offloadMasterForThread
  if result == nil:
    result = cast[ptr Master](allocShared0(sizeof(Master)))
    if result == nil:
      raise newException(OutOfMemDefect, "could not allocate offload master")
    var master = createMaster(activeProducer = true)
    copyMem(result, addr master, sizeof(Master))
    wasMoved(master)
    offloadMasterForThread = result

when defined(nimExpressOffloadTest):
  ## Returns this thread's reused malebolgia master pointer, or nil when no
  ## offload ran on this thread yet. Regression hook: the pointer must be
  ## stable across `runOffload` calls (per-call free caused glibc aborts).
  proc offloadMasterPtrForTest*(): pointer =
    cast[pointer](offloadMasterForThread)

macro runOffload*(expr: typed): untyped =
  ## Run a blocking call on malebolgia's worker pool and return a Future.
  ## Example: let rows = await runOffload(loadRowsBlocking())
  ##
  ## Note: this expects a call expression, e.g. `foo(a, b)`. The pool master is
  ## created once per thread and reused by every offload on that thread.
  if expr.kind notin nnkCallKinds:
    error("runOffload expects a call expression", expr)

  let retType = expr.getTypeInst
  let fnExpr = expr[0]

  let workerProc = genSym(nskProc, "runOffloadWorker")
  let awaitProc = genSym(nskProc, "runOffloadAwait")
  let masterSym = genSym(nskLet, "offloadMaster")
  let stateSym = genSym(nskLet, "sharedState")
  let completionFutureSym = genSym(nskVar, "completionFuture")
  let dispatchServerSym = genSym(nskLet, "dispatchServer")
  let stateParam = genSym(nskParam, "statePtr")
  let stateTy = nnkPtrTy.newTree(
    nnkBracketExpr.newTree(bindSym"OffloadSharedState", retType)
  )

  var workerFormalParams = nnkFormalParams.newTree(newEmptyNode())
  workerFormalParams.add newIdentDefs(stateParam, stateTy, newEmptyNode())

  var workerCall = newCall(copyNimTree(fnExpr))
  var spawnCall = newCall(workerProc)
  spawnCall.add stateSym

  for i in 1 ..< expr.len:
    let argParam = ident("arg" & $i)
    workerFormalParams.add newIdentDefs(argParam, expr[i].getTypeInst, newEmptyNode())
    workerCall.add argParam
    spawnCall.add expr[i]

  let workerBody = quote do:
    try:
      `stateParam`[].result = `workerCall`
    except CatchableError as e:
      `stateParam`[].errorMsg = e.msg
      `stateParam`[].failed.store(true, moRelease)
    finally:
      if `stateParam`[].dispatchServerPtr != nil:
        incRefOffloadSharedState(`stateParam`)
        if not enqueueOffloadCompletion(
          `stateParam`[].dispatchServerPtr,
          completeOffloadOnLoop[`retType`],
          cast[pointer](`stateParam`)
        ):
          decRefOffloadSharedState(`stateParam`)
      `stateParam`[].done.store(true, moRelease)
      releaseOffloadAdmission()
      decRefOffloadSharedState(`stateParam`)

  let workerDef = nnkProcDef.newTree(
    workerProc,
    newEmptyNode(),
    newEmptyNode(),
    workerFormalParams,
    nnkPragma.newTree(ident"gcsafe"),
    newEmptyNode(),
    workerBody
  )

  let awaitDef = quote do:
    proc `awaitProc`(): Future[`retType`] {.async.} =
      let `masterSym` = currentOffloadMaster()
      let `dispatchServerSym` = currentOffloadDispatchServer()
      var `completionFutureSym`: Future[`retType`] = nil
      if `dispatchServerSym` != nil:
        `completionFutureSym` = newFuture[`retType`]("runOffload")
      let `stateSym` = allocOffloadSharedState[`retType`]()
      `stateSym`[].dispatchServerPtr = cast[pointer](`dispatchServerSym`)
      `stateSym`[].completionFuture = `completionFutureSym`
      defer:
        decRefOffloadSharedState(`stateSym`)

      if not acquireOffloadAdmission():
        `stateSym`[].failed.store(true, moRelease)
        `stateSym`[].errorMsg = "offload queue full"
        `stateSym`[].done.store(true, moRelease)
        decRefOffloadSharedState(`stateSym`)
        if `completionFutureSym` != nil:
          discard tryCompleteOffloadSharedState(`stateSym`)
          return await `completionFutureSym`
        raise newException(ValueError, `stateSym`[].errorMsg)

      var spawned = false
      try:
        `masterSym`[].spawn(`spawnCall`)
        spawned = true
      except CatchableError as e:
        releaseOffloadAdmission()
        `stateSym`[].failed.store(true, moRelease)
        `stateSym`[].errorMsg = e.msg
        `stateSym`[].done.store(true, moRelease)
        decRefOffloadSharedState(`stateSym`)
        if `completionFutureSym` != nil:
          discard tryCompleteOffloadSharedState(`stateSym`)
          return await `completionFutureSym`
        raise
      finally:
        discard spawned

      if `completionFutureSym` != nil:
        while not `completionFutureSym`.finished:
          if `stateSym`[].done.load(moAcquire):
            if removeQueuedOffloadCompletion(
              `stateSym`[].dispatchServerPtr,
              completeOffloadOnLoop[`retType`],
              cast[pointer](`stateSym`)
            ):
              decRefOffloadSharedState(`stateSym`)
            discard tryCompleteOffloadSharedState(`stateSym`)
            break
          await sleepAsync(0)
        return await `completionFutureSym`

      while not `stateSym`[].done.load(moAcquire):
        await sleepAsync(0)

      if `stateSym`[].failed.load(moAcquire):
        let errMsg = move(`stateSym`[].errorMsg)
        raise newException(ValueError, errMsg)

      let value = move(`stateSym`[].result)
      return value

  result = quote do:
    block:
      `workerDef`
      `awaitDef`
      `awaitProc`()

macro runOffloadOutcome*(
  operation: static[string],
  correlationId: typed,
  timeoutMs: typed,
  expr: typed
): untyped =
  ## Run a blocking call on the offload pool and return typed outcomes:
  ## - `ookOk`
  ## - `ookOffloadTimeout`
  ## - `ookOffloadError`
  if expr.kind notin nnkCallKinds:
    error("runOffloadOutcome expects a call expression", expr)

  let retType = expr.getTypeInst
  let awaitProc = genSym(nskProc, "runOffloadOutcomeAwait")
  let runCall = newCall(bindSym"runOffload", expr)

  result = quote do:
    block:
      proc `awaitProc`(): Future[OffloadOutcome[`retType`]] {.async.} =
        var outcome: OffloadOutcome[`retType`]
        outcome.operation = `operation`
        outcome.correlationId = `correlationId`
        try:
          let workFuture = `runCall`
          if `timeoutMs` > 0:
            let timeoutBudgetMs = max(1, `timeoutMs`)
            let startedAtMs = int64(epochTime() * 1000.0)
            while not workFuture.finished:
              let elapsedMs = int(int64(epochTime() * 1000.0) - startedAtMs)
              if elapsedMs >= timeoutBudgetMs:
                outcome.kind = ookOffloadTimeout
                outcome.errorClass = "offload_timeout"
                outcome.errorMessage = "offload operation timed out after " & $timeoutBudgetMs & "ms"
                return outcome
              let remainingMs = timeoutBudgetMs - elapsedMs
              await sleepAsync(max(1, min(10, remainingMs)))
            outcome.kind = ookOk
            outcome.value = workFuture.read()
          else:
            outcome.kind = ookOk
            outcome.value = await workFuture
        except CatchableError as err:
          outcome.kind = ookOffloadError
          outcome.errorClass = "offload_error"
          outcome.errorMessage = err.msg
        return outcome

      `awaitProc`()

## Runs ``expr`` on the offload pool and returns an ``OffloadOutcome`` using ``DefaultOffloadTimeoutMs``.
template runOffloadOutcome*(
  operation: static[string],
  correlationId: typed,
  expr: typed
): untyped =
  runOffloadOutcome(operation, correlationId, DefaultOffloadTimeoutMs, expr)

## Returns the short string class name for an ``OffloadOutcome`` kind.
proc offloadOutcomeClass*[T](outcome: OffloadOutcome[T]): string {.inline.} =
  case outcome.kind
  of ookOk:
    "ok"
  of ookOffloadTimeout:
    "offload_timeout"
  of ookOffloadError:
    "offload_error"

proc appendJsonEscaped(dest: var string, raw: string) =
  for c in raw:
    case c
    of '\"':
      dest.add("\\\"")
    of '\\':
      dest.add("\\\\")
    of '\n':
      dest.add("\\n")
    of '\r':
      dest.add("\\r")
    of '\t':
      dest.add("\\t")
    else:
      if c < ' ':
        dest.add("?")
      else:
        dest.add(c)

## Renders an ``OffloadOutcome`` as a compact JSON event string with class, operation, and correlation fields.
proc formatOffloadOutcomeEvent*[T](outcome: OffloadOutcome[T]): string =
  result = "{"
  result.add("\"class\":\"")
  result.appendJsonEscaped(outcome.offloadOutcomeClass())
  result.add("\",\"operation\":\"")
  result.appendJsonEscaped(outcome.operation)
  result.add("\",\"correlation_id\":\"")
  result.appendJsonEscaped(outcome.correlationId)
  result.add("\"")
  if outcome.errorMessage.len > 0:
    result.add(",\"message\":\"")
    result.appendJsonEscaped(outcome.errorMessage)
    result.add("\"")
  result.add("}")
