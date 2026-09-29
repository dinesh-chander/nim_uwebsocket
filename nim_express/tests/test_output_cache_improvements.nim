import std/[unittest, asyncdispatch, strutils, tables]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/output_cache

proc newMockHttpRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[],
  queryStr: string = ""
): HttpRequest =
  new(result)
  result.path = pathVal
  result.queryStringRaw = queryStr
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
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[],
  queryStr: string = ""
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr, headerMap, queryStr)
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

proc sendHandler(counter: ptr int, bodyStr: string): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    inc counter[]
    if not res.finished:
      res.status(200)
      res.send(bodyStr)

proc genHandler(counter: ptr int): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    inc counter[]
    if not res.finished:
      res.status(200)
      res.send("gen-" & $counter[])

suite "Output cache improvements":
  test "cache miss runs handler, delivers body, and stores entry":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0
    let req = newMockRequest(pathVal = "/hello")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "hello-body"))
    check calls == 1
    check res.finished
    check res.native.capturedBody == "hello-body"
    check outputCacheEntryCount(store) == 1

  test "cache hit replays cached body and headers without running handler":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0
    let req1 = newMockRequest(pathVal = "/hello")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, proc(r: Request, s: Response): Future[void] {.async.} =
      inc calls
      if not s.finished:
        s.status(200)
        s.set("x-test-header", "cached-value")
        s.send("hello-body")
    )
    check calls == 1
    check outputCacheEntryCount(store) == 1

    let req2 = newMockRequest(pathVal = "/hello")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, sendHandler(addr calls, "SHOULD-NOT-RUN"))
    check calls == 1
    check res2.finished
    check res2.native.capturedBody == "hello-body"
    check res2.native.capturedHeader.toLowerAscii().contains("x-test-header: cached-value")
    check outputCacheEntryCount(store) == 1

  test "expired entry is not served from cache":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0
    let req1 = newMockRequest(pathVal = "/ttl")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, genHandler(addr calls))
    check calls == 1
    check res1.native.capturedBody == "gen-1"
    check outputCacheEntryCount(store) == 1

    for _, entry in store.entries.mpairs():
      entry.expiresAtMs = 0

    let req2 = newMockRequest(pathVal = "/ttl")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, genHandler(addr calls))
    check calls == 2
    check res2.native.capturedBody == "gen-2"

  test "cache key varies by path":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0
    for path in @["/a", "/b", "/a"]:
      let req = newMockRequest(pathVal = path)
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "body"))
    check calls == 2
    check outputCacheEntryCount(store) == 2

  test "non-GET methods bypass cache and keys vary by method":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0

    let getReq1 = newMockRequest(pathVal = "/p")
    let getRes1 = newMockResponse()
    runMiddlewareChain(@[mw], getReq1, getRes1, sendHandler(addr calls, "get-body"))
    check calls == 1
    check outputCacheEntryCount(store) == 1

    let postReq = newMockRequest(pathVal = "/p", methodKind = hmPost)
    let postRes = newMockResponse()
    runMiddlewareChain(@[mw], postReq, postRes, sendHandler(addr calls, "post-body"))
    check calls == 2
    check outputCacheEntryCount(store) == 1

    let headReq = newMockRequest(pathVal = "/p", methodKind = hmHead)
    let headRes = newMockResponse()
    runMiddlewareChain(@[mw], headReq, headRes, sendHandler(addr calls, "head-body"))
    check calls == 3
    check outputCacheEntryCount(store) == 2

    let getReq2 = newMockRequest(pathVal = "/p")
    let getRes2 = newMockResponse()
    runMiddlewareChain(@[mw], getReq2, getRes2, sendHandler(addr calls, "get-body"))
    check calls == 3
    check getRes2.native.capturedBody == "get-body"
    check outputCacheEntryCount(store) == 2

  test "cache key varies by query when varyByQuery is enabled":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0
    for query in @["a=1", "a=2", "a=1"]:
      let req = newMockRequest(pathVal = "/q", queryStr = query)
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "body"))
    check calls == 2
    check outputCacheEntryCount(store) == 2

  test "cache key varies by configured vary header":
    let policy = initOutputCachePolicy(varyByHeaders = @["accept-language"])
    let store = newOutputCacheStore()
    let mw = outputCache(store, policy)
    var calls = 0

    let req1 = newMockRequest(pathVal = "/lang", headerMap = @ [("accept-language", "en")])
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, sendHandler(addr calls, "en-body"))
    check calls == 1
    check outputCacheEntryCount(store) == 1

    let req2 = newMockRequest(pathVal = "/lang", headerMap = @ [("accept-language", "fr")])
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, sendHandler(addr calls, "fr-body"))
    check calls == 2
    check outputCacheEntryCount(store) == 2

    let req3 = newMockRequest(pathVal = "/lang", headerMap = @ [("accept-language", "en")])
    let res3 = newMockResponse()
    runMiddlewareChain(@[mw], req3, res3, sendHandler(addr calls, "SHOULD-NOT-RUN"))
    check calls == 2
    check res3.native.capturedBody == "en-body"

  test "authenticated requests bypass cache by default":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0
    for _ in 0 ..< 2:
      let req = newMockRequest(pathVal = "/secure", headerMap = @ [("authorization", "Bearer token")])
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "secret"))
    check calls == 2
    check outputCacheEntryCount(store) == 0

  test "cookie-bearing requests bypass cache by default":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0
    for _ in 0 ..< 2:
      let req = newMockRequest(pathVal = "/secure", headerMap = @ [("cookie", "sid=abc")])
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "secret"))
    check calls == 2
    check outputCacheEntryCount(store) == 0

  test "request cache-control no-cache bypasses; other directives do not":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0

    for _ in 0 ..< 2:
      let req = newMockRequest(pathVal = "/nc", headerMap = @ [("cache-control", "no-cache")])
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "body"))
    check calls == 2
    check outputCacheEntryCount(store) == 0

    let reqAge = newMockRequest(pathVal = "/ok", headerMap = @ [("cache-control", "max-age=3600")])
    let resAge = newMockResponse()
    runMiddlewareChain(@[mw], reqAge, resAge, sendHandler(addr calls, "body"))
    check calls == 3
    check outputCacheEntryCount(store) == 1

    let reqExt = newMockRequest(pathVal = "/ne", headerMap = @ [("cache-control", "no-cache-extension")])
    let resExt = newMockResponse()
    runMiddlewareChain(@[mw], reqExt, resExt, sendHandler(addr calls, "body"))
    check calls == 4
    check outputCacheEntryCount(store) == 2

  test "tag invalidation removes matching entries only":
    proc pathTags(req: Req): seq[string] {.closure.} =
      @[req.path.toLowerAscii()]
    let policy = initOutputCachePolicy(tagResolver = pathTags)
    let store = newOutputCacheStore()
    let mw = outputCache(store, policy)
    var calls = 0

    for path in @["/posts", "/other"]:
      let req = newMockRequest(pathVal = path)
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "body"))
    check calls == 2
    check outputCacheEntryCount(store) == 2

    check invalidateOutputCacheTag(store, " /POSTS ") == 1
    check outputCacheEntryCount(store) == 1

    let postsReq = newMockRequest(pathVal = "/posts")
    let postsRes = newMockResponse()
    runMiddlewareChain(@[mw], postsReq, postsRes, sendHandler(addr calls, "body"))
    check calls == 3
    check outputCacheEntryCount(store) == 2

    let otherReq = newMockRequest(pathVal = "/other")
    let otherRes = newMockResponse()
    runMiddlewareChain(@[mw], otherReq, otherRes, sendHandler(addr calls, "SHOULD-NOT-RUN"))
    check calls == 3

  test "invalidateOutputCacheTags handles multiple tags with normalization":
    proc fixedTags(req: Req): seq[string] {.closure.} =
      @["Posts", "Home"]
    let policy = initOutputCachePolicy(tagResolver = fixedTags)
    let store = newOutputCacheStore()
    let mw = outputCache(store, policy)
    var calls = 0

    for path in @["/x", "/y"]:
      let req = newMockRequest(pathVal = path)
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "body"))
    check calls == 2
    check outputCacheEntryCount(store) == 2

    check invalidateOutputCacheTags(store, @[" posts ", "nothing"]) == 2
    check outputCacheEntryCount(store) == 0

  test "clearOutputCache empties the store":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0
    for path in @["/c1", "/c2"]:
      let req = newMockRequest(pathVal = path)
      let res = newMockResponse()
      runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "body"))
    check outputCacheEntryCount(store) == 2

    clearOutputCache(store)
    check outputCacheEntryCount(store) == 0

    let req = newMockRequest(pathVal = "/c1")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "body"))
    check calls == 3
    check outputCacheEntryCount(store) == 1

  test "non-cacheable status codes are not stored":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0
    let req = newMockRequest(pathVal = "/err")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, proc(r: Request, s: Response): Future[void] {.async.} =
      inc calls
      if not s.finished:
        s.status(500)
        s.send("err-body")
    )
    check calls == 1
    check res.native.capturedBody == "err-body"
    check outputCacheEntryCount(store) == 0

  test "response no-store and chunked transfer-encoding block caching":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    var calls = 0

    let req1 = newMockRequest(pathVal = "/no-store")
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, proc(r: Request, s: Response): Future[void] {.async.} =
      inc calls
      if not s.finished:
        s.status(200)
        s.set("cache-control", "no-store")
        s.send("body")
    )
    check calls == 1
    check outputCacheEntryCount(store) == 0

    let req2 = newMockRequest(pathVal = "/chunked")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, proc(r: Request, s: Response): Future[void] {.async.} =
      inc calls
      s.native.sendPreparedResponse(
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ncontent-length: 4\r\n\r\n",
        "body")
    )
    check calls == 2
    check res2.native.capturedBody == "body"
    check outputCacheEntryCount(store) == 0

    let req3 = newMockRequest(pathVal = "/chunked-stable")
    let res3 = newMockResponse()
    runMiddlewareChain(@[mw], req3, res3, proc(r: Request, s: Response): Future[void] {.async.} =
      inc calls
      s.native.sendPreparedResponse(
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked-stable\r\ncontent-length: 4\r\n\r\n",
        "body")
    )
    check calls == 3
    check outputCacheEntryCount(store) == 1

  test "bypassAuthSensitive=false varies key by credential headers":
    let policy = initOutputCachePolicy(bypassAuthSensitive = false)
    check "authorization" in policy.varyByHeaders
    check "cookie" in policy.varyByHeaders

    let store = newOutputCacheStore()
    let mw = outputCache(store, policy)
    var calls = 0

    let req1 = newMockRequest(pathVal = "/me", headerMap = @ [("authorization", "Bearer A")])
    let res1 = newMockResponse()
    runMiddlewareChain(@[mw], req1, res1, sendHandler(addr calls, "me-A"))
    check calls == 1
    check outputCacheEntryCount(store) == 1

    let req2 = newMockRequest(pathVal = "/me", headerMap = @ [("authorization", "Bearer B")])
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, sendHandler(addr calls, "me-B"))
    check calls == 2
    check outputCacheEntryCount(store) == 2

    let req3 = newMockRequest(pathVal = "/me", headerMap = @ [("authorization", "Bearer A")])
    let res3 = newMockResponse()
    runMiddlewareChain(@[mw], req3, res3, sendHandler(addr calls, "SHOULD-NOT-RUN"))
    check calls == 2
    check res3.native.capturedBody == "me-A"

  test "tag resolver output is capped and tag bytes count toward storedBytes":
    proc manyTags(req: Req): seq[string] {.closure.} =
      result = @[]
      for i in 0 ..< 30:
        result.add("tag-" & $i)
    let policy = initOutputCachePolicy(tagResolver = manyTags)
    let store = newOutputCacheStore()
    let mw = outputCache(store, policy)
    var calls = 0

    let req = newMockRequest(pathVal = "/big")
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, sendHandler(addr calls, "body"))
    check calls == 1
    check outputCacheEntryCount(store) == 1

    for _, entry in store.entries.pairs():
      check entry.tags.len == 16
      check entry.tags[0] == "tag-0"
      check entry.tags[15] == "tag-15"
      let tagBytes = 10 * 5 + 6 * 6
      check entry.storedBytes == entry.header.len + entry.body.len + tagBytes

  test "handler errors propagate, are not cached, and restore live native":
    let store = newOutputCacheStore()
    let mw = outputCache(store)
    let req = newMockRequest(pathVal = "/boom")
    let res = newMockResponse()
    let liveNative = res.native

    expect CatchableError:
      runMiddlewareChain(@[mw], req, res, proc(r: Request, s: Response): Future[void] {.async.} =
        raise newException(CatchableError, "boom")
      )

    check outputCacheEntryCount(store) == 0
    check res.native == liveNative
