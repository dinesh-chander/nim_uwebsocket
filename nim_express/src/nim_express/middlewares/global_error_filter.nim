## Global exception filter middleware.
## Registers filters that transform exceptions into HTTP responses,
## similar to ASP.NET's IExceptionFilter pattern.

import std/[asyncdispatch, json]
import common
from logger import sanitizeLogField

const fallbackErrorBody = """{"error":"Internal Server Error"}"""

proc safeStderrWrite(msg: string) =
  try:
    stderr.writeLine(msg)
  except CatchableError:
    discard

type
  ExceptionFilterProc* = proc(err: ref Exception, req: Req, res: Res): bool {.closure.}
    ## Exception filter handler. Returns true when the filter claims the error.
    ## A handler returning true MUST have written and finalized the response
    ## (e.g. via res.json or res.send); the middleware then stops processing and
    ## does not send any further response. `res.finished` is not used as the
    ## claim signal because a write can be dropped as a late write (disconnected
    ## client) while still leaving the handler's chosen status authoritative.

  ExceptionFilter* = object
    name*: string
    priority*: int  ## Higher priority values are evaluated first (default 0).
    exceptionType*: string
    handler*: ExceptionFilterProc

  GlobalErrorFilterOptions* = object
    filters*: seq[ExceptionFilter]
    fallbackStatusCode*: int
    logUnhandled*: bool

## Return global error filter options with safe defaults.
proc defaultGlobalErrorFilterOptions*(): GlobalErrorFilterOptions {.inline.} =
  GlobalErrorFilterOptions(
    filters: @[],
    fallbackStatusCode: 500,
    logUnhandled: true
  )

## Build an `ExceptionFilter` with a `name`, `handler`, and optional priority.
proc newExceptionFilter*(
  name: string,
  handler: ExceptionFilterProc,
  priority: int = 0,
  exceptionType: string = ""
): ExceptionFilter {.inline.} =
  ## Creates an ExceptionFilter. Higher priority values are evaluated first.
  ExceptionFilter(
    name: name,
    priority: priority,
    exceptionType: exceptionType,
    handler: handler
  )

## Return the built-in filter mapping `ValueError` to a 400 response.
proc valueErrorFilter*(): ExceptionFilter =
  ExceptionFilter(
    name: "ValueError",
    priority: 100,
    exceptionType: "ValueError",
    handler: proc(err: ref Exception, req: Req, res: Res): bool =
      if err of ValueError:
        res.status(400)
        res.json("""{"error":"Bad Request"}""")
        return true
      false
  )

## Return the built-in filter mapping `KeyError` to a 400 response.
proc keyErrorFilter*(): ExceptionFilter =
  ExceptionFilter(
    name: "KeyError",
    priority: 90,
    exceptionType: "KeyError",
    handler: proc(err: ref Exception, req: Req, res: Res): bool =
      if err of KeyError:
        res.status(400)
        res.json("""{"error":"Bad Request"}""")
        return true
      false
  )

## Return the built-in filter mapping `IOError` to a 502 response.
proc ioErrorFilter*(): ExceptionFilter =
  ExceptionFilter(
    name: "IOError",
    priority: 70,
    exceptionType: "IOError",
    handler: proc(err: ref Exception, req: Req, res: Res): bool =
      if err of IOError:
        res.status(502)
        res.json("""{"error":"Bad Gateway"}""")
        return true
      false
  )

## Return the built-in filter mapping `OSError` to a 503 response.
proc osErrorFilter*(): ExceptionFilter =
  ExceptionFilter(
    name: "OSError",
    priority: 60,
    exceptionType: "OSError",
    handler: proc(err: ref Exception, req: Req, res: Res): bool =
      if err of OSError:
        res.status(503)
        res.json("""{"error":"Service Unavailable"}""")
        return true
      false
  )

## Return the built-in filter mapping `JsonParsingError` to a 400 response.
proc jsonParsingErrorFilter*(): ExceptionFilter =
  ExceptionFilter(
    name: "JsonParsingError",
    priority: 50,
    exceptionType: "JsonParsingError",
    handler: proc(err: ref Exception, req: Req, res: Res): bool =
      if err of JsonParsingError:
        res.status(400)
        res.json("""{"error":"Bad Request"}""")
        return true
      false
  )

## Return the five built-in exception filters; call once at startup.
proc builtinFilters*(): seq[ExceptionFilter] =
  ## Creates the 5 built-in ExceptionFilter objects (each with a fresh
  ## closure allocation). Call once at startup, not per-request.
  @[
    valueErrorFilter(),
    keyErrorFilter(),
    ioErrorFilter(),
    osErrorFilter(),
    jsonParsingErrorFilter()
  ]

proc sortedFilters(filters: seq[ExceptionFilter]): seq[ExceptionFilter] =
  result = filters
  for i in 1..<result.len:
    let key = result[i]
    var j = i - 1
    while j >= 0 and result[j].priority < key.priority:
      result[j + 1] = result[j]
      dec j
    result[j + 1] = key

## Middleware routing caught exceptions to the configured filters.
proc globalErrorFilter*(
  options: GlobalErrorFilterOptions = defaultGlobalErrorFilterOptions()
): AsyncMiddleware =
  let opts = options
  let sorted = sortedFilters(opts.filters)
  let fallback = if opts.fallbackStatusCode > 0: opts.fallbackStatusCode else: 500

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    try:
      await next()
    except CatchableError as e:
      if res.finished:
        return

      for filter in sorted:
        if filter.handler != nil:
          try:
            let handled = filter.handler(e, req, res)
            if handled:
              return
          except CatchableError as filterErr:
            safeStderrWrite("[global_error_filter] error in filter handler " &
              filter.name & " (" & $filterErr.name & "): " & sanitizeLogField(filterErr.msg))
            if res.finished:
              return
          except Defect as d:
            safeStderrWrite("[global_error_filter] DEFECT in filter handler " & $req.methodKind & " " & sanitizeLogField($req.path) & ": " & $d.name & ": " & sanitizeLogField(d.msg))
            if res.finished:
              return

      if opts.logUnhandled:
        safeStderrWrite("[global_error_filter] Unhandled: " & $e.name & ": " & sanitizeLogField(e.msg))

      res.status(fallback)
      res.json(fallbackErrorBody)
    except Defect as d:
      if res.finished:
        return

      if opts.logUnhandled:
        safeStderrWrite("[global_error_filter] DEFECT " & $req.methodKind & " " & sanitizeLogField($req.path) & ": " & $d.name & ": " & sanitizeLogField(d.msg))

      res.status(fallback)
      res.json(fallbackErrorBody)

## Middleware overload built directly from a sequence of filters.
proc globalErrorFilter*(filters: seq[ExceptionFilter]): AsyncMiddleware =
  globalErrorFilter(GlobalErrorFilterOptions(
    filters: filters,
    fallbackStatusCode: 500,
    logUnhandled: true
  ))

## Middleware with all built-in filters plus the given `extraFilters`.
proc globalErrorFilterWithBuiltins*(
  extraFilters: seq[ExceptionFilter] = @[]
): AsyncMiddleware =
  var allFilters = builtinFilters()
  for f in extraFilters:
    allFilters.add(f)
  globalErrorFilter(allFilters)
