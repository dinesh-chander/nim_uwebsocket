## Performance-oriented example.

import std/[strutils, times]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

proc queryInt(req: Request, key: string, defaultValue: int): int =
  try:
    parseInt(req.queryParam(key, $defaultValue))
  except ValueError:
    defaultValue

proc attachAbortLogging(req: Request) =
  req.onAbort(proc(reason: RequestCancelReason) =
    echo "[performance_app] request aborted: ", $reason
  )

proc main*() =
  let app = newExpressApp()
  app.use(timeout(10_000))
  app.use(requestId())
  app.use(compression())

  app.getAsync("/health") do (_: Request, res: Response) {.async.}:
    res.jsonRaw("""{"status":"ok"}""")

  app.getAsync("/fast-json") do (_: Request, res: Response) {.async.}:
    var b = initJsonBuilder(160)
    b.add("{")
    b.addKey("message")
    b.addEscaped("fast path")
    b.add(",")
    b.addKey("epoch")
    b.addInt(epochTime().int64)
    b.add(",")
    b.addKey("optimized")
    b.addBool(true)
    b.add("}")
    res.jsonRaw(b.finish())

  app.getAsync("/jsony") do (_: Request, res: Response) {.async.}:
    res.json(%*{
      "service": "performance_app",
      "nowUnix": int64(epochTime()),
      "mode": "typed_json_parse_demo"
    })

  app.getAsync("/async-window") do (req: Request, res: Response) {.async.}:
    attachAbortLogging(req)
    let steps = max(1, min(200, queryInt(req, "steps", 12)))

    for _ in 0 ..< steps:
      if req.aborted():
        return
      await sleepAsync(25)

    if req.aborted():
      return

    res.json(%*{
      "ok": true,
      "steps": steps,
      "timeoutRemainingMs": requestTimeoutRemainingMs(req),
      "cancelled": req.aborted()
    })

  app.getAsync("/metrics") do (_: Request, res: Response) {.async.}:
    res.contentType("application/json; charset=utf-8")
    if res.app != nil:
      res.send(res.app.optimizationMetricsJson())
    else:
      res.send("""{"error":"app unavailable"}""")

  let port = parsePort(3000)
  app.listen(port) do (ok: bool):
    if ok:
      echo "performance_app listening on http://localhost:", port
    else:
      echo "failed to start performance_app"
      quit(1)
