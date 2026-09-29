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
  headers: openArray[(string, string)] = []
): Request =
  var nativeReq: types.HttpRequest
  new(nativeReq)
  nativeReq.methodKind = methodKind
  nativeReq.path = path
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

when defined(nimExpressFastProxySecurityTest):
  suite "fast_proxy improvements - internal security checks":
    test "IPv4-mapped IPv6 with private embedded address is private (ISSUE-3)":
      check fastProxyIsPrivateHostForTest("::ffff:127.0.0.1")
      check fastProxyIsPrivateHostForTest("::ffff:192.168.1.1")
      check fastProxyIsPrivateHostForTest("::ffff:169.254.169.254")
      check fastProxyIsPrivateHostForTest("::ffff:10.1.2.3")
      check fastProxyIsPrivateHostForTest("::ffff:100.64.0.1")

    test "IPv4-mapped IPv6 with public embedded address is NOT private (ISSUE-3 fix)":
      check not fastProxyIsPrivateHostForTest("::ffff:8.8.8.8")
      check not fastProxyIsPrivateHostForTest("::ffff:93.184.216.34")
      check not fastProxyIsPrivateHostForTest("::ffff:1.1.1.1")

    test "resolved IPv4-mapped literals classify by embedded IPv4 (ISSUE-3)":
      check not fastProxyResolvedIpLiteralsContainPrivateForTest(["::ffff:8.8.8.8"])
      check not fastProxyResolvedIpLiteralsContainPrivateForTest(["::ffff:93.184.216.34"])
      check fastProxyResolvedIpLiteralsContainPrivateForTest(["::ffff:192.168.0.1"])
      check fastProxyResolvedIpLiteralsContainPrivateForTest(["::ffff:127.0.0.1"])
      check fastProxyResolvedIpLiteralsContainPrivateForTest(["::ffff:169.254.169.254"])

    test "onion addresses are blocked as non-public (ISSUE-9)":
      check fastProxyIsPrivateHostForTest("example.onion")
      check fastProxyIsPrivateHostForTest("a.b.onion")
      check fastProxyIsPrivateHostForTest("abcd1234.onion")
      check not fastProxyIsPrivateHostForTest("example.com")

    test "all C0 control characters are rejected in upstream URLs (ISSUE-14)":
      check fastProxyHasUnsafeUrlCharsForTest("http://example.com/\t")
      check fastProxyHasUnsafeUrlCharsForTest("http://example.com/\x01")
      check fastProxyHasUnsafeUrlCharsForTest("http://example.com/\x1f")
      check fastProxyHasUnsafeUrlCharsForTest("http://example.com/\r\nx: y")
      check fastProxyHasUnsafeUrlCharsForTest("http://example.com/\0")
      check not fastProxyHasUnsafeUrlCharsForTest("http://example.com/api?q=ok")

  suite "fast_proxy improvements - middleware path":
    test "rejects private IPv4-mapped IPv6 upstream through public path (ISSUE-3)":
      let mw = fastProxy("http://[::ffff:127.0.0.1]:65535")
      let req = newReq(types.hmGet, "/api")
      let res = newRes()
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check not nextCalled
      check res.statusCode == 403

    test "rejects private IPv4-mapped IPv6 upstream resolved form (ISSUE-3)":
      let mw = fastProxy("http://[::ffff:192.168.0.1]:65535")
      let req = newReq(types.hmGet, "/api")
      let res = newRes()
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check not nextCalled
      check res.statusCode == 403
