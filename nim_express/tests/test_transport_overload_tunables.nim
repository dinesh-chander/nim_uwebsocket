import std/[unittest, os]
import ../src/nim_express/app

suite "Transport and overload tunables":
  test "runtime env applies epoll and adaptive overload knobs":
    let app = newExpressApp()

    putEnv("NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE", "1")
    putEnv("NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER", "1")
    putEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE", "1")
    putEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MIN_BACKLOG_BYTES", "8192")
    putEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MAX_BACKLOG_BYTES", "32768")
    putEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MIN_PENDING_RESPONSES", "8")
    putEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MAX_PENDING_RESPONSES", "64")
    putEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_TIGHTEN_PERCENT", "30")
    putEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_RELAX_PERCENT", "15")
    putEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_COOLDOWN_REQUESTS", "11")

    app.applyRuntimeTunablesFromEnv()

    check app.server.options.listenEpollExclusive
    check app.server.options.listenEpollEdgeTrigger
    check app.server.options.overloadAdaptiveEnabled
    check app.server.options.overloadAdaptiveMinBacklogBytes == 8192
    check app.server.options.overloadAdaptiveMaxBacklogBytes == 32768
    check app.server.options.overloadAdaptiveMinPendingResponses == 8
    check app.server.options.overloadAdaptiveMaxPendingResponses == 64
    check app.server.options.overloadAdaptiveTightenStepPercent == 30
    check app.server.options.overloadAdaptiveRelaxStepPercent == 15
    check app.server.options.overloadAdaptiveCooldownRequests == 11

    delEnv("NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE")
    delEnv("NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER")
    delEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE")
    delEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MIN_BACKLOG_BYTES")
    delEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MAX_BACKLOG_BYTES")
    delEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MIN_PENDING_RESPONSES")
    delEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MAX_PENDING_RESPONSES")
    delEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_TIGHTEN_PERCENT")
    delEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_RELAX_PERCENT")
    delEnv("NIM_EXPRESS_OVERLOAD_ADAPTIVE_COOLDOWN_REQUESTS")
