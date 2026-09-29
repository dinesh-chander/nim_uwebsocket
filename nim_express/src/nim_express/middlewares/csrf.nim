## CSRF protection middleware (double-submit token model).

import std/[asyncdispatch, strutils, sysrand]
import common

type
  CsrfOptions* = object
    cookieName*: string
    headerName*: string
    formField*: string
    tokenLocalKey*: string
    ignoreMethods*: set[HttpMethod]
    ignoreMethodsSet*: bool
    secureCookie*: bool
    httpOnlyCookie*: bool
    sameSite*: string
    path*: string
    domain*: string
    rotatePerRequest*: bool
    rejectStatus*: int
    allowQueryToken*: bool
    allowInsecureCookie*: bool
    allowClientReadableCookie*: bool

## Returns production-safe default CsrfOptions for the csrf middleware.
proc defaultCsrfOptions*(): CsrfOptions {.inline.} =
  CsrfOptions(
    cookieName: "_csrf",
    headerName: "x-csrf-token",
    formField: "_csrf",
    tokenLocalKey: "csrf_token",
    ignoreMethods: {hmGet, hmHead, hmOptions},
    ignoreMethodsSet: true,
    secureCookie: true,
    # Header-based double-submit requires a JS-readable cookie; the client
    # echoes the cookie value back in the header, so httpOnly must be false by
    # default. Opt into a fully server-only cookie with
    # allowClientReadableCookie = false (normalizeCsrfOptions then forces
    # httpOnlyCookie = true as a fail-safe).
    httpOnlyCookie: false,
    sameSite: "Lax",
    path: "/",
    domain: "",
    rotatePerRequest: false,
    rejectStatus: 403,
    allowQueryToken: false,
    allowInsecureCookie: false,
    allowClientReadableCookie: true
  )

## Fills empty CsrfOptions fields with defaults and enforces safe cookie flag fallbacks.
proc normalizeCsrfOptions*(options: CsrfOptions): CsrfOptions =
  ## Merges partial option literals with production-safe defaults.
  let defaults = defaultCsrfOptions()
  result = options
  if result.cookieName.len == 0:
    result.cookieName = defaults.cookieName
  if result.headerName.len == 0:
    result.headerName = defaults.headerName
  if result.formField.len == 0:
    result.formField = defaults.formField
  if result.tokenLocalKey.len == 0:
    result.tokenLocalKey = defaults.tokenLocalKey
  # Only fall back to the default safe-method set when the caller did not
  # explicitly opt into an empty set (ignoreMethodsSet). This lets a caller
  # deliberately disable validation for every method via
  # CsrfOptions(ignoreMethods: {}, ignoreMethodsSet: true).
  if not result.ignoreMethodsSet and result.ignoreMethods == {}:
    result.ignoreMethods = defaults.ignoreMethods
  if result.sameSite.len == 0:
    result.sameSite = defaults.sameSite
  if result.path.len == 0:
    result.path = defaults.path
  if result.rejectStatus < 400 or result.rejectStatus > 599:
    result.rejectStatus = defaults.rejectStatus
  if not result.allowInsecureCookie:
    result.secureCookie = true
  if not result.allowClientReadableCookie:
    result.httpOnlyCookie = true

const hexDigitsLower = "0123456789abcdef"

## Generates a 40-character lowercase hex CSRF token from 20 random bytes.
proc csrfGenerateToken*(): string =
  ## Generates a 40-character lowercase hex token (20 random bytes).
  ## Not marked noSideEffect: it reads entropy via sysrand.urandom.
  var bytes: array[20, byte]
  if urandom(bytes):
    result = newString(40)
    for i, b in bytes:
      result[i * 2] = hexDigitsLower[int(b shr 4)]
      result[i * 2 + 1] = hexDigitsLower[int(b and 0x0F)]

## Compares two CSRF token strings in constant time to avoid timing side channels.
proc csrfConstantTimeEqual*(a, b: string): bool {.noSideEffect.} =
  ## Constant-time string comparison to prevent timing side-channels.
  ## Runs over the full length of the longer input (no early return) so the
  ## wall-clock cost does not depend on where a mismatch occurs or on the
  ## length difference; the length difference is folded into the diff.
  ## Both sides are normalized to lowercase for case-insensitive hex compare.
  var diff = a.len xor b.len
  let bound = if a.len > b.len: a.len else: b.len
  for i in 0 ..< bound:
    var ca = if i < a.len: ord(a[i]) else: 0
    var cb = if i < b.len: ord(b[i]) else: 0
    # Normalize to lowercase for case-insensitive hex comparison.
    if ca >= ord('A') and ca <= ord('F'):
      ca = ca + 32
    if cb >= ord('A') and cb <= ord('F'):
      cb = cb + 32
    diff = diff or (ca xor cb)
  diff == 0

## Returns the CSRF token stored in req.locals under localKey, or an empty string if absent.
proc csrfToken*(req: Req, localKey: string = "csrf_token"): string {.inline.} =
  if req == nil:
    return ""
  if req.locals == nil:
    return ""
  req.locals.getOrDefault(localKey, "")

## Async CSRF middleware using a double-submit cookie token echoed via header or form field.
proc csrf*(
  options: CsrfOptions = defaultCsrfOptions()
): AsyncMiddleware =
  ## Double-submit CSRF token protection.
  ##
  ## A token is issued as a cookie and echoed back by the client in the
  ## ``headerName`` header (default ``x-csrf-token``) or the ``formField``
  ## form field. Safe methods (GET/HEAD/OPTIONS by default) skip validation.
  ##
  ## The default is a JS-readable cookie (``httpOnlyCookie = false``) because
  ## the header double-submit model needs the client to read the cookie. For
  ## plain-HTTP (non-TLS) deployments set ``allowInsecureCookie = true`` and
  ## ``secureCookie = false``; otherwise the cookie is never sent over HTTP
  ## and validation always fails.
  ##
  ## ``allowQueryToken`` accepts the token from the query string. Keep it
  ## disabled unless required: tokens in URLs leak through Referer headers,
  ## access logs, and browser history.
  ##
  ## The form-field fallback reads ``"form_" & formField`` from
  ## ``req.locals``, which the urlencoded body parser populates; register a
  ## body parser (e.g. ``urlencoded()``) before ``csrf()`` so form
  ## submissions are validated against their token.
  ##
  ## Use ``csrfSync`` for the sync fast path when no async middleware is in
  ## the chain.
  let opts = normalizeCsrfOptions(options)
  let formKey = "form_" & opts.formField
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    var token = req.cookie(opts.cookieName)
    if token.len == 0:
      token = csrfGenerateToken()
      if token.len == 0:
        res.status(500).send("Internal Server Error")
        return
      discard res.cookie(
        opts.cookieName,
        token,
        path = opts.path,
        domain = opts.domain,
        secure = opts.secureCookie,
        httpOnly = opts.httpOnlyCookie,
        sameSite = opts.sameSite
      )
    req.locals[opts.tokenLocalKey] = token

    if req.methodKind in opts.ignoreMethods:
      await next()
      return

    var provided = req.get(opts.headerName)
    if provided.len == 0 and opts.formField.len > 0:
      provided = req.locals.getOrDefault(formKey, "")
      if provided.len == 0 and opts.allowQueryToken:
        provided = req.queryParam(opts.formField, "")

    if provided.len == 0 or not csrfConstantTimeEqual(provided, token):
      res.status(opts.rejectStatus).send("Forbidden")
      return

    if opts.rotatePerRequest:
      token = csrfGenerateToken()
      if token.len == 0:
        res.status(500).send("Internal Server Error")
        return
      req.locals[opts.tokenLocalKey] = token
      discard res.cookie(
        opts.cookieName,
        token,
        path = opts.path,
        domain = opts.domain,
        secure = opts.secureCookie,
        httpOnly = opts.httpOnlyCookie,
        sameSite = opts.sameSite
      )

    await next()

## Synchronous CSRF middleware with the same double-submit validation as csrf for sync handlers.
proc csrfSync*(
  options: CsrfOptions = defaultCsrfOptions()
): SyncNextMiddleware =
  ## Synchronous variant of `csrf` for the sync middleware fast path. Performs
  ## the same double-submit validation with no I/O; if validation behavior
  ## changes, update both this and the async `csrf` middleware.
  let opts = normalizeCsrfOptions(options)
  let formKey = "form_" & opts.formField
  result = proc(req: Req, res: Res, next: proc() {.closure.}) =
    var token = req.cookie(opts.cookieName)
    if token.len == 0:
      token = csrfGenerateToken()
      if token.len == 0:
        res.status(500).send("Internal Server Error")
        return
      discard res.cookie(
        opts.cookieName,
        token,
        path = opts.path,
        domain = opts.domain,
        secure = opts.secureCookie,
        httpOnly = opts.httpOnlyCookie,
        sameSite = opts.sameSite
      )
    req.locals[opts.tokenLocalKey] = token

    if req.methodKind in opts.ignoreMethods:
      next()
      return

    var provided = req.get(opts.headerName)
    if provided.len == 0 and opts.formField.len > 0:
      provided = req.locals.getOrDefault(formKey, "")
      if provided.len == 0 and opts.allowQueryToken:
        provided = req.queryParam(opts.formField, "")

    if provided.len == 0 or not csrfConstantTimeEqual(provided, token):
      res.status(opts.rejectStatus).send("Forbidden")
      return

    if opts.rotatePerRequest:
      token = csrfGenerateToken()
      if token.len == 0:
        res.status(500).send("Internal Server Error")
        return
      req.locals[opts.tokenLocalKey] = token
      discard res.cookie(
        opts.cookieName,
        token,
        path = opts.path,
        domain = opts.domain,
        secure = opts.secureCookie,
        httpOnly = opts.httpOnlyCookie,
        sameSite = opts.sameSite
      )

    next()
