import std/[os, strutils]
import ../nim_express/src/nim_express
import ../nim_express/src/nim_express/config

proc main() =
  let app = newExpressApp()
  var cfg = loadAppEnvConfig()
  if cfg.port == DefaultEnvPort:
    cfg.port = 3100
  let portEnv = getEnv("PORT", "")
  if portEnv.len > 0:
    try: cfg.port = parseInt(portEnv)
    except ValueError: discard
  app.applyAppEnvConfig(cfg)

  app.get("/") do (req: Request, res: Response):
    res.text("ok")

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    ws.send(message, binary = isBinary)

  app.listen(cfg.port) do (ok: bool):
    if ok:
      echo "ws_echo_server listening on http://localhost:", cfg.port
      if cfg.profile.len > 0:
        echo "profile: ", cfg.profile
    else:
      echo "failed to listen on port ", cfg.port
      quit(1)

when isMainModule:
  main()
