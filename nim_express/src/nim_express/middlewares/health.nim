## Health middleware

import std/[asyncdispatch, times, atomics]
import common

# Written once at module initialization, before any threads exist;
# read-only thereafter, so no synchronization is required.
var serverStartTime = epochTime()
# Per-process counter of non-health request arrivals (see `health`).
var requestCounter: Atomic[int64]

## Returns the current per-process count of non-health request arrivals.
proc healthRequestCount*(): int64 {.inline.} =
  requestCounter.load(moRelaxed)

## Resets the per-process non-health request counter to zero.
proc resetHealthRequestCount*() {.inline.} =
  requestCounter.store(0'i64, moRelaxed)

## Serves a JSON health-check response on `path` and keeps a process-wide
## counter of non-health request arrivals.
##
## By default the payload is minimal (`{"status":"healthy"}`) so that
## untrusted clients cannot fingerprint the deployment via uptime or request
## counts; pass `verbose = true` to expose `uptime`, `nonHealthRequests`
## and `timestamp` to trusted/internal callers.
##
## Counter semantics (the `nonHealthRequests` field, reported when verbose):
## - Counts *arrivals* of requests whose path does not match `path`; the
##   increment happens before `next()` runs, so aborted/rejected requests
##   are still counted. Requests to the health path itself are excluded.
## - Per-process: in multi-process deployments (`runCluster`), each worker
##   process maintains its own counter, so the reported value reflects only
##   that worker's traffic, not the cluster aggregate.
proc health*(path: string = "/health", verbose: bool = false): AsyncMiddleware =
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if req.path == path:
      res.set("Cache-Control", "no-cache, no-store")
      if verbose:
        # Single wall-clock read: uptime and timestamp derive from the same
        # value, and the fixed-shape payload is emitted via jsonRaw to avoid
        # a JsonNode allocation.
        let currentRequests = requestCounter.load(moRelaxed)
        let now = epochTime()
        var builder = initJsonBuilder(160)
        builder.add("""{"status":"healthy","uptime":""")
        builder.addFloat(now - serverStartTime)
        builder.add(""","nonHealthRequests":""")
        builder.add($currentRequests)
        builder.add(",\"timestamp\":")
        builder.addEscaped($initTime(int64(now), 0).utc)
        builder.add("}")
        res.jsonRaw(builder.finish())
      else:
        res.jsonRaw("""{"status":"healthy"}""")
    else:
      discard requestCounter.fetchAdd(1'i64, moRelaxed)
      await next()
