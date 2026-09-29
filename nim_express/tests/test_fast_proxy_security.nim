import std/[asyncdispatch, strutils, unittest]

import ../src/nim_express/[request, response, types]
import ../src/nim_express/middlewares/fast_proxy

proc toFastMap(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    discard result.put(k, v)

proc newReq(
  methodKind: types.HttpMethod = types.hmGet,
  path: string = "/",
  headers: openArray[(string, string)] = [],
  bodyStr: string = ""
): Request =
  var nativeReq: types.HttpRequest
  new(nativeReq)
  nativeReq.methodKind = methodKind
  nativeReq.path = path
  nativeReq.body = bodyStr
  nativeReq.headers = toFastMap(headers)
  nativeReq.remoteIp = "203.0.113.44"
  result = newRequest(nativeReq)

proc newRes(methodKind: types.HttpMethod = types.hmGet): Response =
  var nativeRes: types.HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = methodKind
  result = newResponse(nativeRes)

proc makeNext(flag: ptr bool): NextProc =
  proc (): Future[void] {.async.} =
    flag[] = true

suite "fast_proxy security hardening":
  test "rejects private upstream through public middleware path":
    let mw = fastProxy("http://127.0.0.1:65535")
    let req = newReq(types.hmGet, "/api")
    let res = newRes()
    var nextCalled = false

    waitFor mw(req, res, makeNext(addr nextCalled))

    check not nextCalled
    check res.statusCode == 403

  test "rejects private upstream resolved by getaddrinfo through public middleware path":
    let mw = fastProxy("http://2130706433:65535")
    let req = newReq(types.hmGet, "/api")
    let res = newRes()
    var nextCalled = false

    waitFor mw(req, res, makeNext(addr nextCalled))

    check not nextCalled
    check res.statusCode == 403

  test "rejects IPv6 loopback after URI parsing strips brackets":
    let mw = fastProxy("http://[::1]:65535")
    let req = newReq(types.hmGet, "/api")
    let res = newRes()
    var nextCalled = false

    waitFor mw(req, res, makeNext(addr nextCalled))

    check not nextCalled
    check res.statusCode == 403

  test "rejects unsafe CRLF and NUL upstream URLs before dispatch":
    for target in ["http://example.com\r\nx: y", "http://example.com/\0"]:
      let mw = fastProxy(target)
      let req = newReq(types.hmGet, "/api")
      let res = newRes()
      var nextCalled = false

      waitFor mw(req, res, makeNext(addr nextCalled))

      check not nextCalled
      check res.statusCode == 502

  test "rejects unpinned DNS upstreams by default":
    let mw = fastProxy("http://example.com")
    let req = newReq(types.hmGet, "/api")
    let res = newRes()
    var nextCalled = false

    waitFor mw(req, res, makeNext(addr nextCalled))

    check not nextCalled
    check res.statusCode == 403

when defined(nimExpressFastProxySecurityTest):
  import nim_fasthttpclient/client as fastclient
  import nim_fasthttpclient/types as fasttypes

  proc headerValue(headers: seq[fasttypes.HttpHeader], name: string): string =
    for hdr in headers:
      if hdr.name.toLowerAscii() == name.toLowerAscii():
        return hdr.value
    ""

  proc headerCount(headers: seq[fasttypes.HttpHeader], name: string): int =
    for hdr in headers:
      if hdr.name.toLowerAscii() == name.toLowerAscii():
        inc result

  suite "fast_proxy security internals":
    test "classifies non-public literal upstream hosts":
      check fastProxyIsPrivateHostForTest("127.0.0.1")
      check fastProxyIsPrivateHostForTest("10.0.0.1")
      check fastProxyIsPrivateHostForTest("172.16.0.1")
      check fastProxyIsPrivateHostForTest("192.168.0.1")
      check fastProxyIsPrivateHostForTest("169.254.169.254")
      check fastProxyIsPrivateHostForTest("100.64.0.1")
      check fastProxyIsPrivateHostForTest("224.0.0.1")
      check fastProxyIsPrivateHostForTest("240.0.0.1")
      check fastProxyIsPrivateHostForTest("localhost")
      check fastProxyIsPrivateHostForTest("::1")
      check fastProxyIsPrivateHostForTest("fe80::1")
      check fastProxyIsPrivateHostForTest("[::1]")
      check fastProxyIsPrivateHostForTest("[fe80::1]")
      check fastProxyIsPrivateHostForTest("[febf::1]")
      check fastProxyIsPrivateHostForTest("[ff02::1]")
      check fastProxyIsPrivateHostForTest("[2001:db8::1]")
      check not fastProxyIsPrivateHostForTest("93.184.216.34")

    test "distinguishes literal upstreams from unpinned DNS names":
      check fastProxyIsIpLiteralHostForTest("93.184.216.34")
      check fastProxyIsIpLiteralHostForTest("[2606:2800:220:1:248:1893:25c8:1946]")
      check not fastProxyIsIpLiteralHostForTest("example.com")
      check fastProxyShouldRejectUnpinnedDnsHostForTest("example.com", false)
      check not fastProxyShouldRejectUnpinnedDnsHostForTest("example.com", true)
      check not fastProxyShouldRejectUnpinnedDnsHostForTest("93.184.216.34", false)

    test "rejects private IPs returned by resolution":
      check fastProxyResolvedIpLiteralsContainPrivateForTest(["93.184.216.34", "10.0.0.9"])
      check fastProxyResolvedIpLiteralsContainPrivateForTest(["::ffff:127.0.0.1"])
      check fastProxyResolvedIpLiteralsContainPrivateForTest(["2001:db8::1"])
      check not fastProxyResolvedIpLiteralsContainPrivateForTest(["93.184.216.34"])

    test "filters hop-by-hop and client-supplied forwarding headers":
      check fastProxyHasUnsafeUrlCharsForTest("http://example.com/\r\nx: y")
      check fastProxyHasUnsafeUrlCharsForTest("http://example.com/\0")
      check not fastProxyHasUnsafeUrlCharsForTest("http://example.com/api?q=ok")

      check fastProxyShouldSkipRequestHeaderForTest("Connection", false)
      check fastProxyShouldSkipRequestHeaderForTest("Proxy-Authorization", false)
      check fastProxyShouldSkipRequestHeaderForTest("Proxy-Authenticate", false)
      check fastProxyShouldSkipRequestHeaderForTest("Forwarded", false)
      check fastProxyShouldSkipRequestHeaderForTest("X-Forwarded-For", false)
      check fastProxyShouldSkipRequestHeaderForTest("X-Real-IP", false)
      check fastProxyShouldSkipRequestHeaderForTest("Content-Length", false)
      check fastProxyShouldSkipRequestHeaderForTest("Host", false)
      check not fastProxyShouldSkipRequestHeaderForTest("Host", true)
      check not fastProxyShouldSkipRequestHeaderForTest("Authorization", false)

      check fastProxyShouldSkipResponseHeaderForTest("Transfer-Encoding")
      check fastProxyShouldSkipResponseHeaderForTest("Proxy-Authenticate")
      check fastProxyShouldSkipResponseHeaderForTest("Content-Length")
      check not fastProxyShouldSkipResponseHeaderForTest("Location")

    test "does not trust inbound X-Forwarded-For unless trust proxy policy allows it":
      let untrustedReq = newReq(
        types.hmGet,
        "/api",
        [("host", "service.example"), ("x-forwarded-for", "198.51.100.1")]
      )
      untrustedReq.native.remoteIp = "203.0.113.44"
      let untrustedHeaders = fastProxySetXForwardedHeadersForTest(untrustedReq)
      check untrustedHeaders.headerValue("X-Forwarded-For") == "203.0.113.44"
      check untrustedHeaders.headerValue("X-Forwarded-Host") == "service.example"

      let trustedReq = newReq(
        types.hmGet,
        "/api",
        [("host", "service.example"), ("x-forwarded-for", "198.51.100.1, 192.0.2.10")]
      )
      trustedReq.native.remoteIp = "203.0.113.44"
      trustedReq.trustProxyEnabled = true
      trustedReq.trustedProxyHopCount = 1
      let trustedHeaders = fastProxySetXForwardedHeadersForTest(trustedReq)
      check trustedHeaders.headerValue("X-Forwarded-For") == "198.51.100.1, 192.0.2.10, 203.0.113.44"

    test "strips inbound forwarding metadata before regenerating trusted headers":
      let untrustedReq = newReq(
        types.hmGet,
        "/api",
        [
          ("host", "service.example"),
          ("authorization", "Bearer ok"),
          ("forwarded", "for=198.51.100.1"),
          ("x-real-ip", "198.51.100.2"),
          ("x-forwarded-for", "198.51.100.3"),
          ("x-forwarded-proto", "https")
        ]
      )
      untrustedReq.native.remoteIp = "203.0.113.44"
      let untrustedHeaders = fastProxyBuildUpstreamHeadersForTest(
        untrustedReq,
        preserveHostHeader = false,
        addForwardedHeaders = true
      )
      check untrustedHeaders.headerValue("Authorization") == "Bearer ok"
      check untrustedHeaders.headerValue("Forwarded") == ""
      check untrustedHeaders.headerValue("X-Real-IP") == ""
      check untrustedHeaders.headerValue("X-Forwarded-For") == "203.0.113.44"
      check untrustedHeaders.headerCount("X-Forwarded-For") == 1

      let trustedReq = newReq(
        types.hmGet,
        "/api",
        [("host", "service.example"), ("x-forwarded-for", "198.51.100.3, 192.0.2.10")]
      )
      trustedReq.native.remoteIp = "203.0.113.44"
      trustedReq.trustProxyEnabled = true
      trustedReq.trustedProxyHopCount = 1
      let trustedHeaders = fastProxyBuildUpstreamHeadersForTest(
        trustedReq,
        preserveHostHeader = false,
        addForwardedHeaders = true
      )
      check trustedHeaders.headerValue("X-Forwarded-For") == "198.51.100.3, 192.0.2.10, 203.0.113.44"
      check trustedHeaders.headerCount("X-Forwarded-For") == 1

    test "strips Connection-nominated request hop-by-hop headers":
      let req = newReq(
        types.hmGet,
        "/api",
        [
          ("host", "service.example"),
          ("connection", "X-Internal-Auth, keep-alive"),
          ("x-internal-auth", "attacker"),
          ("content-length", "9999"),
          ("authorization", "Bearer ok")
        ]
      )
      let upstreamHeaders = fastProxyBuildUpstreamHeadersForTest(
        req,
        preserveHostHeader = false,
        addForwardedHeaders = false
      )
      check upstreamHeaders.headerValue("Connection") == ""
      check upstreamHeaders.headerValue("X-Internal-Auth") == ""
      check upstreamHeaders.headerValue("Content-Length") == ""
      check upstreamHeaders.headerValue("Authorization") == "Bearer ok"

    test "strips Connection-nominated response hop-by-hop headers":
      let filtered = fastProxyFilterResponseHeadersForTest(@[
        fasttypes.HttpHeader(name: "Connection", value: "X-Accel-Buffering, keep-alive"),
        fasttypes.HttpHeader(name: "X-Accel-Buffering", value: "no"),
        fasttypes.HttpHeader(name: "Content-Type", value: "text/plain")
      ])
      check filtered.headerValue("Connection") == ""
      check filtered.headerValue("X-Accel-Buffering") == ""
      check filtered.headerValue("Content-Type") == "text/plain"

    test "configures request and connect timeout boundaries":
      var explicitClient = fastclient.newHttpClient(
        maxConnsPerHost = 1,
        defaultTimeoutMs = 0
      )
      explicitClient.connectTimeoutMs = 0
      let explicit = fastProxyConfigureClientTimeoutsForTest(
        explicitClient,
        timeoutMs = 7,
        connectTimeoutMs = 11
      )
      check explicit.requestTimeoutMs == 7
      check explicit.connectTimeoutMs == 11

      var defaultClient = fastclient.newHttpClient(
        maxConnsPerHost = 1,
        defaultTimeoutMs = 0
      )
      defaultClient.connectTimeoutMs = 0
      let defaults = fastProxyConfigureClientTimeoutsForTest(
        defaultClient,
        timeoutMs = 0,
        connectTimeoutMs = 0
      )
      check defaults.requestTimeoutMs == DefaultFastProxyRequestTimeoutMs
      check defaults.connectTimeoutMs == DefaultFastProxyConnectTimeoutMs

    test "timeout boundary completes a hung upstream path":
      let res = newRes()
      waitFor fastProxyTimeoutBoundaryForTest(res, 1)
      check res.statusCode == 504

    test "stale upstream callback cannot write through a reused response":
      let res = newRes()
      let oldToken = fastProxyLifecycleTokenForTest(res)
      let staleFuture = newFuture[void]("stale fastProxy upstream")

      var nativeRes2: types.HttpResponse
      new(nativeRes2)
      nativeRes2.requestMethod = types.hmGet
      res.rebindResponse(nativeRes2, nil, "views", "")

      check not fastProxyResponseStillCurrentForTest(res, oldToken, staleFuture)
      fastProxyCompleteUpstreamForTest(
        res,
        staleFuture,
        oldToken,
        fasttypes.HttpResponse(
          statusCode: 201,
          statusText: "Created",
          headers: @[fasttypes.HttpHeader(name: "X-Stale", value: "yes")],
          body: "stale"
        ),
        ""
      )
      check staleFuture.finished
      check res.statusCode == 200
      check res.headers.getOrDefault("x-stale", "") == ""
      check not res.finished

    test "rejects oversized forwarded request bodies before materializing when size is known":
      let req = newReq(
        types.hmPost,
        "/api",
        [("content-length", "9")],
        bodyStr = "123456789"
      )
      check fastProxyRequestBodyTooLargeForTest(req, 8)
      let checked = fastProxyUpstreamRequestBodyForTest(req, 8)
      check not checked.ok
      check checked.body == ""

    test "rejects oversized upstream responses by content length or body length":
      let headers = @[
        fasttypes.HttpHeader(name: "Content-Length", value: "17")
      ]
      check fastProxyUpstreamResponseTooLargeForTest(headers, 0, 16)

      let chunkedHeaders: seq[fasttypes.HttpHeader] = @[]
      check fastProxyUpstreamResponseTooLargeForTest(chunkedHeaders, 17, 16)
      check not fastProxyUpstreamResponseTooLargeForTest(chunkedHeaders, 16, 16)

    test "host validation distinguishes private from resolution failure (ISSUE-4)":
      check fastProxyResolveAndValidateHostForTest("127.0.0.1") == hostPrivate
      check fastProxyResolveAndValidateHostForTest("localhost") == hostPrivate
      check fastProxyResolveAndValidateHostForTest("93.184.216.34") == hostPublic
      check fastProxyResolveAndValidateHostForTest("nonexistent-host.invalid") ==
        hostResolutionFailed

    test "explicit blockPrivateUpstreams flag is honored (ISSUE-2)":
      var explicit = defaultFastProxyOptions()
      explicit.blockPrivateUpstreams = false
      explicit.blockPrivateUpstreamsExplicit = true
      check not fastProxyNormalizeOptionsForTest(explicit).blockPrivateUpstreams

      let implicit = fastProxyNormalizeOptionsForTest(defaultFastProxyOptions())
      check implicit.blockPrivateUpstreams

      var allow = defaultFastProxyOptions()
      allow.allowPrivateUpstreams = true
      check not fastProxyNormalizeOptionsForTest(allow).blockPrivateUpstreams

    test "DNS resolution failure yields 502 through the middleware path (ISSUE-4)":
      var client = fastclient.newHttpClient(maxConnsPerHost = 1)
      let clientPtr = cast[ptr fasttypes.HttpClient](addr client)
      var opts = defaultFastProxyOptions()
      opts.target = "http://nonexistent-host.invalid:8080"
      opts.allowUnpinnedDnsUpstreams = true
      opts.client = clientPtr
      let mw = fastProxy(opts)
      let req = newReq(types.hmGet, "/api")
      let res = newRes()
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check not nextCalled
      check res.statusCode == 502
