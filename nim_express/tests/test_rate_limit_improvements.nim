{.define: nimExpressRateLimitTest.}

import std/[unittest, asyncdispatch, strutils, os]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/rate_limit

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

proc runLimiter(
  mw: AsyncMiddleware, remoteIp: string,
  headers: seq[(string, string)] = @[],
  hopCount: int16 = 0, allowlist: string = ""
): tuple[nextCalled: bool, res: Response] =
  let req = newMockRequest(remoteIpStr = remoteIp, headerMap = headers)
  req.trustedProxyHopCount = hopCount
  req.trustedProxyAllowlist = allowlist
  let res = newMockResponse()
  var nextCalled = false
  proc nextProc(): Future[void] {.async.} =
    nextCalled = true
  waitFor mw(req, res, nextProc)
  result = (nextCalled, res)

proc headerVal(res: Response, name: string): string =
  res.headers.getOrDefault(name, "")

suite "sanitizeRateLimitKey helper":
  test "safe input is returned unchanged":
    check rateLimitSanitizeKeyForTest("192.168.1.1") == "192.168.1.1"
    check rateLimitSanitizeKeyForTest("2001:db8::1") == "2001:db8::1"
    check rateLimitSanitizeKeyForTest("host-1.example_2") == "host-1.example_2"

  test "whitespace stripped and unsafe chars dropped":
    check rateLimitSanitizeKeyForTest("  10.0.0.1  ") == "10.0.0.1"
    check rateLimitSanitizeKeyForTest("1.2.3.4, 5.6.7.8") == "1.2.3.45.6.7.8"
    check rateLimitSanitizeKeyForTest("a!b@c#d") == "abcd"

  test "empty and unsafe-only input yield empty":
    check rateLimitSanitizeKeyForTest("") == ""
    check rateLimitSanitizeKeyForTest("   ") == ""
    check rateLimitSanitizeKeyForTest("!!!") == ""

  test "length capped at 128":
    check rateLimitSanitizeKeyForTest("a".repeat(200)).len == 128
    check rateLimitSanitizeKeyForTest("a".repeat(128)) == "a".repeat(128)
    check rateLimitSanitizeKeyForTest("a".repeat(129)) == "a".repeat(128)

suite "store internals":
  test "cleanupExpired expires keys at exactly resetMs":
    let store = rateLimitNewStoreForTest()
    rateLimitStoreInsert(store, "a", 5, 1000)
    rateLimitStoreInsert(store, "b", 3, 2000)
    rateLimitCleanupExpiredForTest(store, 1000)
    check not rateLimitStoreHasKey(store, "a")
    check rateLimitStoreHasKey(store, "b")
    check rateLimitStoreKeyCount(store) == 1

  test "evictOneExpired never evicts live keys":
    let store = rateLimitNewStoreForTest()
    rateLimitStoreInsert(store, "a", 9, 500)
    rateLimitStoreInsert(store, "b", 1, 2000)
    rateLimitStoreInsert(store, "c", 2, 3000)
    check rateLimitEvictOneExpiredForTest(store, 1000)
    check not rateLimitStoreHasKey(store, "a")
    check rateLimitStoreHasKey(store, "b")
    check rateLimitStoreHasKey(store, "c")
    check rateLimitStoreCount(store, "b") == 1
    check rateLimitStoreCount(store, "c") == 2
    check not rateLimitEvictOneExpiredForTest(store, 1000)
    check rateLimitStoreKeyCount(store) == 2

  test "evictOneExpired rotates its bounded probe window":
    let store = rateLimitNewStoreForTest()
    for i in 0 ..< 300:
      let resetMs = if i == 260: 500'i64 else: 10_000'i64
      rateLimitStoreInsert(store, "k" & $i, 1, resetMs)
    check not rateLimitEvictOneExpiredForTest(store, 1000)
    check rateLimitEvictOneExpiredForTest(store, 1000)
    check not rateLimitStoreHasKey(store, "k260")
    check rateLimitStoreKeyCount(store) == 299

  test "evictOneExpired on empty store is a no-op":
    let store = rateLimitNewStoreForTest()
    check not rateLimitEvictOneExpiredForTest(store, 1000)
    check rateLimitStoreKeyCount(store) == 0

suite "rateLimit middleware":
  test "admits up to maxRequests then 429s with rate limit headers":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 3, windowMs = 60_000)
    resetRateLimitStoreForTest()
    for i in 0 ..< 3:
      let r = runLimiter(mw, "10.9.0.1")
      check r.nextCalled
      check r.res.statusCode == 200
      check headerVal(r.res, "x-ratelimit-limit") == "3"
      check headerVal(r.res, "x-ratelimit-remaining") == $(3 - i - 1)
      check parseInt(headerVal(r.res, "x-ratelimit-reset")) > 0
    let r4 = runLimiter(mw, "10.9.0.1")
    check not r4.nextCalled
    check r4.res.statusCode == 429
    check parseInt(headerVal(r4.res, "retry-after")) >= 1
    check headerVal(r4.res, "x-ratelimit-limit") == "3"
    check headerVal(r4.res, "x-ratelimit-remaining") == "0"
    check parseInt(headerVal(r4.res, "x-ratelimit-reset")) > 0

  test "capacity rejection 429 carries retry-after and rate limit headers":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 1000, windowMs = 60_000, maxTrackedKeys = 3)
    resetRateLimitStoreForTest()
    for i in 0 ..< 3:
      let r = runLimiter(mw, "10.9.1." & $i)
      check r.nextCalled
      check r.res.statusCode == 200
    let r4 = runLimiter(mw, "10.9.1.9")
    check not r4.nextCalled
    check r4.res.statusCode == 429
    check headerVal(r4.res, "retry-after") == "1"
    check headerVal(r4.res, "x-ratelimit-limit") == "1000"
    check headerVal(r4.res, "x-ratelimit-remaining") == "0"
    check parseInt(headerVal(r4.res, "x-ratelimit-reset")) > 0
    check rateLimitTrackedKeyCount() == 3
    check rateLimitKeyCapacityDrops() >= 1

  test "full table evicts an expired key before admitting a new one":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 10, windowMs = 1, maxTrackedKeys = 1)
    resetRateLimitStoreForTest()
    let r1 = runLimiter(mw, "10.9.2.1")
    check r1.nextCalled
    sleep(10)
    refreshCachedTime()
    let r2 = runLimiter(mw, "10.9.2.2")
    check r2.nextCalled
    check r2.res.statusCode == 200
    check rateLimitTrackedKeyCount() == 1
    sleep(10)
    refreshCachedTime()
    let r3 = runLimiter(mw, "10.9.2.1")
    check r3.nextCalled
    check r3.res.statusCode == 200

  test "full table of live keys rejects without resetting live counters":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 2, windowMs = 60_000, maxTrackedKeys = 1,
      rejectNewKeyWhenFull = false)
    resetRateLimitStoreForTest()
    check runLimiter(mw, "10.9.3.1").res.statusCode == 200
    check runLimiter(mw, "10.9.3.1").res.statusCode == 200
    let intruder = runLimiter(mw, "10.9.3.9")
    check not intruder.nextCalled
    check intruder.res.statusCode == 429
    let victim = runLimiter(mw, "10.9.3.1")
    check not victim.nextCalled
    check victim.res.statusCode == 429
    check rateLimitTrackedKeyCount() == 1

  test "window expiry starts a fresh window":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 1, windowMs = 1)
    resetRateLimitStoreForTest()
    check runLimiter(mw, "10.9.4.1").res.statusCode == 200
    check runLimiter(mw, "10.9.4.1").res.statusCode == 429
    sleep(10)
    refreshCachedTime()
    check runLimiter(mw, "10.9.4.1").res.statusCode == 200

  test "huge windowMs is clamped instead of overflowing":
    refreshCachedTime()
    let nowMs = getCachedEpochMs()
    let mw = rateLimit(maxRequests = 10, windowMs = high(int))
    resetRateLimitStoreForTest()
    let r1 = runLimiter(mw, "10.9.5.1")
    check r1.nextCalled
    check headerVal(r1.res, "x-ratelimit-remaining") == "9"
    let expectedReset = (nowMs + 2_592_000_000'i64) div 1000
    check parseInt(headerVal(r1.res, "x-ratelimit-reset")) == expectedReset
    let r2 = runLimiter(mw, "10.9.5.1")
    check r2.nextCalled
    check r2.res.statusCode == 200
    check headerVal(r2.res, "x-ratelimit-remaining") == "8"

  test "allowlisted proxy keys requests on the forwarded client ip":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 1, windowMs = 60_000, trustProxy = true)
    resetRateLimitStoreForTest()
    let h1 = @[( "x-forwarded-for", "198.51.100.7, 10.0.0.1" )]
    let r1 = runLimiter(mw, "10.0.0.1", headers = h1, hopCount = 1, allowlist = "10.0.0.1")
    check r1.nextCalled
    check r1.res.statusCode == 200
    let r2 = runLimiter(mw, "10.0.0.1", headers = h1, hopCount = 1, allowlist = "10.0.0.1")
    check not r2.nextCalled
    check r2.res.statusCode == 429
    let h3 = @[( "x-forwarded-for", "198.51.100.8, 10.0.0.1" )]
    let r3 = runLimiter(mw, "10.0.0.1", headers = h3, hopCount = 1, allowlist = "10.0.0.1")
    check r3.nextCalled
    check r3.res.statusCode == 200
    let r4 = runLimiter(mw, "10.0.0.9", headers = h1, hopCount = 1, allowlist = "10.0.0.1")
    check r4.nextCalled
    check r4.res.statusCode == 200

  test "untrusted peer falls back to the socket address":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 1, windowMs = 60_000, trustProxy = true)
    resetRateLimitStoreForTest()
    let h1 = @[( "x-forwarded-for", "198.51.100.1" )]
    let r1 = runLimiter(mw, "10.0.0.8", headers = h1, hopCount = 1, allowlist = "127.0.0.1")
    check r1.nextCalled
    let h2 = @[( "x-forwarded-for", "203.0.113.9" )]
    let r2 = runLimiter(mw, "10.0.0.8", headers = h2, hopCount = 1, allowlist = "127.0.0.1")
    check not r2.nextCalled
    check r2.res.statusCode == 429

  test "x-real-ip key uses the first token, not the raw header":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 1, windowMs = 60_000, trustProxy = true)
    resetRateLimitStoreForTest()
    let r1 = runLimiter(mw, "127.0.0.1", headers = @[( "x-real-ip", "1.2.3.4, 5.6.7.8" )],
      hopCount = 0, allowlist = "127.0.0.1")
    check r1.nextCalled
    let r2 = runLimiter(mw, "127.0.0.1", headers = @[( "x-real-ip", "1.2.3.4, 9.9.9.9" )],
      hopCount = 0, allowlist = "127.0.0.1")
    check not r2.nextCalled
    check r2.res.statusCode == 429
    check rateLimitTrackedKeyCount() == 1

  test "garbled forwarded value falls back to a single shared bucket":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 1, windowMs = 60_000, trustProxy = true)
    resetRateLimitStoreForTest()
    let r1 = runLimiter(mw, "127.0.0.1", headers = @[
      ( "x-forwarded-for", "!!!" ), ( "x-real-ip", "1.2.3.4, 5.6.7.8" )],
      hopCount = 0, allowlist = "127.0.0.1")
    check r1.nextCalled
    let r2 = runLimiter(mw, "127.0.0.1", headers = @[
      ( "x-forwarded-for", "!!!" ), ( "x-real-ip", "1.2.3.4, 9.9.9.9" )],
      hopCount = 0, allowlist = "127.0.0.1")
    check not r2.nextCalled
    check r2.res.statusCode == 429
    check rateLimitTrackedKeyCount() == 1

  test "nil request or nil native is ignored without crashing":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 1, windowMs = 60_000)
    resetRateLimitStoreForTest()
    let res1 = newMockResponse()
    var next1 = false
    proc nextProc1(): Future[void] {.async.} =
      next1 = true
    var reqNil: Request
    waitFor mw(reqNil, res1, nextProc1)
    check not next1
    check res1.statusCode == 200

    var reqNoNative: Request
    new(reqNoNative)
    let res2 = newMockResponse()
    var next2 = false
    proc nextProc2(): Future[void] {.async.} =
      next2 = true
    waitFor mw(reqNoNative, res2, nextProc2)
    check not next2
    check res2.statusCode == 200

  test "middleware chain stops at the limiter rejection":
    refreshCachedTime()
    let mw = rateLimit(maxRequests = 1, windowMs = 60_000)
    resetRateLimitStoreForTest()
    var handlerCalled = false
    proc okHandler(r: Request, s: Response): Future[void] {.async.} =
      handlerCalled = true
    let req1 = newMockRequest(remoteIpStr = "10.9.6.1")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, okHandler)
    check res1.statusCode == 200
    check handlerCalled
    let req2 = newMockRequest(remoteIpStr = "10.9.6.1")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, okHandler)
    check res2.statusCode == 429

  test "presets produce working limiters":
    refreshCachedTime()
    for preset in [rlpApiDefault, rlpAuthStrict, rlpBurst]:
      let mw = rateLimitPreset(preset, maxTrackedKeys = 4)
      resetRateLimitStoreForTest()
      let r1 = runLimiter(mw, "10.9.7.1")
      check r1.nextCalled
      check r1.res.statusCode == 200
      check headerVal(r1.res, "x-ratelimit-limit").len > 0
