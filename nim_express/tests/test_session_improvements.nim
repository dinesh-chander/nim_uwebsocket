{.define: nimExpressSessionImprovementsTest.}
import std/[unittest, asyncdispatch, strutils, times, os]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/session

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

proc isHex(s: string): bool =
  if s.len == 0:
    return false
  for c in s:
    if not (c in {'0'..'9'} or c in {'a'..'f'} or c in {'A'..'F'}):
      return false
  return true

proc fixedChars(c: char, n: int): string =
  result = newStringOfCap(n)
  for i in 0 ..< n:
    result.add(c)

proc setCookieValue(res: Response, name: string): string =
  for c in res.setCookies:
    if c.startsWith(name & "="):
      let rest = c[name.len + 1 .. ^1]
      let semi = rest.find(';')
      return if semi >= 0: rest[0 ..< semi] else: rest
  ""

proc chainWith(
  opts: SessionOptions, req: Request, res: Response,
  work: proc(r: Request, s: Response) {.closure.} = nil
): bool =
  var ran = false
  proc handler(r: Request, s: Response): Future[void] {.async.} =
    ran = true
    if work != nil:
      work(r, s)
    if not s.finished:
      s.status(200)
      s.send("ok")
  runMiddlewareChain(@[session(opts)], req, res, handler)
  ran

suite "session unit":
  test "buildSessionId yields a 48-char hex id, unique per call":
    let id1 = sessionBuildIdForTest()
    let id2 = sessionBuildIdForTest()
    check id1.len == 48
    check isHex(id1)
    check isHex(id2)
    check id1 != id2

  test "isSafeSessionId enforces length bounds and allowlisted charset":
    check not sessionIsSafeIdForTest(fixedChars('a', 23))
    check sessionIsSafeIdForTest(fixedChars('a', 24))
    check sessionIsSafeIdForTest(fixedChars('a', 128))
    check not sessionIsSafeIdForTest(fixedChars('a', 129))
    check not sessionIsSafeIdForTest(fixedChars('a', 24) & " ")
    check not sessionIsSafeIdForTest(fixedChars('a', 24) & "/")
    check sessionIsSafeIdForTest("a1b2c3d4e5f6g7h8i9j0k1l2m3n4")
    check sessionIsSafeIdForTest("ABC-def_012.345_678_901_234")

  test "isSafeSessionKey enforces non-empty allowlisted charset":
    check not sessionIsSafeKeyForTest("")
    check sessionIsSafeKeyForTest("user")
    check sessionIsSafeKeyForTest("user.name-1_x")
    check not sessionIsSafeKeyForTest("bad key")
    check not sessionIsSafeKeyForTest("bad:key")
    check not sessionIsSafeKeyForTest("bad:key;other=1")

  test "copyStringMap handles nil source and copies by value":
    let empty = sessionCopyStringMapForTest(nil)
    check empty != nil
    check empty.len == 0
    let src = newFastMap[string]()
    src["a"] = "1"
    src["b"] = "2"
    let copy = sessionCopyStringMapForTest(src)
    check copy.len == 2
    check copy.getOrDefault("a", "") == "1"
    check copy.getOrDefault("b", "") == "2"
    copy["a"] = "changed"
    check src.getOrDefault("a", "") == "1"

  test "collectSessionData only collects safe session_ prefixed keys":
    let req = newMockRequest()
    req.locals["session_user"] = "alice"
    req.locals["session_a.b-c_d"] = "v2"
    req.locals["session_bad key"] = "v3"
    req.locals["session_"] = "v4"
    req.locals["_session_id"] = "xyz"
    req.locals["other"] = "v5"
    let data = sessionCollectDataForTest(req)
    check data.len == 2
    check data.getOrDefault("user", "") == "alice"
    check data.getOrDefault("a.b-c_d", "") == "v2"

  test "defaultSessionOptions keeps production-safe defaults and size caps":
    let d = defaultSessionOptions()
    check d.cookieName == "sid"
    check d.ttlSeconds == 86400
    check d.secureCookie
    check d.httpOnlyCookie
    check d.sameSite == "Lax"
    check d.path == "/"
    check d.rolling == false
    check d.saveUninitialized == false
    check d.store.load != nil
    check d.store.save != nil
    check d.store.delete != nil
    check d.maxValueLen == DefaultMaxSessionValueLen
    check d.maxSessionSize == DefaultMaxSessionSize

  test "normalizeSessionOptions fills zero size caps with defaults (ISSUE-2)":
    let n = normalizeSessionOptions(SessionOptions(cookieName: "sess"))
    check n.cookieName == "sess"
    check n.maxValueLen == DefaultMaxSessionValueLen
    check n.maxSessionSize == DefaultMaxSessionSize
    let custom = normalizeSessionOptions(
      SessionOptions(maxValueLen: 123, maxSessionSize: 456))
    check custom.maxValueLen == 123
    check custom.maxSessionSize == 456

  test "inMemorySessionStore returns a stable singleton instance (ISSUE-6)":
    check inMemorySessionStore() == inMemorySessionStore()

  test "in-memory store save/load/delete round-trips data":
    let store = inMemorySessionStore()
    let data = newFastMap[string]()
    data["user"] = "alice"
    store.save("rt-aaaaaaaaaaaaaaaaaaaaaaaaaa", data, 60)
    let loaded = store.load("rt-aaaaaaaaaaaaaaaaaaaaaaaaaa")
    check loaded.found
    check loaded.data.getOrDefault("user", "") == "alice"
    let missing = store.load("rt-missing-missing-missing-xx")
    check not missing.found
    store.delete("rt-aaaaaaaaaaaaaaaaaaaaaaaaaa")
    check not store.load("rt-aaaaaaaaaaaaaaaaaaaaaaaaaa").found

  test "in-memory store expires sessions after their ttl":
    let store = inMemorySessionStore()
    let data = newFastMap[string]()
    data["k"] = "v"
    store.save("exp-aaaaaaaaaaaaaaaaaaaaaaaaaa", data, 1)
    check store.load("exp-aaaaaaaaaaaaaaaaaaaaaaaaaa").found
    sleep(1100)
    check not store.load("exp-aaaaaaaaaaaaaaaaaaaaaaaaaa").found

  test "checkSessionCreationRate: empty ip, exhaustion, window reset":
    check sessionCheckCreationRateForTest("")
    check sessionCheckCreationRateForTest("172.16.50.1", 3, 60)
    check sessionCheckCreationRateForTest("172.16.50.1", 3, 60)
    check sessionCheckCreationRateForTest("172.16.50.1", 3, 60)
    check not sessionCheckCreationRateForTest("172.16.50.1", 3, 60)
    check not sessionCheckCreationRateForTest("172.16.50.1", 3, 60)
    check sessionCheckCreationRateForTest("172.16.50.1", 3, 0)

  test "rate table overflow prunes stale entries before clearing (ISSUE-4)":
    sessionRateSeedForTest("fresh.keep.me", 0)
    for i in 0 ..< 100_001:
      sessionRateSeedForTest("stale." & $i, 120)
    check sessionRateLenForTest() > 100_000
    check sessionCheckCreationRateForTest("fresh.after.overflow")
    check not sessionRateHasForTest("stale.0")
    check not sessionRateHasForTest("stale.100_000")
    check sessionRateHasForTest("fresh.keep.me")
    check sessionRateHasForTest("fresh.after.overflow")
    check sessionRateLenForTest() <= 100_000

  test "sessionSet rejects values over the 4096-byte default cap (ISSUE-2)":
    let req = newMockRequest()
    let okVal = fixedChars('a', 4096)
    sessionSet(req, "k", okVal)
    check sessionGet(req, "k") == okVal
    let tooBig = fixedChars('b', 4097)
    sessionSet(req, "big", tooBig)
    check sessionGet(req, "big") == ""

  test "sessionGet/sessionDelete/destroySession operate on validated locals":
    let req = newMockRequest()
    sessionSet(req, "user", "alice")
    check sessionGet(req, "user") == "alice"
    check sessionGet(req, "user", "fallback") == "alice"
    check sessionGet(req, "missing", "fallback") == "fallback"
    check sessionGet(req, "bad key", "fallback") == "fallback"
    sessionDelete(req, "user")
    check sessionGet(req, "user") == ""
    destroySession(req)
    check req.locals.getOrDefault("_session_destroy", "") == "1"

suite "session integration":
  test "new session saves data and emits a secure cookie":
    var savedId = ""
    var savedData: FastMap[string]
    var opts = defaultSessionOptions()
    opts.store = SessionStore(
      load: proc(id: string): tuple[found: bool, data: SessionData] = (false, nil),
      save: proc(id: string, data: SessionData, ttl: int) =
        savedId = id
        savedData = data,
      delete: proc(id: string) = discard
    )
    let req = newMockRequest(remoteIpStr = "10.0.0.2")
    let res = newMockResponse()
    let ran = chainWith(opts, req, res, proc(r: Request, s: Response) =
      sessionSet(r, "user", "alice")
    )
    check ran
    check res.statusCode == 200
    check savedId.len == 48
    check isHex(savedId)
    check savedData.getOrDefault("user", "") == "alice"
    let cookie = setCookieValue(res, "sid")
    check cookie == savedId
    let raw = res.get("set-cookie")
    check raw.find("; Max-Age=86400") >= 0
    check raw.find("; Path=/") >= 0
    check raw.find("; Secure") >= 0
    check raw.find("; HttpOnly") >= 0
    check raw.find("; SameSite=Lax") >= 0

  test "session data round-trips through the in-memory store across requests":
    let req1 = newMockRequest(remoteIpStr = "10.0.0.3")
    let res1 = newMockResponse()
    let ran1 = chainWith(defaultSessionOptions(), req1, res1,
      proc(r: Request, s: Response) = sessionSet(r, "user", "alice"))
    check ran1
    let id = setCookieValue(res1, "sid")
    check id.len == 48

    var loadedUser = ""
    let req2 = newMockRequest(remoteIpStr = "10.0.0.4",
      headerMap = @[("cookie", "sid=" & id)])
    let res2 = newMockResponse()
    let ran2 = chainWith(defaultSessionOptions(), req2, res2,
      proc(r: Request, s: Response) = loadedUser = sessionGet(r, "user"))
    check ran2
    check loadedUser == "alice"
    check req2.locals.getOrDefault("_session_id", "") == id

  test "unknown valid session id is rotated (fixation protection)":
    let oldId = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    let req = newMockRequest(remoteIpStr = "10.0.0.5",
      headerMap = @[("cookie", "sid=" & oldId)])
    let res = newMockResponse()
    var newId = ""
    let ran = chainWith(defaultSessionOptions(), req, res,
      proc(r: Request, s: Response) =
        sessionSet(r, "user", "carol")
        newId = r.locals.getOrDefault("_session_id", ""))
    check ran
    check newId.len == 48
    check newId != oldId
    check isHex(newId)
    check setCookieValue(res, "sid") == newId

  test "saveUninitialized issues the cookie before any data is set":
    var opts = defaultSessionOptions()
    opts.saveUninitialized = true
    var saved = false
    var savedEmpty = false
    opts.store = SessionStore(
      load: proc(id: string): tuple[found: bool, data: SessionData] = (false, nil),
      save: proc(id: string, data: SessionData, ttl: int) =
        saved = true
        savedEmpty = data.len == 0,
      delete: proc(id: string) = discard
    )
    let req = newMockRequest(remoteIpStr = "10.0.0.6")
    let res = newMockResponse()
    let ran = chainWith(opts, req, res)
    check ran
    check saved
    check savedEmpty
    let cookie = setCookieValue(res, "sid")
    check cookie.len == 48

  test "rolling re-issues the cookie for an existing session":
    let req1 = newMockRequest(remoteIpStr = "10.0.0.7")
    let res1 = newMockResponse()
    discard chainWith(defaultSessionOptions(), req1, res1,
      proc(r: Request, s: Response) = sessionSet(r, "user", "bob"))
    let id = setCookieValue(res1, "sid")
    check id.len == 48

    var opts = defaultSessionOptions()
    opts.rolling = true
    let req2 = newMockRequest(remoteIpStr = "10.0.0.8",
      headerMap = @[("cookie", "sid=" & id)])
    let res2 = newMockResponse()
    let ran2 = chainWith(opts, req2, res2)
    check ran2
    check setCookieValue(res2, "sid") == id

  test "destroySession deletes from the store and clears the cookie":
    let oldId = "d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6"
    var deletedId = ""
    var opts = defaultSessionOptions()
    opts.store = SessionStore(
      load: proc(id: string): tuple[found: bool, data: SessionData] =
        if id != oldId:
          return (false, nil)
        let data = newFastMap[string]()
        data["user"] = "bob"
        (true, data),
      save: proc(id: string, data: SessionData, ttl: int) = discard,
      delete: proc(id: string) = deletedId = id
    )
    let req = newMockRequest(remoteIpStr = "10.0.0.9",
      headerMap = @[("cookie", "sid=" & oldId)])
    let res = newMockResponse()
    let ran = chainWith(opts, req, res, proc(r: Request, s: Response) =
      destroySession(r))
    check ran
    check deletedId == oldId
    check setCookieValue(res, "sid") == ""
    check res.get("set-cookie").find("Max-Age=-1") >= 0

  test "session creation is rate limited per client ip (429)":
    var statuses: seq[int] = @[]
    var lastRan = false
    for i in 0 ..< 11:
      let req = newMockRequest(remoteIpStr = "192.168.77.1")
      let res = newMockResponse()
      lastRan = chainWith(defaultSessionOptions(), req, res)
      statuses.add(res.statusCode)
    for i in 0 ..< 10:
      check statuses[i] == 200
    check statuses[10] == 429
    check not lastRan

  test "session is saved when the handler raises (ISSUE-3)":
    var savedId = ""
    var savedData: FastMap[string]
    var opts = defaultSessionOptions()
    opts.store = SessionStore(
      load: proc(id: string): tuple[found: bool, data: SessionData] = (false, nil),
      save: proc(id: string, data: SessionData, ttl: int) =
        savedId = id
        savedData = data,
      delete: proc(id: string) = discard
    )
    let req = newMockRequest(remoteIpStr = "10.0.0.10")
    let res = newMockResponse()
    var raised = false
    try:
      discard chainWith(opts, req, res, proc(r: Request, s: Response) =
        sessionSet(r, "user", "alice")
        raise newException(ValueError, "boom"))
    except CatchableError:
      raised = true
    check raised
    check savedId.len == 48
    check savedData.getOrDefault("user", "") == "alice"

  test "maxValueLen rejects oversized sessionSet values (ISSUE-2)":
    var opts = defaultSessionOptions()
    opts.maxValueLen = 16
    var got = ""
    let req = newMockRequest(remoteIpStr = "10.0.0.11")
    let res = newMockResponse()
    discard chainWith(opts, req, res, proc(r: Request, s: Response) =
      sessionSet(r, "k", fixedChars('x', 32))
      got = sessionGet(r, "k"))
    check got == ""
    let okReq = newMockRequest(remoteIpStr = "10.0.0.12")
    let okRes = newMockResponse()
    var gotOk = ""
    discard chainWith(opts, okReq, okRes, proc(r: Request, s: Response) =
      sessionSet(r, "k", fixedChars('y', 16))
      gotOk = sessionGet(r, "k"))
    check gotOk == fixedChars('y', 16)

  test "maxValueLen skips oversized store values on load (ISSUE-2)":
    var opts = defaultSessionOptions()
    opts.maxValueLen = 16
    opts.store = SessionStore(
      load: proc(id: string): tuple[found: bool, data: SessionData] =
        let data = newFastMap[string]()
        data["big"] = fixedChars('x', 32)
        data["ok"] = "fine"
        (true, data),
      save: proc(id: string, data: SessionData, ttl: int) = discard,
      delete: proc(id: string) = discard
    )
    let oldId = "e5d4c3b2a1f0e5d4c3b2a1f0e5d4c3b2"
    let req = newMockRequest(remoteIpStr = "10.0.0.13",
      headerMap = @[("cookie", "sid=" & oldId)])
    let res = newMockResponse()
    var bigVal = "sentinel"
    var okVal = "sentinel"
    discard chainWith(opts, req, res, proc(r: Request, s: Response) =
      bigVal = sessionGet(r, "big")
      okVal = sessionGet(r, "ok"))
    check bigVal == ""
    check okVal == "fine"

  test "maxSessionSize rejects values that exceed the per-session budget (ISSUE-2)":
    var opts = defaultSessionOptions()
    opts.maxSessionSize = 60
    var valA = ""
    var valB = ""
    let req = newMockRequest(remoteIpStr = "10.0.0.14")
    let res = newMockResponse()
    discard chainWith(opts, req, res, proc(r: Request, s: Response) =
      sessionSet(r, "a", fixedChars('a', 30))
      sessionSet(r, "b", fixedChars('b', 30))
      valA = sessionGet(r, "a")
      valB = sessionGet(r, "b"))
    check valA == fixedChars('a', 30)
    check valB == ""

  test "allowInsecureCookie omits the Secure attribute":
    var opts = defaultSessionOptions()
    opts.secureCookie = false
    opts.allowInsecureCookie = true
    let req = newMockRequest(remoteIpStr = "10.0.0.15")
    let res = newMockResponse()
    discard chainWith(opts, req, res, proc(r: Request, s: Response) =
      sessionSet(r, "u", "v"))
    let raw = res.get("set-cookie")
    check raw.find("sid=") >= 0
    check raw.find("; Secure") < 0
    check raw.find("; HttpOnly") >= 0

  test "regenerateSessionId rotates the id and re-issues the cookie":
    var opts = defaultSessionOptions()
    let req = newMockRequest(remoteIpStr = "10.0.0.16")
    let res = newMockResponse()
    var oldId = ""
    var newId = ""
    var regenOk = false
    discard chainWith(opts, req, res, proc(r: Request, s: Response) =
      oldId = r.locals.getOrDefault("_session_id", "")
      regenOk = regenerateSessionId(r, s, opts)
      newId = r.locals.getOrDefault("_session_id", ""))
    check regenOk
    check oldId.len == 48
    check newId.len == 48
    check newId != oldId
    check setCookieValue(res, "sid") == newId
