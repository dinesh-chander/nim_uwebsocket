## Compression showcase (zstd/br/gzip negotiation).

import std/[json, strutils]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

proc buildLargeText(lines: int): string =
  result = newStringOfCap(lines * 96)
  for i in 0 ..< lines:
    result.add("row=" & $i & " nim_express compression sample payload repeated repeated repeated\n")

proc main*() =
  let app = newExpressApp()
  app.use(compression())
  app.use(timeout(15_000))
  installCompressionPolicy(
    app,
    CompressionPolicyOptions(
      enabled: true,
      minBytes: 256,
      minSavingsRatio: 0.01,
      level: 5,
      backpressureThresholdBytes: 0,
      offloadThresholdBytes: 2048
    )
  )

  app.getAsync("/") do (_: Request, res: Response) {.async.}:
    res.json(%*{
      "name": "compression_showcase_app",
      "hint": "Set Accept-Encoding to zstd, br, or gzip",
      "routes": [
        "GET /payload/text",
        "GET /payload/json",
        "GET /encoding",
        "GET /payload/slow"
      ]
    })

  app.getAsync("/encoding") do (req: Request, res: Response) {.async.}:
    res.json(%*{
      "acceptEncoding": req.get("accept-encoding"),
      "selectedEncoding": res.compressEncoding
    })

  app.getAsync("/payload/text") do (_: Request, res: Response) {.async.}:
    res.contentType("text/plain; charset=utf-8")
    res.send(buildLargeText(1800))

  app.getAsync("/payload/json") do (_: Request, res: Response) {.async.}:
    var items: seq[JsonNode] = @[]
    items.setLen(400)
    for i in 0 ..< items.len:
      items[i] = %*{
        "id": i,
        "kind": "compression-demo",
        "message": "payload payload payload payload payload"
      }
    res.json(%*{"items": items})

  app.getAsync("/payload/slow") do (req: Request, res: Response) {.async.}:
    req.onAbort(proc(reason: RequestCancelReason) =
      echo "[compression_showcase_app] slow payload aborted: ", $reason
    )
    for _ in 0 ..< 40:
      if req.aborted():
        return
      await sleepAsync(20)
    if req.aborted():
      return
    res.contentType("text/plain; charset=utf-8")
    res.send(buildLargeText(800))

  let port = parsePort(3000)
  app.listen(port) do (ok: bool):
    if ok:
      echo "compression_showcase_app listening on http://localhost:", port
    else:
      echo "failed to start compression_showcase_app"
      quit(1)
