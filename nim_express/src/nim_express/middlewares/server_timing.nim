## Server-Timing middleware.
## Records a microsecond start timestamp in req.locals; the actual
## `Server-Timing` header is emitted by response.nim's applyServerTimingHeader
## (called from res.send() / res.jsonRaw()), so responses sent through custom
## paths that bypass those procs will not carry the header.
## Register this middleware before any route handlers so the measured duration
## covers the full chain.

import std/asyncdispatch
import common

type
  ## Options for the serverTiming middleware.
  ## `productionMode: true` (the default) disables timing entirely,
  ## regardless of `enabled`. `enabled: false` also disables it.
  ## Note: storing the start timestamp in req.locals (a string map) costs one
  ## small heap allocation per timed request; that is inherent to the locals
  ## API and accepted as a known trade-off.
  ## Warning: when timing is active, the `Server-Timing: total;dur=<ms>`
  ## header reveals precise internal processing duration to clients; keep it
  ## disabled in production unless the disclosure is intended.
  ServerTimingOptions* = object
    ## Master switch; `false` disables timing regardless of productionMode.
    enabled*: bool
    ## When `true`, timing is disabled regardless of `enabled`.
    productionMode*: bool

## Returns the default `ServerTimingOptions`; timing is disabled for production safety.
proc defaultServerTimingOptions*(): ServerTimingOptions {.inline.} =
  ## Defaults are safe for production: timing is OFF because
  ## `productionMode` is `true`, even though `enabled` is `true`.
  ServerTimingOptions(
    enabled: true,
    productionMode: true
  )

## Returns middleware that records the request start time in `req.locals` for the `Server-Timing` response header.
proc serverTiming*(
  options: ServerTimingOptions = defaultServerTimingOptions()
): AsyncMiddleware {.inline.} =
  ## Captures `_server_timing_enabled` and `_server_timing_start` in
  ## req.locals; response.nim turns them into the `Server-Timing` header.
  ## Under default options (productionMode: true) this is a no-op pass-through.
  let opts = options

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if req == nil or req.locals == nil:
      await next()
      return

    if not opts.enabled or opts.productionMode:
      await next()
      return

    req.locals["_server_timing_enabled"] = "1"
    req.locals["_server_timing_start"] = $getCachedEpochMicros()

    await next()

## Convenience overload that enables timing only when `productionMode` is false.
proc serverTiming*(productionMode: bool): AsyncMiddleware {.inline.} =
  ## Convenience overload: `serverTiming(false)` enables timing,
  ## `serverTiming(true)` (default-style) disables it.
  serverTiming(ServerTimingOptions(
    enabled: true,
    productionMode: productionMode
  ))
