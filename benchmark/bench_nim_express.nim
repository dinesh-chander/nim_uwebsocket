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

    let staticBody = readFile("bench-results/static16k.bin")
    app.get("/static") do (req: Request, res: Response):
      res.contentType("application/octet-stream")
      res.send(staticBody)

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
