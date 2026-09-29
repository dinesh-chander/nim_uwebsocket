## OpenTelemetry-style middleware with W3C traceparent propagation.

import std/[asyncdispatch, strutils, monotimes, atomics, sysrand]
{.warning[UnreachableElse]: off.}
import common

type
  OtelSpanContext* = object
    traceId*: string
    spanId*: string
    parentSpanId*: string
    traceFlags*: string
    sampled*: bool
    operation*: string

  OpenTelemetryStartHook* = proc(req: Req, span: OtelSpanContext) {.closure.}
  OpenTelemetryEndHook* = proc(req: Req, res: Res, span: OtelSpanContext, durationMicros: int64) {.closure.}
  OpenTelemetryHookErrorHook* = proc(phase: string, err: ref CatchableError) {.closure.}

  OpenTelemetryOptions* = object
    operationName*: string
    includeServerTiming*: bool
    setTraceResponseHeader*: bool
    localPrefix*: string
    onSpanStart*: OpenTelemetryStartHook
    onSpanEnd*: OpenTelemetryEndHook
    onHookError*: OpenTelemetryHookErrorHook

  OtelLocalKeys = object
    traceId: string
    spanId: string
    parentSpanId: string
    traceFlags: string
    sampled: string
    operation: string

var otelFallbackCounter: Atomic[uint64]
let otelMonoEpoch: MonoTime = getMonoTime()

const otelHexPairTable: array[256, array[2, char]] = block:
  var t: array[256, array[2, char]]
  const HexChars = "0123456789abcdef"
  for i in 0..255:
    t[i] = [HexChars[i shr 4], HexChars[i and 0x0F]]
  t

## Default options for the OpenTelemetry middleware.
proc initOpenTelemetryOptions*(): OpenTelemetryOptions =
  OpenTelemetryOptions(
    operationName: "",
    includeServerTiming: false,
    setTraceResponseHeader: true,
    localPrefix: "otel",
    onSpanStart: nil,
    onSpanEnd: nil,
    onHookError: nil
  )

## Map an HttpMethod enum value to its uppercase label.
proc httpMethodLabel*(methodKind: HttpMethod): string {.inline.} =
  # The else branch guards against future HttpMethod enum extensions.
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
  else: "UNKNOWN"

## Check whether a string is lowercase hex of exactly the expected length.
proc isHexToken*(value: string, expectedLen: int): bool {.inline.} =
  if value.len != expectedLen:
    return false
  for ch in value:
    if (ch < '0' or ch > '9') and (ch < 'a' or ch > 'f'):
      return false
  true

## Generate a 16-char hex span id, with a deterministic fallback.
proc randomHex16*(): string =
  var bytes: array[8, byte]
  if urandom(bytes):
    result = newString(16)
    for i, b in bytes:
      result[i * 2] = otelHexPairTable[b][0]
      result[i * 2 + 1] = otelHexPairTable[b][1]
    return
  let micros = uint64((getMonoTime() - otelMonoEpoch).inMicroseconds)
  let tick = otelFallbackCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
  result = toHex(micros xor (tick shl 32), 16).toLowerAscii()

## Generate a 32-char hex trace id, with a deterministic fallback.
proc randomHex32*(): string =
  var bytes: array[16, byte]
  if urandom(bytes):
    result = newString(32)
    for i, b in bytes:
      result[i * 2] = otelHexPairTable[b][0]
      result[i * 2 + 1] = otelHexPairTable[b][1]
    return
  let micros = uint64((getMonoTime() - otelMonoEpoch).inMicroseconds)
  let tick = otelFallbackCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
  result = (toHex(micros, 16) & toHex(tick, 16)).toLowerAscii()

## Parse a W3C traceparent header into its trace context fields.
proc parseTraceParent*(value: string): tuple[ok: bool, traceId: string, parentSpanId: string, flags: string] =
  let token = value.strip().toLowerAscii()
  if token.len == 0:
    return
  let parts = token.split('-')
  if parts.len != 4:
    return
  if not isHexToken(parts[0], 2):
    return
  if not isHexToken(parts[1], 32):
    return
  if parts[1] == "00000000000000000000000000000000":
    return
  if not isHexToken(parts[2], 16):
    return
  if parts[2] == "0000000000000000":
    return
  if not isHexToken(parts[3], 2):
    return
  result.ok = true
  result.traceId = parts[1]
  result.parentSpanId = parts[2]
  result.flags = parts[3]

## Strip control characters and cap length for span operation names.
proc sanitizeOperationPath*(path: string): string {.inline.} =
  const maxLen = 200
  let raw =
    if path.len > maxLen:
      block:
        var endPos = maxLen
        while endPos > 0 and (ord(path[endPos]) and 0xC0) == 0x80:
          dec endPos
        path[0 ..< endPos]
    else:
      path
  result = newStringOfCap(raw.len)
  for c in raw:
    let o = ord(c)
    if o < 0x20 or o == 0x7f:
      discard
    else:
      result.add(c)

## Build a request local key from a prefix and suffix.
proc localKey*(prefix: string, suffix: string): string {.inline.} =
  if prefix.len == 0:
    return suffix
  prefix & "." & suffix

proc reportHookError(opts: OpenTelemetryOptions, phase: string, err: ref CatchableError) =
  if opts.onHookError == nil:
    return
  try:
    opts.onHookError(phase, err)
  except CatchableError:
    discard

## OpenTelemetry middleware with W3C traceparent propagation.
proc openTelemetry*(options: OpenTelemetryOptions = initOpenTelemetryOptions()): AsyncMiddleware =
  let opts = options
  let keys = OtelLocalKeys(
    traceId: localKey(opts.localPrefix, "trace_id"),
    spanId: localKey(opts.localPrefix, "span_id"),
    parentSpanId: localKey(opts.localPrefix, "parent_span_id"),
    traceFlags: localKey(opts.localPrefix, "trace_flags"),
    sampled: localKey(opts.localPrefix, "sampled"),
    operation: localKey(opts.localPrefix, "operation")
  )
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let parsed = parseTraceParent(req.get("traceparent"))
    let traceId =
      if parsed.ok: parsed.traceId
      else: randomHex32()
    let parentSpanId =
      if parsed.ok: parsed.parentSpanId
      else: ""
    let traceFlags =
      if parsed.ok: parsed.flags
      else: "01"
    let spanId = randomHex16()
    let operation =
      if opts.operationName.len > 0:
        opts.operationName
      else:
        httpMethodLabel(req.methodKind) & " " & sanitizeOperationPath(req.path)

    var sampled = false
    if traceFlags.len == 2:
      try:
        sampled = (parseHexInt(traceFlags) and 1) == 1
      except ValueError:
        sampled = false
    let span = OtelSpanContext(
      traceId: traceId,
      spanId: spanId,
      parentSpanId: parentSpanId,
      traceFlags: traceFlags,
      sampled: sampled,
      operation: operation
    )
    let traceparent = "00-" & span.traceId & "-" & span.spanId & "-" & span.traceFlags
    req.setLocal(keys.traceId, span.traceId)
    req.setLocal(keys.spanId, span.spanId)
    req.setLocal(keys.parentSpanId, span.parentSpanId)
    req.setLocal(keys.traceFlags, span.traceFlags)
    req.setLocal(keys.sampled, if span.sampled: "1" else: "0")
    req.setLocal(keys.operation, span.operation)

    if opts.setTraceResponseHeader:
      res.set("traceparent", traceparent)

    if opts.onSpanStart != nil:
      try:
        opts.onSpanStart(req, span)
      except CatchableError as e:
        reportHookError(opts, "span_start", e)

    let startMono = getMonoTime()
    if opts.includeServerTiming:
      # Write the metric via a before-finalize hook so it lands while the
      # response headers are still mutable (i.e. inside the handler's send()),
      # instead of being dropped by the finished guard after the fact.
      res.addBeforeFinalizeHook(
        proc() {.closure.} =
          let durMicros = max(0'i64, (getMonoTime() - startMono).inMicroseconds)
          let durMs = $((durMicros.float) / 1000.0)
          res.append("server-timing",
            "trace;desc=\"" & span.traceId & "\";dur=" & durMs)
      )
    try:
      await next()
    finally:
      let durationMicros = max(0'i64, (getMonoTime() - startMono).inMicroseconds)
      if opts.includeServerTiming and not res.finished:
        let durMs = $((durationMicros.float) / 1000.0)
        res.append("server-timing",
          "trace;desc=\"" & span.traceId & "\";dur=" & durMs)
      if opts.onSpanEnd != nil:
        try:
          opts.onSpanEnd(req, res, span, durationMicros)
        except CatchableError as e:
          reportHookError(opts, "span_end", e)
