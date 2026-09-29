## Developer-experience example focused on timeout and cancellation checks.

import std/[strutils, times]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

proc queryInt(req: Request, key: string, defaultValue: int): int =
  try:
    parseInt(req.queryParam(key, $defaultValue))
  except ValueError:
    defaultValue

proc blockingWork(iterations: int): int {.gcsafe.} =
  var acc = 0
  for i in 0 ..< iterations:
    acc = (acc + ((i * 31) xor (i shr 2))) and 0x7fffffff
  acc

proc main*() =
  let app = newExpressApp()
  app.use(timeout(3_000))
  app.use(requestId())

  app.getAsync("/") do (_: Request, res: Response) {.async.}:
    res.json(%*{
      "name": "cancellation_timeout_app",
      "routes": [
        "GET /work?steps=120",
        "GET /offload?iterations=12000000"
      ]
    })

  app.getAsync("/work") do (req: Request, res: Response) {.async.}:
    req.onAbort(proc(reason: RequestCancelReason) =
      echo "[cancellation_timeout_app] /work aborted: ", $reason
    )
    let steps = max(1, min(2_000, queryInt(req, "steps", 120)))
    for _ in 0 ..< steps:
      if req.aborted():
        return
      await sleepAsync(20)
    if req.aborted():
      return
    res.json(%*{
      "ok": true,
      "steps": steps,
      "cancelled": req.aborted(),
      "timeoutRemainingMs": requestTimeoutRemainingMs(req)
    })

  app.getAsync("/offload") do (req: Request, res: Response) {.async.}:
    req.onAbort(proc(reason: RequestCancelReason) =
      echo "[cancellation_timeout_app] /offload aborted: ", $reason
    )
    let iterations = max(100_000, min(80_000_000, queryInt(req, "iterations", 12_000_000)))
    let started = epochTime()

    # Cancellation is best-effort here: we can drop the response if aborted,
    # but the offloaded CPU task itself is not token-cancellable today.
    let checksum = await runOffload(blockingWork(iterations))
    if req.aborted():
      return

    res.json(%*{
      "ok": true,
      "iterations": iterations,
      "checksum": checksum,
      "elapsedMs": int((epochTime() - started) * 1000.0),
      "timeoutRemainingMs": requestTimeoutRemainingMs(req)
    })

  let port = parsePort(3000)
  app.listen(port) do (ok: bool):
    if ok:
      echo "cancellation_timeout_app listening on http://localhost:", port
    else:
      echo "failed to start cancellation_timeout_app"
      quit(1)
