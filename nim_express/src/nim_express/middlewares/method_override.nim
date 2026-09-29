## Method override support using pre-route advice.
## This avoids method-confusion by applying override before route lookup.

import std/[strutils, uri]
import common
import ../app

type
  MethodOverrideSource* = enum
    mosHeader
    mosQuery
    mosForm

  MethodOverrideAuditHook* = proc(
    req: Req,
    originalMethod: HttpMethod,
    overriddenMethod: HttpMethod,
    source: MethodOverrideSource,
    rawToken: string
  ) {.closure.}

  MethodOverrideOptions* = object
    sources*: seq[MethodOverrideSource]
    headerName*: string
    queryParam*: string
    formField*: string
    fromMethods*: set[HttpMethod]
    allowedMethods*: set[HttpMethod]
    rejectInvalid*: bool
    rejectStatus*: int
    plusAsSpace*: bool
    maxFormBytes*: int
    auditHook*: MethodOverrideAuditHook

  MethodOverrideResolveKind* = enum
    morkNone
    morkInvalidToken
    morkDisallowedTarget
    morkResolved

  MethodOverrideResolveResult* = object
    kind*: MethodOverrideResolveKind
    methodKind*: HttpMethod
    source*: MethodOverrideSource
    rawToken*: string ## cleaned+uppercased token, not the raw user input

const
  DefaultMethodOverrideMaxFormBytes* = 16 * 1024

## Returns a `MethodOverrideOptions` with the standard header, query, and form
## sources, a 16KiB form limit, and PUT/PATCH/DELETE as allowed targets.
proc defaultMethodOverrideOptions*(): MethodOverrideOptions {.inline.} =
  MethodOverrideOptions(
    sources: @[mosHeader, mosQuery, mosForm],
    headerName: "x-http-method-override",
    queryParam: "_method",
    formField: "_method",
    fromMethods: {hmPost},
    allowedMethods: {hmPut, hmPatch, hmDelete},
    rejectInvalid: false,
    rejectStatus: 400,
    plusAsSpace: true,
    maxFormBytes: DefaultMethodOverrideMaxFormBytes,
    auditHook: nil
  )

## Trims and upper-cases a raw override token, returning an empty string when
## it exceeds 15 characters or contains any non-alphabetic byte.
proc cleanMethodToken(raw: string): string {.inline, noSideEffect.} =
  let trimmed = raw.strip()
  # HTTP methods are short; cap prevents large allocations on hostile input.
  if trimmed.len == 0 or trimmed.len > 15:
    return ""
  for c in trimmed:
    if c notin {'a'..'z', 'A'..'Z'}:
      return ""
  var normalized = newStringOfCap(trimmed.len)
  for c in trimmed:
    if c >= 'a' and c <= 'z':
      normalized.add(char(ord(c) - 32))
    else:
      normalized.add(c)
  normalized

## Maps an upper-cased method token to a `HttpMethod`, rejecting CONNECT and
## TRACE as well as unknown method names.
proc parseMethodToken(token: string): tuple[ok: bool, methodKind: HttpMethod] {.noSideEffect.} =
  # CONNECT (SSRF/tunneling) and TRACE (XST) are intentionally not valid
  # override targets.
  case token
  of "GET": (true, hmGet)
  of "POST": (true, hmPost)
  of "PUT": (true, hmPut)
  of "DELETE": (true, hmDelete)
  of "PATCH": (true, hmPatch)
  of "HEAD": (true, hmHead)
  of "OPTIONS": (true, hmOptions)
  else: (false, hmGet)

## URL-decodes a single form key or value, translating `+` to a space first
## when `plusAsSpace` is set.
proc decodeFormComponent(raw: string, plusAsSpace: bool): string {.noSideEffect.} =
  try:
    if plusAsSpace and raw.find('+') >= 0:
      return decodeUrl(raw.replace("+", " "))
    decodeUrl(raw)
  except CatchableError:
    raw

## Scans a urlencoded request body for `fieldName` without decoding the whole
## body, enforcing `maxFormBytes` via the content-length hint and actual size.
proc extractFormOverride(
  req: Req,
  fieldName: string,
  maxFormBytes: int,
  plusAsSpace: bool
): string =
  if fieldName.len == 0:
    return ""
  let contentType = req.get("content-type").toLowerAscii()
  if "application/x-www-form-urlencoded" notin contentType:
    return ""

  if maxFormBytes > 0:
    let hint = req.rawBodySizeHint()
    if hint >= 0 and hint > maxFormBytes:
      return ""

  let body = req.rawBody()
  if body.len == 0:
    return ""
  if maxFormBytes > 0 and body.len > maxFormBytes:
    return ""

  var startPos = 0
  var i = 0
  while true:
    if i >= body.len or body[i] == '&':
      if i > startPos:
        var sepPos = startPos
        while sepPos < i and body[sepPos] != '=':
          inc sepPos
        if sepPos > startPos:
          let key = decodeFormComponent(body[startPos ..< sepPos], plusAsSpace)
          if key == fieldName:
            if sepPos < i:
              return decodeFormComponent(body[(sepPos + 1) ..< i], plusAsSpace)
            return ""
      if i >= body.len:
        break
      startPos = i + 1
    inc i
  ""

## Inspects the header, query, and form sources named in `options` and returns
## the `MethodOverrideResolveResult` for the first valid override token found.
proc resolveOverrideMethod*(
  req: Req,
  options: MethodOverrideOptions = defaultMethodOverrideOptions()
): MethodOverrideResolveResult =
  if req == nil:
    return MethodOverrideResolveResult(kind: morkNone)
  if req.methodKind notin options.fromMethods:
    return MethodOverrideResolveResult(kind: morkNone)

  for source in options.sources:
    var candidate = ""
    case source
    of mosHeader:
      if options.headerName.len > 0:
        candidate = req.get(options.headerName)
    of mosQuery:
      if options.queryParam.len > 0:
        candidate = req.queryParam(options.queryParam, "")
    of mosForm:
      candidate = extractFormOverride(
        req,
        options.formField,
        options.maxFormBytes,
        options.plusAsSpace
      )

    let token = cleanMethodToken(candidate)
    if token.len == 0:
      continue
    let parsed = parseMethodToken(token)
    if not parsed.ok:
      return MethodOverrideResolveResult(
        kind: morkInvalidToken,
        source: source,
        rawToken: token
      )
    if parsed.methodKind notin options.allowedMethods:
      return MethodOverrideResolveResult(
        kind: morkDisallowedTarget,
        methodKind: parsed.methodKind,
        source: source,
        rawToken: token
      )
    return MethodOverrideResolveResult(
      kind: morkResolved,
      methodKind: parsed.methodKind,
      source: source,
      rawToken: token
    )

  MethodOverrideResolveResult(kind: morkNone)

## Rewrites `req.methodKind` for a resolved override and invokes `auditHook`;
## returns true only when the request method actually changed.
proc applyResolvedOverride(
  req: Req,
  resolved: MethodOverrideResolveResult,
  auditHook: MethodOverrideAuditHook,
  res: Res = nil
): bool {.inline.} =
  if resolved.kind != morkResolved:
    return false
  if req.methodKind == resolved.methodKind:
    return false

  let original = req.methodKind
  req.methodKind = resolved.methodKind
  if req.native != nil:
    req.native.methodKind = resolved.methodKind
  if auditHook != nil:
    try:
      auditHook(req, original, resolved.methodKind, resolved.source, resolved.rawToken)
    except CatchableError as e:
      if res != nil and res.app != nil and res.app.errorHook != nil:
        try:
          res.app.errorHook("method_override: audit hook failed: " & e.msg)
        except CatchableError:
          discard
  true

## Resolves and applies the first valid method override for `req`, returning
## whether the request method was changed.
proc applyMethodOverride*(
  req: Req,
  options: MethodOverrideOptions = defaultMethodOverrideOptions()
): bool =
  let resolved = resolveOverrideMethod(req, options)
  applyResolvedOverride(req, resolved, options.auditHook)

## Registers a pre-route advice on `app` that applies method overrides and,
## when enabled, rejects invalid tokens with `rejectStatus`.
proc installMethodOverride*(
  app: ExpressApp,
  options: MethodOverrideOptions = defaultMethodOverrideOptions()
) =
  if app == nil:
    return
  var opts = options
  opts.sources = @(options.sources)
  app.onBeforeRouteMatchAdvice(proc(req: Req, res: Res): bool =
    let resolved = resolveOverrideMethod(req, opts)
    case resolved.kind
    of morkNone:
      return true
    of morkResolved:
      discard applyResolvedOverride(req, resolved, opts.auditHook, res)
      return true
    of morkInvalidToken, morkDisallowedTarget:
      if opts.rejectInvalid and res != nil and not res.finished:
        res.status(opts.rejectStatus).send("Bad Request")
        return false
      return true
  )

## Convenience alias.
proc methodOverride*(
  app: ExpressApp,
  options: MethodOverrideOptions = defaultMethodOverrideOptions()
) {.inline.} =
  installMethodOverride(app, options)
