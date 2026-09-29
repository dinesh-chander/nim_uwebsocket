import std/[unittest, asyncdispatch, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/opentelemetry

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

proc sendOkHandler(): proc(r: Request, s: Response): Future[void] =
  result = proc(r: Request, s: Response): Future[void] {.async.} =
    s.status(200)
    s.send("ok")

proc existingTimingHandler(): proc(r: Request, s: Response): Future[void] =
  result = proc(r: Request, s: Response): Future[void] {.async.} =
    s.set("server-timing", "db;dur=2.500")
    s.status(200)
    s.send("ok")

proc isLowerHex(s: string, expectedLen: int): bool =
  if s.len != expectedLen:
    return false
  for c in s:
    if not (c in {'0'..'9'} or c in {'a'..'f'}):
      return false
  true

const SampledTraceId = "4bf92f3577b34da6a3ce929d0e0e4736"
const SampledParentSpanId = "00f067aa0ba902b7"

suite "opentelemetry unit":
  test "isHexToken: length and character validation":
    check isHexToken("01", 2)
    check isHexToken("deadbeef", 8)
    check not isHexToken("012", 2)
    check not isHexToken("01", 3)
    check not isHexToken("g1", 2)
    check not isHexToken("AB", 2)
    check not isHexToken("", 0) == false

  test "parseTraceParent: valid header parsed and normalized to lowercase":
    let r = parseTraceParent(" 00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01 ")
    check r.ok
    check r.traceId == SampledTraceId
    check r.parentSpanId == SampledParentSpanId
    check r.flags == "01"

  test "parseTraceParent: malformed headers rejected":
    check not parseTraceParent("").ok
    check not parseTraceParent("   ").ok
    check not parseTraceParent("00-abc").ok
    check not parseTraceParent("zz-" & SampledTraceId & "-" & SampledParentSpanId & "-01").ok
    check not parseTraceParent("00-" & SampledTraceId[0 ..< 31] & "-" & SampledParentSpanId & "-01").ok
    check not parseTraceParent("00-" & SampledTraceId & "-g" & SampledParentSpanId[1 ..^ 1] & "-01").ok
    check not parseTraceParent("00-00000000000000000000000000000000-" & SampledParentSpanId & "-01").ok
    check not parseTraceParent("00-" & SampledTraceId & "-0000000000000000-01").ok
    check not parseTraceParent("00-" & SampledTraceId & "-" & SampledParentSpanId & "-z1").ok

  test "httpMethodLabel maps every HttpMethod (ISSUE-2)":
    check httpMethodLabel(hmGet) == "GET"
    check httpMethodLabel(hmPost) == "POST"
    check httpMethodLabel(hmPut) == "PUT"
    check httpMethodLabel(hmDelete) == "DELETE"
    check httpMethodLabel(hmPatch) == "PATCH"
    check httpMethodLabel(hmHead) == "HEAD"
    check httpMethodLabel(hmOptions) == "OPTIONS"
    check httpMethodLabel(hmConnect) == "CONNECT"
    check httpMethodLabel(hmTrace) == "TRACE"

  test "randomHex16: 16 lowercase hex chars, unique per call (ISSUE-3)":
    let a = randomHex16()
    let b = randomHex16()
    check isLowerHex(a, 16)
    check isLowerHex(b, 16)
    check a != b

  test "randomHex32: 32 lowercase hex chars, unique per call (ISSUE-3)":
    let a = randomHex32()
    let b = randomHex32()
    check isLowerHex(a, 32)
    check isLowerHex(b, 32)
    check a != b
    check a != "00000000000000000000000000000000"

  test "sanitizeOperationPath strips control characters":
    check sanitizeOperationPath("/api/users/42") == "/api/users/42"
    check sanitizeOperationPath("/a\x01b\x7fc") == "/abc"
    check sanitizeOperationPath("x\x00y") == "xy"
    check sanitizeOperationPath("") == ""

  test "sanitizeOperationPath truncates long ASCII paths at 200 bytes":
    check sanitizeOperationPath(repeat("x", 250)) == repeat("x", 200)
    check sanitizeOperationPath(repeat("x", 200)).len == 200
    check sanitizeOperationPath(repeat("x", 199)).len == 199

  test "sanitizeOperationPath truncation never splits multi-byte UTF-8 (ISSUE-5)":
    check sanitizeOperationPath(repeat("a", 199) & "€") == repeat("a", 199)
    check sanitizeOperationPath(repeat("a", 198) & "€") == repeat("a", 198)
    check sanitizeOperationPath(repeat("a", 200) & "€") == repeat("a", 200)
    check sanitizeOperationPath(repeat("é", 100)) == repeat("é", 100)

  test "localKey builds prefixed or flat keys (ISSUE-7)":
    check localKey("otel", "trace_id") == "otel.trace_id"
    check localKey("custom", "span_id") == "custom.span_id"
    check localKey("", "trace_id") == "trace_id"

suite "opentelemetry middleware":
  test "no incoming traceparent: fresh ids, locals, sampled, traceparent response header":
    let mw = openTelemetry()
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let tid = req.local("otel.trace_id")
    let sid = req.local("otel.span_id")
    check isLowerHex(tid, 32)
    check isLowerHex(sid, 16)
    check req.local("otel.parent_span_id") == ""
    check req.local("otel.trace_flags") == "01"
    check req.local("otel.sampled") == "1"
    check req.local("otel.operation") == "GET /"
    check res.get("traceparent") == "00-" & tid & "-" & sid & "-01"

  test "incoming sampled traceparent: trace id propagated, parent link preserved":
    let mw = openTelemetry()
    let req = newMockRequest("/users", hmGet, "", "127.0.0.1",
      @[("traceparent", "00-" & SampledTraceId & "-" & SampledParentSpanId & "-01")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check req.local("otel.trace_id") == SampledTraceId
    check req.local("otel.parent_span_id") == SampledParentSpanId
    check req.local("otel.sampled") == "1"
    check req.local("otel.operation") == "GET /users"
    let outHeader = res.get("traceparent")
    check outHeader.len == 55
    check outHeader.startsWith("00-" & SampledTraceId & "-")
    check outHeader.endsWith("-01")
    check isLowerHex(outHeader[36 .. 51], 16)

  test "incoming non-sampled traceparent (flags 00): sampled local is 0":
    let mw = openTelemetry()
    let req = newMockRequest()
    req.native.headers["traceparent"] =
      "00-" & SampledTraceId & "-" & SampledParentSpanId & "-00"
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check req.local("otel.sampled") == "0"
    check req.local("otel.trace_id") == SampledTraceId

  test "invalid incoming traceparent: new ids generated instead":
    let mw = openTelemetry()
    let req = newMockRequest()
    req.native.headers["traceparent"] = "garbage"
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check isLowerHex(req.local("otel.trace_id"), 32)
    check req.local("otel.trace_flags") == "01"
    check req.local("otel.sampled") == "1"
    check req.local("otel.parent_span_id") == ""

  test "custom localPrefix: keys use the custom prefix, default prefix unused":
    var opts = initOpenTelemetryOptions()
    opts.localPrefix = "trace"
    let mw = openTelemetry(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check req.local("trace.trace_id").len == 32
    check req.local("trace.span_id").len == 16
    check req.local("trace.operation") == "GET /"
    check req.local("otel.trace_id") == ""

  test "empty localPrefix yields flat keys (ISSUE-7)":
    var opts = initOpenTelemetryOptions()
    opts.localPrefix = ""
    let mw = openTelemetry(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check req.local("trace_id").len == 32
    check req.local("span_id").len == 16
    check req.local("operation") == "GET /"
    check req.local("otel.trace_id") == ""

  test "operationName override wins over method+path; default uses method label":
    var opts = initOpenTelemetryOptions()
    opts.operationName = "checkout"
    let mw = openTelemetry(opts)
    let req = newMockRequest("/cart/items/9", hmPost)
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check req.local("otel.operation") == "checkout"

    let mw2 = openTelemetry()
    let req2 = newMockRequest("/items", hmPost)
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw2], req2, res2)
    check req2.local("otel.operation") == "POST /items"

  test "setTraceResponseHeader=false omits the traceparent response header":
    var opts = initOpenTelemetryOptions()
    opts.setTraceResponseHeader = false
    let mw = openTelemetry(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check res.get("traceparent") == ""
    check req.local("otel.trace_id").len == 32

  test "onSpanStart/onSpanEnd receive span context and non-negative duration":
    var startTrace = ""
    var startSampled = false
    var startOp = ""
    var endTrace = ""
    var endDur = -1'i64
    var opts = initOpenTelemetryOptions()
    opts.onSpanStart = proc(req: Req, span: OtelSpanContext) =
      startTrace = span.traceId
      startSampled = span.sampled
      startOp = span.operation
    opts.onSpanEnd = proc(req: Req, res: Res, span: OtelSpanContext, durationMicros: int64) =
      endTrace = span.traceId
      endDur = durationMicros
    let mw = openTelemetry(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check isLowerHex(startTrace, 32)
    check startSampled
    check startOp == "GET /"
    check endTrace == startTrace
    check endDur >= 0

  test "failing onSpanStart hook is contained and reported via onHookError (ISSUE-6)":
    var errPhase = ""
    var errCount = 0
    var opts = initOpenTelemetryOptions()
    opts.onSpanStart = proc(req: Req, span: OtelSpanContext) =
      raise newException(ValueError, "start hook boom")
    opts.onHookError = proc(phase: string, err: ref CatchableError) =
      inc errCount
      errPhase = phase
      check err.msg.len > 0
    let mw = openTelemetry(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check errCount == 1
    check errPhase == "span_start"
    check req.local("otel.trace_id").len == 32

  test "failing onSpanEnd hook is contained and reported via onHookError (ISSUE-6)":
    var errPhase = ""
    var errCount = 0
    var opts = initOpenTelemetryOptions()
    opts.onSpanEnd = proc(req: Req, res: Res, span: OtelSpanContext, durationMicros: int64) =
      raise newException(ValueError, "end hook boom")
    opts.onHookError = proc(phase: string, err: ref CatchableError) =
      inc errCount
      errPhase = phase
    let mw = openTelemetry(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check errCount == 1
    check errPhase == "span_end"

  test "server-timing trace metric survives handler send() (ISSUE-1)":
    var opts = initOpenTelemetryOptions()
    opts.includeServerTiming = true
    let mw = openTelemetry(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, sendOkHandler())
    check res.finished
    let tid = req.local("otel.trace_id")
    let st = res.get("server-timing")
    check st.contains("trace;desc=\"" & tid & "\";dur=")

  test "server-timing trace metric written when response is not finalized via send":
    var opts = initOpenTelemetryOptions()
    opts.includeServerTiming = true
    let mw = openTelemetry(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check not res.finished
    let st = res.get("server-timing")
    check st.contains("trace;desc=\"" & req.local("otel.trace_id") & "\";dur=")

  test "server-timing coexists with a pre-existing metric via comma append (ISSUE-1)":
    var opts = initOpenTelemetryOptions()
    opts.includeServerTiming = true
    let mw = openTelemetry(opts)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, existingTimingHandler())
    let st = res.get("server-timing")
    check st.contains("db;dur=2.500")
    check st.contains("trace;desc=\"")
    check st.contains(", ")
    check st.find("db;dur=2.500") < st.find("trace;desc=")
