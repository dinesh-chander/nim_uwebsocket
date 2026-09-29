## Example: nim_express web application
## Built on uWebSockets with async I/O for file operations

import std/[os, strutils]
import ../nim_express/src/nim_express

let app = newExpressApp()

proc blockingCpuWork(iterations: int): int {.gcsafe.} =
  var checksum = 0
  for i in 0 ..< iterations:
    checksum = (checksum + ((i * 31) xor (i shr 3))) and 0x7fffffff
  checksum

# Middleware
app.use(logger())
app.use(cors())
app.use(bodyParser())
app.use(helmet())
app.use(requestId())
app.use(health("/health"))

# Basic route
app.getAsync("/") do (req: Request, res: Response) {.async.}:
  res.html("""
    <h1>nim_express - High Performance Web Framework</h1>
    <p>Built on uWebSockets with async I/O support</p>
    <ul>
      <li><a href="/health">Health Check</a></li>
      <li><a href="/api/users">API Example</a></li>
      <li><a href="/file">File Read (async)</a></li>
      <li><a href="/offload?n=15000000">Threadpool Offload Demo</a></li>
    </ul>
  """)

# JSON API
app.getAsync("/api/users") do (req: Request, res: Response) {.async.}:
  res.json(%*{
    "users": [
      {"id": 1, "name": "Alice"},
      {"id": 2, "name": "Bob"}
    ]
  })

app.getAsync("/api/users/:id") do (req: Request, res: Response) {.async.}:
  let id = req.param("id")
  res.json(%*{"id": id, "name": "User " & id})

# Async file read - non-blocking I/O
app.getAsync("/file") do (req: Request, res: Response) {.async.}:
  try:
    let content = await readFileAsync("/etc/hosts")
    res.text(content)
  except:
    res.serverError("Could not read file")

# POST with JSON body
app.postAsync("/api/data") do (req: Request, res: Response) {.async.}:
  if req.jsonBody != nil:
    res.json(%*{
      "received": req.jsonBody,
      "processed": true
    })
  else:
    res.badRequest("Invalid JSON")

# Threadpool offload demo: run blocking CPU work outside the event-loop thread
app.getAsync("/offload") do (req: Request, res: Response) {.async.}:
  let rawN = req.queryParam("n", "15000000")
  var iterations = 15_000_000
  try:
    iterations = parseInt(rawN)
  except ValueError:
    discard

  if iterations < 1:
    iterations = 1

  let started = epochTime()
  let checksum = await runOffload(blockingCpuWork(iterations))
  let elapsedMs = int((epochTime() - started) * 1000.0)

  res.json(%*{
    "offloaded": true,
    "iterations": iterations,
    "checksum": checksum,
    "elapsedMs": elapsedMs
  })

# Start server
let port = parseInt(getEnv("PORT", "3000"))
echo """
=====================================
  nim_express - uWebSockets Backend
=====================================

Features:
- High performance uWebSockets
- Async file I/O
- WebSocket support
- Express.js-like API

=====================================
"""
echo "Server running at http://localhost:", port
app.run(port)
