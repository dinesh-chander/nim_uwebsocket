## GPU Dashboard — server-push (WebSocket) port of gpu-stats-server.js.
##
## Demonstrates:
## - Backend timer (`app.setInterval`) collecting GPU metrics every N seconds
## - Blocking CLI collectors (amd-smi / nvidia-smi) offloaded via `runOffload`
## - Server-initiated WebSocket push (htmx ws extension on the client)
## - Optional llama.cpp engine metrics ONLY when ENGINE_BASE is configured
##   (polled with nim_fasthttpclient on the app's own event loop — shared
##   loop, pooled keep-alive connections, no offload thread occupied)
## - HTMX frontend (dashboard.html) living in this folder — no frontend polling
##
## Every `GPU_INTERVAL_MS` the backend collects a snapshot and broadcasts it
## to all connected WebSocket clients; the page never fetches an API.
##
## Run (after `make examples`, from repo root):
##   ./examples/bin/gpu_dashboard_app            # http://localhost:8083
##   PORT=9000 GPU_INTERVAL_MS=1000 ./examples/bin/gpu_dashboard_app
##   ENGINE_BASE=http://localhost:8082 ./examples/bin/gpu_dashboard_app
##     # also polls the llama.cpp server /metrics + /props on the backend
##
## Test hook (mirrors the JS sidecar):
##   FAKE_SMI_DIR=/tmp/fakesmi ./examples/bin/gpu_dashboard_app
##     # reads amd.metric.out / amd.static.out / nvidia.out instead of the CLIs

import std/[json, os, strutils, times, asyncdispatch]
import ../../nim_express/src/nim_express
import ../../nim_express/src/nim_express/app as expressApp
import ../../nim_fasthttpclient/src/nim_fasthttpclient/types as fasttypes
import ../../nim_fasthttpclient/src/nim_fasthttpclient/client as fastclient
import ../shared/example_support
import ./collectors

const
  DefaultPort = 8083
  DefaultIntervalMs = 1000

  # Single-file distribution: the frontend assets are embedded into the
  # binary at compile time (nim_express `staticEmbedView`) and also served
  # from disk when present, so local edits to dashboard.html show up on
  # reload without a rebuild.
  # Asset sources are resolved against this file's own directory, so the
  # embed works both when `main.nim` is compiled directly and when it is
  # built through the thin `examples/gpu_dashboard_app.nim` entrypoint
  # (whose project path is `examples/`, not `examples/gpu_dashboard/`).
  AssetsDir = currentSourcePath().parentDir
  ViewDashboard = "dashboard"
  ViewHtmx = "vendor/htmx.min.js"
  ViewWs = "vendor/ws.js"

var
  gIntervalMs: int
  gEngineBase: string
  gFakeSmiDir: string
  gTimeoutExe: string
  gEngClient: fasttypes.HttpClient

proc envIntOr(name: string, def: int): int =
  let raw = getEnv(name, "")
  if raw.len == 0: return def
  try: parseInt(raw) except ValueError: def

# ---------- dashboard asset (served at /) ----------

proc dashboardPath(): string =
  ## Finds dashboard.html next to the example sources, whether the binary runs
  ## from examples/bin/, the repo root, or this folder.
  let appDir = getAppDir()
  for cand in [
    appDir / "../gpu_dashboard/dashboard.html",
    appDir / "dashboard.html",
    "examples/gpu_dashboard/dashboard.html",
    "dashboard.html",
  ]:
    if cand.fileExists(): return cand
  ""

proc serveDashboard(res: Response) =
  ## Disk copy first (live frontend edits without a rebuild), then the copy
  ## embedded into the binary — the binary is self-contained either way.
  var html: string
  let path = dashboardPath()
  if path.len > 0:
    try: html = readFile(path) except CatchableError: discard
  if html.len == 0:
    let v = res.loadView(ViewDashboard)
    if not v.ok: html = "<h1>dashboard missing (embedded view failed: " & v.error & "</h1>"
    else: html = v.content
  res.html(html)

# ---------- collection tick ----------

var gApp: ExpressApp
var gLastSnapshot = ""
var gStaticRaw = ""
var gInFlight = false

type Conn = object
  ## One live WebSocket subscriber with its own delivery cadence.
  ws: WebSocket
  rateMs: int     ## 0 = paused (deliver nothing until resumed)
  nextAtMs: int   ## deliver no earlier than this wall-clock ms

var gConns: seq[Conn] = @[]

proc pushToConns(payload: string) =
  ## Called once per collection tick; each connection receives the snapshot
  ## only when its own requested rate has elapsed. Data freshness is bounded
  ## by the tick; delivery rate is per page.
  let nowMs = int(epochTime() * 1000)
  var i = 0
  while i < gConns.len:
    if not gConns[i].ws.isOpen:
      gConns.del(i)
      continue
    if gConns[i].rateMs > 0 and nowMs >= gConns[i].nextAtMs:
      gConns[i].ws.sendText(payload)
      gConns[i].nextAtMs = nowMs + gConns[i].rateMs
    inc i

proc applyRate(ws: WebSocket; message: string) =
  ## Control frame from a page: {"t":"rate","ms":N} — N=0 pauses delivery.
  if message.len == 0 or message.len > 200 or message[0] != '{': return
  try:
    let j = parseJson(message)
    if j["t"].getStr("-") == "rate" and j.hasKey("ms") and j["ms"].kind == JInt:
      var ms = j["ms"].getInt
      ms = if ms == 0: 0 else: ms.min(3_600_000).max(250)
      for c in gConns.mpairs:
        if c.val.ws == ws:
          c.val.rateMs = ms
          c.val.nextAtMs = 0   # next tick delivers immediately on resume
          break
  except JsonParsingError:
    discard

proc engineGet(url: string): Future[string] =
  ## Async GET on the app's own event loop via `nim_fasthttpclient` (shared
  ## loop, pooled keep-alive connections) — no offload thread is occupied.
  ## Fails like the old blocking path did: transport error or non-2xx.
  var fut = newFuture[string]("engineGet")
  if not gEngClient.initialized:
    fut.fail(newException(IOError, "engine client not initialized"))
    return fut
  fastclient.get(gEngClient, url,
    proc(resp: fasttypes.HttpResponse, err: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        if err.len > 0:
          fut.fail(newException(IOError, "engine GET " & url & ": " & err))
        elif resp.statusCode div 100 != 2:
          fut.fail(newException(IOError, "engine GET " & url & " HTTP " & $resp.statusCode))
        else:
          fut.complete(resp.body))
  result = fut

proc collectTick() {.async.} =
  # One collection round: fire independent blocking calls, gather results
  # with allSettled semantics, broadcast the snapshot.
  let needStatic = gStaticRaw.len == 0
  let engineWanted = gEngineBase.len > 0
  let propsWanted = engineWanted and epochTime() * 1000.0 - gPropsAtMs > PropsTtlMs

  let fAmd = runOffload(runSmiBlocking("amd.metric", gFakeSmiDir, gTimeoutExe))
  let fNv = runOffload(runSmiBlocking("nvidia", gFakeSmiDir, gTimeoutExe))
  var fStatic: Future[string] = nil
  if needStatic: fStatic = runOffload(runSmiBlocking("amd.static", gFakeSmiDir, gTimeoutExe))
  var fEng: Future[string] = nil
  if engineWanted: fEng = engineGet(gEngineBase & "/metrics")
  var fProps: Future[string] = nil
  if propsWanted: fProps = engineGet(gEngineBase & "/props")
  var fSlots: Future[string] = nil
  if engineWanted: fSlots = engineGet(gEngineBase & "/slots")

  var futs = @[fAmd, fNv]
  if fStatic != nil: futs.add fStatic
  if fEng != nil: futs.add fEng
  if fProps != nil: futs.add fProps
  if fSlots != nil: futs.add fSlots
  try:
    discard await all(futs)
  except CatchableError:
    discard

  var errors = newJArray()
  template settle(f: Future[string], label: string): (bool, string) =
    if f == nil: (false, "")
    else:
      try: (true, f.read)
      except CatchableError as e:
        errors.add %(label & ": " & e.msg)
        (false, "")

  let (_, amdRaw) = settle(fAmd, "amd-smi")
  let (_, nvRaw) = settle(fNv, "nvidia-smi")
  var staticRaw = gStaticRaw
  if needStatic:
    let (ok, raw) = settle(fStatic, "amd-smi static")
    if ok: staticRaw = raw
  var engObj: JsonNode = nil
  if engineWanted:
    var propsBody: OptS = (false, "")
    if propsWanted:
      let (ok, raw) = settle(fProps, "engine /props")
      if ok: propsBody = (true, raw)
    let (ok, metricsRaw) = settle(fEng, "engine /metrics")
    if ok: engObj = buildEngineObj(metricsRaw, propsBody)

  # Engine slot inventory (mirrors the Node sidecar's /summary slots field).
  # Optional: engines without /slots answer 404, so failures stay silent and
  # the dashboard falls back to the max-context placeholder like the Node page.
  var slotsVal: JsonNode = newJNull()
  if fSlots != nil:
    try:
      let parsed = parseJson(fSlots.read)
      if parsed.kind == JArray: slotsVal = parsed
    except CatchableError:
      discard

  let (amdRows, amdErr) = collectAmdGpus(amdRaw, staticRaw)
  if amdErr[0]: errors.add %amdErr[1]
  let (nvRows, nvErr) = collectNvGpus(nvRaw)
  if nvErr[0]: errors.add %nvErr[1]

  var gpus = newJArray()
  for g in amdRows: gpus.add g
  for g in nvRows: gpus.add g
  var gi = 0
  for g in gpus:
    g["global_index"] = %gi
    inc gi
  if needStatic and staticRaw.len > 0: gStaticRaw = staticRaw

  let nowMs = int(epochTime() * 1000)
  var snapshot = newJObject()
  snapshot["time"] = %nowMs
  var gpusObj = newJObject()
  gpusObj["time"] = %nowMs
  gpusObj["gpus"] = gpus
  gpusObj["errors"] = errors
  snapshot["gpus"] = gpusObj
  if engineWanted:
    snapshot["engine"] =
      if engObj != nil: engObj
      else: %*{"kind": "error"}
    snapshot["slots"] = slotsVal
  let payload = $snapshot
  gLastSnapshot = payload
  pushToConns(payload)

proc tickRunner() {.async.} =
  try:
    await collectTick()
  except CatchableError as e:
    echo "tick error: ", e.msg
  finally:
    gInFlight = false

proc onTick() =
  if gInFlight: return
  gInFlight = true
  discard tickRunner()

proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()

  # One async route keeps the framework's asyncdispatch pump (and thus
  # `runOffload` future completion) installed; also handy for debugging.
  app.getAsync("/debug/tick") do (req: Request, res: Response) {.async.}:
    res.json(%*{"inFlight": gInFlight, "hasSnapshot": gLastSnapshot.len > 0})

  # Frontend assets embedded at compile time; the single executable below is
  # fully self-contained (no CDN, no asset files needed at runtime).
  # Relative to this file's directory (the compile-time project path), so the
  # embed works from any build cwd.
  staticEmbedView(app, ViewDashboard, AssetsDir / "dashboard.html")
  staticEmbedView(app, ViewHtmx, AssetsDir / "vendor/htmx.min.js")
  staticEmbedView(app, ViewWs, AssetsDir / "vendor/ws.js")

  app.get("/") do (req: Request, res: Response):
    serveDashboard(res)
  app.get("/gpu-dashboard.html") do (req: Request, res: Response):
    serveDashboard(res)

  # Vendored frontend assets (htmx + ws extension), embedded into the binary
  # so the page works with no CDN and no external files.
  app.get("/vendor/htmx.min.js") do (req: Request, res: Response):
    let v = res.loadView(ViewHtmx)
    res.contentType("application/javascript; charset=utf-8")
       .set("Cache-Control", "public, max-age=31536000, immutable")
       .send(v.content)
  app.get("/vendor/ws.js") do (req: Request, res: Response):
    let v = res.loadView(ViewWs)
    res.contentType("text/javascript; charset=utf-8")
       .set("Cache-Control", "public, max-age=31536000, immutable")
       .send(v.content)
  app.get("/healthz") do (req: Request, res: Response):
    res.json(%*{"status": "ok", "intervalMs": gIntervalMs, "wsClients": gConns.len,
                "engine": (if gEngineBase.len > 0: gEngineBase else: "disabled")})

  # ---- WebSocket: clients subscribe at /ws; we push snapshots at each
  # connection's requested rate (control frame {"t":"rate","ms":N}). ----
  app.ws proc(ws: WebSocket, message: string, isBinary: bool) =
    if not isBinary: applyRate(ws, message)

  app.onWsOpen proc(ws: WebSocket) =
    gConns.add Conn(ws: ws, rateMs: gIntervalMs, nextAtMs: 0)
    if gLastSnapshot.len > 0:
      ws.sendText(gLastSnapshot)

  app.onWsClose proc(ws: WebSocket) =
    for i in 0 ..< gConns.len:
      if gConns[i].ws == ws:
        gConns.del(i)
        break

  app.setInterval(onTick, gIntervalMs)

  return app

proc main*() =
  gIntervalMs = max(250, envIntOr("GPU_INTERVAL_MS", DefaultIntervalMs))
  gEngineBase = getEnv("ENGINE_BASE", "").strip(false, true)
  while gEngineBase.len > 0 and gEngineBase[^1] == '/':
    gEngineBase.setLen(gEngineBase.len - 1)
  gFakeSmiDir = getEnv("FAKE_SMI_DIR", "")
  gTimeoutExe = if gFakeSmiDir.len == 0: findExe("timeout") else: ""
  let port = parsePort(DefaultPort)

  let app = createApp()
  gApp = app
  echo "GPU dashboard (push over /ws) — every ", gIntervalMs, " ms"
  echo "  collectors: ",
    (if gFakeSmiDir.len > 0: "FAKE_SMI_DIR=" & gFakeSmiDir
      else: "amd-smi + nvidia-smi" &
        (if gTimeoutExe.len > 0: " (timeout " & $SmiTimeoutSecs & "s)" else: ""))
  echo "  engine:     ",
    (if gEngineBase.len > 0: gEngineBase else: "disabled (set ENGINE_BASE to enable)")
  echo "  open:       http://localhost:", port
  app.listen(port) do (success: bool):
    if success:
      if gEngineBase.len > 0:
        # Share the express event loop: the client's sockets are pumped by
        # the same loop as the server (no second loop, no extra thread).
        gEngClient = fastclient.newHttpClient(defaultTimeoutMs = HttpTimeoutMs)
        fastclient.initClientWithLoop(gEngClient, expressApp.getEventLoop(app))
      echo "GPU dashboard running at http://localhost:", port
    else:
      echo "Failed to bind port ", port
      quit 1

when isMainModule:
  main()
