{.define: nimExpressProxySecurityTest.}

import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/proxy

proc newMockHttpRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[]
): HttpRequest =
  new(result)
  result.path = pathVal
  result.queryStringRaw = ""
  result.httpVersion = "1.1"
  result.httpMajor = 1
  result.httpMinor = 1
  result.body = bodyStr
  result.remoteIp = remoteIpStr
  result.methodKind = methodKind
  result.connectionClose = false
  result.headersDeferred = false
  result.bodyInFile = false
  result.bodyFilePath = ""
  result.bodyFileRoot = ""
  result.headers = newFastMap[string]()
  discard result.headers.reserve(16)
  result.query = newFastMap[string]()
  discard result.query.reserve(8)
  for (k, v) in headerMap:
    result.headers[k] = v

proc newMockRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[]
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr, headerMap)
  result = newRequest(native)

proc newMockResponse(): Response =
  new(result)
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = hmGet
  nativeRes.connectionClose = false
  result.native = nativeRes
  result.request = nil
  result.app = nil
  result.viewsDir = "views"
  result.viewExt = ""
  result.requestMethodKind = hmGet
  result.statusCode = 200
  result.headersInited = true
  result.finished = false
  result.compress = false
  result.compressEncoding = ""
  result.headerBuf = newStringOfCap(256)
  result.droppedLateWrites = 0
  result.headers = newFastMap[string]()
  discard result.headers.reserve(16)
  result.locals = newFastMap[string]()
  discard result.locals.reserve(4)

proc startMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
): Future[void] =
  var idx = 0
  proc finalHandler(r: Request, s: Response): Future[void] {.async.} =
    if handler != nil:
      await handler(r, s)
    elif not s.finished:
      s.status(200)
  proc advance(): Future[void] {.async.} =
    if idx < middlewares.len:
      let current = middlewares[idx]
      inc idx
      await current(req, res, advance)
    else:
      await finalHandler(req, res)
  result = advance()

proc runMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
) =
  waitFor startMiddlewareChain(middlewares, req, res, handler)

proc flagHandler(flag: ptr bool): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    flag[] = true
    if not res.finished:
      res.status(200)
      res.send("ok")

from std/httpcore import HttpHeaders, newHttpHeaders, add, hasKey, pairs
from std/asyncstreams import write, complete

proc headerValue(headers: HttpHeaders, name: string): string =
  for key, value in headers.pairs():
    if key.toLowerAscii == name.toLowerAscii:
      return value
  ""

suite "proxy unit":
  test "isPrivateHost: private IPv4 ranges (regression)":
    check proxyIsPrivateHostForTest("127.0.0.1")
    check proxyIsPrivateHostForTest("10.1.2.3")
    check proxyIsPrivateHostForTest("172.16.0.1")
    check proxyIsPrivateHostForTest("172.31.255.255")
    check proxyIsPrivateHostForTest("192.168.1.1")
    check proxyIsPrivateHostForTest("169.254.1.1")
    check proxyIsPrivateHostForTest("100.64.0.1")
    check proxyIsPrivateHostForTest("224.0.0.1")
    check proxyIsPrivateHostForTest("240.0.0.1")
    check proxyIsPrivateHostForTest("0.0.0.0")
    check proxyIsPrivateHostForTest("255.255.255.255")
    check proxyIsPrivateHostForTest("LOCALHOST")

  test "isPrivateHost: public IPv4 allowed (regression)":
    check not proxyIsPrivateHostForTest("8.8.8.8")
    check not proxyIsPrivateHostForTest("1.1.1.1")
    check not proxyIsPrivateHostForTest("172.32.0.1")
    check not proxyIsPrivateHostForTest("11.0.0.1")
    check not proxyIsPrivateHostForTest("93.184.216.34")

  test "isPrivateHost: local names (regression)":
    check proxyIsPrivateHostForTest("localhost")
    check proxyIsPrivateHostForTest("api.localhost")
    check proxyIsPrivateHostForTest("host.local")
    check proxyIsPrivateHostForTest("svc.internal")
    check not proxyIsPrivateHostForTest("example.com")
    check not proxyIsPrivateHostForTest("my-internal.example.com")

  test "isPrivateHost: unbracketed IPv6 literals (ISSUE-4)":
    check proxyIsPrivateHostForTest("::1")
    check proxyIsPrivateHostForTest("::")
    check proxyIsPrivateHostForTest("fd12:3456:789a::1")
    check proxyIsPrivateHostForTest("fc00::1")
    check proxyIsPrivateHostForTest("fe80::1")
    check proxyIsPrivateHostForTest("ff02::1")
    check proxyIsPrivateHostForTest("2001:db8::1")
    check proxyIsPrivateHostForTest("0:0:0:0:0:0:0:1")
    check not proxyIsPrivateHostForTest("2001:4860:4860::8888")

  test "isPrivateHost: bracketed IPv6 literals (regression)":
    check proxyIsPrivateHostForTest("[::1]")
    check proxyIsPrivateHostForTest("[fd12::1]")
    check not proxyIsPrivateHostForTest("[2001:4860:4860::8888]")

  test "IPv4 parse overflow guard (ISSUE-7)":
    check not proxyIsPrivateHostForTest("999999999999999999999.1.2.3")
    check not proxyIsIpLiteralHostForTest("999999999999999999999.1.2.3")
    check not proxyIsIpLiteralHostForTest("256.1.1.1")
    check proxyIsIpLiteralHostForTest("10.0.0.1")
    check proxyIsIpLiteralHostForTest("[::1]")
    check proxyIsIpLiteralHostForTest("8.8.8.8")

  test "hasUnsafeUrlChars rejects all control chars (ISSUE-8)":
    check not proxyHasUnsafeUrlCharsForTest("http://example.com/path?q=1")
    check proxyHasUnsafeUrlCharsForTest("http://example.com/a" & '\r')
    check proxyHasUnsafeUrlCharsForTest("http://example.com/a" & '\n')
    check proxyHasUnsafeUrlCharsForTest("http://example.com/a" & chr(0))
    check proxyHasUnsafeUrlCharsForTest("http://example.com/a" & chr(1))
    check proxyHasUnsafeUrlCharsForTest("http://example.com/a" & chr(31))
    check proxyHasUnsafeUrlCharsForTest("http://example.com/a" & chr(127))
    check not proxyHasUnsafeUrlCharsForTest("http://example.com/ok path")

  test "unpinned DNS host rejection (regression)":
    check proxyShouldRejectUnpinnedDnsHostForTest("example.com", false)
    check not proxyShouldRejectUnpinnedDnsHostForTest("example.com", true)
    check not proxyShouldRejectUnpinnedDnsHostForTest("10.0.0.1", false)
    check not proxyShouldRejectUnpinnedDnsHostForTest("[2001:4860::1]", false)
    check not proxyShouldRejectUnpinnedDnsHostForTest("::1", false)

  test "request header filtering (regression)":
    check proxyShouldSkipRequestHeaderForTest("connection", false)
    check proxyShouldSkipRequestHeaderForTest("CONNECTION", false)
    check proxyShouldSkipRequestHeaderForTest("keep-alive", false)
    check proxyShouldSkipRequestHeaderForTest("transfer-encoding", false)
    check proxyShouldSkipRequestHeaderForTest("upgrade", false)
    check proxyShouldSkipRequestHeaderForTest("te", false)
    check proxyShouldSkipRequestHeaderForTest("trailer", false)
    check proxyShouldSkipRequestHeaderForTest("proxy-authorization", false)
    check proxyShouldSkipRequestHeaderForTest("x-forwarded-for", false)
    check proxyShouldSkipRequestHeaderForTest("x-forwarded-host", false)
    check proxyShouldSkipRequestHeaderForTest("x-real-ip", false)
    check proxyShouldSkipRequestHeaderForTest("forwarded", false)
    check proxyShouldSkipRequestHeaderForTest("content-length", false)
    check proxyShouldSkipRequestHeaderForTest("host", false)
    check not proxyShouldSkipRequestHeaderForTest("host", true)
    check not proxyShouldSkipRequestHeaderForTest("authorization", false)
    check not proxyShouldSkipRequestHeaderForTest("content-type", false)
    check not proxyShouldSkipRequestHeaderForTest("cookie", false)

  test "response header filtering (regression)":
    check proxyShouldSkipResponseHeaderForTest("connection")
    check proxyShouldSkipResponseHeaderForTest("keep-alive")
    check proxyShouldSkipResponseHeaderForTest("transfer-encoding")
    check proxyShouldSkipResponseHeaderForTest("content-length")
    check not proxyShouldSkipResponseHeaderForTest("content-type")
    check not proxyShouldSkipResponseHeaderForTest("server")
    check not proxyShouldSkipResponseHeaderForTest("x-upstream")

  test "buildUpstreamHeaders strips hop-by-hop, replaces X-Forwarded":
    let req = newMockRequest(
      pathVal = "/", methodKind = hmGet, remoteIpStr = "203.0.113.7",
      headerMap = @[
        ("content-type", "text/plain"),
        ("authorization", "Bearer tok"),
        ("cookie", "a=b"),
        ("connection", "keep-alive"),
        ("keep-alive", "timeout=5"),
        ("x-forwarded-for", "9.9.9.9"),
        ("host", "example.test")
      ])
    let h = proxyBuildUpstreamHeadersForTest(req, false, true)
    check h.hasKey("content-type")
    check h.hasKey("authorization")
    check h.hasKey("cookie")
    check not h.hasKey("connection")
    check not h.hasKey("keep-alive")
    check not h.hasKey("host")
    check headerValue(h, "X-Forwarded-For") == "203.0.113.7"
    check headerValue(h, "X-Forwarded-Proto") == "http"
    check headerValue(h, "X-Forwarded-Host") == "example.test"

  test "buildUpstreamHeaders preserves host, omits forwarded when disabled":
    let req = newMockRequest(
      pathVal = "/", methodKind = hmGet,
      headerMap = @[("host", "example.test")])
    let h = proxyBuildUpstreamHeadersForTest(req, true, false)
    check h.hasKey("host")
    check not h.hasKey("x-forwarded-for")
    check not h.hasKey("x-forwarded-proto")

  test "buildUpstreamHeaders strips Connection-listed tokens":
    let req = newMockRequest(
      pathVal = "/", methodKind = hmGet,
      headerMap = @[("connection", "X-Custom, close"), ("x-custom", "1")])
    let h = proxyBuildUpstreamHeadersForTest(req, false, false)
    check not h.hasKey("connection")
    check not h.hasKey("x-custom")

  test "filterResponseHeaders strips hop-by-hop and content-length":
    var h = newHttpHeaders()
    h.add("Content-Type", "text/html")
    h.add("Content-Length", "42")
    h.add("Connection", "close")
    h.add("Keep-Alive", "timeout=5")
    h.add("Server", "nginx")
    h.add("X-Upstream", "yes")
    let f = proxyFilterResponseHeadersForTest(h)
    check f.hasKey("Content-Type")
    check headerValue(f, "Content-Type") == "text/html"
    check not f.hasKey("Content-Length")
    check not f.hasKey("Connection")
    check not f.hasKey("Keep-Alive")
    check f.hasKey("Server")
    check f.hasKey("X-Upstream")

  test "filterResponseHeaders strips Connection-listed tokens":
    var h = newHttpHeaders()
    h.add("Connection", "X-Trace")
    h.add("X-Trace", "t")
    h.add("Server", "nginx")
    let f = proxyFilterResponseHeadersForTest(h)
    check not f.hasKey("Connection")
    check not f.hasKey("X-Trace")
    check f.hasKey("Server")

  test "setXForwardedHeaders basic values (regression)":
    let req = newMockRequest(
      pathVal = "/", methodKind = hmGet, remoteIpStr = "203.0.113.7",
      headerMap = @[("host", "example.test")])
    let h = proxySetXForwardedHeadersForTest(req)
    check headerValue(h, "X-Forwarded-For") == "203.0.113.7"
    check headerValue(h, "X-Forwarded-Proto") == "http"
    check headerValue(h, "X-Forwarded-Host") == "example.test"

  test "setXForwardedHeaders drops poisoned remoteIp (ISSUE-15)":
    let req1 = newMockRequest(remoteIpStr = "1.2.3.4, 6.7.8.9")
    let h1 = proxySetXForwardedHeadersForTest(req1)
    check headerValue(h1, "X-Forwarded-For") == ""
    let req2 = newMockRequest(remoteIpStr = "1.2.3.4\r\nX-Inject: 1")
    let h2 = proxySetXForwardedHeadersForTest(req2)
    check headerValue(h2, "X-Forwarded-For") == ""
    let req3 = newMockRequest(remoteIpStr = "2001:db8::5")
    let h3 = proxySetXForwardedHeadersForTest(req3)
    check headerValue(h3, "X-Forwarded-For") == "2001:db8::5"

  test "request body forwarded only for body methods (regression)":
    check proxyShouldForwardRequestBodyForTest(hmPost)
    check proxyShouldForwardRequestBodyForTest(hmPut)
    check proxyShouldForwardRequestBodyForTest(hmPatch)
    check proxyShouldForwardRequestBodyForTest(hmDelete)
    check not proxyShouldForwardRequestBodyForTest(hmGet)
    check not proxyShouldForwardRequestBodyForTest(hmHead)
    check not proxyShouldForwardRequestBodyForTest(hmOptions)

  test "request body size limit (regression)":
    let bigBody = "x".repeat(2048)
    let req = newMockRequest(methodKind = hmPost, bodyStr = bigBody)
    check proxyRequestBodyTooLargeForTest(req, 1024)
    check not proxyRequestBodyTooLargeForTest(req, 4096)
    let r1 = proxyUpstreamRequestBodyForTest(req, 1024)
    check not r1.ok
    let r2 = proxyUpstreamRequestBodyForTest(req, 4096)
    check r2.ok
    check r2.body == bigBody
    let getReq = newMockRequest(methodKind = hmGet, bodyStr = bigBody)
    check not proxyRequestBodyTooLargeForTest(getReq, 8)

  test "response size limit (regression)":
    var h = newHttpHeaders()
    h.add("Content-Length", "100")
    check proxyUpstreamResponseTooLargeForTest(h, 0, 50)
    check not proxyUpstreamResponseTooLargeForTest(h, 0, 200)
    var h2 = newHttpHeaders()
    check proxyUpstreamResponseTooLargeForTest(h2, 60, 50)
    check not proxyUpstreamResponseTooLargeForTest(h2, 40, 50)

  test "readResponseBodyWithLimit within limit":
    var stream = newFutureStream[string]("test")
    discard stream.write("hello ")
    discard stream.write("world")
    stream.complete()
    let r = waitFor proxyReadResponseBodyWithLimitForTest(stream, 100)
    check r.ok
    check r.body == "hello world"

  test "readResponseBodyWithLimit exceeds limit":
    var stream = newFutureStream[string]("test")
    discard stream.write("123456789")
    stream.complete()
    let r = waitFor proxyReadResponseBodyWithLimitForTest(stream, 5)
    check not r.ok

  test "sendGeneratedError sets status, nil/finished safe":
    let res = newMockResponse()
    proxySendGeneratedErrorForTest(res, 502, """{"error":"Bad Gateway"}""")
    check res.statusCode == 502
    check res.finished
    proxySendGeneratedErrorForTest(nil, 504, "x")
    proxySendGeneratedErrorForTest(res, 504, "y")
    check res.statusCode == 502

suite "proxy integration":
  test "CONNECT rejected with 405 (regression)":
    let mw = proxy(initProxyOptions("http://127.0.0.1:9"))
    let req = newMockRequest(methodKind = hmConnect)
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 405
    check res.finished

  test "TRACE rejected with 405 (regression)":
    let mw = proxy(initProxyOptions("http://127.0.0.1:9"))
    let req = newMockRequest(methodKind = hmTrace)
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 405
    check res.finished

  test "unsafe URL chars produce 502 (ISSUE-8)":
    let mw = proxy(initProxyOptions("http://example.com/" & chr(1)))
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 502

  test "non-http scheme produces 502 (regression)":
    let mw = proxy(initProxyOptions("ftp://example.com"))
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 502

  test "private IPv4 literal upstream rejected with 403 (regression)":
    let mw = proxy(initProxyOptions("http://127.0.0.1:9999"))
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403

  test "unpinned DNS hostname upstream rejected with 403 (regression)":
    let mw = proxy(initProxyOptions("http://intranet.example"))
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403

  test "request body over limit produces 413":
    var opts = initProxyOptions("http://127.0.0.1:9")
    opts.allowPrivateUpstreams = true
    opts.maxRequestBytes = 1024
    let mw = proxy(opts)
    let req = newMockRequest(methodKind = hmPost, bodyStr = "x".repeat(4096))
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 413

  test "empty target falls through to next() (regression)":
    let mw = proxy()
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
