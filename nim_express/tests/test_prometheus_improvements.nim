import std/[unittest, asyncdispatch, strutils]
import std/atomics
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/prometheus

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

proc makeRoute(requestCount: int64, bucketCounts: array[DefaultBuckets.len, int64],
               totalDuration: float64, statusCounts: array[6, int64]): RouteMetrics =
  result.requestCount = requestCount
  result.totalDuration = totalDuration
  for i in 0..5:
    result.statusCounts[i] = statusCounts[i]
  for i in 0..<DefaultBuckets.len:
    result.buckets.add(MetricsBucket(le: DefaultBuckets[i], count: bucketCounts[i]))

proc scanLabelValue(line: string, i: var int): bool =
  while i < line.len:
    let c = line[i]
    if c == '\\':
      if i + 1 >= line.len:
        return false
      inc i
    elif c == '"':
      return true
    inc i
  false

proc isNameChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc isValidMetricValue(s: string): bool =
  if s == "NaN" or s == "+Inf" or s == "-Inf":
    return true
  var seenDigit = false
  var seenDot = false
  for c in s:
    if c in {'0'..'9'}:
      seenDigit = true
    elif c == '.' and not seenDot:
      seenDot = true
    else:
      return false
  seenDigit

proc isValidSampleLine(line: string): bool =
  var i = 0
  let n = line.len
  if n == 0 or line[0] notin {'a'..'z', 'A'..'Z', '_'}:
    return false
  while i < n and isNameChar(line[i]):
    inc i
  if i < n and line[i] == '{':
    inc i
    var firstLabel = true
    while i < n and line[i] != '}':
      if not firstLabel:
        if line[i] != ',':
          return false
        inc i
        if i < n and line[i] == ' ':
          inc i
      firstLabel = false
      if i >= n or line[i] notin {'a'..'z', 'A'..'Z', '_'}:
        return false
      var nameEnd = i
      while nameEnd < n and isNameChar(line[nameEnd]):
        inc nameEnd
      if nameEnd >= n or line[nameEnd] != '=':
        return false
      inc nameEnd
      if nameEnd >= n or line[nameEnd] != '"':
        return false
      inc nameEnd
      i = nameEnd
      if not scanLabelValue(line, i):
        return false
      inc i
    if i >= n or line[i] != '}':
      return false
    inc i
  if i >= n or line[i] != ' ':
    return false
  inc i
  isValidMetricValue(line[i..^1])

proc invalidExpositionLines(body: string): seq[string] =
  for line in body.split('\n'):
    if line.len == 0 or line[0] == '#':
      continue
    if not isValidSampleLine(line):
      result.add(line)

suite "prometheus unit":
  test "renderMetrics: empty registry emits HELP/TYPE headers and zero in-flight gauge":
    let reg = newPrometheusRegistry()
    let rendered = renderMetrics(reg)
    check rendered.find("# HELP http_requests_total Total number of HTTP requests.\n") >= 0
    check rendered.find("# TYPE http_requests_total counter\n") >= 0
    check rendered.find("# HELP http_request_duration_seconds HTTP request duration in seconds.\n") >= 0
    check rendered.find("# TYPE http_request_duration_seconds histogram\n") >= 0
    check rendered.find("# HELP http_requests_in_flight Current number of HTTP requests being processed.\n") >= 0
    check rendered.find("# TYPE http_requests_in_flight gauge\n") >= 0
    check rendered.find("http_requests_in_flight 0\n") >= 0
    check rendered.find("http_metrics_dropped_routes_total") < 0
    check invalidExpositionLines(rendered).len == 0

  test "renderMetrics: counter lines per status group and cumulative histogram (regression)":
    let reg = newPrometheusRegistry()
    reg.routes["GET|/users"] = makeRoute(
      requestCount = 6'i64,
      bucketCounts = [4'i64, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      totalDuration = 1.5,
      statusCounts = [0'i64, 3, 2, 1, 0, 0])
    let rendered = renderMetrics(reg)
    check rendered.find("http_requests_total{method=\"GET\",path=\"/users\",status=\"2xx\"} 3\n") >= 0
    check rendered.find("http_requests_total{method=\"GET\",path=\"/users\",status=\"3xx\"} 2\n") >= 0
    check rendered.find("http_requests_total{method=\"GET\",path=\"/users\",status=\"4xx\"} 1\n") >= 0
    check rendered.find("http_requests_total{method=\"GET\",path=\"/users\",status=\"1xx\"}") < 0
    check rendered.find("http_requests_total{method=\"GET\",path=\"/users\",status=\"5xx\"}") < 0
    check rendered.find("http_request_duration_seconds_bucket{method=\"GET\",path=\"/users\",le=\"0.005000\"} 4\n") >= 0
    check rendered.find("http_request_duration_seconds_bucket{method=\"GET\",path=\"/users\",le=\"0.010000\"} 6\n") >= 0
    check rendered.find("http_request_duration_seconds_bucket{method=\"GET\",path=\"/users\",le=\"0.025000\"} 6\n") >= 0
    check rendered.find("http_request_duration_seconds_bucket{method=\"GET\",path=\"/users\",le=\"+Inf\"} 6\n") >= 0
    check rendered.find("http_request_duration_seconds_sum{method=\"GET\",path=\"/users\"} 1.500000\n") >= 0
    check rendered.find("http_request_duration_seconds_count{method=\"GET\",path=\"/users\"} 6\n") >= 0

  test "renderMetrics: label escaping for quote, backslash, newline, CR, NUL (ISSUE-1, ISSUE-4)":
    let reg = newPrometheusRegistry()
    reg.routes["GET|/a\"b\\c\nd\re\0f"] = makeRoute(
      requestCount = 1'i64,
      bucketCounts = [1'i64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      totalDuration = 0.25,
      statusCounts = [0'i64, 1, 0, 0, 0, 0])
    let rendered = renderMetrics(reg)
    check rendered.find("path=\"/a\\\"b\\\\c\\nd\\re\\u0000f\"") >= 0
    check rendered.find("method=\"GET\",path=\"/a\\\"b\\\\c\\nd\\re\\u0000f\",status=\"2xx\"} 1\n") >= 0

  test "renderMetrics: dropped routes counter appears only when non-zero":
    let reg = newPrometheusRegistry()
    check renderMetrics(reg).find("http_metrics_dropped_routes_total") < 0
    reg.droppedRoutes = 4
    let rendered = renderMetrics(reg)
    check rendered.find("# TYPE http_metrics_dropped_routes_total counter\n") >= 0
    check rendered.find("http_metrics_dropped_routes_total 4\n") >= 0

  test "renderMetrics: exposition format valid across multiple routes":
    let reg = newPrometheusRegistry()
    reg.routes["GET|/a"] = makeRoute(1'i64, [1'i64,0,0,0,0,0,0,0,0,0,0], 0.001, [0'i64,1,0,0,0,0])
    reg.routes["POST|/b/c"] = makeRoute(2'i64, [0'i64,2,0,0,0,0,0,0,0,0,0], 12.5, [0'i64,0,0,2,0,0])
    reg.inFlight.store(3)
    reg.droppedRoutes = 1
    let rendered = renderMetrics(reg)
    check invalidExpositionLines(rendered).len == 0
    check rendered.find("http_requests_in_flight 3\n") >= 0
    check rendered.find("http_metrics_dropped_routes_total 1\n") >= 0
    check rendered.find("http_requests_total{method=\"POST\",path=\"/b/c\",status=\"4xx\"} 2\n") >= 0
    check rendered.find("http_request_duration_seconds_sum{method=\"POST\",path=\"/b/c\"} 12.500000\n") >= 0
    check rendered.find("http_request_duration_seconds_bucket{method=\"POST\",path=\"/b/c\",le=\"+Inf\"} 2\n") >= 0

suite "prometheus middleware":
  test "/metrics: 200 with Prometheus text content type, valid format, no next (regression)":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg)
    let req = newMockRequest(pathVal = "/metrics")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 200
    check res.get("content-type").find("text/plain; version=0.0.4") >= 0
    let body = res.native.capturedBody
    check body.find("# TYPE http_requests_total counter\n") >= 0
    check body.find("# TYPE http_request_duration_seconds histogram\n") >= 0
    check body.find("# TYPE http_requests_in_flight gauge\n") >= 0
    check invalidExpositionLines(body).len == 0

  test "non-metrics path passes through and is recorded per method/route/status (regression)":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg)
    let req = newMockRequest(pathVal = "/api/data", methodKind = hmGet)
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[mw], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    let body = renderMetrics(reg)
    check body.find("http_requests_total{method=\"GET\",path=\"/api/data\",status=\"2xx\"} 1\n") >= 0
    check body.find("http_request_duration_seconds_count{method=\"GET\",path=\"/api/data\"} 1\n") >= 0
    check body.find("http_request_duration_seconds_bucket{method=\"GET\",path=\"/api/data\",le=\"+Inf\"} 1\n") >= 0
    check reg.inFlight.load() == 0

  test "in-flight gauge is 1 while handler runs and 0 after (ISSUE-2)":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg)
    let req = newMockRequest()
    let res = newMockResponse()
    var observedInFlight = -1'i64
    let handler = proc(r: Request, s: Response): Future[void] {.async.} =
      observedInFlight = reg.inFlight.load()
      s.status(200)
      s.send("ok")
    runMiddlewareChain(@[mw], req, res, handler)
    check observedInFlight == 1
    check reg.inFlight.load() == 0

  test "404 POST response recorded under method=POST status=4xx (regression)":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg)
    let req = newMockRequest(pathVal = "/missing", methodKind = hmPost)
    let res = newMockResponse()
    let handler = proc(r: Request, s: Response): Future[void] {.async.} =
      s.status(404)
      s.send("nope")
    runMiddlewareChain(@[mw], req, res, handler)
    let body = renderMetrics(reg)
    check body.find("http_requests_total{method=\"POST\",path=\"/missing\",status=\"4xx\"} 1\n") >= 0

  test "numeric path segments collapse to :id (regression)":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg)
    let req = newMockRequest(pathVal = "/users/12345/posts/999")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let body = renderMetrics(reg)
    check body.find("path=\"/users/:id/posts/:id\"") >= 0
    check body.find("path=\"/users/12345") < 0

  test "UUID segments collapse to :id; non-hex 36-char segments do not (ISSUE-6)":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg)
    let req1 = newMockRequest(pathVal = "/items/123e4567-e89b-12d3-a456-426614174000")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1)
    let req2 = newMockRequest(pathVal = "/items/abcdefghij-klmn-opqr-stuv-wxyz0123456789")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2)
    let body = renderMetrics(reg)
    check body.find("path=\"/items/:id\"") >= 0
    check body.find("path=\"/items/abcdefghij-klmn-opqr-stuv-wxyz0123456789\"") >= 0

  test "label sanitization: CR and NUL in request path are escaped in output (ISSUE-1, ISSUE-4)":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg)
    let req = newMockRequest(pathVal = "/x\r\0")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let body = renderMetrics(reg)
    check body.find("path=\"/x\\r\\u0000\"") >= 0

  test "includeMethod=false uses ALL method label":
    let reg = newPrometheusRegistry()
    var opts = defaultPrometheusOptions()
    opts.includeMethod = false
    let mw = prometheusMetrics(reg, opts)
    let req = newMockRequest(pathVal = "/a", methodKind = hmPut)
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let body = renderMetrics(reg)
    check body.find("http_requests_total{method=\"ALL\",path=\"/a\",status=\"2xx\"} 1\n") >= 0

  test "normalizePaths=false keeps raw numeric path":
    let reg = newPrometheusRegistry()
    var opts = defaultPrometheusOptions()
    opts.normalizePaths = false
    let mw = prometheusMetrics(reg, opts)
    let req = newMockRequest(pathVal = "/users/12345")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let body = renderMetrics(reg)
    check body.find("path=\"/users/12345\"") >= 0

  test "cardinality overflow: routes beyond maxRoutes are dropped to OVERFLOW key":
    let reg = newPrometheusRegistry()
    var opts = defaultPrometheusOptions()
    opts.maxRoutes = 16
    let mw = prometheusMetrics(reg, opts)
    for i in 0..<18:
      let req = newMockRequest(pathVal = "/p" & $i)
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res)
    check reg.droppedRoutes == 2
    let body = renderMetrics(reg)
    check body.find("http_metrics_dropped_routes_total 2\n") >= 0
    check body.find("method=\"OVERFLOW\",path=\"__cardinality_overflow__\"") >= 0
    check reg.routes.len == 17

  test "/metrics requests are not recorded in metrics (ISSUE-8 documented behavior)":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg)
    let req = newMockRequest(pathVal = "/metrics")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    check reg.routes.len == 0
    check renderMetrics(reg).find("path=\"/metrics\"") < 0
    check reg.inFlight.load() == 0

  test "fast request lands in first histogram bucket (middleware bucketing)":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg)
    let req = newMockRequest(pathVal = "/fast")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res)
    let body = renderMetrics(reg)
    check body.find("http_request_duration_seconds_bucket{method=\"GET\",path=\"/fast\",le=\"0.005000\"} 1\n") >= 0
    check body.find("http_request_duration_seconds_sum{method=\"GET\",path=\"/fast\"}") >= 0

  test "prometheusMetrics(registry, metricsPath) overload serves only the custom path":
    let reg = newPrometheusRegistry()
    let mw = prometheusMetrics(reg, "/custom-metrics")
    let req1 = newMockRequest(pathVal = "/custom-metrics")
    let res1 = newMockResponse()
    var next1 = false
    runMiddlewareChain(@[mw], req1, res1, flagHandler(addr next1))
    check not next1
    check res1.statusCode == 200
    check res1.native.capturedBody.find("# TYPE http_requests_total counter\n") >= 0

    let req2 = newMockRequest(pathVal = "/metrics")
    let res2 = newMockResponse()
    var next2 = false
    runMiddlewareChain(@[mw], req2, res2, flagHandler(addr next2))
    check next2
    check res2.statusCode == 200
