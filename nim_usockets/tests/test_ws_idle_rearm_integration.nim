# Live end-to-end regression test for two framework bugs:
#
# Bug 1 — WS idle timeout re-arm
#   Server-to-client sends must re-arm the C-level WS idle deadline
#   (setSocketTimeoutPhase with rearm=true). Before the fix, the phase
#   dedup guard skipped the re-arm, so a busy connection that only
#   receives server traffic was killed by the idle timeout.
#   The uSockets C timeout wheel has 4s granularity and fires on exact
#   slot match (src/loop.c: short_ticks == s->timeout), so the test uses
#   a 12s idle timeout (slot offset 3): without working re-arms the
#   deadline armed at connect fires 8-12s after connect (three slots,
#   alignment-dependent); with working re-arms a connection with
#   continuous server->client traffic crosses every boundary. The test
#   runs pings for 6->14.9s: a no-fix close (8-12s) yields at most 60
#   pings, a fixed server yields ~89. The 12s horizon also tolerates a
#   single stalled 4s wheel slot under CI load (a 6s idle could be
#   flaky when the loop misses one full slot).
#
# Bug 2 — Defect in a .cdecl timer callback must not poison the runtime
#   Before the fix, a Defect (e.g. index out of bounds) escaping a
#   .cdecl callback left the Nim runtime error flag set, silently
#   no-opping every later Nim call (zombie hang, no diagnostics). The
#   callback wrappers must catch the Defect, report it through the panic
#   handler, and keep serving.
#
# Scenario A (0..6s): wsIdleTimeout = 12s; the server sends a "tick" text
#   frame every 100ms with zero client traffic. The client (a plain
#   non-buffered socket driven from the internal timer) counts frames.
#   Requires >= 50 ticks over the 6s phase.
#
# Scenario B (6..14.9s): the internal timer callback raises an
#   IndexDefect for 10 consecutive fires (6..7s) while the server keeps
#   sending a "ping" text frame every 100ms. Requires: all 10 defects
#   reported through the panic handler, and >= 80 pings received — only
#   possible if the connection stays open to the end (a no-re-arm
#   deadline would close it 8-12s after connect, capping pings at ~60).
#
# Runs in ~15s and exits 0 on success.

import std/[net, times, strutils]
include ../src/nim_usockets/http

const TestPort = 49613
const TickBudget = 50
const PingBudget = 80

type Phase = enum
  phaseIdle, phaseTraffic, phaseDefect

var csock: Socket
var phase: Phase = phaseIdle
var activeWs: WebSocket
var ticks = 0
var pings = 0
var defectCount = 0
var panicDefects = 0
var startedAtMs = 0'i64

proc nowMs(): int64 = toUnix(getTime()) * 1000

proc wsDial(host: string, port: int): Socket =
  result = dial(host, Port(port), buffered = false)
  # NOTE: buffered=false is required. std/net's buffered-socket recv()
  # loops a blocking fill-recv until the requested size is satisfied;
  # called from the event-loop thread that would stall the whole loop.
  result.send("GET /ws HTTP/1.1\r\nHost: " & host & ":" & $port & "\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
    "Sec-WebSocket-Version: 13\r\n\r\n")

proc countNeedles(buf: openArray[byte], needle: string): int =
  for i in 0 ..< buf.len - needle.len + 1:
    var match = true
    for j in 0 ..< needle.len:
      if buf[i + j] != byte(needle[j]):
        match = false
        break
    if match:
      inc result

proc pollClientSocket(needle: string, counter: var int) =
  if csock == nil:
    return
  var rfds: TFdSet
  FD_ZERO(rfds)
  let fd = int(getFd(csock))
  FD_SET(getFd(csock), rfds)
  var tv: Timeval
  if select(cint(fd + 1), addr rfds, nil, nil, addr tv) > 0:
    var raw = newSeq[byte](65536)
    let got = csock.recv(unsafeAddr raw[0], raw.len)
    if got > 0:
      counter += countNeedles(raw[0 ..< got], needle)

let srv = newHttpServer()
srv.setWsIdleTimeout(12)
srv.wsHandler = proc(ws: WebSocket, message: string, isBinary: bool) = discard
srv.onPanic(proc(message: string) =
  if "defect" in message:
    inc panicDefects
)
srv.onWebSocketClose(proc(ws: WebSocket) =
  if startedAtMs > 0:
    echo "[close] at t=", $(nowMs() - startedAtMs), "ms phase=", $phase
)
srv.onWebSocketOpen proc(ws: WebSocket) =
  activeWs = ws

srv.setInterval(proc() =
  case phase
  of phaseTraffic:
    if activeWs != nil:
      activeWs.sendText("tick")
    if startedAtMs > 0 and (nowMs() - startedAtMs) >= 6000:
      phase = phaseDefect
  of phaseDefect:
    if activeWs != nil:
      activeWs.sendText("ping")
    if startedAtMs > 0 and (nowMs() - startedAtMs) >= 14900:
      srv.close()
  else:
    discard
, 100)

srv.setInternalInterval(proc() =
  if startedAtMs > 0 and (nowMs() - startedAtMs) > 16500:
    # Hard watchdog: never hang the test suite.
    srv.close()
    return
  case phase
  of phaseTraffic:
    pollClientSocket("tick", ticks)
  of phaseDefect:
    if defectCount < 10:
      inc defectCount
      var a: seq[int]
      discard a[7]  # deliberate IndexDefect: framework must catch it
    pollClientSocket("ping", pings)
  else:
    discard
, 50)

srv.listen("127.0.0.1", TestPort) do(success: bool):
  if success:
    csock = wsDial("127.0.0.1", TestPort)
    phase = phaseTraffic
    startedAtMs = nowMs()

srv.run()

if csock != nil:
  csock.close()

let elapsed = (nowMs() - startedAtMs) div 1000
if ticks < TickBudget:
  echo "FAIL: Bug 1 regression — WS idle timeout killed a busy connection " &
    $(ticks) & " ticks, expected >= " & $TickBudget
  quit(1)
if pings < PingBudget:
  echo "FAIL: Bug 1 regression — WS idle timeout killed a busy connection " &
    $(pings) & " pings, expected >= " & $PingBudget
  quit(1)
if defectCount < 10 or panicDefects < 10:
  echo "FAIL: Bug 2 regression — defects not caught " &
    $(defectCount) & " fires, " & $panicDefects & " panics"
  quit(1)

echo "WS_IDLE_REARM_INTEGRATION_PASS ticks=" & $ticks &
  " pings=" & $pings & " defects=" & $defectCount &
  " elapsed=" & $elapsed & "s"
