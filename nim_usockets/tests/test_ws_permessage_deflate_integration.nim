import std/[base64, os, osproc, streams, strtabs, strutils, unittest]
import libdeflate_gzip

include ../src/nim_usockets/http

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0..<s.len:
    result[i] = byte(s[i])

proc fromHex(hexs: string): string =
  result = newStringOfCap(hexs.len div 2)
  var i = 0
  while i + 1 < hexs.len:
    result.add(char(parseHexInt(hexs[i .. i + 1])))
    inc i, 2

proc parseReq(payload: string): Option[HttpRequest] =
  let data = payload.toBytes()
  var totalRequestSize = 0
  var parseError = false
  var parseStatusCode = 400
  parseHttpRequest(
    data, 0, totalRequestSize, false,
    0, "", parseError, parseStatusCode
  )

proc makeWsUpgradeRequest(
  host = "example.test",
  wsKey = "dGhlIHNhbXBsZSBub25jZQ==",
  extraHeaders = ""
): string =
  result =
    "GET /ws HTTP/1.1\r\n" &
    "Host: " & host & "\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Key: " & wsKey & "\r\n" &
    "Sec-WebSocket-Version: 13\r\n"
  if extraHeaders.len > 0:
    result.add(extraHeaders)
  result.add("\r\n")

proc buildMaskedClientFrame(
  opcode: int,
  payload: string,
  fin = true,
  rsv1 = false,
  mask: array[4, byte] = [0x37'u8, 0xfa, 0x21, 0x3d]
): seq[byte] =
  var frame = newSeq[byte]()
  var byte1 = opcode and 0x0F
  if fin:
    byte1 = byte1 or 0x80
  if rsv1:
    byte1 = byte1 or 0x40
  frame.add(byte(byte1))

  let length = payload.len
  if length < 126:
    frame.add(byte(0x80 or length))
  elif length < 65536:
    frame.add(byte(0x80 or 126))
    frame.add(byte((length shr 8) and 0xFF))
    frame.add(byte(length and 0xFF))
  else:
    doAssert false, "test payload too large"

  for b in mask:
    frame.add(b)
  for i in 0..<length:
    frame.add(byte(payload[i]) xor mask[i mod 4])
  result = frame

proc decodeClientFrame(
  rawFrame: seq[byte],
  allowCompressed: bool
): tuple[status: int, opcode: int, payload: string, consumed: int, fin: bool, compressed: bool] =
  var data = rawFrame
  var opcode = 0
  var payload = ""
  var consumed = 0
  var fin = true
  var compressed = false
  let status = decodeWebSocketFrame(
    data, 0, opcode, payload, consumed, fin, compressed, allowCompressed
  )
  (status, opcode, payload, consumed, fin, compressed)

proc parseServerFrame(rawFrame: string): tuple[opcode: int, payload: string, fin: bool, compressed: bool] =
  check rawFrame.len >= 2
  let byte1 = ord(rawFrame[0])
  let byte2 = ord(rawFrame[1])
  check (byte2 and 0x80) == 0

  result.fin = (byte1 and 0x80) != 0
  result.compressed = (byte1 and 0x40) != 0
  result.opcode = byte1 and 0x0F

  var payloadLen = byte2 and 0x7F
  var pos = 2
  if payloadLen == 126:
    check rawFrame.len >= 4
    payloadLen = (ord(rawFrame[2]) shl 8) or ord(rawFrame[3])
    pos = 4
  elif payloadLen == 127:
    check rawFrame.len >= 10
    payloadLen = 0
    for i in 0..7:
      payloadLen = (payloadLen shl 8) or ord(rawFrame[2 + i])
    pos = 10

  check rawFrame.len == pos + payloadLen
  result.payload = rawFrame.substr(pos, rawFrame.high)

proc verifyLiveCompressedEcho(port: int, payload: string) =
  let pythonExe = findExe("python3")
  if pythonExe.len == 0:
    raise newException(OSError, "python3 executable not found in PATH")
  let script = """
import base64, socket, struct, sys, zlib
port = int(sys.argv[1])
payload = base64.b64decode(sys.argv[2])
comp = zlib.compressobj(level=1, wbits=-15)
wire = comp.compress(payload) + comp.flush(zlib.Z_SYNC_FLUSH)
wire = wire[:-4]
mask = b"\x37\xfa\x21\x3d"
masked = bytes(b ^ mask[i % 4] for i, b in enumerate(wire))
frame = bytes([0xC1, 0x80 | len(wire)]) + mask + masked
s = socket.create_connection(("127.0.0.1", port), timeout=5)
req = (
    "GET / HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{port}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
).encode()
s.sendall(req)
resp = b""
while b"\r\n\r\n" not in resp:
    chunk = s.recv(1024)
    if not chunk:
        raise SystemExit("closed during handshake")
    resp += chunk
hdr = resp.decode("latin1")
if "101 Switching Protocols" not in hdr:
    raise SystemExit("missing 101 response")
if "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover" not in hdr:
    raise SystemExit("missing negotiated permessage-deflate response")
s.sendall(frame)
head = s.recv(2)
if not head:
    raise SystemExit("missing websocket reply frame")
length = head[1] & 0x7F
if length == 126:
    length = struct.unpack("!H", s.recv(2))[0]
elif length == 127:
    length = struct.unpack("!Q", s.recv(8))[0]
reply = b""
while len(reply) < length:
    chunk = s.recv(length - len(reply))
    if not chunk:
        raise SystemExit("closed during websocket reply frame")
    reply += chunk
if not (head[0] & 0x80):
    raise SystemExit("reply frame was fragmented")
if (head[0] & 0x0F) != 0x1:
    raise SystemExit("reply opcode was not text")
if not (head[0] & 0x40):
    raise SystemExit("reply frame was not compressed")
inflater = zlib.decompressobj(wbits=-15)
plain = inflater.decompress(reply + b"\x00\x00\xff\xff")
if plain != payload:
    raise SystemExit("reply payload mismatch")
s.close()
"""
  let client = startProcess(
    pythonExe,
    args = @["-c", script, $port, encode(payload)],
    options = {poStdErrToStdOut}
  )
  let exitCode = waitForExit(client, 10000)
  let output =
    if client.outputStream != nil:
      client.outputStream.readAll()
    else:
      ""
  close(client)
  if exitCode != 0:
    raise newException(IOError, "python websocket client failed:\n" & output)

const
  LivePort = 9321

proc waitForServerWarmup() =
  sleep(1500)

proc compileExpressFixture(repoRoot, serverBin: string) =
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    raise newException(OSError, "nim executable not found in PATH")
  # macOS GCD builds of uSockets need CoreFoundation at link time; Linux needs
  # pthread/dl. Wrong flags here fail the fixture compile with a bare exit 1.
  let linkFlags =
    when defined(macosx):
      "--passL:\"nim_usockets/usockets/uSockets.a -framework CoreFoundation\""
    else:
      "--passL:\"nim_usockets/usockets/uSockets.a -lpthread -ldl\""
  var cmd = "\"" & nimExe & "\" c -d:release"
  cmd.add " --path:nim_utils/src --path:nim_usockets/src"
  cmd.add " --path:vendor/zippy/src --path:vendor/checksums"
  cmd.add " " & linkFlags
  cmd.add " -o:\"" & serverBin & "\""
  cmd.add " nim_express/tests/ws_permessage_deflate_integration_server.nim"
  let (compileOut, exitCode) = execCmdEx(cmd, options = {poUsePath}, workingDir = repoRoot)
  if exitCode != 0:
    echo "[fixture compile failed]\n" & compileOut
  check exitCode == 0

suite "WebSocket permessage-deflate integration":
  test "upgrade negotiation and compressed echo frame round-trip":
    var options = defaultServerOptions()
    options.wsCompressionEnabled = true
    options.wsCompressionServerNoContextTakeover = true
    options.wsCompressionClientNoContextTakeover = true
    options.wsCompressionMinBytes = 1
    options.wsCompressionMinSavingsBytes = 0

    let reqOpt = parseReq(
      makeWsUpgradeRequest(
        extraHeaders = "Sec-WebSocket-Extensions: permessage-deflate\r\n"
      )
    )
    require reqOpt.isSome
    let req = reqOpt.get()

    let validation = validateWebSocketUpgrade(req)
    check validation.ok
    check validation.statusCode == 101

    let negotiated = negotiateWsCompressionHeader(
      req.requestWsExtensionsHeader(),
      options
    )
    check negotiated == "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n"

    let accept = generateAcceptKey(req.requestWsKeyHeader())
    check accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    let original = repeat("permessage-deflate echo payload ", 3)
    let clientCompressed = compressWsPayload(original)
    require clientCompressed.ok
    check clientCompressed.compressed.len > 0
    check clientCompressed.compressed.len < original.len
    check clientCompressed.compressed.len < 126

    let clientFrame = buildMaskedClientFrame(
      0x1,
      clientCompressed.compressed,
      rsv1 = true
    )
    let decoded = decodeClientFrame(clientFrame, allowCompressed = true)
    check decoded.status == 1
    check decoded.fin
    check decoded.compressed
    check decoded.opcode == 0x1
    check decoded.consumed == clientFrame.len

    let inflated = decompressWsPayload(decoded.payload, original.len * 4)
    check inflated.ok
    check inflated.plain == original

    # Browser clients send sync-flushed raw DEFLATE messages with the
    # RFC 7692 0x00 0x00 0xFF 0xFF trailer removed. This sample was
    # generated from Python zlib raw deflate + Z_SYNC_FLUSH for
    # "hello compressed", then trimmed per permessage-deflate.
    let browserStyleCompressed = fromHex("ca48cdc9c95748cecf2d284a2d2e4e4d0100")
    let browserInflated = decompressWsPayload(browserStyleCompressed, 128)
    check browserInflated.ok
    check browserInflated.plain == "hello compressed"

    let rawDeflateSource = "raw libdeflate websocket codec"
    var compressor = libdeflate_gzip.newCompressor(1)
    let bound = compressor.compressDeflateBound(rawDeflateSource.len)
    require bound > 0
    var rawCompressed = newString(bound)
    let rawWritten = compressor.compressDeflate(
      unsafeAddr rawDeflateSource[0],
      rawDeflateSource.len,
      addr rawCompressed[0],
      rawCompressed.len
    )
    require rawWritten > 0
    rawCompressed.setLen(rawWritten)

    var decompressor = libdeflate_gzip.newDecompressor()
    var rawInflated = newString(256)
    var rawRead = 0
    var rawOut = 0
    let rawRc = decompressor.decompressDeflate(
      unsafeAddr rawCompressed[0],
      rawCompressed.len,
      addr rawInflated[0],
      rawInflated.len,
      rawRead,
      rawOut
    )
    check rawRc == libdeflate_gzip.Success
    check rawRead == rawCompressed.len
    rawInflated.setLen(rawOut)
    check rawInflated == rawDeflateSource

    let serverCompressed = compressWsPayload(inflated.plain)
    require serverCompressed.ok
    check serverCompressed.compressed.len < 126
    let serverFrame = buildWsFrame(
      wsText,
      serverCompressed.compressed,
      rsv1 = true
    )
    let parsedServer = parseServerFrame(serverFrame)
    check parsedServer.fin
    check parsedServer.compressed
    check parsedServer.opcode == ord(wsText)

    let roundtrip = decompressWsPayload(parsedServer.payload, original.len * 4)
    check roundtrip.ok
    check roundtrip.plain == original

  test "nim_express accepts repeated compressed websocket connections":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let serverBin = repoRoot / "nim_express" / "tests" / "ws_permessage_deflate_integration_server"
    let logPath = repoRoot / "nim_express" / "tests" / "ws_permessage_deflate_integration_server.log"
    if fileExists(logPath):
      removeFile(logPath)
    compileExpressFixture(repoRoot, serverBin)

    var serverProc: Process
    try:
      serverProc = startProcess(
        serverBin,
        workingDir = repoRoot / "nim_express",
        env = newStringTable({
          "NIM_EXPRESS_WS_PORT": $LivePort,
          "NIM_EXPRESS_WS_LOG": logPath
        })
      )
      waitForServerWarmup()
      let probeScript =
        "set -euo pipefail\n" &
        "for i in 1 2 3; do\n" &
        "  exec 3<>/dev/tcp/127.0.0.1/" & $LivePort & "\n" &
        "  printf \"GET / HTTP/1.1\\r\\nHost: 127.0.0.1:" & $LivePort & "\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\nSec-WebSocket-Version: 13\\r\\nSec-WebSocket-Extensions: permessage-deflate\\r\\n\\r\\n\" >&3\n" &
        "  headers=''\n" &
        "  while IFS= read -r -u 3 line; do\n" &
        "    headers+=\"$line\\n\"\n" &
        "    [ \"$line\" = $'\\r' ] && break\n" &
        "  done\n" &
        "  echo \"$headers\" | grep -q \"101 Switching Protocols\"\n" &
        "  echo \"$headers\" | grep -q \"Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\"\n" &
        "  exec 3>&-\n" &
        "done\n"
      let clientProc = startProcess(
        "/bin/bash",
        workingDir = repoRoot / "nim_express",
        args = @["-lc", probeScript]
      )
      let clientExit = waitForExit(clientProc, 10000)
      close(clientProc)
      check clientExit == 0
      for i in 0..<3:
        try:
          verifyLiveCompressedEcho(
            LivePort,
            repeat("compressed websocket roundtrip payload ", 3) & $i
          )
        except CatchableError as err:
          checkpoint("server peekExitCode=" & $peekExitCode(serverProc))
          if fileExists(logPath):
            checkpoint("server log:\n" & readFile(logPath))
          raise err
    finally:
      if serverProc != nil:
        terminate(serverProc)
        discard waitForExit(serverProc, 3000)
        close(serverProc)
