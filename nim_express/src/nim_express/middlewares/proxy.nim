## Reverse proxy middleware.

import std/[asyncdispatch, httpclient, httpcore, strutils, uri, nativesockets, net, monotimes]
import common
import nim_utils/helpers/simd_str
from logger import sanitizeLogField

const
  DefaultProxyMaxRequestBytes* = 8 * 1024 * 1024
  DefaultProxyMaxResponseBytes* = 16 * 1024 * 1024

type
  ProxyTargetResolver* = proc(req: Req): string {.closure.}

  ProxyPathRewriter* = proc(path: string): string {.closure.}

  ProxyOptions* = object
    target*: string
    targetResolver*: ProxyTargetResolver
    timeoutMs*: int
    stripPrefix*: string
    pathRewriter*: ProxyPathRewriter
    preserveHostHeader*: bool
    addXForwardedHeaders*: bool
    blockPrivateUpstreams*: bool
      ## Block requests to private/internal IP addresses (RFC 1918, link-local,
      ## loopback, CGNAT). Enabled by default. Resolves DNS and validates
      ## resolved IPs against CIDR ranges to prevent DNS rebinding attacks.
      ## Note: normalizeProxyOptions() forces this to true unless
      ## allowPrivateUpstreams is set, so setting it to false here has no effect.
    allowPrivateUpstreams*: bool
      ## Explicitly permit private/internal upstreams. This is intended for
      ## trusted local deployments and tests; partial option literals do not
      ## disable blockPrivateUpstreams unless this is set.
    allowUnpinnedDnsUpstreams*: bool
      ## Permit hostname upstreams when blockPrivateUpstreams is enabled. This
      ## preserves legacy behavior but cannot prevent DNS rebinding because
      ## AsyncHttpClient resolves the hostname again during the actual request.
    maxRequestBytes*: int
      ## Maximum request body bytes forwarded upstream. Non-positive values use
      ## DefaultProxyMaxRequestBytes.
    maxResponseBytes*: int
      ## Maximum upstream response body bytes sent downstream. Non-positive
      ## values use DefaultProxyMaxResponseBytes.

## Return proxy options with secure defaults.
proc defaultProxyOptions*(): ProxyOptions {.inline.} =
  ProxyOptions(
    target: "",
    targetResolver: nil,
    timeoutMs: 30_000,
    stripPrefix: "",
    pathRewriter: nil,
    preserveHostHeader: false,
    addXForwardedHeaders: true,
    blockPrivateUpstreams: true,
    allowPrivateUpstreams: false,
    allowUnpinnedDnsUpstreams: false,
    maxRequestBytes: DefaultProxyMaxRequestBytes,
    maxResponseBytes: DefaultProxyMaxResponseBytes
  )

## Return proxy options targeting the given upstream `target` URL.
proc initProxyOptions*(target: string): ProxyOptions {.inline.} =
  ## Build proxy options from secure defaults.
  result = defaultProxyOptions()
  result.target = target

proc normalizeProxyOptions(options: ProxyOptions): ProxyOptions {.inline.} =
  result = options
  if result.timeoutMs <= 0:
    result.timeoutMs = 30_000
  if result.maxRequestBytes <= 0:
    result.maxRequestBytes = DefaultProxyMaxRequestBytes
  if result.maxResponseBytes <= 0:
    result.maxResponseBytes = DefaultProxyMaxResponseBytes
  if result.allowPrivateUpstreams:
    result.blockPrivateUpstreams = false
  else:
    result.blockPrivateUpstreams = true

proc resolveUpstreamUrl(opts: ProxyOptions, req: Req): string =
  var base =
    if opts.targetResolver != nil:
      opts.targetResolver(req)
    else:
      opts.target

  if base.len == 0:
    return ""

  # Remove trailing slash from base.
  if base.endsWith("/"):
    base.setLen(base.len - 1)

  var path = $req.path

  # Strip prefix if configured.
  if opts.stripPrefix.len > 0 and path.len >= opts.stripPrefix.len and
      simdStrEquals(unsafeAddr path[0], unsafeAddr opts.stripPrefix[0], opts.stripPrefix.len):
    path = path[opts.stripPrefix.len .. ^1]
    if path.len == 0 or path[0] != '/':
      path = "/" & path

  # Apply custom path rewriter.
  if opts.pathRewriter != nil:
    path = opts.pathRewriter(path)

  let rawQuery = $req.rawQuery()
  if rawQuery.len > 0:
    base & path & "?" & rawQuery
  else:
    base & path

proc toHttpMethod(req: Req): httpcore.HttpMethod {.inline.} =
  case req.methodKind
  of hmGet: httpcore.HttpGet
  of hmPost: httpcore.HttpPost
  of hmPut: httpcore.HttpPut
  of hmDelete: httpcore.HttpDelete
  of hmPatch: httpcore.HttpPatch
  of hmHead: httpcore.HttpHead
  of hmOptions: httpcore.HttpOptions
  of hmConnect: httpcore.HttpConnect
  of hmTrace: httpcore.HttpTrace

proc shouldForwardRequestBody(methodKind: nim_usockets.HttpMethod): bool {.inline.} =
  methodKind in {hmPost, hmPut, hmPatch, hmDelete}

proc effectiveMaxRequestBytes(opts: ProxyOptions): int {.inline.} =
  if opts.maxRequestBytes > 0: opts.maxRequestBytes else: DefaultProxyMaxRequestBytes

proc effectiveMaxResponseBytes(opts: ProxyOptions): int {.inline.} =
  if opts.maxResponseBytes > 0: opts.maxResponseBytes else: DefaultProxyMaxResponseBytes

proc clearProxyGeneratedResponseMetadata(res: Res) {.inline.} =
  if res == nil:
    return
  if res.headers != nil:
    res.headers.clear()
  res.headersInited = false
  res.setCookies.setLen(0)

proc sendProxyGeneratedError(res: Res, statusCode: int, body: string) {.inline.} =
  if res == nil or res.finished:
    return
  clearProxyGeneratedResponseMetadata(res)
  res.status(statusCode)
  res.set("Content-Type", "application/json; charset=utf-8")
  res.send(body)

proc parseKnownLength(value: string): int =
  let stripped = value.strip()
  if stripped.len == 0:
    return -1
  try:
    result = parseInt(stripped)
    if result < 0:
      return -1
  except ValueError:
    result = -1

proc requestBodyTooLarge(req: Req, maxBytes: int): bool =
  if req == nil or not shouldForwardRequestBody(req.methodKind):
    return false
  let declaredLen = parseKnownLength(req.get("content-length"))
  if declaredLen > maxBytes:
    return true
  let sizeHint = req.rawBodySizeHint()
  sizeHint >= 0 and sizeHint > maxBytes

proc upstreamRequestBody(req: Req, maxBytes: int): tuple[ok: bool, body: string] =
  if not shouldForwardRequestBody(req.methodKind):
    return (true, "")
  if requestBodyTooLarge(req, maxBytes):
    return (false, "")
  let body = req.rawBody()
  if body.len > maxBytes:
    return (false, "")
  (true, body)

proc upstreamRequestBody(req: Req): string {.inline, used.} =
  let checked = upstreamRequestBody(req, DefaultProxyMaxRequestBytes)
  if checked.ok: checked.body else: ""

proc responseContentLength(headers: HttpHeaders): int =
  for key, value in headers.pairs():
    if key.cmpIgnoreCase("content-length") == 0:
      return parseKnownLength(value)
  -1

proc upstreamResponseTooLarge(headers: HttpHeaders, bodyLen: int, maxBytes: int): bool =
  let declaredLen = responseContentLength(headers)
  declaredLen > maxBytes or bodyLen > maxBytes

proc readResponseBodyWithLimit(response: AsyncResponse, maxBytes: int): Future[tuple[ok: bool, body: string]] {.async.} =
  var body = newStringOfCap(min(maxBytes, 8192))
  while true:
    let (hasValue, chunk) = await response.bodyStream.read()
    if not hasValue:
      break
    if chunk.len > maxBytes - body.len:
      return (false, "")
    body.add(chunk)
  (true, body)

proc parseIPv4ToUint32(ip: string): tuple[ok: bool, val: uint32] =
  if ip.len > 15:
    # Longest valid IPv4 literal is "255.255.255.255"; longer input is invalid
    # and would risk integer overflow in the accumulator below.
    return (false, 0'u32)
  var parts: array[4, int]
  var partIdx = 0
  var num = 0
  var hasDigit = false
  for c in ip:
    if c == '.':
      if not hasDigit or partIdx >= 3:
        return (false, 0'u32)
      if num > 255:
        return (false, 0'u32)
      parts[partIdx] = num
      inc partIdx
      num = 0
      hasDigit = false
    elif c >= '0' and c <= '9':
      num = num * 10 + (ord(c) - ord('0'))
      hasDigit = true
    else:
      return (false, 0'u32)
  if not hasDigit or partIdx != 3 or num > 255:
    return (false, 0'u32)
  parts[3] = num
  let val = (uint32(parts[0]) shl 24) or (uint32(parts[1]) shl 16) or
            (uint32(parts[2]) shl 8) or uint32(parts[3])
  (true, val)

proc inCIDR(ip: uint32, network: uint32, prefixLen: int): bool {.inline.} =
  let mask = if prefixLen == 0: 0'u32 else: (0xFFFFFFFF'u32 shl (32 - prefixLen))
  (ip and mask) == (network and mask)

proc isPrivateIPv4(ip: uint32): bool {.inline.} =
  inCIDR(ip, 0x0A000000'u32, 8) or
  inCIDR(ip, 0xAC100000'u32, 12) or
  inCIDR(ip, 0xC0A80000'u32, 16) or
  inCIDR(ip, 0x7F000000'u32, 8) or
  inCIDR(ip, 0xA9FE0000'u32, 16) or
  inCIDR(ip, 0x64400000'u32, 10) or
  inCIDR(ip, 0xC6120000'u32, 15) or
  inCIDR(ip, 0x00000000'u32, 8) or
  inCIDR(ip, 0xC0000000'u32, 24) or
  inCIDR(ip, 0xC0000200'u32, 24) or
  inCIDR(ip, 0xC6336400'u32, 24) or
  inCIDR(ip, 0xCB007100'u32, 24) or
  inCIDR(ip, 0xE0000000'u32, 4) or
  inCIDR(ip, 0xF0000000'u32, 4) or
  ip == 0xFFFFFFFF'u32

proc isPrivateIPv6Str(h: string): bool {.inline.} =
  let stripped = h.strip(chars = {'[', ']'}).toLowerAscii()
  stripped == "::1" or stripped == "::" or
  stripped.startsWith("fc") or stripped.startsWith("fd") or
  stripped.startsWith("fe8") or stripped.startsWith("fe9") or
  stripped.startsWith("fea") or stripped.startsWith("feb") or
  stripped.startsWith("ff") or stripped.startsWith("::ffff:") or
  stripped.startsWith("2001:db8") or
  stripped == "0:0:0:0:0:0:0:0" or stripped == "0:0:0:0:0:0:0:1"

proc isIpLiteralHost(host: string): bool =
  let stripped = host.strip(chars = {'[', ']'})
  if stripped.len == 0:
    return false
  try:
    discard parseIpAddress(stripped)
    return true
  except ValueError:
    discard
  parseIPv4ToUint32(stripped).ok

proc isPrivateHost(host: string): bool =
  let h = host.toLowerAscii()
  if h == "localhost" or h.endsWith(".localhost") or
     h.endsWith(".local") or h.endsWith(".internal"):
    return true
  if h.startsWith("[") or h.contains(':'):
    # RFC 3986: a host containing ':' is an IP literal. URI parsers may strip
    # the brackets from "[::1]", so handle unbracketed IPv6 literals too.
    return isPrivateIPv6Str(h)
  let parsed = parseIPv4ToUint32(h)
  if parsed.ok:
    return isPrivateIPv4(parsed.val)
  false

proc resolveAndValidateHost(host: string): bool =
  ## Known limitation: getAddrInfo is a blocking syscall; under load it stalls
  ## the event loop for the duration of DNS resolution. A non-blocking fix
  ## requires async DNS or a resolver thread pool (architectural change).
  if host.len == 0:
    return true
  if isPrivateHost(host):
    return true
  try:
    let addrs = getAddrInfo(host, Port(0), AF_UNSPEC)
    var info = addrs
    defer: freeAddrInfo(addrs)
    while info != nil:
      if info.ai_family == nativesockets.AF_INET.cint:
        let sockAddr = cast[ptr Sockaddr_in](info.ai_addr)
        let b = cast[ptr array[4, uint8]](addr sockAddr.sin_addr)
        let ipVal = (uint32(b[0]) shl 24) or (uint32(b[1]) shl 16) or
                    (uint32(b[2]) shl 8) or uint32(b[3])
        if isPrivateIPv4(ipVal):
          return true
      elif info.ai_family == nativesockets.AF_INET6.cint:
        let sockAddr6 = cast[ptr Sockaddr_in6](info.ai_addr)
        let bytes = cast[ptr array[16, uint8]](addr sockAddr6.sin6_addr)
        var allZero10 = true
        for i in 0..9:
          if bytes[i] != 0: allZero10 = false; break
        if allZero10 and bytes[10] == 0xFF and bytes[11] == 0xFF:
          let ipVal = (uint32(bytes[12]) shl 24) or (uint32(bytes[13]) shl 16) or
                      (uint32(bytes[14]) shl 8) or uint32(bytes[15])
          if isPrivateIPv4(ipVal):
            return true
        var allZero = true
        for i in 0..15:
          if bytes[i] != 0: allZero = false; break
        if allZero:
          return true
        if allZero10 and bytes[10] == 0 and bytes[11] == 0 and
           bytes[12] == 0 and bytes[13] == 0 and bytes[14] == 0 and bytes[15] == 1:
          return true
        if bytes[0] == 0xFC or bytes[0] == 0xFD:
          return true
        if bytes[0] == 0xFE and (bytes[1] and 0xC0) == 0x80:
          return true
        if bytes[0] == 0xFF:
          return true
        if bytes[0] == 0x20 and bytes[1] == 0x01 and
           bytes[2] == 0x0D and bytes[3] == 0xB8:
          return true
      info = info.ai_next
    false
  except OSError:
    true

proc shouldRejectUnpinnedDnsHost(host: string, opts: ProxyOptions): bool {.inline.} =
  opts.blockPrivateUpstreams and
    not opts.allowUnpinnedDnsUpstreams and
    not isIpLiteralHost(host)

proc hasUnsafeUrlChars(url: string): bool {.inline.} =
  for c in url:
    if ord(c) < 0x20 or ord(c) == 0x7F:
      return true
  false

const HopByHopHeaders = [
  "connection", "keep-alive", "transfer-encoding", "upgrade",
  "proxy-connection", "te", "trailer", "proxy-authorization",
  "proxy-authenticate"
]

proc isHopByHopHeader(name: string): bool {.inline.} =
  ## Caller must pass a lowercased header name; comparison is case-sensitive.
  for blocked in HopByHopHeaders:
    if name == blocked:
      return true
  false

proc isForwardedMetadataHeader(name: string): bool {.inline.} =
  name == "forwarded" or name == "x-real-ip" or name.startsWith("x-forwarded-")

proc addConnectionHeaderTokens(value: string, tokens: var seq[string]) =
  var start = 0
  for i in 0 .. value.len:
    if i == value.len or value[i] == ',':
      let token = value[start ..< i].strip().toLowerAscii()
      if token.len > 0 and token notin tokens:
        tokens.add(token)
      start = i + 1

proc connectionListedHeader(name: string, tokens: openArray[string]): bool {.inline.} =
  for token in tokens:
    if name == token:
      return true
  false

proc connectionTokensFromRequestHeaders(headers: FastMap[string]): seq[string] =
  if headers == nil:
    return
  for key, value in headers.pairs():
    if key.cmpIgnoreCase("connection") == 0:
      addConnectionHeaderTokens(value, result)

proc connectionTokensFromResponseHeaders(headers: HttpHeaders): seq[string] =
  for key, value in headers.pairs():
    if key.cmpIgnoreCase("connection") == 0:
      addConnectionHeaderTokens(value, result)

proc shouldSkipRequestHeader(name: string, preserveHostHeader: bool): bool {.inline.} =
  if isHopByHopHeader(name) or isForwardedMetadataHeader(name) or name == "content-length":
    return true
  (not preserveHostHeader) and name == "host"

proc shouldSkipRequestHeader(name: string, preserveHostHeader: bool, connectionTokens: openArray[string]): bool {.inline.} =
  shouldSkipRequestHeader(name, preserveHostHeader) or connectionListedHeader(name, connectionTokens)

proc shouldSkipResponseHeader(name: string): bool {.inline.} =
  isHopByHopHeader(name) or name == "content-length"

proc shouldSkipResponseHeader(name: string, connectionTokens: openArray[string]): bool {.inline.} =
  shouldSkipResponseHeader(name) or connectionListedHeader(name, connectionTokens)

proc sanitizeRemoteIpForHeader(ip: string): string =
  ## Accept only characters valid in IPv4/IPv6 literals. Anything else (e.g.
  ## commas or control chars from a misconfigured fronting proxy) is dropped
  ## so a poisoned remoteIp cannot forge entries in the X-Forwarded-For chain.
  for c in ip:
    if not (c in {'0'..'9', 'a'..'f', 'A'..'F', '.', ':'}):
      return ""
  ip

proc setXForwardedHeaders(upstreamHeaders: HttpHeaders, req: Req) =
  let remoteIp = sanitizeRemoteIpForHeader(req.native.remoteIp)
  let trustedForwarded = req.forwardedHeadersTrusted()
  let existingForwardedFor =
    if trustedForwarded:
      req.get("x-forwarded-for")
    else:
      ""

  if existingForwardedFor.len > 0 and remoteIp.len > 0:
    upstreamHeaders["X-Forwarded-For"] = existingForwardedFor & ", " & remoteIp
  elif existingForwardedFor.len > 0:
    upstreamHeaders["X-Forwarded-For"] = existingForwardedFor
  else:
    upstreamHeaders["X-Forwarded-For"] = remoteIp

  upstreamHeaders["X-Forwarded-Proto"] = req.protocol()
  upstreamHeaders["X-Forwarded-Host"] = req.hostname()

proc buildUpstreamHeaders(req: Req, preserveHostHeader: bool, addForwardedHeaders: bool): HttpHeaders =
  result = newHttpHeaders()
  req.bindHeaders()
  let connectionTokens = connectionTokensFromRequestHeaders(req.headers)
  for key, value in req.headers.pairs():
    let lower = key.toLowerAscii()
    if shouldSkipRequestHeader(lower, preserveHostHeader, connectionTokens):
      continue
    result.add(key, value)
  if addForwardedHeaders:
    setXForwardedHeaders(result, req)

proc filterResponseHeaders(headers: HttpHeaders): HttpHeaders =
  result = newHttpHeaders()
  let connectionTokens = connectionTokensFromResponseHeaders(headers)
  for key, value in headers.pairs():
    let lower = key.toLowerAscii()
    if shouldSkipResponseHeader(lower, connectionTokens):
      continue
    result.add(key, value)

when defined(nimExpressProxySecurityTest):
  ## Test hook: `isPrivateHost`.
  proc proxyIsPrivateHostForTest*(host: string): bool = isPrivateHost(host)
  ## Test hook: `resolveAndValidateHost`.
  proc proxyResolveAndValidateHostForTest*(host: string): bool = resolveAndValidateHost(host)
  ## Test hook: `isIpLiteralHost`.
  proc proxyIsIpLiteralHostForTest*(host: string): bool = isIpLiteralHost(host)
  ## Test hook: `shouldRejectUnpinnedDnsHost` with a chosen `allowUnpinnedDnsUpstreams`.
  proc proxyShouldRejectUnpinnedDnsHostForTest*(host: string, allowUnpinnedDnsUpstreams: bool): bool =
    var opts = defaultProxyOptions()
    opts.allowUnpinnedDnsUpstreams = allowUnpinnedDnsUpstreams
    shouldRejectUnpinnedDnsHost(host, opts)
  ## Test hook: `hasUnsafeUrlChars`.
  proc proxyHasUnsafeUrlCharsForTest*(url: string): bool = hasUnsafeUrlChars(url)
  ## Test hook: `shouldSkipRequestHeader` for a lowercased header `name`.
  proc proxyShouldSkipRequestHeaderForTest*(name: string, preserveHostHeader: bool): bool =
    shouldSkipRequestHeader(name.toLowerAscii(), preserveHostHeader)
  ## Test hook: `shouldSkipResponseHeader` for a lowercased header `name`.
  proc proxyShouldSkipResponseHeaderForTest*(name: string): bool =
    shouldSkipResponseHeader(name.toLowerAscii())
  ## Test hook: `setXForwardedHeaders` writing into a fresh header set.
  proc proxySetXForwardedHeadersForTest*(req: Req): HttpHeaders =
    result = newHttpHeaders()
    setXForwardedHeaders(result, req)
  ## Test hook: `buildUpstreamHeaders`.
  proc proxyBuildUpstreamHeadersForTest*(
    req: Req,
    preserveHostHeader: bool,
    addForwardedHeaders: bool
  ): HttpHeaders =
    buildUpstreamHeaders(req, preserveHostHeader, addForwardedHeaders)
  ## Test hook: `filterResponseHeaders`.
  proc proxyFilterResponseHeadersForTest*(headers: HttpHeaders): HttpHeaders =
    filterResponseHeaders(headers)
  ## Test hook: `shouldForwardRequestBody`.
  proc proxyShouldForwardRequestBodyForTest*(methodKind: nim_usockets.HttpMethod): bool =
    shouldForwardRequestBody(methodKind)
  ## Test hook: `upstreamRequestBody` using the default request size limit.
  proc proxyUpstreamRequestBodyForTest*(req: Req): string =
    upstreamRequestBody(req)
  ## Test hook: `requestBodyTooLarge`.
  proc proxyRequestBodyTooLargeForTest*(req: Req, maxBytes: int): bool =
    requestBodyTooLarge(req, maxBytes)
  ## Test hook: `upstreamRequestBody` with an explicit `maxBytes` limit.
  proc proxyUpstreamRequestBodyForTest*(req: Req, maxBytes: int): tuple[ok: bool, body: string] =
    upstreamRequestBody(req, maxBytes)
  ## Test hook: `upstreamResponseTooLarge`.
  proc proxyUpstreamResponseTooLargeForTest*(headers: HttpHeaders, bodyLen: int, maxBytes: int): bool =
    upstreamResponseTooLarge(headers, bodyLen, maxBytes)
  ## Test hook: `readResponseBodyWithLimit` driven by a raw body stream.
  proc proxyReadResponseBodyWithLimitForTest*(
    stream: FutureStream[string],
    maxBytes: int
  ): Future[tuple[ok: bool, body: string]] {.async.} =
    let response = AsyncResponse(
      version: "1.1",
      status: "200 OK",
      headers: newHttpHeaders(),
      bodyStream: stream
    )
    result = await readResponseBodyWithLimit(response, maxBytes)
  ## Test hook: `sendProxyGeneratedError`.
  proc proxySendGeneratedErrorForTest*(res: Res, statusCode: int, body: string) =
    sendProxyGeneratedError(res, statusCode, body)

## Forward requests to an upstream backend server.
proc proxy*(
  options: ProxyOptions = defaultProxyOptions()
): AsyncMiddleware =
  ## Forward requests to an upstream backend server.
  ##
  ## Opens one upstream connection per request and resolves DNS on the event
  ## loop, so keep-alive connections are not reused. Use `fastProxy` for pooled
  ## upstream connections and offloaded DNS resolution.
  let opts = normalizeProxyOptions(options)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if req.methodKind == hmConnect or req.methodKind == hmTrace:
      if not res.finished:
        res.status(405)
        res.set("Content-Type", "application/json; charset=utf-8")
        res.send("""{"error":"Method Not Allowed"}""")
      return

    let upstreamUrl = resolveUpstreamUrl(opts, req)
    if upstreamUrl.len == 0:
      await next()
      return
    if hasUnsafeUrlChars(upstreamUrl):
      if not res.finished:
        res.status(502)
        res.set("Content-Type", "application/json; charset=utf-8")
        res.send("""{"error":"Bad Gateway: invalid upstream URL"}""")
      return

    let parsedUpstream = parseUri(upstreamUrl)

    if parsedUpstream.scheme != "http" and parsedUpstream.scheme != "https":
      if not res.finished:
        res.status(502)
        res.set("Content-Type", "application/json; charset=utf-8")
        res.send("""{"error":"Bad Gateway: invalid upstream scheme"}""")
      return

    if opts.blockPrivateUpstreams:
      if shouldRejectUnpinnedDnsHost(parsedUpstream.hostname, opts):
        if not res.finished:
          res.status(403)
          res.set("Content-Type", "application/json; charset=utf-8")
          res.send("""{"error":"Forbidden"}""")
        return
      if resolveAndValidateHost(parsedUpstream.hostname):
        if not res.finished:
          res.status(403)
          res.set("Content-Type", "application/json; charset=utf-8")
          res.send("""{"error":"Forbidden"}""")
        return

    let client = newAsyncHttpClient(maxRedirects = 0)

    try:
      let upstreamHeaders = buildUpstreamHeaders(req, opts.preserveHostHeader, opts.addXForwardedHeaders)
      let requestMaxBytes = effectiveMaxRequestBytes(opts)
      if requestBodyTooLarge(req, requestMaxBytes):
        if not res.finished:
          res.status(413)
          res.set("Content-Type", "application/json; charset=utf-8")
          res.send("""{"error":"Payload Too Large"}""")
        return

      let checkedBody = upstreamRequestBody(req, requestMaxBytes)
      if not checkedBody.ok:
        if not res.finished:
          res.status(413)
          res.set("Content-Type", "application/json; charset=utf-8")
          res.send("""{"error":"Payload Too Large"}""")
        return
      let body = checkedBody.body

      let upstreamMethod = toHttpMethod(req)
      let requestStart = getMonoTime()
      let responseFut = client.request(
        url = upstreamUrl,
        httpMethod = upstreamMethod,
        headers = upstreamHeaders,
        body = body
      )
      let completed = await withTimeout(responseFut, opts.timeoutMs)
      if not completed:
        # Abort the in-flight upstream connection immediately instead of
        # waiting for the finally block.
        client.close()
        if not res.finished:
          res.status(504)
          res.set("Content-Type", "application/json; charset=utf-8")
          res.send("""{"error":"Gateway Timeout"}""")
        return
      let upstreamResp = responseFut.read()

      let statusStr = upstreamResp.status.split(' ')[0]
      let statusCode = try: parseInt(statusStr) except ValueError: 502

      let responseMaxBytes = effectiveMaxResponseBytes(opts)
      if upstreamResponseTooLarge(upstreamResp.headers, 0, responseMaxBytes):
        if not res.finished:
          res.status(502)
          res.set("Content-Type", "application/json; charset=utf-8")
          res.send("""{"error":"Bad Gateway: upstream response too large"}""")
        return
      let responseHeaders = filterResponseHeaders(upstreamResp.headers)
      for key, value in responseHeaders.pairs():
        res.set(key, value)

      let elapsedMs = int((getMonoTime() - requestStart).inMilliseconds)
      let bodyTimeoutMs = max(opts.timeoutMs - elapsedMs, 1000)
      let bodyFut = readResponseBodyWithLimit(upstreamResp, responseMaxBytes)
      let bodyCompleted = await withTimeout(bodyFut, bodyTimeoutMs)
      if not bodyCompleted:
        client.close()
        sendProxyGeneratedError(
          res,
          504,
          """{"error":"Gateway Timeout"}"""
        )
        return
      let limitedBody = bodyFut.read()
      if not limitedBody.ok:
        sendProxyGeneratedError(
          res,
          502,
          """{"error":"Bad Gateway: upstream response too large"}"""
        )
        return
      # Status is set only after the body is validated so error paths above
      # never observe a partially populated response state.
      res.status(statusCode)
      res.send(limitedBody.body)

    except OSError as e:
      stderr.writeLine("[proxy] OS error ", $req.methodKind, " ", sanitizeLogField($req.path), ": ", sanitizeLogField(e.msg))
      sendProxyGeneratedError(res, 502, """{"error":"Bad Gateway"}""")
    except CatchableError as e:
      stderr.writeLine("[proxy] upstream error ", $req.methodKind, " ", sanitizeLogField($req.path), ": ", sanitizeLogField(e.msg))
      sendProxyGeneratedError(res, 502, """{"error":"Bad Gateway"}""")
    finally:
      client.close()
