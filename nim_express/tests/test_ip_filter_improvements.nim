import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/ip_filter

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

proc clientIpBytes(ip: string): (array[16, uint8], bool) =
  var buf: array[16, uint8]
  if parseIpv4Bytes(ip, buf):
    result = (buf, false)
  else:
    if not parseIpv6Bytes(ip, buf):
      raise newException(ValueError, "test helper: unparseable IP " & ip)
    result = (buf, true)

proc expectV4(a, b, c, d: int): array[16, uint8] =
  result[0] = uint8(a)
  result[1] = uint8(b)
  result[2] = uint8(c)
  result[3] = uint8(d)

proc expectV6(groups: openArray[int]): array[16, uint8] =
  for i in 0 ..< groups.len:
    let g = uint16(groups[i])
    result[i * 2] = uint8(g shr 8)
    result[i * 2 + 1] = uint8(g and 0xFF)

suite "ip_filter unit — parseIpv4Bytes":
  test "parses valid dotted-decimal IPv4 into bytes 0..3":
    var buf: array[16, uint8]
    check parseIpv4Bytes("192.168.1.1", buf)
    check buf == expectV4(192, 168, 1, 1)
    check parseIpv4Bytes("0.0.0.0", buf)
    check buf == expectV4(0, 0, 0, 0)
    check parseIpv4Bytes("255.255.255.255", buf)
    check buf == expectV4(255, 255, 255, 255)
    check parseIpv4Bytes("10.0.0.0", buf)
    check buf == expectV4(10, 0, 0, 0)

  test "rejects out-of-range, malformed, and negative parts":
    var buf: array[16, uint8]
    for bad in @["256.1.1.1", "1.2.256.1", "1.2.3", "1.2.3.4.5",
                 "1.2.3.4x", "1..2.3", "1.2.3.", ".1.2.3", "-1.2.3.4",
                 "1.2.3.-4", "1.2.3.4 ", "a.b.c.d", ""]:
      buf = default(array[16, uint8])
      check parseIpv4Bytes(bad, buf) == false

suite "ip_filter unit — parseIpv6Bytes":
  test "parses :: and ::1 shorthands":
    var buf: array[16, uint8]
    check parseIpv6Bytes("::", buf)
    check buf == default(array[16, uint8])
    check parseIpv6Bytes("::1", buf)
    check buf == expectV6([0, 0, 0, 0, 0, 0, 0, 1])

  test "parses full and partial group forms":
    var buf: array[16, uint8]
    check parseIpv6Bytes("2001:0db8:0001:0002:0003:0004:0005:0006", buf)
    check buf == expectV6([0x2001, 0x0DB8, 1, 2, 3, 4, 5, 6])
    check parseIpv6Bytes("2001:db8::1", buf)
    check buf == expectV6([0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1])
    check parseIpv6Bytes("::ffff:c0a8:101", buf)
    check buf == expectV6([0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101])

  test "parses IPv4-mixed notation (ISSUE-1)":
    var buf: array[16, uint8]
    check parseIpv6Bytes("::ffff:192.168.1.1", buf)
    check buf == expectV6([0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101])
    check parseIpv6Bytes("::ffff:10.0.0.255", buf)
    check buf == expectV6([0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x00FF])
    check parseIpv6Bytes("1:2:3:4:5:6:192.168.1.1", buf)
    check buf == expectV6([1, 2, 3, 4, 5, 6, 0xC0A8, 0x0101])
    check parseIpv6Bytes("64:ff9b::198.51.100.7", buf)
    check buf == expectV6([0x0064, 0xFF9B, 0, 0, 0, 0, 0xC633, 0x6407])

  test "rejects invalid IPv6 inputs":
    var buf: array[16, uint8]
    for bad in @["1:2:3:4:5:6:7:8:9",
                 "1:2:3:4:5:6:7::8:9",
                 "::1:2:3:4:5:6:7:8:9",
                 "::1::2",
                 "::1.2.3.4",
                 "1:2:3:4:5:6:7:1.2.3.4",
                 "::1:2:3:4:5:6:7:1.2.3.4",
                 "1:2:3:4:5:6:7:8 ",
                 "gggg::1",
                 "2001:db8::1::2",
                 ""]:
      buf = default(array[16, uint8])
      check parseIpv6Bytes(bad, buf) == false

suite "ip_filter unit — parseCidr":
  test "defaults to /32 and /128 without an explicit prefix":
    let v4 = parseCidr("10.0.0.1")
    check v4.isValid
    check not v4.isV6
    check v4.prefixLen == 32
    check v4.addrBytes == expectV4(10, 0, 0, 1)
    let v6 = parseCidr("2001:db8::1")
    check v6.isValid
    check v6.isV6
    check v6.prefixLen == 128
    check v6.addrBytes == expectV6([0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1])

  test "accepts valid explicit prefixes":
    let c0 = parseCidr("10.0.0.0/0")
    check c0.isValid and c0.prefixLen == 0
    let c8 = parseCidr("10.0.0.0/8")
    check c8.isValid and c8.prefixLen == 8
    let c32 = parseCidr("10.0.0.5/32")
    check c32.isValid and c32.prefixLen == 32
    let c128 = parseCidr("::1/128")
    check c128.isValid and c128.prefixLen == 128
    let c32v6 = parseCidr("2001:db8::/32")
    check c32v6.isValid and c32v6.prefixLen == 32
    check c32v6.addrBytes == expectV6([0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0])

  test "rejects negative and out-of-range prefixes (ISSUE-3)":
    for bad in @["10.0.0.1/-1", "192.168.1.0/-1", "10.0.0.1/33",
                 "::1/-5", "::1/129"]:
      check parseCidr(bad).isValid == false

  test "rejects malformed entries":
    for bad in @["", "   ", "/24", "10.0.0.1/", "10.0.0.1/abc",
                 "not-an-ip", "10.0.0.999", "300.1.1.1/24"]:
      check parseCidr(bad).isValid == false

suite "ip_filter unit — matchesCidrBytes":
  test "IPv4 range matching":
    let c24 = parseCidr("192.168.1.0/24")
    check c24.isValid
    let (inRange, inIsV6) = clientIpBytes("192.168.1.50")
    check not inIsV6
    check matchesCidrBytes(inRange, inIsV6, c24)
    let (outRange, outIsV6) = clientIpBytes("192.168.2.50")
    check not outIsV6
    check not matchesCidrBytes(outRange, outIsV6, c24)
    let c32 = parseCidr("192.168.1.50/32")
    check matchesCidrBytes(inRange, inIsV6, c32)
    let (other, otherIsV6) = clientIpBytes("192.168.1.51")
    check not matchesCidrBytes(other, otherIsV6, c32)
    let c0 = parseCidr("0.0.0.0/0")
    check matchesCidrBytes(other, otherIsV6, c0)
    let c10 = parseCidr("10.0.0.0/10")
    let (in10, in10IsV6) = clientIpBytes("10.63.255.255")
    check matchesCidrBytes(in10, in10IsV6, c10)
    let (out10, out10IsV6) = clientIpBytes("10.64.0.0")
    check not matchesCidrBytes(out10, out10IsV6, c10)

  test "IPv6 range matching":
    let c32 = parseCidr("2001:db8::/32")
    check c32.isValid
    let (inV6, inV6Flag) = clientIpBytes("2001:db8::42")
    check inV6Flag
    check matchesCidrBytes(inV6, inV6Flag, c32)
    let (outV6, outV6Flag) = clientIpBytes("2001:db9::1")
    check not matchesCidrBytes(outV6, outV6Flag, c32)
    let c112 = parseCidr("2001:db8::/112")
    let (in112, in112Flag) = clientIpBytes("2001:db8::3")
    check matchesCidrBytes(in112, in112Flag, c112)
    let (out112, out112Flag) = clientIpBytes("2001:db8::102:3")
    check not matchesCidrBytes(out112, out112Flag, c112)

  test "cross-family matching via ::ffff: in both directions":
    let v4cidr = parseCidr("192.168.0.0/16")
    let (mapped, mappedIsV6) = clientIpBytes("::ffff:192.168.1.2")
    check mappedIsV6
    check matchesCidrBytes(mapped, mappedIsV6, v4cidr)
    let (plainV6, plainIsV6) = clientIpBytes("2001:db8::1")
    check not matchesCidrBytes(plainV6, plainIsV6, v4cidr)
    let v6cidr = parseCidr("::ffff:10.0.0.0/104")
    check v6cidr.isValid
    let (v4client, v4clientIsV6) = clientIpBytes("10.1.2.3")
    check not v4clientIsV6
    check matchesCidrBytes(v4client, v4clientIsV6, v6cidr)
    let (v4other, v4otherIsV6) = clientIpBytes("11.0.0.1")
    check not matchesCidrBytes(v4other, v4otherIsV6, v6cidr)

  test "invalid CIDR entries never match":
    let bad = CidrEntry()
    let (b, isV6) = clientIpBytes("192.168.1.1")
    check not matchesCidrBytes(b, isV6, bad)

suite "ip_filter unit — mapped IPv6 helpers":
  test "isIpv4MappedIpv6 and extractMappedIpv4":
    let (mapped, mappedIsV6) = clientIpBytes("::ffff:192.168.1.2")
    check mappedIsV6
    check isIpv4MappedIpv6(mapped)
    var v4: array[16, uint8]
    extractMappedIpv4(mapped, v4)
    check v4 == expectV4(192, 168, 1, 2)
    let (plain, plainIsV6) = clientIpBytes("2001:db8::1")
    check plainIsV6
    check not isIpv4MappedIpv6(plain)
    let (nat64, nat64IsV6) = clientIpBytes("64:ff9b::198.51.100.7")
    check nat64IsV6
    check not isIpv4MappedIpv6(nat64)

suite "ip_filter integration":
  test "allows all when no lists configured":
    let mw = ipFilter()
    let req = newMockRequest(remoteIpStr = "8.8.8.8")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200

  test "denylist blocks matching exact IP and CIDR range":
    let opts = IpFilterOptions(denylist: @["10.0.0.5", "10.0.1.0/24"])
    let mw = ipFilter(opts)
    for blocked in @["10.0.0.5", "10.0.1.77"]:
      let req = newMockRequest(remoteIpStr = blocked)
      let res = newMockResponse()
      var nextCalled = false
      runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
      check not nextCalled
      check res.statusCode == 403
    let req = newMockRequest(remoteIpStr = "10.0.2.1")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200

  test "allowlist admits matching and blocks non-matching IPs":
    let opts = IpFilterOptions(allowlist: @["192.168.1.0/24"])
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "192.168.1.50")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    let req2 = newMockRequest(remoteIpStr = "10.0.0.1")
    let res2 = newMockResponse()
    var nextCalled2 = false
    runMiddlewareChain(@[mw], req2, res2, flagHandler(addr nextCalled2))
    check not nextCalled2
    check res2.statusCode == 403

  test "denylist takes precedence over allowlist":
    let opts = IpFilterOptions(
      allowlist: @["10.0.0.0/8"],
      denylist: @["10.1.2.3"])
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "10.1.2.3")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403

  test "deny status code is honored and clamped to 4xx/5xx (ISSUE-8)":
    let opts = IpFilterOptions(denylist: @["10.0.0.5"], denyStatusCode: 451)
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "10.0.0.5")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.statusCode == 451
    let optsLow = IpFilterOptions(denylist: @["10.0.0.5"], denyStatusCode: 100)
    let mwLow = ipFilter(optsLow)
    let reqLow = newMockRequest(remoteIpStr = "10.0.0.5")
    let resLow = newMockResponse()
    runMiddlewareChain(@[mwLow], reqLow, resLow)
    check resLow.statusCode == 400
    let optsHigh = IpFilterOptions(denylist: @["10.0.0.5"], denyStatusCode: 999)
    let mwHigh = ipFilter(optsHigh)
    let reqHigh = newMockRequest(remoteIpStr = "10.0.0.5")
    let resHigh = newMockResponse()
    runMiddlewareChain(@[mwHigh], reqHigh, resHigh)
    check resHigh.statusCode == 599

  test "mixed-notation CIDR works end-to-end (ISSUE-1)":
    let opts = IpFilterOptions(allowlist: @["::ffff:10.0.0.0/104"])
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "10.1.2.3")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    let reqOut = newMockRequest(remoteIpStr = "11.0.0.1")
    let resOut = newMockResponse()
    var nextOut = false
    runMiddlewareChain(@[mw], reqOut, resOut, flagHandler(addr nextOut))
    check not nextOut
    check resOut.statusCode == 403
    let reqV6 = newMockRequest(remoteIpStr = "::ffff:10.2.0.1")
    let resV6 = newMockResponse()
    var nextV6 = false
    runMiddlewareChain(@[mw], reqV6, resV6, flagHandler(addr nextV6))
    check nextV6
    check resV6.statusCode == 200

  test "IPv6 client matching against IPv6 lists":
    let opts = IpFilterOptions(allowlist: @["2001:db8::/32"])
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "2001:db8::42")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    let reqOut = newMockRequest(remoteIpStr = "2001:db9::1")
    let resOut = newMockResponse()
    var nextOut = false
    runMiddlewareChain(@[mw], reqOut, resOut, flagHandler(addr nextOut))
    check not nextOut
    check resOut.statusCode == 403

  test "unparseable or empty client IP handling":
    let opts = IpFilterOptions(allowlist: @["10.0.0.0/8"])
    let mw = ipFilter(opts)
    let req = newMockRequest(remoteIpStr = "not-an-ip")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403
    let mwNone = ipFilter()
    let reqNone = newMockRequest(remoteIpStr = "not-an-ip")
    let resNone = newMockResponse()
    var nextNone = false
    runMiddlewareChain(@[mwNone], reqNone, resNone, flagHandler(addr nextNone))
    check nextNone
    check resNone.statusCode == 200
    let reqEmpty = newMockRequest(remoteIpStr = "")
    let resEmpty = newMockResponse()
    var nextEmpty = false
    runMiddlewareChain(@[mwNone], reqEmpty, resEmpty, flagHandler(addr nextEmpty))
    check not nextEmpty
    check resEmpty.statusCode == 403

  test "invalid CIDR entries are skipped and onWarning fires (ISSUE-7)":
    var warnings: seq[string] = @[]
    var opts = defaultIpFilterOptions()
    opts.denylist = @["garbage-entry", "10.0.0.5"]
    opts.onWarning = proc(msg: string) =
      warnings.add(msg)
    let mw = ipFilter(opts)
    check warnings.len == 1
    check warnings[0].find("garbage-entry") >= 0
    let req = newMockRequest(remoteIpStr = "10.0.0.5")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 403
    let reqOk = newMockRequest(remoteIpStr = "8.8.8.8")
    let resOk = newMockResponse()
    var nextOk = false
    runMiddlewareChain(@[mw], reqOk, resOk, flagHandler(addr nextOk))
    check nextOk
    check resOk.statusCode == 200

  test "trusted forwarded IP is used when proxy headers are trusted (ISSUE-4)":
    let req = newMockRequest(
      remoteIpStr = "127.0.0.1",
      headerMap = @[("x-forwarded-for", "203.0.113.7, 10.0.0.1, 127.0.0.1")])
    req.trustedProxyHopCount = 2
    var opts = defaultIpFilterOptions()
    opts.allowlist = @["203.0.113.0/24"]
    opts.trustProxy = true
    let mw = ipFilter(opts)
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    let reqNoXff = newMockRequest(remoteIpStr = "127.0.0.1")
    reqNoXff.trustedProxyHopCount = 2
    let resNoXff = newMockResponse()
    var nextNoXff = false
    runMiddlewareChain(@[mw], reqNoXff, resNoXff, flagHandler(addr nextNoXff))
    check not nextNoXff
    check resNoXff.statusCode == 403
