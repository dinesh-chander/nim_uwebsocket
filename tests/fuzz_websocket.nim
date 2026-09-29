import std/[random, strutils, options]
import ../nim_usockets/src/nim_usockets/websocket

const
  Iterations = 10_000
  ProgressInterval = 1000

var rng = initRand(42)
var failures: seq[string]

proc hexDump(data: string): string =
  for i, c in data:
    if i > 0 and i mod 32 == 0: result.add "\n"
    result.add toHex(ord(c), 2) & " "

proc fail(label, msg: string, data: string = "") =
  var entry = label & ": " & msg
  if data.len > 0:
    entry.add "\n" & hexDump(data[0 ..< min(data.len, 256)])
  failures.add entry

proc tryDecode(label: string, data: string) =
  try:
    let res = decodeFrame(data)
    discard res
  except CatchableError:
    discard
  except Defect as e:
    fail(label, "Defect: " & e.msg, data)

proc randomBytes(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(255))

proc randomMask(): array[4, byte] =
  for i in 0 ..< 4:
    result[i] = byte(rng.rand(255))

proc buildFrame(fin: bool, rsv: int, opcode: int, masked: bool, payload: string): string =
  var byte1 = opcode and 0x0F
  if fin: byte1 = byte1 or 0x80
  byte1 = byte1 or ((rsv and 0x07) shl 4)
  result.add char(byte1)

  var lenByte = payload.len
  var maskBit = if masked: 0x80 else: 0
  if payload.len < 126:
    result.add char(maskBit or payload.len)
  elif payload.len < 65536:
    result.add char(maskBit or 126)
    result.add char((payload.len shr 8) and 0xFF)
    result.add char(payload.len and 0xFF)
  else:
    result.add char(maskBit or 127)
    for shift in countdown(56, 0, 8):
      result.add char((payload.len shr shift) and 0xFF)

  if masked:
    let mask = randomMask()
    for b in mask: result.add char(b)
    for i, c in payload:
      result.add char(ord(c) xor int(mask[i mod 4]))
  else:
    result.add payload

echo "=== Fuzz WebSocket Frame Parser ==="

echo "--- Category 1: Random bytes as WebSocket frames ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let data = randomBytes(rng.rand(512) + 1)
  tryDecode("random_bytes_" & $i, data)

echo "--- Category 2: Invalid opcodes ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let invalidOpcodes = [0x3, 0x4, 0x5, 0x6, 0x7, 0xB, 0xC, 0xD, 0xE, 0xF]
  let opcode = invalidOpcodes[rng.rand(invalidOpcodes.high)]
  let data = buildFrame(true, 0, opcode, true, randomBytes(rng.rand(20)))
  let res = decodeFrame(data)
  if res.isSome:
    fail("invalid_opcode_" & $i, "accepted invalid opcode " & $opcode, data)

echo "--- Category 3: Control frames > 125 bytes ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let opcode = [0x8, 0x9, 0xA][rng.rand(2)]
  let payload = randomBytes(rng.rand(500) + 126)
  let data = buildFrame(true, 0, opcode, true, payload)
  let res = decodeFrame(data)
  if res.isSome:
    fail("oversized_control_" & $i, "accepted oversized control frame", data)

echo "--- Category 4: Payload length mismatches ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let payload = randomBytes(rng.rand(100) + 10)
  var data = buildFrame(true, 0, 0x1, true, payload)
  let cutLen = rng.rand(data.len - 1)
  data = data[0 ..< cutLen]
  tryDecode("length_mismatch_" & $i, data)

echo "--- Category 5: Unmasked frames (server expects masked) ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let payload = randomBytes(rng.rand(50))
  let data = buildFrame(true, 0, 0x1, false, payload)
  let res = decodeFrame(data)
  if res.isSome:
    fail("unmasked_" & $i, "accepted unmasked frame", data)

echo "--- Category 6: Fragmented control frames ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let opcode = [0x8, 0x9, 0xA][rng.rand(2)]
  let data = buildFrame(false, 0, opcode, true, randomBytes(rng.rand(10)))
  let res = decodeFrame(data)
  if res.isSome:
    fail("fragmented_control_" & $i, "accepted fragmented control frame", data)

echo "--- Category 7: Close frames with invalid status codes ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let variant = rng.rand(4)
  var closePayload: string
  case variant
  of 0:
    closePayload = newString(1)
    closePayload[0] = char(rng.rand(255))
  of 1:
    let code = rng.rand(999)
    closePayload = newString(2)
    closePayload[0] = char((code shr 8) and 0xFF)
    closePayload[1] = char(code and 0xFF)
  of 2:
    closePayload = ""
  of 3:
    let code = 5000 + rng.rand(1000)
    closePayload = newString(2)
    closePayload[0] = char((code shr 8) and 0xFF)
    closePayload[1] = char(code and 0xFF)
  else:
    closePayload = randomBytes(rng.rand(125))
  let data = buildFrame(true, 0, 0x8, true, closePayload)
  tryDecode("close_code_" & $i, data)

echo "--- Category 8: RSV bits set ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let rsv = rng.rand(6) + 1
  let data = buildFrame(true, rsv, 0x1, true, randomBytes(rng.rand(50)))
  let res = decodeFrame(data)
  if res.isSome:
    fail("rsv_bits_" & $i, "accepted frame with RSV=" & $rsv, data)

echo "--- Category 9: Zero-length payloads ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let opcode = [0x0, 0x1, 0x2, 0x9, 0xA][rng.rand(4)]
  let isFin = rng.rand(1) == 1
  let finForControl = if opcode in {0x8, 0x9, 0xA}: true else: isFin
  let data = buildFrame(finForControl, 0, opcode, true, "")
  tryDecode("zero_payload_" & $i, data)

echo "--- Category 10: Large payload length fields ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  var data = newString(2)
  data[0] = char(0x81)
  data[1] = char(0xFF)
  for shift in countdown(56, 0, 8):
    let byteVal = case rng.rand(2)
      of 0: 0x7F
      of 1: 0xFF
      else: rng.rand(255)
    data.add char(byteVal)
  data.add randomBytes(4)
  tryDecode("huge_payload_" & $i, data)

echo "--- Category 11: Encode/decode roundtrip fuzz ---"
for i in 1 .. Iterations:
  if i mod ProgressInterval == 0: echo "  progress: ", i, "/", Iterations
  let opcodes = [wsText, wsBinary, wsPing, wsPong]
  let opcode = opcodes[rng.rand(opcodes.high)]
  let maxLen = if opcode in {wsPing, wsPong}: 125 else: rng.rand(4096)
  let payload = randomBytes(rng.rand(maxLen))
  let encoded = encodeFrame(opcode, payload, mask = true)
  let decoded = decodeFrame(encoded)
  if decoded.isNone:
    fail("roundtrip_" & $i, "failed to decode validly encoded frame")
  elif decoded.get().message.data != payload:
    fail("roundtrip_" & $i, "payload mismatch after roundtrip")
  elif decoded.get().message.opcode != opcode:
    fail("roundtrip_" & $i, "opcode mismatch: got " & $decoded.get().message.opcode)

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All WebSocket fuzz tests passed (", Iterations * 11, " total iterations)"
  quit(0)
