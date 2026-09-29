## Centralized error handler middleware (RFC 7807 Problem Details).

import std/[asyncdispatch, envVars]
import common
import logger

type
  ErrorHandlerOptions* = object
    devMode*: bool
    logErrors*: bool

## Returns the default error handler options, with error logging enabled and dev mode disabled.
proc defaultErrorHandlerOptions*(): ErrorHandlerOptions {.inline.} =
  ErrorHandlerOptions(
    devMode: false,
    logErrors: true
  )

## Returns the RFC 7807 problem type URI for an HTTP status code.
proc errorHandlerProblemType*(status: int): string {.inline.} =
  case status
  of 400: "https://tools.ietf.org/html/rfc7231#section-6.5.1"
  of 401: "https://tools.ietf.org/html/rfc7235#section-3.1"
  of 403: "https://tools.ietf.org/html/rfc7231#section-6.5.3"
  of 404: "https://tools.ietf.org/html/rfc7231#section-6.5.4"
  of 405: "https://tools.ietf.org/html/rfc7231#section-6.5.5"
  of 409: "https://tools.ietf.org/html/rfc7231#section-6.5.8"
  of 413: "https://tools.ietf.org/html/rfc7231#section-6.5.11"
  of 415: "https://tools.ietf.org/html/rfc7231#section-6.5.13"
  of 422: "https://tools.ietf.org/html/rfc4918#section-11.2"
  of 429: "https://tools.ietf.org/html/rfc6585#section-4"
  of 500: "https://tools.ietf.org/html/rfc7231#section-6.6.1"
  of 502: "https://tools.ietf.org/html/rfc7231#section-6.6.3"
  of 503: "https://tools.ietf.org/html/rfc7231#section-6.6.4"
  of 504: "https://tools.ietf.org/html/rfc7231#section-6.6.5"
  else: "about:blank"

## Returns the short human-readable title for an HTTP status code.
proc errorHandlerTitle*(status: int): string {.inline.} =
  case status
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 409: "Conflict"
  of 413: "Payload Too Large"
  of 415: "Unsupported Media Type"
  of 422: "Unprocessable Entity"
  of 429: "Too Many Requests"
  of 500: "Internal Server Error"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  of 504: "Gateway Timeout"
  else: "Error"

## Strips control characters from a stack trace to prevent log injection.
proc errorHandlerSanitizeTrace*(trace: string): string {.noSideEffect.} =
  ## Strips control characters (except newlines) from a stack trace before it
  ## is written to stderr, to prevent log injection / display corruption.
  result = newStringOfCap(trace.len)
  for c in trace:
    if c == '\n':
      result.add(c)
    elif c < ' ' or c == '\x7f':
      result.add(' ')
    else:
      result.add(c)

## Builds the RFC 7807 problem details JSON body for a given status code.
proc errorHandlerBody*(
  status: int,
  detail: string,
  includeErrorType: bool,
  errorTypeName: string,
  instance: string
): string =
  ## Builds the RFC 7807 ``application/problem+json`` body using the shared
  ## zero-alloc ``JsonBuilder`` path (no intermediate ``JsonNode`` allocation,
  ## ISSUE-4). ``error_type`` is emitted as an extension member when
  ## ``includeErrorType`` is set (dev mode).
  var extensions: seq[ProblemDetailExtension]
  if includeErrorType:
    extensions.add((key: "error_type", value: errorTypeName))
  buildRfc7807ProblemBody(
    statusCode = status,
    detail = detail,
    typeUri = errorHandlerProblemType(status),
    title = errorHandlerTitle(status),
    instance = instance,
    extensions = extensions
  )

proc writeErrorLog(kind, methodKind, path, className, msg: string, status: int) =
  ## Writes one error line to stderr. Logging failures are swallowed so they
  ## never prevent the error response from being sent (ISSUE-1).
  let classNamePart = if className.len > 0: className & ": " else: ""
  try:
    stderr.writeLine("[error_handler] ", kind, methodKind, " ",
      sanitizeLogField(path), " ", status, ": ", classNamePart, sanitizeLogField(msg))
  except CatchableError:
    discard

proc writeTrace(trace: string) =
  ## Writes a (pre-sanitized) stack trace to stderr; failures are swallowed.
  if trace.len == 0:
    return
  try:
    stderr.writeLine(trace)
  except CatchableError:
    discard

proc sendProblem(
  req: Req, res: Res, opts: ErrorHandlerOptions, isDevelopment: bool,
  status: int, detail: string, errorTypeName: string
) =
  ## Builds the RFC 7807 body and writes it. A failure to write never
  ## propagates out of the error handler: we retry with a minimal plain-text
  ## body, and if that also fails we swallow it (ISSUE-7).
  let devDetail = opts.devMode and isDevelopment
  let body = errorHandlerBody(
    status,
    detail = if devDetail: detail else: errorHandlerTitle(status),
    includeErrorType = devDetail,
    errorTypeName = errorTypeName,
    instance = req.locals.getOrDefault("requestId", "")
  )
  try:
    res.status(status)
    res.set("Content-Type", "application/problem+json; charset=utf-8")
    res.send(body)
  except CatchableError:
    try:
      res.status(status)
      res.set("Content-Type", "text/plain; charset=utf-8")
      res.send("Error")
    except CatchableError:
      discard

## Catches unhandled downstream exceptions and replies with an RFC 7807 problem details JSON response.
proc errorHandler*(
  options: ErrorHandlerOptions = defaultErrorHandlerOptions()
): AsyncMiddleware =
  ## Catches unhandled exceptions from downstream and returns RFC 7807
  ## Problem Details JSON responses.
  ##
  ## Exception details (message, class name, stack trace) are only included
  ## in the HTTP body when built with ``devMode = true`` AND
  ## ``NIM_EXPRESS_ENV`` is explicitly ``development`` (a positive check,
  ## ISSUE-2). In any other environment -- unset, staging, or production --
  ## the body carries only the generic status title, and details go to
  ## stderr.
  let opts = options
  let isDevelopment = getEnv("NIM_EXPRESS_ENV") == "development"

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    try:
      await next()
    except CatchableError as e:
      if res.finished:
        return
      let status = if res.statusCode >= 400: res.statusCode else: 500
      if opts.logErrors:
        writeErrorLog("", $req.methodKind, $req.path, "", e.msg, status)
      if opts.devMode and isDevelopment:
        writeTrace(errorHandlerSanitizeTrace(e.getStackTrace()))
      sendProblem(req, res, opts, isDevelopment, status, e.msg, $e.name)
    except Defect as d:
      if res.finished:
        return
      let status = 500
      if opts.logErrors:
        writeErrorLog("DEFECT ", $req.methodKind, $req.path, $d.name, d.msg, status)
        writeTrace(errorHandlerSanitizeTrace(d.getStackTrace()))
      sendProblem(req, res, opts, isDevelopment, status, d.msg, $d.name)
