import std/strutils
import nim_fasthttpclient/ws_frame

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

proc testAcceptCalculation() =
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  check(webSocketAccept(key) == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455 accept calculation")

proc testHandshakeBuilder() =
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let req = buildUpgradeRequest(
    "example.com",
    "/chat?room=1",
    8080'u16,
    key,
    ["chat", "superchat"],
    [("Authorization", "Bearer token")],
  )
  check(req.startsWith("GET /chat?room=1 HTTP/1.1\r\n"), "request line")
  check("Host: example.com:8080\r\n" in req, "host includes non-default port")
  check("Upgrade: websocket\r\n" in req, "upgrade header")
  check("Connection: Upgrade\r\n" in req, "connection header")
  check("Sec-WebSocket-Key: " & key & "\r\n" in req, "key header")
  check("Sec-WebSocket-Version: 13\r\n" in req, "version header")
  check("Sec-WebSocket-Protocol: chat, superchat\r\n" in req, "subprotocol header")
  check("Authorization: Bearer token\r\n" in req, "custom header")
  check(req.endsWith("\r\n\r\n"), "request terminator")

proc testHandshakeValidation() =
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let goodResp =
    "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: keep-alive, Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & webSocketAccept(key) & "\r\n" &
    "\r\n"
  check(validateUpgradeResponse(goodResp, key), "valid 101 response")

  let badAccept = goodResp.replace(webSocketAccept(key), "invalid")
  check(not validateUpgradeResponse(badAccept, key), "reject wrong accept")

  let badStatus = goodResp.replace("101 Switching Protocols", "200 OK")
  check(not validateUpgradeResponse(badStatus, key), "reject non-101")
  check(validateUpgradeResponse(goodResp), "keyless validator accepts strict 101 upgrade shape")

  let forged =
    "HTTP/1.1 200 OK\r\n" &
    "X-Test: 101 upgrade websocket\r\n" &
    "\r\n"
  check(not validateUpgradeResponse(forged), "keyless validator rejects forged non-upgrade text")

  let missingConnection =
    "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\n\r\n"
  check(not validateUpgradeResponse(missingConnection), "keyless validator requires Connection upgrade token")

testAcceptCalculation()
testHandshakeBuilder()
testHandshakeValidation()

echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
