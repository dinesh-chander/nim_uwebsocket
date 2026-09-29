## WebSocket example with compression and pub/sub.

import std/[json, strutils]
import ../../../nim_express/src/nim_express
import ../../shared/example_support

type
  PublishBody = object
    message: string

proc main*() =
  let app = newExpressApp()
  let viewsDir = resolveViewsDir("websocket_pubsub")
  if viewsDir.len == 0:
    echo "websocket_pubsub views not found"
    quit(1)
  app.setViewsDir(viewsDir)

  # Enable permessage-deflate negotiation and tune for small demo payloads.
  app.server.setWsCompressionEnabled(true)
  app.server.setWsCompressionThreshold(64)
  app.server.setWsCompressionBackpressureBypass(512 * 1024)
  app.setWsMaxBackpressure(2 * 1024 * 1024)
  app.setWsIdleTimeout(120)

  app.use(bodyParser())
  app.use(timeout(30_000))

  app.getAsync("/") do (_: Request, res: Response) {.async.}:
    res.render("index")

  app.postAsync("/publish/:topic") do (req: Request, res: Response) {.async.}:
    let topic = req.param("topic").strip()
    if topic.len == 0:
      res.badRequest("topic is required")
      return
    let parsed = tryParseBody[PublishBody](req)
    if not parsed.ok or parsed.value.message.len == 0:
      res.badRequest("message is required")
      return
    let delivered = app.publish(topic, parsed.value.message)
    res.json(%*{"topic": topic, "delivered": delivered})

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    if isBinary:
      ws.sendText("""{"error":"binary frames are not handled in this demo"}""")
      return

    let msg = message.strip()
    if msg.startsWith("sub:"):
      let topic = msg[4 .. ^1].strip()
      if topic.len == 0:
        ws.sendText("""{"error":"empty topic"}""")
      elif ws.subscribe(topic):
        ws.sendText($(%*{"ok": true, "action": "subscribed", "topic": topic}))
      else:
        ws.sendText($(%*{"ok": false, "action": "subscribed", "topic": topic}))
      return

    if msg.startsWith("unsub:"):
      let topic = msg[6 .. ^1].strip()
      if topic.len == 0:
        ws.sendText("""{"error":"empty topic"}""")
      elif ws.unsubscribe(topic):
        ws.sendText($(%*{"ok": true, "action": "unsubscribed", "topic": topic}))
      else:
        ws.sendText($(%*{"ok": false, "action": "unsubscribed", "topic": topic}))
      return

    if msg.startsWith("pub:"):
      let parts = msg.split(":", maxsplit = 2)
      if parts.len < 3 or parts[1].strip().len == 0:
        ws.sendText("""{"error":"use pub:<topic>:<message>"}""")
        return
      let topic = parts[1].strip()
      let payload = parts[2]
      let delivered = app.publish(topic, payload)
      ws.sendText($(%*{"ok": true, "action": "published", "topic": topic, "delivered": delivered}))
      return

    if msg == "ping":
      ws.sendText("""{"type":"pong"}""")
    else:
      ws.sendText("""{"error":"unknown command"}""")

  app.onWsOpen proc(ws: WebSocket) =
    discard ws.subscribe("updates")
    ws.sendText("""{"type":"welcome","hint":"sub:<topic> | unsub:<topic> | pub:<topic>:<message>"}""")

  app.onWsClose proc(_: WebSocket) =
    discard

  app.getAsync("/api/replay/:topic") do (req: Request, res: Response) {.async.}:
    req.onAbort(proc(reason: RequestCancelReason) =
      echo "[websocket_pubsub_compression_app] replay aborted: ", $reason
    )
    let rawTopic = req.param("topic")
    let topic = if rawTopic.len == 0: "updates" else: rawTopic
    for i in 0 ..< 20:
      if req.aborted():
        return
      discard app.publish(topic, "replay message #" & $i)
      await sleepAsync(40)
    if req.aborted():
      return
    res.json(%*{
      "ok": true,
      "topic": topic,
      "published": 20,
      "timeoutRemainingMs": requestTimeoutRemainingMs(req)
    })

  let port = parsePort(3000)
  app.listen(port) do (ok: bool):
    if ok:
      echo "websocket_pubsub_compression_app listening on http://localhost:", port
      echo "WebSocket endpoint: ws://localhost:", port, "/ws"
    else:
      echo "failed to start websocket_pubsub_compression_app"
      quit(1)
