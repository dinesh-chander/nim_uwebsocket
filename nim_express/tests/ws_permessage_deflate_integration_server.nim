import std/[os, strutils]
import ../src/nim_express

proc envIntOr(key: string, defaultValue: int): int =
  let raw = getEnv(key, "")
  if raw.len == 0:
    return defaultValue
  try:
    parseInt(raw)
  except ValueError:
    defaultValue

proc appendLog(line: string) =
  let path = getEnv("NIM_EXPRESS_WS_LOG", "")
  if path.len == 0:
    return
  try:
    writeFile(path, (if fileExists(path): readFile(path) else: "") & line & "\n")
  except CatchableError:
    discard

proc main() =
  let port = envIntOr("NIM_EXPRESS_WS_PORT", 9321)
  let app = newExpressApp()

  app.setWsCompressionEnabled(true)
  app.setWsCompressionThreshold(1)
  app.setWsCompressionMinSavings(0)

  app.get("/", proc(req: Request, res: Response) =
    res.text("nim_express ws deflate fixture")
  )

  app.onWsOpen(proc(ws: WebSocket) =
    appendLog("open")
  )

  app.onWsClose(proc(ws: WebSocket) =
    appendLog("close")
  )

  app.ws(proc(ws: WebSocket, message: string, isBinary: bool) =
    appendLog("message:" & $message.len & ":" & message)
    ws.send(message, binary = isBinary)
    appendLog("sent:" & $message.len)
  )

  app.run("127.0.0.1", port)

when isMainModule:
  main()
