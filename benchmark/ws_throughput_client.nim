import std/[asyncdispatch, asyncnet, net, strutils, times, os, base64, sha1, random, monotimes]

const
  Clients = 100
  DurationSec = 10
  PayloadSize = 64
  MaxInflight = 16
  WsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type
  WsClient = ref object
    sock: AsyncSocket
    inflight: int
    sent: int
    recv: int

var
  totalSent = 0
  totalRecv = 0
  payload: string

proc generateKey(): string =
  var buf: array[16, byte]
  for i in 0..<16: buf[i] = byte(rand(255))
  result = encode(buf)

proc buildFrame(data: string, masked: bool): string =
  let dataLen = data.len
  result = newStringOfCap(dataLen + 14)
  result.add(char(0x81))
  let maskBit = if masked: 0x80 else: 0
  if dataLen < 126:
    result.add(char(maskBit or dataLen))
  elif dataLen < 65536:
    result.add(char(maskBit or 126))
    result.add(char((dataLen shr 8) and 0xFF))
    result.add(char(dataLen and 0xFF))
  else:
    result.add(char(maskBit or 127))
    for i in countdown(7, 0):
      result.add(char((dataLen shr (i * 8)) and 0xFF))
  if masked:
    var maskKey: array[4, byte]
    for i in 0..3: maskKey[i] = byte(rand(255))
    for b in maskKey: result.add(char(b))
    for i in 0..<dataLen:
      result.add(char(byte(data[i]) xor maskKey[i mod 4]))
  else:
    result.add(data)

proc doHandshake(sock: AsyncSocket, host: string, port: int): Future[bool] {.async.} =
  let key = generateKey()
  let req = "GET / HTTP/1.1\r\nHost: " & host & ":" & $port &
    "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " &
    key & "\r\nSec-WebSocket-Version: 13\r\n\r\n"
  await sock.send(req)
  var headers = ""
  while true:
    let line = await sock.recvLine()
    if line == "\r\n" or line == "": break
    headers.add(line & "\n")
  return headers.contains("101")

proc readFrame(sock: AsyncSocket): Future[string] {.async.} =
  let h = await sock.recv(2)
  if h.len < 2: return ""
  let payloadLen = int(h[1]) and 0x7F
  var actualLen: int
  if payloadLen < 126:
    actualLen = payloadLen
  elif payloadLen == 126:
    let ext = await sock.recv(2)
    if ext.len < 2: return ""
    actualLen = (int(ext[0]) shl 8) or int(ext[1])
  else:
    let ext = await sock.recv(8)
    if ext.len < 8: return ""
    actualLen = 0
    for i in 0..7:
      actualLen = (actualLen shl 8) or int(ext[i])
  if actualLen == 0: return ""
  result = await sock.recv(actualLen)

proc runClient(id: int, host: string, port: int, deadline: MonoTime): Future[tuple[sent, recv: int]] {.async.} =
  var sock = newAsyncSocket()
  try:
    await sock.connect(host, Port(port))
    let ok = await sock.doHandshake(host, port)
    if not ok:
      return (0, 0)
  except:
    return (0, 0)

  let frame = buildFrame(payload, true)
  var sent = 0
  var recv = 0
  var inflight = 0

  proc pump() {.async.} =
    while getMonoTime() < deadline and inflight < MaxInflight:
      try:
        await sock.send(frame)
        inc sent
        inc inflight
      except:
        break

  proc reader() {.async.} =
    while getMonoTime() < deadline:
      try:
        let data = await sock.readFrame()
        if data.len == 0: break
        inc recv
        dec inflight
        if getMonoTime() < deadline and inflight < MaxInflight:
          try:
            await sock.send(frame)
            inc sent
            inc inflight
          except:
            break
      except:
        break

  await pump()
  await reader()

  try: sock.close()
  except: discard

  return (sent, recv)

proc main() {.async.} =
  randomize()
  payload = newString(PayloadSize)
  for i in 0..<PayloadSize:
    payload[i] = chr(65 + (i mod 26))

  let host = "127.0.0.1"
  let port = 3400
  let deadline = getMonoTime() + initDuration(seconds = DurationSec)

  echo "Starting ", Clients, " WS clients to ws://", host, ":", port, " for ", DurationSec, "s..."

  var futures: seq[Future[tuple[sent, recv: int]]]
  for i in 0..<Clients:
    futures.add(runClient(i, host, port, deadline))

  var totalS = 0
  var totalR = 0
  for f in futures:
    let r = await f
    totalS += r.sent
    totalR += r.recv

  echo "Sent: ", totalS, " Recv: ", totalR
  echo "Throughput: ", formatFloat(float(totalR) / float(DurationSec), ffDecimal, 0), " msg/sec"

waitFor main()
