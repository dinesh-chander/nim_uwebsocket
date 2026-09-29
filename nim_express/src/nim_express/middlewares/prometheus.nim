import std/[asyncdispatch, tables, times, strutils, locks, math, atomics]
import common

const
  MaxRouteCardinality* = 2048
  MaxLabelLength = 128
  DefaultBuckets* = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
  OverflowRouteKey = "OVERFLOW|__cardinality_overflow__"

type
  MetricsBucket* = object
    le*: float64
    count*: int64

  RouteMetrics* = object
    requestCount*: int64
    statusCounts*: array[6, int64]
    buckets*: seq[MetricsBucket]
    totalDuration*: float64

  PrometheusRegistry* = ref object
    routes*: Table[string, RouteMetrics]
    inFlight*: Atomic[int64]
    lock: Lock
    maxRoutes*: int
    droppedRoutes*: int64

  PrometheusOptions* = object
    metricsPath*: string
    includeMethod*: bool
    normalizePaths*: bool
    maxRoutes*: int

## Returns the default ``PrometheusOptions`` with metrics served from ``/metrics``, method labels included, path normalization enabled, and the default route cardinality limit.
proc defaultPrometheusOptions*(): PrometheusOptions {.inline.} =
  PrometheusOptions(
    metricsPath: "/metrics",
    includeMethod: true,
    normalizePaths: true,
    maxRoutes: MaxRouteCardinality
  )

## Creates a new ``PrometheusRegistry`` with an empty route table and zeroed counters, clamping the maximum tracked route count to at least 16.
proc newPrometheusRegistry*(maxRoutes: int = MaxRouteCardinality): PrometheusRegistry =
  new(result)
  result.routes = initTable[string, RouteMetrics]()
  result.inFlight.store(0)
  result.maxRoutes = max(16, maxRoutes)
  result.droppedRoutes = 0
  initLock(result.lock)

proc newRouteMetrics(): RouteMetrics =
  result.requestCount = 0
  result.totalDuration = 0.0
  result.buckets = newSeq[MetricsBucket](DefaultBuckets.len)
  for i in 0..<DefaultBuckets.len:
    result.buckets[i] = MetricsBucket(le: DefaultBuckets[i], count: 0)

proc escapeLabelValue(s: string): string =
  var needsEscape = false
  for c in s:
    if c == '\\' or c == '"' or c == '\n' or c == '\r' or c == '\0':
      needsEscape = true
      break
  if not needsEscape:
    return s
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\0': result.add("\\u0000")
    else: result.add(c)

proc normalizePath(path: string): string =
  let queryPos = path.find('?')
  let fragmentPos = path.find('#')
  var endPos = path.len
  if queryPos >= 0 and queryPos < endPos: endPos = queryPos
  if fragmentPos >= 0 and fragmentPos < endPos: endPos = fragmentPos
  let cleanPath = if endPos < path.len: path[0..<endPos] else: path

  var parts = cleanPath.split('/')
  var collapsed = newSeqOfCap[string](parts.len)
  for i in 0..<parts.len:
    if parts[i].len == 0 and i > 0 and i < parts.len - 1:
      continue
    var segment = parts[i]
    if segment.len > 0:
      var allDigits = true
      for c in segment:
        if c < '0' or c > '9':
          allDigits = false
          break
      if allDigits:
        segment = ":id"
      elif segment.len == 36 and segment[8] == '-' and segment[13] == '-' and
           segment[18] == '-' and segment[23] == '-':
        var isUuid = true
        for c in segment:
          if c != '-' and not (c in {'0'..'9', 'a'..'f', 'A'..'F'}):
            isUuid = false
            break
        if isUuid:
          segment = ":id"
    collapsed.add(segment)
  var normalized = collapsed.join("/")
  if normalized.len > MaxLabelLength:
    normalized = normalized[0..<MaxLabelLength]
  normalized

proc methodString(methodKind: nim_usockets.HttpMethod): string {.inline.} =
  case methodKind
  of hmGet: "GET"
  of hmPost: "POST"
  of hmPut: "PUT"
  of hmDelete: "DELETE"
  of hmPatch: "PATCH"
  of hmHead: "HEAD"
  of hmOptions: "OPTIONS"
  of hmConnect: "CONNECT"
  of hmTrace: "TRACE"

proc statusBucketIndex(code: int): int {.inline.} =
  if code >= 100 and code < 200: 0
  elif code >= 200 and code < 300: 1
  elif code >= 300 and code < 400: 2
  elif code >= 400 and code < 500: 3
  elif code >= 500 and code < 600: 4
  else: 5

proc sanitizeDuration(duration: float64): float64 {.inline.} =
  if classify(duration) in {fcNan, fcInf, fcNegInf} or duration < 0.0:
    0.0
  else:
    duration

proc recordRequest(registry: PrometheusRegistry, key: string, statusCode: int, duration: float64) =
  let safeDuration = sanitizeDuration(duration)
  acquire(registry.lock)
  try:
    var effectiveKey = key
    if not registry.routes.hasKey(key):
      if registry.routes.len >= registry.maxRoutes:
        effectiveKey = OverflowRouteKey
        inc registry.droppedRoutes
        if not registry.routes.hasKey(effectiveKey):
          registry.routes[effectiveKey] = newRouteMetrics()
      else:
        registry.routes[key] = newRouteMetrics()
    var metrics = addr registry.routes[effectiveKey]
    inc metrics.requestCount
    metrics.statusCounts[statusBucketIndex(statusCode)] += 1
    metrics.totalDuration += safeDuration
    for i in 0..<metrics.buckets.len:
      if safeDuration <= metrics.buckets[i].le:
        metrics.buckets[i].count += 1
        break
  finally:
    release(registry.lock)

proc formatFloat6(val: float64): string =
  if classify(val) == fcNan: return "NaN"
  if classify(val) == fcInf: return "+Inf"
  if classify(val) == fcNegInf: return "-Inf"
  formatFloat(val, ffDecimal, 6)

## Takes a snapshot of all route metrics under the registry lock and renders them as a Prometheus text exposition string with request counters, a duration histogram, and the in-flight gauge.
proc renderMetrics*(registry: PrometheusRegistry): string =
  var snapshot: seq[tuple[key: string, metrics: RouteMetrics]]
  var snapshotInFlight: int64
  var snapshotDroppedRoutes: int64

  acquire(registry.lock)
  try:
    snapshot = newSeqOfCap[tuple[key: string, metrics: RouteMetrics]](registry.routes.len)
    for key, metrics in registry.routes:
      snapshot.add((key: key, metrics: metrics))
    snapshotInFlight = registry.inFlight.load()
    snapshotDroppedRoutes = registry.droppedRoutes
  finally:
    release(registry.lock)

  var buf = newStringOfCap(4096)

  var labels = newSeqOfCap[tuple[methodLabel: string, pathLabel: string]](snapshot.len)
  for entry in snapshot:
    let sepIdx = entry.key.find('|')
    labels.add((
      methodLabel: escapeLabelValue(if sepIdx >= 0: entry.key[0..<sepIdx] else: "UNKNOWN"),
      pathLabel: escapeLabelValue(if sepIdx >= 0: entry.key[sepIdx+1..^1] else: entry.key)
    ))

  buf.add("# HELP http_requests_total Total number of HTTP requests.\n")
  buf.add("# TYPE http_requests_total counter\n")
  for idx, entry in snapshot:
    let methodLabel = labels[idx].methodLabel
    let pathLabel = labels[idx].pathLabel
    for i in 0..5:
      if entry.metrics.statusCounts[i] > 0:
        let statusGroup = case i
          of 0: "1xx"
          of 1: "2xx"
          of 2: "3xx"
          of 3: "4xx"
          of 4: "5xx"
          else: "other"
        buf.add("http_requests_total{method=\"")
        buf.add(methodLabel)
        buf.add("\",path=\"")
        buf.add(pathLabel)
        buf.add("\",status=\"")
        buf.add(statusGroup)
        buf.add("\"} ")
        buf.add($entry.metrics.statusCounts[i])
        buf.add("\n")

  buf.add("# HELP http_request_duration_seconds HTTP request duration in seconds.\n")
  buf.add("# TYPE http_request_duration_seconds histogram\n")
  for idx, entry in snapshot:
    let methodLabel = labels[idx].methodLabel
    let pathLabel = labels[idx].pathLabel
    var cumulative: int64 = 0
    for i in 0..<entry.metrics.buckets.len:
      cumulative += entry.metrics.buckets[i].count
      buf.add("http_request_duration_seconds_bucket{method=\"")
      buf.add(methodLabel)
      buf.add("\",path=\"")
      buf.add(pathLabel)
      buf.add("\",le=\"")
      buf.add(formatFloat6(entry.metrics.buckets[i].le))
      buf.add("\"} ")
      buf.add($cumulative)
      buf.add("\n")
    buf.add("http_request_duration_seconds_bucket{method=\"")
    buf.add(methodLabel)
    buf.add("\",path=\"")
    buf.add(pathLabel)
    buf.add("\",le=\"+Inf\"} ")
    buf.add($entry.metrics.requestCount)
    buf.add("\n")
    buf.add("http_request_duration_seconds_sum{method=\"")
    buf.add(methodLabel)
    buf.add("\",path=\"")
    buf.add(pathLabel)
    buf.add("\"} ")
    buf.add(formatFloat6(entry.metrics.totalDuration))
    buf.add("\n")
    buf.add("http_request_duration_seconds_count{method=\"")
    buf.add(methodLabel)
    buf.add("\",path=\"")
    buf.add(pathLabel)
    buf.add("\"} ")
    buf.add($entry.metrics.requestCount)
    buf.add("\n")

  buf.add("# HELP http_requests_in_flight Current number of HTTP requests being processed.\n")
  buf.add("# TYPE http_requests_in_flight gauge\n")
  buf.add("http_requests_in_flight ")
  buf.add($snapshotInFlight)
  buf.add("\n")

  if snapshotDroppedRoutes > 0:
    buf.add("# HELP http_metrics_dropped_routes_total Routes dropped due to cardinality limit.\n")
    buf.add("# TYPE http_metrics_dropped_routes_total counter\n")
    buf.add("http_metrics_dropped_routes_total ")
    buf.add($snapshotDroppedRoutes)
    buf.add("\n")

  buf

## Prometheus metrics middleware: records per-route request counters, status
## group counts, and latency histograms, and serves them in Prometheus text
## format at ``options.metricsPath``.
##
## Requests to the metrics path itself are short-circuited and are NOT
## recorded in the collected metrics (matches Prometheus client library
## conventions, e.g. Go's promhttp.Handler); the in-flight gauge therefore
## does not include scrapes in progress.
##
## The exposition endpoint has no access control by design. Enforce access
## control at the infrastructure level (dedicated metrics port, reverse proxy
## allow/deny, VPN) rather than in application middleware.
proc prometheusMetrics*(
  registry: PrometheusRegistry,
  options: PrometheusOptions = defaultPrometheusOptions()
): AsyncMiddleware =
  let opts = options
  let reg = registry
  reg.maxRoutes = max(16, opts.maxRoutes)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let reqPath = $req.path
    if reqPath == opts.metricsPath:
      discard res.set("content-type", "text/plain; version=0.0.4; charset=utf-8")
      res.send(renderMetrics(reg))
      return

    let methodStr = methodString(req.methodKind)
    var normalizedPath = if opts.normalizePaths: normalizePath(reqPath) else: reqPath
    if normalizedPath.len > MaxLabelLength:
      normalizedPath = normalizedPath[0..<MaxLabelLength]
    let key = if opts.includeMethod: methodStr & "|" & normalizedPath
              else: "ALL|" & normalizedPath

    reg.inFlight += 1
    let startTime = epochTime()
    try:
      await next()
    finally:
      let duration = epochTime() - startTime
      reg.inFlight -= 1
      recordRequest(reg, key, res.statusCode, duration)

## Creates the Prometheus metrics middleware with default options but a custom metrics path.
proc prometheusMetrics*(
  registry: PrometheusRegistry,
  metricsPath: string
): AsyncMiddleware =
  var opts = defaultPrometheusOptions()
  opts.metricsPath = metricsPath
  prometheusMetrics(registry, opts)
