import std/[unittest, asyncdispatch, strutils, json, times]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/health

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

proc flagHandler(flag: ptr bool): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    flag[] = true
    if not res.finished:
      res.status(200)
      res.send("ok")

suite "health unit":
  test "resetHealthRequestCount zeroes the counter":
    discard healthRequestCount()
    resetHealthRequestCount()
    check healthRequestCount() == 0'i64

  test "health requests do not increment the counter (ISSUE-1)":
    resetHealthRequestCount()
    let req = newMockRequest("/health")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[health()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check healthRequestCount() == 0'i64

  test "non-health requests increment the counter (ISSUE-1)":
    resetHealthRequestCount()
    for i in 0..<3:
      let req = newMockRequest("/api/data")
      let res = newMockResponse()
      var nextCalled = false
      runMiddlewareChain(@[health()], req, res, flagHandler(addr nextCalled))
      check nextCalled
    check healthRequestCount() == 3'i64

  test "counter counts arrivals even when the handler rejects (ISSUE-1)":
    resetHealthRequestCount()
    let req = newMockRequest("/api/data")
    let res = newMockResponse()
    let handler = proc(req: Request, res: Response): Future[void] {.async.} =
      res.status(403)
      res.send("no")
    runMiddlewareChain(@[health()], req, res, handler)
    check healthRequestCount() == 1'i64
    check res.statusCode == 403

suite "health integration":
  test "default payload is minimal and discloses no operational metrics (ISSUE-6)":
    resetHealthRequestCount()
    let req = newMockRequest("/health")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[health()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.finished
    check res.statusCode == 200
    let node = parseJson(res.native.capturedBody)
    check node.len == 1
    check node["status"].getStr() == "healthy"
    check not node.hasKey("uptime")
    check not node.hasKey("nonHealthRequests")
    check not node.hasKey("timestamp")
    check res.get("cache-control") == "no-cache, no-store"

  test "verbose payload includes uptime, counter and timestamp (ISSUE-6)":
    resetHealthRequestCount()
    let req = newMockRequest("/health")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[health(verbose = true)], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.finished
    check res.statusCode == 200
    let node = parseJson(res.native.capturedBody)
    check node.len == 4
    check node["status"].getStr() == "healthy"
    check node.hasKey("nonHealthRequests")
    check not node.hasKey("requests")
    check node["nonHealthRequests"].getInt == 0
    check node["uptime"].getFloat >= 0.0
    check node.hasKey("timestamp")
    check res.get("cache-control") == "no-cache, no-store"
    check res.native.capturedHeader.find("application/json") >= 0

  test "health path returns 200 JSON with renamed counter field (ISSUE-1)":
    resetHealthRequestCount()
    let req = newMockRequest("/health")
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[health(verbose = true)], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.finished
    check res.statusCode == 200
    let node = parseJson(res.native.capturedBody)
    check node.len == 4
    check node["status"].getStr() == "healthy"
    check node.hasKey("nonHealthRequests")
    check not node.hasKey("requests")
    check node["nonHealthRequests"].getInt == 0
    check node["uptime"].getFloat >= 0.0
    check node.hasKey("timestamp")
    check res.get("cache-control") == "no-cache, no-store"
    check res.native.capturedHeader.find("application/json") >= 0

  test "health payload reflects prior non-health traffic (ISSUE-1)":
    resetHealthRequestCount()
    for i in 0..<2:
      let req = newMockRequest("/x")
      let res = newMockResponse()
      var nextCalled = false
      runMiddlewareChain(@[health()], req, res, flagHandler(addr nextCalled))
      check nextCalled
    let req = newMockRequest("/health")
    let res = newMockResponse()
    runMiddlewareChain(@[health(verbose = true)], req, res)
    let node = parseJson(res.native.capturedBody)
    check node["nonHealthRequests"].getInt == 2

  test "timestamp is a current UTC wall-clock value (ISSUE-3)":
    let req = newMockRequest("/health")
    let res = newMockResponse()
    runMiddlewareChain(@[health(verbose = true)], req, res)
    let ts = parseJson(res.native.capturedBody)["timestamp"].getStr()
    # $Time.utc format: "YYYY-MM-DDTHH:MM:SSZ"
    check ts.len == 20
    check ts[10] == 'T'
    check ts[19] == 'Z'
    let t = toTime(parse(ts, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()))
    check abs(epochTime() - float(t.toUnix)) < 5.0

  test "uptime is non-negative and grows monotonically with the clock (ISSUE-3)":
    let req1 = newMockRequest("/health")
    let res1 = newMockResponse()
    runMiddlewareChain(@[health(verbose = true)], req1, res1)
    let u1 = parseJson(res1.native.capturedBody)["uptime"].getFloat
    check u1 >= 0.0
    let req2 = newMockRequest("/health")
    let res2 = newMockResponse()
    runMiddlewareChain(@[health(verbose = true)], req2, res2)
    let u2 = parseJson(res2.native.capturedBody)["uptime"].getFloat
    check u2 >= u1

  test "custom health path responds; default path passes through (regression)":
    let mw = health("/status")
    let req1 = newMockRequest("/status")
    let res1 = newMockResponse()
    var next1 = false
    runMiddlewareChain(@[mw], req1, res1, flagHandler(addr next1))
    check not next1
    check res1.finished
    check parseJson(res1.native.capturedBody)["status"].getStr() == "healthy"

    var next2 = false
    let req2 = newMockRequest("/health")
    let res2 = newMockResponse()
    runMiddlewareChain(@[mw], req2, res2, flagHandler(addr next2))
    check next2
    check res2.statusCode == 200
    check res2.native.capturedBody == "ok"

  test "non-health path forwards to handler (regression)":
    resetHealthRequestCount()
    var nextCalled = false
    let req = newMockRequest("/api/data")
    let res = newMockResponse()
    runMiddlewareChain(@[health()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check res.native.capturedBody == "ok"
    check healthRequestCount() == 1'i64
