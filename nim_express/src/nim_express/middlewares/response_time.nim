## Response time header middleware.

import std/[asyncdispatch, monotimes, strutils]
import common

type
  ResponseTimeOptions* = object
    headerName*: string

const defaultResponseTimeHeaderName* = "X-Response-Time"

## Returns the default response time middleware options using the `X-Response-Time` header.
proc defaultResponseTimeOptions*(): ResponseTimeOptions {.inline.} =
  ResponseTimeOptions(
    headerName: defaultResponseTimeHeaderName
  )

## Returns the configured header name, falling back to the default when it is not a valid HTTP header token.
proc normalizeResponseTimeHeaderName*(headerName: string): string {.inline.} =
  ## Fall back to the default header when the configured name is not a
  ## valid HTTP header token, so typos do not silently drop the header.
  if sanitizeHeaderName(headerName).len == 0:
    defaultResponseTimeHeaderName
  else:
    headerName

## Middleware that adds a response time header to every response using a high-resolution monotonic clock.
proc responseTime*(
  options: ResponseTimeOptions = defaultResponseTimeOptions()
): AsyncMiddleware =
  ## Add a response time header (e.g. `X-Response-Time: 12.345ms`) to
  ## every response using a high-resolution monotonic clock.
  let headerName = normalizeResponseTimeHeaderName(options.headerName)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let start = getMonoTime()
    res.addBeforeFinalizeHook(proc() =
      if res.isNil: return
      let elapsed = getMonoTime() - start
      let ms = elapsed.inMicroseconds.float / 1_000.0
      discard res.set(headerName, formatFloat(ms, ffDecimal, 3) & "ms")
    )
    await next()
