## Compression middleware
## Supports Brotli, Zstandard, and gzip (via libdeflate).
## Negotiates encoding from Accept-Encoding with quality values.
## Preference order (server tie-breaker): Zstandard > Brotli > gzip.
## Sensitive routes (CSRF/session data in HTML) can opt out per-request by
## setting `res.compress = false` in the handler to mitigate BREACH-style
## compression side channels.

import std/[asyncdispatch, strutils]
import common
import ../compression_codec
import ../app

const
  ## Content-Encoding values that indicate already-compressed responses.
  AlreadyCompressedEncodings = ["gzip", "br", "zstd", "deflate", "compress"]

type
  ## Per-request compression middleware options.
  ##
  ## `minBytes`: minimum response body size to compress (smaller bodies are
  ## sent uncompressed). Precedence: middleware option > app policy set by
  ## `installCompressionPolicy` > `MinCompressSize` (860 bytes). The default
  ## (0) means "no override", so an explicitly configured app policy is
  ## honored; a value of 0 likewise falls back to the app policy / default
  ## minimum.
  ##
  ## Sensitive routes (CSRF/session data embedded in HTML) can opt out by
  ## setting `res.compress = false` in the handler to mitigate BREACH-style
  ## compression side channels.
  CompressionOptions* = object
    enabled*: bool
    minBytes*: int
    minRequestContentLengthHint*: int
    enableOnMethods*: set[HttpMethod]
    skipPrecompressedMimes*: bool  ## Skip compression for already-compressed MIME types.

  CompressionPolicyOptions* = object
    enabled*: bool
    minBytes*: int
    minSavingsRatio*: float
    level*: int
    ## Accepted for API stability but currently a no-op: compression runs
    ## inline on the event loop with no backpressure gating. Do not rely on
    ## this to cap CPU under load.
    backpressureThresholdBytes*: int
    ## Accepted for API stability but currently a no-op: bodies are not
    ## offloaded to a worker thread; compression is synchronous.
    offloadThresholdBytes*: int

## Returns the default per-request compression options with compression enabled for common safe methods.
proc defaultCompressionOptions*(): CompressionOptions {.inline.} =
  CompressionOptions(
    enabled: true,
    minBytes: 0,
    minRequestContentLengthHint: 0,
    enableOnMethods: {hmGet, hmHead, hmPost, hmPut, hmPatch, hmDelete},
    skipPrecompressedMimes: true
  )

## Returns the default app-wide compression policy options with the standard minimum size and level.
proc defaultCompressionPolicyOptions*(): CompressionPolicyOptions {.inline.} =
  CompressionPolicyOptions(
    enabled: true,
    minBytes: 860,
    minSavingsRatio: 0.05,
    level: 6,
    backpressureThresholdBytes: 0,
    offloadThresholdBytes: 16 * 1024
  )

proc stripEncodingParam(token: string): string {.inline.} =
  let semi = token.find(';')
  if semi >= 0:
    token[0..<semi].strip()
  else:
    token.strip()

## Returns true if a Content-Encoding header indicates the response body is already compressed.
proc isAlreadyCompressed*(contentEncoding: string): bool {.inline.} =
  ## Returns true if the response already has a content-encoding applied.
  if contentEncoding.len == 0:
    return false
  let lower = contentEncoding.strip().toLowerAscii()
  if lower == "identity":
    return false
  # Strip `;param` suffixes before matching tokens.
  if ',' notin lower:
    let tok = stripEncodingParam(lower)
    for enc in AlreadyCompressedEncodings:
      if tok == enc:
        return true
    return false
  for part in lower.split(','):
    let tok = stripEncodingParam(part)
    if tok.len > 0 and tok != "identity":
      return true
  false

## Returns true if a Content-Type header indicates an already-compressed file format.
proc isPrecompressedMime*(contentType: string): bool {.inline.} =
  ## Returns true if the MIME type indicates an already-compressed format.
  if contentType.len == 0:
    return false
  let token = contentTypeToken(contentType)
  for mime in PrecompressedMimeTypes:
    if token == mime:
      return true
  false

proc varyHasToken(varyValue: string, token: string): bool {.inline.} =
  for part in varyValue.split(','):
    if part.strip().cmpIgnoreCase(token) == 0:
      return true
  false

proc mergeVaryToken(res: Res, token: string) {.inline.} =
  let existing = res.get("vary")
  if existing.len == 0:
    res.setTrusted("vary", token)
  elif not existing.varyHasToken("*") and not existing.varyHasToken(token):
    res.setTrusted("vary", existing & ", " & token)

## Sets the app-wide compression policy; must be called before the server starts listening.
proc installCompressionPolicy*(
  app: ExpressApp,
  options: CompressionPolicyOptions = defaultCompressionPolicyOptions()
) =
  ## Sets app-wide compression policy. Must be called before `listen()`; the
  ## values are read without synchronization by the response path at request
  ## time, so mutating them after the server starts is a data race in
  ## multi-threaded/cluster mode.
  if app == nil:
    return
  app.setCompressionEnabled(options.enabled)
  app.setCompressionMinBytes(options.minBytes)
  app.setCompressionMinSavingsRatio(options.minSavingsRatio)
  app.setCompressionLevel(options.level)
  app.setCompressionBackpressureThreshold(options.backpressureThresholdBytes)
  app.setCompressionOffloadThreshold(options.offloadThresholdBytes)

## Middleware that negotiates response compression from the Accept-Encoding header and marks the response for compressed output.
proc compression*(
  options: CompressionOptions = defaultCompressionOptions()
): AsyncMiddleware =
  let opts = options
  let minBytesStr = $opts.minBytes
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if not opts.enabled or req.methodKind notin opts.enableOnMethods:
      await next()
      return

    if opts.minRequestContentLengthHint > 0:
      let contentLength = req.get("content-length")
      if contentLength.len > 0:
        try:
          if parseInt(contentLength) < opts.minRequestContentLengthHint:
            await next()
            return
        except ValueError:
          discard

    let acceptEncodingView = req.getView("accept-encoding")
    if acceptEncodingView.len == 0:
      await next()
      return

    let enc = chooseCompressionEncoding(acceptEncodingView)
    if enc == ceNone:
      await next()
      return

    res.mergeVaryToken("Accept-Encoding")

    let existingEnc = res.get("content-encoding")
    if existingEnc.len > 0 and isAlreadyCompressed(existingEnc):
      await next()
      return

    res.compress = true
    res.compressEncoding = headerValue(enc)
    if opts.minBytes > 0:
      res.locals["_compress_min_bytes"] = minBytesStr
    res.locals["_compress_skip_precompressed"] =
      if opts.skipPrecompressedMimes: "1" else: "0"

    await next()

    if opts.skipPrecompressedMimes and res.compress:
      let contentType = res.get("content-type")
      if contentType.len > 0 and isPrecompressedMime(contentType):
        res.compress = false
        res.compressEncoding = ""
