import std/[times, os, strutils]
import ../nim_express/src/nim_express
import ../nim_express/src/nim_express/config
import ../nim_express/src/nim_express/fastrand
import ../nim_express/src/nim_express/json_utils
import ../nim_utils/src/nim_utils/nim_fastjson/direct_engine

type
  JsonResponse = object
    message {.jsonSafe.}: string
    timestamp: int64
    id: int
    success: bool

const
  PlainBody = "Hello, World!"
  DefaultBenchPort = 3002

proc hasExplicitPortConfig(): bool =
  getEnv("NIM_EXPRESS_PORT", "").strip().len > 0 or
    getEnv("PORT", "").strip().len > 0 or
    getEnv("NIM_EXPRESS_CONFIG", "").strip().len > 0

proc resolvePort(): int =
  let cfg = loadAppEnvConfig()
  if cfg.port == DefaultEnvPort and not hasExplicitPortConfig():
    DefaultBenchPort
  else:
    cfg.port

proc resolveWorkers(): int =
  if paramCount() > 0:
    return parseInt(paramStr(1))
  for key in ["NIM_EXPRESS_WORKERS", "WORKERS", "THREADS"]:
    let raw = getEnv(key, "").strip()
    if raw.len == 0:
      continue
    try:
      return max(0, parseInt(raw))
    except ValueError:
      discard
  0

proc resolveScaleMode(workers: int): string =
  result = getEnv("NIM_EXPRESS_SCALE_MODE", "").strip().toLowerAscii()
  if result.len == 0:
    result = if workers > 1: "threaded" else: "single"
  if result notin ["single", "auto", "cluster", "threaded"]:
    result = "single"

proc createApp(): ExpressApp =
  {.cast(gcsafe).}:
    seedFastRand(uint64(getTime().toUnix()) xor uint64(getThreadId()))
    let app = newExpressApp()
    var cfg = loadAppEnvConfig()
    if cfg.port == DefaultEnvPort and not hasExplicitPortConfig():
      cfg.port = DefaultBenchPort
    app.applyAppEnvConfig(cfg)
    app.server.options.minimalHeaderParsing = true

    app.get("/json") do (req: Request, res: Response):
      let response = JsonResponse(
        message: "Hello, World!",
        timestamp: getTime().toUnix(),
        id: fastRandRange(1, 999999),
        success: true
      )
      res.json(response)

    app.get("/plaintext") do (req: Request, res: Response):
      res.text(PlainBody)

    # canonical static-serving path (ETag/ranges/sendfile fast path).
    # Sync handler + sendFileDirect: zero async machinery on steady state.
    app.get("/static") do (req: Request, res: Response):
      res.sendFileDirect(req, "benchmark/static16k.bin",
          trustedRoot = "benchmark")
    # sendfile path without per-request metadata work (prebuilt header block).
    # The 16 KiB fixture is generated on first start so no binary stays in VCS.
    let staticFixtureDir = "benchmark"
    let staticFixture = staticFixtureDir / "static16k.bin"
    var staticSize = 16384
    # Read-only or missing fixture dir (e.g. the non-root Docker runtime
    # image) must not crash startup; /static and /staticraw then 404/500.
    try:
      if not fileExists(staticFixture):
        if not dirExists(staticFixtureDir): createDir(staticFixtureDir)
        var buf: string
        setLen(buf, 16384)
        for i in 0 ..< 16384: buf[i] = char((i * 7 + 13) mod 251)
        var f = staticFixture.open(fmWrite)
        f.write(buf[0 ..< buf.len])
        f.close()
      staticSize = getFileInfo(staticFixture).size.int
    except CatchableError as e:
      echo "static fixture unavailable: ", e.msg, " (static routes disabled)"
    let staticRawHeader = "HTTP/1.1 200 OK\r\n" &
      "Content-Type: application/octet-stream\r\n" &
      "Content-Length: " & $staticSize & "\r\n" &
      "Connection: keep-alive\r\n\r\n"
    app.get("/staticraw") do (req: Request, res: Response):
      if res.native.sendFilePreparedResponse(
          staticRawHeader, "benchmark/static16k.bin", staticSize, false):
        res.native.markBodySent()
        res.finished = true
      else:
        res.serverError("sendfile failed")

    if cfg.profile.len > 0:
      echo "profile: ", cfg.profile
    app

let workers = resolveWorkers()
let port = resolvePort()
let scaleMode = resolveScaleMode(workers)

case scaleMode
of "auto":
  echo "nim_express running in auto scale mode on http://localhost:", port
  runAuto(createApp, port, workers)
of "cluster":
  echo "nim_express running in cluster mode on http://localhost:", port
  runCluster(createApp, port, workers)
of "threaded":
  echo "nim_express running with ", workers, " threads on http://localhost:", port
  runThreaded(createApp, port, workers)
else:
  echo "nim_express running on http://localhost:", port
  let app = createApp()
  app.run(port)
