## Server-sent events example using chunked streaming.

import std/[json, times]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

proc main*() =
  let app = newExpressApp()
  let viewsDir = resolveViewsDir("sse")
  if viewsDir.len == 0:
    echo "sse views not found"
    quit(1)
  app.setViewsDir(viewsDir)

  app.use(timeout(20_000))

  app.get("/") do (_: Request, res: Response):
    res.render("index")

  app.getAsync("/events") do (req: Request, res: Response) {.async.}:
    var aborted = false
    req.onAbort(proc(reason: RequestCancelReason) =
      aborted = true
      echo "[sse_stream_app] stream aborted: ", $reason
    )

    res.status(200)
    res.set("Cache-Control", "no-cache")
    res.set("Connection", "keep-alive")
    res.set("X-Accel-Buffering", "no")
    if not res.startChunked("text/event-stream; charset=utf-8"):
      return

    discard res.writeChunk("retry: 2000\n\n")
    for i in 0 ..< 10:
      if aborted or req.aborted():
        break
      let payload = %*{
        "seq": i,
        "timestamp": $now(),
        "timeoutRemainingMs": requestTimeoutRemainingMs(req)
      }
      discard res.writeChunk("event: tick\n")
      discard res.writeChunk("data: " & $payload & "\n\n")
      await sleepAsync(1000)
    discard res.endChunked(closeAfterWrite = false)

  let port = parsePort(3000)
  app.listen(port) do (ok: bool):
    if ok:
      echo "sse_stream_app listening on http://localhost:", port
    else:
      echo "failed to start sse_stream_app"
      quit(1)
