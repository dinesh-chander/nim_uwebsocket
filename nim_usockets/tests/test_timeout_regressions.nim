# Regression tests for socket-timeout and interval-timer behavior:
#
# Bug 1: The WS idle timeout must be refreshed (re-armed) on send. The dedup
#        guard in setSocketTimeoutPhase skips the C-level us_socket_timeout
#        call when phase/seq/seconds are unchanged, which is correct for phase
#        *transitions* but wrong for timer *re-arms*. refreshWsIdleTimeout
#        must therefore pass rearm=true so the deadline is pushed forward on
#        every send, even at unchanged phase/seq/seconds.
#
# Bug 2: setInterval (and other loop timers) must keep firing after a
#        timeout-close event (WS idle close or HTTP header-timeout close).
#        The integration tests below prove the loop stays healthy and the
#        user interval keeps firing across such events.
#
# The integration scenarios run single-threaded: clients are driven from a
# 50ms internal interval (select with zero timeout + read), which matches the
# uSockets single-threaded loop model.
#
# Timing note: uSockets keeps socket deadlines in a 240-slot wheel swept
# every 4s (src/socket.c). A 1s configured timeout therefore closes within
# (0, ~4s] of the last activity, and assertions below use generous upper
# bounds instead of exact deadlines.

import std/[net, posix, strutils, times, unittest, sequtils]

include ../src/nim_usockets/http

proc nowMs(): int64 =
  # 1s resolution is plenty for the scenario windows used here.
  toUnix(getTime()) * 1000

proc pickFreePort(): int =
  let s = newSocket()
  try:
    s.bindAddr(Port(0), "127.0.0.1")
    let (_, port) = s.getLocalAddr()
    result = int(port)
  finally:
    s.close()

# --- Raw WS client helpers --------------------------------------------------

proc wsClientBegin(host: string, port: int): Socket =
  result = dial(host, Port(port), buffered = false)
  result.send(
    "GET /ws HTTP/1.1\r\n" &
    "Host: " & host & ":" & $port & "\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
    "Sec-WebSocket-Version: 13\r\n\r\n"
  )

# Parse one unmasked server->client frame at `offset`. Returns (frameLen,
# opcode, payload) or (0, 0, "") when the frame is incomplete.
proc parseServerFrame(buf: string, offset: int): (int, int, string) =
  if buf.len - offset < 2:
    return (0, 0, "")
  let b0 = byte(buf[offset])
  let b1 = byte(buf[offset + 1])
  let opcode = int(b0 and 0x0F)
  var payloadLen = int(b1 and 0x7F)
  var hdr = 2
  if payloadLen == 126:
    if buf.len - offset < 4:
      return (0, 0, "")
    payloadLen = int(byte(buf[offset + 2])) * 256 + int(byte(buf[offset + 3]))
    hdr = 4
  elif payloadLen == 127:
    if buf.len - offset < 10:
      return (0, 0, "")
    payloadLen = 0
    for i in 0 .. 7:
      payloadLen = payloadLen * 256 + int(byte(buf[offset + 2 + i]))
    hdr = 10
  if buf.len - offset < hdr + payloadLen:
    return (0, 0, "")
  result = (hdr + payloadLen, opcode, buf.substr(offset + hdr, payloadLen))

# Drain all complete frames from `buf` (in place). Returns (opcode, payload)
# pairs.
proc drainServerFrames(buf: var string): seq[(int, string)] =
  var off = 0
  while off < buf.len:
    let (frameLen, opcode, payload) = parseServerFrame(buf, off)
    if frameLen == 0:
      break
    result.add((opcode, payload))
    off += frameLen
  if off > 0:
    buf = buf.substr(off)

proc selectReadable(sock: Socket): bool =
  let fd = int(getFd(sock))
  var rfds: TFdSet
  FD_ZERO(rfds)
  FD_SET(getFd(sock), rfds)
  var tv: Timeval
  result = select(cint(fd + 1), addr rfds, nil, nil, addr tv) > 0 and
           cint(FD_ISSET(getFd(sock), rfds)) > 0

# --- Unit tests --------------------------------------------------------------

suite "timeout re-arm and interval regressions":

  test "dedup guard distinguishes phase transitions from unchanged state":
    let server = newHttpServer()
    server.setWsIdleTimeout(1)
    var sd: SocketData
    sd.server = server
    # Fresh state (never armed) must be considered an update.
    check shouldUpdateSocketTimeoutPhase(addr sd, tpWebSocketIdle, 0'u64, 1)
    sd.timeoutPhase = tpWebSocketIdle
    sd.activeRequestSeq = 0'u64
    sd.timeoutPhaseSeconds = 1
    # Same phase/seq/seconds: dedup (this is the transition case).
    check not shouldUpdateSocketTimeoutPhase(addr sd, tpWebSocketIdle, 0'u64, 1)
    # A changed seq is a new request: must update.
    check shouldUpdateSocketTimeoutPhase(addr sd, tpWebSocketIdle, 1'u64, 1)
    # A changed phase is a transition: must update.
    check shouldUpdateSocketTimeoutPhase(addr sd, tpHeaderRead, 0'u64, 1)

  test "idle refresh path re-arms instead of relying on the dedup guard":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let source = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
    # refreshWsIdleTimeout must force a re-arm of the C-level timer even when
    # phase/seq/seconds are unchanged, otherwise mostly-sending WS servers
    # die at the idle deadline.
    check "sockData.setSocketTimeoutPhase(s, tpWebSocketIdle, sockData.activeRequestSeq, rearm = true)" in source
    # The transition path must keep the dedup guard (no re-arm).
    check "if not rearm and not shouldUpdateSocketTimeoutPhase(" in source
    # Re-arms must still respect the wsResetIdleTimeoutOnSend switch.
    check "if onSendPath and not sockData.server.options.wsResetIdleTimeoutOnSend:" in source

  test "ws idle timeout clamps to the uSockets wheel horizon":
    let server = newHttpServer()
    server.setWsIdleTimeout(10000)
    check server.options.wsIdleTimeoutSeconds == WsIdleTimeoutWheelHorizonSeconds
    server.setWsIdleTimeout(-5)
    check server.options.wsIdleTimeoutSeconds == 0
    var sd: SocketData
    sd.server = server
    server.setWsIdleTimeout(60)
    check wsIdleTimeoutFor(addr sd) == 60.cuint
    server.setWsIdleTimeout(10000)
    check wsIdleTimeoutFor(addr sd) == WsIdleTimeoutWheelHorizonSeconds.cuint
    server.setWsIdleTimeout(0)
    check wsIdleTimeoutFor(addr sd) == 0.cuint

# --- Integration scenarios (single-threaded, loop-driven clients) -----------

type Scenario = object
  port: int
  listenOk: bool
  violations: seq[string]
  done: bool
  t0: int64
  timerFires: int
  clients: seq[Socket]
  bufs: seq[string]
  closedAtMs: seq[int64]       # client-side EOF observation (-1 = open)
  serverClosedAtMs: seq[int64] # server-side close handlers (0 = open)
  tickCount: int
  f1: int
  f1Captured: bool
  stopAtMs: int64
  failAfterMs: int64           # hard watchdog for the scenario
  # scenario A
  activeWs, silentWs: WebSocket
  # scenario B
  sawTimeoutClose: bool
  verifiedFreshConnection: bool
  freshClient: Socket
  freshResp: string
  freshDeadlineMs: int64

var gScenario: Scenario
var gServer: HttpServer

proc vfail(scenario: var Scenario, msg: string) =
  scenario.violations.add(msg)

proc finishScenario(scenario: var Scenario, server: HttpServer, label: string) =
  if scenario.done:
    return
  scenario.done = true
  if scenario.violations.len > 0:
    for v in scenario.violations:
      echo "FAIL[", label, "]: ", v
    quit(1)
  echo "PASS[", label, "]"
  # Same-thread shutdown: close() wakes the loop; the 25ms shutdown poll then
  # runs beginShutdown, drains (200ms), force-closes and stops the timers so
  # us_loop_run returns and the scenario's run() call completes.
  server.close()

# Scenario A driver: two WS clients, active (server pushes) + silent.
proc runScenarioADriver(scenario: var Scenario, server: HttpServer) =
  let now = nowMs()
  let t = now - scenario.t0
  if scenario.failAfterMs > 0 and t >= scenario.failAfterMs:
    scenario.vfail("scenario exceeded hard watchdog at t=" & $t & "ms")
    finishScenario(scenario, server, "A")
    return
  if now >= scenario.stopAtMs:
    # Evaluate assertions at the end of the observation window.
    let f2 = scenario.timerFires
    let silentAt = scenario.serverClosedAtMs[1]
    let activeAt = scenario.serverClosedAtMs[0]
    if silentAt <= 0:
      scenario.vfail("silent WS client was not closed by idle timeout")
    elif silentAt - scenario.t0 > 9500:
      scenario.vfail("idle close took too long: " &
                     $(silentAt - scenario.t0) & "ms")
    if activeAt > 0:
      scenario.vfail("active WS client was closed at " & $activeAt &
                     " despite send-path idle re-arms (Bug 1)")
    if scenario.tickCount < 6:
      scenario.vfail("active client only received " & $scenario.tickCount &
                     " ticks")
    if f2 < 50:
      scenario.vfail("setInterval only fired " & $f2 & " times in 10s")
    if scenario.f1Captured and f2 < scenario.f1 + 2:
      scenario.vfail("setInterval stopped after timeout close: " &
                     $scenario.f1 & " -> " & $f2 & " (Bug 2)")
    finishScenario(scenario, server, "A")
    return

  # Drive client 0 (active: receives ticks) and client 1 (silent).
  for i in 0 .. 1:
    let c = scenario.clients[i]
    if scenario.closedAtMs[i] >= 0:
      continue
    if selectReadable(c):
      var raw = newStringOfCap(65536)
      raw.setLen(65536)
      let n = c.recv(unsafeAddr raw[0], 65536)
      if n <= 0:
        scenario.closedAtMs[i] = now
      else:
        raw.setLen(n)
        scenario.bufs[i] &= raw
        # Drop the HTTP upgrade response before any WS frame parsing:
        # the status line is not a frame and its bytes would otherwise
        # parse as a bogus opcode-0x8 (close) frame.
        let sep = scenario.bufs[i].find("\r\n\r\n")
        if sep >= 0:
          scenario.bufs[i] = scenario.bufs[i].substr(sep + 4)
        for (opcode, payload) in drainServerFrames(scenario.bufs[i]):
          if opcode == 0x1 and i == 0:
            inc scenario.tickCount
          elif opcode == 0x8:
            scenario.closedAtMs[i] = now
          discard payload

  # Capture the interval counter 1s after the silent-client close event so
  # we can prove the interval kept firing afterwards (Bug 2).
  if not scenario.f1Captured:
    let closedAt = scenario.serverClosedAtMs[1]
    if closedAt > 0 and now >= closedAt + 1000:
      scenario.f1 = scenario.timerFires
      scenario.f1Captured = true

# Scenario B driver: raw client with incomplete headers, then a fresh
# connection to prove the loop is still healthy after the timeout close.
proc runScenarioBDriver(scenario: var Scenario, server: HttpServer) =
  let now = nowMs()
  let t = now - scenario.t0
  if scenario.failAfterMs > 0 and t >= scenario.failAfterMs:
    scenario.vfail("scenario exceeded hard watchdog at t=" & $t & "ms")
    finishScenario(scenario, server, "B")
    return

  if not scenario.sawTimeoutClose:
    # Phase 1: wait for the timeout close (client 0, incomplete headers).
    if scenario.closedAtMs[0] >= 0:
      return
    if selectReadable(scenario.clients[0]):
      var raw = newStringOfCap(65536)
      raw.setLen(65536)
      let n = scenario.clients[0].recv(unsafeAddr raw[0], 65536)
      if n <= 0:
        scenario.sawTimeoutClose = true
        scenario.serverClosedAtMs[0] = now
        scenario.closedAtMs[0] = now
        echo "[B] connection closed after ", $t, "ms (timeout close)"
    return

  # Phase 2: prove setInterval keeps firing after the close (Bug 2).
  if not scenario.f1Captured:
    scenario.f1 = scenario.timerFires
    scenario.f1Captured = true
    scenario.stopAtMs = now + 1500 # reuse stopAtMs as the phase-2 window
    return
  if now < scenario.stopAtMs:
    return
  let f2 = scenario.timerFires
  if f2 < scenario.f1 + 2:
    scenario.vfail("setInterval stopped after HTTP timeout close: " &
                   $scenario.f1 & " -> " & $f2 & " (Bug 2)")

  # Phase 3: a fresh connection must still be served. This is a
  # non-blocking state machine: the read loop must never block the event
  # loop thread, because the server's response write only happens when
  # the loop is free to run.
  if not scenario.verifiedFreshConnection:
    if scenario.freshClient == nil:
      var c: Socket
      try:
        c = dial("127.0.0.1", Port(scenario.port), buffered = false)
        c.send("GET / HTTP/1.1\r\nHost: regression.test\r\n\r\n")
      except CatchableError as err:
        scenario.vfail("fresh connection dial failed after timeout close: " &
                       err.msg)
        c = nil
      scenario.freshClient = c
      scenario.freshDeadlineMs = now + 3000
      if c == nil:
        finishScenario(scenario, server, "B")
        return
    if scenario.freshClient != nil:
      if selectReadable(scenario.freshClient):
        var raw = newStringOfCap(8192)
        raw.setLen(8192)
        let n = scenario.freshClient.recv(unsafeAddr raw[0], 8192)
        if n <= 0:
          scenario.freshClient = nil
          scenario.vfail("fresh connection closed before any response")
          finishScenario(scenario, server, "B")
          return
        raw.setLen(n)
        scenario.freshResp &= raw
      if scenario.freshResp.find("HTTP/1.1 200") >= 0:
        scenario.freshClient.close()
        scenario.freshClient = nil
        scenario.verifiedFreshConnection = true
        finishScenario(scenario, server, "B")
        return
      if now >= scenario.freshDeadlineMs:
        scenario.freshClient.close()
        scenario.freshClient = nil
        scenario.vfail("server stopped serving after timeout close: " &
                       scenario.freshResp.substr(0, min(120, scenario.freshResp.len)))
        finishScenario(scenario, server, "B")
        return
  finishScenario(scenario, server, "B")

# --- Scenario runners --------------------------------------------------------

proc runScenarioA(): int =
  # WS idle timeout: a mostly-receiving client (server pushes) must survive
  # past the idle deadline thanks to send-path re-arms, while a fully silent
  # client must be closed. The user setInterval must keep firing before and
  # after the idle close.
  resetShutdownSignalFlags()
  gScenario = Scenario(port: 0, t0: nowMs(), stopAtMs: nowMs() + 10_000,
                       failAfterMs: 25_000,
                       clients: @[], bufs: @["", ""],
                       closedAtMs: @[-1, -1], serverClosedAtMs: @[0, 0])
  gScenario.port = pickFreePort()

  let server = newHttpServer()
  gServer = server
  # A wsHandler must be registered for the framework to accept upgrades
  # (onWebSocketOpen/Close hooks alone are not enough).
  server.wsHandler = proc(ws: WebSocket, message: string, isBinary: bool) = discard
  # 6s => C wheel slot offset 2 (see us_socket_timeout in usockets/src/
  # socket.c: ((seconds + 3) >> 2) with 4s-granularity slots and exact
  # slot-match firing). Without send-path re-arms the active client's
  # deadline (open + 2 slots) fires at the t=8s boundary; with re-arms
  # it is pushed past every boundary for the whole 10s window. The
  # silent client has no re-arms and closes at that t=8s boundary.
  server.setWsIdleTimeout(6)
  server.options.gracefulShutdownDrainMs = 200
  server.onWebSocketOpen(proc(ws: WebSocket) =
    if gScenario.activeWs == nil:
      gScenario.activeWs = ws
    else:
      gScenario.silentWs = ws
  )
  server.onWebSocketClose(proc(ws: WebSocket) =
    if ws == gScenario.activeWs:
      gScenario.serverClosedAtMs[0] = nowMs()
    elif ws == gScenario.silentWs:
      gScenario.serverClosedAtMs[1] = nowMs()
  )
  server.setInterval(proc() =
    inc gScenario.timerFires
    if gScenario.timerFires mod 5 == 0:
      let ws = gScenario.activeWs
      if ws != nil and ws.isOpen:
        ws.sendText("tick")
  , 100)
  server.setInternalInterval(proc() =
    runScenarioADriver(gScenario, gServer)
  , 50)
  server.listen("127.0.0.1", gScenario.port) do(success: bool):
    gScenario.listenOk = success
    if not success:
      gScenario.vfail("failed to listen on port " & $gScenario.port)
      server.close()

  # Start the clients (kernel accept backlog queues them until the loop runs).
  gScenario.clients.add(wsClientBegin("127.0.0.1", gScenario.port))
  gScenario.clients.add(wsClientBegin("127.0.0.1", gScenario.port))
  gScenario.t0 = nowMs()
  gScenario.stopAtMs = gScenario.t0 + 10_000

  server.run()

  for c in gScenario.clients:
    c.close()
  if gScenario.done and gScenario.violations.len == 0:
    return 0
  for v in gScenario.violations:
    echo "FAIL[A]: ", v
  return 1

proc runScenarioB(): int =
  # HTTP header-read timeout close: a raw TCP client that sends an incomplete
  # header block must be closed by the timeout, and the server's setInterval
  # must keep firing afterwards while the loop still serves fresh connections
  # (Bug 2).
  resetShutdownSignalFlags()
  gScenario = Scenario(port: 0, t0: nowMs(), stopAtMs: nowMs() + 12_000,
                       failAfterMs: 30_000,
                       clients: @[], bufs: @["", ""],
                       closedAtMs: @[-1, -1], serverClosedAtMs: @[0, 0])
  gScenario.port = pickFreePort()

  let server = newHttpServer()
  gServer = server
  server.options.headerReadTimeoutMs = 1000
  server.options.gracefulShutdownDrainMs = 200
  server.handle(proc(req: HttpRequest, res: HttpResponse) =
    res.`end`("ok")
  )
  server.setInterval(proc() =
    inc gScenario.timerFires
  , 100)
  server.setInternalInterval(proc() =
    runScenarioBDriver(gScenario, gServer)
  , 50)
  server.listen("127.0.0.1", gScenario.port) do(success: bool):
    gScenario.listenOk = success
    if not success:
      gScenario.vfail("failed to listen on port " & $gScenario.port)
      server.close()

  # Incomplete headers: no blank line, so the header-read timeout applies.
  let c = dial("127.0.0.1", Port(gScenario.port), buffered = false)
  c.send("GET / HTTP/1.1\r\nHost: regression.test\r\n")
  gScenario.clients.add(c)
  gScenario.t0 = nowMs()
  gScenario.stopAtMs = gScenario.t0 + 12_000

  server.run()

  for cl in gScenario.clients:
    cl.close()
  if gScenario.done and gScenario.violations.len == 0:
    return 0
  for v in gScenario.violations:
    echo "FAIL[B]: ", v
  return 1

when isMainModule:
  if runScenarioA() != 0:
    echo "FAIL: scenario A (WS idle re-arm)"
    quit(1)
  if runScenarioB() != 0:
    echo "FAIL: scenario B (HTTP timeout close)"
    quit(1)
  echo "timeout regression tests passed"
  quit(0)
