import std/[asyncdispatch, strutils, uri, nativesockets, net, times]
import common
import ../offload
import nim_fasthttpclient/client as fastclient
import nim_fasthttpclient/types as fasttypes

const
  DefaultFastProxyRequestTimeoutMs* = 30_000
  DefaultFastProxyConnectTimeoutMs* = 5_000
  DefaultFastProxyMaxRequestBytes* = 8 * 1024 * 1024
  DefaultFastProxyMaxResponseBytes* = 16 * 1024 * 1024

type
  FastProxyTargetResolver* = proc(req: Req): string {.closure.}

  FastProxyPathRewriter* = proc(path: string): string {.closure.}

  FastProxyHostValidation* = enum
    ## hostPublic: the host is a public IP literal or all resolved addresses
    ## are public.
    hostPublic
    ## hostPrivate: the host name or a resolved address is private/internal.
    hostPrivate
    ## hostResolutionFailed: the DNS lookup failed (NXDOMAIN, SERVFAIL,
    ## resolver unreachable, ...). This is distinct from hostPrivate so
    ## callers can answer 502 instead of 403 when DNS itself is down.
    hostResolutionFailed

  FastProxyConnectionToken = object
    ## A comma-separated token inside a Connection header value, kept as an
    ## in-string slice so token extraction performs no per-token allocation.
    value: string
    start: int
    finish: int

  FastProxyOptions* = object
    target*: string
    targetResolver*: FastProxyTargetResolver
    timeoutMs*: int
      ## Upper bound for the upstream request. Defaults to 30s.
    connectTimeoutMs*: int
      ## Upper bound for the upstream TCP connect. Defaults to 5s.
    stripPrefix*: string
    pathRewriter*: FastProxyPathRewriter
    preserveHostHeader*: bool
    addXForwardedHeaders*: bool
    blockPrivateUpstreams*: bool
      ## Block requests to private/internal IP addresses (RFC 1918, link-local,
      ## loopback, CGNAT). Enabled by default to match proxy(). To disable
      ## blocking, set allowPrivateUpstreams, or set this field to false
      ## together with blockPrivateUpstreamsExplicit.
    blockPrivateUpstreamsExplicit*: bool
      ## Marks blockPrivateUpstreams as user-provided. When false (the
      ## default), normalizeFastProxyOptions forces blockPrivateUpstreams to
      ## true unless allowPrivateUpstreams is set, so a bare object literal
      ## cannot accidentally disable SSRF protection.
    allowPrivateUpstreams*: bool
      ## Explicitly permit private/internal upstreams for trusted local
      ## deployments. Takes precedence over blockPrivateUpstreams.
    allowUnpinnedDnsUpstreams*: bool
      ## Permit hostname upstreams when blockPrivateUpstreams is enabled. This
      ## preserves legacy behavior but cannot prevent DNS rebinding unless the
      ## underlying client pins the validated address.
    maxRequestBytes*: int
      ## Maximum request body bytes forwarded upstream. Non-positive values use
      ## DefaultFastProxyMaxRequestBytes.
    maxResponseBytes*: int
      ## Maximum upstream response body bytes sent downstream. Non-positive
      ## values use DefaultFastProxyMaxResponseBytes.
    client*: ptr fasttypes.HttpClient
    loop*: UsLoopPtr

## Create a `FastProxyOptions` with the default secure configuration.
proc defaultFastProxyOptions*(): FastProxyOptions {.inline.} =
  FastProxyOptions(
    target: "",
    targetResolver: nil,
    timeoutMs: DefaultFastProxyRequestTimeoutMs,
    connectTimeoutMs: DefaultFastProxyConnectTimeoutMs,
    stripPrefix: "",
    pathRewriter: nil,
    preserveHostHeader: false,
    addXForwardedHeaders: true,
    blockPrivateUpstreams: true,
    blockPrivateUpstreamsExplicit: false,
    allowPrivateUpstreams: false,
    allowUnpinnedDnsUpstreams: false,
    maxRequestBytes: DefaultFastProxyMaxRequestBytes,
    maxResponseBytes: DefaultFastProxyMaxResponseBytes,
    client: nil,
    loop: nil,
  )

## Create `FastProxyOptions` preloaded with the given upstream target URL.
proc initFastProxyOptions*(target: string): FastProxyOptions {.inline.} =
  ## Build fast proxy options from secure defaults.
  result = defaultFastProxyOptions()
  result.target = target

proc normalizeFastProxyOptions(options: FastProxyOptions): FastProxyOptions {.inline.} =
  result = options
  if result.timeoutMs <= 0:
    result.timeoutMs = DefaultFastProxyRequestTimeoutMs
  if result.connectTimeoutMs <= 0:
    result.connectTimeoutMs = DefaultFastProxyConnectTimeoutMs
  if result.maxRequestBytes <= 0:
    result.maxRequestBytes = DefaultFastProxyMaxRequestBytes
  if result.maxResponseBytes <= 0:
    result.maxResponseBytes = DefaultFastProxyMaxResponseBytes
  if result.allowPrivateUpstreams:
    result.blockPrivateUpstreams = false
  elif not result.blockPrivateUpstreamsExplicit:
    result.blockPrivateUpstreams = true

proc mapHttpMethod(m: nim_usockets.HttpMethod): tuple[ok: bool, mapped: fasttypes.HttpMethod] {.inline.} =
  case m
  of nim_usockets.hmGet: (true, fasttypes.hmGet)
  of nim_usockets.hmPost: (true, fasttypes.hmPost)
  of nim_usockets.hmPut: (true, fasttypes.hmPut)
  of nim_usockets.hmDelete: (true, fasttypes.hmDelete)
  of nim_usockets.hmPatch: (true, fasttypes.hmPatch)
  of nim_usockets.hmHead: (true, fasttypes.hmHead)
  of nim_usockets.hmOptions: (true, fasttypes.hmOptions)
  of nim_usockets.hmConnect, nim_usockets.hmTrace: (false, fasttypes.hmGet)

proc resolveUpstreamUrl(opts: FastProxyOptions, req: Req): string =
  var base =
    if opts.targetResolver != nil:
      opts.targetResolver(req)
    else:
      opts.target

  if base.len == 0:
    return ""

  var baseLen = base.len
  if baseLen > 0 and base[baseLen - 1] == '/':
    baseLen -= 1

  var path = $req.path

  if opts.stripPrefix.len > 0 and path.startsWith(opts.stripPrefix):
    path = path[opts.stripPrefix.len .. ^1]
    if path.len == 0 or path[0] != '/':
      path = "/" & path

  if opts.pathRewriter != nil:
    path = opts.pathRewriter(path)

  let rawQuery = $req.rawQuery()
  let totalLen = baseLen + path.len + (if rawQuery.len > 0: 1 + rawQuery.len else: 0)
  result = newStringOfCap(totalLen)
  if baseLen == base.len:
    result.add base
  else:
    result.add base[0 ..< baseLen]
  result.add path
  if rawQuery.len > 0:
    result.add '?'
    result.add rawQuery

const HopByHopHeaders = [
  "connection", "keep-alive", "transfer-encoding", "upgrade",
  "proxy-connection", "te", "trailer", "proxy-authorization",
  "proxy-authenticate"
]

proc cmpIgnoreCase(a, b: string): bool {.inline.} =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    let ca = a[i]
    let la = if ca >= 'A' and ca <= 'Z': chr(ord(ca) + 32) else: ca
    let cb = b[i]
    let lb = if cb >= 'A' and cb <= 'Z': chr(ord(cb) + 32) else: cb
    if la != lb: return false
  true

proc isHopByHop(name: string): bool {.inline.} =
  for h in HopByHopHeaders:
    if cmpIgnoreCase(name, h): return true
  false

proc startsWithIgnoreCase(value, prefix: string): bool {.inline.} =
  if value.len < prefix.len:
    return false
  for i in 0 ..< prefix.len:
    let ca = value[i]
    let la = if ca >= 'A' and ca <= 'Z': chr(ord(ca) + 32) else: ca
    let cb = prefix[i]
    let lb = if cb >= 'A' and cb <= 'Z': chr(ord(cb) + 32) else: cb
    if la != lb:
      return false
  true

proc isForwardedMetadataHeader(name: string): bool {.inline.} =
  cmpIgnoreCase(name, "forwarded") or
  cmpIgnoreCase(name, "x-real-ip") or
  startsWithIgnoreCase(name, "x-forwarded-")

proc collectConnectionTokens(value: string, tokens: var seq[FastProxyConnectionToken]) {.inline.} =
  var start = 0
  for i in 0 .. value.len:
    if i == value.len or value[i] == ',':
      tokens.add(FastProxyConnectionToken(value: value, start: start, finish: i))
      start = i + 1

proc connectionTokenMatches(token: FastProxyConnectionToken, name: string): bool {.inline.} =
  var i = token.start
  var j = token.finish - 1
  while i < token.finish and token.value[i] <= ' ':
    inc i
  while j >= i and token.value[j] <= ' ':
    dec j
  if name.len != j - i + 1:
    return false
  for k in 0 ..< name.len:
    let ca = name[k]
    let la = if ca >= 'A' and ca <= 'Z': chr(ord(ca) + 32) else: ca
    let cb = token.value[i + k]
    let lb = if cb >= 'A' and cb <= 'Z': chr(ord(cb) + 32) else: cb
    if la != lb:
      return false
  true

proc connectionListedHeader(name: string, tokens: openArray[FastProxyConnectionToken]): bool {.inline.} =
  for token in tokens:
    if connectionTokenMatches(token, name):
      return true
  false

proc connectionTokensFromRequestHeaders(headers: FastMap[string]): seq[FastProxyConnectionToken] =
  if headers == nil:
    return
  for key, value in headers.pairs():
    if cmpIgnoreCase(key, "connection"):
      collectConnectionTokens(value, result)

proc connectionTokensFromResponseHeaders(headers: openArray[fasttypes.HttpHeader]): seq[FastProxyConnectionToken] =
  for hdr in headers:
    if cmpIgnoreCase(hdr.name, "connection"):
      collectConnectionTokens(hdr.value, result)

proc shouldSkipRequestHeader(name: string, preserveHostHeader: bool): bool {.inline.} =
  if isHopByHop(name) or isForwardedMetadataHeader(name) or cmpIgnoreCase(name, "content-length"):
    return true
  (not preserveHostHeader) and cmpIgnoreCase(name, "host")

proc shouldSkipRequestHeader(name: string, preserveHostHeader: bool, connectionTokens: openArray[FastProxyConnectionToken]): bool {.inline.} =
  shouldSkipRequestHeader(name, preserveHostHeader) or connectionListedHeader(name, connectionTokens)

proc shouldSkipResponseHeader(name: string): bool {.inline.} =
  isHopByHop(name) or cmpIgnoreCase(name, "content-length")

proc shouldSkipResponseHeader(name: string, connectionTokens: openArray[FastProxyConnectionToken]): bool {.inline.} =
  shouldSkipResponseHeader(name) or connectionListedHeader(name, connectionTokens)

proc hasUnsafeUrlChars(url: string): bool {.inline.} =
  # Reject all C0 control characters (0x00-0x1F), not just CRLF/NUL, to stop
  # request-line and header parsing inconsistencies in upstream servers.
  for c in url:
    if ord(c) < 32:
      return true
  false

proc effectiveRequestTimeoutMs(opts: FastProxyOptions): int {.inline.} =
  if opts.timeoutMs > 0: opts.timeoutMs else: DefaultFastProxyRequestTimeoutMs

proc effectiveConnectTimeoutMs(opts: FastProxyOptions): int {.inline.} =
  if opts.connectTimeoutMs > 0: opts.connectTimeoutMs else: DefaultFastProxyConnectTimeoutMs

proc effectiveMaxRequestBytes(opts: FastProxyOptions): int {.inline.} =
  if opts.maxRequestBytes > 0: opts.maxRequestBytes else: DefaultFastProxyMaxRequestBytes

proc effectiveMaxResponseBytes(opts: FastProxyOptions): int {.inline.} =
  if opts.maxResponseBytes > 0: opts.maxResponseBytes else: DefaultFastProxyMaxResponseBytes

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

proc shouldForwardRequestBody(methodKind: nim_usockets.HttpMethod): bool {.inline.} =
  methodKind in {nim_usockets.hmPost, nim_usockets.hmPut, nim_usockets.hmPatch, nim_usockets.hmDelete}

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

proc responseContentLength(headers: openArray[fasttypes.HttpHeader]): int =
  for hdr in headers:
    if cmpIgnoreCase(hdr.name, "content-length"):
      return parseKnownLength(hdr.value)
  -1

proc upstreamResponseTooLarge(headers: openArray[fasttypes.HttpHeader], bodyLen: int, maxBytes: int): bool =
  let declaredLen = responseContentLength(headers)
  declaredLen > maxBytes or bodyLen > maxBytes

proc filterResponseHeaders(headers: openArray[fasttypes.HttpHeader]): seq[fasttypes.HttpHeader] =
  result = newSeqOfCap[fasttypes.HttpHeader](headers.len)
  let connectionTokens = connectionTokensFromResponseHeaders(headers)
  for hdr in headers:
    if shouldSkipResponseHeader(hdr.name, connectionTokens):
      continue
    result.add(hdr)

proc configureClientTimeouts(client: ptr fasttypes.HttpClient, opts: FastProxyOptions) {.inline.} =
  if client == nil:
    return
  if opts.timeoutMs > 0 or client[].defaultTimeoutMs <= 0:
    client[].defaultTimeoutMs = effectiveRequestTimeoutMs(opts)
  if opts.connectTimeoutMs > 0 or client[].connectTimeoutMs <= 0:
    client[].connectTimeoutMs = effectiveConnectTimeoutMs(opts)

proc fastProxyResponseStillCurrent(res: Res, lifecycleToken: uint64, retFuture: Future[void]): bool {.inline.} =
  res.responseLifecycleTokenMatches(lifecycleToken) and not res.finished and
    (retFuture == nil or not retFuture.finished)

proc completeGatewayTimeout(res: Res, retFuture: Future[void], lifecycleToken: uint64) {.inline.} =
  if res.fastProxyResponseStillCurrent(lifecycleToken, retFuture):
    res.status(504)
    res.set("Content-Type", "application/json; charset=utf-8")
    res.send("""{"error":"Gateway Timeout"}""")
  if not retFuture.finished:
    retFuture.complete()

proc completeFastProxyUpstream(
  capturedRes: Res,
  capturedFuture: Future[void],
  lifecycleToken: uint64,
  resp: fasttypes.HttpResponse,
  err: string,
  responseMaxBytes: int
) =
  try:
    if not capturedRes.fastProxyResponseStillCurrent(lifecycleToken, capturedFuture):
      return
    if err.len > 0 or resp.statusCode == 0:
      capturedRes.status(502)
      capturedRes.set("Content-Type", "application/json; charset=utf-8")
      capturedRes.send("""{"error":"Bad Gateway"}""")
      return
    if upstreamResponseTooLarge(resp.headers, resp.body.len, responseMaxBytes):
      capturedRes.status(502)
      capturedRes.set("Content-Type", "application/json; charset=utf-8")
      capturedRes.send("""{"error":"Bad Gateway: upstream response too large"}""")
      return
    capturedRes.status(resp.statusCode)
    for hdr in filterResponseHeaders(resp.headers):
      capturedRes.set(hdr.name, hdr.value)
    capturedRes.send(resp.body)
  except CatchableError:
    if capturedRes.fastProxyResponseStillCurrent(lifecycleToken, capturedFuture):
      capturedRes.status(502)
      capturedRes.send("""{"error":"Bad Gateway"}""")
  finally:
    if not capturedFuture.finished:
      capturedFuture.complete()

proc armFastProxyTimeout(res: Res, retFuture: Future[void], timeoutMs: int, lifecycleToken: uint64) =
  let boundedTimeoutMs = max(1, timeoutMs)
  let timeoutFuture = sleepAsync(boundedTimeoutMs)
  timeoutFuture.addCallback proc () {.gcsafe.} =
    # Single-threaded event loop: sleepAsync callbacks always run on the loop
    # thread, so capturing res/retFuture is race-free; the lifecycle token
    # additionally guards against a recycled response.
    {.cast(gcsafe).}:
      if not retFuture.finished:
        completeGatewayTimeout(res, retFuture, lifecycleToken)

proc addXForwardedHeaders(upstreamHeaders: var seq[fasttypes.HttpHeader], req: Req) {.inline.} =
  let remoteIp = req.native.remoteIp
  let existingForwardedFor =
    if req.forwardedHeadersTrusted():
      req.get("x-forwarded-for")
    else:
      ""

  if existingForwardedFor.len > 0 and remoteIp.len > 0:
    upstreamHeaders.add(fasttypes.HttpHeader(
      name: "X-Forwarded-For",
      value: existingForwardedFor & ", " & remoteIp
    ))
  elif existingForwardedFor.len > 0:
    upstreamHeaders.add(fasttypes.HttpHeader(
      name: "X-Forwarded-For",
      value: existingForwardedFor
    ))
  else:
    upstreamHeaders.add(fasttypes.HttpHeader(
      name: "X-Forwarded-For",
      value: remoteIp
    ))

  upstreamHeaders.add(fasttypes.HttpHeader(
    name: "X-Forwarded-Proto",
    value: req.protocol()
  ))
  upstreamHeaders.add(fasttypes.HttpHeader(
    name: "X-Forwarded-Host",
    value: req.hostname()
  ))

proc parseIPv4ToUint32(ip: string): tuple[ok: bool, val: uint32] =
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

proc ipv4BytesToUint32(bytes: openArray[uint8]): uint32 {.inline.} =
  (uint32(bytes[0]) shl 24) or (uint32(bytes[1]) shl 16) or
  (uint32(bytes[2]) shl 8) or uint32(bytes[3])

proc isPrivateIPv6Bytes(bytes: openArray[uint8]): bool {.inline.} =
  var allZero10 = true
  for i in 0..9:
    if bytes[i] != 0:
      allZero10 = false
      break
  if allZero10 and bytes[10] == 0xFF and bytes[11] == 0xFF:
    return isPrivateIPv4(ipv4BytesToUint32(bytes[12 .. 15]))

  var allZero = true
  for i in 0..15:
    if bytes[i] != 0:
      allZero = false
      break
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
  bytes[0] == 0x20 and bytes[1] == 0x01 and
    bytes[2] == 0x0D and bytes[3] == 0xB8

proc isPrivateV4MappedIpv6Str(s: string): bool {.noSideEffect.} =
  # s is lowercase and starts with "::ffff:"; evaluate the embedded IPv4 part.
  if s.len <= 7:
    return true
  let parsed = parseIPv4ToUint32(s[7 .. ^1])
  if not parsed.ok:
    return true
  isPrivateIPv4(parsed.val)

proc isPrivateIPv6Str(h: string): bool {.inline.} =
  let stripped = h.strip(chars = {'[', ']'}).toLowerAscii()
  stripped == "::1" or stripped == "::" or
  stripped.startsWith("fc") or stripped.startsWith("fd") or
  stripped.startsWith("fe8") or stripped.startsWith("fe9") or
  stripped.startsWith("fea") or stripped.startsWith("feb") or
  stripped.startsWith("ff") or stripped.startsWith("2001:db8") or
  stripped == "0:0:0:0:0:0:0:0" or stripped == "0:0:0:0:0:0:0:1" or
  (stripped.startsWith("::ffff:") and isPrivateV4MappedIpv6Str(stripped))

proc isPrivateIpLiteral(host: string): bool =
  let stripped = host.strip(chars = {'[', ']'})
  try:
    let ip = parseIpAddress(stripped)
    case ip.family
    of IPv4:
      return isPrivateIPv4(ipv4BytesToUint32(ip.address_v4))
    of IPv6:
      return isPrivateIPv6Bytes(ip.address_v6)
  except ValueError:
    return false

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
     h.endsWith(".local") or h.endsWith(".internal") or
     h.endsWith(".onion"):
    return true
  if isPrivateIpLiteral(h):
    return true
  if h.startsWith("["):
    return isPrivateIPv6Str(h)
  let parsed = parseIPv4ToUint32(h)
  if parsed.ok:
    return isPrivateIPv4(parsed.val)
  false

proc resolveAndValidateHost(host: string): FastProxyHostValidation =
  if host.len == 0:
    return hostPrivate
  if isPrivateHost(host):
    return hostPrivate
  if isIpLiteralHost(host):
    return hostPublic
  try:
    let addrs = getAddrInfo(host, Port(0), AF_UNSPEC)
    var info = addrs
    defer: freeAddrInfo(addrs)
    while info != nil:
      if info.ai_family == nativesockets.AF_INET.cint:
        let sockAddr = cast[ptr Sockaddr_in](info.ai_addr)
        let b = cast[ptr array[4, uint8]](addr sockAddr.sin_addr)
        if isPrivateIPv4(ipv4BytesToUint32(b[])):
          return hostPrivate
      elif info.ai_family == nativesockets.AF_INET6.cint:
        let sockAddr6 = cast[ptr Sockaddr_in6](info.ai_addr)
        let bytes = cast[ptr array[16, uint8]](addr sockAddr6.sin6_addr)
        if isPrivateIPv6Bytes(bytes[]):
          return hostPrivate
      info = info.ai_next
    hostPublic
  except OSError:
    hostResolutionFailed

proc resolveHostOffload(host: string): FastProxyHostValidation {.gcsafe.} =
  # Runs on a malebolgia worker thread via runOffloadOutcome; the cast is
  # safe because the call is self-contained (getaddrinfo + pure checks) and
  # only a value enum crosses back to the event loop thread.
  {.cast(gcsafe).}:
    resolveAndValidateHost(host)

proc shouldRejectUnpinnedDnsHost(host: string, opts: FastProxyOptions): bool {.inline.} =
  opts.blockPrivateUpstreams and
    not opts.allowUnpinnedDnsUpstreams and
    not isIpLiteralHost(host)

proc resolvedIpLiteralsContainPrivate(ips: openArray[string]): bool {.used.} =
  for ip in ips:
    if isPrivateIpLiteral(ip):
      return true
  false

proc buildUpstreamHeaders(
  req: Req,
  preserveHostHeader: bool,
  addForwardedHeaders: bool
): seq[fasttypes.HttpHeader] =
  # The upstream client emits the Host header (HTTP/2: :authority) itself from
  # the request URL, so dropping the inbound Host here is intentional and the
  # upstream always receives a correct Host.
  result = newSeqOfCap[fasttypes.HttpHeader](16)
  req.bindHeaders()
  let connectionTokens = connectionTokensFromRequestHeaders(req.headers)
  for key, value in req.headers.pairs():
    if shouldSkipRequestHeader(key, preserveHostHeader, connectionTokens):
      continue
    result.add(fasttypes.HttpHeader(name: key, value: value))
  if addForwardedHeaders:
    result.addXForwardedHeaders(req)

when defined(nimExpressFastProxySecurityTest):
  ## Expose the private-host check to the security test suite.
  proc fastProxyIsPrivateHostForTest*(host: string): bool = isPrivateHost(host)
  ## Expose host DNS resolution and validation to the security test suite.
  proc fastProxyResolveAndValidateHostForTest*(host: string): FastProxyHostValidation =
    resolveAndValidateHost(host)
  ## Expose option normalization to the security test suite.
  proc fastProxyNormalizeOptionsForTest*(options: FastProxyOptions): FastProxyOptions =
    normalizeFastProxyOptions(options)
  ## Expose the IP literal host check to the security test suite.
  proc fastProxyIsIpLiteralHostForTest*(host: string): bool = isIpLiteralHost(host)
  ## Expose the unpinned DNS host rejection check to the security test suite.
  proc fastProxyShouldRejectUnpinnedDnsHostForTest*(host: string, allowUnpinnedDnsUpstreams: bool): bool =
    var opts = defaultFastProxyOptions()
    opts.allowUnpinnedDnsUpstreams = allowUnpinnedDnsUpstreams
    shouldRejectUnpinnedDnsHost(host, opts)
  ## Expose the resolved IP literal private check to the security test suite.
  proc fastProxyResolvedIpLiteralsContainPrivateForTest*(ips: openArray[string]): bool =
    resolvedIpLiteralsContainPrivate(ips)
  ## Expose the unsafe URL character check to the security test suite.
  proc fastProxyHasUnsafeUrlCharsForTest*(url: string): bool = hasUnsafeUrlChars(url)
  ## Expose the request header skip check to the security test suite.
  proc fastProxyShouldSkipRequestHeaderForTest*(name: string, preserveHostHeader: bool): bool =
    shouldSkipRequestHeader(name, preserveHostHeader)
  ## Expose the response header skip check to the security test suite.
  proc fastProxyShouldSkipResponseHeaderForTest*(name: string): bool =
    shouldSkipResponseHeader(name)
  ## Expose the X-Forwarded header builder to the security test suite.
  proc fastProxySetXForwardedHeadersForTest*(req: Req): seq[fasttypes.HttpHeader] =
    result = @[]
    addXForwardedHeaders(result, req)
  ## Expose the upstream header builder to the security test suite.
  proc fastProxyBuildUpstreamHeadersForTest*(
    req: Req,
    preserveHostHeader: bool,
    addForwardedHeaders: bool
  ): seq[fasttypes.HttpHeader] =
    buildUpstreamHeaders(req, preserveHostHeader, addForwardedHeaders)
  ## Expose the response header filter to the security test suite.
  proc fastProxyFilterResponseHeadersForTest*(headers: openArray[fasttypes.HttpHeader]): seq[fasttypes.HttpHeader] =
    filterResponseHeaders(headers)
  ## Expose the client timeout configuration to the security test suite.
  proc fastProxyConfigureClientTimeoutsForTest*(
    client: var fasttypes.HttpClient,
    timeoutMs: int,
    connectTimeoutMs: int
  ): tuple[requestTimeoutMs: int, connectTimeoutMs: int] =
    var opts = defaultFastProxyOptions()
    opts.timeoutMs = timeoutMs
    opts.connectTimeoutMs = connectTimeoutMs
    configureClientTimeouts(addr client, opts)
    (client.defaultTimeoutMs, client.connectTimeoutMs)
  ## Expose the timeout arming boundary to the security test suite.
  proc fastProxyTimeoutBoundaryForTest*(res: Res, timeoutMs: int): Future[void] {.async.} =
    let retFuture = newFuture[void]("fastProxyTimeoutBoundaryForTest")
    armFastProxyTimeout(res, retFuture, timeoutMs, res.responseLifecycleToken())
    await retFuture
  ## Expose the response lifecycle token accessor to the security test suite.
  proc fastProxyLifecycleTokenForTest*(res: Res): uint64 =
    res.responseLifecycleToken()
  ## Expose the response staleness check to the security test suite.
  proc fastProxyResponseStillCurrentForTest*(res: Res, lifecycleToken: uint64, retFuture: Future[void]): bool =
    res.fastProxyResponseStillCurrent(lifecycleToken, retFuture)
  ## Expose the upstream response completion logic to the security test suite.
  proc fastProxyCompleteUpstreamForTest*(
    res: Res,
    retFuture: Future[void],
    lifecycleToken: uint64,
    resp: fasttypes.HttpResponse,
    err: string,
    responseMaxBytes: int = DefaultFastProxyMaxResponseBytes
  ) =
    completeFastProxyUpstream(res, retFuture, lifecycleToken, resp, err, responseMaxBytes)
  ## Expose the request body size check to the security test suite.
  proc fastProxyRequestBodyTooLargeForTest*(req: Req, maxBytes: int): bool =
    requestBodyTooLarge(req, maxBytes)
  ## Expose the upstream request body reader to the security test suite.
  proc fastProxyUpstreamRequestBodyForTest*(req: Req, maxBytes: int): tuple[ok: bool, body: string] =
    upstreamRequestBody(req, maxBytes)
  ## Expose the upstream response size check to the security test suite.
  proc fastProxyUpstreamResponseTooLargeForTest*(
    headers: openArray[fasttypes.HttpHeader],
    bodyLen: int,
    maxBytes: int
  ): bool =
    upstreamResponseTooLarge(headers, bodyLen, maxBytes)

proc fastProxyDispatch(
  opts: FastProxyOptions,
  clientPtr: ptr fasttypes.HttpClient,
  req: Req,
  res: Res,
  retFuture: Future[void],
  upstreamUrl: string,
  preserveHostHeader: bool
): Future[void] =
  ## Shared upstream dispatch: method mapping, header filtering, body limits,
  ## timeout arming, and the client request itself.
  let (methodOk, fastMethod) = mapHttpMethod(req.methodKind)
  if not methodOk:
    res.status(405)
    res.set("Content-Type", "application/json; charset=utf-8")
    res.send("""{"error":"Method Not Allowed"}""")
    retFuture.complete()
    return retFuture
  var upstreamHeaders = buildUpstreamHeaders(
    req,
    preserveHostHeader = preserveHostHeader,
    addForwardedHeaders = opts.addXForwardedHeaders
  )
  let requestMaxBytes = effectiveMaxRequestBytes(opts)
  if requestBodyTooLarge(req, requestMaxBytes):
    res.status(413)
    res.set("Content-Type", "application/json; charset=utf-8")
    res.send("""{"error":"Payload Too Large"}""")
    retFuture.complete()
    return retFuture
  let checkedBody = upstreamRequestBody(req, requestMaxBytes)
  if not checkedBody.ok:
    res.status(413)
    res.set("Content-Type", "application/json; charset=utf-8")
    res.send("""{"error":"Payload Too Large"}""")
    retFuture.complete()
    return retFuture
  let body = checkedBody.body
  let capturedRes = res
  let capturedFuture = retFuture
  let capturedLifecycleToken = res.responseLifecycleToken()
  let responseMaxBytes = effectiveMaxResponseBytes(opts)
  armFastProxyTimeout(capturedRes, capturedFuture, effectiveRequestTimeoutMs(opts), capturedLifecycleToken)
  fastclient.request(
    clientPtr[],
    fastMethod,
    upstreamUrl,
    body,
    upstreamHeaders,
    proc(resp: fasttypes.HttpResponse, err: string) {.gcsafe.} =
      # Single-threaded event loop: fasthttpclient callbacks always run on the
      # loop thread, so capturing res/retFuture is race-free; the lifecycle
      # token additionally guards against a recycled response.
      {.cast(gcsafe).}:
        completeFastProxyUpstream(
          capturedRes,
          capturedFuture,
          capturedLifecycleToken,
          resp,
          err,
          responseMaxBytes
        )
  )
  retFuture

proc fastProxyDispatchWithDnsValidation(
  opts: FastProxyOptions,
  clientPtr: ptr fasttypes.HttpClient,
  req: Req,
  res: Res,
  retFuture: Future[void],
  upstreamUrl: string,
  host: string,
  preserveHostHeader: bool
): Future[void] {.async.} =
  # Offloads the blocking getaddrinfo call to the offload worker pool so the
  # event loop is never blocked on DNS; the wait is bounded by
  # connectTimeoutMs. Resolution failure or an offload error answers 502
  # (DNS infrastructure problem), while a resolved private address answers 403.
  let outcome = await runOffloadOutcome(
    "fastProxyDnsValidation",
    host,
    effectiveConnectTimeoutMs(opts),
    resolveHostOffload(host)
  )
  var validation: FastProxyHostValidation
  case outcome.kind
  of ookOk:
    validation = outcome.value
  else:
    validation = hostResolutionFailed
  case validation
  of hostPublic:
    discard
  of hostPrivate:
    res.status(403)
    res.set("Content-Type", "application/json; charset=utf-8")
    res.send("""{"error":"Forbidden"}""")
    retFuture.complete()
    return
  else:
    res.status(502)
    res.set("Content-Type", "application/json; charset=utf-8")
    res.send("""{"error":"Bad Gateway: upstream DNS validation failed"}""")
    retFuture.complete()
    return
  let dispatchFuture = fastProxyDispatch(
    opts, clientPtr, req, res, retFuture, upstreamUrl, preserveHostHeader
  )
  await dispatchFuture

proc fastProxyValidateAndDispatch(
  opts: FastProxyOptions,
  clientPtr: ptr fasttypes.HttpClient,
  req: Req,
  res: Res,
  retFuture: Future[void],
  upstreamUrl: string,
  preserveHostHeader: bool
): Future[void] =
  if hasUnsafeUrlChars(upstreamUrl):
    res.status(502)
    res.set("Content-Type", "application/json; charset=utf-8")
    res.send("""{"error":"Bad Gateway: invalid upstream URL"}""")
    retFuture.complete()
    return retFuture
  let parsedUpstream = parseUri(upstreamUrl)
  if parsedUpstream.scheme != "http" and parsedUpstream.scheme != "https":
    res.status(502)
    res.set("Content-Type", "application/json; charset=utf-8")
    res.send("""{"error":"Bad Gateway: invalid upstream scheme"}""")
    retFuture.complete()
    return retFuture
  if opts.blockPrivateUpstreams:
    let host = parsedUpstream.hostname
    if shouldRejectUnpinnedDnsHost(host, opts):
      res.status(403)
      res.set("Content-Type", "application/json; charset=utf-8")
      res.send("""{"error":"Forbidden"}""")
      retFuture.complete()
      return retFuture
    if isIpLiteralHost(host):
      if isPrivateHost(host):
        res.status(403)
        res.set("Content-Type", "application/json; charset=utf-8")
        res.send("""{"error":"Forbidden"}""")
        retFuture.complete()
        return retFuture
      return fastProxyDispatch(
        opts, clientPtr, req, res, retFuture, upstreamUrl, preserveHostHeader
      )
    return fastProxyDispatchWithDnsValidation(
      opts, clientPtr, req, res, retFuture, upstreamUrl, host, preserveHostHeader
    )
  fastProxyDispatch(opts, clientPtr, req, res, retFuture, upstreamUrl, preserveHostHeader)

## Build a proxy middleware that forwards requests to a fixed upstream target.
proc fastProxy*(
  target: string,
  maxConnsPerHost: int = 16,
  maxRequestBytes: int = DefaultFastProxyMaxRequestBytes,
  maxResponseBytes: int = DefaultFastProxyMaxResponseBytes
): AsyncMiddleware =
  ## Forward requests to a fixed upstream target.
  ##
  ## The returned middleware owns its client for the process lifetime; the
  ## client is allocated with raw memory and is intentionally never
  ## deallocated. Create one middleware per upstream and keep it for the life
  ## of the process; do not create and discard it repeatedly.
  var managedClient = fastclient.newHttpClient(
    maxConnsPerHost = maxConnsPerHost,
    defaultTimeoutMs = DefaultFastProxyRequestTimeoutMs
  )
  managedClient.connectTimeoutMs = DefaultFastProxyConnectTimeoutMs
  let clientPtr = cast[ptr fasttypes.HttpClient](alloc0(sizeof(fasttypes.HttpClient)))
  clientPtr[] = managedClient
  var opts = initFastProxyOptions(target)
  opts.client = clientPtr
  opts.maxRequestBytes = maxRequestBytes
  opts.maxResponseBytes = maxResponseBytes
  result = proc(req: Req, res: Res, next: NextProc): Future[void] =
    if not clientPtr[].initialized:
      if res.app != nil and res.app.server != nil:
        let loop = res.app.server.loop
        if loop != nil:
          fastclient.initClientWithLoop(clientPtr[], loop)
    let retFuture = newFuture[void]("fastProxy")
    let upstreamUrl = resolveUpstreamUrl(opts, req)
    if upstreamUrl.len == 0:
      let nextFut = next()
      nextFut.addCallback proc() =
        retFuture.complete()
      return retFuture
    fastProxyValidateAndDispatch(
      opts, clientPtr, req, res, retFuture, upstreamUrl, preserveHostHeader = false
    )

## Build a proxy middleware from explicit `FastProxyOptions`.
proc fastProxy*(options: FastProxyOptions = defaultFastProxyOptions()): AsyncMiddleware =
  let opts = normalizeFastProxyOptions(options)
  let clientPtr = opts.client
  let sharedLoop = opts.loop

  if clientPtr != nil and not clientPtr[].initialized and sharedLoop != nil:
    fastclient.initClientWithLoop(clientPtr[], sharedLoop)
  configureClientTimeouts(clientPtr, opts)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] =
    let retFuture = newFuture[void]("fastProxy")

    if clientPtr == nil:
      retFuture.complete()
      return retFuture

    let upstreamUrl = resolveUpstreamUrl(opts, req)
    if upstreamUrl.len == 0:
      let nextFut = next()
      nextFut.addCallback proc() =
        retFuture.complete()
      return retFuture
    fastProxyValidateAndDispatch(
      opts, clientPtr, req, res, retFuture, upstreamUrl, opts.preserveHostHeader
    )
