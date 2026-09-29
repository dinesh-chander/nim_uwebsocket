import std/[json, times, strutils]
import ../nim_express/src/nim_express

let app = newExpressApp()

app.use(cors())
app.use(bodyParser())
app.use(compression())

app.get("/") do (req: Request, res: Response):
  res.html("""<!DOCTYPE html>
<html>
<head><title>HTTP/2 Example</title></head>
<body>
  <h1>nim_express HTTP/2 Server</h1>
  <p>This server supports both HTTP/1.1 and HTTP/2 (h2c).</p>
  <ul>
    <li><a href="/json">JSON response</a></li>
    <li><a href="/html">HTML response</a></li>
    <li><a href="/stream">Streaming response</a></li>
    <li><a href="/health">Health check</a></li>
  </ul>
</body>
</html>""")

app.get("/json") do (req: Request, res: Response):
  res.json(%*{
    "message": "Hello from HTTP/2!",
    "timestamp": epochTime().int,
    "protocol": "h2c / http/1.1 (auto-detected)",
    "features": ["multiplexing", "header compression", "server push"],
    "server": "nim_express"
  })

app.get("/html") do (req: Request, res: Response):
  res.html("""<!DOCTYPE html>
<html>
<head><title>HTML Response</title></head>
<body>
  <h1>HTML over HTTP/2</h1>
  <p>This page was served with automatic protocol detection.</p>
  <p>The server handles both HTTP/1.1 and HTTP/2 connections transparently.</p>
</body>
</html>""")

app.get("/stream") do (req: Request, res: Response):
  var parts: seq[string] = @[]
  for i in 0 ..< 10:
    parts.add("{\"chunk\":" & $i & ",\"data\":\"payload_" & $i & "\"}")
  res.set("Content-Type", "application/x-ndjson")
  res.send(parts.join("\n") & "\n")

app.get("/health") do (req: Request, res: Response):
  res.jsonRaw("""{"status":"ok"}""")

app.get("/users/:id") do (req: Request, res: Response):
  let id = req.param("id")
  res.json(%*{
    "id": id,
    "name": "User " & id,
    "email": "user" & id & "@example.com"
  })

echo """
=====================================
  HTTP/2 Example Server
=====================================

Endpoints:
  GET /        - Home page (HTML)
  GET /json    - JSON response
  GET /html    - HTML page
  GET /stream  - NDJSON streaming
  GET /health  - Health check
  GET /users/:id - User by ID

Testing with curl:
  HTTP/1.1:  curl http://localhost:3100/json
  HTTP/2:    curl --http2-prior-knowledge http://localhost:3100/json

=====================================
"""

app.listen(3100) do (success: bool):
  if success:
    echo "HTTP/2 server running on http://localhost:3100"
  else:
    echo "Failed to start server!"
    quit(1)
