import std/[asyncdispatch, strutils, unittest]

import ../src/nim_express/[request, response, types]
import ../src/nim_express/middlewares/proxy

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

suite "proxy security hardening":
  test "rejects private upstream through public middleware path":
    var opts = defaultProxyOptions()
    opts.target = "http://127.0.0.1:65535"
    let mw = proxy(opts)
    let req = newReq(types.hmGet, "/api")
    let res = newRes()
    var nextCalled = false

    waitFor mw(req, res, makeNext(addr nextCalled))

    check not nextCalled
    check res.statusCode == 403

  test "rejects unpinned DNS upstreams by default":
    var opts = defaultProxyOptions()
    opts.target = "http://example.com"
    let mw = proxy(opts)
    let req = newReq(types.hmGet, "/api")
    let res = newRes()
    var nextCalled = false

    waitFor mw(req, res, makeNext(addr nextCalled))

    check not nextCalled
    check res.statusCode == 403

  test "rejects CONNECT and TRACE before upstream dispatch":
    var opts = defaultProxyOptions()
    opts.target = "http://203.0.113.10"
    let mw = proxy(opts)

    for methodKind in [types.hmConnect, types.hmTrace]:
      let req = newReq(methodKind, "/api")
      let res = newRes(methodKind)
      var nextCalled = false

      waitFor mw(req, res, makeNext(addr nextCalled))

      check not nextCalled
      check res.statusCode == 405

when defined(nimExpressProxySecurityTest):
  import std/[asyncstreams, httpcore, os]

  proc headerValue(headers: HttpHeaders, name: string): string =
    for key, value in headers.pairs():
      if key.toLowerAscii() == name.toLowerAscii():
        return value
    ""

  suite "proxy security internals":
    test "classifies non-public literal upstream hosts":
      check proxyIsPrivateHostForTest("127.0.0.1")
      check proxyIsPrivateHostForTest("10.0.0.1")
      check proxyIsPrivateHostForTest("172.16.0.1")
      check proxyIsPrivateHostForTest("192.168.0.1")
      check proxyIsPrivateHostForTest("169.254.169.254")
      check proxyIsPrivateHostForTest("100.64.0.1")
      check proxyIsPrivateHostForTest("224.0.0.1")
      check proxyIsPrivateHostForTest("240.0.0.1")
      check proxyIsPrivateHostForTest("localhost")
      check proxyIsPrivateHostForTest("[::1]")
      check proxyIsPrivateHostForTest("[fe80::1]")
      check proxyIsPrivateHostForTest("[febf::1]")
      check proxyIsPrivateHostForTest("[ff02::1]")
      check proxyIsPrivateHostForTest("[2001:db8::1]")
      check not proxyIsPrivateHostForTest("93.184.216.34")

    test "distinguishes literal upstreams from unpinned DNS names":
      check proxyIsIpLiteralHostForTest("93.184.216.34")
      check proxyIsIpLiteralHostForTest("[2606:2800:220:1:248:1893:25c8:1946]")
      check not proxyIsIpLiteralHostForTest("example.com")
      check proxyShouldRejectUnpinnedDnsHostForTest("example.com", false)
      check not proxyShouldRejectUnpinnedDnsHostForTest("example.com", true)
      check not proxyShouldRejectUnpinnedDnsHostForTest("93.184.216.34", false)

    test "filters hop-by-hop and client-supplied forwarding headers":
      check proxyHasUnsafeUrlCharsForTest("http://example.com/\r\nx: y")
      check proxyHasUnsafeUrlCharsForTest("http://example.com/\0")
      check not proxyHasUnsafeUrlCharsForTest("http://example.com/api?q=ok")

      check proxyShouldSkipRequestHeaderForTest("Connection", false)
      check proxyShouldSkipRequestHeaderForTest("Proxy-Authorization", false)
      check proxyShouldSkipRequestHeaderForTest("Forwarded", false)
      check proxyShouldSkipRequestHeaderForTest("X-Forwarded-For", false)
      check proxyShouldSkipRequestHeaderForTest("X-Real-IP", false)
      check proxyShouldSkipRequestHeaderForTest("Content-Length", false)
      check proxyShouldSkipRequestHeaderForTest("Host", false)
      check not proxyShouldSkipRequestHeaderForTest("Host", true)
      check not proxyShouldSkipRequestHeaderForTest("Authorization", false)

      check proxyShouldSkipResponseHeaderForTest("Transfer-Encoding")
      check proxyShouldSkipResponseHeaderForTest("Proxy-Authenticate")
      check proxyShouldSkipResponseHeaderForTest("Content-Length")
      check not proxyShouldSkipResponseHeaderForTest("Location")

    test "does not trust inbound X-Forwarded-For unless trust proxy policy allows it":
      let untrustedReq = newReq(
        types.hmGet,
        "/api",
        [("host", "service.example"), ("x-forwarded-for", "198.51.100.1")]
      )
      untrustedReq.native.remoteIp = "203.0.113.44"
      let untrustedHeaders = proxySetXForwardedHeadersForTest(untrustedReq)
      check untrustedHeaders["X-Forwarded-For"] == "203.0.113.44"
      check untrustedHeaders["X-Forwarded-Host"] == "service.example"

      let trustedReq = newReq(
        types.hmGet,
        "/api",
        [("host", "service.example"), ("x-forwarded-for", "198.51.100.1, 192.0.2.10")]
      )
      trustedReq.native.remoteIp = "203.0.113.44"
      trustedReq.trustProxyEnabled = true
      trustedReq.trustedProxyHopCount = 1
      let trustedHeaders = proxySetXForwardedHeadersForTest(trustedReq)
      check trustedHeaders["X-Forwarded-For"] == "198.51.100.1, 192.0.2.10, 203.0.113.44"

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
      let upstreamHeaders = proxyBuildUpstreamHeadersForTest(
        req,
        preserveHostHeader = false,
        addForwardedHeaders = false
      )
      check upstreamHeaders.headerValue("Connection") == ""
      check upstreamHeaders.headerValue("X-Internal-Auth") == ""
      check upstreamHeaders.headerValue("Content-Length") == ""
      check upstreamHeaders.headerValue("Authorization") == "Bearer ok"

    test "strips Connection-nominated response hop-by-hop headers":
      var headers = newHttpHeaders()
      headers.add("Connection", "X-Accel-Buffering, keep-alive")
      headers.add("X-Accel-Buffering", "no")
      headers.add("Content-Type", "text/plain")
      let filtered = proxyFilterResponseHeadersForTest(headers)
      check filtered.headerValue("Connection") == ""
      check filtered.headerValue("X-Accel-Buffering") == ""
      check filtered.headerValue("Content-Type") == "text/plain"

    test "forwards request bodies only for mutation methods":
      for methodKind in [types.hmPost, types.hmPut, types.hmPatch, types.hmDelete]:
        let req = newReq(methodKind, "/api", bodyStr = "payload-" & $methodKind)
        check proxyShouldForwardRequestBodyForTest(methodKind)
        check proxyUpstreamRequestBodyForTest(req) == "payload-" & $methodKind

      for methodKind in [types.hmGet, types.hmHead, types.hmOptions]:
        let req = newReq(methodKind, "/api", bodyStr = "must-not-forward")
        check not proxyShouldForwardRequestBodyForTest(methodKind)
        check proxyUpstreamRequestBodyForTest(req) == ""

    test "forwards spilled bodies for mutation methods":
      for methodKind in [types.hmPost, types.hmPut, types.hmPatch, types.hmDelete]:
        let spillPath = getTempDir() / ("nim_express_proxy_body_" & $methodKind & "_" & $getCurrentProcessId())
        let payload = "file-body-" & $methodKind
        writeFile(spillPath, payload)
        try:
          let req = newReq(methodKind, "/api")
          req.native.bodyInFile = true
          req.native.bodyFilePath = spillPath
          req.native.bodyFileRoot = getTempDir()

          check proxyUpstreamRequestBodyForTest(req) == payload
        finally:
          if fileExists(spillPath):
            removeFile(spillPath)

    test "does not read spilled bodies for non-forwarded methods":
      let spillPath = getTempDir() / ("nim_express_proxy_get_body_" & $getCurrentProcessId())
      writeFile(spillPath, "get-file-body")
      try:
        let req = newReq(types.hmGet, "/api")
        req.native.bodyInFile = true
        req.native.bodyFilePath = spillPath
        req.native.bodyFileRoot = getTempDir()

        check proxyUpstreamRequestBodyForTest(req) == ""
        check req.body == ""
      finally:
        if fileExists(spillPath):
          removeFile(spillPath)

    test "rejects oversized forwarded request bodies before materializing when size is known":
      let req = newReq(
        types.hmPost,
        "/api",
        [("content-length", "9")],
        bodyStr = "123456789"
      )
      check proxyRequestBodyTooLargeForTest(req, 8)
      let checked = proxyUpstreamRequestBodyForTest(req, 8)
      check not checked.ok
      check checked.body == ""

    test "rejects oversized spilled request bodies before reading file content":
      let spillPath = getTempDir() / ("nim_express_proxy_oversized_body_" & $getCurrentProcessId())
      writeFile(spillPath, repeat("x", 32))
      try:
        let req = newReq(types.hmPost, "/api")
        req.native.bodyInFile = true
        req.native.bodyFilePath = spillPath
        req.native.bodyFileRoot = getTempDir()

        check proxyRequestBodyTooLargeForTest(req, 16)
        let checked = proxyUpstreamRequestBodyForTest(req, 16)
        check not checked.ok
        check checked.body == ""
        check req.body == ""
      finally:
        if fileExists(spillPath):
          removeFile(spillPath)

    test "rejects oversized upstream responses by content length or body length":
      var headers = newHttpHeaders()
      headers.add("Content-Length", "17")
      check proxyUpstreamResponseTooLargeForTest(headers, 0, 16)

      var chunkedHeaders = newHttpHeaders()
      check proxyUpstreamResponseTooLargeForTest(chunkedHeaders, 17, 16)
      check not proxyUpstreamResponseTooLargeForTest(chunkedHeaders, 16, 16)

    test "caps streamed upstream responses before full materialization":
      let boundedStream = newFutureStream[string]("proxy bounded upstream")
      waitFor boundedStream.write("abc")
      waitFor boundedStream.write("def")
      boundedStream.complete()
      let bounded = waitFor proxyReadResponseBodyWithLimitForTest(boundedStream, 6)
      check bounded.ok
      check bounded.body == "abcdef"

      let oversizedStream = newFutureStream[string]("proxy oversized upstream")
      waitFor oversizedStream.write("abcd")
      waitFor oversizedStream.write("efg")
      let oversized = waitFor proxyReadResponseBodyWithLimitForTest(oversizedStream, 6)
      check not oversized.ok
      check oversized.body == ""

    test "generated proxy errors clear upstream response metadata":
      let res = newRes()
      discard res.set("X-Upstream-Trace", "attacker-controlled")
      discard res.append("Set-Cookie", "sid=evil; Path=/")

      proxySendGeneratedErrorForTest(
        res,
        502,
        """{"error":"Bad Gateway: upstream response too large"}"""
      )

      let header = res.native.capturedHeader.toLowerAscii()
      check res.statusCode == 502
      check header.contains("content-type: application/json")
      check not header.contains("x-upstream-trace")
      check not header.contains("set-cookie")
