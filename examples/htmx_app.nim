## HTMX Demo Application
##
## Demonstrates:
## - HTMX integration with nim_express (uWebSockets backend)
## - All HTTP methods (GET, POST, PUT, PATCH, DELETE)
## - WebSocket live updates
## - Async handlers with sync response methods

import std/[json, strutils, sequtils, times, random]
import std/httpclient except Response
import ../nim_express/src/nim_express

# Store connected WebSocket clients
var wsClients: seq[WebSocket] = @[]

# In-memory "database" for todos
var todos: seq[JsonNode] = @[
  %*{"id": 1, "title": "Learn Nim", "completed": false},
  %*{"id": 2, "title": "Build nim_express", "completed": true},
  %*{"id": 3, "title": "Create HTMX demo", "completed": false}
]
var nextId = 4

type
  WsStringPayload = object
    `type`: string
    value: string

  WsIntPayload = object
    `type`: string
    value: int

proc findTodoIndex(id: int): int =
  for i, todo in todos:
    if todo["id"].getInt() == id:
      return i
  return -1

# HTML Templates
const layoutTemplate = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>nim_express + HTMX Demo</title>
  <script src="https://unpkg.com/htmx.org@1.9.10"></script>
  <script src="https://unpkg.com/htmx.org/dist/ext/ws.js"></script>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      max-width: 800px;
      margin: 0 auto;
      padding: 20px;
      background: #f5f5f5;
    }
    h1 { color: #333; margin-bottom: 20px; }
    h2 { color: #555; margin: 20px 0 10px; font-size: 1.2em; }
    .card {
      background: white;
      border-radius: 8px;
      padding: 20px;
      margin-bottom: 20px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    .todo-list { list-style: none; }
    .todo-item {
      display: flex;
      align-items: center;
      padding: 12px;
      border-bottom: 1px solid #eee;
      gap: 12px;
    }
    .todo-item:last-child { border-bottom: none; }
    .todo-item.completed .todo-title {
      text-decoration: line-through;
      color: #888;
    }
    .todo-title { flex: 1; }
    .todo-actions { display: flex; gap: 8px; }
    button, input[type="submit"] {
      padding: 8px 16px;
      border: none;
      border-radius: 4px;
      cursor: pointer;
      font-size: 14px;
    }
    .btn-primary { background: #007bff; color: white; }
    .btn-success { background: #28a745; color: white; }
    .btn-danger { background: #dc3545; color: white; }
    .btn-warning { background: #ffc107; color: #333; }
    .btn-secondary { background: #6c757d; color: white; }
    button:hover { opacity: 0.9; }
    input[type="text"] {
      padding: 10px;
      border: 1px solid #ddd;
      border-radius: 4px;
      font-size: 16px;
      width: 100%;
    }
    .add-form { display: flex; gap: 10px; margin-bottom: 20px; }
    .add-form input { flex: 1; }
    .edit-form { display: flex; gap: 10px; flex: 1; }
    .edit-form input { flex: 1; }
    .stats { display: flex; gap: 20px; margin-bottom: 20px; }
    .stat { background: #e9ecef; padding: 10px 20px; border-radius: 4px; }
    .stat-value { font-size: 24px; font-weight: bold; color: #333; }
    .stat-label { font-size: 12px; color: #666; }
    .live-counter {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 20px;
    }
    .counter-value {
      font-size: 72px;
      font-weight: bold;
      color: #007bff;
      min-width: 150px;
      text-align: center;
      transition: transform 0.1s;
    }
    .ws-status {
      padding: 6px 12px;
      border-radius: 20px;
      font-size: 12px;
      font-weight: bold;
    }
    .ws-connected { background: #28a745; color: white; }
    .ws-disconnected { background: #dc3545; color: white; }
    .ws-connecting { background: #ffc107; color: #333; }
    .server-time { font-size: 24px; font-weight: bold; color: #333; }
    .polling-demo { padding: 15px; background: #e9ecef; border-radius: 4px; text-align: center; }
  </style>
</head>
<body>
  <h1>nim_express + HTMX Demo</h1>
  {{content}}

  <script>
    let ws = null;
    let reconnectInterval = null;

    function connectWebSocket() {
      const statusEl = document.getElementById('ws-status');
      const counterEl = document.getElementById('live-counter-value');
      const timeEl = document.getElementById('server-time');

      if (statusEl) statusEl.className = 'ws-status ws-connecting';
      if (statusEl) statusEl.textContent = 'Connecting...';

      ws = new WebSocket('ws://' + window.location.host + '/ws');

      ws.onopen = function() {
        if (statusEl) {
          statusEl.className = 'ws-status ws-connected';
          statusEl.textContent = 'Connected';
        }
        if (reconnectInterval) {
          clearInterval(reconnectInterval);
          reconnectInterval = null;
        }
      };

      ws.onmessage = function(event) {
        try {
          const data = JSON.parse(event.data);
          if (data.type === 'counter' && counterEl) {
            counterEl.textContent = data.value;
            counterEl.style.transform = 'scale(1.1)';
            setTimeout(() => counterEl.style.transform = 'scale(1)', 100);
          } else if (data.type === 'time' && timeEl) {
            timeEl.textContent = data.value;
          }
        } catch (e) {
          console.log('WS message:', event.data);
        }
      };

      ws.onclose = function() {
        if (statusEl) {
          statusEl.className = 'ws-status ws-disconnected';
          statusEl.textContent = 'Disconnected';
        }
        if (!reconnectInterval) {
          reconnectInterval = setTimeout(connectWebSocket, 3000);
        }
      };

      ws.onerror = function(err) {
        console.error('WebSocket error:', err);
      };
    }

    document.addEventListener('DOMContentLoaded', connectWebSocket);
  </script>
</body>
</html>
"""

proc renderTodoItem(todo: JsonNode): string =
  let id = todo["id"].getInt()
  let title = todo["title"].getStr()
  let completed = todo["completed"].getBool()
  let completedClass = if completed: "completed" else: ""
  let toggleText = if completed: "Undo" else: "Done"
  let toggleClass = if completed: "btn-secondary" else: "btn-success"

  result = """
  <li class="todo-item $1" id="todo-$2">
    <span class="todo-title">$3</span>
    <div class="todo-actions">
      <button class="$4" hx-patch="/api/todos/$2/toggle" hx-target="#todo-$2" hx-swap="outerHTML">$5</button>
      <button class="btn-warning" hx-get="/api/todos/$2/edit" hx-target="#todo-$2" hx-swap="outerHTML">Edit</button>
      <button class="btn-danger" hx-delete="/api/todos/$2" hx-target="#todo-$2" hx-swap="outerHTML" hx-confirm="Delete this todo?">Delete</button>
    </div>
  </li>
  """.replace("$1", completedClass).replace("$2", $id).replace("$3", title).replace("$4", toggleClass).replace("$5", toggleText)

proc renderTodoList(): string =
  result = "<ul class=\"todo-list\" id=\"todo-list\">"
  for todo in todos:
    result.add(renderTodoItem(todo))
  result.add("</ul>")

proc renderStats(): string =
  let total = todos.len
  let completed = todos.filterIt(it["completed"].getBool()).len
  let pending = total - completed

  result = """
  <div class="stats" id="stats">
    <div class="stat"><div class="stat-value">$1</div><div class="stat-label">Total</div></div>
    <div class="stat"><div class="stat-value">$2</div><div class="stat-label">Completed</div></div>
    <div class="stat"><div class="stat-value">$3</div><div class="stat-label">Pending</div></div>
  </div>
  """.replace("$1", $total).replace("$2", $completed).replace("$3", $pending)

proc renderEditForm(todo: JsonNode): string =
  let id = todo["id"].getInt()
  let title = todo["title"].getStr()

  result = """
  <li class="todo-item" id="todo-$1">
    <form class="edit-form" hx-put="/api/todos/$1" hx-target="#todo-$1" hx-swap="outerHTML">
      <input type="text" name="title" value="$2" autofocus>
      <button type="submit" class="btn-primary">Save</button>
      <button type="button" class="btn-secondary" hx-get="/api/todos/$1" hx-target="#todo-$1" hx-swap="outerHTML">Cancel</button>
    </form>
  </li>
  """.replace("$1", $id).replace("$2", title)

proc main() =
  let app = newExpressApp()

  # Middlewares
  app.use(compression())  # Enable gzip compression
  app.use(logger(llInfo))
  app.use(cors())
  app.use(bodyParser())
  app.use(htmx())

  # Main page
  app.getAsync("/") do (req: Request, res: Response) {.async.}:
    let content = """
    <div class="card">
      <h2>Todo List</h2>
      """ & renderStats() & """
      <form class="add-form" hx-post="/api/todos" hx-target="#todo-list" hx-swap="beforeend" hx-on::after-request="this.reset(); htmx.trigger('#stats', 'refresh')">
        <input type="text" name="title" placeholder="Add a new todo..." required>
        <button type="submit" class="btn-primary">Add</button>
      </form>
      """ & renderTodoList() & """
    </div>

    <div class="card">
      <h2>Live WebSocket Counter</h2>
      <p style="color: #666; margin-bottom: 15px;">Real-time updates via WebSocket. Random values pushed every second.</p>
      <div class="live-counter">
        <span id="ws-status" class="ws-status ws-disconnected">Disconnected</span>
        <span id="live-counter-value" class="counter-value">0</span>
      </div>
    </div>

    <div class="card">
      <h2>Live Server Time (WebSocket)</h2>
      <p style="color: #666; margin-bottom: 15px;">Server time pushed via WebSocket every second.</p>
      <div class="polling-demo">
        <span id="server-time" class="server-time">Connecting...</span>
      </div>
    </div>
    """

    let html = layoutTemplate.replace("{{content}}", content)
    res.html(html)

  # Stats refresh endpoint
  app.getAsync("/api/stats") do (req: Request, res: Response) {.async.}:
    res.fragment(renderStats())

  # GET all todos
  app.getAsync("/api/todos") do (req: Request, res: Response) {.async.}:
    if req.isHtmx:
      res.fragment(renderTodoList())
    else:
      res.json(%*{"todos": todos, "count": todos.len})

  # Cross-app proxy endpoint (non-blocking outbound HTTP)
  app.getAsync("/api/proxy/users") do (req: Request, res: Response) {.async.}:
    try:
      let upstreamClient = newAsyncHttpClient(userAgent = "nim-express-htmx-proxy")
      defer:
        upstreamClient.close()
      let upstreamBody = await upstreamClient.getContent("http://127.0.0.1:3001/api/users")
      res.jsonRaw(upstreamBody)
    except CatchableError as e:
      res.status(502).json(%*{"error": "upstream request failed", "details": e.msg})

  # GET single todo
  app.getAsync("/api/todos/:id") do (req: Request, res: Response) {.async.}:
    let id = parseInt(req.params["id"])
    let idx = findTodoIndex(id)
    if idx >= 0:
      if req.isHtmx:
        res.fragment(renderTodoItem(todos[idx]))
      else:
        res.json(todos[idx])
    else:
      res.status(404).json(%*{"error": "Todo not found"})

  # GET edit form
  app.getAsync("/api/todos/:id/edit") do (req: Request, res: Response) {.async.}:
    let id = parseInt(req.params["id"])
    let idx = findTodoIndex(id)
    if idx >= 0:
      res.fragment(renderEditForm(todos[idx]))
    else:
      res.status(404).json(%*{"error": "Todo not found"})

  # POST new todo
  app.postAsync("/api/todos") do (req: Request, res: Response) {.async.}:
    var title = ""
    if req.jsonBody() != nil and req.jsonBody().kind == JObject:
      if "title" in req.jsonBody():
        title = req.jsonBody()["title"].getStr()

    if title.len == 0:
      res.status(400).json(%*{"error": "Title is required"})
      return

    let newTodo = %*{"id": nextId, "title": title, "completed": false}
    todos.add(newTodo)
    inc nextId

    if req.isHtmx:
      res.htmxTrigger("todoAdded")
      res.fragment(renderTodoItem(newTodo))
    else:
      res.status(201).json(newTodo)

  # PUT update todo
  app.putAsync("/api/todos/:id") do (req: Request, res: Response) {.async.}:
    let id = parseInt(req.params["id"])
    let idx = findTodoIndex(id)

    if idx < 0:
      res.status(404).json(%*{"error": "Todo not found"})
      return

    var title = ""
    if req.jsonBody() != nil and req.jsonBody().kind == JObject:
      if "title" in req.jsonBody():
        title = req.jsonBody()["title"].getStr()

    if title.len > 0:
      todos[idx]["title"] = %title

    if req.isHtmx:
      res.fragment(renderTodoItem(todos[idx]))
    else:
      res.json(todos[idx])

  # PATCH toggle todo
  app.patchAsync("/api/todos/:id/toggle") do (req: Request, res: Response) {.async.}:
    let id = parseInt(req.params["id"])
    let idx = findTodoIndex(id)

    if idx < 0:
      res.status(404).json(%*{"error": "Todo not found"})
      return

    let current = todos[idx]["completed"].getBool()
    todos[idx]["completed"] = %(not current)

    if req.isHtmx:
      res.htmxTrigger("todoToggled")
      res.fragment(renderTodoItem(todos[idx]))
    else:
      res.json(todos[idx])

  # DELETE todo
  app.deleteAsync("/api/todos/:id") do (req: Request, res: Response) {.async.}:
    let id = parseInt(req.params["id"])
    let idx = findTodoIndex(id)

    if idx < 0:
      res.status(404).json(%*{"error": "Todo not found"})
      return

    let deleted = todos[idx]
    todos.delete(idx)

    if req.isHtmx:
      res.htmxTrigger("todoDeleted")
      res.send("")  # Empty response removes the element
    else:
      res.json(%*{"deleted": deleted})

  # ============= WebSocket handlers =============
  randomize()

  # Broadcast time and counter to all connected clients
  proc broadcastUpdates() =
    if wsClients.len > 0:
      let currentTime = now().format("yyyy-MM-dd HH:mm:ss")
      let timeMessage = jsony.toJson(WsStringPayload(`type`: "time", value: currentTime))
      let preparedTime = prepareWsMessage(timeMessage)
      discard app.broadcastPreparedWs(preparedTime)

      for client in wsClients:
        let counterValue = rand(1..999)
        let counterMessage = jsony.toJson(WsIntPayload(`type`: "counter", value: counterValue))
        client.sendText(counterMessage)

  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    echo "WS message received: ", message
    ws.sendText("{\"type\": \"echo\", \"message\": \"" & message & "\"}")

  app.onWsOpen proc(ws: WebSocket) =
    echo "WebSocket client connected"
    wsClients.add(ws)
    let currentTime = now().format("yyyy-MM-dd HH:mm:ss")
    let initialValue = rand(1..999)
    ws.sendText(jsony.toJson(WsStringPayload(`type`: "time", value: currentTime)))
    ws.sendText(jsony.toJson(WsIntPayload(`type`: "counter", value: initialValue)))

  app.onWsClose proc(ws: WebSocket) =
    echo "WebSocket client disconnected"
    let idx = wsClients.find(ws)
    if idx >= 0:
      wsClients.delete(idx)

  # Timer for live updates
  app.setInterval(broadcastUpdates, 100)

  # Start server
  echo "Starting HTMX demo server..."
  echo "Features: uWebSockets, WebSocket, HTMX, Async handlers"
  app.listen(3000) do (success: bool):
    if success:
      echo "Server running at http://localhost:3000"
      echo "Open in browser to see the HTMX demo!"
    else:
      echo "Failed to start server!"
      quit(1)

when isMainModule:
  main()
