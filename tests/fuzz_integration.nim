import std/[random, strutils, net, os]

const
  Iterations = 5_000
  SlowIterations = 500
  ProgressInterval = 100
  ReadTimeout = 200

var rng = initRand(42)
var failures: seq[string]
var ServerPort: int
var serverPid: int

proc hexDump(data: string): string =
  let cap = min(data.len, 256)
  for i in 0 ..< cap:
    if i > 0 and i mod 32 == 0: result.add "\n"
    result.add toHex(ord(data[i]), 2) & " "

proc fail(label, msg: string, data: string = "") =
  var entry = label & ": " & msg
  if data.len > 0:
    entry.add "\n" & hexDump(data)
  failures.add entry

proc randomBytes(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(255))

proc randomPrintable(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(93) + 33)

proc startServer(): bool =
  let appDir = getAppDir()
  let binPath = appDir / "fuzz_integration_server"
  if not fileExists(binPath):
    echo "Server binary not found at: ", binPath
    return false
  let pidFile = getTempDir() / "fuzz_integ_" & $ServerPort & ".pid"
  let logFile = getTempDir() / "fuzz_integ_" & $ServerPort & ".log"
  discard execShellCmd(binPath & " " & $ServerPort &
    " > " & logFile & " 2>&1 & echo $! > " & pidFile)
  sleep(500)
  if fileExists(pidFile):
    let pidStr = readFile(pidFile).strip()
    if pidStr.len > 0:
      serverPid = parseInt(pidStr)
  for attempt in 0 ..< 20:
    try:
      var sock = newSocket()
      sock.connect("127.0.0.1", Port(ServerPort))
      sock.send("GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      let resp = sock.recv(1024, timeout = 2000)
      sock.close()
      if resp.contains("ok"):
        return true
    except CatchableError:
      sleep(250)
  return false

proc stopServer() =
  try:
    var sock = newSocket()
    sock.connect("127.0.0.1", Port(ServerPort))
    sock.send("GET /shutdown HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    discard sock.recv(100, timeout = ReadTimeout)
    sock.close()
  except CatchableError:
    discard
  sleep(500)
  if serverPid > 0:
    discard execShellCmd("kill -9 " & $serverPid & " 2>/dev/null")

proc restartServer(): bool =
  stopServer()
  sleep(500)
  ServerPort = ServerPort + 1
  result = startServer()
  if result:
    echo "  Server restarted on port ", ServerPort

proc trySend(label: string, data: string, expectResponse: bool = false): bool =
  try:
    var sock = newSocket(buffered = false)
    sock.connect("127.0.0.1", Port(ServerPort), timeout = 200)
    sock.send(data)
    if expectResponse:
      try:
        discard sock.recv(4096, timeout = 200)
      except TimeoutError:
        discard
    sock.close()
    return true
  except CatchableError:
    return false

proc trySendExpectResponse(label: string, data: string): string =
  try:
    var sock = newSocket()
    sock.connect("127.0.0.1", Port(ServerPort), timeout = 2000)
    sock.send(data)
    try:
      result = sock.recv(8192, timeout = 2000)
    except TimeoutError:
      result = ""
    sock.close()
  except CatchableError:
    result = ""

proc checkServerAlive(): bool =
  for attempt in 0 ..< 3:
    try:
      let resp = trySendExpectResponse("health_check",
        "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      if resp.contains("ok"):
        return true
    except CatchableError:
      discard
    sleep(500)
  return false

ServerPort = 19876 + rng.rand(1000)

echo "=== Fuzz Integration Tests ==="
echo "Starting server on port ", ServerPort, "..."

if not startServer():
  echo "FATAL: Could not start test server"
  echo "Make sure to build fuzz_integration_server first"
  stopServer()
  quit(1)

echo "Server ready on port ", ServerPort

echo "--- Category 1: Raw TCP with random bytes ---"
var serverCrashes = 0
block rawTcpBlock:
  for i in 1 .. Iterations:
    if i mod ProgressInterval == 0:
      echo "  progress: ", i, "/", Iterations
    if i mod 50 == 0:
      if not checkServerAlive():
        fail("random_tcp_" & $i, "server crashed from random bytes")
        inc serverCrashes
        if serverCrashes > 5:
          echo "  Server keeps crashing on random bytes (", serverCrashes, " times), moving on"
          break rawTcpBlock
        if not restartServer():
          echo "  Could not restart server"
          break rawTcpBlock
    let data = randomBytes(rng.rand(2048) + 1)
    discard trySend("random_tcp_" & $i, data)

echo "--- Category 2: Slowloris-style partial requests ---"
let slowlorisIters = min(Iterations, 500)
for i in 1 .. slowlorisIters:
  if i mod 100 == 0:
    echo "  progress: ", i, "/", slowlorisIters
  try:
    var sock = newSocket(buffered = false)
    sock.connect("127.0.0.1", Port(ServerPort), timeout = 1000)
    let partialHeader = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Slow: "
    sock.send(partialHeader)
    let chunks = rng.rand(3) + 1
    for c in 0 ..< chunks:
      sleep(rng.rand(5))
      sock.send(randomPrintable(rng.rand(20) + 1))
    sock.close()
  except CatchableError:
    discard

if not checkServerAlive():
  fail("slowloris", "server died during slowloris test")
  discard restartServer()

echo "--- Category 3: WebSocket upgrade with invalid headers ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0:
    echo "  progress: ", i, "/", Iterations
    if not checkServerAlive():
      fail("ws_upgrade_" & $i, "server died during ws upgrade test")
      if not restartServer(): break
  let variant = rng.rand(7)
  var req: string
  case variant
  of 0:
    req = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n\r\n"
  of 1:
    req = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
  of 2:
    req = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " &
          randomPrintable(rng.rand(50)) & "\r\nSec-WebSocket-Version: 13\r\n\r\n"
  of 3:
    req = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: " &
          $rng.rand(20) & "\r\n\r\n"
  of 4:
    req = "POST / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" &
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
  of 5:
    req = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: WEBSOCKET\r\nConnection: upgrade\r\n" &
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
  of 6:
    req = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" &
          "Sec-WebSocket-Key: \r\nSec-WebSocket-Version: 13\r\n\r\n"
  else:
    req = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" &
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 0\r\n\r\n"
  discard trySend("ws_upgrade_" & $i, req, expectResponse = true)

echo "--- Category 4: Rapid connect/disconnect ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0:
    echo "  progress: ", i, "/", Iterations
    if not checkServerAlive():
      fail("rapid_cd_" & $i, "server died during rapid connect/disconnect")
      if not restartServer(): break
  try:
    var sock = newSocket()
    sock.connect("127.0.0.1", Port(ServerPort))
    if rng.rand(2) == 0:
      sock.send(randomBytes(rng.rand(10)))
    sock.close()
  except CatchableError:
    discard

echo "--- Category 5: Mixed HTTP and WebSocket on same connection ---"
for i in 1 .. SlowIterations:
  if i mod ProgressInterval == 0:
    echo "  progress: ", i, "/", SlowIterations
    if not checkServerAlive():
      fail("mixed_" & $i, "server died during mixed protocol test")
      if not restartServer(): break
  try:
    var sock = newSocket()
    sock.connect("127.0.0.1", Port(ServerPort))
    sock.send("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
    try:
      discard sock.recv(4096, timeout = ReadTimeout)
    except TimeoutError:
      discard
    var wsNoise = newString(rng.rand(100) + 2)
    wsNoise[0] = char(0x81)
    wsNoise[1] = char(rng.rand(125))
    for j in 2 ..< wsNoise.len:
      wsNoise[j] = char(rng.rand(255))
    sock.send(wsNoise)
    try:
      discard sock.recv(4096, timeout = ReadTimeout)
    except TimeoutError:
      discard
    sock.close()
  except CatchableError:
    discard

echo "--- Category 6: Very large request bodies ---"
let largeBodyIters = min(Iterations, 1000)
for i in 1 .. largeBodyIters:
  if i mod ProgressInterval == 0:
    echo "  progress: ", i, "/", largeBodyIters
  let bodySize = rng.rand(100_000) + 10_000
  let body = randomBytes(bodySize)
  let req = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: " &
            $bodySize & "\r\n\r\n" & body
  discard trySend("large_body_" & $i, req, expectResponse = true)

if not checkServerAlive():
  fail("large_body", "server died during large body test")
  discard restartServer()

echo "--- Category 7: Pipelined requests ---"
for i in 1 .. SlowIterations:
  if i mod ProgressInterval == 0:
    echo "  progress: ", i, "/", SlowIterations
    if not checkServerAlive():
      fail("pipeline_" & $i, "server died during pipeline test")
      if not restartServer(): break
  try:
    var sock = newSocket()
    sock.connect("127.0.0.1", Port(ServerPort))
    let numReqs = rng.rand(10) + 2
    var pipeline = ""
    for j in 0 ..< numReqs:
      pipeline.add "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
    sock.send(pipeline)
    try:
      discard sock.recv(8192, timeout = ReadTimeout)
    except TimeoutError:
      discard
    sock.close()
  except CatchableError:
    discard

echo ""
echo "Stopping server..."
stopServer()

if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All integration fuzz tests passed"
  quit(0)
