## Request helpers for nim_express
## With lazy parsing for cookies and JSON

import std/[strutils, parseutils]
import types
import nim_utils/helpers/fast_map
import windowing

export types

type
  ## Result of resolving a request window/range. See ``resolveWindowRangeHeader``.
  WindowRangeResolveResult* = object
    ## True when ``value`` holds a valid range.
    ok*: bool
    ## Canonical `unit=start-end` range string.
    value*: string
    ## Reason text when resolution failed.
    error*: string

  ## Multipart upload metadata populated by multipart() middleware.
  UploadedFile* = object
    ## True when a file with this field name was found.
    found*: bool
    ## Form field name the file was submitted under.
    field*: string
    ## Original filename reported by the client.
    name*: string
    ## File size in bytes.
    size*: int
    ## Path on disk when the upload was streamed to a file.
    path*: string
    ## In-memory file content when not stored on disk.
    data*: string

proc containsNullByte(s: string): bool {.inline.} =
  for c in s:
    if c == '\0':
      return true
  false

proc normalizeHeaderLookupKey(header: string): string {.inline.} =
  for c in header:
    if c >= 'A' and c <= 'Z':
      return header.toLowerAscii()
  header

proc fastStringSlice(value: fast_map.FastStringView, startPos, endPos: int): string {.inline.} =
  let sliceLen = endPos - startPos
  if value.data == nil or sliceLen <= 0:
    return ""
  let chars = cast[ptr UncheckedArray[char]](value.data)
  result = newStringUninit(sliceLen)
  copyMem(addr result[0], unsafeAddr chars[startPos], sliceLen)

proc firstHeaderToken(value: string): string {.inline.} =
  if value.len == 0:
    return ""
  let comma = value.find(',')
  if comma >= 0:
    return value[0..<comma].strip()
  value.strip()

proc firstHeaderToken(value: fast_map.FastStringView): string {.inline, used.} =
  if value.len == 0 or value.data == nil:
    return ""
  let chars = cast[ptr UncheckedArray[char]](value.data)
  var endPos = value.len
  var i = 0
  while i < value.len:
    if chars[i] == ',':
      endPos = i
      break
    inc i
  var startPos = 0
  while startPos < endPos and (chars[startPos] == ' ' or chars[startPos] == '\t'):
    inc startPos
  while endPos > startPos and (chars[endPos - 1] == ' ' or chars[endPos - 1] == '\t'):
    dec endPos
  fastStringSlice(value, startPos, endPos)

proc headerTokenFromRight(value: string, skipFromRight: int): string =
  if value.len == 0:
    return ""
  var want = max(0, skipFromRight)
  var endPos = value.len
  var i = value.len - 1
  while i >= 0:
    while i >= 0 and (value[i] == ',' or value[i] == ' ' or value[i] == '\t'):
      dec i
    if i < 0:
      break
    let tokenEnd = i + 1
    while i >= 0 and value[i] != ',':
      dec i
    let tokenStart = i + 1
    let token = value[tokenStart..<tokenEnd].strip()
    if token.len > 0:
      if want == 0:
        return token
      dec want
    endPos = tokenStart
    if endPos <= 0:
      break
  ""

proc headerTokenFromRight(value: fast_map.FastStringView, skipFromRight: int): string {.used.} =
  if value.len == 0 or value.data == nil:
    return ""
  let chars = cast[ptr UncheckedArray[char]](value.data)
  var want = max(0, skipFromRight)
  var i = value.len - 1
  while i >= 0:
    while i >= 0 and (chars[i] == ',' or chars[i] == ' ' or chars[i] == '\t'):
      dec i
    if i < 0:
      break
    let tokenEnd = i + 1
    while i >= 0 and chars[i] != ',':
      dec i
    var tokenStart = i + 1
    while tokenStart < tokenEnd and (chars[tokenStart] == ' ' or chars[tokenStart] == '\t'):
      inc tokenStart
    var trimmedEnd = tokenEnd
    while trimmedEnd > tokenStart and (chars[trimmedEnd - 1] == ' ' or chars[trimmedEnd - 1] == '\t'):
      dec trimmedEnd
    if trimmedEnd > tokenStart:
      if want == 0:
        return fastStringSlice(value, tokenStart, trimmedEnd)
      dec want
  ""

proc forwardedHeaderTokenCount(value: fast_map.FastStringView): int {.used.} =
  if value.len == 0 or value.data == nil:
    return 0
  let chars = cast[ptr UncheckedArray[char]](value.data)
  var i = 0
  while i < value.len:
    while i < value.len and (chars[i] == ',' or chars[i] == ' ' or chars[i] == '\t'):
      inc i
    if i >= value.len:
      break
    inc result
    while i < value.len and chars[i] != ',':
      inc i

proc forwardedHeaderTokenCount(value: string): int =
  if value.len == 0:
    return 0
  var i = 0
  while i < value.len:
    while i < value.len and (value[i] == ',' or value[i] == ' ' or value[i] == '\t'):
      inc i
    if i >= value.len:
      break
    inc result
    while i < value.len and value[i] != ',':
      inc i

proc ipInAllowlist(ip: string, allowlistCsv: string): bool =
  if ip.len == 0 or allowlistCsv.len == 0:
    return false
  var start = 0
  while start <= allowlistCsv.len:
    var stop = start
    while stop < allowlistCsv.len and allowlistCsv[stop] != ',':
      inc stop
    let token = allowlistCsv[start..<stop].strip()
    if token == "*":
      return true
    if token.len > 0 and token == ip:
      return true
    start = stop + 1

## Check whether proxy headers such as ``X-Forwarded-*`` may be trusted.
## Validates the peer IP against the allowlist and trusted hop count.
proc forwardedHeadersTrusted*(
  req: Request,
  trustProxyEnabled: bool = req.trustProxyEnabled
): bool =
  if req == nil or not trustProxyEnabled:
    return false

  if req.trustedProxyAllowlist.len > 0 and not ipInAllowlist(req.native.remoteIp, req.trustedProxyAllowlist):
    return false

  let trustedHops = max(0, int(req.trustedProxyHopCount))
  if trustedHops == 0 and req.trustedProxyAllowlist.len == 0:
    return false
  if trustedHops > 0:
    req.bindHeaders()
    let forwardedFor = req.headers.getOrDefault("x-forwarded-for", "")
    if forwardedHeaderTokenCount(forwardedFor) < trustedHops + 1:
      return false
  true

## Resolve the client IP from forwarded headers when proxy trust passes.
## Returns "" when untrusted. See ``forwardedHeadersTrusted``.
proc trustedClientIp*(req: Request, trustProxyEnabled: bool = req.trustProxyEnabled): string {.inline.} =
  if req == nil or not req.forwardedHeadersTrusted(trustProxyEnabled = trustProxyEnabled):
    return ""
  req.bindHeaders()
  let forwardedFor = req.headers.getOrDefault("x-forwarded-for", "")
  let realIp = req.headers.getOrDefault("x-real-ip", "")
  let trustedHops = max(0, int(req.trustedProxyHopCount))
  let forwarded =
    if trustedHops > 0:
      headerTokenFromRight(forwardedFor, trustedHops)
    else:
      firstHeaderToken(forwardedFor)
  if forwarded.len > 0:
    return forwarded
  firstHeaderToken(realIp)

proc trustedForwardedProto(req: Request): string {.inline.} =
  if req == nil or not req.forwardedHeadersTrusted():
    return ""
  req.bindHeaders()
  let forwardedProto = req.headers.getOrDefault("x-forwarded-proto", "")
  if req.trustedProxyHopCount > 0:
    return headerTokenFromRight(forwardedProto, 0)
  firstHeaderToken(forwardedProto)

proc trustedForwardedHost(req: Request): string {.inline.} =
  if req == nil or not req.forwardedHeadersTrusted():
    return ""
  req.bindHeaders()
  let forwardedHost = req.headers.getOrDefault("x-forwarded-host", "")
  if req.trustedProxyHopCount > 0:
    return headerTokenFromRight(forwardedHost, 0)
  firstHeaderToken(forwardedHost)

proc mediaRangeSpecificity(offerLower: string, mediaRangeLower: string): int {.inline.} =
  if mediaRangeLower.len == 0:
    return -1
  if mediaRangeLower == "*/*" or mediaRangeLower == "*":
    return 0
  if mediaRangeLower == offerLower:
    return 2
  if mediaRangeLower.endsWith("/*"):
    let slash = mediaRangeLower.find('/')
    if slash > 0 and offerLower.startsWith(mediaRangeLower[0..<slash] & "/"):
      return 1
  -1

proc parseQValue(raw: string): float {.inline.} =
  if raw.len == 0:
    return -1.0
  try:
    let parsed = parseFloat(raw)
    if parsed < 0.0:
      return 0.0
    if parsed > 1.0:
      return 1.0
    parsed
  except ValueError:
    -1.0

proc weakNormalizeEtag(tag: string): string {.inline.} =
  var normalized = tag.strip()
  if normalized.len >= 2 and normalized[0].toLowerAscii() == 'w' and normalized[1] == '/':
    normalized = normalized[2..^1].strip()
  normalized

proc ifNoneMatchSatisfied(ifNoneMatch: string, etag: string): bool =
  if ifNoneMatch.len == 0 or etag.len == 0:
    return false
  let target = weakNormalizeEtag(etag)
  var i = 0
  while i < ifNoneMatch.len:
    while i < ifNoneMatch.len and (ifNoneMatch[i] == ' ' or ifNoneMatch[i] == '\t' or ifNoneMatch[i] == ','):
      inc i
    if i >= ifNoneMatch.len:
      break
    let start = i
    while i < ifNoneMatch.len and ifNoneMatch[i] != ',':
      inc i
    let token = ifNoneMatch[start..<i].strip()
    if token == "*":
      return true
    if token.len > 0 and weakNormalizeEtag(token) == target:
      return true
  false

proc parseImfFixdate(value: string, outTime: var DateTime): bool =
  try:
    outTime = parse(value, "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc())
    return true
  except ValueError:
    return false

proc stripPortFromHost(hostHeader: string): string {.inline.} =
  let host = firstHeaderToken(hostHeader)
  if host.len == 0:
    return ""
  if host[0] == '[':
    let closeBracket = host.find(']')
    if closeBracket > 1:
      return host[1..<closeBracket]
    return host
  let sep = host.find(':')
  if sep >= 0:
    return host[0..<sep]
  host

proc isSafeForwardedHostToken(token: string): bool {.inline.} =
  if token.len == 0 or token.len > 255:
    return false
  for c in token:
    case c
    of 'a'..'z', 'A'..'Z', '0'..'9', '.', '-', ':', '[', ']':
      discard
    else:
      return false
  true

## Borrow raw query metadata from the native request.
proc rawQuery*(req: Request): lent string {.inline.} =
  req.native.queryStringRawView()

## Borrow a request header view without materializing an owned string.
proc getView*(req: Request, header: string): fast_map.FastStringView {.inline.} =
  req.bindHeaders()
  req.headers.getView(header.normalizeHeaderLookupKey())

## Get a request header
proc get*(req: Request, header: string): string {.inline.} =
  req.bindHeaders()
  req.headers.getOrDefault(header.normalizeHeaderLookupKey(), "")

## Get a route parameter
proc param*(req: Request, name: string): string {.inline.} =
  req.params.getOrDefault(name, "")

## Get a query parameter value, falling back to raw query parsing.
proc queryParam*(req: Request, name: string, default: string = ""): string {.inline.} =
  if req == nil or name.len == 0 or name.len > DefaultMaxQueryKeyBytes:
    return default
  if name.containsNullByte():
    return default
  if req.query != nil:
    return req.query.getOrDefault(name, default)

  let nativeQuery =
    if req.native != nil:
      req.native.query
    else:
      nil
  if nativeQuery != nil and nativeQuery.len > 0:
    return nativeQuery.getOrDefault(name, default)

  let raw = req.rawQuery()
  if raw.len == 0:
    return default

  var parsedPairs = 0
  var i = 0
  var found = false
  var matchedValue = default
  while i < raw.len and parsedPairs < DefaultMaxQueryPairs:
    let keyStart = i
    var keyEnd = i
    var valStart = -1
    while i < raw.len and raw[i] != '&':
      if raw[i] == '=' and valStart < 0:
        keyEnd = i
        valStart = i + 1
      inc i
    if valStart < 0:
      keyEnd = i
    let valueEnd = i

    if keyEnd > keyStart:
      let keyLen = keyEnd - keyStart
      let valueLen =
        if valStart >= 0 and valueEnd >= valStart:
          valueEnd - valStart
        else:
          0
      if keyLen > 0 and keyLen <= DefaultMaxQueryKeyBytes and valueLen <= DefaultMaxQueryValueBytes:
        var hasNull = false
        for offset in 0..<keyLen:
          if raw[keyStart + offset] == '\0':
            hasNull = true
            break
        if not hasNull:
          inc parsedPairs
          if keyLen == name.len:
            var matches = true
            for offset in 0..<keyLen:
              if raw[keyStart + offset] != name[offset]:
                matches = false
                break
            if matches:
              if valStart >= 0 and valueEnd > valStart:
                var valueHasNull = false
                for offset in valStart..<valueEnd:
                  if raw[offset] == '\0':
                    valueHasNull = true
                    break
                if not valueHasNull:
                  found = true
                  matchedValue = raw[valStart..<valueEnd]
              else:
                found = true
                matchedValue = ""
    inc i

  if found:
    return matchedValue
  default

## Get a request-scoped local value.
proc local*(req: Request, name: string, default: string = ""): string {.inline.} =
  if req == nil:
    return default
  req.locals.getOrDefault(name, default)

## Set a request-scoped local value.
proc setLocal*(req: Request, name: string, value: string) {.inline.} =
  if req == nil or name.len == 0:
    return
  req.locals[name] = value

## Get urlencoded form field parsed by urlencoded() middleware.
proc form*(req: Request, name: string, default: string = ""): string {.inline.} =
  if req == nil or name.len == 0:
    return default
  req.locals.getOrDefault("form_" & name, default)

## Typed accessor for multipart file metadata populated by multipart() middleware.
proc uploadFile*(req: Request, field: string): UploadedFile {.inline.} =
  if req == nil or field.len == 0:
    return UploadedFile(found: false)
  let prefix = "file_" & field & "_"
  let name = req.locals.getOrDefault(prefix & "name", "")
  let path = req.locals.getOrDefault(prefix & "path", "")
  let data = req.locals.getOrDefault(prefix & "data", "")
  let rawSize = req.locals.getOrDefault(prefix & "size", "")
  var size = 0
  if rawSize.len > 0:
    try:
      size = parseInt(rawSize)
    except ValueError:
      size = 0
  result = UploadedFile(
    found: name.len > 0 or path.len > 0 or data.len > 0,
    field: field,
    name: name,
    size: max(0, size),
    path: path,
    data: data
  )

## True when a multipart file exists for the given field. See ``uploadFile``.
proc hasUploadFile*(req: Request, field: string): bool {.inline.} =
  req.uploadFile(field).found

## Get text body parsed by text() middleware.
proc bodyText*(req: Request, default: string = ""): string {.inline.} =
  if req == nil:
    return default
  req.locals.getOrDefault("body_text", default)

## Get raw body parsed by raw() middleware.
proc bodyRaw*(req: Request, default: string = ""): string {.inline.} =
  if req == nil:
    return default
  req.locals.getOrDefault("body_raw", default)

## Set a request-scoped local value from an int.
proc setLocal*(req: Request, name: string, value: int) {.inline.} =
  req.setLocal(name, $value)

## Set a request-scoped local value from a bool ("true"/"false").
proc setLocal*(req: Request, name: string, value: bool) {.inline.} =
  req.setLocal(name, if value: "true" else: "false")

proc copyFastMap(source: FastMap[string], reserveHint: int = 8): FastMap[string] {.inline.} =
  result = newFastMap[string]()
  discard result.reserve(max(1, reserveHint))
  if source == nil:
    return
  for key, value in source.pairs():
    discard result.put(key, value)

## Copy the request path into an owned string usable after the request ends.
proc detachPath*(req: Request): string {.inline.} =
  if req == nil:
    return ""
  $req.path

## Copy the raw query string into an owned string. See ``rawQuery``.
proc detachQueryStringRaw*(req: Request): string {.inline.} =
  if req == nil:
    return ""
  $req.rawQuery()

## Copy the raw request body into an owned string usable after the request ends.
proc detachBody*(req: Request): string {.inline.} =
  if req == nil:
    return ""
  req.bindBody()
  req.body

## Copy all request headers into an owned ``FastMap``.
proc detachHeaders*(req: Request): FastMap[string] {.inline.} =
  if req == nil:
    return copyFastMap(nil)
  req.bindHeaders()
  copyFastMap(req.headers, max(8, req.headers.len))

## Copy route parameters into an owned ``FastMap``. See ``param``.
proc detachParams*(req: Request): FastMap[string] {.inline.} =
  if req == nil:
    return copyFastMap(nil)
  copyFastMap(req.params, max(8, req.params.len))

## Copy parsed query parameters into an owned ``FastMap``. See ``queryParam``.
proc detachQuery*(req: Request): FastMap[string] {.inline.} =
  if req == nil:
    return copyFastMap(nil)
  req.bindQuery()
  copyFastMap(req.query, max(8, req.query.len))

## Copy parsed cookies into an owned ``FastMap``. See ``cookie``.
proc detachCookies*(req: Request): FastMap[string] {.inline.} =
  if req == nil:
    return copyFastMap(nil)
  discard req.getCookie("")
  copyFastMap(req.cookies, max(8, req.cookies.len))

## Copy request-scoped locals into an owned ``FastMap``. See ``local``.
proc detachLocals*(req: Request): FastMap[string] {.inline.} =
  if req == nil:
    return copyFastMap(nil)
  copyFastMap(req.locals, max(8, req.locals.len))

## Build an owned ``RequestSnapshot`` of the request for async handoff.
## Body, headers, cookies, and locals are included selectively.
proc snapshot*(
  req: Request,
  includeBody: bool = false,
  includeHeaders: bool = true,
  includeCookies: bool = true,
  includeLocals: bool = true
): RequestSnapshot =
  if req == nil:
    return
  result.methodKind = req.methodKind
  result.path = req.detachPath()
  result.queryStringRaw = req.detachQueryStringRaw()
  result.params = req.detachParams()
  result.query = req.detachQuery()
  result.headers =
    if includeHeaders: req.detachHeaders()
    else: copyFastMap(nil)
  result.cookies =
    if includeCookies: req.detachCookies()
    else: copyFastMap(nil)
  result.locals =
    if includeLocals: req.detachLocals()
    else: copyFastMap(nil)
  result.body =
    if includeBody: req.detachBody()
    else: ""
  result.correlationId = req.correlationId
  result.requestSeq = req.requestSeq
  result.cancelReason = req.cancelReason

## Register a hook called when the request is aborted, receiving the request.
proc onAbort*(
  req: Request,
  hook: proc(req: Request, reason: RequestCancelReason) {.closure.}
) {.inline.} =
  req.onCancel(hook)

## Register an abort hook without the request argument; pass nil to clear.
proc onAbort*(req: Request, hook: proc(reason: RequestCancelReason) {.closure.}) {.inline.} =
  if req == nil:
    return
  if hook == nil:
    req.onCancel(nil)
    return
  req.onCancel(proc(_: Request, reason: RequestCancelReason) =
    hook(reason)
  )

## True when the request has been aborted/cancelled. See ``abortReason``.
proc aborted*(req: Request): bool {.inline.} =
  req.requestCancelled()

## Reason the request was aborted, or ``rcrNone`` when still active.
proc abortReason*(req: Request): RequestCancelReason {.inline.} =
  if req == nil:
    return rcrNone
  req.cancelReason

## True when request explicitly asks for window/range semantics.
proc hasWindowSemantics*(
  req: Request,
  modeParam: string = "mode",
  windowParam: string = "window",
  rangeHeader: string = "range",
  offsetParam: string = "offset",
  limitParam: string = "limit"
): bool {.inline.} =
  if isWindowingModeEnabled(req.queryParam(modeParam, ""), req.queryParam(windowParam, "")):
    return true
  req.bindHeaders()
  if req.headers.getLen(rangeHeader.normalizeHeaderLookupKey(), 0) > 0:
    return true
  if req.queryParam(offsetParam, "").len > 0:
    return true
  if req.queryParam(limitParam, "").len > 0:
    return true
  false

## Get a cookie value; parsing is lazy.
proc cookie*(req: Request, name: string): string {.inline.} =
  req.getCookie(name)

## Get parsed JSON body; parsing is lazy.
proc jsonBody*(req: Request): JsonNode {.inline.} =
  req.getJsonBody()

## Check if request is XMLHttpRequest
proc isXhr*(req: Request): bool {.inline.} =
  req.get("x-requested-with").cmpIgnoreCase("xmlhttprequest") == 0

## Check if request has JSON content type
proc isJson*(req: Request): bool {.inline.} =
  isJsonContentType(req.get("content-type"))

## Check if request is from HTMX
proc isHtmx*(req: Request): bool {.inline.} =
  req.get("hx-request") == "true"

## Content negotiation - return best matching type
proc accepts*(req: Request, types: varargs[string]): string {.inline.} =
  if types.len == 0:
    return ""
  let accept = req.get("accept")
  if accept.len == 0:
    return types[0]

  var bestType = ""
  var bestQ = -1.0
  var bestSpecificity = -1

  for t in types:
    let offer = t.strip()
    if offer.len == 0:
      continue
    let offerLower = offer.toLowerAscii()
    var itemStart = 0
    while itemStart < accept.len:
      while itemStart < accept.len and (accept[itemStart] == ' ' or accept[itemStart] == '\t' or accept[itemStart] == ','):
        inc itemStart
      if itemStart >= accept.len:
        break

      var itemEnd = itemStart
      while itemEnd < accept.len and accept[itemEnd] != ',':
        inc itemEnd
      let item = accept[itemStart..<itemEnd]
      itemStart = itemEnd + 1

      var mediaRange = item.strip()
      if mediaRange.len == 0:
        continue
      var q = 1.0
      let semicolon = mediaRange.find(';')
      if semicolon >= 0:
        let params = mediaRange[semicolon + 1..^1]
        mediaRange = mediaRange[0..<semicolon].strip()

        var pStart = 0
        while pStart < params.len:
          while pStart < params.len and (params[pStart] == ' ' or params[pStart] == '\t' or params[pStart] == ';'):
            inc pStart
          if pStart >= params.len:
            break
          var pEnd = pStart
          while pEnd < params.len and params[pEnd] != ';':
            inc pEnd
          let part = params[pStart..<pEnd].strip()
          pStart = pEnd + 1
          if part.len >= 2 and part[0].toLowerAscii() == 'q' and part[1] == '=':
            let parsedQ = parseQValue(part[2..^1].strip())
            if parsedQ < 0.0:
              q = 0.0
            else:
              q = parsedQ
            break
      if q <= 0.0:
        continue
      let specificity = mediaRangeSpecificity(offerLower, mediaRange.toLowerAscii())
      if specificity < 0:
        continue
      if q > bestQ or (q == bestQ and specificity > bestSpecificity):
        bestQ = q
        bestSpecificity = specificity
        bestType = t
  bestType

## True when the client accepts JSON. See ``accepts``.
proc acceptsJson*(req: Request): bool {.inline.} =
  req.accepts("application/json").len > 0

## True when the client accepts HTML. See ``accepts``.
proc acceptsHtml*(req: Request): bool {.inline.} =
  req.accepts("text/html").len > 0

## Get request protocol
proc protocol*(req: Request): string {.inline.} =
  let proto = req.trustedForwardedProto().toLowerAscii()
  if proto.len > 0:
    if proto == "https":
      return "https"
    if proto == "http":
      return "http"
  "http"

## Check if connection is secure
proc secure*(req: Request): bool {.inline.} =
  req.protocol() == "https"

## Get hostname from Host header. If trust proxy is enabled, prefer X-Forwarded-Host.
proc hostname*(req: Request): string {.inline.} =
  let forwardedHostToken = req.trustedForwardedHost()
  if isSafeForwardedHostToken(forwardedHostToken):
    let parsed = stripPortFromHost(forwardedHostToken)
    if parsed.len > 0:
      return parsed
  stripPortFromHost(req.get("host"))

## Check if cache is fresh for conditional requests.
proc fresh*(req: Request, etag: string = "", lastModified: string = ""): bool {.inline.} =
  if req.get("cache-control").toLowerAscii().contains("no-cache"):
    return false

  let ifNoneMatch = req.get("if-none-match")
  let ifModifiedSince = req.get("if-modified-since")

  if ifNoneMatch.len > 0 and etag.len > 0:
    return ifNoneMatchSatisfied(ifNoneMatch, etag)

  if ifModifiedSince.len > 0 and lastModified.len > 0:
    var modifiedAt: DateTime
    var ifModifiedAt: DateTime
    if parseImfFixdate(lastModified.strip(), modifiedAt) and parseImfFixdate(ifModifiedSince.strip(), ifModifiedAt):
      return modifiedAt <= ifModifiedAt
    return lastModified.strip() == ifModifiedSince.strip()

  false

proc readFieldValue(req: Request, source: RequestFieldSource, name: string): string {.inline.} =
  case source
  of rfsQuery:
    req.queryParam(name)
  of rfsParam:
    req.param(name)
  of rfsHeader:
    req.get(name)
  of rfsCookie:
    req.cookie(name)
  of rfsLocal:
    req.local(name)
  of rfsBody:
    req.bindBody()
    req.body

proc coercionError(
  source: RequestFieldSource,
  field: string,
  rawValue: string,
  reason: string
): RequestCoercionError {.inline.} =
  RequestCoercionError(
    source: source,
    field: field,
    rawValue: rawValue,
    reason: reason
  )

proc parseStrictInt(raw: string, value: var int): bool {.inline.} =
  if raw.len == 0:
    return false
  var parsed = 0
  let consumed = parseInt(raw, parsed)
  if consumed != raw.len:
    return false
  value = parsed
  true

proc parseStrictBool(raw: string, value: var bool): bool {.inline.} =
  if raw.cmpIgnoreCase("true") == 0 or raw.cmpIgnoreCase("1") == 0 or
     raw.cmpIgnoreCase("yes") == 0 or raw.cmpIgnoreCase("on") == 0:
    value = true
    return true
  if raw.cmpIgnoreCase("false") == 0 or raw.cmpIgnoreCase("0") == 0 or
     raw.cmpIgnoreCase("no") == 0 or raw.cmpIgnoreCase("off") == 0:
    value = false
    return true
  false

## Require a non-empty field read from the given source.
## Returns an error in the ``CoercionResult`` when the field is missing.
proc requireField*(
  req: Request,
  source: RequestFieldSource,
  name: string
): CoercionResult[string] {.inline.} =
  let value = req.readFieldValue(source, name)
  if value.len == 0:
    result.ok = false
    result.error = coercionError(source, name, "", "missing required field")
    return
  result.ok = true
  result.value = value

## Coerce a field from the given source to an int with range checks.
proc coerceIntField*(
  req: Request,
  source: RequestFieldSource,
  name: string,
  required: bool = true,
  defaultValue: int = 0,
  minValue: int = low(int),
  maxValue: int = high(int)
): CoercionResult[int] =
  let raw = req.readFieldValue(source, name).strip()
  if raw.len == 0:
    if required:
      result.ok = false
      result.error = coercionError(source, name, "", "missing required integer")
      return
    result.ok = true
    result.value = defaultValue
    return

  var parsed = 0
  if not parseStrictInt(raw, parsed):
    result.ok = false
    result.error = coercionError(source, name, raw, "invalid integer")
    return
  if parsed < minValue or parsed > maxValue:
    result.ok = false
    result.error = coercionError(source, name, raw, "integer out of range")
    return
  result.ok = true
  result.value = parsed

## Coerce a field from the given source to a bool (true/1/yes/on).
proc coerceBoolField*(
  req: Request,
  source: RequestFieldSource,
  name: string,
  required: bool = true,
  defaultValue: bool = false
): CoercionResult[bool] =
  let raw = req.readFieldValue(source, name).strip()
  if raw.len == 0:
    if required:
      result.ok = false
      result.error = coercionError(source, name, "", "missing required boolean")
      return
    result.ok = true
    result.value = defaultValue
    return

  var parsed = false
  if not parseStrictBool(raw, parsed):
    result.ok = false
    result.error = coercionError(source, name, raw, "invalid boolean")
    return
  result.ok = true
  result.value = parsed

## Require a non-empty query parameter. See ``requireField``.
proc queryRequired*(req: Request, name: string): CoercionResult[string] {.inline.} =
  req.requireField(rfsQuery, name)

## Require a non-empty route parameter. See ``requireField``.
proc paramRequired*(req: Request, name: string): CoercionResult[string] {.inline.} =
  req.requireField(rfsParam, name)

## Coerce a query parameter to an int. See ``coerceIntField``.
proc queryInt*(
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: int = 0,
  minValue: int = low(int),
  maxValue: int = high(int)
): CoercionResult[int] {.inline.} =
  req.coerceIntField(
    source = rfsQuery,
    name = name,
    required = required,
    defaultValue = defaultValue,
    minValue = minValue,
    maxValue = maxValue
  )

## Coerce a route parameter to an int. See ``coerceIntField``.
proc paramInt*(
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: int = 0,
  minValue: int = low(int),
  maxValue: int = high(int)
): CoercionResult[int] {.inline.} =
  req.coerceIntField(
    source = rfsParam,
    name = name,
    required = required,
    defaultValue = defaultValue,
    minValue = minValue,
    maxValue = maxValue
  )

## Resolve a request window in canonical `unit=start-end` form.
## Priority:
## 1) existing Range header
## 2) synthesized from query `offset` + `limit`
proc resolveWindowRangeHeader*(
  req: Request,
  unit: string = "items",
  rangeHeader: string = "range",
  offsetParam: string = "offset",
  limitParam: string = "limit",
  defaultOffset: int = 0,
  defaultLimit: int = 64,
  minOffset: int = 0,
  minLimit: int = 1,
  maxLimit: int = high(int)
): WindowRangeResolveResult {.inline.} =
  result.value = req.get(rangeHeader)
  if result.value.len > 0:
    result.ok = true
    return

  let offsetRes = req.queryInt(
    offsetParam,
    required = false,
    defaultValue = defaultOffset,
    minValue = minOffset
  )
  if not offsetRes.ok:
    result.error = offsetRes.error.reason
    return

  let limitRes = req.queryInt(
    limitParam,
    required = false,
    defaultValue = defaultLimit,
    minValue = minLimit,
    maxValue = maxLimit
  )
  if not limitRes.ok:
    result.error = limitRes.error.reason
    return

  if offsetRes.value > high(int) - limitRes.value:
    result.error = "offset + limit exceeds supported integer range"
    return

  let endExclusive = offsetRes.value + limitRes.value
  result.value = unit & "=" & $offsetRes.value & "-" & $(endExclusive - 1)
  result.ok = true

## Coerce a query parameter to a bool. See ``coerceBoolField``.
proc queryBool*(
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: bool = false
): CoercionResult[bool] {.inline.} =
  req.coerceBoolField(
    source = rfsQuery,
    name = name,
    required = required,
    defaultValue = defaultValue
  )

## Coerce a route parameter to a bool. See ``coerceBoolField``.
proc paramBool*(
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: bool = false
): CoercionResult[bool] {.inline.} =
  req.coerceBoolField(
    source = rfsParam,
    name = name,
    required = required,
    defaultValue = defaultValue
  )

## Require a non-empty local value. See ``requireField`` and ``local``.
proc localRequired*(req: Request, name: string): CoercionResult[string] {.inline.} =
  req.requireField(rfsLocal, name)

## Coerce a local value to an int. See ``coerceIntField``.
proc localInt*(
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: int = 0,
  minValue: int = low(int),
  maxValue: int = high(int)
): CoercionResult[int] {.inline.} =
  req.coerceIntField(
    source = rfsLocal,
    name = name,
    required = required,
    defaultValue = defaultValue,
    minValue = minValue,
    maxValue = maxValue
  )

## Coerce a local value to a bool. See ``coerceBoolField``.
proc localBool*(
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: bool = false
): CoercionResult[bool] {.inline.} =
  req.coerceBoolField(
    source = rfsLocal,
    name = name,
    required = required,
    defaultValue = defaultValue
  )

## Generic field extractor for ``string``, ``int``, or ``bool`` targets.
## Dispatches to the matching coercion for ``T`` from the given source.
proc extract*[T](
  req: Request,
  source: RequestFieldSource,
  name: string,
  required: bool = true,
  defaultValue: T = default(T)
): CoercionResult[T] =
  static:
    doAssert(T is string or T is int or T is bool,
      "unsupported extractor type; supported: string, int, bool")
  when T is string:
    let field = req.readFieldValue(source, name)
    if field.len == 0:
      if required:
        result.ok = false
        result.error = coercionError(source, name, "", "missing required field")
      else:
        result.ok = true
        result.value = defaultValue
    else:
      result.ok = true
      result.value = field
  elif T is int:
    result = req.coerceIntField(source, name, required = required, defaultValue = defaultValue)
  elif T is bool:
    result = req.coerceBoolField(source, name, required = required, defaultValue = defaultValue)

## Extract a query parameter as ``T``. See ``extract``.
proc queryAs*[T](
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: T = default(T)
): CoercionResult[T] {.inline.} =
  extract[T](req, rfsQuery, name, required = required, defaultValue = defaultValue)

## Extract a route parameter as ``T``. See ``extract``.
proc paramAs*[T](
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: T = default(T)
): CoercionResult[T] {.inline.} =
  extract[T](req, rfsParam, name, required = required, defaultValue = defaultValue)

## Extract a header value as ``T``. See ``extract`` and ``get``.
proc headerAs*[T](
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: T = default(T)
): CoercionResult[T] {.inline.} =
  extract[T](req, rfsHeader, name, required = required, defaultValue = defaultValue)

## Extract a cookie value as ``T``. See ``extract`` and ``cookie``.
proc cookieAs*[T](
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: T = default(T)
): CoercionResult[T] {.inline.} =
  extract[T](req, rfsCookie, name, required = required, defaultValue = defaultValue)

## Extract a local value as ``T``. See ``extract`` and ``local``.
proc localAs*[T](
  req: Request,
  name: string,
  required: bool = true,
  defaultValue: T = default(T)
): CoercionResult[T] {.inline.} =
  extract[T](req, rfsLocal, name, required = required, defaultValue = defaultValue)
