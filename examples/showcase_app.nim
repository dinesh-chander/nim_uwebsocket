# nim_express showcase app.
#
# Demonstrates the core strengths of the framework in one small service:
#   - sync fast-path handlers (no async overhead on simple endpoints)
#   - zero-allocation-ish JSON via JsonBuilder + jsonRaw
#   - typed JSON responses via res.json(T)
#   - route params, query params, and body parsing
#   - CPU-bound work offloaded to a worker pool (runOffload) without
#     blocking the event loop
#   - WebSockets with per-client echo and server-side broadcast
#   - built-in middleware stack: panic recovery, request IDs, path
#     normalization, CORS, rate limiting, compression, ETags, timeouts
#   - process-level observability via optimizationMetricsJson
#   - horizontal scaling via runAuto (SO_REUSEPORT cluster on Linux,
#     graceful single-process fallback on macOS/Windows)
#
# Build (from repo root):
#   make usockets
#   nim c -d:release --opt:speed --mm:arc --stackTrace:on \
#     --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
#     --path:nim_fasthttpclient/src --path:vendor/zippy/src --path:vendor/brotli/src \
#     --path:vendor/nim_zstd --path:vendor/nim_libdeflate_gzip/src \
#     --path:vendor/malebolgia/src --path:vendor/jsony/src --path:vendor/checksums \
#     --passL:"nim_usockets/usockets/uSockets.a -lpthread -ldl" \
#     -o:examples/bin/showcase_app examples/showcase_app.nim
# or simply: make examples
#
# Run:
#   ./examples/bin/showcase_app            # PORT env overrides port (default 3000)
#   WORKERS=4 ./examples/bin/showcase_app  # cluster of 4 workers on Linux

import std/[algorithm, os, strutils, tables, times]
import ../nim_express/src/nim_express
import ./shared/example_support

type
  Item* = object
    id*: int
    title*: string
    done*: bool
    createdAt*: int64

  UserView* = object
    id*: int
    name*: string
    email*: string

  UserNameView* = object
    id*: int
    name*: string

  ComputeResult* = object
    iterations*: int
    totalPrimes*: int
    offloaded*: bool

var
  items = initTable[int, Item]()
  nextId = 1

proc addItem(title: string): Item =
  result = Item(id: nextId, title: title, done: false, createdAt: epochTime().int64)
  items[nextId] = result
  inc nextId

proc itemSnapshot(): seq[Item] =
  result = @[]
  result.setLen(items.len)
  var ix = 0
  for id in items.keys:
    result[ix] = items[id]
    inc ix
  result.sort(proc(a, b: Item): int = a.id.cmp(b.id))

proc computePrimes(count: int): int =
  ## CPU-bound work for the offload demo: count primes below 2^20 `count` times.
  let bound = 1_048_576
  var total = 0
  for _ in 0 ..< count:
    var isComposite = newSeq[bool](bound)
    for i in 2 ..< bound:
      if not isComposite[i]:
        total += 1
        if i * i < bound:
          var j = i * i
          while j < bound:
            isComposite[j] = true
            j += i
  total

proc itemsJsonPayload(page: int, limit: int): string =
  ## Build the paged items response with JsonBuilder (no JsonNode allocation).
  let all = itemSnapshot()
  let start = (page - 1) * limit
  let endPos = min(start + limit, all.len)
  let lo = max(0, start)

  var b = initJsonBuilder(256 + (max(0, endPos - lo)) * 96)
  b.add("{\"total\":")
  b.addInt(all.len)
  b.add(",\"page\":")
  b.addInt(page)
  b.add(",\"limit\":")
  b.addInt(limit)
  b.add(",\"items\":[")
  for i in lo ..< endPos:
    if i > lo:
      b.add(",")
    let it = all[i]
    b.add("{\"id\":")
    b.addInt(it.id)
    b.add(",\"title\":")
    b.addEscaped(it.title)
    b.add(",\"done\":")
    b.addBool(it.done)
    b.add(",\"createdAt\":")
    b.addInt(it.createdAt)
    b.add("}")
  b.add("]}")
  result = b.finish()

const LandingPage = """<!doctype html>
<html>
<head><meta charset="utf-8"><title>nim_express showcase</title>
<style>
 body{font-family:ui-monospace,monospace;max-width:760px;margin:2rem auto;padding:0 1rem}
 code{background:#f2f2f2;padding:2px 6px}
 h1{border-bottom:2px solid #444}
 li{margin:.4rem 0}
</style></head>
<body>
<h1>nim_express showcase</h1>
<p>One event loop, zero framework ceremony. Try:</p>
<ul>
  <li><code>curl localhost:3000/fast-json</code> &mdash; sync handler + JsonBuilder (fastest JSON path)</li>
  <li><code>curl localhost:3000/api/items?page=1&limit=5</code> &mdash; typed store, paged, ETag-able</li>
  <li><code>curl -XPOST localhost:3000/api/items -H 'Content-Type: application/json' -d '{"title":"ship it"}'</code> &mdash; body parse + WS broadcast</li>
  <li><code>curl localhost:3000/users/42?fields=name</code> &mdash; route params + query</li>
  <li><code>curl localhost:3000/compute/4</code> &mdash; CPU work offloaded to the worker pool (event loop never blocks)</li>
  <li><code>curl localhost:3000/health</code> &mdash; health-check middleware</li>
  <li><code>curl localhost:3000/metrics</code> &mdash; runtime optimization metrics</li>
  <li><code>websocat ws://localhost:3000/ws</code> &mdash; echo + live broadcast of new items</li>
</ul>
<p>Middleware: panicRecovery &rarr; requestId &rarr; normalizePath &rarr; cors &rarr; bodyParser &rarr; rateLimit &rarr; compression &rarr; etag &rarr; timeout &rarr; health.<br>
Scaling: <code>WORKERS=4</code> starts a SO_REUSEPORT cluster on Linux (runAuto falls back to one process elsewhere).</p>
</body>
</html>
"""

proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()

  # --- server tuning (mirrors the production benchmark setup) -------------
  app.server.options.socketNoDelay = true
  app.server.options.socketKeepAlive = true
  app.server.options.socketKeepAliveSeconds = 60
  app.server.options.wsKeepaliveInterval = 20_000

  # --- middleware stack ----------------------------------------------------
  app.use(panicRecovery())       # never let a handler panic take down the process
  app.use(requestId())           # X-Request-Id on every response
  app.use(normalizePath())       # trailing-slash safe
  app.use(cors())                # permissive CORS for the demo
  app.use(bodyParser())            # parse JSON / urlencoded bodies
  app.use(rateLimit(2000, 60_000))  # 2000 req/min per client
  app.use(compression())         # gzip/brotli/zstd response compression
  app.use(etag())                # weak ETags + 304 handling for GETs
  app.use(timeout(10_000))       # per-request timeout

  app.use(health(path = "/health", verbose = true))

  # --- landing page ---------------------------------------------------------
  app.get "/", proc(req: Request, res: Response) =
    res.sendHtmlBody(LandingPage)

  # --- fastest JSON path: sync handler + manual builder ----------------------
  app.get "/fast-json", proc(req: Request, res: Response) =
    var b = initJsonBuilder(192)
    b.add("{")
    b.addKey("service")
    b.addEscaped("nim_express_showcase")
    b.add(",")
    b.addKey("path")
    b.addEscaped(req.path)
    b.add(",")
    b.addKey("epoch")
    b.addInt(epochTime().int64)
    b.add(",")
    b.addKey("fastPath")
    b.addBool(true)
    b.add("}")
    res.jsonRaw(b.finish())

  # --- typed store: paged items (ETag + compression apply) -------------------
  app.get "/api/items", proc(req: Request, res: Response) =
    let page =
      try: max(1, parseInt(req.queryParam("page", "1")))
      except ValueError: 1
    let limit =
      try: min(100, max(1, parseInt(req.queryParam("limit", "10"))))
      except ValueError: 10
    res.jsonRaw(itemsJsonPayload(page, limit))

  app.post "/api/items", proc(req: Request, res: Response) =
    let body = req.jsonBody()
    if body == nil:
      res.status(400)
      res.jsonRaw("""{"error":"expected a JSON body with a \"title\" field"}""")
      return
    let title = body["title"].getStr().strip()
    if title.len == 0 or title.len > 200:
      res.status(400)
      res.jsonRaw("""{"error":"title must be 1..200 chars"}""")
      return
    let item = addItem(title)
    # notify all live websocket clients about the new item
    var notice = initJsonBuilder(96)
    notice.add("{\"type\":\"item.created\",\"id\":")
    notice.addInt(item.id)
    notice.add(",\"title\":")
    notice.addEscaped(item.title)
    notice.add("}")
    discard broadcastWs(app, notice.finish())
    res.status(201)
    res.jsonify(item)

  # --- route params + query params -------------------------------------------
  app.get "/users/:id", proc(req: Request, res: Response) =
    let rawId = req.param("id")
    let id =
      try: rawId.parseInt
      except ValueError: -1
    let user = UserView(id: id, name: "user_" & rawId,
                        email: "user_" & rawId & "@example.com")
    if req.queryParam("fields", "") == "name":
      res.jsonify(UserNameView(id: user.id, name: user.name))
    else:
      res.jsonify(user)

  # --- offloaded CPU work: event loop stays responsive ------------------------
  app.getAsync("/compute/:n") do (req: Request, res: Response) {.async.}:
    let n =
      try: min(8, max(1, parseInt(req.param("n"))))
      except ValueError: 1
    # the sieve runs on malebolgia's worker pool; other requests keep flowing
    let totalPrimes = await runOffload(computePrimes(n))
    res.jsonify(ComputeResult(iterations: n, totalPrimes: totalPrimes, offloaded: true))

  # --- observability -----------------------------------------------------------
  app.get "/metrics", proc(req: Request, res: Response) =
    res.contentType("application/json; charset=utf-8")
    if res.app != nil:
      res.send(res.app.optimizationMetricsJson())
    else:
      res.send("""{"error":"app unavailable"}""")

  # --- websockets: echo + broadcast -------------------------------------------
  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    if not isBinary:
      ws.send($(%*{"type": "echo", "text": message}))

  app.onWsOpen proc(ws: WebSocket) =
    ws.send($(%*{"type": "welcome",
                 "hint": "send any text to echo it; POST /api/items to see broadcasts"}))

  app.onWsClose proc(ws: WebSocket) =
    discard

  result = app

when isMainModule:
  proc main*() =
    let port = parsePort(3000)
    let workers =
      try: max(0, parseInt(getEnv("WORKERS", "0")))
      except ValueError: 0
    if workers > 1:
      # SO_REUSEPORT process cluster (Linux; runAuto falls back to a
      # single process on macOS/Windows).
      runAuto(createApp, port, workers)
    else:
      # Single event loop: one process, zero fork complexity.
      let app = createApp()
      app.run(port)

when isMainModule:
  main()
