import std/unittest

include ../src/nim_usockets/http

suite "Overload and transport stability":
  test "adaptive overload controller tightens and relaxes within safety bounds":
    let server = newHttpServer()
    server.setOverloadController(maxBacklogBytes = 1000, maxPendingResponses = 10, closeOnReject = false)
    server.setAdaptiveOverloadController(
      enabled = true,
      minBacklogBytes = 400,
      maxBacklogBytes = 1000,
      minPendingResponses = 3,
      maxPendingResponses = 10,
      tightenStepPercent = 50,
      relaxStepPercent = 25,
      cooldownRequests = 2
    )

    var sockData: SocketData
    sockData.server = server
    sockData.pendingBytes = 1500
    sockData.pendingSlots = @[]
    sockData.pendingUsed = @[]

    check shouldRejectForOverload(addr sockData)
    check shouldRejectForOverload(addr sockData)
    check server.overloadAdaptiveBacklogLimit <= 500
    check server.overloadAdaptiveBacklogLimit >= 400

    for _ in 0 ..< 12:
      discard shouldRejectForOverload(addr sockData)
    check server.overloadAdaptiveBacklogLimit == 400

    sockData.pendingBytes = 0
    for _ in 0 ..< 4:
      check not shouldRejectForOverload(addr sockData)
    check server.overloadAdaptiveBacklogLimit > 400
    check server.overloadAdaptiveBacklogLimit <= 1000

  test "listen options encode exclusive and epoll policies as bit flags":
    let server = newHttpServer()
    check computeListenOptions(server).int == LibusListenOptionDefault

    server.options.listenExclusivePort = true
    server.options.listenEpollExclusive = true
    server.options.listenEpollEdgeTrigger = true
    server.options.socketFastOpen = true
    let encoded = computeListenOptions(server).int
    check (encoded and LibusListenOptionExclusivePort) != 0
    check (encoded and LibusListenOptionEpollExclusive) != 0
    check (encoded and LibusListenOptionEpollEdgeTrigger) != 0
    check (encoded and LibusListenOptionTcpFastOpen) != 0

  test "socket tunable outcomes are tracked and warnings are deduplicated":
    let server = newHttpServer()
    var errors: seq[string] = @[]
    server.onError(proc(message: string) =
      errors.add(message)
    )

    recordSocketTunableResult(server, "TCP_NODELAY", 0)
    check server.getSocketTunableAppliedCount() == 1

    var unsupportedErr: cint = 0
    when declared(ENOPROTOOPT):
      unsupportedErr = ENOPROTOOPT
    elif declared(EOPNOTSUPP):
      unsupportedErr = EOPNOTSUPP
    elif declared(ENOTSUP):
      unsupportedErr = ENOTSUP

    if unsupportedErr != 0:
      recordSocketTunableResult(server, "TCP_TEST_UNSUPPORTED", unsupportedErr)
      recordSocketTunableResult(server, "TCP_TEST_UNSUPPORTED", unsupportedErr)
      check server.getSocketTunableUnsupportedCount() == 2
      check errors.len == 1

    recordSocketTunableResult(server, "TCP_TEST_FAILED", 12345)
    recordSocketTunableResult(server, "TCP_TEST_FAILED", 12345)
    check server.getSocketTunableFailedCount() == 2
    if unsupportedErr != 0:
      check errors.len == 2
    else:
      check errors.len == 1

  test "io_uring backend sources do not contain crash stubs":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let ioSocket = readFile(repoRoot / "nim_usockets/usockets/src/io_uring/io_socket.c")
    let ioContext = readFile(repoRoot / "nim_usockets/usockets/src/io_uring/io_context.c")
    let ioLoop = readFile(repoRoot / "nim_usockets/usockets/src/io_uring/io_loop.c")
    let httpSource = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")

    check "exit(1);" notin ioSocket
    check "exit(1);" notin ioContext
    check "exit(1);" notin ioLoop

    check "void us_socket_context_close(int ssl, struct us_socket_context_t *context) {\n\n}" notin ioContext
    check "struct us_socket_t *us_socket_close(int ssl, struct us_socket_t *s, int code, void *reason) {\n    return s;\n}" notin ioSocket
    check "void us_loop_free(struct us_loop_t *loop) {\n\n}" notin ioLoop
    check "linuxSendfile(" in httpSource
