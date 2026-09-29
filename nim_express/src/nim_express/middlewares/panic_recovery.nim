## Panic/crash recovery middleware.
## Catches unhandled exceptions and returns 500 instead of crashing.

import std/asyncdispatch
import common
import logger

type
  ErrorResponseFormat* = enum
    erfJson
    erfPlainText

  ErrorReportHook* = proc(err: ref Exception, req: Req, path: string) {.closure.}
    ## Invoked when an exception is caught. `path` is the raw decoded request
    ## path (unsanitized) and may contain control characters; sanitize it
    ## before writing to structured logging systems.

  PanicRecoveryOptions* = object
    responseFormat*: ErrorResponseFormat
    ## Log caught errors to stderr.
    logErrors*: bool
    ## Also log the stack trace for CatchableError. Stack traces for Defect
    ## are always logged (when logErrors is true) regardless of this flag.
    includeStackTrace*: bool
    reportHook*: ErrorReportHook

## Returns the default ``PanicRecoveryOptions``: JSON error format, stderr logging enabled, no stack traces, no report hook.
proc defaultPanicRecoveryOptions*(): PanicRecoveryOptions {.inline.} =
  PanicRecoveryOptions(
    responseFormat: erfJson,
    logErrors: true,
    includeStackTrace: false,
    reportHook: nil
  )

proc sendPanicResponse(res: Res, opts: PanicRecoveryOptions) {.inline.} =
  res.status(500)
  case opts.responseFormat
  of erfJson:
    res.jsonRaw("""{"error":"Internal Server Error"}""")
  of erfPlainText:
    res.set("Content-Type", "text/plain; charset=utf-8")
    res.send("Internal Server Error")

proc logAndReport(
  opts: PanicRecoveryOptions,
  req: Req,
  exc: ref Exception,
  defectName: string,
  logTrace: bool
) =
  if opts.logErrors:
    let safePath = sanitizeLogField($req.path)
    if defectName.len > 0:
      stderr.writeLine("[panic_recovery] DEFECT ", $req.methodKind, " ", safePath, " 500: ", defectName, ": ", sanitizeLogField(exc.msg))
    else:
      stderr.writeLine("[panic_recovery] ", $req.methodKind, " ", safePath, " 500: ", sanitizeLogField(exc.msg))
    if logTrace:
      let trace = exc.getStackTrace()
      if trace.len > 0:
        stderr.writeLine(trace)

  if opts.reportHook != nil:
    try:
      opts.reportHook(exc, req, $req.path)
    except CatchableError as hookErr:
      stderr.writeLine("[panic_recovery] error in report hook: " & sanitizeLogField(hookErr.msg))
    except Defect as hookDef:
      stderr.writeLine("[panic_recovery] DEFECT in report hook: " & $hookDef.name & ": " & sanitizeLogField(hookDef.msg))

## Builds a panic-recovery middleware from the given ``PanicRecoveryOptions``.
proc panicRecovery*(
  options: PanicRecoveryOptions = defaultPanicRecoveryOptions()
): AsyncMiddleware =
  ## Creates an async middleware that catches unhandled exceptions from
  ## downstream handlers and returns a generic 500 response instead of
  ## crashing the process.
  ##
  ## - CatchableError: logged when `options.logErrors` is true; the stack
  ##   trace is logged only when `options.includeStackTrace` is true.
  ## - Defect: message and stack trace are always logged (when
  ##   `options.logErrors` is true), regardless of `options.includeStackTrace`.
  ## - When `options.reportHook` is set, it is invoked with the raw
  ##   exception, the request, and the raw (unsanitized) decoded path.
  let opts = options

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    try:
      await next()
    except CatchableError as e:
      if res.finished:
        return
      logAndReport(opts, req, e, "", logTrace = opts.includeStackTrace)
      sendPanicResponse(res, opts)
    # NOTE: In Nim 2.x release builds (--exceptions:cpp), Defects are not
    # catchable and terminate the process before this handler runs; this
    # branch fires only in debug/legacy builds. The production safety net
    # for Defects is the process supervisor (systemd, Docker, etc.).
    except Defect as d:
      if res.finished:
        return
      logAndReport(opts, req, d, $d.name, logTrace = true)
      sendPanicResponse(res, opts)

## Builds a panic-recovery middleware with default options plus the given ``reportHook``.
proc panicRecovery*(reportHook: ErrorReportHook): AsyncMiddleware =
  ## Creates a panic-recovery middleware with default options plus the
  ## given `reportHook`. See `panicRecovery(options)` for behavior.
  var opts = defaultPanicRecoveryOptions()
  opts.reportHook = reportHook
  panicRecovery(opts)
