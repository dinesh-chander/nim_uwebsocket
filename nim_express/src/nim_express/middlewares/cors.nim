## CORS middleware
##
## origin = "*" (default) allows any origin without credentials; combine with
## allowedOrigins to allow a specific set. origin = "reflect" echoes the
## request's Origin (never "null", and never with credentials unless the origin
## is allowlisted). A concrete origin sends that origin verbatim.
##
## reflect + credentials with no allowlist denies every cross-origin request
## (reflecting arbitrary origins with credentials is unsafe); configure
## allowedOrigins to permit specific origins in that mode.
##
## Setup-time validation (ValueError): allowedOrigins entries must be literal
## origins ("*" is rejected — use origin = "*"); a concrete origin cannot be
## combined with allowedOrigins (the allowlist only applies in "*" / "reflect"
## modes).
##
## OPTIONS preflights short-circuit with 204, or 403 when the origin is denied
## or the requested method is not in the configured allow-methods list. With
## allowPrivateNetwork, preflights carrying
## access-control-request-private-network: true also receive
## access-control-allow-private-network: true.

import std/[asyncdispatch, strutils]
import common
import nim_utils/helpers/fast_map

type
  CorsOptions* = object
    origin*: string
    allowedOrigins*: seq[string]
    methods*: seq[string]
    allowedHeaders*: seq[string]
    exposedHeaders*: seq[string]
    credentials*: bool
    maxAge*: int
    allowPrivateNetwork*: bool

  CorsPrecomputed = object
    configuredOrigin: string
    methods: string
    methodList: seq[string]
    headers: string
    exposedHeaders: string
    allowlist: fast_map.FastMap[string]
    maxAgeStr: string
    credentials: bool
    allowPrivateNetwork: bool
    isSimpleWildcard: bool

## Pure origin-vs-allowlist match, case-insensitive; exported for unit tests.
proc corsOriginMatched*(origin: string, allowlist: seq[string]): bool {.inline.} =
  ## Pure origin-vs-allowlist match (case-insensitive). Exported for unit tests.
  if origin.len == 0:
    return false
  for entry in allowlist:
    if cmpIgnoreCase(origin, entry) == 0:
      return true
  false

proc normalizeAllowlist(entries: seq[string]): fast_map.FastMap[string] =
  result = newFastMap[string]()
  if entries.len > 0:
    discard result.reserve(entries.len)
  for entry in entries:
    let lower = entry.strip().toLowerAscii()
    if lower.len > 0:
      discard result.put(lower, "")

const
  DefaultCorsMethods = ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]
  CorsHeaderOrigin = "access-control-allow-origin"
  CorsHeaderMethods = "access-control-allow-methods"
  CorsHeaderHeaders = "access-control-allow-headers"
  CorsHeaderCredentials = "access-control-allow-credentials"
  CorsHeaderMaxAge = "access-control-max-age"
  CorsHeaderExpose = "access-control-expose-headers"
  CorsHeaderPrivateNetwork = "access-control-allow-private-network"

proc viewTrimmedBounds(view: fast_map.FastStringView): (int, int) {.inline.} =
  if view.len <= 0 or view.data == nil:
    return (1, 0)
  let chars = cast[ptr UncheckedArray[char]](view.data)
  var lo = 0
  while lo < view.len and (chars[lo] == ' ' or chars[lo] == '\t' or
      chars[lo] == '\n' or chars[lo] == '\r'):
    inc lo
  var hi = view.len - 1
  while hi >= lo and (chars[hi] == ' ' or chars[hi] == '\t' or
      chars[hi] == '\n' or chars[hi] == '\r'):
    dec hi
  (lo, hi)

proc viewSliceString(view: fast_map.FastStringView, lo, hi: int): string {.inline.} =
  let sliceLen = hi - lo + 1
  let chars = cast[ptr UncheckedArray[char]](view.data)
  result = newStringUninit(sliceLen)
  copyMem(addr result[0], unsafeAddr chars[lo], sliceLen)

proc viewTrimmedString(view: fast_map.FastStringView): string {.inline.} =
  let (lo, hi) = viewTrimmedBounds(view)
  if lo > hi:
    return ""
  viewSliceString(view, lo, hi)

proc lowerOriginKey(origin: string): string {.inline.} =
  for c in origin:
    if c in 'A'..'Z':
      return origin.toLowerAscii()
  origin

proc setAllowHeaders(req: Req, res: Res, pre: CorsPrecomputed) {.inline.} =
  if pre.headers == "*":
    let requested = req.getView("access-control-request-headers")
    let (lo, hi) = viewTrimmedBounds(requested)
    if lo <= hi:
      # The reflected value is attacker-controlled; sanitize to RFC 9110 field
      # value bytes (setTrusted alone only blocks CR/LF/NUL).
      discard res.setTrusted(CorsHeaderHeaders, sanitizeHeaderValue(viewSliceString(requested, lo, hi)))
      res.append("Vary", "Access-Control-Request-Headers")
    else:
      discard res.setTrusted(CorsHeaderHeaders, pre.headers)
  else:
    discard res.setTrusted(CorsHeaderHeaders, pre.headers)

proc preflightMethodDenied(req: Req, pre: CorsPrecomputed): bool {.inline.} =
  let requested = req.getView("access-control-request-method")
  if requested.len == 0:
    return false
  for entry in pre.methodList:
    if requested.equalsIgnoreCaseAscii(entry):
      return false
  true

proc sendPrivateNetworkHeader(req: Req, res: Res, pre: CorsPrecomputed) {.inline.} =
  if pre.allowPrivateNetwork and
     req.getView("access-control-request-private-network").equalsIgnoreCaseAscii("true"):
    discard res.setTrusted(CorsHeaderPrivateNetwork, "true")

proc finishPreflight(req: Req, res: Res, pre: CorsPrecomputed, originDenied: bool) =
  if originDenied or preflightMethodDenied(req, pre):
    res.status(403)
  else:
    res.status(204)
    sendPrivateNetworkHeader(req, res, pre)
  res.send("")

proc corsPrecompute(options: CorsOptions): CorsPrecomputed =
  for entry in options.allowedOrigins:
    if entry.strip() == "*":
      raise newException(
        ValueError,
        "cors: allowedOrigins entries must be literal origins; use origin = \"*\" for the wildcard")
  let origin = if options.origin.len > 0: options.origin else: "*"
  let isReflect = origin == "reflect"
  let isWildcard = origin == "*"
  if not isReflect and not isWildcard and options.allowedOrigins.len > 0:
    raise newException(
      ValueError,
      "cors: a concrete origin cannot be combined with allowedOrigins; " &
      "use origin = \"*\" or \"reflect\" to apply the allowlist")
  result.configuredOrigin = origin
  result.methodList =
    if options.methods.len > 0:
      options.methods
    else:
      @DefaultCorsMethods
  result.methods = result.methodList.join(", ")
  result.headers =
    if options.allowedHeaders.len > 0:
      options.allowedHeaders.join(", ")
    else:
      "Content-Type, Authorization, HX-Request, HX-Trigger, HX-Target"
  result.exposedHeaders =
    if options.exposedHeaders.len > 0:
      options.exposedHeaders.join(", ")
    else:
      ""
  result.allowlist = normalizeAllowlist(options.allowedOrigins)
  result.maxAgeStr = if options.maxAge > 0: $options.maxAge else: ""
  result.credentials = options.credentials
  result.allowPrivateNetwork = options.allowPrivateNetwork
  result.isSimpleWildcard = not options.credentials and isWildcard and
    result.allowlist.len == 0 and options.maxAge <= 0 and result.exposedHeaders.len == 0

proc applyCorsHeaders(req: Req, res: Res, pre: CorsPrecomputed): bool =
  ## Sets the CORS response headers. Returns true when the request was an OPTIONS
  ## preflight and the response was finalized (the caller must not call next);
  ## false otherwise (the caller calls next).
  if pre.isSimpleWildcard:
    discard res.setTrusted(CorsHeaderOrigin, "*")
    discard res.setTrusted(CorsHeaderMethods, pre.methods)
    setAllowHeaders(req, res, pre)
    if req.methodKind == hmOptions:
      finishPreflight(req, res, pre, false)
      return true
    return false

  let originView = req.getView("origin")
  let hasAllowlist = pre.allowlist.len > 0
  var requestOrigin: string
  var allowlisted = false
  if hasAllowlist or pre.configuredOrigin == "reflect":
    requestOrigin = viewTrimmedString(originView)
    if hasAllowlist and requestOrigin.len > 0:
      allowlisted = lowerOriginKey(requestOrigin) in pre.allowlist
  # In reflect mode the response always depends on Origin, so it must vary by
  # Origin even when a given request carries no Origin header (cache correctness).
  var varyOrigin = pre.configuredOrigin == "reflect"
  # The allowlist only changes the response in wildcard/reflect modes; with a
  # fixed origin the response is constant, so no Vary is needed.
  let allowlistVaries = hasAllowlist and (pre.configuredOrigin == "*" or pre.configuredOrigin == "reflect")
  var allowOrigin = pre.configuredOrigin
  var sendCredentials = pre.credentials

  if pre.credentials and pre.configuredOrigin == "*":
    if allowlisted:
      allowOrigin = requestOrigin
      varyOrigin = true
    else:
      allowOrigin = ""
      sendCredentials = false
  elif pre.configuredOrigin == "reflect":
    let isNullOrigin = cmpIgnoreCase(requestOrigin, "null") == 0
    if requestOrigin.len > 0 and
       ((not pre.credentials and not hasAllowlist and not isNullOrigin) or allowlisted):
      allowOrigin = requestOrigin
      varyOrigin = true
    else:
      allowOrigin = ""
      sendCredentials = false
  elif hasAllowlist and pre.configuredOrigin == "*":
    if allowlisted:
      allowOrigin = requestOrigin
      varyOrigin = true
    else:
      allowOrigin = ""

  if pre.credentials and hasAllowlist and not allowlisted:
    allowOrigin = ""
    sendCredentials = false

  if allowOrigin.len > 0:
    discard res.setTrusted(CorsHeaderOrigin, allowOrigin)
  discard res.setTrusted(CorsHeaderMethods, pre.methods)
  setAllowHeaders(req, res, pre)

  if varyOrigin or allowlistVaries:
    res.append("Vary", "Origin")

  if sendCredentials:
    discard res.setTrusted(CorsHeaderCredentials, "true")
  if pre.maxAgeStr.len > 0:
    discard res.setTrusted(CorsHeaderMaxAge, pre.maxAgeStr)
  if pre.exposedHeaders.len > 0:
    discard res.setTrusted(CorsHeaderExpose, pre.exposedHeaders)

  if req.methodKind == hmOptions:
    finishPreflight(req, res, pre, pre.credentials and allowOrigin.len == 0)
    return true
  return false

## Async CORS middleware that applies the configured ``CorsOptions`` to every request.
proc cors*(options: CorsOptions = CorsOptions()): AsyncMiddleware {.gcsafe.} =
  ## Async CORS middleware. Note: origin = "reflect" with credentials = true and
  ## no allowedOrigins denies every cross-origin request by design (reflecting
  ## arbitrary origins with credentials is unsafe); set allowedOrigins to permit
  ## specific origins in that mode.
  let pre = corsPrecompute(options)
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if applyCorsHeaders(req, res, pre):
      return
    await next()

## Synchronous CORS middleware that applies the configured ``CorsOptions`` to every request.
proc corsSync*(options: CorsOptions = CorsOptions()): SyncNextMiddleware {.gcsafe.} =
  ## Sync CORS middleware. Note: origin = "reflect" with credentials = true and
  ## no allowedOrigins denies every cross-origin request by design (reflecting
  ## arbitrary origins with credentials is unsafe); set allowedOrigins to permit
  ## specific origins in that mode.
  let pre = corsPrecompute(options)
  result = proc(req: Req, res: Res, next: proc() {.closure.}) =
    if applyCorsHeaders(req, res, pre):
      return
    next()
