## Simple browser chat demo with direct and broadcast websocket messages.

import std/[atomics, json, strutils]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

const
  ChatTopic = "chat-demo"

var
  clientCounter: Atomic[uint64]
  activeClients = newFastMap[WebSocket]()

proc nextClientId(): uint64 =
  clientCounter.fetchAdd(1'u64, moRelaxed) + 1'u64

proc parseMessagePayload(message: string): tuple[scope: string, author: string, text: string, target: string] =
  let trimmed = message.strip()
  if trimmed.len == 0:
    return ("", "", "", "")
  try:
    let node = parseJson(trimmed)
    result.scope = node{"scope"}.getStr("").strip().toLowerAscii()
    result.author = node{"author"}.getStr("guest").strip()
    result.text = node{"text"}.getStr("").strip()
    result.target = node{"target"}.getStr("").strip()
  except CatchableError:
    result = ("", "", "", "")
  if result.author.len == 0:
    result.author = "guest"

proc chatEvent(kind, scope, author, text: string; delivered = 0; target = ""): string =
  var node = %*{
    "kind": kind,
    "scope": scope,
    "author": author,
    "text": text
  }
  if delivered > 0:
    node["delivered"] = %delivered
  if target.len > 0:
    node["target"] = %target
  $node

proc main*() =
  let app = newExpressApp()
  let viewsDir = resolveViewsDir("chat_webapp")
  if viewsDir.len == 0:
    echo "chat_webapp views not found"
    quit(1)

  app.setViewsDir(viewsDir)
  # Keep chat delivery stable across browser clients.
  # The current live compressed-message path is not reliable for this example.
  app.server.setWsCompressionEnabled(false)
  app.setWsMaxBackpressure(1 * 1024 * 1024)
  app.setWsIdleTimeout(120)

  app.get("/") do (_: Request, res: Response):
    res.render("index")

  app.get("/health") do (_: Request, res: Response):
    res.json(%*{
      "status": "ok",
      "websockets": app.server.getWebSocketCount()
    })

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    if isBinary:
      ws.sendText(chatEvent("error", "direct", "system", "binary frames are not supported"))
      return

    let payload = parseMessagePayload(message)
    if payload.text.len == 0:
      ws.sendText(chatEvent("error", "direct", "system", "message text is required"))
      return

    case payload.scope
    of "broadcast":
      let wire = chatEvent("message", "broadcast", payload.author, payload.text)
      let delivered = app.publish(ChatTopic, wire)
      ws.sendText(chatEvent("ack", "broadcast", "system", "broadcast delivered", delivered))
    of "direct":
      if payload.target.len == 0:
        ws.sendText(chatEvent("error", "direct", "system", "target client id is required"))
        return
      let peer = activeClients.getOrDefault(payload.target, nil)
      if peer == nil or not peer.isOpen:
        ws.sendText(chatEvent("error", "direct", "system", "target client is not connected", target = payload.target))
        return
      peer.sendText(chatEvent("message", "direct", payload.author, payload.text, target = payload.target))
      if peer != ws:
        ws.sendText(chatEvent("ack", "direct", "system", "direct message delivered", target = payload.target))
    else:
      ws.sendText(chatEvent("error", "direct", "system", "scope must be direct or broadcast"))

  app.onWsOpen proc(ws: WebSocket) =
    let clientId = nextClientId()
    discard activeClients.put($clientId, ws)
    discard ws.subscribe(ChatTopic)
    ws.sendText($(%*{
      "kind": "welcome",
      "scope": "direct",
      "clientId": clientId,
      "text": "Connected. Use direct with a target client id, or broadcast to send to everyone."
    }))

  app.onWsClose proc(ws: WebSocket) =
    var staleId = ""
    for clientId, clientWs in activeClients:
      if clientWs == ws:
        staleId = clientId
        break
    if staleId.len > 0:
      discard activeClients.del(staleId)

  let port = parsePort(3000)
  app.listen(port) do (ok: bool):
    if ok:
      echo "chat_webapp listening on http://localhost:", port
      echo "WebSocket endpoint: ws://localhost:", port, "/ws"
    else:
      echo "failed to start chat_webapp"
      quit(1)
