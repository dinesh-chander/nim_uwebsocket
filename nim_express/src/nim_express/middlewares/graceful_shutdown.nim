## Graceful shutdown middleware.
## Handles SIGTERM/SIGINT, drains in-flight requests, and runs cleanup hooks.
##
## Signal delivery is async-signal-safe: the handler only sets a volatile flag.
## On POSIX a dedicated drain thread (10ms flag poll, off the async event loop)
## performs shutdown initiation + drain checks, so the event loop never polls
## and signal-to-shutdown latency is bounded by 10ms. A self-pipe was avoided
## because re-declaring C `write`/`read` conflicts with unistd.h signatures.
## Shutdown hooks run exactly once when the drain completes, either on the
## drain thread or on the thread whose last in-flight request finished
## (whichever observes the completion first), and always before any forced
## exit.
##
## Concurrency model (important): the drain thread only touches state objects
## through a lock-free registry of raw pointers. Objects stay alive because
## registration pins them with `GC_ref` and the main thread releases the pin
## (after drain + hooks finished and after a drain-thread quiescence point) in
## `cleanupFinishedDrainStates`, which the middleware runs at creation. The
## drain thread never creates threads, never frees GC memory, and never
## allocates in its steady-state loop (all log output uses literal strings).
##
## Note: installing the SIGINT/SIGTERM handlers REPLACES any handlers the
## application previously registered for those signals (they are not chained,
## because a signal handler must stay `gcsafe`/`raises: []` and cannot invoke an
## arbitrary prior handler). Pass `installSignalHandlers = false` to opt out.

import std/[asyncdispatch, monotimes, atomics, os, streams]
when defined(posix):
  import std/[posix, volatile]
import common
from logger import sanitizeLogField

const DrainCheckIntervalMs = 100
const DrainPollIntervalMs = 10

type
  ## Shutdown hooks run off the request path when the drain completes, so
  ## they must be GC-safe. They may run while in-flight requests remain if the
  ## drain times out.
  ShutdownHook* = proc() {.closure, gcsafe.}

  GracefulShutdownOptions* = object
    drainTimeoutMs*: int
    healthPath*: string
    shutdownHooks*: seq[ShutdownHook]
    forceExitOnTimeout*: bool

  GracefulShutdownState* = ref object
    shuttingDown: Atomic[int64]
    inflight: Atomic[int64]
    shutdownStartedMs: Atomic[int64]
    drainTimeoutMs: int
    healthPath: string
    shutdownHooks: seq[ShutdownHook]
    forceExitOnTimeout: bool
    drainComplete: Atomic[int64]
    signalObserved: bool
    drainLoopStarted: Atomic[int64]
    hooksCompleted: Atomic[int64]
    forceExitRequested: Atomic[int64]

when defined(posix):
  const MaxDrainStates = 64

  var
    gracefulShutdownSignalPending {.global.}: Sig_atomic
    drainThread: Thread[void]
    drainThreadStarted: Atomic[int64]
    # Registry of raw pointers: invisible to the GC so the {.thread.} drain
    # thread may read it without touching GC'ed global memory. Liveness of the
    # pointed-to objects is guaranteed by the GC_ref pin taken in
    # registerDrainState and released (main thread only) by
    # cleanupFinishedDrainStates.
    drainStateOwned: array[0..MaxDrainStates - 1, Atomic[int64]]
    drainStateSlots: array[0..MaxDrainStates - 1, ptr GracefulShutdownState]
    # High-water mark of the highest filled slot + 1. Monotonic: slots are
    # reclaimed but the mark never shrinks, so the snapshot loop is a cheap
    # range scan.
    drainStateCount: Atomic[int64]
    # Set while the drain thread is inside a pass over the registry.
    # cleanupFinishedDrainStates waits for this to clear before unpinning, so
    # the drain thread never dereferences a freed object.
    drainPassActive: Atomic[int64]
    signalHandlersInstalled: Atomic[int64]

  proc markGracefulShutdownSignalPending() {.noconv, gcsafe, raises: [].} =
    volatileStore(addr gracefulShutdownSignalPending, Sig_atomic(1))

  proc markGracefulShutdownTermPending(sig: cint) {.noconv, gcsafe, raises: [].} =
    discard sig
    markGracefulShutdownSignalPending()

  proc installGracefulShutdownSignal(sig: cint) =
    var action: Sigaction
    action.sa_handler = markGracefulShutdownTermPending
    discard sigemptyset(action.sa_mask)
    action.sa_flags = SA_RESTART
    if sigaction(sig, action) != 0:
      stderr.writeLine("[graceful_shutdown] WARNING: sigaction failed for signal ", $sig,
        " (graceful shutdown will not trigger on this signal)")

  proc gracefulShutdownSignalRequested(): bool {.inline.} =
    volatileLoad(addr gracefulShutdownSignalPending) != Sig_atomic(0)

  ## Test hook: clear the pending shutdown signal flag.
  proc resetGracefulShutdownSignalForTest*() =
    volatileStore(addr gracefulShutdownSignalPending, Sig_atomic(0))
else:
  var gracefulShutdownSignalPending: Atomic[int64]

  proc markGracefulShutdownSignalPending() {.noconv, gcsafe, raises: [].} =
    gracefulShutdownSignalPending.store(1'i64, moRelaxed)

  proc gracefulShutdownSignalRequested(): bool {.inline.} =
    gracefulShutdownSignalPending.load(moRelaxed) != 0'i64

  ## Test hook: clear the pending shutdown signal flag.
  proc resetGracefulShutdownSignalForTest*() =
    gracefulShutdownSignalPending.store(0'i64, moRelaxed)

## Test hook: mark the pending shutdown signal flag.
proc markGracefulShutdownSignalForTest*() =
  markGracefulShutdownSignalPending()

## Return graceful shutdown options with safe defaults.
proc defaultGracefulShutdownOptions*(): GracefulShutdownOptions {.inline.} =
  GracefulShutdownOptions(
    drainTimeoutMs: 30000,
    healthPath: "/health",
    shutdownHooks: @[],
    forceExitOnTimeout: false
  )

## Create a `GracefulShutdownState` from `options`.
proc newGracefulShutdownState*(options: GracefulShutdownOptions = defaultGracefulShutdownOptions()): GracefulShutdownState =
  new(result)
  result.shuttingDown.store(0'i64, moRelaxed)
  result.inflight.store(0'i64, moRelaxed)
  result.shutdownStartedMs.store(0'i64, moRelaxed)
  result.drainTimeoutMs = max(1000, options.drainTimeoutMs)
  result.healthPath = if options.healthPath.len > 0: options.healthPath else: "/health"
  result.shutdownHooks = options.shutdownHooks
  result.forceExitOnTimeout = options.forceExitOnTimeout
  result.drainComplete.store(0'i64, moRelaxed)
  result.signalObserved = false
  result.drainLoopStarted.store(0'i64, moRelaxed)
  result.hooksCompleted.store(0'i64, moRelaxed)
  result.forceExitRequested.store(0'i64, moRelaxed)

## Return true when `state` is in its shutdown phase.
proc isShuttingDown*(state: GracefulShutdownState): bool {.inline.} =
  if state == nil:
    return false
  state.shuttingDown.load(moRelaxed) != 0'i64

## Return the current number of in-flight requests tracked by `state`.
proc inflightCount*(state: GracefulShutdownState): int64 {.inline.} =
  if state == nil: 0'i64
  else: state.inflight.load(moRelaxed)

## Return true when all in-flight requests of `state` have drained.
proc isDrainComplete*(state: GracefulShutdownState): bool {.inline.} =
  if state == nil:
    return false
  state.drainComplete.load(moRelaxed) != 0'i64

## Return true when all shutdown hooks of `state` have finished.
proc hooksCompleted*(state: GracefulShutdownState): bool {.inline.} =
  if state == nil:
    return false
  state.hooksCompleted.load(moRelaxed) != 0'i64

## Run all shutdown hooks of `state` in order, logging any that raise.
proc runShutdownHooks*(state: GracefulShutdownState) =
  for hook in state.shutdownHooks:
    if hook != nil:
      try:
        hook()
      except CatchableError:
        # No string formatting here: this may run on the drain thread and the
        # message is only for diagnostics.
        write(stderr, "[graceful_shutdown] error in shutdown hook\n")

## Complete the drain of `state` exactly once: record completion, run all
## hooks, mark hooks completed, and force-exit when requested. Runs on
## whichever thread observes drain completion first (drain thread or the
## thread of the last finishing request).
proc finishDrainAndRunHooks(state: GracefulShutdownState, forceExit: bool) =
  if state == nil:
    return
  if forceExit:
    state.forceExitRequested.store(1'i64, moRelease)
  else:
    state.forceExitRequested.store(0'i64, moRelaxed)
  state.runShutdownHooks()
  state.hooksCompleted.store(1'i64, moRelease)
  if state.forceExitRequested.load(moAcquire) != 0'i64:
    write(stderr,
      "[graceful_shutdown] Drain timed out; hooks finished, terminating with exit code 1.\n")
    quit(1)

## Start the shutdown of `state` exactly once and record the start time.
proc initiateShutdown*(state: GracefulShutdownState) =
  if state == nil:
    return
  let prev = state.shuttingDown.exchange(1'i64, moAcquireRelease)
  if prev != 0'i64:
    return
  state.shutdownStartedMs.store(getMonoTime().ticks div 1_000_000, moRelaxed)
  # Literal-only write: this runs on the drain thread and must not allocate.
  write(stderr,
    "[graceful_shutdown] Shutdown initiated, draining in-flight requests...\n")

proc pollSignalShutdown(state: GracefulShutdownState) =
  if state == nil or state.signalObserved:
    return
  if gracefulShutdownSignalRequested():
    state.signalObserved = true
    state.initiateShutdown()

proc checkDrainStatus(state: GracefulShutdownState) =
  if state == nil or not state.isShuttingDown():
    return
  if state.drainComplete.load(moRelaxed) != 0'i64:
    return

  let inflight = state.inflight.load(moRelaxed)
  if inflight <= 0'i64:
    if state.drainComplete.exchange(1'i64, moAcquireRelease) == 0'i64:
      write(stderr,
        "[graceful_shutdown] All in-flight requests drained.\n")
      state.finishDrainAndRunHooks(false)
    return

  let startedMs = state.shutdownStartedMs.load(moRelaxed)
  let elapsedMs = getMonoTime().ticks div 1_000_000 - startedMs
  if elapsedMs >= state.drainTimeoutMs.int64:
    if state.drainComplete.exchange(1'i64, moAcquireRelease) == 0'i64:
      write(stderr,
        "[graceful_shutdown] Drain timeout reached with in-flight requests remaining.\n")
      state.finishDrainAndRunHooks(state.forceExitOnTimeout)

when defined(posix):
  proc drainSnapshot(dst: var array[0..MaxDrainStates - 1, ptr GracefulShutdownState]): int =
    let count = int(min(drainStateCount.load(moAcquire), int64(MaxDrainStates)))
    var n = 0
    for i in 0 ..< count:
      let s = drainStateSlots[i]
      if s != nil:
        dst[n] = s
        inc n
    result = n

  proc processAllDrainStates() =
    drainPassActive.store(1'i64, moRelease)
    var snap: array[0..MaxDrainStates - 1, ptr GracefulShutdownState]
    try:
      while true:
        let n = drainSnapshot(snap)
        for i in 0 ..< n:
          let s = cast[GracefulShutdownState](snap[i])
          s.pollSignalShutdown()
        var allDone = true
        for i in 0 ..< n:
          let s = cast[GracefulShutdownState](snap[i])
          if s.isShuttingDown() and not s.isDrainComplete():
            s.checkDrainStatus()
            if not s.isDrainComplete():
              allDone = false
        if allDone or n == 0:
          break
        os.sleep(DrainCheckIntervalMs)
    finally:
      drainPassActive.store(0'i64, moRelease)

  proc drainThreadMain() {.thread.} =
    while true:
      # A pending shutdown signal is never cleared, so the thread must sleep
      # between passes unconditionally or it would busy-spin at 100% CPU.
      if gracefulShutdownSignalRequested():
        processAllDrainStates()
      os.sleep(DrainPollIntervalMs)

  ## Pin `state` in the registry so the drain thread may safely touch it.
  ## Called on the main thread (middleware creation).
  proc registerDrainState(state: GracefulShutdownState) =
    for i in 0 ..< MaxDrainStates:
      if drainStateOwned[i].exchange(1'i64, moAcquireRelease) == 0'i64:
        GC_ref(state)
        drainStateSlots[i] = cast[ptr GracefulShutdownState](state)
        let target = int64(i) + 1
        var c = drainStateCount.load(moRelaxed)
        while c < target:
          let desired = max(c, target)
          let old = drainStateCount.exchange(desired, moAcquireRelease)
          if old >= desired:
            break
          c = max(c, old)
        return
    stderr.writeLine("[graceful_shutdown] WARNING: drain state registry full; a state will not be tracked for signal shutdown")

  ## Release registry slots of states whose shutdown fully finished (drain
  ## complete AND hooks completed). Must run on the main thread: `GC_unref`
  ## of these (potentially cyclic) objects must not happen on the drain
  ## thread. Called from middleware creation, so long-lived apps and
  ## churning test suites stay within the registry limit.
  proc cleanupFinishedDrainStates() =
    for i in 0 ..< MaxDrainStates:
      if drainStateOwned[i].load(moAcquire) == 1'i64:
        let s = cast[GracefulShutdownState](drainStateSlots[i])
        if s != nil and s.isDrainComplete() and s.hooksCompleted():
          if drainStateOwned[i].exchange(0'i64, moAcquireRelease) == 1'i64:
            drainStateSlots[i] = nil # future snapshots cannot see it
            # The drain thread may still hold a snapshot from an in-flight
            # pass; wait for a quiescence point before dropping the pin.
            let deadline = getMonoTime().ticks + 2_000_000_000
            while drainPassActive.load(moAcquire) != 0'i64:
              if getMonoTime().ticks > deadline:
                break # pin stays for process lifetime (bounded leak, no crash)
              os.sleep(5)
            if drainPassActive.load(moAcquire) == 0'i64:
              GC_unref(s)

when not defined(posix):
  proc drainCheckLoop(state: GracefulShutdownState) {.async.} =
    while true:
      try:
        await sleepAsync(DrainCheckIntervalMs)
      except CatchableError:
        break
      state.pollSignalShutdown()
      if not state.isShuttingDown():
        continue
      try:
        checkDrainStatus(state)
      except CatchableError as e:
        stderr.writeLine("[graceful_shutdown] error in drain check: ", sanitizeLogField(e.msg))
      if state.isDrainComplete():
        break

## Middleware that tracks in-flight requests and drains them on shutdown.
proc gracefulShutdown*(
  state: GracefulShutdownState,
  installSignalHandlers: bool = true
): AsyncMiddleware =
  let gsState = if state == nil: newGracefulShutdownState() else: state

  when defined(posix):
    cleanupFinishedDrainStates()
    if drainThreadStarted.exchange(1'i64, moAcquireRelease) == 0'i64:
      createThread(drainThread, drainThreadMain)
    registerDrainState(gsState)
    if installSignalHandlers and signalHandlersInstalled.exchange(1'i64, moAcquireRelease) == 0'i64:
      installGracefulShutdownSignal(SIGINT)
      installGracefulShutdownSignal(SIGTERM)
  else:
    if gsState.drainLoopStarted.exchange(1'i64, moAcquireRelease) == 0'i64:
      asyncCheck drainCheckLoop(gsState)
    if installSignalHandlers:
      setControlCHook(markGracefulShutdownSignalPending)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    discard gsState.inflight.fetchAdd(1'i64, moAcquireRelease)
    if gsState.isShuttingDown():
      discard gsState.inflight.fetchSub(1'i64, moAcquireRelease)
      if gsState.isShuttingDown():
        checkDrainStatus(gsState)
      if req.path == gsState.healthPath:
        if not res.finished:
          res.set("Connection", "close")
          res.status(503)
          res.json(%*{"status": "shutting_down"})
        return

      if not res.finished:
        res.set("Connection", "close")
        res.status(503)
        res.json(%*{"error": "Service Unavailable", "reason": "shutting_down"})
      return

    try:
      await next()
    finally:
      discard gsState.inflight.fetchSub(1'i64, moAcquireRelease)
      if gsState.isShuttingDown():
        checkDrainStatus(gsState)

## Create the shutdown middleware from `options` with a fresh state.
proc gracefulShutdown*(
  options: GracefulShutdownOptions = defaultGracefulShutdownOptions()
): AsyncMiddleware =
  let state = newGracefulShutdownState(options)
  gracefulShutdown(state, installSignalHandlers = true)
