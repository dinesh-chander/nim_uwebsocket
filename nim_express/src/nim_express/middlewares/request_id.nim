## Request id middleware

import std/[asyncdispatch, strutils, sysrand, times, atomics]
import common
import nim_utils/helpers/fast_map

var requestIdFallbackCounter: Atomic[uint64]

const
  MaxRequestIdLen = 128

## Fallback request id built from the current microsecond time and a monotonic counter, rendered as lowercase hex.
proc buildFallbackRequestId*(): string {.inline.} =
  let tick = requestIdFallbackCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
  let micros = uint64(epochTime() * 1_000_000.0)
  (toHex(micros, 16) & toHex(tick, 16)).toLowerAscii()

proc upstreamIdBounds(view: fast_map.FastStringView): (int, int) {.inline.} =
  ## Trim and validate an upstream request-id view in place; returns an empty
  ## range when the value is missing, overlong, or contains unsafe chars.
  if view.len <= 0 or view.data == nil:
    return (1, 0)
  let chars = cast[ptr UncheckedArray[char]](view.data)
  var lo = 0
  while lo < view.len and (chars[lo] in {' ', '\t', '\n', '\r', '\f', '\v'}):
    inc lo
  var hi = view.len - 1
  while hi >= lo and (chars[hi] in {' ', '\t', '\n', '\r', '\f', '\v'}):
    dec hi
  if lo > hi or hi - lo + 1 > MaxRequestIdLen:
    return (1, 0)
  for i in lo..hi:
    let c = chars[i]
    if not (c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'}):
      return (1, 0)
  (lo, hi)

proc sliceUpstreamId(view: fast_map.FastStringView, lo, hi: int): string {.inline.} =
  let sliceLen = hi - lo + 1
  let chars = cast[ptr UncheckedArray[char]](view.data)
  result = newStringUninit(sliceLen)
  copyMem(addr result[0], unsafeAddr chars[lo], sliceLen)

## Assign each request a unique id, reusing a validated upstream header value only when `trustUpstream` is enabled, and echo it back in the X-Request-Id response header.
proc requestId*(trustUpstream: bool = false, headerName: string = "x-request-id"): AsyncMiddleware =
  ## Generate or propagate a unique request ID.
  ## When trustUpstream is true, accept and forward an existing header value
  ## (if it passes validation), instead of always generating a new one.
  ## A requestId local set by an earlier middleware is overwritten
  ## (last-write-wins); register this middleware before any other
  ## ID-setting middleware.
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    var id = ""

    if trustUpstream and headerName.len > 0:
      let upstream = req.getView(headerName)
      let (lo, hi) = upstreamIdBounds(upstream)
      if lo <= hi:
        id = sliceUpstreamId(upstream, lo, hi)

    if id.len == 0:
      var bytes: array[16, byte]
      if urandom(bytes):
        id = newString(32)
        const hex = "0123456789abcdef"
        for i, b in bytes:
          id[i * 2] = hex[int(b shr 4)]
          id[i * 2 + 1] = hex[int(b and 0x0F)]
      else:
        id = buildFallbackRequestId()

    req.locals["requestId"] = id
    res.set("X-Request-Id", id)
    await next()
