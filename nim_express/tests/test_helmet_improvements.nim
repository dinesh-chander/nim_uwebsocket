import std/[unittest, asyncdispatch, strutils, tables, algorithm]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/helmet

proc newMockHttpRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[]
): HttpRequest =
  new(result)
  result.path = pathVal
  result.queryStringRaw = ""
  result.httpVersion = "1.1"
  result.httpMajor = 1
  result.httpMinor = 1
  result.body = bodyStr
  result.remoteIp = remoteIpStr
  result.methodKind = methodKind
  result.connectionClose = false
  result.headersDeferred = false
  result.bodyInFile = false
  result.bodyFilePath = ""
  result.bodyFileRoot = ""
  result.headers = newFastMap[string]()
  discard result.headers.reserve(16)
  result.query = newFastMap[string]()
  discard result.query.reserve(8)
  for (k, v) in headerMap:
    result.headers[k] = v

proc newMockRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[]
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr, headerMap)
  result = newRequest(native)

proc newMockResponse(): Response =
  new(result)
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = hmGet
  nativeRes.connectionClose = false
  result.native = nativeRes
  result.request = nil
  result.app = nil
  result.viewsDir = "views"
  result.viewExt = ""
  result.requestMethodKind = hmGet
  result.statusCode = 200
  result.headersInited = true
  result.finished = false
  result.compress = false
  result.compressEncoding = ""
  result.headerBuf = newStringOfCap(256)
  result.droppedLateWrites = 0
  result.headers = newFastMap[string]()
  discard result.headers.reserve(16)
  result.locals = newFastMap[string]()
  discard result.locals.reserve(4)

proc startMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
): Future[void] =
  var idx = 0
  proc finalHandler(r: Request, s: Response): Future[void] {.async.} =
    if handler != nil:
      await handler(r, s)
    elif not s.finished:
      s.status(200)
  proc advance(): Future[void] {.async.} =
    if idx < middlewares.len:
      let current = middlewares[idx]
      inc idx
      await current(req, res, advance)
    else:
      await finalHandler(req, res)
  result = advance()

proc runMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
) =
  waitFor startMiddlewareChain(middlewares, req, res, handler)

proc newSecureMockRequest(): Request =
  ## Request whose trusted proxy chain reports an https origin (req.secure() = true).
  result = newMockRequest(headerMap = @[
    ("x-forwarded-proto", "https"),
    ("x-forwarded-for", "198.51.100.10, 127.0.0.1")
  ])
  result.trustProxyEnabled = true
  result.trustedProxyHopCount = 1

proc isHex32(s: string): bool =
  if s.len != 32:
    return false
  for c in s:
    if not (c in {'0'..'9'} or c in {'a'..'f'} or c in {'A'..'F'}):
      return false
  true

suite "helmet unit":
  test "normalizeHelmetOptions enables baseline headers, keeps opt-in headers disabled (ISSUE-7)":
    let opts = normalizeHelmetOptions(HelmetOptions())
    check opts.xContentTypeOptions
    check opts.xFrameOptions
    check opts.referrerPolicy
    check opts.strictTransportSecurity
    check opts.crossOriginOpenerPolicy
    check opts.crossOriginResourcePolicy
    check not opts.xXssProtection
    check not opts.contentSecurityPolicy
    check not opts.permissionsPolicy

  test "normalizeHelmetOptions honors disable overrides and explicit enables":
    let opts = normalizeHelmetOptions(HelmetOptions(
      disableXFrameOptions: true,
      disableStrictTransportSecurity: true,
      xXssProtection: true
    ))
    check not opts.xFrameOptions
    check not opts.strictTransportSecurity
    check opts.xContentTypeOptions
    check opts.referrerPolicy
    check opts.xXssProtection

  test "value defaults only materialized for enabled opt-in headers (ISSUE-9)":
    let disabled = normalizeHelmetOptions(HelmetOptions())
    check disabled.xXssProtectionValue.len == 0
    check disabled.contentSecurityPolicyValue.len == 0
    check disabled.permissionsPolicyValue.len == 0
    check disabled.xFrameOptionsValue == "SAMEORIGIN"
    check disabled.referrerPolicyValue == "strict-origin-when-cross-origin"
    check disabled.strictTransportSecurityValue == "max-age=31536000; includeSubDomains"

    let enabled = normalizeHelmetOptions(HelmetOptions(
      xXssProtection: true,
      contentSecurityPolicy: true,
      permissionsPolicy: true
    ))
    check enabled.xXssProtectionValue == "0"
    check enabled.contentSecurityPolicyValue ==
      "default-src 'self'; base-uri 'self'; frame-ancestors 'self'"
    check enabled.permissionsPolicyValue == "camera=(), microphone=(), geolocation=()"

    let custom = normalizeHelmetOptions(HelmetOptions(
      contentSecurityPolicy: true,
      contentSecurityPolicyValue: "default-src 'none'"
    ))
    check custom.contentSecurityPolicyValue == "default-src 'none'"

  test "nonce local key default and override":
    let opts = normalizeHelmetOptions(HelmetOptions(contentSecurityPolicyNonce: true))
    check opts.contentSecurityPolicyNonceLocalKey == "csp_nonce"
    let custom = normalizeHelmetOptions(HelmetOptions(contentSecurityPolicyNonceLocalKey: "my_nonce"))
    check custom.contentSecurityPolicyNonceLocalKey == "my_nonce"

  test "buildNonce yields a 32-char hex nonce, unique per call":
    let n1 = buildNonce()
    let n2 = buildNonce()
    check n1.len == 32
    check isHex32(n1)
    check isHex32(n2)
    check n1 != n2

  test "applyCspNonce replaces {nonce} placeholder with raw nonce (ISSUE-4)":
    let policy = "script-src 'self' 'nonce-{nonce}'; style-src 'self'"
    check applyCspNonce(policy, policy.toLowerAscii(), "abc123") ==
      "script-src 'self' 'nonce-abc123'; style-src 'self'"
    let multi = "script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'"
    check applyCspNonce(multi, multi.toLowerAscii(), "abc123") ==
      "script-src 'nonce-abc123'; style-src 'nonce-abc123'"

  test "applyCspNonce appends nonce to existing script-src directive":
    let policy = "default-src 'self'; script-src 'self'; img-src 'self'"
    check applyCspNonce(policy, policy.toLowerAscii(), "abc123") ==
      "default-src 'self'; script-src 'self' 'nonce-abc123'; img-src 'self'"
    let upper = "DEFAULT-SRC 'SELF'; SCRIPT-SRC 'SELF'"
    check applyCspNonce(upper, upper.toLowerAscii(), "abc123") ==
      "DEFAULT-SRC 'SELF'; SCRIPT-SRC 'SELF' 'nonce-abc123'"
    let elem = "script-src-elem 'self'"
    check applyCspNonce(elem, elem.toLowerAscii(), "abc123") ==
      "script-src-elem 'self'; script-src 'nonce-abc123'"

  test "applyCspNonce handles script-src at end of string (ISSUE-1)":
    let policy = "default-src 'self'; script-src"
    check applyCspNonce(policy, policy.toLowerAscii(), "abc123") ==
      "default-src 'self'; script-src 'nonce-abc123'"
    let elemEnd = "default-src 'self'; script-src-elem"
    check applyCspNonce(elemEnd, elemEnd.toLowerAscii(), "abc123") ==
      "default-src 'self'; script-src-elem; script-src 'nonce-abc123'"

  test "applyCspNonce empty policy and empty nonce":
    check applyCspNonce("", "", "abc123") == "script-src 'nonce-abc123'"
    check applyCspNonce("default-src 'self'", "default-src 'self'", "") == "default-src 'self'"

suite "helmet integration":
  test "default options set baseline headers over plain HTTP":
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet()], req, res)
    check res.headers.getOrDefault("x-content-type-options", "") == "nosniff"
    check res.headers.getOrDefault("x-frame-options", "") == "SAMEORIGIN"
    check res.headers.getOrDefault("referrer-policy", "") == "strict-origin-when-cross-origin"
    check res.headers.getOrDefault("cross-origin-opener-policy", "") == "same-origin"
    check res.headers.getOrDefault("cross-origin-resource-policy", "") == "same-origin"
    check res.headers.getOrDefault("strict-transport-security", "") == ""
    check res.headers.getOrDefault("x-xss-protection", "") == ""
    check res.headers.getOrDefault("content-security-policy", "") == ""
    check res.headers.getOrDefault("permissions-policy", "") == ""

  test "HSTS only emitted on secure connections":
    let plainReq = newMockRequest()
    let plainRes = newMockResponse()
    runMiddlewareChain(@[helmet()], plainReq, plainRes)
    check plainRes.headers.getOrDefault("strict-transport-security", "") == ""

    let secureReq = newSecureMockRequest()
    let secureRes = newMockResponse()
    runMiddlewareChain(@[helmet()], secureReq, secureRes)
    check secureRes.headers.getOrDefault("strict-transport-security", "") ==
      "max-age=31536000; includeSubDomains"

  test "CSP nonce stored in req.locals and injected into default policy":
    let opts = HelmetOptions(contentSecurityPolicy: true, contentSecurityPolicyNonce: true)
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet(opts)], req, res)
    let nonce = req.locals.getOrDefault("csp_nonce", "")
    check nonce.len == 32
    check isHex32(nonce)
    let csp = res.headers.getOrDefault("content-security-policy", "")
    check csp.len > 0
    check ("'nonce-" & nonce & "'") in csp
    check csp.endsWith("script-src 'nonce-" & nonce & "'")

  test "CSP nonce is unique per request":
    let mw = helmet(HelmetOptions(contentSecurityPolicy: true, contentSecurityPolicyNonce: true))
    let req1 = newMockRequest()
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1)
    let req2 = newMockRequest()
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2)
    let n1 = req1.locals.getOrDefault("csp_nonce", "")
    let n2 = req2.locals.getOrDefault("csp_nonce", "")
    check isHex32(n1)
    check isHex32(n2)
    check n1 != n2

  test "CSP with {nonce} placeholder (ISSUE-4)":
    let opts = HelmetOptions(
      contentSecurityPolicy: true,
      contentSecurityPolicyNonce: true,
      contentSecurityPolicyValue: "script-src 'self' 'nonce-{nonce}'"
    )
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet(opts)], req, res)
    let nonce = req.locals.getOrDefault("csp_nonce", "")
    check isHex32(nonce)
    check res.headers.getOrDefault("content-security-policy", "") ==
      "script-src 'self' 'nonce-" & nonce & "'"

  test "CSP with script-src at end of policy gets nonce appended (ISSUE-1)":
    let opts = HelmetOptions(
      contentSecurityPolicy: true,
      contentSecurityPolicyNonce: true,
      contentSecurityPolicyValue: "default-src 'self'; script-src"
    )
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet(opts)], req, res)
    let nonce = req.locals.getOrDefault("csp_nonce", "")
    check isHex32(nonce)
    check res.headers.getOrDefault("content-security-policy", "") ==
      "default-src 'self'; script-src 'nonce-" & nonce & "'"

  test "all opt-in headers enabled on secure connection":
    let opts = HelmetOptions(
      xXssProtection: true,
      contentSecurityPolicy: true,
      permissionsPolicy: true
    )
    let req = newSecureMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet(opts)], req, res)
    check res.headers.getOrDefault("x-xss-protection", "") == "0"
    check res.headers.getOrDefault("content-security-policy", "") ==
      "default-src 'self'; base-uri 'self'; frame-ancestors 'self'"
    check res.headers.getOrDefault("permissions-policy", "") ==
      "camera=(), microphone=(), geolocation=()"
    check res.headers.getOrDefault("strict-transport-security", "") ==
      "max-age=31536000; includeSubDomains"

  test "disable override removes header; custom values respected":
    let opts = HelmetOptions(
      disableXContentTypeOptions: true,
      xFrameOptionsValue: "DENY",
      referrerPolicyValue: "no-referrer"
    )
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet(opts)], req, res)
    check res.headers.getOrDefault("x-content-type-options", "") == ""
    check res.headers.getOrDefault("x-frame-options", "") == "DENY"
    check res.headers.getOrDefault("referrer-policy", "") == "no-referrer"

  test "custom nonce local key is used":
    let opts = HelmetOptions(
      contentSecurityPolicy: true,
      contentSecurityPolicyNonce: true,
      contentSecurityPolicyNonceLocalKey: "my_csp_nonce"
    )
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet(opts)], req, res)
    check req.locals.getOrDefault("my_csp_nonce", "").len == 32
    check req.locals.getOrDefault("csp_nonce", "") == ""

  test "middleware chain continues to next handler":
    var nextCalled = false
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet()], req, res,
      proc(r: Request, s: Response): Future[void] {.async.} =
        nextCalled = true
        s.status(200)
        s.send("ok"))
    check nextCalled
    check res.statusCode == 200

suite "helmet pre-lowercased names + nonce buffer reuse (audit MWB-002)":
  test "header name key set is exactly the pre-change lowercase set":
    ## The assertions in the "helmet integration" suite were green BEFORE the
    ## pre-lowercasing change while the middleware passed mixed-case literals,
    ## which proves `res.set` stores and emits lowercase names
    ## (`sanitizeHeaderName`, response.nim:414-426). This test pins the full
    ## key set so an accidental case change cannot slip through.
    let opts = HelmetOptions(
      xXssProtection: true, xXssProtectionValue: "0",
      permissionsPolicy: true, permissionsPolicyValue: "geolocation=()",
      crossOriginOpenerPolicy: true, crossOriginOpenerPolicyValue: "same-origin",
      crossOriginResourcePolicy: true, crossOriginResourcePolicyValue: "same-site",
      contentSecurityPolicy: true,
      contentSecurityPolicyValue: "default-src 'self'")
    let req = newMockRequest()
    let res = newMockResponse()
    runMiddlewareChain(@[helmet(opts)], req, res)
    var keys: seq[string] = @[]
    for k in res.headers.keys():
      keys.add(k)
    keys.sort()
    let expected = @[
      "content-security-policy", "cross-origin-opener-policy",
      "cross-origin-resource-policy", "permissions-policy",
      "referrer-policy", "x-content-type-options", "x-frame-options",
      "x-xss-protection"]
    check keys == expected
    check res.headers.getOrDefault("x-content-type-options", "") == "nosniff"
    check res.headers.getOrDefault("x-xss-protection", "") == "0"
    check res.headers.getOrDefault("permissions-policy", "") == "geolocation=()"
    # No mixed-case twin of any header may appear.
    for k in keys:
      check k == k.toLowerAscii()

  test "nonce stays 32-char UPPERCASE hex with no lowercase nibbles":
    ## Regression guard for the known bad candidate: a lowercase nibble table
    ## passed length checks but failed byte parity on every sample.
    var seen: Table[string, int]
    for i in 0 ..< 4000:
      let nonce = buildNonce()
      check nonce.len == 32
      for c in nonce:
        check c in {'0' .. '9', 'A' .. 'F'}
      seen[nonce] = seen.getOrDefault(nonce, 0) + 1
    # 16 random bytes -> collisions are effectively impossible.
    check seen.len >= 3990

  test "nonce is independent per thread call site and reusable across calls":
    ## The scratch buffer is reused; a returned string must never be mutated by
    ## a later call (guards against returning a view of the scratch buffer).
    let a = buildNonce()
    let b = buildNonce()
    check a != b
    check a.len == 32 and b.len == 32
    let aCopy = a
    discard buildNonce()
    discard buildNonce()
    check a == aCopy
