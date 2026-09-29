import std/[json, asyncdispatch]
import ../nim_express/src/nim_express
import ../nim_fasthttpclient/src/nim_fasthttpclient/client as fastclient
import ../nim_fasthttpclient/src/nim_fasthttpclient/types as fasttypes

var downstreamClient = fastclient.newHttpClient()

let app = newExpressApp()

app.get("/health") do (req: Request, res: Response):
  res.json(%*{"status": "ok"})

app.getAsync("/api/aggregated") do (req: Request, res: Response) {.async.}:
  let capturedRes = res
  let fut = newFuture[void]("aggregated")
  fastclient.get(downstreamClient, "http://httpbin.org/get",
    proc(resp: fasttypes.HttpResponse, err: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        if err.len > 0:
          capturedRes.status(502).json(%*{"error": err})
        else:
          capturedRes.json(%*{"downstream_status": resp.statusCode, "downstream_body_len": resp.body.len})
        fut.complete()
  )
  await fut

app.getAsync("/api/post-downstream") do (req: Request, res: Response) {.async.}:
  let capturedRes = res
  let fut = newFuture[void]("post-downstream")
  fastclient.post(downstreamClient, "http://httpbin.org/post", """{"hello":"world"}""",
    proc(resp: fasttypes.HttpResponse, err: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        if err.len > 0:
          capturedRes.status(502).json(%*{"error": err})
        else:
          capturedRes.json(%*{"downstream_status": resp.statusCode, "downstream_body_len": resp.body.len})
        fut.complete()
  )
  await fut

app.listen(3000) do (success: bool):
  if success:
    fastclient.initClientWithLoop(downstreamClient, app.getEventLoop())
    echo "Server running on port 3000"
    echo "Try: curl http://localhost:3000/api/aggregated"
    echo "Try: curl http://localhost:3000/api/post-downstream"
  else:
    echo "Failed to start server"
    quit(1)
