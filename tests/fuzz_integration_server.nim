import std/[os, strutils]
import ../nim_usockets/src/nim_usockets/http

var opts = defaultServerOptions()
opts.connectionTimeout = 2
opts.headerReadTimeoutMs = 1000
opts.bodyReadTimeoutMs = 1000
opts.writeDrainTimeoutMs = 1000

let server = newHttpServer(options = opts)

server.handle proc(req: HttpRequest, res: HttpResponse) =
  let path = req.path
  if path == "/health":
    res.setStatus(Http200)
    res.setHeader("Content-Type", "text/plain")
    res.`end`("ok")
  elif path == "/echo":
    res.setStatus(Http200)
    res.setHeader("Content-Type", "application/octet-stream")
    res.`end`(req.body)
  elif path == "/shutdown":
    res.setStatus(Http200)
    res.`end`("bye")
    server.shutdown()
  else:
    res.setStatus(Http404)
    res.`end`("not found")

server.onWebSocket proc(ws: WebSocket, message: string, isBinary: bool) =
  discard

let port = if paramCount() > 0: parseInt(paramStr(1)) else: 19876

server.listen("127.0.0.1", port) do (success: bool):
  if success:
    echo "READY:" & $port
  else:
    echo "FAIL"
    quit(1)
server.run()
