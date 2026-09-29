## Request body size limit middleware.
## Rejects requests exceeding a configurable body size with 413 Payload Too Large.

import std/[asyncdispatch, strutils]
import common
import nim_utils/helpers/fast_map

type
  ContentTypeLimitEntry* = object
    contentType*: string
    maxBytes*: int

  BodyLimitOptions* = object
    maxBytes*: int
    contentTypeLimits*: seq[ContentTypeLimitEntry]

## Generic 413 body. Intentionally omits the configured `limit` so internal
## per-type policy is not disclosed to clients.
const payloadTooLargeBody* = """{"error":"Payload Too Large"}"""

## Default options: 1 MiB max body size with no per-type limits.
proc defaultBodyLimitOptions*(): BodyLimitOptions {.inline.} =
  BodyLimitOptions(maxBytes: 1_048_576)

## Validate per-type entries; negative ``maxBytes`` raises ValueError, empty and wildcard tokens are skipped, and duplicates keep the first entry.
proc normalizeContentTypeLimits*(entries: seq[ContentTypeLimitEntry]): seq[ContentTypeLimitEntry] {.noSideEffect.} =
  result = newSeqOfCap[ContentTypeLimitEntry](entries.len)
  for i, entry in entries:
    if entry.maxBytes < 0:
      raise newException(
        ValueError,
        "bodyLimit: content-type limit for '" & entry.contentType & "' must have maxBytes >= 0")
    let token = contentTypeToken(entry.contentType)
    # Skip entries that can never match: an empty token, or a wildcard pattern
    # (content-type matching here is exact-token only, no `*` expansion), and
    # duplicate tokens (the first entry wins).
    if token.len > 0 and token.find('*') < 0:
      var duplicate = false
      for existing in result:
        if existing.contentType == token:
          duplicate = true
          break
      if not duplicate:
        result.add(ContentTypeLimitEntry(contentType: token, maxBytes: entry.maxBytes))

## Return the max bytes for an exact content-type token match, else ``defaultMax``.
proc resolveLimit*(limits: seq[ContentTypeLimitEntry], defaultMax: int, contentType: string): int {.inline, noSideEffect.} =
  if limits.len > 0 and contentType.len > 0:
    let token = contentTypeToken(contentType)
    for entry in limits:
      if token == entry.contentType:
        return entry.maxBytes
  defaultMax

## No-allocation variant that tokenizes a ``FastStringView`` content-type header in place before matching entries.
proc resolveLimit*(limits: seq[ContentTypeLimitEntry], defaultMax: int,
                   contentType: fast_map.FastStringView): int {.inline, noSideEffect.} =
  if limits.len > 0 and contentType.len > 0 and contentType.data != nil:
    let data = cast[ptr UncheckedArray[char]](contentType.data)
    var tokenLen = contentType.len
    var i = 0
    while i < contentType.len:
      if data[i] == ';':
        tokenLen = i
        break
      inc i
    var startPos = 0
    while startPos < tokenLen and (data[startPos] == ' ' or data[startPos] == '\t'):
      inc startPos
    while tokenLen > startPos and (data[tokenLen - 1] == ' ' or data[tokenLen - 1] == '\t'):
      dec tokenLen
    let valueLen = tokenLen - startPos
    if valueLen > 0:
      let token = fast_map.FastStringView(
        data: cast[pointer](unsafeAddr data[startPos]),
        len: valueLen)
      for entry in limits:
        if token.equalsIgnoreCaseAscii(entry.contentType):
          return entry.maxBytes
  defaultMax

## Rejects requests whose body exceeds a configurable size with 413.
##
## This is a *processing* guard: it prevents downstream parsing of oversized
## bodies. uSockets buffers the full request body before the middleware chain
## runs, so `maxBodySize`/`bodySpillThreshold` on the server are the actual
## buffering guards; configure `maxBodySize` >= this limit so the 413 path is
## reachable. `maxBytes <= 0` on the options overload means "no body allowed";
## the `bodyLimit(int)` overload clamps to at least 1 byte.
proc bodyLimit*(
  options: BodyLimitOptions = defaultBodyLimitOptions()
): AsyncMiddleware =
  let opts = BodyLimitOptions(
    maxBytes: if options.maxBytes < 0: 0 else: options.maxBytes,
    contentTypeLimits: options.contentTypeLimits
  )
  let normalizedLimits = normalizeContentTypeLimits(opts.contentTypeLimits)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    # Only compute the content-type token when per-type limits are configured;
    # the common case (empty limits) must not pay for the header copy + tokenize.
    let limit =
      if normalizedLimits.len > 0:
        resolveLimit(normalizedLimits, opts.maxBytes, req.getView("content-type"))
      else:
        opts.maxBytes

    let contentLengthView = req.getView("content-length")
    if contentLengthView.len > 0:
      try:
        # RFC 9110 permits a comma-separated list of identical values
        # (e.g. "100, 100"); parse only the first element.
        let data = cast[ptr UncheckedArray[char]](contentLengthView.data)
        var comma = -1
        for i in 0..<contentLengthView.len:
          if data[i] == ',':
            comma = i
            break
        let firstElement = fast_map.FastStringView(
          data: contentLengthView.data,
          len: if comma >= 0: comma else: contentLengthView.len)
        let declaredRaw =
          if comma >= 0: ($firstElement).strip()
          else: $contentLengthView
        let declared = parseInt(declaredRaw)
        # NOTE: the 400 branches below are defense-in-depth; the server's HTTP
        # parser already rejects malformed/negative/overflowing Content-Length
        # before a request reaches this middleware.
        if declared < 0:
          res.set("Connection", "close")
          res.status(400)
          res.json(%*{"error": "Bad Request"})
          return
        if declared > limit:
          res.set("Connection", "close")
          res.status(413)
          res.jsonRaw(payloadTooLargeBody)
          return
      except ValueError:
        res.set("Connection", "close")
        res.status(400)
        res.json(%*{"error": "Bad Request", "detail": "Malformed Content-Length"})
        return

    let sizeHint = req.rawBodySizeHint()
    if sizeHint > limit:
      res.set("Connection", "close")
      res.status(413)
      res.jsonRaw(payloadTooLargeBody)
      return

    req.bindBody()
    if req.bodyReadFailed():
      res.set("Connection", "close")
      res.status(500)
      res.json(%*{"error": "Internal Server Error"})
      return
    if req.body.len > limit:
      res.set("Connection", "close")
      res.status(413)
      res.jsonRaw(payloadTooLargeBody)
      return

    await next()

## Convenience overload building the middleware from a plain byte count, clamped to at least 1 byte.
proc bodyLimit*(maxBytes: int): AsyncMiddleware =
  bodyLimit(BodyLimitOptions(maxBytes: max(1, maxBytes)))
