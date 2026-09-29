## Timeout middleware
## Wraps the downstream handler in a deadline. If the handler does not
## complete within the budget, a 504 Gateway Timeout is sent.
##
## Cancellation is best-effort: Nim's cooperative futures cannot be
## force-cancelled, so on timeout the handler and any sub-futures it spawned
## keep running to completion in the background. Handler authors should use
## short-lived or internally cancellable sub-futures, or poll
## `requestTimeoutRemainingMs` to bail out early.

import std/[asyncdispatch, times]
import common

type
  TimeoutPreset* = enum
    tpApiStrict
    tpApiDefault
    tpLongPoll

## Middleware that answers with 504 Gateway Timeout if the handler does not complete within `ms` milliseconds.
proc timeout*(ms: int = 30000): AsyncMiddleware {.inline.}

## Returns a `timeout` middleware preconfigured for the named `preset`.
proc timeoutPreset*(preset: TimeoutPreset): AsyncMiddleware {.inline.} =
  case preset
  of tpApiStrict:
    timeout(5000)
  of tpApiDefault:
    timeout(15000)
  of tpLongPoll:
    timeout(60000)

## Enforces a deadline: if `next` has not completed within `ms` milliseconds, a 504 Gateway Timeout is sent to the client.
proc timeout*(ms: int = 30000): AsyncMiddleware {.inline.} =
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let timeoutMs = max(1, ms)
    let now = epochTime()
    let deadline = now + (timeoutMs.float / 1000.0)
    req.setRequestTimeoutBudget(timeoutMs)
    req.locals["_deadline"] = $deadline
    req.locals["_timeout_started_ms"] = $(int64(now * 1000.0))
    req.locals["_timeout_budget_ms"] = $timeoutMs

    let nextFuture = next()
    let completed = await nextFuture.withTimeout(timeoutMs)

    if completed:
      # Handler finished in time. If it raised, re-raise.
      if nextFuture.failed:
        raise nextFuture.readError()
      return

    # Timeout path.
    if not res.finished:
      res.status(504).send("Gateway Timeout")
    if not nextFuture.finished:
      when compiles(cancel(nextFuture)):
        try:
          cancel(nextFuture)
        except CatchableError:
          discard
    let notified = req.notifyRequestTimeout()
    when not defined(release):
      if not notified:
        req.locals["_timeout_hook_skipped"] = "1"
    req.clearRequestTimeoutBudget()
    req.locals["_timed_out"] = "1"
