import std/[unittest, asyncdispatch, strutils, os]

import ../src/nim_express/[app, types, response, request, offload]
import ../src/nim_express/middlewares/[timeout, body_parser, rate_limit]

proc toFastMap(entries: openArray[(string, string)]): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(max(8, entries.len * 2))
  for (k, v) in entries:
    discard result.put(k, v)

proc blockingSlow(): int =
  sleep(100)
  1

suite "exp stability iter 31-40":
  test "timeout middleware applies deadline to downstream async handler":
    let webApp = newExpressApp()
    webApp.use(timeout(10))
    webApp.getAsync("/slow", proc(req: Request, res: Response): Future[void] {.async.} =
      await sleepAsync(50)
      res.send("late")
    )

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.path = "/slow"
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req
    res.app = webApp

    waitFor webApp.handleRequestForTest(req, res)
    check req.requestCancelled()
    check req.cancelReason == rcrTimeout
    check req.locals.getOrDefault("_timed_out", "") == "1"
    check res.statusCode == 504

  test "timeout middleware applies deadline to downstream middleware work":
    let webApp = newExpressApp()
    webApp.use(timeout(10))
    webApp.use(proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
      await sleepAsync(50)
      await next()
    )
    webApp.get("/slow-mw", proc(req: Request, res: Response) =
      res.status(200).send("ok")
    )

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.path = "/slow-mw"
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req
    res.app = webApp

    waitFor webApp.handleRequestForTest(req, res)
    check req.requestCancelled()
    check req.cancelReason == rcrTimeout
    check res.statusCode == 504

  test "jsonify drops late writes for cancelled request":
    type TinyPayload = object
      ok: bool

    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    let req = newRequest(reqNative)
    discard req.notifyRequestTimeout()

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmGet
    let res = newResponse(resNative)
    res.request = req

    res.jsonify(TinyPayload(ok: true))
    check res.finished == false
    check res.droppedLateWritesCount() == 1

  test "disconnect notification marks active async request as cancelled":
    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmGet
    reqNative.remoteIp = "127.0.0.9"
    let req = newRequest(reqNative)

    registerActiveAsyncRequestForTest(req)
    notifyAsyncDisconnectByRemoteIpForTest("127.0.0.9")
    unregisterActiveAsyncRequestForTest(req)

    check req.requestCancelled()
    check req.cancelReason == rcrDisconnect

  test "urlencoded parser counts malformed segments toward cap":
    let parser = bodyParser()
    var reqNative: HttpRequest
    new(reqNative)
    reqNative.methodKind = hmPost
    reqNative.headers = toFastMap([("content-type", "application/x-www-form-urlencoded")])
    reqNative.body = repeat("a&", 300)
    let req = newRequest(reqNative)

    var resNative: HttpResponse
    new(resNative)
    resNative.requestMethod = hmPost
    let res = newResponse(resNative)

    var nextCalled = false
    proc nextProc(): Future[void] {.async.} =
      nextCalled = true
    waitFor parser(req, res, nextProc)
    check nextCalled == false
    check res.statusCode == 413

  test "rate limit state is isolated per middleware instance":
    let limiterA = rateLimit(maxRequests = 1, windowMs = 60_000)
    let limiterB = rateLimit(maxRequests = 1, windowMs = 60_000)

    proc runLimiter(limiter: AsyncMiddleware): tuple[nextCalled: bool, statusCode: int] =
      var reqNative: HttpRequest
      new(reqNative)
      reqNative.methodKind = hmGet
      reqNative.remoteIp = "198.51.100.77"
      let req = newRequest(reqNative)

      var resNative: HttpResponse
      new(resNative)
      resNative.requestMethod = hmGet
      let res = newResponse(resNative)

      var nextCalled = false
      proc nextProc(): Future[void] {.async.} =
        nextCalled = true
      waitFor limiter(req, res, nextProc)
      (nextCalled: nextCalled, statusCode: res.statusCode)

    check runLimiter(limiterA) == (nextCalled: true, statusCode: 200)
    check runLimiter(limiterB) == (nextCalled: true, statusCode: 200)
    check runLimiter(limiterA) == (nextCalled: false, statusCode: 429)
    check runLimiter(limiterB) == (nextCalled: false, statusCode: 429)

  test "offload default timeout budget is non-zero and timeout message includes budget":
    check DefaultOffloadTimeoutMs > 0
    let timed = waitFor runOffloadOutcome("slow", "req-offload", 5, blockingSlow())
    check timed.kind == ookOffloadTimeout
    check timed.errorClass == "offload_timeout"
    check timed.errorMessage.contains("after 5ms")
