import std/[net, os, strutils, unittest]

import ../src/nim_usockets/http

const
  CloseBodySize = 32 * 1024
  CloseBodyTail = "io_uring-close-delivery-tail"

proc closeBody(): string =
  result = newString(CloseBodySize)
  for i in 0 ..< result.len:
    result[i] = char(ord('a') + (i mod 26))
  let start = result.len - CloseBodyTail.len
  for i, ch in CloseBodyTail:
    result[start + i] = ch

proc reserveLoopbackPort(): int =
  let sock = newSocket()
  try:
    sock.bindAddr(Port(0), "127.0.0.1")
    let (_, port) = sock.getLocalAddr()
    parseInt($port)
  finally:
    sock.close()

proc runCloseDeliveryServer(port: Port) =
  let server = newHttpServer()
  let body = closeBody()
  stderr.writeLine("close delivery server starting on port " & $port)

  server.handle proc(req: HttpRequest, res: HttpResponse) =
    if req.path == "/close":
      res.setStatus(Http200)
      res.setHeader("content-type", "text/plain")
      res.setConnectionCloseEnabled(true)
      res.`end`(body)
    else:
      res.setStatus(Http200)
      res.setConnectionCloseEnabled(true)
      res.`end`("ready")

  server.onWebSocket proc(ws: WebSocket, message: string, isBinary: bool) =
    if not isBinary and message == "close-ws":
      ws.close(1000, "done")
    else:
      ws.send(message, binary = isBinary)

  server.listen("127.0.0.1", int(port)) do(success: bool):
    if not success:
      stderr.writeLine("close delivery server failed to listen on port " & $port)
      quit(2)
    stderr.writeLine("close delivery server listening on port " & $port)

  server.run()

proc waitForServer(port: int): bool =
  for _ in 0 ..< 80:
    try:
      let sock = newSocket()
      sock.connect("127.0.0.1", Port(port))
      sock.send("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      var response = ""
      while true:
        let chunk = sock.recv(512, timeout = 1000)
        if chunk.len == 0:
          break
        response.add(chunk)
      sock.close()
      if response.contains("ready"):
        return true
    except CatchableError:
      sleep(50)
  false

proc readCloseResponse(port: int): string =
  let sock = newSocket()
  try:
    sock.connect("127.0.0.1", Port(port))
    sock.send("GET /close HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    while true:
      let chunk = sock.recv(64 * 1024, timeout = 5000)
      if chunk.len == 0:
        break
      result.add(chunk)
  finally:
    sock.close()

proc buildMaskedTextFrame(payload: string): string =
  let mask = [0x37'u8, 0xfa'u8, 0x21'u8, 0x3d'u8]
  result.add(char(0x81))
  result.add(char(0x80 or payload.len))
  for b in mask:
    result.add(char(b))
  for i, ch in payload:
    result.add(char(byte(ch) xor mask[i and 3]))

proc parseClosePayload(data: string): tuple[ok: bool, payload: string] =
  if data.len < 2:
    return
  let first = ord(data[0])
  let second = ord(data[1])
  if (first and 0x0F) != 0x8:
    return
  let payloadLen = second and 0x7F
  if (second and 0x80) != 0 or payloadLen > 125:
    return
  if data.len < 2 + payloadLen:
    return
  result.ok = true
  if payloadLen > 0:
    result.payload = data[2 ..< 2 + payloadLen]

proc recvByte(sock: Socket, timeoutMs: int): string =
  sock.recv(1, timeout = timeoutMs)

proc readWebSocketClosePayload(port: int): string =
  let sock = newSocket()
  try:
    sock.connect("127.0.0.1", Port(port))
    sock.send(
      "GET /ws HTTP/1.1\r\n" &
      "Host: localhost\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: Upgrade\r\n" &
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Version: 13\r\n\r\n"
    )

    var handshake = ""
    var frameData = ""
    while handshake.find("\r\n\r\n") < 0:
      let ch = recvByte(sock, 5000)
      if ch.len == 0:
        return ""
      handshake.add(ch)
      let headerEnd = handshake.find("\r\n\r\n")
      if headerEnd >= 0 and headerEnd + 4 < handshake.len:
        frameData = handshake[(headerEnd + 4) .. ^1]
    if not handshake.contains("101"):
      return ""

    sock.send(buildMaskedTextFrame("close-ws"))
    for _ in 0 ..< 20:
      let parsed = parseClosePayload(frameData)
      if parsed.ok:
        return parsed.payload
      let ch = recvByte(sock, 1000)
      if ch.len == 0:
        break
      frameData.add(ch)
    ""
  finally:
    sock.close()

proc readFileOrEmpty(path: string): string =
  if fileExists(path):
    readFile(path)
  else:
    ""

proc startServerProcess(port: int): tuple[pid: int, logFile: string] =
  let base = getTempDir() / ("nim_usockets_close_delivery_" & $getCurrentProcessId() & "_" & $port)
  let pidFile = base & ".pid"
  result.logFile = base & ".log"
  removeFile(pidFile)
  removeFile(result.logFile)
  let command =
    "nohup " & quoteShell(getAppFilename()) & " --server " & $port &
    " > " & quoteShell(result.logFile) & " 2>&1 & echo $! > " & quoteShell(pidFile)
  if execShellCmd(command) != 0:
    raise newException(OSError, "failed to start close delivery server")
  for _ in 0 ..< 20:
    if fileExists(pidFile):
      let raw = readFile(pidFile).strip()
      if raw.len > 0:
        result.pid = parseInt(raw)
        break
    sleep(25)
  if result.pid <= 0:
    raise newException(OSError, "server pid file was not written: " & readFileOrEmpty(result.logFile))

proc stopServerProcess(pid: int) =
  when defined(posix):
    if pid > 0:
      discard execShellCmd("kill -TERM " & $pid & " 2>/dev/null || true")
      sleep(100)
      discard execShellCmd("kill -KILL " & $pid & " 2>/dev/null || true")
  else:
    discard pid

when isMainModule:
  if paramCount() == 2 and paramStr(1) == "--server":
    runCloseDeliveryServer(Port(parseInt(paramStr(2))))
  else:
    suite "io_uring close delivery":
      test "HTTP close response body is delivered before EOF":
        let port = reserveLoopbackPort()
        let serverProcess = startServerProcess(port)
        defer:
          stopServerProcess(serverProcess.pid)
          removeFile(serverProcess.logFile)

        if not waitForServer(port):
          raise newException(AssertionDefect, "server did not become ready: " & readFileOrEmpty(serverProcess.logFile))

        let response = readCloseResponse(port)
        let splitAt = response.find("\r\n\r\n")
        check splitAt >= 0
        let body =
          if splitAt >= 0:
            response[(splitAt + 4) .. ^1]
          else:
            ""
        check response.contains("HTTP/1.1 200")
        check body.len == CloseBodySize
        check body.endsWith(CloseBodyTail)

      test "WebSocket close frame is delivered before EOF":
        let port = reserveLoopbackPort()
        let serverProcess = startServerProcess(port)
        defer:
          stopServerProcess(serverProcess.pid)
          removeFile(serverProcess.logFile)

        if not waitForServer(port):
          raise newException(AssertionDefect, "server did not become ready: " & readFileOrEmpty(serverProcess.logFile))

        let payload = readWebSocketClosePayload(port)
        check payload.len >= 2
        if payload.len >= 2:
          let code = (ord(payload[0]) shl 8) or ord(payload[1])
          check code == 1000
          check payload[2 .. ^1] == "done"
