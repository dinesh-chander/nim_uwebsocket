import std/[os, strutils, random, times]
import ../nim_express/src/nim_express
import ../nim_express/src/nim_express/config

var
  totalMessages: int64
  totalConnections: int64
  currentConnections: int

const
  Products = [
    ("Widget Pro", 29.99, "electronics"),
    ("Gizmo X", 149.50, "electronics"),
    ("Comfort Chair", 349.00, "furniture"),
    ("Speed Runner", 89.95, "footwear"),
    ("Smart Lamp", 45.00, "home"),
    ("Desk Organizer", 22.50, "office"),
    ("Power Bank", 39.99, "electronics"),
    ("Yoga Mat", 34.95, "fitness"),
  ]
  Warehouses = ["US-WEST-1", "US-EAST-2", "EU-CENTRAL-1", "AP-SOUTH-1"]

proc buildResponse(requestId: string, action: string): string =
  result = newStringOfCap(384)
  result.add("{\"requestId\":\"")
  result.add(requestId)
  result.add("\",\"status\":\"ok\",\"action\":\"")
  result.add(action)
  result.add("\",\"data\":{")
  
  let pidx = rand(0 ..< Products.len)
  let (name, price, category) = Products[pidx]
  let qty = rand(1 .. 100)
  let warehouse = Warehouses[rand(0 ..< Warehouses.len)]
  let ts = epochTime()
  
  result.add("\"product\":\"")
  result.add(name)
  result.add("\",\"category\":\"")
  result.add(category)
  result.add("\",\"unitPrice\":")
  result.add(formatFloat(price, ffDecimal, 2))
  result.add(",\"quantity\":")
  result.add($qty)
  result.add(",\"totalPrice\":")
  result.add(formatFloat(price * float64(qty), ffDecimal, 2))
  result.add(",\"warehouse\":\"")
  result.add(warehouse)
  result.add("\",\"estimatedDeliveryDays\":")
  result.add($(rand(1 .. 14)))
  result.add(",\"timestamp\":")
  result.add(formatFloat(ts, ffDecimal, 3))
  result.add(",\"tax\":")
  result.add(formatFloat(price * float64(qty) * 0.08, ffDecimal, 2))
  result.add(",\"available\":true}}")

proc extractField(msg: string, field: string): string =
  let key = "\"" & field & "\":\""
  let pos = msg.find(key)
  if pos < 0: return ""
  let start = pos + key.len
  let endPos = msg.find('"', start)
  if endPos < 0: return ""
  msg[start ..< endPos]

proc main() =
  randomize()
  let app = newExpressApp()
  var cfg = loadAppEnvConfig()
  if cfg.port == DefaultEnvPort:
    cfg.port = 3200
  let portEnv = getEnv("PORT", "")
  if portEnv.len > 0:
    try: cfg.port = parseInt(portEnv)
    except ValueError: discard
  app.applyAppEnvConfig(cfg)

  app.get("/stats") do (req: Request, res: Response):
    res.text("connections=" & $currentConnections &
      " totalMessages=" & $totalMessages &
      " totalConnections=" & $totalConnections)

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    inc totalMessages
    let requestId = extractField(message, "requestId")
    let action = extractField(message, "action")
    let response = buildResponse(
      if requestId.len > 0: requestId else: "unknown",
      if action.len > 0: action else: "query"
    )
    ws.send(response, binary = false)

  app.onWsOpen proc(ws: WebSocket) =
    inc currentConnections
    inc totalConnections

  app.onWsClose proc(ws: WebSocket) =
    dec currentConnections

  app.listen(cfg.port) do (ok: bool):
    if ok:
      echo "ws_realistic_server on http://localhost:", cfg.port
      if cfg.profile.len > 0:
        echo "profile: ", cfg.profile
    else:
      echo "failed"
      quit(1)

when isMainModule:
  main()
