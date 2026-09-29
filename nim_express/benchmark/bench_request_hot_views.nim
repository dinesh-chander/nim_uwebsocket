import std/[os, strutils, times]

import nim_express/[types, request]

type
  BenchResult = object
    elapsedMs: float
    checksum: int

proc msBetween(startTs, endTs: float): float {.inline.} =
  (endTs - startTs) * 1000.0

proc makeRequest(): Request =
  var native: HttpRequest
  new(native)
  native.path = "/todos"
  native.remoteIp = "10.0.0.1"
  native.headers = newFastMap[string]()
  native.headers["x-requested-with"] = "XMLHttpRequest"
  native.headers["content-type"] = "application/merge-patch+json; charset=utf-8"
  native.headers["x-forwarded-for"] = "198.51.100.10, 203.0.113.90"
  native.headers["x-real-ip"] = "203.0.113.90"
  native.headers["x-forwarded-proto"] = "https"
  native.headers["x-forwarded-host"] = "app.example.com:8443"
  native.headers["host"] = "origin.example.com:8080"
  native.headers["cache-control"] = "private, NO-CACHE, max-age=0"
  result = newRequest(native)
  result.trustProxyEnabled = true
  result.trustedProxyHopCount = 1

proc firstHeaderTokenLegacy(value: string): string {.inline.} =
  if value.len == 0:
    return ""
  let comma = value.find(',')
  if comma >= 0:
    return value[0..<comma].strip()
  value.strip()

proc headerTokenFromRightLegacy(value: string, skipFromRight: int): string =
  if value.len == 0:
    return ""
  var want = max(0, skipFromRight)
  var i = value.len - 1
  while i >= 0:
    while i >= 0 and (value[i] == ',' or value[i] == ' ' or value[i] == '\t'):
      dec i
    if i < 0:
      break
    let tokenEnd = i + 1
    while i >= 0 and value[i] != ',':
      dec i
    let token = value[i + 1..<tokenEnd].strip()
    if token.len > 0:
      if want == 0:
        return token
      dec want
  ""

proc forwardedHeaderTokenCountLegacy(value: string): int =
  var i = 0
  while i < value.len:
    while i < value.len and (value[i] == ',' or value[i] == ' ' or value[i] == '\t'):
      inc i
    if i >= value.len:
      break
    inc result
    while i < value.len and value[i] != ',':
      inc i

proc trustedClientIpLegacy(req: Request): string =
  if req == nil or not req.trustProxyEnabled:
    return ""
  let trustedHops = max(0, int(req.trustedProxyHopCount))
  let forwardedFor = req.get("x-forwarded-for")
  if trustedHops > 0 and forwardedHeaderTokenCountLegacy(forwardedFor) < trustedHops + 1:
    return ""
  let forwarded =
    if trustedHops > 0:
      headerTokenFromRightLegacy(forwardedFor, trustedHops)
    else:
      firstHeaderTokenLegacy(forwardedFor)
  if forwarded.len > 0:
    return forwarded
  firstHeaderTokenLegacy(req.get("x-real-ip"))

proc forwardedHeadersTrustedLegacy(req: Request): bool =
  if req == nil or not req.trustProxyEnabled:
    return false
  let trustedHops = max(0, int(req.trustedProxyHopCount))
  if trustedHops <= 0:
    return true
  let forwardedFor = req.get("x-forwarded-for")
  forwardedHeaderTokenCountLegacy(forwardedFor) >= trustedHops + 1

proc trustedForwardedHostLegacy(req: Request): string =
  if not forwardedHeadersTrustedLegacy(req):
    return ""
  let forwardedHost = req.get("x-forwarded-host")
  if req.trustedProxyHopCount > 0:
    return headerTokenFromRightLegacy(forwardedHost, 0)
  firstHeaderTokenLegacy(forwardedHost)

proc stripPortFromHostLegacy(hostHeader: string): string {.inline.} =
  let host = firstHeaderTokenLegacy(hostHeader)
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

proc hostnameLegacy(req: Request): string =
  if req == nil:
    return ""
  let forwardedHost = trustedForwardedHostLegacy(req)
  if forwardedHost.len > 0:
    let parsed = stripPortFromHostLegacy(forwardedHost)
    if parsed.len > 0:
      return parsed
  stripPortFromHostLegacy(req.get("host"))

proc freshLegacy(req: Request): bool {.inline.} =
  "no-cache" notin req.get("cache-control").toLowerAscii()

proc benchXhrOwned(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    if req.get("x-requested-with").cmpIgnoreCase("xmlhttprequest") == 0:
      inc checksum
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchXhrView(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    if req.isXhr():
      inc checksum
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchJsonOwned(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    if isJsonContentType(req.get("content-type")):
      inc checksum
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchJsonView(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    if req.isJson():
      inc checksum
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchTrustedIpOwned(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    checksum += trustedClientIpLegacy(req).len
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchTrustedIpView(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    checksum += req.trustedClientIp().len
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchHostnameOwned(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    checksum += hostnameLegacy(req).len
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchHostnameView(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    checksum += req.hostname().len
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchFreshOwned(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    if not freshLegacy(req):
      inc checksum
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc benchFreshView(n: int): BenchResult =
  let req = makeRequest()
  let t0 = epochTime()
  var checksum = 0
  for _ in 0..<n:
    if not req.fresh():
      inc checksum
  let t1 = epochTime()
  result.elapsedMs = msBetween(t0, t1)
  result.checksum = checksum

proc printResult(name: string, r: BenchResult) =
  echo name
  echo "  elapsed: ", formatFloat(r.elapsedMs, ffDecimal, 3), " ms"
  echo "  checksum: ", r.checksum

when isMainModule:
  var n = 200_000
  if paramCount() >= 1:
    n = parseInt(paramStr(1))

  discard benchXhrOwned(10_000)
  discard benchXhrView(10_000)
  discard benchJsonOwned(10_000)
  discard benchJsonView(10_000)
  discard benchTrustedIpOwned(10_000)
  discard benchTrustedIpView(10_000)
  discard benchHostnameOwned(10_000)
  discard benchHostnameView(10_000)
  discard benchFreshOwned(10_000)
  discard benchFreshView(10_000)

  printResult("Request XHR Owned", benchXhrOwned(n))
  printResult("Request XHR View", benchXhrView(n))
  printResult("Request JSON Owned", benchJsonOwned(n))
  printResult("Request JSON View", benchJsonView(n))
  printResult("Request Trusted IP Owned", benchTrustedIpOwned(n))
  printResult("Request Trusted IP View", benchTrustedIpView(n))
  printResult("Request Hostname Owned", benchHostnameOwned(n))
  printResult("Request Hostname View", benchHostnameView(n))
  printResult("Request Fresh Owned", benchFreshOwned(n))
  printResult("Request Fresh View", benchFreshView(n))
