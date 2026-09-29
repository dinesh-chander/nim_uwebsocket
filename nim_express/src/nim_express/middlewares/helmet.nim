## Security headers middleware with production-oriented defaults.

import std/[asyncdispatch, strutils, syncio, sysrand]
import common

type
  HelmetOptions* = object
    xContentTypeOptions*: bool
    xFrameOptions*: bool
    xFrameOptionsValue*: string
    referrerPolicy*: bool
    referrerPolicyValue*: string
    strictTransportSecurity*: bool
    strictTransportSecurityValue*: string
    xXssProtection*: bool
    xXssProtectionValue*: string
    contentSecurityPolicy*: bool
    contentSecurityPolicyValue*: string
    contentSecurityPolicyNonce*: bool
    ## Key under which the generated CSP nonce is stored in `req.locals`.
    ## Keep it unique per middleware instance to avoid collisions with other
    ## middleware or user code.
    contentSecurityPolicyNonceLocalKey*: string
    permissionsPolicy*: bool
    permissionsPolicyValue*: string
    crossOriginOpenerPolicy*: bool
    crossOriginOpenerPolicyValue*: string
    crossOriginResourcePolicy*: bool
    crossOriginResourcePolicyValue*: string
    disableXContentTypeOptions*: bool
    disableXFrameOptions*: bool
    disableReferrerPolicy*: bool
    disableStrictTransportSecurity*: bool
    disableCrossOriginOpenerPolicy*: bool
    disableCrossOriginResourcePolicy*: bool
    onError*: proc (msg: string)

## Returns the production-safe baseline `HelmetOptions` used to merge partial user options.
proc defaultHelmetOptions*(): HelmetOptions {.inline.} =
  HelmetOptions(
    xContentTypeOptions: true,
    xFrameOptions: true,
    xFrameOptionsValue: "SAMEORIGIN",
    referrerPolicy: true,
    referrerPolicyValue: "strict-origin-when-cross-origin",
    strictTransportSecurity: true,
    strictTransportSecurityValue: "max-age=31536000; includeSubDomains",
    xXssProtection: false,
    xXssProtectionValue: "0",
    contentSecurityPolicy: false,
    contentSecurityPolicyValue: "default-src 'self'; base-uri 'self'; frame-ancestors 'self'",
    contentSecurityPolicyNonce: false,
    contentSecurityPolicyNonceLocalKey: "csp_nonce",
    permissionsPolicy: false,
    permissionsPolicyValue: "camera=(), microphone=(), geolocation=()",
    crossOriginOpenerPolicy: true,
    crossOriginOpenerPolicyValue: "same-origin",
    crossOriginResourcePolicy: true,
    crossOriginResourcePolicyValue: "same-origin",
    disableXContentTypeOptions: false,
    disableXFrameOptions: false,
    disableReferrerPolicy: false,
    disableStrictTransportSecurity: false,
    disableCrossOriginOpenerPolicy: false,
    disableCrossOriginResourcePolicy: false,
    onError: nil
  )

## Merges options with production-safe defaults, applies disable overrides, and sanitizes header values.
proc normalizeHelmetOptions*(options: HelmetOptions): HelmetOptions {.noSideEffect.} =
  ## Merges partial option literals with production-safe baseline headers.
  let defaults = defaultHelmetOptions()
  result = options
  result.xContentTypeOptions =
    (result.xContentTypeOptions or defaults.xContentTypeOptions) and not result.disableXContentTypeOptions
  result.xFrameOptions =
    (result.xFrameOptions or defaults.xFrameOptions) and not result.disableXFrameOptions
  result.referrerPolicy =
    (result.referrerPolicy or defaults.referrerPolicy) and not result.disableReferrerPolicy
  result.strictTransportSecurity =
    (result.strictTransportSecurity or defaults.strictTransportSecurity) and not result.disableStrictTransportSecurity
  result.crossOriginOpenerPolicy =
    (result.crossOriginOpenerPolicy or defaults.crossOriginOpenerPolicy) and not result.disableCrossOriginOpenerPolicy
  result.crossOriginResourcePolicy =
    (result.crossOriginResourcePolicy or defaults.crossOriginResourcePolicy) and not result.disableCrossOriginResourcePolicy

  # xXssProtection, contentSecurityPolicy, and permissionsPolicy are intentionally
  # not normalized: they are opt-in headers (default false) with no disable*
  # override, so the (enabled or default) and not disable pattern does not apply.
  if result.xFrameOptionsValue.len == 0:
    result.xFrameOptionsValue = defaults.xFrameOptionsValue
  if result.referrerPolicyValue.len == 0:
    result.referrerPolicyValue = defaults.referrerPolicyValue
  if result.strictTransportSecurityValue.len == 0:
    result.strictTransportSecurityValue = defaults.strictTransportSecurityValue
  # Value defaults for opt-in headers are only materialized when the header is
  # enabled, avoiding wasted allocation for disabled options.
  if result.xXssProtection and result.xXssProtectionValue.len == 0:
    result.xXssProtectionValue = defaults.xXssProtectionValue
  if result.contentSecurityPolicy and result.contentSecurityPolicyValue.len == 0:
    result.contentSecurityPolicyValue = defaults.contentSecurityPolicyValue
  if result.contentSecurityPolicyNonceLocalKey.len == 0:
    result.contentSecurityPolicyNonceLocalKey = defaults.contentSecurityPolicyNonceLocalKey
  if result.permissionsPolicy and result.permissionsPolicyValue.len == 0:
    result.permissionsPolicyValue = defaults.permissionsPolicyValue
  if result.crossOriginOpenerPolicyValue.len == 0:
    result.crossOriginOpenerPolicyValue = defaults.crossOriginOpenerPolicyValue
  if result.crossOriginResourcePolicyValue.len == 0:
    result.crossOriginResourcePolicyValue = defaults.crossOriginResourcePolicyValue
  result.xFrameOptionsValue = sanitizeHeaderValue(result.xFrameOptionsValue)
  result.referrerPolicyValue = sanitizeHeaderValue(result.referrerPolicyValue)
  result.strictTransportSecurityValue = sanitizeHeaderValue(result.strictTransportSecurityValue)
  result.xXssProtectionValue = sanitizeHeaderValue(result.xXssProtectionValue)
  result.contentSecurityPolicyValue = sanitizeHeaderValue(result.contentSecurityPolicyValue)
  result.permissionsPolicyValue = sanitizeHeaderValue(result.permissionsPolicyValue)
  result.crossOriginOpenerPolicyValue = sanitizeHeaderValue(result.crossOriginOpenerPolicyValue)
  result.crossOriginResourcePolicyValue = sanitizeHeaderValue(result.crossOriginResourcePolicyValue)

## Generates a 32-character hex CSP nonce from 16 random bytes, or an empty string if randomness is unavailable.
proc buildNonce*(): string {.inline.} =
  var bytes: array[16, byte]
  result = newStringOfCap(32)
  if not urandom(bytes):
    var f: File
    if not open(f, "/dev/urandom", fmRead):
      return ""
    let n = f.readBuffer(addr(bytes), bytes.len)
    close(f)
    if n != bytes.len:
      return ""
  for b in bytes:
    result.add(b.toHex(2))

## Returns the CSP policy with the nonce directive injected, replacing {nonce} placeholders or extending script-src.
proc applyCspNonce*(policy, policyLower, nonce: string): string {.noSideEffect, inline.} =
  ## Injects a CSP nonce. `{nonce}` placeholders are replaced globally in every
  ## directive; place the placeholder only in directives that should receive it.
  if nonce.len == 0:
    return policy
  let nonceDirective = "'nonce-" & nonce & "'"
  if "{nonce}" in policy:
    return policy.replace("{nonce}", nonce)
  if policy.len == 0:
    return "script-src " & nonceDirective
  # If script-src already exists, append the nonce to it rather than adding a duplicate directive.
  let scriptSrcIdx = policyLower.find("script-src ")
  if scriptSrcIdx >= 0:
    # Insert the nonce after "script-src " by finding the end of the directive.
    let directiveEnd = policy.find(';', scriptSrcIdx)
    if directiveEnd >= 0:
      return policy[0..<directiveEnd] & " " & nonceDirective & policy[directiveEnd..^1]
    else:
      return policy & " " & nonceDirective
  if policyLower.endsWith("script-src"):
    # script-src is the final directive with no trailing space or semicolon.
    return policy & " " & nonceDirective
  policy & "; script-src " & nonceDirective

## Middleware that sets production-oriented security headers on each response from the normalized options.
proc helmet*(
  options: HelmetOptions = defaultHelmetOptions()
): AsyncMiddleware =
  let opts = normalizeHelmetOptions(options)
  # Lowercased CSP policy is computed once at construction time so the
  # per-request nonce path does not allocate a lowercase copy.
  let cspPolicyLower =
    if opts.contentSecurityPolicy and opts.contentSecurityPolicyNonce:
      opts.contentSecurityPolicyValue.toLowerAscii()
    else:
      ""
  let onError =
    if opts.onError.isNil:
      proc (msg: string) =
        stderr.writeLine("[helmet] ERROR: ", msg)
    else:
      opts.onError
  if opts.contentSecurityPolicy and opts.contentSecurityPolicyNonce and buildNonce().len == 0:
    onError("CSP nonce source unavailable at startup; nonce directives will be omitted")
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if opts.xContentTypeOptions:
      res.set("X-Content-Type-Options", "nosniff")
    if opts.xFrameOptions and opts.xFrameOptionsValue.len > 0:
      res.set("X-Frame-Options", opts.xFrameOptionsValue)
    if opts.referrerPolicy and opts.referrerPolicyValue.len > 0:
      res.set("Referrer-Policy", opts.referrerPolicyValue)
    if opts.strictTransportSecurity and opts.strictTransportSecurityValue.len > 0 and req.secure():
      # RFC 6797 §7.2: HSTS MUST NOT be sent over non-HTTPS responses.
      res.set("Strict-Transport-Security", opts.strictTransportSecurityValue)
    if opts.xXssProtection and opts.xXssProtectionValue.len > 0:
      res.set("X-XSS-Protection", opts.xXssProtectionValue)
    if opts.permissionsPolicy and opts.permissionsPolicyValue.len > 0:
      res.set("Permissions-Policy", opts.permissionsPolicyValue)
    if opts.crossOriginOpenerPolicy and opts.crossOriginOpenerPolicyValue.len > 0:
      res.set("Cross-Origin-Opener-Policy", opts.crossOriginOpenerPolicyValue)
    if opts.crossOriginResourcePolicy and opts.crossOriginResourcePolicyValue.len > 0:
      res.set("Cross-Origin-Resource-Policy", opts.crossOriginResourcePolicyValue)

    if opts.contentSecurityPolicy:
      var policy = opts.contentSecurityPolicyValue
      if opts.contentSecurityPolicyNonce:
        let nonce = buildNonce()
        if nonce.len > 0:
          req.locals[opts.contentSecurityPolicyNonceLocalKey] = nonce
          policy = applyCspNonce(policy, cspPolicyLower, nonce)
      if policy.len > 0:
        res.set("Content-Security-Policy", policy)

    await next()
