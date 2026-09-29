import std/options
import nim_fasthttpclient/types
import nim_fasthttpclient/ws_client

proc check(cond: bool, msg: string) =
  if not cond:
    quit "FAIL: " & msg

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ord(ch))

proc main() =
  let ws = newWsConnection()
  initWsClientDefaults(ws)
  markWsOpen(ws, 1000)

  let ping = buildWsPing(ws, 1000, "abc")
  check(ping.len > 0, "client ping emitted")
  check(ws.awaitingPong, "client awaits pong")
  var pos = 0
  let decodedPing = decodeWsFrame(toBytes(ping), pos)
  check(decodedPing.isSome, "client ping decodes")
  check(decodedPing.get.opcode == woPing, "client ping opcode")
  check(decodedPing.get.payload == "abc", "client ping payload")

  noteWsPong(ws, "abc", 1001)
  check(not ws.awaitingPong, "matching pong clears heartbeat wait")

  let serverPing = encodePingFrame("server", masked = false)
  pos = 0
  let read = readWsFrame(serverPing, pos)
  check(read.status == wfrOk, "server ping read")
  let pong = buildWsPongResponse(read.frame.payload)
  pos = 0
  let decodedPong = decodeWsFrame(toBytes(pong), pos)
  check(decodedPong.isSome, "pong response decodes")
  check(decodedPong.get.opcode == woPong, "pong response opcode")
  check(decodedPong.get.payload == "server", "pong echoes ping payload")

  discard buildWsPing(ws, 2000, "late")
  ws.pongTimeoutMs = 10
  check(shouldFailPongTimeout(ws, 2010), "pong timeout detected")
  echo "test_ws_client_ping: OK"

main()
