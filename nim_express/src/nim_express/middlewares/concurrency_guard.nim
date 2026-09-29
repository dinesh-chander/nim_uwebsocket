## Concurrency guard middleware.
## Caps concurrent in-flight requests and rejects excess load early.
##
## The cap is PER WORKER: under runCluster/runThreaded each process/thread owns
## its own ConcurrencyGuardState, so the effective global cap is
## workers * maxInflight. Divide maxInflight by the worker count for a global cap.
##
## state is immutable-after-construction: maxInflight must not change after the
## middleware is built (it is read on the hot path without atomics). Passing
## state = nil allocates a fresh state on EVERY factory call, so call the factory
## once at app setup and register that single instance (registering the same
## state in two instances double-counts each request and halves the effective cap).

import std/[asyncdispatch, atomics]
import common

type
  ConcurrencyGuardState* = ref object
    maxInflight*: int
    inflight: Atomic[int64]
    rejected: Atomic[int64]

## Allocate a concurrency guard state with a maximum in-flight request cap.
proc newConcurrencyGuardState*(maxInflight: int = 1024): ConcurrencyGuardState =
  new(result)
  result.maxInflight = max(1, maxInflight)
  result.inflight.store(0'i64, moRelaxed)
  result.rejected.store(0'i64, moRelaxed)

## Read the current number of in-flight requests tracked by a guard state.
proc currentInflight*(state: ConcurrencyGuardState): int64 {.inline.} =
  if state == nil:
    return 0'i64
  state.inflight.load(moRelaxed)

## Read how many requests a guard state has rejected so far.
proc rejectedCount*(state: ConcurrencyGuardState): int64 {.inline.} =
  if state == nil:
    return 0'i64
  state.rejected.load(moRelaxed)

## Reset the in-flight and rejected counters while no request is in flight.
proc resetConcurrencyGuardState*(state: ConcurrencyGuardState) {.inline.} =
  ## Safe at any time: it is a no-op while any request is in flight (the CAS
  ## only succeeds while the counter is exactly 0, so a concurrent admission
  ## cannot be clobbered), and an in-flight completion cannot drive the
  ## counter negative after a reset.
  if state == nil:
    return
  var expected = 0'i64
  if state.inflight.compareExchange(expected, 0'i64, moAcquireRelease, moRelaxed):
    state.rejected.store(0'i64, moRelaxed)

## Sanitize a configured rejection status code, falling back to 503.
proc concurrencyGuardRejectStatus*(statusCode: int): int {.inline.} =
  ## Only body-bearing 4xx/5xx codes are meaningful for a busy signal.
  if statusCode in 400..599:
    statusCode
  else:
    503

## Clamp a configured Retry-After value to a non-negative number of seconds.
proc concurrencyGuardRetryAfter*(retryAfterSeconds: int): int {.inline.} =
  max(0, retryAfterSeconds)

## Build middleware that rejects requests once the shared in-flight cap is exceeded.
proc concurrencyGuard*(
  state: ConcurrencyGuardState,
  statusCode: int = 503,
  retryAfterSeconds: int = 1,
  message: string = "Server busy",
  contentType: string = "text/plain; charset=utf-8"
): AsyncMiddleware =
  ## An empty `contentType` does not omit the Content-Type header: `res.send`
  ## falls back to the framework default (text/plain; charset=utf-8), so ""
  ## cannot mean "no Content-Type".
  ##
  ## Counter ops use moAcquireRelease (stronger than the moRelaxed the limit
  ## logic requires) deliberately, for consistency with tryAcquireAsyncSlot in
  ## app.nim.
  let guard = if state == nil: newConcurrencyGuardState() else: state
  let rejectStatus = concurrencyGuardRejectStatus(statusCode)
  let retryAfter = concurrencyGuardRetryAfter(retryAfterSeconds)
  let retryAfterStr = $retryAfter
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let now = guard.inflight.fetchAdd(1'i64, moAcquireRelease) + 1'i64
    if now > guard.maxInflight.int64:
      discard guard.inflight.fetchSub(1'i64, moAcquireRelease)
      discard guard.rejected.fetchAdd(1'i64, moAcquireRelease)
      if not res.finished:
        res.set("Retry-After", retryAfterStr)
        if contentType.len > 0:
          res.set("Content-Type", contentType)
        res.status(rejectStatus)
        res.send(message)
      return

    try:
      await next()
    finally:
      discard guard.inflight.fetchSub(1'i64, moAcquireRelease)

## Build concurrency guard middleware backed by a freshly allocated state.
proc concurrencyGuard*(
  maxInflight: int = 1024,
  statusCode: int = 503,
  retryAfterSeconds: int = 1,
  message: string = "Server busy",
  contentType: string = "text/plain; charset=utf-8"
): AsyncMiddleware =
  let guard = newConcurrencyGuardState(maxInflight)
  concurrencyGuard(
    state = guard,
    statusCode = statusCode,
    retryAfterSeconds = retryAfterSeconds,
    message = message,
    contentType = contentType
  )
