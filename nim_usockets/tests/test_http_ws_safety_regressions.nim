import std/unittest

include ../src/nim_usockets/http

proc bytesToString(data: seq[byte]): string =
  result = newString(data.len)
  for i in 0..<data.len:
    result[i] = char(data[i])

proc stringToBytes(data: string): seq[byte] =
  result = newSeq[byte](data.len)
  for i in 0 ..< data.len:
    result[i] = byte(data[i])

proc buildMaskedClientFrame(
  opcode: int,
  payload: string,
  fin: bool = true,
  mask: array[4, byte] = [0x37'u8, 0xfa, 0x21, 0x3d]
): seq[byte] =
  var byte1 = opcode and 0x0F
  if fin:
    byte1 = byte1 or 0x80
  result.add(byte(byte1))
  result.add(byte(0x80 or payload.len))
  for b in mask:
    result.add(b)
  for i in 0 ..< payload.len:
    result.add(byte(payload[i]) xor mask[i mod 4])

suite "HTTP/WS safety regressions":
  test "H2 pseudo headers reject unknown methods and map CONNECT/TRACE explicitly":
    check not h2ValidatePseudoHeaders(@[
      (":method", "FOO"),
      (":path", "/"),
      (":scheme", "https"),
      (":authority", "example.test")
    ])
    check h2ValidatePseudoHeaders(@[
      (":method", "TRACE"),
      (":path", "/"),
      (":scheme", "https"),
      (":authority", "example.test")
    ])
    check h2ValidatePseudoHeaders(@[
      (":method", "CONNECT"),
      (":authority", "example.test:443")
    ])
    check h2MethodKind("CONNECT") == hmConnect
    check h2MethodKind("TRACE") == hmTrace

  test "H2 pseudo headers reject duplicate authority":
    check not h2ValidatePseudoHeaders(@[
      (":method", "GET"),
      (":path", "/"),
      (":scheme", "https"),
      (":authority", "first.example"),
      (":authority", "second.example")
    ])
    check not h2ValidatePseudoHeaders(@[
      (":method", "CONNECT"),
      (":authority", "first.example:443"),
      (":authority", "second.example:443")
    ])

  test "H2 prior-knowledge sniffing requires exact PRI prefix":
    check hasH2PriorKnowledgePrefix(stringToBytes("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"), 0)
    check not hasH2PriorKnowledgePrefix(stringToBytes("FOO / HTTP/1.1\r\n\r\n"), 0)
    check not hasH2PriorKnowledgePrefix(stringToBytes("PRI* / HTTP/1.1\r\n\r\n"), 0)
    check not hasH2PriorKnowledgePrefix(stringToBytes("\x00\x00\x00\x04"), 0)

  test "compactSocketBuffer preserves unread bytes under overlap":
    var sockData: SocketData
    sockData.buffer = @[]
    for ch in "0123456789":
      sockData.buffer.add(byte(ch))
    sockData.bufferStart = 3

    compactSocketBuffer(addr sockData)

    check sockData.bufferStart == 0
    check sockData.buffer.len == 7
    check bytesToString(sockData.buffer) == "3456789"

  test "compactH2ReadBuffer releases fully consumed H2 input":
    var sockData: SocketData
    sockData.server = newHttpServer()
    sockData.buffer = @[]
    for i in 0 ..< 100_000:
      sockData.buffer.add(byte(i and 0xFF))
    sockData.bufferStart = sockData.buffer.len

    compactH2ReadBuffer(addr sockData)

    check sockData.bufferStart == 0
    check sockData.buffer.len == 0

  test "H2 end headers use one computed content-length":
    let res = acquireHttpResponse()
    defer: releaseHttpResponse(res)
    setStatus(res, Http200)
    res.setHeader("Content-Length", "999")

    var manualHeaders = h2BuildResponseHeaders(res)
    var manualCount = 0
    for header in manualHeaders:
      if header[0] == HeaderContentLength:
        inc manualCount
        check header[1] == "999"
    check manualCount == 1

    var endHeaders = h2BuildResponseHeaders(res, includeContentLength = false)
    endHeaders.add((HeaderContentLength, "4"))
    var endCount = 0
    for header in endHeaders:
      if header[0] == HeaderContentLength:
        inc endCount
        check header[1] == "4"
    check endCount == 1

  test "retained response snapshots request before pool reuse":
    let req = acquireHttpRequest()
    req.path = "/first"
    req.queryStringRaw = "id=1"
    req.httpVersion = HttpVersion11
    req.httpMajor = 1
    req.httpMinor = 1
    req.methodKind = hmGet
    req.remoteIp = "198.51.100.10"
    req.headers = newFastMap[string]()
    req.headers["host"] = "first.example"
    req.headers["origin"] = "https://first.example"

    let res = acquireHttpResponse()
    res.requestRef = req
    res.requestMethod = req.methodKind
    res.requestIsHttp11 = true

    retainHttpResponse(res)
    releaseHttpResponse(res)
    recycleHttpRequest(req)

    let reused = acquireHttpRequest()
    reused.path = "/second"
    reused.remoteIp = "203.0.113.20"

    let snapshot = res.requestHandle()
    check snapshot != nil
    check snapshot.path == "/first"
    check snapshot.queryStringRaw == "id=1"
    check snapshot.remoteIp == "198.51.100.10"
    check snapshot.headers.getOrDefault("host", "") == "first.example"
    check snapshot.headers.getOrDefault("origin", "") == "https://first.example"

    recycleHttpRequest(reused)
    releaseHttpResponse(res)

  test "H2 chunked stream queues stalled DATA without ending stream":
    resetSocketFaultInjectionForTest()
    let conn = initH2ServerConnection()
    conn.remoteWindow = 0
    conn.streams[1'u32] = H2ServerStream(
      id: 1'u32,
      state: h2p.ssOpen,
      sendWindow: 0,
      recvWindow: h2p.DefaultWindowSize
    )
    var res: HttpResponse
    new(res)
    res.h2Conn = conn
    res.h2StreamId = 1
    res.ssl = 0
    res.socket = cast[UsSocketPtr](cast[pointer](0x101))

    check h2WriteChunkedStream(res, "abc")
    var streamPtr = h2FindStream(conn, 1)
    check streamPtr != nil
    check streamPtr.pendingSendData == "abc"
    check not streamPtr.pendingSendEndStream

    conn.remoteWindow = 64
    streamPtr.sendWindow = 64
    setInjectedWriteResultsForTest([12])
    h2FlushPendingSendData(conn, 1)
    streamPtr = h2FindStream(conn, 1)
    check streamPtr != nil
    check streamPtr.pendingSendData.len == 0
    check not streamPtr.endStreamSent
    resetSocketFaultInjectionForTest()

  test "H2 finish waits for pending chunked DATA before END_STREAM":
    resetSocketFaultInjectionForTest()
    let conn = initH2ServerConnection()
    conn.remoteWindow = 0
    conn.streams[3'u32] = H2ServerStream(
      id: 3'u32,
      state: h2p.ssOpen,
      sendWindow: 0,
      recvWindow: h2p.DefaultWindowSize
    )
    var res: HttpResponse
    new(res)
    res.h2Conn = conn
    res.h2StreamId = 3
    res.ssl = 0
    res.socket = cast[UsSocketPtr](cast[pointer](0x103))

    check h2WriteChunkedStream(res, "xyz")
    check h2FinishChunkedStream(res)
    var streamPtr = h2FindStream(conn, 3)
    check streamPtr != nil
    check streamPtr.pendingSendData == "xyz"
    check streamPtr.pendingSendEndStream

    conn.remoteWindow = 64
    streamPtr.sendWindow = 64
    setInjectedWriteResultsForTest([12])
    h2FlushPendingSendData(conn, 3)
    check h2FindStream(conn, 3) == nil
    resetSocketFaultInjectionForTest()

  test "setHeader rejects invalid names and unsafe values":
    var res: HttpResponse
    new(res)
    res.headersInited = false

    res.setHeader("X-Good", "ok")
    check res.headersInited
    check res.headers.getOrDefault("x-good", "") == "ok"

    # Space is not a valid token character for header names.
    res.setHeader("Bad Header", "blocked")
    check res.headers.getOrDefault("bad header", "") == ""

    # CR/LF in values must be rejected to avoid response splitting.
    res.setHeader("X-Injected", "ok\r\nX-Other: bad")
    check res.headers.getOrDefault("x-injected", "") == ""

  test "before-write callback failures route through panic handler":
    let server = newHttpServer()
    var panicCount = 0
    var panicMessage = ""

    server.onPanic(proc(message: string) =
      inc panicCount
      panicMessage = message
    )
    server.onBeforeWrite(proc(bytes: int, isWebSocket: bool) =
      discard bytes
      discard isWebSocket
      raise newException(ValueError, "before-write boom")
    )

    server.emitBeforeWrite(64, false)

    check panicCount == 1
    check panicMessage.contains("beforeWriteHandler")

  test "high-water reclaim keeps control frames when requested":
    var sockData: SocketData
    sockData.wsOutHead = 0
    sockData.wsOutPos = 0
    sockData.wsOutPalette = @["PING", "DATA"]
    sockData.wsOutPaletteRefs = @[1, 1]
    sockData.wsOutPaletteFree = @[]
    sockData.wsOutQueue = @[
      WsQueuedFrame(paletteIdx: 0, frameOffset: 0, payloadBytes: 0, isBinary: false, isControl: true),
      WsQueuedFrame(paletteIdx: 1, frameOffset: 0, payloadBytes: 4, isBinary: false, isControl: false)
    ]
    sockData.wsPendingBytes = 8

    let reclaimed = reclaimWsQueuedBytesOldest(
      addr sockData,
      nil,
      4,
      preserveControlFrames = true
    )

    check reclaimed == 4
    check sockData.wsPendingBytes == 4
    check sockData.wsOutQueue[0].paletteIdx == 0
    check sockData.wsOutQueue[1].paletteIdx < 0

  test "dynamic websocket backpressure budget derives bounded high-water":
    check wsBackpressureHighWaterFromBudget(
      expectedConnections = 20_000,
      messageBytes = 4096,
      queueBudgetBytes = 512 * 1024 * 1024,
      maxBackpressureBytes = 128 * 1024
    ) == 26_843
    check wsBackpressureHighWaterFromBudget(0, 4096, 512 * 1024 * 1024) == 0

    let server = newHttpServer()
    server.setWsDynamicBackpressure(
      enabled = true,
      expectedConnections = 20_000,
      messageBytes = 4096,
      queueBudgetBytes = 512 * 1024 * 1024,
      action = bhwDropOldest,
      closeOnBackpressureLimit = false
    )
    check server.options.wsDynamicBackpressureEnabled
    check server.options.wsExpectedConnections == 20_000
    check server.options.wsMessageBytes == 4096
    check server.options.wsQueueBudgetBytes == 512 * 1024 * 1024
    check server.options.wsBackpressureHighWaterBytes == 26_843
    check server.options.wsBackpressureHighWaterAction == bhwDropOldest
    check not server.options.wsCloseOnBackpressureLimit

  test "small websocket direct path queues behind existing backpressure":
    let state = wsSmallFrameQueuesBehindBackpressureForTest()
    check state.queued == 2
    check state.pendingBytes > 0
    check state.firstPayload == 5
    check state.secondPayload == 1
    check state.secondIsControl

  test "coalesced websocket continuation is delivered after zero-copy first fragment":
    let server = newHttpServer()
    var messages: seq[string] = @[]
    var binaryFlags: seq[bool] = @[]
    server.onWebSocket(proc(ws: WebSocket, message: string, isBinary: bool) =
      discard ws
      messages.add(message)
      binaryFlags.add(isBinary)
    )

    var sockData: SocketData
    sockData.server = server
    sockData.flags = SDF_IS_WEBSOCKET
    sockData.ws = WebSocket(
      socket: cast[UsSocketPtr](cast[pointer](0x5151)),
      ssl: 0,
      isOpen: true,
      server: server
    )
    sockData.buffer = buildMaskedClientFrame(0x1, "he", fin = false) &
      buildMaskedClientFrame(0x0, "llo", fin = true)

    handleWebSocketData(addr sockData, sockData.ws.socket)

    check messages == @["hello"]
    check binaryFlags == @[false]
    check sockData.wsFragmentOpcode == 0
    check sockData.wsFragmentPayload.len == 0
    check sockData.buffer.len == 0

  test "raw websocket handler receives direct and fragmented messages":
    let server = newHttpServer()
    var payloadLens: seq[int] = @[]
    var payloads: seq[string] = @[]
    var binaryFlags: seq[bool] = @[]
    server.onWebSocketRaw(proc(ws: WebSocket, data: pointer, dataLen: int, isBinary: bool) =
      discard ws
      payloadLens.add(dataLen)
      binaryFlags.add(isBinary)
      var copied = newString(dataLen)
      if dataLen > 0:
        copyMem(addr copied[0], data, dataLen)
      payloads.add(copied)
    )

    var sockData: SocketData
    sockData.server = server
    sockData.flags = SDF_IS_WEBSOCKET
    sockData.ws = WebSocket(
      socket: cast[UsSocketPtr](cast[pointer](0x6161)),
      ssl: 0,
      isOpen: true,
      server: server
    )
    sockData.buffer = buildMaskedClientFrame(0x2, "abc", fin = true) &
      buildMaskedClientFrame(0x1, "he", fin = false) &
      buildMaskedClientFrame(0x0, "llo", fin = true)

    handleWebSocketData(addr sockData, sockData.ws.socket)

    check payloadLens == @[3, 5]
    check payloads == @["abc", "hello"]
    check binaryFlags == @[true, false]
    check sockData.wsFragmentOpcode == 0
    check sockData.wsFragmentPayload.len == 0
    check sockData.buffer.len == 0

  test "raw-only websocket apps are eligible for HTTP upgrade":
    let repoRoot = currentSourcePath().parentDir.parentDir
    let source = readFile(repoRoot / "src/nim_usockets/http.nim")
    check source.contains(
      "if (server.wsHandler != nil or server.wsRawHandler != nil) and req.isWebSocketUpgrade:"
    )

  test "sendPtr frame fallback preserves pointer payload bytes":
    let payload = "pointer-payload"
    let frame = buildWsFrameFromPtr(
      wsText,
      cast[pointer](unsafeAddr payload[0]),
      payload.len,
      false
    )

    check frame.len == 2 + payload.len
    check frame[0] == char(0x80 or ord(wsText))
    check frame[1] == char(payload.len)
    check frame[2 .. ^1] == payload

  test "incomplete HTTP/1 headers trip byte limit before terminator":
    let raw = "GET / HTTP/1.1\r\nHost: example\r\nX-Fill: " & repeat("a", 64)
    check incompleteHeaderExceedsLimitForTest(raw, 48)
    check not incompleteHeaderExceedsLimitForTest(raw & "\r\n\r\n", 48)

  test "protocol error response builder includes transformed body and keep-alive flag":
    let body = """{"error":"bad request"}"""
    let response = buildProtocolErrorResponse(422, body, closeConnection = false)
    check response.startsWith("HTTP/1.1 422 Unprocessable Content\r\n")
    check response.contains("content-length: " & $body.len & "\r\n")
    check response.contains("connection: keep-alive\r\n")
    check response.endsWith("\r\n" & body)

  test "protocol error send path does not append transformed body twice":
    let repoRoot = currentSourcePath().parentDir.parentDir
    let source = readFile(repoRoot / "src/nim_usockets/http.nim")
    check not source.contains(
      "buildProtocolErrorResponse(finalStatus, responseBody, closeConnection),\n              responseBody,"
    )
    check source.contains(
      "buildProtocolErrorResponse(finalStatus, responseBody, closeConnection),\n              \"\","
    )

  test "parse-error quarantine consumes at least one unread byte":
    check parseErrorQuarantineBytes(0, 0) == 0
    check parseErrorQuarantineBytes(0, 1) == 1
    check parseErrorQuarantineBytes(0, 16) == 1
    check parseErrorQuarantineBytes(4, 16) == 4
    check parseErrorQuarantineBytes(32, 8) == 8

  test "parse-error keep-alive path quarantines bytes before next parse":
    let repoRoot = currentSourcePath().parentDir.parentDir
    let source = readFile(repoRoot / "src/nim_usockets/http.nim")
    check source.contains(
      "let quarantineBytes = parseErrorQuarantineBytes(totalRequestSize, unreadAtParsePos)"
    )
    check source.contains("if sockData.buffer.len > sockData.bufferStart + consumed:")
    check source.contains("scheduleResume = true")

  test "request spill-file cleanup removes trusted files only":
    let suffix = $int64(epochTime() * 1_000_000.0)
    let trustedRoot = getTempDir() / ("nim_uws_spill_trusted_" & suffix)
    let trustedFile = trustedRoot / "body.tmp"
    createDir(trustedRoot)
    writeFile(trustedFile, "abc")

    var trustedReq: HttpRequest
    new(trustedReq)
    trustedReq.bodyInFile = true
    trustedReq.bodyFilePath = trustedFile
    trustedReq.bodyFileRoot = trustedRoot
    cleanupRequestSpillFile(trustedReq)
    check not fileExists(trustedFile)
    check not trustedReq.bodyInFile
    check trustedReq.bodyFilePath.len == 0

    let untrustedRoot = getTempDir() / ("nim_uws_spill_untrusted_root_" & suffix)
    let untrustedFileDir = getTempDir() / ("nim_uws_spill_untrusted_file_" & suffix)
    let untrustedFile = untrustedFileDir / "body.tmp"
    createDir(untrustedRoot)
    createDir(untrustedFileDir)
    writeFile(untrustedFile, "xyz")

    var untrustedReq: HttpRequest
    new(untrustedReq)
    untrustedReq.bodyInFile = true
    untrustedReq.bodyFilePath = untrustedFile
    untrustedReq.bodyFileRoot = untrustedRoot
    cleanupRequestSpillFile(untrustedReq)
    check fileExists(untrustedFile)
    check not untrustedReq.bodyInFile
    check untrustedReq.bodyFilePath.len == 0

    removeFile(untrustedFile)
    removeDir(trustedRoot)
    removeDir(untrustedRoot)
    removeDir(untrustedFileDir)

  test "cross-thread defer gateway queues and flushes callbacks":
    let server = newHttpServer()
    server.setCrossThreadDeferEnabled(true)
    var fired = 0

    server.deferFromAnyThread(proc() =
      inc fired
    )

    when compileOption("threads"):
      check server.crossThreadDeferQueue.len == 1
    server.flushCrossThreadDeferQueue()
    when compileOption("threads"):
      check server.crossThreadDeferQueue.len == 0
    check server.deferredCallbacks.len == 1
    server.flushDeferredPostCallbacks()
    check fired == 1

  test "phase timeout mapping and metadata callbacks are explicit":
    let server = newHttpServer()
    server.setPhaseTimeouts(
      headerReadMs = 1200,
      bodyReadMs = 2300,
      handlerExecMs = 3400,
      writeDrainMs = 4500
    )
    server.setWsIdleTimeout(9)

    check phaseTimeoutMillisFor(server, "header_read") == 1200
    check phaseTimeoutMillisFor(server, "body_read") == 2300
    check phaseTimeoutMillisFor(server, "handler_exec") == 3400
    check phaseTimeoutMillisFor(server, "write_drain") == 4500
    check phaseTimeoutMillisFor(server, "websocket_idle") == 9000

    var timedKind = ""
    var timedIp = ""
    var metaKind = ""
    var metaPhase = ""
    var metaIp = ""
    var metaSeq = 0'u64
    var metaWs = false
    server.onTimeout(proc(kind: string, remoteIp: string) =
      timedKind = kind
      timedIp = remoteIp
    )
    server.onTimeoutMetadata(proc(
      kind: string,
      phase: string,
      remoteIp: string,
      requestSeq: uint64,
      isWebSocket: bool
    ) =
      metaKind = kind
      metaPhase = phase
      metaIp = remoteIp
      metaSeq = requestSeq
      metaWs = isWebSocket
    )

    var sockData: SocketData
    sockData.server = server
    sockData.remoteIp = "127.0.0.1"
    sockData.activeRequestSeq = 77'u64
    sockData.isWebSocket = true
    emitTimeoutCallbacks(addr sockData, "write_drain", "write_drain")

    check timedKind == "write_drain"
    check timedIp == "127.0.0.1"
    check metaKind == "write_drain"
    check metaPhase == "write_drain"
    check metaIp == "127.0.0.1"
    check metaSeq == 77'u64
    check metaWs
    check timeoutPhaseFromLabel("handler_exec") == tpHandlerExec
    check timeoutPhaseLabel(tpWriteDrain) == "write_drain"
    check timeoutKindLabel(tpNone) == "http_connection"
    var phaseState: SocketData
    phaseState.timeoutPhase = tpHeaderRead
    phaseState.activeRequestSeq = 5'u64
    phaseState.timeoutPhaseSeconds = 2
    check not shouldUpdateSocketTimeoutPhase(addr phaseState, tpHeaderRead, 5'u64, 2)
    check shouldUpdateSocketTimeoutPhase(addr phaseState, tpHeaderRead, 6'u64, 2)
    check shouldUpdateSocketTimeoutPhase(addr phaseState, tpWriteDrain, 5'u64, 2)
    check shouldUpdateSocketTimeoutPhase(addr phaseState, tpHeaderRead, 5'u64, 3)

    let disabledServer = newHttpServer()
    disabledServer.options.connectionTimeout = 0
    disabledServer.setPhaseTimeouts(0, 0, 0, 0)
    var disabledState: SocketData
    disabledState.server = disabledServer
    check phaseTimeoutSecondsFor(addr disabledState, tpHeaderRead) == 0
    check phaseTimeoutSecondsFor(addr disabledState, tpHandlerExec) == 0

  test "overload reason classification and graceful shutdown metrics":
    let overloadServer = newHttpServer()
    overloadServer.setOverloadController(
      maxBacklogBytes = 32,
      maxPendingResponses = 2,
      closeOnReject = false
    )
    overloadServer.setOverloadRetryAfter(3)
    check overloadServer.options.overloadRetryAfterSeconds == 3

    var overloadedSocket: SocketData
    overloadedSocket.server = overloadServer
    overloadedSocket.pendingBytes = 40
    overloadedSocket.pendingSlots = @[]
    check overloadRejectReasonFor(addr overloadedSocket) == orrBacklog

    overloadedSocket.pendingBytes = 0
    overloadedSocket.pendingSlots = newSeq[QueuedResponse](8)
    overloadedSocket.pendingUsed = @[false, true, false, false, true, false, false, false]
    overloadedSocket.pendingActiveCount = 0
    check overloadRejectReasonFor(addr overloadedSocket) == orrNone

    overloadedSocket.pendingUsed[7] = true
    overloadedSocket.pendingActiveCount = 0
    check overloadRejectReasonFor(addr overloadedSocket) == orrPending

    let drainedServer = newHttpServer()
    drainedServer.connectionCount = 2
    drainedServer.setGracefulShutdownDrainMs(100)
    beginShutdown(drainedServer)
    drainedServer.connectionCount = 0
    beginShutdown(drainedServer)
    check drainedServer.getShutdownDrainedConnectionCount() == 2

    let forcedServer = newHttpServer()
    forcedServer.connectionCount = 3
    forcedServer.setGracefulShutdownDrainMs(1)
    beginShutdown(forcedServer)
    forcedServer.shutdownForceCloseAtMs = nowEpochMs() - 1
    beginShutdown(forcedServer)
    check forcedServer.getShutdownForcedConnectionCount() >= 3

  test "overload rejection close policy is deterministic on short writes":
    check shouldCloseAfterOverloadWrite(true, 0, 64)
    check shouldCloseAfterOverloadWrite(false, 63, 64)
    check shouldCloseAfterOverloadWrite(false, -1, 64)
    check not shouldCloseAfterOverloadWrite(false, 64, 64)
    check not shouldCloseAfterOverloadWrite(false, 80, 64)
    check shouldCloseAfterOverloadWrite(false, 0, 0)
    check shouldCloseAfterOverloadWrite(false, 0, -1)

  test "pending stream close intent latches only on stream finish":
    var sockData: SocketData
    check enqueuePendingResponse(
      addr sockData,
      0'u64,
      QueuedResponse(
        isStreamBody: true,
        streamOpen: true,
        hasTryEnd: true,
        tryEndOffset: 0'u64,
        tryEndTotal: 8'u64
      )
    )
    check sockData.pendingSlots.len == 1
    check sockData.pendingSlots[0].closeAfterWrite == false

    # Mid-stream chunks must not close the socket yet.
    check appendPendingStreamChunk(addr sockData, 0'u64, "abc", finishStream = false, closeAfterWrite = true)
    check sockData.pendingSlots[0].streamOpen
    check sockData.pendingSlots[0].closeAfterWrite == false

    # Final chunk can safely latch close-after-write for pending drain.
    check appendPendingStreamChunk(addr sockData, 0'u64, "", finishStream = true, closeAfterWrite = true)
    check sockData.pendingSlots[0].streamOpen == false
    check sockData.pendingSlots[0].closeAfterWrite

  when defined(macosx):
    test "macOS fallback maintenance blocks nested re-entry":
      let server = newHttpServer()
      var preRuns = 0
      server.deferPre(proc() =
        inc preRuns
      )
      let entered = beginMacosFallbackMaintenance(server)
      check entered
      let nested = beginMacosFallbackMaintenance(server)
      check not nested
      endMacosFallbackMaintenance(server, entered)
      check preRuns == 1

  test "loop-affinity mismatch raises deterministic debug defect":
    when not defined(release):
      let server = newHttpServer()
      server.bindLoopOwner()
      server.loopOwnerThreadId = server.loopOwnerThreadId xor 1'u64
      expect Defect:
        server.`defer`(proc() = discard)

  test "cross-thread defer disabled reroutes safely with deduplicated warning":
    let server = newHttpServer()
    server.setCrossThreadDeferEnabled(false)
    var errors = 0
    var fired = 0
    server.onError(proc(message: string) =
      discard message
      inc errors
    )

    server.deferFromAnyThread(proc() = inc fired)
    server.deferFromAnyThread(proc() = inc fired)

    when compileOption("threads"):
      check server.getCrossThreadDeferViolationCount() == 2
      check server.getCrossThreadDeferReroutedCount() == 2
      check server.crossThreadDeferQueue.len == 2
      check server.crossThreadDeferPreQueue.len == 1
      check server.crossThreadDeferWakePending
      check errors == 0

    server.flushCrossThreadDeferQueue()
    when compileOption("threads"):
      check server.crossThreadDeferQueue.len == 0
      check server.crossThreadDeferPreQueue.len == 0
      check not server.crossThreadDeferWakePending
    server.flushDeferredPreCallbacks()
    check errors == 1
    server.flushDeferredPostCallbacks()
    check fired == 2

  test "shutdown signal flags are atomic and idempotent":
    resetShutdownSignalFlags()
    check not loadShutdownRequested()
    check not loadForceExitRequested()

    markShutdownSignalRequested()
    check loadShutdownRequested()
    check loadForceExitRequested()

    setForceExitRequested(false)
    check loadShutdownRequested()
    check not loadForceExitRequested()

    resetShutdownSignalFlags()
    check not loadShutdownRequested()
    check not loadForceExitRequested()

  test "close outcome observability tracks attempts failures and warnings":
    let server = newHttpServer()
    var errors: seq[string] = @[]
    server.onError(proc(message: string) =
      errors.add(message)
    )

    recordSocketCloseOutcome(server, "unit_close_path", false)
    recordSocketCloseOutcome(server, "unit_close_path", false)
    recordSocketCloseOutcome(server, "unit_close_path", true)

    check server.getSocketCloseAttemptCount() == 3
    check server.getSocketCloseFailureCount() == 2
    let snapshot = server.socketCloseOutcomeSnapshot()
    check snapshot.getOrDefault("fail:unit_close_path", -1'i64) == 2
    check snapshot.getOrDefault("ok:unit_close_path", -1'i64) == 1
    check errors.len == 1

  test "listen failure callback exceptions route through panic handler":
    let server = newHttpServer()
    var callbackInvoked = false
    var panicCount = 0
    var panicMessage = ""
    server.onPanic(proc(message: string) =
      inc panicCount
      panicMessage = message
    )

    server.listen("256.256.256.256", 3000, proc(success: bool) =
      callbackInvoked = true
      if not success:
        raise newException(ValueError, "listen callback failure")
    )

    check callbackInvoked
    check panicCount == 1
    check panicMessage.contains("listenCallback")

  test "spill pressure hysteresis contributes to overload reject classification":
    let server = newHttpServer()
    server.setOverloadController(maxBacklogBytes = 256, maxPendingResponses = 4, closeOnReject = false)
    server.setSpillPressureController(rejectThreshold = 2, recoverThreshold = 0)

    var sockData: SocketData
    sockData.server = server
    sockData.pendingBytes = 0
    sockData.pendingSlots = @[]
    sockData.pendingUsed = @[]
    sockData.pendingActiveCount = 0

    check overloadRejectReasonFor(addr sockData) == orrNone
    noteSpillPressureDrop(server)
    noteSpillPressureDrop(server)
    check overloadRejectReasonFor(addr sockData) == orrBacklog
    check overloadRejectReasonFor(addr sockData) == orrNone

  test "callback routing relies on loop and timer bound server state":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let source = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
    check not source.contains("globalServer = ")
    check source.contains("let server = resolveServerFromLoop(loop)")
    check source.contains("let server = resolveServerFromTimer(timer)")
    check source.contains("let server = resolveServerFromSocket(s)")
    check source.contains("bindTimerServer(server.wsKeepaliveTimer, server)")
    check source.contains("runWsKeepalive(resolveServerFromTimer(timer))")
    check source.contains("server.wsKeepaliveCursor")
    # Regression guard: the per-tick keepalive sweep must NOT reintroduce the
    # redundant per-connection wsKey() string format + websocketSet.contains
    # probe (that was the PARENT-VERIFIED allocation hot spot removed from
    # runWsKeepalive; the seq + isOpen/socket guards are authoritative instead).
    check not source.contains("key.len == 0 or server.websocketSet == nil or server.websocketSet.contains(key)")
    check resolveServerFromLoop(nil) == nil
    check resolveServerFromTimer(nil) == nil
    check resolveServerFromSocket(nil) == nil

  when defined(macosx):
    test "macOS listen path uses native timers with fallback guards":
      let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
      let source = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
      check source.contains("server.dateHeaderTimer = us_create_timer")
      check source.contains("server.wsKeepaliveTimer = us_create_timer")
      check source.contains("server.shutdownPollTimer = us_create_timer")
      check source.contains("us_timer_set(server.shutdownPollTimer, onShutdownPollFire, 25, 25)")
      check source.contains("if server.timer == nil and server.timerCallback != nil")
      check source.contains("if server.internalTimer == nil and server.internalTimerCallback != nil")
      check source.contains("if server.wsKeepaliveTimer == nil and wsInterval > 0")
      check source.contains("if loadShutdownRequested() or server.isShuttingDown:\n      beginShutdown(server)")

  test "fallback write and close lifecycle uses shared tracked helpers":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let source = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
    check source.contains("proc writeFallbackPayloadAndMaybeClose(")
    check source.contains("proc writeFallbackDirectAndMaybeClose(")
    check source.contains("proc closeSocketTracked(")
    check source.contains("payload_too_large_413_short_write")
    check source.contains("overload_reject_short_write")

  test "fallback short-write paths report delivery failure":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let source = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
    check source.contains("return wrote >= header.len")
    check source.contains("return wrote >= finalFrame.len")
    check source.contains("return wrote >= frame.len")

  test "H2 dispatch auto-end runs request lifecycle and cleanup":
    let server = newHttpServer()
    var handlerCalled = false
    var endStatus = 0

    server.handle(proc(req: HttpRequest, res: HttpResponse) =
      handlerCalled = true
      check req.httpMajor == 2
      check req.path == "/h2"
      check req.queryStringRaw == "x=1&y=2"
      check req.headers.getOrDefault("x-test", "") == "ok"
      check res.autoEndEnabled()
    )
    server.onRequestEnd(proc(req: HttpRequest, statusCode: int, durationMicros: int64) =
      discard req
      discard durationMicros
      endStatus = statusCode
    )

    var sockData: SocketData
    sockData.server = server
    sockData.memoryBudget = initRequestMemoryBudget()
    setRemoteIp(addr sockData, "127.0.0.1")
    let conn = initH2ServerConnection()
    sockData.h2conn = conn
    conn.streams[1'u32] = H2ServerStream(
      id: 1'u32,
      state: h2p.ssOpen,
      sendWindow: int32(conn.remoteSettings.initialWindowSize),
      recvWindow: h2p.DefaultWindowSize,
      headersReceived: true,
      endStreamRecv: true
    )

    h2DispatchRequest(addr sockData, nil, server, conn, 1'u32, @[
      (":method", "GET"),
      (":path", "/h2?x=1&y=2"),
      (":scheme", "http"),
      (":authority", "localhost"),
      ("x-test", "ok")
    ], "", "h2UnitHandler")

    check handlerCalled
    check endStatus == 200
    check h2FindStream(conn, 1'u32) == nil
    check sockData.nextRequestSeq == 1'u64
    check sockData.memoryBudget.used == 0

  test "H2 connection window update snapshots streams before flushing":
    let repoRoot = currentSourcePath().parentDir.parentDir
    let source = readFile(repoRoot / "src/nim_usockets/http.nim")
    check source.contains("var sids: seq[uint32] = @[]")
    check source.contains("for sid in sids:\n            h2FlushPendingSendData(conn, sid)")

  test "h2c upgrade is rejected instead of advertising a partial protocol switch":
    let repoRoot = currentSourcePath().parentDir.parentDir
    let source = readFile(repoRoot / "src/nim_usockets/http.nim")
    check source.contains("discard writeSocketChecked(ssl, s, NotImplementedResponse.cstring, NotImplementedResponse.len)")
    check not source.contains("Upgrade: h2c\\r\\n\\r\\n")

  test "H2 CONNECT without path dispatches instead of being dropped":
    let server = newHttpServer()
    var handlerCalled = false
    var seenMethod = hmGet
    var seenPath = "unset"

    server.handle(proc(req: HttpRequest, res: HttpResponse) =
      handlerCalled = true
      seenMethod = req.methodKind
      seenPath = req.path
      res.statusCode = Http500
      res.statusCodeInt = 500
      h2End(res, "")
    )

    var sockData: SocketData
    sockData.server = server
    sockData.memoryBudget = initRequestMemoryBudget()
    let conn = initH2ServerConnection()
    sockData.h2conn = conn
    conn.streams[11'u32] = H2ServerStream(
      id: 11'u32,
      state: h2p.ssOpen,
      sendWindow: int32(conn.remoteSettings.initialWindowSize),
      recvWindow: h2p.DefaultWindowSize,
      headersReceived: true,
      endStreamRecv: true
    )

    h2DispatchRequest(addr sockData, nil, server, conn, 11'u32, @[
      (":method", "CONNECT"),
      (":authority", "example.test:443")
    ], "", "h2UnitConnect")

    check handlerCalled
    check seenMethod == hmConnect
    check seenPath == ""

  test "H2 handler exception emits panic, returns 500, and releases stream":
    let server = newHttpServer()
    var panicMessage = ""
    var endStatus = 0

    server.handle(proc(req: HttpRequest, res: HttpResponse) =
      discard req
      discard res
      raise newException(ValueError, "h2 boom")
    )
    server.onPanic(proc(message: string) =
      panicMessage = message
    )
    server.onRequestEnd(proc(req: HttpRequest, statusCode: int, durationMicros: int64) =
      discard req
      discard durationMicros
      endStatus = statusCode
    )

    var sockData: SocketData
    sockData.server = server
    sockData.memoryBudget = initRequestMemoryBudget()
    let conn = initH2ServerConnection()
    sockData.h2conn = conn
    conn.streams[3'u32] = H2ServerStream(
      id: 3'u32,
      state: h2p.ssOpen,
      sendWindow: int32(conn.remoteSettings.initialWindowSize),
      recvWindow: h2p.DefaultWindowSize,
      headersReceived: true,
      endStreamRecv: true
    )

    h2DispatchRequest(addr sockData, nil, server, conn, 3'u32, @[
      (":method", "GET"),
      (":path", "/boom"),
      (":scheme", "http"),
      (":authority", "localhost")
    ], "", "h2UnitBoom")

    check panicMessage.contains("h2UnitBoom")
    check endStatus == 500
    check h2FindStream(conn, 3'u32) == nil

  test "H2 response pool release clears stream identity":
    let conn = initH2ServerConnection()
    let res = acquireHttpResponse()
    res.h2StreamId = 7'u32
    res.h2Conn = conn
    res.requestIsHttp11 = false
    releaseHttpResponse(res)

    let reused = acquireHttpResponse()
    check reused.h2StreamId == 0'u32
    check reused.h2Conn == nil
    releaseHttpResponse(reused)

  test "H2 close cleanup drops buffered frames and stream bodies":
    let conn = initH2ServerConnection()
    conn.h2SendBuf = "pending"
    conn.h2SendBufPos = 1
    conn.headerBlockBuf = "headers"
    conn.streams[1'u32] = H2ServerStream(
      id: 1'u32,
      requestBody: "body",
      pendingSendData: "response"
    )

    cleanupH2Connection(conn)

    check not conn.active
    check conn.h2SendBuf.len == 0
    check conn.h2SendBufPos == 0
    check conn.headerBlockBuf.len == 0
    check conn.streams.len == 0

  test "H2 send buffer overflow does not consume flow-control windows":
    let conn = initH2ServerConnection()
    conn.h2SendBuf = newString(MaxH2SendBufSize)
    conn.h2SendBufPos = 0
    conn.remoteWindow = 100
    conn.streams[1'u32] = H2ServerStream(
      id: 1'u32,
      state: h2p.ssOpen,
      sendWindow: 100,
      recvWindow: h2p.DefaultWindowSize
    )
    var res: HttpResponse
    new(res)
    res.socket = cast[UsSocketPtr](1)
    res.ssl = 0
    res.h2StreamId = 1'u32
    res.h2Conn = conn

    h2SendData(res, "hello")

    check conn.remoteWindow == 100
    check conn.streams[1'u32].sendWindow == 100

  test "H2 header limits follow configured HTTP header limits":
    let server = newHttpServer()
    server.setHeaderLimits(maxHeaderBytes = 48, maxHeaderCount = 3, maxHeaderLineBytes = 24)
    let conn = initH2ServerConnection()
    configureH2ConnectionLimits(conn, server)
    check conn.localSettings.maxHeaderListSize == 48'u32
    check h2HeaderBlockWouldExceed(server, 40, 9)
    check not h2HeaderBlockWouldExceed(server, 40, 8)
    check h2HeaderListWithinLimits(server, @[
      (":method", "GET"),
      (":path", "/"),
      (":scheme", "http"),
    ])
    check not h2HeaderListWithinLimits(server, @[
      (":method", "GET"),
      (":path", "/"),
      (":scheme", "http"),
      ("x-extra", "1"),
    ])
    check not h2HeaderListWithinLimits(server, @[
      (":method", "GET"),
      ("x-long", repeat("a", 32)),
    ])

  test "H2 HPACK decode enforces configured header limits":
    let server = newHttpServer()
    server.setHeaderLimits(maxHeaderBytes = 128, maxHeaderCount = 2, maxHeaderLineBytes = 64)
    let conn = initH2ServerConnection()
    var encoder = hpackMod.initHpackEncoder(huffman = false)
    var headerBlock = ""
    hpackMod.hpackEncode(encoder, [
      (":method", "GET"),
      (":path", "/"),
      (":scheme", "http"),
    ], headerBlock)
    var decoded: seq[(string, string)]
    check h2DecodeHeadersLimited(conn, server, headerBlock, decoded) == h2hdsLimitExceeded

  test "keepalive and interleaving reduced soak preserves queue and shutdown invariants":
    let server = newHttpServer()
    server.setCrossThreadDeferEnabled(true)
    server.setOverloadController(maxBacklogBytes = 128, maxPendingResponses = 8, closeOnReject = false)
    server.setSpillPressureController(rejectThreshold = 4, recoverThreshold = 1)

    var sockData: SocketData
    sockData.server = server
    sockData.pendingBytes = 0
    sockData.pendingSlots = @[]
    sockData.pendingUsed = @[]
    sockData.pendingActiveCount = 0

    var fired = 0
    defer:
      resetShutdownSignalFlags()

    for i in 0 ..< 256:
      server.deferFromAnyThread(proc() = inc fired)
      if (i and 1) == 0:
        server.flushCrossThreadDeferQueue()
      if (i mod 3) == 0:
        server.flushDeferredPostCallbacks()
      if (i mod 5) == 0:
        noteSpillPressureDrop(server)
      discard overloadRejectReasonFor(addr sockData)
      onWsKeepaliveFire(nil)
      if (i mod 32) == 0:
        markShutdownSignalRequested()
        check loadShutdownRequested()
        resetShutdownSignalFlags()

    server.flushCrossThreadDeferQueue()
    server.flushDeferredPostCallbacks()
    check fired == 256
    when compileOption("threads"):
      check server.crossThreadDeferQueue.len == 0
      check not server.crossThreadDeferWakePending
    check not loadShutdownRequested()
    check not loadForceExitRequested()

  test "websocket idle timeout re-arm bypasses phase dedup guard":
    # Regression: server-to-client sends used to hit the dedup guard and
    # never push the C-level idle deadline forward, so a busy WS connection
    # was killed after the first idle window. re-arm must bypass the guard.
    let server = newHttpServer()
    server.setWsIdleTimeout(0)  # keep us_socket_timeout out of this unit test

    var sockData: SocketData
    sockData.server = server
    sockData.isWebSocket = true
    let fakeSock = cast[UsSocketPtr](alloc0(64))

    setSocketTimeoutPhase(addr sockData, fakeSock, tpWebSocketIdle, 1'u64, 1000'i64)
    check sockData.timeoutPhase == tpWebSocketIdle
    check sockData.phaseStartedAtMs == 1000

    # Duplicate transition without re-arm: the guard must skip the update.
    setSocketTimeoutPhase(addr sockData, fakeSock, tpWebSocketIdle, 1'u64, 2000'i64)
    check sockData.phaseStartedAtMs == 1000

    # Re-arm (same phase/seq, later instant) must bypass the guard.
    setSocketTimeoutPhase(addr sockData, fakeSock, tpWebSocketIdle, 1'u64, 3000'i64,
      rearm = true)
    check sockData.phaseStartedAtMs == 3000

    # A phase/seq change still passes the plain (non-rearm) path.
    setSocketTimeoutPhase(addr sockData, fakeSock, tpWebSocketIdle, 2'u64, 4000'i64)
    check sockData.phaseStartedAtMs == 4000
    check sockData.activeRequestSeq == 2'u64

    dealloc(fakeSock)

  test "timer callbacks that raise a defect do not poison the runtime":
    # Regression: a Defect (index out of bounds, OOM, ...) escaping a .cdecl
    # timer callback left the runtime error flag set, and every later Nim
    # call on the loop thread silently no-opped (zombie hang, no output).
    # The wrapper must catch the Defect and reset the error state.
    let server = newHttpServer()
    var panicMessages: seq[string] = @[]
    server.onPanic(proc(message: string) =
      panicMessages.add(message)
    )

    let fakeTimer = cast[UsTimerPtr](alloc0(128))
    bindTimerServer(fakeTimer, server)

    var defectRuns = 0
    var safeRuns = 0
    server.internalTimerCallback = proc() =
      inc defectRuns
      var s: string
      discard s[0]  # deliberate IndexDefect
    server.internalTimerIntervalMs = 50

    onInternalTimerFire(fakeTimer)
    check defectRuns == 1
    check panicMessages.len == 1
    check panicMessages[0].contains("internalTimerCallback_defect")
    check panicMessages[0].contains("index out of bounds")

    # The loop must still be functional after the defect: a later callback
    # on the same server must actually execute (pre-fix it silently no-oped).
    server.internalTimerCallback = proc() = inc safeRuns
    onInternalTimerFire(fakeTimer)
    check safeRuns == 1

    # The user-interval wrapper has the same protection.
    var userDefectRuns = 0
    server.timerCallback = proc() =
      inc userDefectRuns
      var a: seq[int]
      discard a[3]  # deliberate IndexDefect
    server.timerIntervalMs = 100
    onTimerFire(fakeTimer)
    check userDefectRuns == 1
    check panicMessages.len == 2
    check panicMessages[1].contains("timerCallback_defect")

    server.timerCallback = proc() = inc safeRuns
    onTimerFire(fakeTimer)
    check safeRuns == 2

    dealloc(fakeTimer)

  # --- RFC 6455 §8.1 strict UTF-8 validation regression tests ---

  test "validateUtf8Strict rejects E0 80 80 (overlong encoding)":
    let s = "\xE0\x80\x80"
    check validateUtf8Strict(s) == 0

  test "validateUtf8Strict rejects ED A0 80 (surrogate D800)":
    let s = "\xED\xA0\x80"
    check validateUtf8Strict(s) == 0

  test "validateUtf8Strict rejects F4 90 80 80 (cp > 10FFFF)":
    let s = "\xF4\x90\x80\x80"
    check validateUtf8Strict(s) == 0

  test "validateUtf8Strict rejects C0 AF (overlong slash)":
    let s = "\xC0\xAF"
    check validateUtf8Strict(s) == 0

  test "validateUtf8Strict rejects F5-F7 leads (invalid 4-byte starts)":
    for lead in '\xF5'..'\xF7':
      let s = $lead & "\x80\x80\x80"
      check validateUtf8Strict(s) == 0

  test "validateUtf8Strict rejects bare continuation bytes":
    for b in '\x80'..'\xBF':
      let s = $b
      check validateUtf8Strict(s) == 0

  test "validateUtf8Strict rejects truncated 2-byte sequence":
    let s = "\xC3"
    check validateUtf8Strict(s) == 0

  test "validateUtf8Strict rejects truncated 3-byte sequence":
    let s = "A\xE0\xA0"
    check validateUtf8Strict(s) == 1

  test "validateUtf8Strict rejects truncated 4-byte sequence":
    let s = "AB\xF0\x9F\x98"
    check validateUtf8Strict(s) == 2

  test "validateUtf8Strict accepts valid multi-byte sequences":
    # U+00E9 (2-byte), U+20AC (3-byte), U+1F600 (4-byte)
    check validateUtf8Strict("caf\xC3\xA9") == -1
    check validateUtf8Strict("\xE2\x82\xAC") == -1
    check validateUtf8Strict("\xF0\x9F\x98\x80") == -1
    check validateUtf8Strict("") == -1
    check validateUtf8Strict("pure ascii") == -1

  test "validateUtf8Bytes agrees with validateUtf8Strict for byte arrays":
    let cases = [
      "\xE0\x80\x80",
      "\xED\xA0\x80",
      "\xF4\x90\x80\x80",
      "\xC0\xAF",
      "\xF5\x80\x80\x80",
      "\x80",
      "\xC3",
      "A\xE0\xA0",
      "\xC3\xA9",
      "\xF0\x9F\x98\x80"
    ]
    for item in cases:
      var byteArr = newSeq[byte](item.len)
      for i in 0 ..< item.len:
        byteArr[i] = byte(item[i])
      check validateUtf8Bytes(byteArr, 0, byteArr.len) == validateUtf8Strict(item)

  test "validWsCloseReasonPrefixLen rejects overlong in close reason":
    # E0 80 80 in close reason must yield 0-length prefix (invalid → strip entirely)
    check validWsCloseReasonPrefixLen("\xE0\x80\x80", 123) == 0

  test "validWsCloseReasonPrefixLen rejects surrogate in close reason":
    check validWsCloseReasonPrefixLen("\xED\xA0\x80", 123) == 0

  test "validWsCloseReasonPrefixLen rejects cp>10FFFF in close reason":
    check validWsCloseReasonPrefixLen("\xF4\x90\x80\x80", 123) == 0

  test "validWsCloseReasonPrefixLen truncates valid string at byte boundary safely":
    # Full string is valid UTF-8 (euro sign = 3 bytes + 'A'), but maxBytes=4
    # truncates mid-'A'? No, maxBytes=3 cuts exactly at euro boundary, maxBytes=2 breaks euro.
    let reason = "\xE2\x82\xAC" & "A"  # 3-byte euro + 1-byte A = 4 bytes
    check validWsCloseReasonPrefixLen(reason, 4) == 4  # fits entirely
    check validWsCloseReasonPrefixLen(reason, 3) == 3  # cuts at byte boundary after euro
    check validWsCloseReasonPrefixLen(reason, 2) == 0  # would truncate mid-euro, back to 0
    # Strict check: truncation that creates an invalid prefix must be rejected
    # maxBytes=1: just first byte E2 is incomplete → 0
    check validWsCloseReasonPrefixLen(reason, 1) == 0

  test "text frame strict path: overlong after ASCII prefix detected at correct offset":
    let payload = "hello\xE0\x80\x80"
    check isAsciiOnly(payload) == false
    check validateUtf8Strict(payload) == 5

  test "text frame strict path: surrogate after ASCII prefix":
    let payload = "ok\xED\xA0\x80"
    check validateUtf8Strict(payload) == 2
