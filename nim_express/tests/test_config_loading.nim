import std/[unittest, os, times]
import ../src/nim_express/[config, app]

proc tempConfigPath(prefix: string): string =
  getTempDir() / (prefix & "_" & $epochTime().int64 & ".json")

type
  EnvSnapshot = tuple[key: string, had: bool, value: string]

proc snapshotEnv(keys: openArray[string]): seq[EnvSnapshot] =
  for key in keys:
    let had = existsEnv(key)
    result.add((key: key, had: had, value: if had: getEnv(key, "") else: ""))

proc restoreEnv(snapshot: openArray[EnvSnapshot]) =
  for item in snapshot:
    if item.had:
      putEnv(item.key, item.value)
    else:
      delEnv(item.key)

suite "Config loading":
  test "loads grouped section values from json":
    let path = tempConfigPath("nim_express_cfg_sections")
    defer:
      if fileExists(path):
        removeFile(path)

    writeFile(path, """
{
  "server": { "host": "127.0.0.1", "port": 3100, "trustProxy": true },
  "runtime": { "asyncPumpIntervalMs": 7, "maxInflightAsyncRequests": 1234, "contextPoolPrewarm": 77 },
  "socket": { "fastOpen": true, "sendBufferBytes": 65536 },
  "coalesce": { "mode": "throughput", "maxBytes": 131072, "maxResponses": 16 },
  "overload": { "maxBacklogBytes": 2097152, "adaptive": { "enabled": true, "cooldownRequests": 9 } },
  "websocket": {
    "dynamicBackpressureEnabled": true,
    "expectedConnections": 20000,
    "messageBytes": 4096,
    "queueBudgetBytes": 536870912,
    "backpressureHighWaterAction": "drop-oldest",
    "compression": { "enabled": true, "thresholdBytes": 2048 }
  }
}
""")

    let cfg = loadAppEnvConfig(path)
    check cfg.host == "127.0.0.1"
    check cfg.port == 3100
    check cfg.trustProxy
    check cfg.asyncPumpIntervalMs == 7
    check cfg.maxInflightAsyncRequests == 1234
    check cfg.contextPoolPrewarm == 77
    check cfg.socketFastOpen
    check cfg.socketSendBufferBytes == 65536
    check cfg.writeCoalesceMode == wcmThroughput
    check cfg.writeCoalesceMaxBytes == 131072
    check cfg.writeCoalesceMaxResponses == 16
    check cfg.overloadMaxLoopBacklogBytes == 2 * 1024 * 1024
    check cfg.overloadAdaptiveEnabled
    check cfg.overloadAdaptiveCooldownRequests == 9
    check cfg.wsCompressionEnabled
    check cfg.wsCompressionThresholdBytes == 2048
    check cfg.wsDynamicBackpressureEnabled
    check cfg.wsExpectedConnections == 20000
    check cfg.wsMessageBytes == 4096
    check cfg.wsQueueBudgetBytes == 512 * 1024 * 1024
    check cfg.wsBackpressureHighWaterAction == bhwDropOldest

  test "env overrides json values":
    let path = tempConfigPath("nim_express_cfg_env")
    defer:
      if fileExists(path):
        removeFile(path)

    writeFile(path, """
{
  "server": { "port": 3200 },
  "runtime": { "asyncPumpIntervalMs": 10 },
  "socket": { "fastOpen": false }
}
""")

    let envKeys = [
      "NIM_EXPRESS_PORT",
      "NIM_EXPRESS_ASYNC_PUMP_INTERVAL_MS",
      "NIM_EXPRESS_SOCKET_FASTOPEN"
    ]
    let oldVals = snapshotEnv(envKeys)
    defer:
      restoreEnv(oldVals)

    putEnv("NIM_EXPRESS_PORT", "3300")
    putEnv("NIM_EXPRESS_ASYNC_PUMP_INTERVAL_MS", "2")
    putEnv("NIM_EXPRESS_SOCKET_FASTOPEN", "true")

    let cfg = loadAppEnvConfig(path)
    check cfg.port == 3300
    check cfg.asyncPumpIntervalMs == 2
    check cfg.socketFastOpen

  test "falls back to settings.json when config.json is absent":
    let tmpDir = getTempDir() / ("nim_express_cfg_dir_" & $epochTime().int64)
    createDir(tmpDir)
    let cwdBefore = getCurrentDir()
    defer:
      setCurrentDir(cwdBefore)
      let settingsPath = tmpDir / "settings.json"
      if fileExists(settingsPath):
        removeFile(settingsPath)
      if dirExists(tmpDir):
        removeDir(tmpDir)

    setCurrentDir(tmpDir)
    writeFile("settings.json", """
{
  "server": { "host": "127.0.0.9", "port": 3999 },
  "runtime": { "asyncPumpIntervalMs": 3 }
}
""")

    let envKeys = ["NIM_EXPRESS_CONFIG", "NIM_EXPRESS_PORT", "PORT", "HOST"]
    let saved = snapshotEnv(envKeys)
    defer:
      restoreEnv(saved)
    for key in envKeys:
      delEnv(key)

    let cfg = loadAppEnvConfig()
    check cfg.host == "127.0.0.9"
    check cfg.port == 3999
    check cfg.asyncPumpIntervalMs == 3

  test "config.json takes precedence over settings.json in default discovery":
    let tmpDir = getTempDir() / ("nim_express_cfg_precedence_" & $epochTime().int64)
    createDir(tmpDir)
    let cwdBefore = getCurrentDir()
    defer:
      setCurrentDir(cwdBefore)
      let configPath = tmpDir / "config.json"
      let settingsPath = tmpDir / "settings.json"
      if fileExists(configPath):
        removeFile(configPath)
      if fileExists(settingsPath):
        removeFile(settingsPath)
      if dirExists(tmpDir):
        removeDir(tmpDir)

    setCurrentDir(tmpDir)
    writeFile("settings.json", """{ "server": { "port": 4555 } }""")
    writeFile("config.json", """{ "server": { "port": 4666 } }""")

    let envKeys = ["NIM_EXPRESS_CONFIG", "NIM_EXPRESS_PORT", "PORT", "HOST"]
    let saved = snapshotEnv(envKeys)
    defer:
      restoreEnv(saved)
    for key in envKeys:
      delEnv(key)

    let cfg = loadAppEnvConfig()
    check cfg.port == 4666

  test "NIM_EXPRESS_CONFIG points to explicit config path":
    let path = tempConfigPath("nim_express_cfg_explicit_env")
    defer:
      if fileExists(path):
        removeFile(path)
    writeFile(path, """
{
  "server": { "port": 4111 },
  "socket": { "keepAliveSeconds": 45 }
}
""")

    let envKeys = ["NIM_EXPRESS_CONFIG", "NIM_EXPRESS_PORT", "PORT"]
    let saved = snapshotEnv(envKeys)
    defer:
      restoreEnv(saved)
    putEnv("NIM_EXPRESS_CONFIG", path)
    delEnv("NIM_EXPRESS_PORT")
    delEnv("PORT")

    let cfg = loadAppEnvConfig()
    check cfg.port == 4111
    check cfg.socketKeepAliveSeconds == 45

  test "invalid json falls back to defaults and env overrides still apply":
    let path = tempConfigPath("nim_express_cfg_invalid_json")
    defer:
      if fileExists(path):
        removeFile(path)
    writeFile(path, "{ invalid json")

    let envKeys = ["NIM_EXPRESS_PORT", "PORT"]
    let saved = snapshotEnv(envKeys)
    defer:
      restoreEnv(saved)

    putEnv("NIM_EXPRESS_PORT", "3777")
    let cfg = loadAppEnvConfig(path)
    check cfg.port == 3777
    check cfg.host == DefaultEnvHost

  test "profile preset is applied then env overrides selected keys":
    let path = tempConfigPath("nim_express_cfg_profile")
    defer:
      if fileExists(path):
        removeFile(path)
    writeFile(path, """{ "profile": "linux-throughput" }""")

    let envKeys = ["NIM_EXPRESS_SOCKET_FASTOPEN", "NIM_EXPRESS_WRITE_COALESCE_MODE"]
    let saved = snapshotEnv(envKeys)
    defer:
      restoreEnv(saved)
    putEnv("NIM_EXPRESS_SOCKET_FASTOPEN", "false")
    putEnv("NIM_EXPRESS_WRITE_COALESCE_MODE", "latency")

    let cfg = loadAppEnvConfig(path)
    check cfg.profile == "linux-throughput"
    check cfg.listenExclusivePort == false
    check cfg.socketFastOpen == false
    check cfg.writeCoalesceMode == wcmLatency

  test "apply config updates app runtime options":
    let webApp = newExpressApp()
    var cfg = defaultAppEnvConfig()
    cfg.trustProxy = true
    cfg.asyncPumpIntervalMs = 4
    cfg.maxInflightAsyncRequests = 555
    cfg.contextPoolPrewarm = 88
    cfg.socketFastOpen = true
    cfg.wsCompressionEnabled = true
    cfg.wsCompressionThresholdBytes = 1024
    cfg.wsMaxBackpressureBytes = 128 * 1024
    cfg.wsDynamicBackpressureEnabled = true
    cfg.wsExpectedConnections = 20_000
    cfg.wsMessageBytes = 4096
    cfg.wsQueueBudgetBytes = 512 * 1024 * 1024
    cfg.wsBackpressureHighWaterAction = bhwDropNewest

    webApp.applyAppEnvConfig(cfg)
    check webApp.getTrustProxy()
    check webApp.getAsyncPumpIntervalMs() == 4
    check webApp.getMaxInflightAsyncRequests() == 555
    check webApp.getContextPoolPrewarm() == 88
    check webApp.server.options.socketFastOpen
    check webApp.server.options.wsCompressionEnabled
    check webApp.server.options.wsCompressionMinBytes == 1024
    check webApp.server.options.wsDynamicBackpressureEnabled
    check webApp.server.options.wsBackpressureHighWaterBytes == 26_843
    check webApp.server.options.wsBackpressureHighWaterAction == bhwDropNewest
