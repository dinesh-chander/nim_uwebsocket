import common

type
  ## States of a `CircuitBreaker`.
  CircuitState* = enum
    csClosed
    csOpen
    csHalfOpen

  ## Configuration for `newCircuitBreaker`. Invalid values are clamped to
  ## defaults; treat as read-only after the breaker is created.
  CircuitBreakerOptions* = object
    failureThreshold*: int
    successThreshold*: int
    timeoutMs*: int
    name*: string

  ## Three-state circuit breaker (closed -> open -> half-open). Gate requests
  ## with `isAllowed`; report outcomes with `recordSuccess`/`recordFailure`.
  ## Trips on *consecutive* failures (a success in `csClosed` resets the
  ## counter).
  ##
  ## WARNING: Not thread-safe. Do not share a single instance across threads
  ## (e.g. in `runThreaded`); give each thread its own breaker. The
  ## single-threaded async path is safe because no preemption occurs between
  ## state transitions.
  CircuitBreaker* = ref object
    state: CircuitState
    failures: int
    successes: int
    halfOpenInflight: int
    lastFailureTime: int64
    options*: CircuitBreakerOptions

## Read-only view of the current circuit state of ``cb``.
proc state*(cb: CircuitBreaker): CircuitState {.inline.} =
  ## Read-only view of the current state. Change it only via
  ## `recordSuccess`/`recordFailure`/`reset`.
  cb.state

## Create a breaker in closed state; invalid option values are clamped to defaults.
proc newCircuitBreaker*(options: CircuitBreakerOptions): CircuitBreaker =
  ## Creates a breaker in `csClosed`. Invalid option values are clamped to
  ## defaults (failureThreshold 5, successThreshold 2, timeoutMs 30000).
  new(result)
  result.state = csClosed
  result.failures = 0
  result.successes = 0
  result.halfOpenInflight = 0
  result.lastFailureTime = 0'i64
  result.options = options
  if result.options.failureThreshold < 1:
    result.options.failureThreshold = 5
  if result.options.successThreshold < 1:
    result.options.successThreshold = 2
  if result.options.timeoutMs < 100:
    result.options.timeoutMs = 30000

## Named-argument convenience wrapper around the options-based constructor.
proc newCircuitBreaker*(
  name: string = "default",
  failureThreshold: int = 5,
  successThreshold: int = 2,
  timeoutMs: int = 30000
): CircuitBreaker =
  ## Named-argument convenience wrapper around the options-based constructor.
  newCircuitBreaker(CircuitBreakerOptions(
    failureThreshold: failureThreshold,
    successThreshold: successThreshold,
    timeoutMs: timeoutMs,
    name: name
  ))

## Whether a request may proceed; an open circuit allows probes only after the timeout elapses.
proc isAllowed*(cb: CircuitBreaker): bool {.inline.} =
  ## Returns true if the request should be allowed. `csClosed`: always.
  ## `csHalfOpen`: up to `successThreshold` concurrent probes. `csOpen`: only
  ## after `timeoutMs` has elapsed (transitions to half-open on first probe).
  case cb.state
  of csClosed:
    return true
  of csHalfOpen:
    if cb.halfOpenInflight < cb.options.successThreshold:
      inc cb.halfOpenInflight
      return true
    return false
  of csOpen:
    let nowMs = getCachedEpochMs()
    if nowMs - cb.lastFailureTime >= cb.options.timeoutMs.int64:
      cb.state = csHalfOpen
      cb.successes = 0
      cb.halfOpenInflight = 1
      return true
    return false

## Report a successful request, closing the circuit after enough half-open successes.
proc recordSuccess*(cb: CircuitBreaker) {.inline.} =
  ## Reports a successful request. In `csHalfOpen`, `successThreshold`
  ## successes close the circuit; in `csClosed`, the failure counter resets.
  case cb.state
  of csHalfOpen:
    inc cb.successes
    if cb.successes >= cb.options.successThreshold:
      cb.state = csClosed
      cb.failures = 0
      cb.successes = 0
      cb.halfOpenInflight = 0
  of csClosed:
    # A success resets the counter, so only *consecutive* failures trip the
    # breaker. A sliding-window model would instead accumulate across
    # intervening successes.
    if cb.failures > 0:
      cb.failures = 0
  of csOpen:
    discard

## Report a failed request, opening the circuit once consecutive failures reach the threshold.
proc recordFailure*(cb: CircuitBreaker) {.inline.} =
  ## Reports a failed request. In `csClosed`, `failureThreshold` consecutive
  ## failures open the circuit; in `csHalfOpen`, a single failure re-opens it.
  case cb.state
  of csClosed:
    cb.lastFailureTime = getCachedEpochMs()
    if cb.failures < high(int):
      inc cb.failures
    if cb.failures >= cb.options.failureThreshold:
      cb.state = csOpen
      cb.successes = 0
      cb.failures = 0
  of csHalfOpen:
    cb.lastFailureTime = getCachedEpochMs()
    cb.state = csOpen
    cb.successes = 0
    cb.failures = 0
    cb.halfOpenInflight = 0
  of csOpen:
    discard

## Restore the breaker to a fresh closed state and clear all counters.
proc reset*(cb: CircuitBreaker) {.inline.} =
  ## Restores the breaker to a fresh `csClosed` state.
  cb.state = csClosed
  cb.failures = 0
  cb.successes = 0
  cb.halfOpenInflight = 0
  cb.lastFailureTime = 0'i64

## Generic 503 body for a request rejected by an open circuit. Intentionally
## omits the circuit name so internal labels are not leaked to clients.
const circuitBreakerRejectBody* = """{"error":"Service unavailable","state":"open"}"""

## Middleware that gates requests through the breaker; rejected requests receive a 503 with Retry-After.
proc circuitBreakerMiddleware*(cb: CircuitBreaker): AsyncMiddleware =
  ## Gate requests through `cb`; requests rejected by an open circuit receive
  ## 503 + `Retry-After`. The 503 body is intentionally generic (no circuit
  ## name) so internal infrastructure labels are not leaked to clients.
  ##
  ## WARNING: Not thread-safe — do not share `cb` across threads.
  let retryAfterStr = $max(1, (cb.options.timeoutMs + 999) div 1000)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if not cb.isAllowed():
      if not res.finished:
        res.set("Retry-After", retryAfterStr)
        res.status(503)
        res.jsonRaw(circuitBreakerRejectBody)
      return

    try:
      await next()
      if res.statusCode >= 500:
        cb.recordFailure()
      else:
        cb.recordSuccess()
    except CatchableError:
      cb.recordFailure()
      raise
