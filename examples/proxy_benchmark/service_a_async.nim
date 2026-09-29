import ../../nim_express/src/nim_express
import std/[httpclient, strutils]

const UpstreamTarget = "http://127.0.0.1:3201"

proc proxyMiddleware(): AsyncMiddleware =
  proc(req: Request, res: types.Response, next: NextProc): Future[void] {.async.} =
    let path = $req.path
    let rawQuery = $req.rawQuery()
    let upstreamUrl =
      if rawQuery.len > 0: UpstreamTarget & path & "?" & rawQuery
      else: UpstreamTarget & path

    let client = newAsyncHttpClient()
    try:
      var upstreamHeaders = newHttpHeaders()
      req.bindHeaders()
      for key, value in req.headers.pairs():
        let lower = key.toLowerAscii()
        if lower == "connection" or lower == "keep-alive" or
           lower == "transfer-encoding" or lower == "upgrade" or
           lower == "host":
          continue
        upstreamHeaders.add(key, value)

      let upstreamResp = await client.request(
        url = upstreamUrl,
        httpMethod = HttpGet,
        headers = upstreamHeaders,
      )

      res.status(parseInt(upstreamResp.status.split(' ')[0]))

      for key, value in upstreamResp.headers.pairs():
        let lower = key.toLowerAscii()
        if lower == "connection" or lower == "keep-alive" or
           lower == "transfer-encoding" or lower == "content-length":
          continue
        res.set(key, value)

      let respBody = await upstreamResp.body
      res.send(respBody)
    except CatchableError:
      if not res.finished:
        res.status(502)
        res.set("Content-Type", "application/json; charset=utf-8")
        res.send("""{"error":"Bad Gateway"}""")
    finally:
      client.close()

let app = newExpressApp()
app.use(compression())
app.use(proxyMiddleware())

echo "Service A (async proxy) starting on port 3200..."
app.listen(3200) do (success: bool):
  if success:
    echo "Service A running on http://127.0.0.1:3200 -> proxying to :3201"
  else:
    echo "Service A failed to start!"
    quit(1)
