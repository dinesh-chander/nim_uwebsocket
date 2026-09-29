import std/[random, options, strutils]
import ../nim_fasthttpclient/src/nim_fasthttpclient/types
import ../nim_fasthttpclient/src/nim_fasthttpclient/ws_client

const
  Iterations = 10_000
  ProgressInterval = 1000

var rng = initRand(42)
var totalIterations = 0
var failures: seq[string]

proc fail(label, msg: string) =
  failures.add label & ": " & msg

proc randomBytes(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(255))

proc randomByteSeq(n: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte(rng.rand(255))

template fuzzCategory(name: string, iters: int, body: untyped) =
  echo "Category: ", name
  for i {.inject.} in 0 ..< iters:
    try:
      body
    except CatchableError:
      discard
    inc totalIterations
    if totalIterations mod ProgressInterval == 0:
      echo "  progress: ", totalIterations

echo "=== Fuzz WebSocket Client ==="

fuzzCategory("Frame build/parse roundtrip", Iterations):
  let opcodes = [woText, woBinary, woPing, woPong, woClose]
  let opcode = opcodes[rng.rand(opcodes.high)]
  let maxPayload = if opcode in {woPing, woPong, woClose}: 125 else: rng.rand(4096)
  let payload = randomBytes(rng.rand(maxPayload))
  let masked = rng.rand(1) == 1
  let encoded = encodeWsFrame(opcode, payload, fin = true, masked = masked)
  let encodedBytes = cast[seq[byte]](encoded)
  var pos = 0
  let decoded = decodeWsFrame(encodedBytes, pos)
  if decoded.isNone:
    fail("roundtrip_" & $i, "failed to decode encoded frame")
  else:
    let f = decoded.get()
    if f.payload != payload:
      fail("roundtrip_" & $i, "payload mismatch")
    if f.opcode != opcode:
      fail("roundtrip_" & $i, "opcode mismatch")

fuzzCategory("Large payloads (> 65535 bytes, 8-byte length)", 100):
  let payloadLen = 65536 + rng.rand(10000)
  let payload = randomBytes(payloadLen)
  let encoded = encodeWsFrame(woBinary, payload, fin = true, masked = true)
  let encodedBytes = cast[seq[byte]](encoded)
  var pos = 0
  let decoded = decodeWsFrame(encodedBytes, pos)
  if decoded.isNone:
    fail("large_payload_" & $i, "failed to decode large frame")
  elif decoded.get().payload.len != payloadLen:
    fail("large_payload_" & $i, "length mismatch")

fuzzCategory("Masked vs unmasked frames", Iterations):
  let payload = randomBytes(rng.rand(200))
  let masked = rng.rand(1) == 1
  let encoded = encodeWsFrame(woText, payload, fin = true, masked = masked)
  let encodedBytes = cast[seq[byte]](encoded)
  var pos = 0
  let decoded = decodeWsFrame(encodedBytes, pos)
  if decoded.isNone:
    fail("mask_" & $i, "failed to decode")
  else:
    if decoded.get().masked != masked:
      fail("mask_" & $i, "mask flag mismatch")
    if decoded.get().payload != payload:
      fail("mask_" & $i, "payload mismatch after masking")

fuzzCategory("Truncated frames", Iterations):
  let payload = randomBytes(rng.rand(200) + 10)
  let encoded = encodeWsFrame(woText, payload, fin = true, masked = true)
  let cutPoint = rng.rand(encoded.len - 1)
  let truncated = cast[seq[byte]](encoded[0 ..< cutPoint])
  var pos = 0
  let decoded = decodeWsFrame(truncated, pos)
  if decoded.isSome:
    fail("truncated_" & $i, "parsed truncated frame")

fuzzCategory("Random bytes fed to decodeWsFrame", Iterations):
  let data = randomByteSeq(rng.rand(512) + 1)
  var pos = 0
  discard decodeWsFrame(data, pos)

fuzzCategory("Upgrade request construction verification", Iterations):
  let hosts = ["localhost", "example.com", "192.168.1.1", "", randomBytes(rng.rand(50))]
  let paths = ["/ws", "/", "/chat/room1", "", randomBytes(rng.rand(50))]
  let ports = [uint16(80), uint16(443), uint16(8080), uint16(rng.rand(65535))]
  let host = hosts[rng.rand(hosts.high)]
  let path = paths[rng.rand(paths.high)]
  let port = ports[rng.rand(ports.high)]
  let key = generateWebSocketKey()
  let req = buildUpgradeRequest(host, path, port, key)
  if "websocket" notin req:
    fail("upgrade_" & $i, "missing websocket in upgrade request")
  if key notin req:
    fail("upgrade_" & $i, "missing key in upgrade request")

fuzzCategory("Invalid opcodes", Iterations):
  let invalidOpcodes = [0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F]
  let opcode = invalidOpcodes[rng.rand(invalidOpcodes.high)]
  var data = newSeq[byte](2 + rng.rand(20))
  data[0] = byte(0x80 or opcode)
  data[1] = byte(rng.rand(125))
  for j in 2 ..< data.len:
    data[j] = byte(rng.rand(255))
  var pos = 0
  let decoded = decodeWsFrame(data, pos)
  if decoded.isSome:
    fail("invalid_opcode_" & $i, "accepted invalid opcode 0x" & $opcode)

fuzzCategory("Control frames with large payloads (> 125 bytes)", Iterations):
  let controlOpcodes = [woClose, woPing, woPong]
  let opcode = controlOpcodes[rng.rand(controlOpcodes.high)]
  let payloadLen = 126 + rng.rand(500)
  let payload = randomBytes(payloadLen)
  let encoded = encodeWsFrame(opcode, payload, fin = true, masked = true)
  let encodedBytes = cast[seq[byte]](encoded)
  var pos = 0
  discard decodeWsFrame(encodedBytes, pos)

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All WebSocket client fuzz tests passed (", totalIterations, " total iterations)"
  quit(0)
