## WebSocket server example using nim_usockets
##
## This example shows how to handle WebSocket connections alongside HTTP.
## Run with:
##   nim c -r --passL:"-L../usockets -lusockets" websocket_server.nim

import ../src/nim_usockets
import std/options

# Track active WebSocket connections
var connections: seq[WebSocketConnection] = @[]

proc broadcast(message: string, excludeWs: WebSocketConnection = nil) =
  ## Send a message to all connected clients
  for ws in connections:
    if ws != excludeWs and ws.state == wsOpen:
      ws.sendText(message)

proc handleWebSocket(ws: WebSocketConnection, data: string) =
  ## Process incoming WebSocket data
  let frameOpt = decodeFrame(data)
  if frameOpt.isNone():
    return

  let (message, _) = frameOpt.get()

  case message.opcode
  of wsText:
    echo "Received text: ", message.data
    # Echo back and broadcast
    ws.sendText("Echo: " & message.data)
    broadcast("User says: " & message.data, ws)

  of wsBinary:
    echo "Received binary data, length: ", message.data.len
    ws.sendBinary(message.data)

  of wsPing:
    ws.pong(message.data)

  of wsPong:
    echo "Received pong"

  of wsClose:
    echo "Client requested close"
    ws.close(1000, "Goodbye")

  else:
    discard

proc main() =
  let server = newHttpServer(NoSsl)

  server.handle proc(req: HttpRequest, res: HttpResponse) =
    echo "Request: ", req.methodKind, " ", req.path

    # Check for WebSocket upgrade
    if isWebSocketUpgrade(req.headers):
      let wsKey = getWebSocketKey(req.headers)
      if wsKey.len > 0:
        let acceptKey = generateAcceptKey(wsKey)
        let handshake = createHandshakeResponse(acceptKey)

        # Send handshake response
        res.send(handshake)

        # Create WebSocket connection
        let ws = WebSocketConnection(
          socket: res.socket,
          ssl: res.ssl,
          state: wsOpen,
          buffer: "",
          fragmentBuffer: "",
          fragmentOpcode: wsText
        )
        connections.add(ws)
        echo "WebSocket connected! Total connections: ", connections.len
        return

    # Regular HTTP handling
    case req.path
    of "/":
      res.html("""
<!DOCTYPE html>
<html>
<head>
  <title>WebSocket Demo</title>
  <style>
    body { font-family: Arial, sans-serif; max-width: 600px; margin: 50px auto; }
    #messages { border: 1px solid #ccc; height: 300px; overflow-y: scroll; padding: 10px; margin: 10px 0; }
    #input { width: 80%; padding: 10px; }
    button { padding: 10px 20px; }
  </style>
</head>
<body>
  <h1>WebSocket Demo</h1>
  <div id="messages"></div>
  <input type="text" id="input" placeholder="Type a message..." />
  <button onclick="send()">Send</button>

  <script>
    const messages = document.getElementById('messages');
    const input = document.getElementById('input');

    const ws = new WebSocket('ws://' + location.host + '/');

    ws.onopen = () => {
      messages.innerHTML += '<p><em>Connected!</em></p>';
    };

    ws.onmessage = (event) => {
      messages.innerHTML += '<p>' + event.data + '</p>';
      messages.scrollTop = messages.scrollHeight;
    };

    ws.onclose = () => {
      messages.innerHTML += '<p><em>Disconnected</em></p>';
    };

    function send() {
      if (input.value) {
        ws.send(input.value);
        input.value = '';
      }
    }

    input.addEventListener('keypress', (e) => {
      if (e.key === 'Enter') send();
    });
  </script>
</body>
</html>
""")
    else:
      res.setStatus(Http404)
      res.`end`("Not Found")

  server.listen("0.0.0.0", 3000) do(success: bool):
    if success:
      echo "WebSocket server running at http://localhost:3000"
      echo "Open in browser to test WebSocket functionality"
    else:
      echo "Failed to start server!"
      quit(1)

  server.run()

when isMainModule:
  main()
