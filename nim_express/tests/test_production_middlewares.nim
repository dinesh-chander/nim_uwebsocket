import std/[asyncdispatch, os, random, strutils, unittest]

import ../src/nim_express/[types, request, response, paged_buffer]
import ../src/nim_express/middlewares/[
  body_parser, method_override, etag, helmet, session, csrf, multipart,
  server_timing, response_time
]

proc toFastMap(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    result[k] = v

proc newReq(
  methodKind: HttpMethod = hmGet,
  path: string = "/",
  headers: openArray[(string, string)] = [],
  body: string = "",
  queryStringRaw: string = ""
): Request =
  var nativeReq: HttpRequest
  new(nativeReq)
  nativeReq.methodKind = methodKind
  nativeReq.path = path
  nativeReq.headers = toFastMap(headers)
  nativeReq.body = body
  nativeReq.queryStringRaw = queryStringRaw
  result = newRequest(nativeReq)

proc newRes(methodKind: HttpMethod = hmGet): Response =
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = methodKind
  result = newResponse(nativeRes)
  result.locals = newFastMap[string]()
  discard result.locals.reserve(8)

proc makeNext(flag: ptr bool): NextProc =
  proc (): Future[void] {.async.} =
    flag[] = true

proc cookiePair(setCookie: string): string =
  let idx = setCookie.find(';')
  if idx < 0:
    return setCookie
  setCookie[0 ..< idx]

suite "Production middleware surface":
  test "json/urlencoded/text/raw parsers enforce constraints":
    block:
      let mw = json()
      let req = newReq(
        hmPost,
        "/",
        [("content-type", "application/json")],
        """{"ok":true}"""
      )
      let res = newRes(hmPost)
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check nextCalled
      check req.local("_json_valid", "") == "1"

    block:
      let mw = json()
      let req = newReq(
        hmPatch,
        "/",
        [("content-type", "application/merge-patch+json; charset=utf-8")],
        """{"patched":true}"""
      )
      let res = newRes(hmPatch)
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check nextCalled
      check req.local("_json_valid", "") == "1"
      check req.getJsonBody()["patched"].getBool()

    block:
      let mw = json()
      let req = newReq(
        hmPost,
        "/",
        [("content-type", "application/json")],
        """{"ok":"""
      )
      let res = newRes(hmPost)
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check not nextCalled
      check res.statusCode == 400

    block:
      let mw = urlencoded()
      let req = newReq(
        hmPost,
        "/",
        [("content-type", "application/x-www-form-urlencoded")],
        "name=nim&lang=nim%2Bexpress"
      )
      let res = newRes(hmPost)
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check nextCalled
      check req.form("name") == "nim"
      check req.form("lang") == "nim+express"

    block:
      let mw = urlencoded()
      let req = newReq(
        hmPost,
        "/",
        [("content-type", "application/x-www-form-urlencoded")],
        "name=nim%ZZ"
      )
      let res = newRes(hmPost)
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check not nextCalled
      check res.statusCode == 400

    block:
      let txt = text()
      let req = newReq(hmPost, "/", [("content-type", "text/plain; charset=utf-8")], "hello")
      let res = newRes(hmPost)
      var nextCalled = false
      waitFor txt(req, res, makeNext(addr nextCalled))
      check nextCalled
      check req.bodyText() == "hello"

    block:
      let rawMw = raw(defaultRawParserOptions())
      let req = newReq(hmPost, "/", [("content-type", "application/octet-stream")], "ABC")
      let res = newRes(hmPost)
      var nextCalled = false
      waitFor rawMw(req, res, makeNext(addr nextCalled))
      check nextCalled
      check req.bodyRaw() == "ABC"

  test "body parsers reject oversized spilled bodies before materialization":
    let spillPath = getTempDir() / ("nim_express_json_spill_" & $getCurrentProcessId() & ".body")
    writeFile(spillPath, repeat("x", 4096))
    try:
      var opts = defaultJsonParserOptions()
      opts.limitBytes = 64
      let mw = json(opts)
      let req = newReq(hmPost, "/", [("content-type", "application/json")])
      req.native.bodyInFile = true
      req.native.bodyFilePath = spillPath
      req.native.bodyFileRoot = getTempDir()
      let res = newRes(hmPost)
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check not nextCalled
      check res.statusCode == 413
      check req.body.len == 0
    finally:
      if fileExists(spillPath):
        removeFile(spillPath)

  test "method override resolves safely before route matching":
    let req = newReq(
      hmPost,
      "/todos/1",
      [("x-http-method-override", "PATCH")]
    )
    let opts = defaultMethodOverrideOptions()
    let resolved = resolveOverrideMethod(req, opts)
    check resolved.rawToken == "PATCH"
    check applyMethodOverride(req, opts)
    check req.methodKind == hmPatch
    check req.native.methodKind == hmPatch

  test "etag middleware sets validators and handles If-None-Match":
    let tag = generateETag("payload")
    check ifNoneMatchMatches(tag, tag)
    check weakEqual("W/\"abc\"", "\"abc\"")

    let req = newReq(
      hmGet,
      "/",
      [("if-none-match", tag)]
    )
    let res = newRes(hmGet)
    res.request = req
    let mw = etag()
    waitFor mw(req, res, proc(): Future[void] {.async.} =
      res.send("payload")
    )
    check res.statusCode == 304
    check res.get("etag").len > 0

  test "page buffer send preserves etag and server timing finalizers":
    block:
      let req = newReq(hmGet, "/pb")
      let res = newRes(hmGet)
      res.request = req
      let timing = serverTiming(productionMode = false)
      let validator = etag()
      waitFor timing(req, res, proc(): Future[void] {.async.} =
        await validator(req, res, proc(): Future[void] {.async.} =
          var buf = initPageBuffer(32)
          buf.add("payload")
          check res.sendPageBuffer(buf, "text/plain; charset=utf-8")
        )
      )
      check res.get("etag").len > 0
      check res.native.capturedRaw.contains("server-timing:")
      check res.native.capturedBody == "payload"

    block:
      let tag = generateETag("payload")
      let req = newReq(hmGet, "/pb", [("if-none-match", tag)])
      let res = newRes(hmGet)
      res.request = req
      let validator = etag()
      waitFor validator(req, res, proc(): Future[void] {.async.} =
        var buf = initPageBuffer(32)
        buf.add("payload")
        check res.sendPageBuffer(buf, "text/plain; charset=utf-8")
      )
      check res.statusCode == 304
      check res.native.capturedBody.len == 0

  test "responseTime header is emitted when downstream sends":
    let mw = responseTime()
    let req = newReq(hmGet, "/timed")
    let res = newRes()

    waitFor mw(req, res, proc(): Future[void] {.async.} =
      res.send("ok")
    )

    let header = res.native.capturedHeader.toLowerAscii()
    check res.finished
    check header.contains("x-response-time:")

  test "responseTime header is emitted through optimized text path":
    let mw = responseTime()
    let req = newReq(hmGet, "/timed-text")
    let res = newRes()

    waitFor mw(req, res, proc(): Future[void] {.async.} =
      res.text("ok")
    )

    let header = res.native.capturedHeader.toLowerAscii()
    check res.finished
    check header.contains("x-response-time:")

  test "helmet supports nonce-based CSP profile":
    var options = defaultHelmetOptions()
    options.contentSecurityPolicy = true
    options.contentSecurityPolicyNonce = true
    options.contentSecurityPolicyValue = "default-src 'self'; script-src 'nonce-{nonce}'"
    let mw = helmet(options)
    let req = newReq()
    let res = newRes()
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))
    check nextCalled
    check req.local("csp_nonce", "").len > 0
    check res.get("content-security-policy").contains("nonce-")

  test "session middleware persists with in-memory store":
    var opts = defaultSessionOptions()
    opts.saveUninitialized = true
    let mw = session(opts)

    let req1 = newReq(hmGet, "/")
    let res1 = newRes()
    waitFor mw(req1, res1, proc(): Future[void] {.async.} =
      sessionSet(req1, "user", "42")
    )
    check req1.local(SessionIdLocal, "").len > 0
    check res1.setCookies.len > 0

    let sidCookie = cookiePair(res1.setCookies[0])
    let req2 = newReq(hmGet, "/", [("cookie", sidCookie)])
    let res2 = newRes()
    var nextCalled = false
    waitFor mw(req2, res2, makeNext(addr nextCalled))
    check nextCalled
    check sessionGet(req2, "user", "") == "42"

  test "session middleware emits cookie when route mutates session then sends":
    let mw = session()
    let req = newReq(hmPost, "/login")
    let res = newRes(hmPost)

    waitFor mw(req, res, proc(): Future[void] {.async.} =
      sessionSet(req, "user", "alice")
      res.send("ok")
    )

    check res.finished
    check res.setCookies.len > 0
    check res.native.capturedHeader.toLowerAscii().contains("set-cookie:")
    check res.native.capturedHeader.toLowerAscii().contains("sid=")

  test "session middleware emits cookie through optimized text path":
    let mw = session()
    let req = newReq(hmPost, "/login-text")
    let res = newRes(hmPost)

    waitFor mw(req, res, proc(): Future[void] {.async.} =
      sessionSet(req, "user", "alice")
      res.text("ok")
    )

    check res.finished
    check res.setCookies.len > 0
    check res.native.capturedHeader.toLowerAscii().contains("set-cookie:")
    check res.native.capturedHeader.toLowerAscii().contains("sid=")

  test "session middleware avoids phantom cookie for untouched public GET":
    let mw = session()
    let req = newReq(hmGet, "/public")
    let res = newRes()
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))
    check nextCalled
    check req.local(SessionIdLocal, "").len > 0
    check res.setCookies.len == 0

  test "session middleware skips rolling cookie after cancellation":
    var opts = defaultSessionOptions()
    opts.rolling = true
    opts.store = SessionStore(
      load: proc(sessionId: string): tuple[found: bool, data: SessionData] =
        var data = newFastMap[string]()
        discard data.reserve(4)
        result = (found: true, data: data),
      save: nil,
      delete: nil
    )
    let mw = session(opts)
    let req = newReq(hmGet, "/", [("cookie", opts.cookieName & "=abcdefghijklmnopqrstuvwxyz123456")])
    let res = newRes()
    var nextCalled = false
    waitFor mw(req, res, proc(): Future[void] {.async.} =
      nextCalled = true
      discard req.notifyRequestTimeout()
    )
    check nextCalled
    check res.setCookies.len == 0

  test "session middleware skips rolling cookie after native headers sent":
    var opts = defaultSessionOptions()
    opts.rolling = true
    opts.store = SessionStore(
      load: proc(sessionId: string): tuple[found: bool, data: SessionData] =
        var data = newFastMap[string]()
        discard data.reserve(4)
        result = (found: true, data: data),
      save: nil,
      delete: nil
    )
    let mw = session(opts)
    let req = newReq(hmGet, "/", [("cookie", opts.cookieName & "=abcdefghijklmnopqrstuvwxyz123456")])
    let res = newRes()
    var nextCalled = false
    waitFor mw(req, res, proc(): Future[void] {.async.} =
      nextCalled = true
      res.native.headersSent = true
    )
    check nextCalled
    check res.setCookies.len == 0

  test "session destroy clears domain-scoped cookie":
    var deletedId = ""
    var opts = defaultSessionOptions()
    opts.domain = ".example.com"
    opts.store = SessionStore(
      load: proc(sessionId: string): tuple[found: bool, data: SessionData] =
        var data = newFastMap[string]()
        discard data.reserve(4)
        result = (found: true, data: data),
      save: nil,
      delete: proc(sessionId: string) =
        deletedId = sessionId
    )
    let mw = session(opts)
    let sid = "abcdefghijklmnopqrstuvwxyz123456"
    let req = newReq(hmPost, "/logout", [("cookie", opts.cookieName & "=" & sid)])
    let res = newRes(hmPost)
    waitFor mw(req, res, proc(): Future[void] {.async.} =
      destroySession(req)
    )
    check deletedId == sid
    check res.setCookies.len == 1
    check res.setCookies[0].contains("Max-Age=-1")
    check res.setCookies[0].contains("Domain=.example.com")

  test "csrf middleware validates token for unsafe methods":
    var opts = defaultCsrfOptions()
    let mw = csrf(opts)

    let getReq = newReq(hmGet, "/")
    let getRes = newRes()
    var getNext = false
    waitFor mw(getReq, getRes, makeNext(addr getNext))
    check getNext
    check getReq.local(opts.tokenLocalKey, "").len > 0
    check getRes.setCookies.len > 0

    let cookie = cookiePair(getRes.setCookies[0])
    let token = getReq.local(opts.tokenLocalKey, "")
    let postReq = newReq(
      hmPost,
      "/",
      [("cookie", cookie), (opts.headerName, token)]
    )
    let postRes = newRes(hmPost)
    var postNext = false
    waitFor mw(postReq, postRes, makeNext(addr postNext))
    check postNext

  test "multipart parser extracts fields and files":
    let boundary = "----nimboundary"
    let body = "--" & boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"title\"\r\n\r\n" &
      "hello\r\n" &
      "--" & boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\n" &
      "Content-Type: text/plain\r\n\r\n" &
      "abc\r\n" &
      "--" & boundary & "--\r\n"
    let req = newReq(
      hmPost,
      "/upload",
      [("content-type", "multipart/form-data; boundary=" & boundary)],
      body
    )
    let res = newRes(hmPost)
    var opts = defaultMultipartOptions()
    opts.uploadDir = getTempDir()
    let mw = multipart(opts)
    var nextCalled = false
    waitFor mw(req, res, makeNext(addr nextCalled))
    check nextCalled
    check req.form("title") == "hello"
    check req.local("file_upload_path", "").len > 0

  test "multipart parser handles file-backed boundary lines without splitting payload markers":
    let boundary = "----nimfilebacked"
    let embedded = "alpha --" & boundary & " is payload data"
    let body = "--" & boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"title\"\r\n\r\n" &
      embedded & "\r\n" &
      "--" & boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"upload\"; filename=\"b.txt\"\r\n" &
      "Content-Type: text/plain\r\n\r\n" &
      "file-bytes\r\n" &
      "--" & boundary & "--\r\n"
    let spillPath = getTempDir() / ("nim_express_multipart_spill_" & $getCurrentProcessId() & ".body")
    writeFile(spillPath, body)

    let req = newReq(
      hmPost,
      "/upload",
      [
        ("content-type", "multipart/form-data; boundary=" & boundary),
        ("content-length", $body.len)
      ]
    )
    req.native.bodyInFile = true
    req.native.bodyFilePath = spillPath
    req.native.bodyFileRoot = getTempDir()
    let res = newRes(hmPost)
    let mw = multipart(defaultMultipartOptions())
    var nextCalled = false
    try:
      waitFor mw(req, res, makeNext(addr nextCalled))
      let uploaded = req.uploadFile("upload")
      check nextCalled
      check req.form("title") == embedded
      check uploaded.found
      check uploaded.name == "b.txt"
      check uploaded.data == "file-bytes"
    finally:
      if fileExists(spillPath):
        removeFile(spillPath)

  test "multipart parser rejects oversized spilled body before materialization":
    let boundary = "----nimspilllimit"
    let body = "--" & boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"field\"\r\n\r\n" &
      repeat("x", 4096) & "\r\n" &
      "--" & boundary & "--\r\n"
    let spillPath = getTempDir() / ("nim_express_multipart_limit_" & $getCurrentProcessId() & ".body")
    writeFile(spillPath, body)
    try:
      let req = newReq(
        hmPost,
        "/upload",
        [("content-type", "multipart/form-data; boundary=" & boundary)]
      )
      req.native.bodyInFile = true
      req.native.bodyFilePath = spillPath
      req.native.bodyFileRoot = getTempDir()
      let res = newRes(hmPost)
      var opts = defaultMultipartOptions()
      opts.maxBodyBytes = 64
      let mw = multipart(opts)
      var nextCalled = false
      waitFor mw(req, res, makeNext(addr nextCalled))
      check not nextCalled
      check res.statusCode == 413
      check req.body.len == 0
    finally:
      if fileExists(spillPath):
        removeFile(spillPath)

  test "multipart parser creates fresh upload directory before disk write":
    let boundary = "----nimfreshdir"
    let body = "--" & boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"upload\"; filename=\"fresh.txt\"\r\n" &
      "Content-Type: text/plain\r\n\r\n" &
      "fresh-bytes\r\n" &
      "--" & boundary & "--\r\n"
    let freshDir = getTempDir() / ("nim_express_multipart_fresh_" & $getCurrentProcessId())
    if dirExists(freshDir):
      removeDir(freshDir)

    var opts = defaultMultipartOptions()
    opts.uploadDir = freshDir
    let mw = multipart(opts)
    let req = newReq(
      hmPost,
      "/upload",
      [("content-type", "multipart/form-data; boundary=" & boundary)],
      body
    )
    let res = newRes(hmPost)
    var nextCalled = false
    try:
      waitFor mw(req, res, makeNext(addr nextCalled))
      let uploaded = req.uploadFile("upload")
      check nextCalled
      check dirExists(freshDir)
      check uploaded.found
      check uploaded.path.len > 0
      check fileExists(uploaded.path)
      check readFile(uploaded.path) == "fresh-bytes"
    finally:
      if dirExists(freshDir):
        removeDir(freshDir)

  test "parser fuzz smoke keeps deterministic 4xx or pass-through":
    randomize(1337)
    let jsonMw = json(defaultJsonParserOptions())
    let formMw = urlencoded(defaultUrlEncodedParserOptions())
    for _ in 0 ..< 128:
      let n = rand(0 .. 256)
      var payload = newStringOfCap(n)
      for _ in 0 ..< n:
        payload.add(char(rand(32 .. 126)))

      block:
        let req = newReq(hmPost, "/", [("content-type", "application/json")], payload)
        let res = newRes(hmPost)
        var nextCalled = false
        waitFor jsonMw(req, res, makeNext(addr nextCalled))
        check nextCalled or res.statusCode == 400 or res.statusCode == 413

      block:
        let req = newReq(
          hmPost,
          "/",
          [("content-type", "application/x-www-form-urlencoded")],
          payload
        )
        let res = newRes(hmPost)
        var nextCalled = false
        waitFor formMw(req, res, makeNext(addr nextCalled))
        check nextCalled or res.statusCode == 400 or res.statusCode == 413
