import std/[os, strutils, times]
import ../nim_express/src/nim_express
import ../nim_express/src/nim_express/config

var
  totalConnections: int
  totalDisconnections: int
  peakConnections: int
  currentConnections: int

proc main() =
  let app = newExpressApp()
  var cfg = loadAppEnvConfig()
  if cfg.port == DefaultEnvPort:
    cfg.port = 3100
  cfg.maxConnections = 120000
  app.applyAppEnvConfig(cfg)

  app.get("/stats") do (req: Request, res: Response):
    res.text("current=" & $currentConnections &
      " peak=" & $peakConnections &
      " totalOpen=" & $totalConnections &
      " totalClose=" & $totalDisconnections)

  app.onWsOpen proc(ws: WebSocket) =
    inc totalConnections
    inc currentConnections
    if currentConnections > peakConnections:
      peakConnections = currentConnections
    if totalConnections mod 5000 == 0:
      echo "open: ", currentConnections, " peak: ", peakConnections, " total: ", totalConnections

  app.onWsClose proc(ws: WebSocket) =
    inc totalDisconnections
    dec currentConnections

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    discard

  app.listen(cfg.port) do (ok: bool):
    if ok:
      echo "ws_conntest_server on http://localhost:", cfg.port
      echo "maxConnections: ", cfg.maxConnections
    else:
      echo "failed"
      quit(1)

when isMainModule:
  main()
