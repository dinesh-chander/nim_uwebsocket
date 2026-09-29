import std/[unittest, asyncdispatch, strutils]

import ../src/nim_express/[types, request, response]
import ../src/nim_express/middlewares/[session, csrf, cors, helmet]

proc toFastMap(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    discard result.put(k, v)

proc newReq(
  methodKind: HttpMethod = hmGet,
  path: string = "/",
  headers: openArray[(string, string)] = []
): Request =
  var native: HttpRequest
  new(native)
  native.methodKind = methodKind
  native.path = path
  native.headers = toFastMap(headers)
  newRequest(native)

proc newRes(methodKind: HttpMethod = hmGet): Response =
  var native: HttpResponse
  new(native)
  native.requestMethod = methodKind
  newResponse(native)

suite "Security and pending API extensions":
  test "typed upload accessor reads multipart locals":
    let req = newReq()
    req.locals["file_avatar_name"] = "avatar.png"
    req.locals["file_avatar_size"] = "42"
    req.locals["file_avatar_path"] = "/tmp/avatar.png"
    let uploaded = req.uploadFile("avatar")
    check uploaded.found
    check uploaded.name == "avatar.png"
    check uploaded.size == 42
    check uploaded.path == "/tmp/avatar.png"
    check req.hasUploadFile("avatar")

  test "response links helper builds RFC 8288 header":
    let res = newRes()
    discard res.links([
      ("next", "/todos?page=2"),
      ("prev", "/todos?page=1")
    ])
    let linkHeader = res.get("link")
    check linkHeader.contains("rel=\"next\"")
    check linkHeader.contains("rel=\"prev\"")

  test "response format helper selects accept-compatible handler":
    let req = newReq(headers = [("accept", "application/json")])
    let res = newRes()
    var called = ""
    let handlers: seq[(string, proc() {.closure.})] = @[
      ("text/html", (proc() {.closure.} = called = "html")),
      ("application/json", (proc() {.closure.} = called = "json"))
    ]
    let selected = res.format(req, handlers)
    check selected
    check called == "json"

  test "response format helper respects q-values and q=0":
    let req = newReq(headers = [("accept", "application/json;q=0, text/html;q=1")])
    let res = newRes()
    var called = ""
    let handlers: seq[(string, proc() {.closure.})] = @[
      ("application/json", (proc() {.closure.} = called = "json")),
      ("text/html", (proc() {.closure.} = called = "html"))
    ]
    check res.format(req, handlers)
    check called == "html"

  test "session and csrf defaults are production-safe":
    let sessionOpts = defaultSessionOptions()
    let csrfOpts = defaultCsrfOptions()
    check sessionOpts.secureCookie
    check csrfOpts.secureCookie
    check not csrfOpts.allowQueryToken

  test "session and csrf partial options retain fail-safe cookie defaults":
    let sessionOpts = normalizeSessionOptions(SessionOptions(cookieName: "custom_sid"))
    check sessionOpts.cookieName == "custom_sid"
    check sessionOpts.ttlSeconds > 0
    check sessionOpts.path == "/"
    check sessionOpts.secureCookie
    check sessionOpts.httpOnlyCookie
    check sessionOpts.store.load != nil

    let csrfOpts = normalizeCsrfOptions(CsrfOptions(cookieName: "custom_csrf"))
    check csrfOpts.cookieName == "custom_csrf"
    check csrfOpts.headerName == "x-csrf-token"
    check csrfOpts.ignoreMethods == {hmGet, hmHead, hmOptions}
    check csrfOpts.rejectStatus == 403
    check csrfOpts.secureCookie
    check csrfOpts.httpOnlyCookie

  test "session and csrf insecure cookie mode requires explicit opt-out":
    let sessionOpts = normalizeSessionOptions(SessionOptions(
      secureCookie: false,
      httpOnlyCookie: false,
      allowInsecureCookie: true,
      allowClientReadableCookie: true
    ))
    check not sessionOpts.secureCookie
    check not sessionOpts.httpOnlyCookie

    let csrfOpts = normalizeCsrfOptions(CsrfOptions(
      secureCookie: false,
      httpOnlyCookie: false,
      allowInsecureCookie: true,
      allowClientReadableCookie: true
    ))
    check not csrfOpts.secureCookie
    check not csrfOpts.httpOnlyCookie

  test "helmet partial options keep baseline security headers":
    let opts = normalizeHelmetOptions(HelmetOptions(contentSecurityPolicy: true))
    check opts.xContentTypeOptions
    check opts.xFrameOptions
    check opts.referrerPolicy
    check opts.strictTransportSecurity
    check opts.crossOriginOpenerPolicy
    check opts.crossOriginResourcePolicy
    check opts.contentSecurityPolicy
    check opts.contentSecurityPolicyValue.len > 0

  test "helmet baseline header opt-out is explicit":
    let opts = normalizeHelmetOptions(HelmetOptions(
      disableXFrameOptions: true,
      disableStrictTransportSecurity: true
    ))
    check not opts.xFrameOptions
    check not opts.strictTransportSecurity
    check opts.xContentTypeOptions
    check opts.referrerPolicy

  test "credentialed wildcard cors denies non-allowlisted origins":
    let mw = cors(CorsOptions(
      origin: "*",
      credentials: true,
      allowedOrigins: @["https://allowed.example"]
    ))
    let req = newReq(
      methodKind = hmOptions,
      headers = [("origin", "https://blocked.example")]
    )
    let res = newRes(hmOptions)
    var nextCalled = false
    waitFor mw(
      req,
      res,
      proc(): Future[void] {.async.} =
        nextCalled = true
    )
    check not nextCalled
    check res.statusCode == 403
    check res.get("vary") == "Origin"

  test "credentialed reflect cors requires an explicit allowlist":
    let mw = cors(CorsOptions(
      origin: "reflect",
      credentials: true
    ))
    let req = newReq(
      methodKind = hmOptions,
      headers = [("origin", "https://blocked.example")]
    )
    let res = newRes(hmOptions)
    var nextCalled = false
    waitFor mw(
      req,
      res,
      proc(): Future[void] {.async.} =
        nextCalled = true
    )
    check not nextCalled
    check res.statusCode == 403
    check res.get("access-control-allow-origin") == ""
    check res.get("access-control-allow-credentials") == ""

    let allowedMw = cors(CorsOptions(
      origin: "reflect",
      credentials: true,
      allowedOrigins: @["https://allowed.example"]
    ))
    let allowedReq = newReq(
      methodKind = hmOptions,
      headers = [("origin", "https://allowed.example")]
    )
    let allowedRes = newRes(hmOptions)
    var allowedNextCalled = false
    waitFor allowedMw(
      allowedReq,
      allowedRes,
      proc(): Future[void] {.async.} =
        allowedNextCalled = true
    )
    check not allowedNextCalled
    check allowedRes.statusCode == 204
    check allowedRes.get("access-control-allow-origin") == "https://allowed.example"
    check allowedRes.get("access-control-allow-credentials") == "true"
