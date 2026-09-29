import std/[unittest, asyncdispatch]
import ../src/nim_express/[types, request, response]
import ../src/nim_express/middlewares/concurrency_guard

suite "Concurrency guard middleware":
  proc mkReqRes(): tuple[req: Request, res: Response] =
    var nativeReq: HttpRequest
    new(nativeReq)
    nativeReq.methodKind = hmGet
    nativeReq.remoteIp = "127.0.0.1"

    var nativeRes: HttpResponse
    new(nativeRes)
    nativeRes.requestMethod = hmGet

    (req: newRequest(nativeReq), res: newResponse(nativeRes))

  test "rejects requests above inflight limit":
    let guard = newConcurrencyGuardState(maxInflight = 1)
    let mw = concurrencyGuard(guard, statusCode = 503, retryAfterSeconds = 2, message = "busy")
    let ctx1 = mkReqRes()
    let ctx2 = mkReqRes()
    var next1Called = false
    var next2Called = false
    let gate = newFuture[void]("concurrency-guard-gate")

    proc next1(): Future[void] {.async.} =
      next1Called = true
      await gate

    proc next2(): Future[void] {.async.} =
      next2Called = true

    proc runScenario(): Future[void] {.async.} =
      let f1 = mw(ctx1.req, ctx1.res, next1)
      await sleepAsync(10)
      await mw(ctx2.req, ctx2.res, next2)
      check next2Called == false
      check ctx2.res.statusCode == 503
      check ctx2.res.get("Retry-After") == "2"
      check rejectedCount(guard) == 1
      gate.complete()
      await f1

    waitFor runScenario()
    check next1Called
    check currentInflight(guard) == 0

  test "always decrements inflight on downstream failure":
    let ctx = mkReqRes()
    let guard = newConcurrencyGuardState(maxInflight = 8)
    let mw = concurrencyGuard(guard)

    proc failNext(): Future[void] {.async.} =
      await sleepAsync(1)
      raise newException(ValueError, "boom")

    expect ValueError:
      waitFor mw(ctx.req, ctx.res, failNext)
    check currentInflight(guard) == 0
