import ../nim_express/src/nim_express
import ../nim_express/src/nim_express/config

const
  PlainBody = "Hello, World!"
  JsonBody = """{"message":"Hello, World!"}"""

proc createApp(): ExpressApp =
  {.cast(gcsafe).}:
    let app = newExpressApp()
    var cfg = loadAppEnvConfig()
    cfg.port = 3500
    cfg.minimalHeaderParsing = true
    cfg.writeCoalesceMode = wcmThroughput
    cfg.writeCoalesceMaxBytes = 256 * 1024
    cfg.writeCoalesceMaxResponses = 128
    cfg.writeCoalesceThroughputMaxBytes = 256 * 1024
    cfg.writeCoalesceThroughputMaxResponses = 256
    cfg.parseBudgetRequestsPerRead = 512
    cfg.parseBudgetBytesPerRead = 8 * 1024 * 1024
    cfg.loopDispatchBudgetRequests = 4096
    cfg.loopDispatchBudgetBytes = 64 * 1024 * 1024
    cfg.writeBudgetIterationsPerFlush = 512
    cfg.writeBudgetBytesPerFlush = 8 * 1024 * 1024
    cfg.loopWriteBudgetBytes = 64 * 1024 * 1024
    cfg.macosHighQos = true
    cfg.socketNoDelay = false
    cfg.socketKeepAlive = true
    cfg.socketKeepAliveSeconds = 60
    cfg.socketSendBufferBytes = 512 * 1024
    cfg.socketRecvBufferBytes = 256 * 1024
    cfg.socketNotSentLowWaterBytes = 128 * 1024
    cfg.overloadMaxLoopBacklogBytes = 64 * 1024 * 1024
    cfg.overloadMaxPendingResponses = 16384
    app.applyAppEnvConfig(cfg)
    app.generateCorrelationIds = false

    app.get("/plaintext") do (req: Request, res: Response):
      res.text(PlainBody)

    app.get("/json") do (req: Request, res: Response):
      res.jsonRaw(JsonBody)

    app.get("/headers") do (req: Request, res: Response):
      res.set("x-bench-1", "value1")
      res.set("x-bench-2", "value2")
      res.set("x-bench-3", "value3")
      res.set("x-bench-4", "value4")
      res.set("x-bench-5", "value5")
      res.set("x-bench-6", "value6")
      res.set("x-bench-7", "value7")
      res.set("x-bench-8", "value8")
      res.set("x-bench-9", "value9")
      res.set("x-bench-10", "value10")
      res.text(PlainBody)

    app.post("/echo") do (req: Request, res: Response):
      let body = req.rawBody()
      res.send(body)

    app

echo "bench_e2e_server starting on http://localhost:3500"
let app = createApp()
app.run(3500)
