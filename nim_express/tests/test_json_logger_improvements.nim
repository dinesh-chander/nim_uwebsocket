import std/[unittest, asyncdispatch, strutils, json, random]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/json_logger

type
  JsonLoggerTestErr* = object of CatchableError
  JsonLoggerDeepErr* = object of CatchableError

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

proc makeLoggerOpts(
  sink: JsonLogSink,
  includeFields: set[JsonLogField] = defaultJsonLoggerOptions().includeFields,
  excludeFields: set[JsonLogField] = {},
  skipPaths: seq[string] = @[],
  skipHealthChecks: bool = true
): JsonLoggerOptions =
  JsonLoggerOptions(
    sink: sink,
    includeFields: includeFields,
    excludeFields: excludeFields,
    skipPaths: skipPaths,
    skipHealthChecks: skipHealthChecks
  )

proc oracleIso8601(t: float): string =
  ## Independent loop-based decomposition used to cross-check
  ## appendIso8601Ms (avoids the same closed-form date math).
  let totalMs = int64(t * 1000.0)
  let ms = int(totalMs mod 1000)
  let secs = totalMs div 1000
  var days = secs div 86400
  let rem = secs mod 86400
  let hh = int(rem div 3600)
  let mi = int((rem mod 3600) div 60)
  let ss = int(rem mod 60)
  var y = 1970
  while true:
    let leap = (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0
    let dy = if leap: 366 else: 365
    if days < dy: break
    days -= dy
    y += 1
  let leap = (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0
  var m = 1
  while true:
    var dim = 31
    case m
    of 4, 6, 9, 11:
      dim = 30
    of 2:
      dim = if leap: 29 else: 28
    else:
      discard
    if days < dim: break
    days -= dim
    m += 1
  let d = int(days) + 1
  proc p2(v: int): string =
    if v < 10: "0" & $v else: $v
  let msStr = if ms < 10: "00" & $ms
              elif ms < 100: "0" & $ms
              else: $ms
  result = $y & "-" & p2(m) & "-" & p2(d) & "T" & p2(hh) & ":" & p2(mi) &
           ":" & p2(ss) & "." & msStr & "Z"

proc isTimestampShape(ts: string): bool =
  if ts.len != 24:
    return false
  if ts[4] != '-' or ts[7] != '-' or ts[10] != 'T' or ts[13] != ':' or
     ts[16] != ':' or ts[19] != '.' or ts[23] != 'Z':
    return false
  for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 22]:
    if ts[i] < '0' or ts[i] > '9':
      return false
  true

suite "json_logger — pure helpers":

  test "escapeJsonString passes plain text through":
    check escapeJsonString("hello world") == "hello world"
    check escapeJsonString("") == ""

  test "escapeJsonString escapes quotes and backslashes":
    check escapeJsonString("a\"b") == "a\\\"b"
    check escapeJsonString("a\\b") == "a\\\\b"

  test "escapeJsonString escapes common control characters":
    check escapeJsonString("a\nb") == "a\\nb"
    check escapeJsonString("a\rb") == "a\\rb"
    check escapeJsonString("a\tb") == "a\\tb"
    check escapeJsonString("a\bb") == "a\\bb"
    check escapeJsonString("a\fb") == "a\\fb"

  test "escapeJsonString uses unicode escapes for remaining control chars":
    check escapeJsonString("a\1b") == "a\\u0001b"
    check escapeJsonString("a\x0fb") == "a\\u000Fb"
    check escapeJsonString("a\x7fb") == "a\\u007Fb"

  test "escapeJsonString output round-trips through a JSON parser":
    let raw = "line1\nline2\t\"quoted\" \1 \127 \b \f"
    check getStr(parseJson("\"" & escapeJsonString(raw) & "\"")) == raw

  test "isHealthPath matches default and custom skip paths":
    check isHealthPath("/health", @[])
    check isHealthPath("/healthz", @[])
    check isHealthPath("/ready", @[])
    check isHealthPath("/readyz", @[])
    check isHealthPath("/livez", @[])
    check not isHealthPath("/api", @[])
    check isHealthPath("/custom", @["/custom"])
    check not isHealthPath("/custom2", @["/custom"])

  test "shouldInclude honours include and exclude sets":
    let opts = defaultJsonLoggerOptions()
    check opts.shouldInclude(jlfMethod)
    check opts.shouldInclude(jlfError)
    var ex = opts
    ex.excludeFields = {jlfRemoteIp, jlfUserAgent}
    check not ex.shouldInclude(jlfRemoteIp)
    check not ex.shouldInclude(jlfUserAgent)
    check ex.shouldInclude(jlfMethod)
    var inc = defaultJsonLoggerOptions()
    inc.includeFields = {jlfPath, jlfStatus}
    check inc.shouldInclude(jlfPath)
    check inc.shouldInclude(jlfStatus)
    check not inc.shouldInclude(jlfMethod)
    var both = inc
    both.excludeFields = {jlfPath}
    check not both.shouldInclude(jlfPath)

  test "appendFloatDec matches formatFloat(ffDecimal, 3) shape":
    var s = ""
    appendFloatDec(s, 0.0)
    check s == "0.000"
    s = ""
    appendFloatDec(s, 12.345)
    check s == "12.345"
    s = ""
    appendFloatDec(s, 12.3456)
    check s == "12.346"
    s = ""
    appendFloatDec(s, -0.5)
    check s == "-0.500"
    s = ""
    appendFloatDec(s, 1000000.25)
    check s == "1000000.250"
    s = ""
    appendFloatDec(s, 0.9999)
    check s == "1.000"
    s = ""
    appendFloatDec(s, 99.9996)
    check s == "100.000"
    s = ""
    appendFloatDec(s, 0.0004)
    check s == "0.000"
    s = ""
    appendFloatDec(s, 12.345, 2)
    check s == "12.35"
    s = ""
    appendFloatDec(s, 12.0, 0)
    check s == "12"

  test "appendIso8601Ms known fixed values":
    var s = ""
    appendIso8601Ms(s, 0.0)
    check s == "1970-01-01T00:00:00.000Z"
    s = ""
    appendIso8601Ms(s, 86399.5)
    check s == "1970-01-01T23:59:59.500Z"
    s = ""
    appendIso8601Ms(s, 1000000000.0)
    check s == "2001-09-09T01:46:40.000Z"
    s = ""
    appendIso8601Ms(s, 1136073600.0)
    check s == "2006-01-01T00:00:00.000Z"
    s = ""
    appendIso8601Ms(s, 1262304000.0)
    check s == "2010-01-01T00:00:00.000Z"
    s = ""
    appendIso8601Ms(s, 1577836800.0)
    check s == "2020-01-01T00:00:00.000Z"
    s = ""
    appendIso8601Ms(s, 1700000000.0)
    check s == "2023-11-14T22:13:20.000Z"
    s = ""
    appendIso8601Ms(s, 951782400.0)
    check s == "2000-02-29T00:00:00.000Z"
    s = ""
    appendIso8601Ms(s, 951868800.0)
    check s == "2000-03-01T00:00:00.000Z"
    s = ""
    appendIso8601Ms(s, 4102444800.0)
    check s == "2100-01-01T00:00:00.000Z"

  test "appendIso8601Ms matches an independent oracle for random epochs":
    var rng = initRand(12345)
    for i in 0 ..< 500:
      let k = int(rng.next() mod 4_000_000_001'u64)
      let t = float(k)
      var s = ""
      appendIso8601Ms(s, t)
      check s == oracleIso8601(t)
    for i in 0 ..< 200:
      let k = int(rng.next() mod 4_000_000_001'u64)
      let t = float(k) + 0.5
      var s = ""
      appendIso8601Ms(s, t)
      check s == oracleIso8601(t)

suite "json_logger — middleware integration":

  test "emits a well-formed NDJSON line with all optional fields":
    var logLine = ""
    let opts = makeLoggerOpts(proc(line: string) = logLine = line)
    let req = newMockRequest("/api/items", hmGet, "", "10.0.0.5",
      @[("user-agent", "test-agent/1.0"), ("content-length", "42")])
    req.locals["requestId"] = "req-123"
    req.locals["traceId"] = "trace-abc"
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req, res)
    check logLine.len > 0
    check logLine[0] == '{'
    check logLine[^1] == '}'
    check '\n' notin logLine
    let j = parseJson(logLine)
    check getStr(j["method"]) == "GET"
    check getStr(j["path"]) == "/api/items"
    check j["status"].kind == JInt
    check getInt(j["status"]) == 200
    check j["duration_ms"].kind == JFloat
    check getFloat(j["duration_ms"]) >= 0.0
    check getStr(j["request_id"]) == "req-123"
    check getStr(j["trace_id"]) == "trace-abc"
    check getStr(j["remote_ip"]) == "10.0.0.5"
    check getStr(j["user_agent"]) == "test-agent/1.0"
    check getStr(j["request_content_length"]) == "42"
    check isTimestampShape(getStr(j["timestamp"]))
    check not j.hasKey("error")
    check not j.hasKey("error_trace")

  test "logs POST method and omits absent optional fields":
    var logLine = ""
    let opts = makeLoggerOpts(proc(line: string) = logLine = line)
    let req = newMockRequest("/p", hmPost)
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req, res)
    let j = parseJson(logLine)
    check getStr(j["method"]) == "POST"
    check not j.hasKey("request_id")
    check not j.hasKey("trace_id")
    check not j.hasKey("user_agent")
    check not j.hasKey("request_content_length")

  test "skips default health check paths":
    var count = 0
    let opts = makeLoggerOpts(proc(line: string) = inc count)
    for p in ["/health", "/healthz", "/ready", "/readyz", "/livez"]:
      let req = newMockRequest(p)
      let res = newMockResponse()
      runMiddlewareChain(@[jsonLogger(opts)], req, res)
    check count == 0

  test "respects custom skipPaths":
    var logLine = ""
    let opts = makeLoggerOpts(
      proc(line: string) = logLine = line, skipPaths = @["/metrics"])
    let req1 = newMockRequest("/metrics")
    let res1 = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req1, res1)
    check logLine == ""
    let req2 = newMockRequest("/api")
    let res2 = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req2, res2)
    check getStr(parseJson(logLine)["path"]) == "/api"

  test "logs health path when skipHealthChecks is false":
    var logLine = ""
    let opts = makeLoggerOpts(
      proc(line: string) = logLine = line, skipHealthChecks = false)
    let req = newMockRequest("/health")
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req, res)
    check getStr(parseJson(logLine)["path"]) == "/health"

  test "excluded fields are omitted from the log line":
    var logLine = ""
    let opts = makeLoggerOpts(
      proc(line: string) = logLine = line,
      excludeFields = {jlfUserAgent, jlfRemoteIp, jlfTraceId, jlfRequestId,
                       jlfContentLength, jlfError})
    let req = newMockRequest("/x", hmGet, "", "10.0.0.9",
      @[("user-agent", "ua")])
    req.locals["requestId"] = "r1"
    req.locals["traceId"] = "t1"
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req, res)
    let j = parseJson(logLine)
    check not j.hasKey("user_agent")
    check not j.hasKey("remote_ip")
    check not j.hasKey("trace_id")
    check not j.hasKey("request_id")
    check not j.hasKey("request_content_length")
    check getStr(j["method"]) == "GET"
    check getStr(j["path"]) == "/x"
    check getInt(j["status"]) == 200

  test "only included fields are emitted":
    var logLine = ""
    let opts = makeLoggerOpts(
      proc(line: string) = logLine = line,
      includeFields = {jlfMethod, jlfStatus})
    let req = newMockRequest("/only")
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req, res)
    let j = parseJson(logLine)
    check j.len == 2
    check j.hasKey("method")
    check j.hasKey("status")
    check getStr(j["method"]) == "GET"
    check getInt(j["status"]) == 200

  test "middleware still calls next and the handler runs":
    var logLine = ""
    let opts = makeLoggerOpts(proc(line: string) = logLine = line)
    var flag = false
    let req = newMockRequest("/ok")
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req, res, flagHandler(addr flag))
    check flag
    check res.finished
    check getInt(parseJson(logLine)["status"]) == 200

  test "handler error is logged, status upgraded to 500, and re-raised":
    var logLine = ""
    let opts = makeLoggerOpts(proc(line: string) = logLine = line)
    let req = newMockRequest("/boom")
    let res = newMockResponse()
    proc boom(r: Request, s: Response): Future[void] {.async.} =
      raise newException(JsonLoggerTestErr, "kaboom\nline2")
    var caught = false
    try:
      runMiddlewareChain(@[jsonLogger(opts)], req, res, boom)
    except CatchableError as e:
      caught = e.name == "JsonLoggerTestErr"
    check caught
    check res.statusCode == 500
    check '\n' notin logLine
    let j = parseJson(logLine)
    check getInt(j["status"]) == 500
    check getStr(j["error"]).startsWith("kaboom\nline2")
    check getStr(j["error_trace"]).len > 0

  test "handler error does not downgrade an already-set 4xx status":
    var logLine = ""
    let opts = makeLoggerOpts(proc(line: string) = logLine = line)
    let req = newMockRequest("/nf")
    let res = newMockResponse()
    proc notFound(r: Request, s: Response): Future[void] {.async.} =
      s.status(404)
      raise newException(JsonLoggerTestErr, "nf")
    var caught = false
    try:
      runMiddlewareChain(@[jsonLogger(opts)], req, res, notFound)
    except CatchableError as e:
      caught = e.name == "JsonLoggerTestErr"
    check caught
    check res.statusCode == 404
    let j = parseJson(logLine)
    check getInt(j["status"]) == 404
    check getStr(j["error"]).startsWith("nf")

  test "long error trace is truncated with a marker":
    var logLine = ""
    let opts = makeLoggerOpts(proc(line: string) = logLine = line)
    proc deep(depth: int) =
      if depth <= 0:
        raise newException(JsonLoggerDeepErr, "deep")
      deep(depth - 1)
    let req = newMockRequest("/deep")
    let res = newMockResponse()
    proc boom(r: Request, s: Response): Future[void] {.async.} =
      deep(1500)
    var caught = false
    try:
      runMiddlewareChain(@[jsonLogger(opts)], req, res, boom)
    except CatchableError as e:
      caught = e.name == "JsonLoggerDeepErr"
    check caught
    let j = parseJson(logLine)
    let trace = getStr(j["error_trace"])
    check trace.len <= MaxErrorTraceLen + 16
    check trace.endsWith("... [truncated]")

  test "default options (nil sink) still log without crashing":
    let req = newMockRequest("/default")
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger()], req, res)
    check res.statusCode == 200

suite "json_logger — clock and buffer regression":

  test "200 response line has required keys, non-negative duration with 3 decimals":
    var logLine = ""
    let opts = makeLoggerOpts(proc(line: string) = logLine = line)
    let req = newMockRequest("/api/data", hmGet)
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req, res)
    # single-line JSON
    check '\n' notin logLine
    check logLine[0] == '{' and logLine[^1] == '}'
    # required substrings present
    check "\"timestamp\":\"" in logLine
    check "\"duration_ms\":" in logLine
    check "\"status\":" in logLine
    check "\"method\":" in logLine
    check "\"path\":" in logLine
    # parse and validate
    let j = parseJson(logLine)
    check getStr(j["method"]) == "GET"
    check getStr(j["path"]) == "/api/data"
    check getInt(j["status"]) == 200
    check getFloat(j["duration_ms"]) >= 0.0
    # duration_ms has exactly 3 decimal places in raw text
    let dmIdx = logLine.find("\"duration_ms\":")
    let dmStart = dmIdx + "\"duration_ms\":".len
    let dmEnd = logLine.find(',', dmStart)
    let dmStr = logLine[dmStart ..< dmEnd]
    let dotIdx = dmStr.find('.')
    check dotIdx > 0
    check dmStr.len - dotIdx - 1 == 3

  test "timestamp structure: 19+ chars, contains T, valid ISO shape":
    var logLine = ""
    let opts = makeLoggerOpts(proc(line: string) = logLine = line)
    let req = newMockRequest("/ts")
    let res = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req, res)
    let j = parseJson(logLine)
    let ts = getStr(j["timestamp"])
    check ts.len >= 19
    check 'T' in ts
    check isTimestampShape(ts)

  test "two consecutive requests produce independent non-aliased lines":
    var lines: seq[string] = @[]
    let opts = makeLoggerOpts(proc(line: string) = lines.add(line))
    # request 1: path /first, status 200
    let req1 = newMockRequest("/first", hmGet)
    let res1 = newMockResponse()
    runMiddlewareChain(@[jsonLogger(opts)], req1, res1)
    # request 2: path /second, status 404
    let req2 = newMockRequest("/second", hmPost)
    let res2 = newMockResponse()
    res2.statusCode = 404
    res2.finished = true
    runMiddlewareChain(@[jsonLogger(opts)], req2, res2)
    check lines.len == 2
    let l1 = lines[0]
    let l2 = lines[1]
    # both intact, independently correct
    check l1 != l2
    check getStr(parseJson(l1)["path"]) == "/first"
    check getInt(parseJson(l1)["status"]) == 200
    check getStr(parseJson(l2)["path"]) == "/second"
    check getInt(parseJson(l2)["status"]) == 404
    # not aliases: line1 contains its path, line2 contains its path
    check "/first" in l1
    check "/second" in l2
    check "/second" notin l1
    check "/first" notin l2

  test "error path emits error field and truncates long stack trace":
    var logLine = ""
    let opts = makeLoggerOpts(proc(line: string) = logLine = line)
    proc deep(depth: int) =
      if depth <= 0:
        raise newException(JsonLoggerDeepErr, "bottom")
      deep(depth - 1)
    let req = newMockRequest("/err")
    let res = newMockResponse()
    proc boom(r: Request, s: Response): Future[void] {.async.} =
      deep(1000)
    var caught = false
    try:
      runMiddlewareChain(@[jsonLogger(opts)], req, res, boom)
    except CatchableError:
      caught = true
    check caught
    let j = parseJson(logLine)
    check j.hasKey("error")
    check j.hasKey("error_trace")
    let trace = getStr(j["error_trace"])
    check trace.len <= MaxErrorTraceLen + 16
    check trace.endsWith("... [truncated]")
