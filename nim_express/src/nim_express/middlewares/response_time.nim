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

## Renders an elapsed duration given in microseconds as a fixed 3-decimal
## millisecond string, matching what formatting `us / 1000.0` with 3 decimals
## produces, but without float formatting or intermediate string copies.
proc renderElapsedMs(us: int64): string {.inline.} =
  if us < 0:
    # Monotonic clocks do not go backwards; keep the previous rendering for the
    # degenerate case instead of inventing a new one.
    return formatFloat(us.float / 1_000.0, ffDecimal, 3) & "ms"
  let whole = us div 1_000
  let frac = (us mod 1_000).int
  result = newStringOfCap(24)
  var digits: array[24, char]
  var n = whole
  if n == 0:
    result.add('0')
  else:
    var p = 0
    while n > 0:
      digits[p] = chr(ord('0') + int(n mod 10))
      n = n div 10
      inc p
    var i = p - 1
    while i >= 0:
      result.add(digits[i])
      dec i
  result.add('.')
  result.add(chr(ord('0') + frac div 100))
  result.add(chr(ord('0') + (frac div 10) mod 10))
  result.add(chr(ord('0') + frac mod 10))
  result.add("ms")

## Test hook: renders an elapsed microsecond duration with the middleware's
## internal fixed-precision formatter so tests can sweep it against the float
## path it replaced.
proc renderElapsedMsForTest*(us: int64): string =
  renderElapsedMs(us)

## Middleware that adds a response time header to every response using a high-resolution monotonic clock.
proc responseTime*(
  options: ResponseTimeOptions = defaultResponseTimeOptions()
): AsyncMiddleware =
  ## Add a response time header (e.g. `X-Response-Time: 12.345ms`) to
  ## every response using a high-resolution monotonic clock.
  let headerName = normalizeResponseTimeHeaderName(options.headerName)
  # `set` lowercases header names itself, so pre-lowercasing once here is
  # wire-invisible and skips that work on every response.
  let headerNameLower = sanitizeHeaderName(headerName)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let start = getMonoTime()
    res.addBeforeFinalizeHook(proc() =
      if res.isNil: return
      let elapsed = getMonoTime() - start
      discard res.set(headerNameLower, renderElapsedMs(elapsed.inMicroseconds))
    )
    await next()
