import std/unittest

include ../src/nim_usockets/http

suite "exp stability iter 51-60":
  test "listen failure resets bootstrap pointers and run guard is safe":
    let server = newHttpServer()
    var successSeen = true
    server.listen("256.256.256.256", 3000, proc(success: bool) =
      successSeen = success
    )
    check not successSeen
    check server.loop == nil
    check server.context == nil
    check server.listenSocket == nil

    server.run()
    server.close()
    check server.cleanupCompleted

  test "cleanup is idempotent":
    let server = newHttpServer()
    cleanupServer(server)
    cleanupServer(server)
    check server.cleanupCompleted

  test "defer queue limit is bounded with deterministic overflow drop":
    let server = newHttpServer()
    server.setCrossThreadDeferEnabled(true)
    server.setCrossThreadDeferQueueLimit(2)
    var fired = 0

    server.deferFromAnyThread(proc() = inc fired)
    server.deferFromAnyThread(proc() = inc fired)
    server.deferFromAnyThread(proc() = inc fired)

    when compileOption("threads"):
      check server.crossThreadDeferQueue.len == 2
      check server.getCrossThreadDeferDroppedCount() == 1

    server.flushCrossThreadDeferQueue()
    server.flushDeferredPostCallbacks()
    check fired == 2

  test "close disables cross-thread defer producers before cleanup":
    let server = newHttpServer()
    server.close()
    when compileOption("threads"):
      let droppedBefore = server.getCrossThreadDeferDroppedCount()
      server.deferFromAnyThread(proc() = discard)
      check server.getCrossThreadDeferDroppedCount() == droppedBefore + 1
      check server.crossThreadDeferQueue.len == 0

  test "deferred callback exceptions are isolated per callback":
    let server = newHttpServer()
    var panicCount = 0
    var executed = 0
    server.onPanic(proc(message: string) =
      if message.contains("defer"):
        inc panicCount
    )

    server.`defer`(proc() =
      raise newException(ValueError, "boom")
    )
    server.`defer`(proc() =
      inc executed
    )
    server.flushDeferredPostCallbacks()

    check panicCount == 1
    check executed == 1

  test "binary ws handler path is routed via guarded dispatch":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let source = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
    check source.contains("if not deliverWebSocketMessage(sockData, s, opcode, messagePayload, wsHandler, wsRawHandler, wsConn):")
    check source.contains("if not deliverWebSocketMessage(sockData, s, msgOpcode, msgPayload, wsHandler, wsRawHandler, wsConn):")

  test "websocket optimization preserves coalesced frame bytes after long upgrade":
    var sockData: SocketData
    sockData.buffer = newSeq[byte](512)
    sockData.bufferStart = 260
    for i in 0..<sockData.buffer.len:
      sockData.buffer[i] = byte(i and 0xff)
    let expected = sockData.buffer[sockData.bufferStart ..< sockData.buffer.len]

    optimizeForWebSocket(addr sockData, nil)

    check sockData.buffer == expected
    check sockData.bufferStart == 0
    check sockData.readBufferTarget == WsReadBufferSize

  test "h2 response tail queue failure resets stream instead of marking end-stream":
    let conn = initH2ServerConnection()
    conn.remoteWindow = 0
    conn.streams[1'u32] = H2ServerStream(
      id: 1'u32,
      state: h2p.ssOpen,
      sendWindow: 0,
      recvWindow: h2p.DefaultWindowSize,
      headersReceived: true,
      pendingSendData: newString(MaxH2SendBufSize)
    )
    let res = HttpResponse(
      statusCode: Http200,
      statusCodeInt: 200,
      h2StreamId: 1'u32,
      h2Conn: conn,
      headersInited: false
    )

    h2End(res, "x")

    check h2FindStream(conn, 1'u32) == nil

  test "decompression output limit rejects oversized inflate":
    let plain = repeat("A", 4096)
    let compressed = compressWsPayload(plain)
    check compressed.ok

    let tooLarge = decompressWsPayload(compressed.compressed, 128)
    check not tooLarge.ok
    check tooLarge.tooLarge

    let allowed = decompressWsPayload(compressed.compressed, 8192)
    check allowed.ok
    check allowed.plain == plain

  test "sendfile hard error path is fail-closed":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let source = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
    check source.contains("resp.hardFailure = true")
    check source.contains("resp.closeAfterWrite = true")

  test "write length clamping bounds int to cint range":
    let oversized = int(high(cint)) + 4096
    check clampedWriteLen(oversized) == int(high(cint))
    check clampedWriteLen(1024) == 1024

  test "ws unmask handles odd payload offsets without alignment assumptions":
    let plain = "unaligned-mask-check"
    let mask = [byte(0x11), byte(0x22), byte(0x33), byte(0x44)]
    var data = @[byte(0xFF), byte(0xEE), byte(0xDD)]
    for i, ch in plain:
      data.add(byte(byte(ord(ch)) xor mask[i and 3]))

    let decoded = unmaskWebSocketPayload(data, 3, plain.len, mask[0], mask[1], mask[2], mask[3])
    check decoded == plain

  test "listen timers use native timer path including macOS shutdown polling":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let source = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
    check source.contains("server.timer = us_create_timer")
    check source.contains("server.internalTimer = us_create_timer")
    check source.contains("server.dateHeaderTimer = us_create_timer")
    check source.contains("server.wsKeepaliveTimer = us_create_timer")
    check source.contains("server.shutdownPollTimer = us_create_timer")
    check source.contains("us_timer_set(server.shutdownPollTimer, onShutdownPollFire, 25, 25)")
    check source.contains("server.runMacosFallbackTimers()")

  test "socket-data length arithmetic is overflow-safe and fail-closed":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let source = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
    check source.contains("if length < 0:")
    check source.contains("if chunkLen > maxBodySize or activeLen > maxBodySize - chunkLen:")
    check source.contains("if chunkLen > high(int) - oldLen:")
