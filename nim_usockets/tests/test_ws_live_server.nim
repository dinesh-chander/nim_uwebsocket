import std/[os, strutils]
import ../src/nim_usockets/http

proc envIntOr(key: string, defaultValue: int): int =
  let raw = getEnv(key, "")
  if raw.len == 0:
    return defaultValue
  try:
    parseInt(raw)
  except ValueError:
    defaultValue

proc main() =
  let server = newHttpServer()
  let port = envIntOr("HTTP_WS_PORT", 9001)

  server.handle proc(req: HttpRequest, res: HttpResponse) =
    res.setStatus(Http200)
    res.setHeader("content-type", "text/plain")
    res.`end`("websocket echo server")

  server.onWebSocket proc(ws: WebSocket, message: string, isBinary: bool) =
    ws.send(message, binary = isBinary)

  server.onWebSocketOpen proc(ws: WebSocket) =
    discard

  server.onWebSocketClose proc(ws: WebSocket) =
    discard

  echo "WS live echo server starting on port ", port, "..."
  server.listen("0.0.0.0", port) do(success: bool):
    if success:
      echo "WS echo server listening on port ", port
    else:
      echo "FATAL: Failed to bind port ", port
      quit(1)

  server.run()

when isMainModule:
  main()
