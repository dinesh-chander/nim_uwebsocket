## Backpressure / load shedding middleware.
## Returns 503 when the server is under pressure based on configurable thresholds.

import std/[asyncdispatch, times, atomics, envVars]
import common

type
  LoadMetricsHook* = proc(): tuple[shouldShed: bool, retryAfterSeconds: int] {.closure.}

  BackpressureOptions* = object
    maxConnections*: int
    maxPendingResponses*: int
    maxResponseTimeMs*: int
    retryAfterSeconds*: int
    loadMetricsHook*: LoadMetricsHook

  BackpressureState* = ref object
    activeConnections: Atomic[int64]
    # Tracks the same value as `activeConnections` (incremented/decremented
    # together on the same request lifecycle); kept as a separate atomic so the
    # connection cap and pending cap can be tuned independently.
    pendingResponses: Atomic[int64]
    totalRequests: Atomic[int64]
    shedRequests: Atomic[int64]
    # Approximate last-writer-wins gauge of the most recent completed request's
    # duration. Deliberately unsmoothed: cheap to update, but noisy under
    # concurrency (a fast request can overwrite a slow one).
    lastResponseDurationMs: Atomic[int64]

## Sensible production defaults for backpressure thresholds.
proc defaultBackpressureOptions*(): BackpressureOptions {.inline.} =
  BackpressureOptions(
    maxConnections: 10000,
    maxPendingResponses: 5000,
    maxResponseTimeMs: 30000,
    retryAfterSeconds: 5,
    loadMetricsHook: nil
  )

## Create an empty backpressure state with all counters zero.
proc newBackpressureState*(): BackpressureState =
  new(result)
  result.activeConnections.store(0'i64, moRelaxed)
  result.pendingResponses.store(0'i64, moRelaxed)
  result.totalRequests.store(0'i64, moRelaxed)
  result.shedRequests.store(0'i64, moRelaxed)
  result.lastResponseDurationMs.store(0'i64, moRelaxed)

## Current number of in-flight connections tracked by the state.
proc activeConnectionCount*(state: BackpressureState): int64 {.inline, noSideEffect.} =
  if state == nil: 0'i64
  else: state.activeConnections.load(moRelaxed)

## Current number of responses pending completion in the state.
proc pendingResponseCount*(state: BackpressureState): int64 {.inline, noSideEffect.} =
  if state == nil: 0'i64
  else: state.pendingResponses.load(moRelaxed)

## Total number of requests shed since the state was created.
proc shedRequestCount*(state: BackpressureState): int64 {.inline, noSideEffect.} =
  if state == nil: 0'i64
  else: state.shedRequests.load(moRelaxed)

## Reset all backpressure counters back to zero.
proc resetBackpressureState*(state: BackpressureState) {.inline.} =
  if state == nil:
    return
  state.activeConnections.store(0'i64, moRelaxed)
  state.pendingResponses.store(0'i64, moRelaxed)
  state.totalRequests.store(0'i64, moRelaxed)
  state.shedRequests.store(0'i64, moRelaxed)
  state.lastResponseDurationMs.store(0'i64, moRelaxed)

const shedBody = """{"error":"Service Unavailable"}"""

## Backpressure middleware that sheds requests with 503 under pressure.
proc backpressure*(
  state: BackpressureState,
  options: BackpressureOptions = defaultBackpressureOptions()
): AsyncMiddleware =
  let bpState = if state == nil: newBackpressureState() else: state
  let opts = options
  let retryAfter = max(1, opts.retryAfterSeconds)
  let retryAfterStr = $retryAfter
  let debugShed = getEnv("NIM_EXPRESS_ENV") == "development"

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    var hookShed = false
    var hookRetryAfter = 0
    if opts.loadMetricsHook != nil:
      try:
        let metrics = opts.loadMetricsHook()
        hookShed = metrics.shouldShed
        hookRetryAfter = metrics.retryAfterSeconds
      except CatchableError as e:
        var safeMsg = newStringOfCap(e.msg.len)
        for c in e.msg:
          if ord(c) < 0x20 or ord(c) == 0x7f: safeMsg.add('?')
          else: safeMsg.add(c)
        stderr.writeLine("[backpressure] loadMetricsHook error: ", safeMsg)
    if hookShed:
      discard bpState.shedRequests.fetchAdd(1'i64, moRelaxed)
      res.set("Retry-After", if hookRetryAfter > 0: $hookRetryAfter else: retryAfterStr)
      res.status(503)
      res.jsonRaw(shedBody)
      return

    let connections = bpState.activeConnections.fetchAdd(1'i64, moAcquireRelease) + 1'i64
    let pending = bpState.pendingResponses.fetchAdd(1'i64, moAcquireRelease) + 1'i64
    discard bpState.totalRequests.fetchAdd(1'i64, moRelaxed)

    var shed = false
    var shedReason = ""
    if opts.maxConnections > 0 and connections > opts.maxConnections.int64:
      shed = true
      shedReason = "maxConnections"
    elif opts.maxPendingResponses > 0 and pending > opts.maxPendingResponses.int64:
      shed = true
      shedReason = "maxPendingResponses"
    elif opts.maxResponseTimeMs > 0:
      let lastDuration = bpState.lastResponseDurationMs.load(moRelaxed)
      if lastDuration > opts.maxResponseTimeMs.int64:
        shed = true
        shedReason = "maxResponseTimeMs"

    if shed:
      if debugShed:
        stderr.writeLine("[backpressure] shed: ", shedReason,
                         " connections=", $connections, " pending=", $pending)
      discard bpState.activeConnections.fetchSub(1'i64, moAcquireRelease)
      discard bpState.pendingResponses.fetchSub(1'i64, moAcquireRelease)
      discard bpState.shedRequests.fetchAdd(1'i64, moRelaxed)
      res.set("Retry-After", retryAfterStr)
      res.status(503)
      res.jsonRaw(shedBody)
      return

    var startMs: int64
    try:
      startMs = int64(epochTime() * 1000.0)
      await next()
    finally:
      let durationMs = max(0'i64, int64(epochTime() * 1000.0) - startMs)
      bpState.lastResponseDurationMs.store(durationMs, moRelaxed)
      discard bpState.activeConnections.fetchSub(1'i64, moAcquireRelease)
      discard bpState.pendingResponses.fetchSub(1'i64, moAcquireRelease)

## Backpressure middleware with a freshly created state.
proc backpressure*(
  options: BackpressureOptions = defaultBackpressureOptions()
): AsyncMiddleware =
  let state = newBackpressureState()
  backpressure(state, options)

## Backpressure middleware from plain threshold values.
proc backpressure*(
  maxConnections: int,
  maxPendingResponses: int = 5000,
  maxResponseTimeMs: int = 30000,
  retryAfterSeconds: int = 5
): AsyncMiddleware =
  backpressure(BackpressureOptions(
    maxConnections: maxConnections,
    maxPendingResponses: maxPendingResponses,
    maxResponseTimeMs: maxResponseTimeMs,
    retryAfterSeconds: retryAfterSeconds,
    loadMetricsHook: nil
  ))
