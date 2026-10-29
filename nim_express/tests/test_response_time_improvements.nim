import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/response_time
import ../src/nim_express/middlewares/compression
import ../src/nim_express/middlewares/etag
import std/json

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

proc timingProbeHandler(probe: ptr string): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    probe[] = res.get("X-Response-Time")
    if not res.finished:
      res.status(200)
      res.send("ok")

# Splits "12.345ms" into (true, 12.345); validates the "<digits>.<3 digits>ms"
# structure produced by formatFloat(ms, ffDecimal, 3) & "ms".
proc parseMsValue(value: string): (bool, float) =
  if value.len <= 2 or value[^2] != 'm' or value[^1] != 's':
    return (false, 0.0)
  let num = value[0 ..^ 3]
  let dot = num.find('.')
  if dot < 1 or num[dot + 1 ..^ 1].len != 3:
    return (false, 0.0)
  var intPart = 0.0
  for c in num[0 ..< dot]:
    if c notin {'0'..'9'}:
      return (false, 0.0)
    intPart = intPart * 10.0 + (ord(c) - ord('0')).float
  var fracPart = 0.0
  for c in num[dot + 1 ..^ 1]:
    if c notin {'0'..'9'}:
      return (false, 0.0)
    fracPart = fracPart * 10.0 + (ord(c) - ord('0')).float
  result = (true, intPart + fracPart / 1000.0)

suite "response_time unit":
  test "defaultResponseTimeOptions uses the default header name (ISSUE-4)":
    let d = defaultResponseTimeOptions()
    check d.headerName == defaultResponseTimeHeaderName
    check d.headerName == "X-Response-Time"

  test "normalizeResponseTimeHeaderName passes valid tokens through (ISSUE-4)":
    check normalizeResponseTimeHeaderName("X-Response-Time") == "X-Response-Time"
    check normalizeResponseTimeHeaderName("x-custom-time") == "x-custom-time"
    check normalizeResponseTimeHeaderName("X_Custom-Time.9") == "X_Custom-Time.9"

  test "normalizeResponseTimeHeaderName falls back on empty/invalid names (ISSUE-4)":
    check normalizeResponseTimeHeaderName("") == defaultResponseTimeHeaderName
    check normalizeResponseTimeHeaderName("bad header") == defaultResponseTimeHeaderName
    check normalizeResponseTimeHeaderName("bad\thdr") == defaultResponseTimeHeaderName
    check normalizeResponseTimeHeaderName("a/b") == defaultResponseTimeHeaderName
    check normalizeResponseTimeHeaderName("Set-Cookie") == "Set-Cookie"

suite "response_time integration":
  test "default middleware sets X-Response-Time in <ms>.<3 digits>ms format":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[responseTime()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.finished
    let v = res.get("X-Response-Time")
    check v.len > 0
    var parsedOk: bool
    var ms: float
    (parsedOk, ms) = parseMsValue(v)
    check parsedOk
    check ms >= 0.0

  test "custom header name is honored and default is not set":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(
      @[responseTime(ResponseTimeOptions(headerName: "X-Custom-Time"))],
      req, res, flagHandler(addr nextCalled))
    check nextCalled
    let v = res.get("X-Custom-Time")
    check v.len > 0
    var parsedOk: bool
    var ms: float
    (parsedOk, ms) = parseMsValue(v)
    check parsedOk
    check res.get("X-Response-Time").len == 0

  test "invalid custom header name falls back to default at construction (ISSUE-4)":
    let req = newMockRequest()
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(
      @[responseTime(ResponseTimeOptions(headerName: "bad header"))],
      req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.get("X-Response-Time").len > 0

  test "header is absent during next() and written at finalization (ISSUE-5)":
    let req = newMockRequest()
    let res = newMockResponse()
    var duringNext = ""
    runMiddlewareChain(@[responseTime()], req, res, timingProbeHandler(addr duringNext))
    check duringNext == ""
    let v = res.get("X-Response-Time")
    check v.len > 0
    var parsedOk: bool
    var ms: float
    (parsedOk, ms) = parseMsValue(v)
    check parsedOk

  test "header survives alongside an upstream middleware in the chain":
    let req = newMockRequest()
    let res = newMockResponse()
    res.set("X-Upstream", "1")
    var nextCalled = false
    let upstream: AsyncMiddleware =
      proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
        await next()
    runMiddlewareChain(@[upstream, responseTime()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.get("X-Upstream") == "1"
    var parsedOk: bool
    var ms: float
    (parsedOk, ms) = parseMsValue(res.get("X-Response-Time"))
    check parsedOk

suite "response_time fixed-precision formatter (audit MWA-004)":
  test "renders byte-identically to the float path it replaced":
    ## The value is derived from whole microseconds, so the millisecond figure
    ## has at most 3 exact decimals and the integer renderer cannot round
    ## differently. Sweep it anyway: a previous float-format swap in this repo
    ## silently differed on tens of thousands of sampled values.
    var checked = 0
    var mismatches = 0
    var firstMismatch = ""
    proc expect(us: int64) =
      let want = formatFloat(us.float / 1_000.0, ffDecimal, 3) & "ms"
      let got = renderElapsedMsForTest(us)
      if got != want:
        if mismatches == 0:
          firstMismatch = "us=" & $us & " want=" & want & " got=" & got
        inc mismatches
      inc checked
    for us in 0'i64 .. 200_000'i64:
      expect(us)
    for edge in [999'i64, 1_000, 1_001, 1_009, 1_042, 999_999, 1_000_000,
                 1_000_001, 1_500_000, 12_345_678, 999_999_999_999,
                 1_000_000_000_000, 3_600_000_000]:
      expect(edge)
    check checked > 200_000
    if mismatches != 0:
      echo "firstMismatch=", firstMismatch
    check mismatches == 0

  test "header is stored under the lowercase name and still parses":
    var nextCalled = false
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[responseTime()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.headers.contains("x-response-time")
    check res.headers.getOrDefault("x-response-time", "").endsWith("ms")

# --------------------------------------------------------------------------------
# json() fast-path wire contract.
#
# The non-typed `json` overloads were moved onto the same framing path the typed
# `json[T]` overload already uses (precomputed `content-type` header line + the
# simple framed writer) instead of `contentType()` + `send()`. These tests pin the
# emitted bytes so the rewrite is provably wire-identical. `expectedJsonHeader`
# was captured from the pre-change build (`nim c ... probe/c3_jsonstring_probe.nim`
# run with the `wire` argument) and is asserted unchanged.
# --------------------------------------------------------------------------------

const JsonCrlf = "\c\L"
const JsonContentTypeLine = "content-type: application/json; charset=utf-8"

proc expectedJsonHeader(statusLine, bodyLen, body: string): string =
  statusLine & JsonCrlf & JsonContentTypeLine & JsonCrlf &
    "connection: keep-alive" & JsonCrlf & "content-length: " & bodyLen & JsonCrlf &
    JsonCrlf & body

proc jsonHeaderBlock(raw: string): string =
  let idx = raw.find(JsonCrlf & JsonCrlf)
  if idx < 0: raw
  else: raw[0 ..< idx]

proc jsonBodyBlock(raw: string): string =
  let idx = raw.find(JsonCrlf & JsonCrlf)
  if idx < 0: ""
  else: raw[idx + 4 ..< raw.len]

proc countHeaderLine(header, name: string): int =
  for line in header.split(JsonCrlf):
    if line.len >= name.len and line[0 ..< name.len] == name:
      inc result

proc newJsonMockResponse(
  methodKind: HttpMethod = hmGet,
  headerMap: seq[(string, string)] = @[]
): Response =
  # Unlike newMockResponse this leaves headersInited = false, which is the state a
  # fresh response is in when a handler calls json() directly.
  let req = newMockRequest("/", methodKind, headerMap = headerMap)
  new(result)
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = methodKind
  nativeRes.connectionClose = false
  result.native = nativeRes
  result.request = req
  result.app = nil
  result.viewsDir = "views"
  result.viewExt = ""
  result.requestMethodKind = methodKind
  result.statusCode = 200
  result.finished = false
  result.compress = false
  result.compressEncoding = ""
  result.headerBuf = newStringOfCap(256)
  result.droppedLateWrites = 0
  result.headers = newFastMap[string]()
  discard result.headers.reserve(16)
  result.locals = newFastMap[string]()
  discard result.locals.reserve(4)

proc jsonStrWriter(payload: ptr string): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    res.json(payload[])

proc jsonNodeWriter(payload: ptr string): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    res.json(parseJson(payload[]))

proc jsonRawWriter(payload: ptr string): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    res.jsonRaw(payload[])

proc runJsonThrough(mws: seq[AsyncMiddleware], res: Response,
                    writer: proc(req: Request, res: Response): Future[void]) =
  runMiddlewareChain(mws, res.request, res, writer)

test "json(string)/json(JsonNode) emit exactly one exact content-type line and the same body":
  let payload = "{\"a\":1}"
  let expected = expectedJsonHeader("HTTP/1.1 200 OK", $payload.len, payload)

  let resStr = newJsonMockResponse()
  resStr.json(payload)
  check resStr.native.capturedRaw == expected
  check countHeaderLine(jsonHeaderBlock(resStr.native.capturedRaw), "content-type") == 1
  check jsonBodyBlock(resStr.native.capturedRaw) == payload

  let resNode = newJsonMockResponse()
  resNode.json(parseJson(payload))
  check resNode.native.capturedRaw == expected
  check countHeaderLine(jsonHeaderBlock(resNode.native.capturedRaw), "content-type") == 1
  check jsonBodyBlock(resNode.native.capturedRaw) == payload

  # A nil JsonNode keeps the literal "null" body with the same header block.
  let resNil = newJsonMockResponse()
  resNil.json(JsonNode(nil))
  check resNil.native.capturedRaw ==
    expectedJsonHeader("HTTP/1.1 200 OK", "4", "null")

test "json(string) matches the already-shipped jsonRaw framing under compression":
  var payload = "{\"rows\":["
  for i in 0 ..< 400:
    payload.add("{\"i\":" & $i & ",\"s\":\"value-" & $i & "\"},")
  payload.add("{\"i\":400,\"s\":\"tail\"}]}")
  doAssert payload.len > MinCompressSize

  let gzHeaders = @[("accept-encoding", "gzip")]
  let resStr = newJsonMockResponse(headerMap = gzHeaders)
  runJsonThrough(@[compression()], resStr, jsonStrWriter(addr payload))
  let rawStr = resStr.native.capturedRaw
  let hdrStr = jsonHeaderBlock(rawStr)
  check resStr.statusCode == 200
  check countHeaderLine(hdrStr, "content-type") == 1
  check hdrStr.contains(JsonContentTypeLine)
  check countHeaderLine(hdrStr, "content-encoding") == 1
  check hdrStr.contains("content-encoding: gzip")
  check jsonBodyBlock(rawStr) != payload
  # content-length must describe the compressed body that was actually written.
  check hdrStr.contains("content-length: " & $jsonBodyBlock(rawStr).len)

  # Behaviour equality: the already-shipped jsonRaw path must produce the same bytes.
  let resRef = newJsonMockResponse(headerMap = gzHeaders)
  runJsonThrough(@[compression()], resRef, jsonRawWriter(addr payload))
  check rawStr == resRef.native.capturedRaw

  # identity encoding (no accept-encoding) stays uncompressed and single-valued.
  let resPlain = newJsonMockResponse()
  runJsonThrough(@[compression()], resPlain, jsonStrWriter(addr payload))
  check countHeaderLine(jsonHeaderBlock(resPlain.native.capturedRaw), "content-type") == 1
  check countHeaderLine(jsonHeaderBlock(resPlain.native.capturedRaw), "content-encoding") == 0
  check jsonBodyBlock(resPlain.native.capturedRaw) == payload

test "json(string) under etag agrees with jsonRaw for 304 and HEAD":
  let payload = "{\"a\":1}"

  # Precomputed headers for the jsonRaw baseline, captured from the pre-change build.
  var payloadRef = payload
  let resRef304 = newJsonMockResponse(headerMap = @[("if-none-match", "placeholder")])
  runJsonThrough(@[etag()], resRef304, jsonRawWriter(addr payloadRef))
  let etagValue = resRef304.headers.getOrDefault("etag", "")
  check etagValue.len > 0

  let matchHeaders = @[("if-none-match", etagValue)]
  let resStr304 = newJsonMockResponse(headerMap = matchHeaders)
  runJsonThrough(@[etag()], resStr304, jsonStrWriter(addr payloadRef))
  check resStr304.statusCode == 304
  check jsonBodyBlock(resStr304.native.capturedRaw).len == 0
  check countHeaderLine(jsonHeaderBlock(resStr304.native.capturedRaw), "content-type") == 0
  let resRef304b = newJsonMockResponse(headerMap = matchHeaders)
  runJsonThrough(@[etag()], resRef304b, jsonRawWriter(addr payloadRef))
  check resStr304.native.capturedRaw == resRef304b.native.capturedRaw

  # HEAD: headers present, no body, exactly one content-type line.
  let resHead = newJsonMockResponse(hmHead)
  runJsonThrough(@[etag()], resHead, jsonStrWriter(addr payloadRef))
  check resHead.statusCode == 200
  check jsonBodyBlock(resHead.native.capturedRaw).len == 0
  check countHeaderLine(jsonHeaderBlock(resHead.native.capturedRaw), "content-type") == 1
  let resHeadRef = newJsonMockResponse(hmHead)
  runJsonThrough(@[etag()], resHeadRef, jsonRawWriter(addr payloadRef))
  check resHead.native.capturedRaw == resHeadRef.native.capturedRaw
  check resHead.native.capturedRaw.contains("content-length: " & $payload.len)

test "user-set content-type still wins over the json fast path":
  let payload = "{\"a\":1}"
  let res = newJsonMockResponse()
  discard res.set("content-type", "application/json")
  res.json(payload)
  let hdr = jsonHeaderBlock(res.native.capturedRaw)
  check countHeaderLine(hdr, "content-type") == 1
  check hdr.contains("content-type: application/json")
  check not hdr.contains("content-type: application/json; charset=utf-8")
  check jsonBodyBlock(res.native.capturedRaw) == payload

test "json fast path keeps content-type readable through get and getView":
  let payload = "{\"a\":1}"

  let resStr = newJsonMockResponse()
  resStr.json(payload)
  check resStr.get("content-type").find("application/json") >= 0
  check resStr.get("content-type") == "application/json; charset=utf-8"
  # The fast path must not have created a headers-map entry.
  check not resStr.headersInited

  let resNode = newJsonMockResponse()
  resNode.json(parseJson("{\"a\":1}"))
  check resNode.get("content-type").find("application/json") >= 0
  check resNode.get("content-type") == "application/json; charset=utf-8"

  # getView reports the same bytes as get on the fast path.
  let view = resStr.getView("content-type")
  check view.len == resStr.get("content-type").len
  check $view == resStr.get("content-type")

  # Unrelated headers are unaffected by the fallback.
  check resStr.get("x-nope") == ""

test "headers map still wins over the json fast path content type":
  let payload = "{\"a\":1}"

  # User-set value before the write: the map value is what goes on the wire.
  let resBefore = newJsonMockResponse()
  discard resBefore.set("content-type", "application/json; x=1")
  resBefore.json(payload)
  check resBefore.get("content-type") == "application/json; x=1"
  let hdrBefore = jsonHeaderBlock(resBefore.native.capturedRaw)
  check countHeaderLine(hdrBefore, "content-type") == 1
  check hdrBefore.contains("content-type: application/json; x=1")
  check not hdrBefore.contains("charset=utf-8")

  # User-set value after the write: `set` is guarded by `finished`, so the call is a
  # no-op for both the map and the already-emitted wire. Readers and the wire stay
  # in agreement (this is the same shape as before the fast path existed).
  let resAfter = newJsonMockResponse()
  resAfter.json(payload)
  discard resAfter.set("content-type", "application/json; x=1")
  check resAfter.get("content-type") == "application/json; charset=utf-8"
  let hdrAfter = jsonHeaderBlock(resAfter.native.capturedRaw)
  check countHeaderLine(hdrAfter, "content-type") == 1
  check hdrAfter.contains(JsonContentTypeLine)
  check not hdrAfter.contains("x=1")

test "removeHeader clears the json fast path content type when it can act":
  let payload = "{\"a\":1}"

  # removeHeader is a no-op once the response is finished (pre-existing guard);
  # the emitted wire and the readable value must still agree.
  let resAfter = newJsonMockResponse()
  resAfter.json(payload)
  discard resAfter.removeHeader("content-type")
  check resAfter.get("content-type") == "application/json; charset=utf-8"
  check countHeaderLine(jsonHeaderBlock(resAfter.native.capturedRaw), "content-type") == 1

  # Before the write the removal is effective: no map key, so the json fast path
  # supplies its own line and get reports exactly what the wire carries.
  let resBefore = newJsonMockResponse()
  discard resBefore.set("content-type", "application/json; x=1")
  discard resBefore.removeHeader("content-type")
  resBefore.json(payload)
  let hdr = jsonHeaderBlock(resBefore.native.capturedRaw)
  check countHeaderLine(hdr, "content-type") == 1
  check hdr.contains(JsonContentTypeLine)
  check resBefore.get("content-type") == "application/json; charset=utf-8"

  # Removing without any json write leaves the read empty.
  let resEmpty = newJsonMockResponse()
  discard resEmpty.set("content-type", "text/plain")
  discard resEmpty.removeHeader("content-type")
  check resEmpty.get("content-type") == ""
