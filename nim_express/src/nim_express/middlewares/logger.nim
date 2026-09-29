## Logger middleware

import std/[asyncdispatch, times, strutils]
import common

type
  MiddlewareLogLevel* = types.LogLevel
  # `types.LogFormat` is shadowed by a re-exported async_logger.LogFormat in the
  # shared types module; derive the express LogFormat (lfDev/lfCommon/...) from a
  # value of the intended enum so the format overload is usable.
  MiddlewareLogFormat* = type(lfDev)
  LoggerSink* = proc(line: string)

var loggerSink*: LoggerSink = proc(line: string) = echo line

const
  ordLlDebug = ord(MiddlewareLogLevel.llDebug)
  ordLlInfo = ord(MiddlewareLogLevel.llInfo)
  ordLlWarn = ord(MiddlewareLogLevel.llWarn)
  ordLlError = ord(MiddlewareLogLevel.llError)

  ordLfDev = ord(lfDev)
  ordLfCombined = ord(lfCombined)
  ordLfCommon = ord(lfCommon)
  ordLfShort = ord(lfShort)
  ordLfTiny = ord(lfTiny)

## Escapes control characters, quotes, and backslashes so the value stays safe for line-oriented log output.
proc sanitizeLogField*(value: string): string =
  ## Escapes bytes that can break line-oriented log parsers. U+2028/U+2029 are
  ## multi-byte UTF-8 (0xE2 0x80 0xA8/0xA9) so they are matched on the raw byte
  ## sequence without altering behaviour for any other input.
  if value.len == 0:
    return ""
  result = newStringOfCap(value.len + 8)
  var i = 0
  while i < value.len:
    let b = value[i].int
    if b < 0x20 or b == 0x7f:
      result.add("\\x")
      result.add(toHex(b, 2))
      inc i
    elif b == 0xe2 and i + 2 < value.len and value[i+1].int == 0x80 and
         (value[i+2].int == 0xa8 or value[i+2].int == 0xa9):
      if value[i+2].int == 0xa8:
        result.add("\\u2028")
      else:
        result.add("\\u2029")
      inc i, 3
    elif b == 0x5c:
      result.add("\\\\")
      inc i
    elif b == 0x22:
      result.add("\\\"")
      inc i
    else:
      result.add(value[i])
      inc i

proc remoteIpForLog(req: Req): string =
  ## ISSUE-4: nil-guard req.native before dereferencing remoteIp.
  if req.native != nil:
    sanitizeLogField(req.native.remoteIp)
  else:
    "-"

proc httpVersionString(req: Req): string =
  ## ISSUE-3: derive the protocol version from the native request instead of
  ## hardcoding HTTP/1.1; fall back to HTTP/1.1 when unavailable/unset.
  if req.native != nil and req.native.httpMajor >= 1:
    result = "HTTP/" & $req.native.httpMajor & "." & $req.native.httpMinor
  else:
    result = "HTTP/1.1"

template emitLogLine(req: Req, res: Res, duration: int, requestId: string, safePath: string) =
  if requestId.len > 0:
    loggerSink($req.methodKind & " " & safePath & " " & $res.statusCode & " - " & $duration & "ms reqId=" & requestId)
  else:
    loggerSink($req.methodKind & " " & safePath & " " & $res.statusCode & " - " & $duration & "ms")

## Creates middleware that logs each request at the given ``MiddlewareLogLevel`` threshold.
proc logger*(level: MiddlewareLogLevel = types.llInfo): AsyncMiddleware =
  let logLevelOrd = ord(level)
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let start = epochTime()
    var handlerError: ref CatchableError = nil
    var handlerDefect: ref Defect = nil
    try:
      await next()
    except CatchableError as e:
      handlerError = e
      if res.statusCode < 400:
        res.statusCode = 500
    except Defect as d:
      handlerDefect = d
      if res.statusCode < 400:
        res.statusCode = 500
    let duration = ((epochTime() - start) * 1000).int
    let safePath = sanitizeLogField(req.path)
    let requestId = sanitizeLogField(req.locals.getOrDefault("requestId", ""))

    var shouldLog = false
    if logLevelOrd == ordLlDebug or logLevelOrd == ordLlInfo:
      shouldLog = true
    elif logLevelOrd == ordLlWarn:
      shouldLog = res.statusCode >= 400
    elif logLevelOrd == ordLlError:
      shouldLog = res.statusCode >= 500

    if shouldLog:
      emitLogLine(req, res, duration, requestId, safePath)

    if handlerDefect != nil:
      raise handlerDefect
    elif handlerError != nil:
      raise handlerError

## Creates middleware that logs each request using the given ``MiddlewareLogFormat`` style.
proc logger*(format: MiddlewareLogFormat): AsyncMiddleware =
  let logFormatOrd = ord(format)
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let start = epochTime()
    var handlerError: ref CatchableError = nil
    var handlerDefect: ref Defect = nil
    try:
      await next()
    except CatchableError as e:
      handlerError = e
      if res.statusCode < 400:
        res.statusCode = 500
    except Defect as d:
      handlerDefect = d
      if res.statusCode < 400:
        res.statusCode = 500
    let duration = ((epochTime() - start) * 1000).int
    let safePath = sanitizeLogField(req.path)
    let requestId = sanitizeLogField(req.locals.getOrDefault("requestId", ""))

    if logFormatOrd == ordLfDev:
      let color = case res.statusCode
        of 200..299: "\e[32m"
        of 300..399: "\e[36m"
        of 400..499: "\e[33m"
        of 500..599: "\e[31m"
        else: "\e[0m"
      if requestId.len > 0:
        loggerSink(color & $req.methodKind & "\e[0m " & safePath & " " & color & $res.statusCode & "\e[0m - " & $duration & "ms reqId=" & requestId)
      else:
        loggerSink(color & $req.methodKind & "\e[0m " & safePath & " " & color & $res.statusCode & "\e[0m - " & $duration & "ms")
    elif logFormatOrd == ordLfCommon:
      let remoteIp = remoteIpForLog(req)
      let ts = now().utc.format("[dd/MMM/yyyy:HH:mm:ss '+0000']")
      let requestLine = $req.methodKind & " " & safePath & " " & httpVersionString(req)
      let cl = req.get("content-length")
      let bodySize = if cl.len > 0: cl else: "-"
      loggerSink(remoteIp & " - - " & ts & " \"" & requestLine & "\" " & $res.statusCode & " " & bodySize)
    elif logFormatOrd == ordLfCombined:
      let remoteIp = remoteIpForLog(req)
      let ts = now().utc.format("[dd/MMM/yyyy:HH:mm:ss '+0000']")
      let requestLine = $req.methodKind & " " & safePath & " " & httpVersionString(req)
      let cl = req.get("content-length")
      let bodySize = if cl.len > 0: cl else: "-"
      let referer = sanitizeLogField(req.get("referer"))
      let refererStr = if referer.len > 0: referer else: "-"
      let ua = sanitizeLogField(req.get("user-agent"))
      let uaStr = if ua.len > 0: ua else: "-"
      loggerSink(remoteIp & " - - " & ts & " \"" & requestLine & "\" " & $res.statusCode & " " & bodySize & " \"" & refererStr & "\" \"" & uaStr & "\"")
    elif logFormatOrd == ordLfShort:
      if requestId.len > 0:
        loggerSink($req.methodKind & " " & safePath & " " & $res.statusCode & " " & $duration & "ms reqId=" & requestId)
      else:
        loggerSink($req.methodKind & " " & safePath & " " & $res.statusCode & " " & $duration & "ms")
    elif logFormatOrd == ordLfTiny:
      if requestId.len > 0:
        loggerSink($req.methodKind & " " & safePath & " " & $res.statusCode & " reqId=" & requestId)
      else:
        loggerSink($req.methodKind & " " & safePath & " " & $res.statusCode)

    if handlerDefect != nil:
      raise handlerDefect
    elif handlerError != nil:
      raise handlerError
