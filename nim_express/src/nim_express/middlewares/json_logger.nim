## Structured JSON logger middleware (NDJSON to stdout).

import std/[asyncdispatch, times, strutils]
import common

const
  DefaultSkipPaths* = ["/health", "/healthz", "/ready", "/readyz", "/livez"]
  MaxErrorTraceLen* = 2048

type
  JsonLogSink* = proc(line: string) {.closure.}

  JsonLogField* = enum
    jlfTimestamp
    jlfMethod
    jlfPath
    jlfStatus
    jlfDurationMs
    jlfRequestId
    jlfTraceId
    jlfRemoteIp
    jlfUserAgent
    jlfContentLength
    jlfError

  JsonLoggerOptions* = object
    sink*: JsonLogSink
    includeFields*: set[JsonLogField]
    excludeFields*: set[JsonLogField]
    skipPaths*: seq[string]
    skipHealthChecks*: bool
    maxErrorTraceLen*: int

## Log all fields, with health check skipping enabled.
proc defaultJsonLoggerOptions*(): JsonLoggerOptions {.inline.} =
  JsonLoggerOptions(
    sink: nil,
    includeFields: {jlfTimestamp, jlfMethod, jlfPath, jlfStatus,
                    jlfDurationMs, jlfRequestId, jlfTraceId,
                    jlfRemoteIp, jlfUserAgent, jlfContentLength,
                    jlfError},
    excludeFields: {},
    skipPaths: @[],
    skipHealthChecks: true,
    maxErrorTraceLen: MaxErrorTraceLen
  )

## Check whether a log field should be emitted for these options.
proc shouldInclude*(opts: JsonLoggerOptions, field: JsonLogField): bool {.inline.} =
  if field in opts.excludeFields:
    return false
  field in opts.includeFields

## Escape a string for safe JSON embedding without allocating a JsonNode.
proc escapeJsonString*(value: string): string {.inline.} =
  if value.len == 0:
    return ""
  result = newStringOfCap(value.len + 8)
  for c in value:
    case c
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    else:
      let o = ord(c)
      if o < 0x20 or o == 0x7f:
        result.add("\\u00")
        result.add(toHex(o, 2))
      else:
        result.add(c)

## Check whether a path is a default or configured health check path.
proc isHealthPath*(path: string, skipPaths: seq[string]): bool {.inline.} =
  for p in DefaultSkipPaths:
    if path == p:
      return true
  for p in skipPaths:
    if path == p:
      return true
  false

## Append `value` as a fixed-point decimal (same shape as
## `formatFloat(value, ffDecimal, decimals)`) directly into `line`
## without an intermediate string allocation.
proc appendFloatDec*(line: var string, value: float, decimals: int = 3) =
  if value != value:
    line.add("NaN")
    return
  var v = value
  if v < 0:
    line.add('-')
    v = -v
  if v > 9.0e15:
    line.add(formatFloat(v, ffDecimal, decimals))
    return
  var scale = 1
  for i in 0 ..< decimals:
    scale *= 10
  let scaled = int64(v * float(scale) + 0.5)
  let intPart = scaled div int64(scale)
  let frac = scaled mod int64(scale)
  fastIntToStr(int(intPart), line)
  if decimals > 0:
    line.add('.')
    var fbuf: array[32, char]
    var p = 0
    if frac == 0:
      fbuf[0] = '0'
      p = 1
    else:
      var f = frac
      while f > 0:
        fbuf[p] = char(int('0') + int(f mod 10))
        inc p
        f = f div 10
    for i in 0 ..< (decimals - p):
      line.add('0')
    for i in countdown(p - 1, 0):
      line.add(fbuf[i])

## Append `epochSec` (seconds since 1970-01-01T00:00:00Z) formatted as
## "yyyy-MM-ddTHH:mm:ss.fffZ" directly into `line` without constructing
## a DateTime. Only valid for dates on or after 1970-01-01.
proc appendIso8601Ms*(line: var string, epochSec: float) =
  let totalMs = int64(epochSec * 1000.0)
  let millis = int(totalMs mod 1000)
  let totalSecs = totalMs div 1000
  let days = totalSecs div 86400
  let remSecs = totalSecs mod 86400
  let z = days + 719468
  let era = z div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let day = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  let year = if m <= 2: y + 1 else: y
  fastIntToStr(int(year), line)
  line.add("-")
  line.add(char(int('0') + int(m) div 10))
  line.add(char(int('0') + int(m) mod 10))
  line.add("-")
  line.add(char(int('0') + int(day) div 10))
  line.add(char(int('0') + int(day) mod 10))
  line.add('T')
  let hh = int(remSecs div 3600)
  let mi = int((remSecs mod 3600) div 60)
  let ss = int(remSecs mod 60)
  line.add(char(int('0') + hh div 10))
  line.add(char(int('0') + hh mod 10))
  line.add(':')
  line.add(char(int('0') + mi div 10))
  line.add(char(int('0') + mi mod 10))
  line.add(':')
  line.add(char(int('0') + ss div 10))
  line.add(char(int('0') + ss mod 10))
  line.add('.')
  line.add(char(int('0') + millis div 100))
  line.add(char(int('0') + (millis div 10) mod 10))
  line.add(char(int('0') + millis mod 10))
  line.add('Z')

## Emit one NDJSON line per request to stdout (or custom sink).
proc jsonLogger*(
  options: JsonLoggerOptions = defaultJsonLoggerOptions()
): AsyncMiddleware =
  let opts = options
  let sinkProc = opts.sink

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let reqPath = $req.path
    if opts.skipHealthChecks and isHealthPath(reqPath, opts.skipPaths):
      await next()
      return

    let start = epochTime()
    var handlerError: ref Exception = nil
    var handlerDefect: ref Defect = nil
    var errorMsg = ""
    var errorTrace = ""

    try:
      await next()
    except CatchableError as e:
      handlerError = e
      errorMsg = e.msg
      errorTrace = e.getStackTrace()
      if res.statusCode < 400:
        res.statusCode = 500
    except Defect as d:
      handlerDefect = d
      errorMsg = $d.name & ": " & d.msg
      errorTrace = d.getStackTrace()
      if res.statusCode < 400:
        res.statusCode = 500

    let maxTrace = if opts.maxErrorTraceLen > 0: opts.maxErrorTraceLen else: MaxErrorTraceLen
    if errorTrace.len > maxTrace:
      errorTrace = errorTrace[0 ..< maxTrace] & "... [truncated]"

    let durationMs = ((epochTime() - start) * 1000.0)

    var line = newStringOfCap(512)
    line.add("{")
    var first = true

    template addField(key: string, value: string) =
      if not first:
        line.add(",")
      first = false
      line.add("\"")
      line.add(key)
      line.add("\":\"")
      line.add(escapeJsonString(value))
      line.add("\"")

    template addIntField(key: string, value: int) =
      if not first:
        line.add(",")
      first = false
      line.add("\"")
      line.add(key)
      line.add("\":")
      fastIntToStr(value, line)

    template addFloatField(key: string, value: float) =
      if not first:
        line.add(",")
      first = false
      line.add("\"")
      line.add(key)
      line.add("\":")
      appendFloatDec(line, value, 3)

    if opts.shouldInclude(jlfTimestamp):
      if not first:
        line.add(",")
      first = false
      line.add("\"timestamp\":\"")
      appendIso8601Ms(line, epochTime())
      line.add("\"")

    if opts.shouldInclude(jlfMethod):
      addField("method", $req.methodKind)

    if opts.shouldInclude(jlfPath):
      addField("path", reqPath)

    if opts.shouldInclude(jlfStatus):
      addIntField("status", res.statusCode)

    if opts.shouldInclude(jlfDurationMs):
      addFloatField("duration_ms", durationMs)

    if opts.shouldInclude(jlfRequestId):
      let requestId = req.locals.getOrDefault("requestId", "")
      if requestId.len > 0:
        addField("request_id", requestId)

    if opts.shouldInclude(jlfTraceId):
      var traceId = req.locals.getOrDefault("traceId", "")
      if traceId.len == 0:
        traceId = req.locals.getOrDefault("otel.trace_id", "")
      if traceId.len > 0:
        addField("trace_id", traceId)

    if opts.shouldInclude(jlfRemoteIp):
      addField("remote_ip", req.native.remoteIp)

    if opts.shouldInclude(jlfUserAgent):
      let ua = req.get("user-agent")
      if ua.len > 0:
        addField("user_agent", ua)

    if opts.shouldInclude(jlfContentLength):
      let cl = req.get("content-length")
      if cl.len > 0:
        addField("request_content_length", cl)

    if opts.shouldInclude(jlfError) and errorMsg.len > 0:
      addField("error", errorMsg)
      if errorTrace.len > 0:
        addField("error_trace", errorTrace)

    line.add("}")

    if sinkProc != nil:
      sinkProc(line)
    else:
      echo line

    if handlerDefect != nil:
      raise handlerDefect
    elif handlerError != nil:
      raise handlerError
