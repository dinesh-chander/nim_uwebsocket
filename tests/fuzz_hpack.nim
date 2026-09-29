import std/random
import ../nim_usockets/src/nim_usockets/hpack

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

proc randomHeaderName(): string =
  const names = ["content-type", "x-custom", "authorization", "accept",
                 "cache-control", "user-agent", ":method", ":path",
                 ":scheme", ":authority", ":status", "cookie", "set-cookie"]
  names[rng.rand(names.high)]

proc randomHeaderValue(): string =
  let n = rng.rand(200)
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(rng.rand(93) + 33)

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

echo "=== Fuzz HPACK Codec ==="

fuzzCategory("Random bytes fed to hpackDecode", Iterations):
  var decoder = initHpackDecoder()
  let data = randomByteSeq(rng.rand(512) + 1)
  discard hpackDecode(decoder, data)

fuzzCategory("Integer encoding/decoding roundtrip", Iterations):
  let value = rng.rand(1_000_000)
  let prefix = rng.rand(6) + 1
  let prefixByte = uint8(rng.rand(255)) and not uint8((1 shl prefix) - 1)
  var buf = ""
  hpackEncodeInt(buf, value, prefix, prefixByte)
  let encoded = cast[seq[byte]](buf)
  var pos = 0
  let decoded = hpackDecodeInt(encoded, pos, prefix)
  if decoded != value:
    fail("int_roundtrip_" & $i, "mismatch: encoded " & $value & " got " & $decoded)

fuzzCategory("Huffman encode/decode random payloads", Iterations):
  let srcLen = rng.rand(200) + 1
  var src = newString(srcLen)
  for j in 0 ..< srcLen:
    src[j] = char(rng.rand(94) + 32)
  var encodedBuf = ""
  let srcBytes = cast[seq[byte]](src)
  huffmanEncode(srcBytes, encodedBuf)
  var decoded = ""
  let encodedBytes = cast[seq[byte]](encodedBuf)
  huffmanDecode(encodedBytes, decoded)
  if decoded != src:
    fail("huffman_roundtrip_" & $i, "len " & $src.len & " vs " & $decoded.len)

fuzzCategory("HPACK bomb: huge dynamic table size", Iterations):
  var decoder = initHpackDecoder()
  let hugeSize = rng.rand(100_000_000)
  var buf = ""
  hpackEncodeInt(buf, hugeSize, 5, 0x20)
  let data = cast[seq[byte]](buf)
  discard hpackDecode(decoder, data)

fuzzCategory("Truncated HPACK blocks", Iterations):
  var encoder = initHpackEncoder()
  let headers = @[(randomHeaderName(), randomHeaderValue())]
  var encoded = ""
  hpackEncode(encoder, headers, encoded)
  if encoded.len > 0:
    let cutPoint = rng.rand(encoded.len - 1)
    let truncated = cast[seq[byte]](encoded[0 ..< cutPoint])
    var decoder = initHpackDecoder()
    discard hpackDecode(decoder, truncated)

fuzzCategory("Invalid Huffman codes", Iterations):
  let variant = rng.rand(3)
  var data: seq[byte]
  case variant
  of 0:
    data = randomByteSeq(rng.rand(100) + 1)
  of 1:
    data = @[0xFF'u8]
  of 2:
    data = @[0x00'u8, 0x00'u8]
  else:
    data = randomByteSeq(rng.rand(10) + 1)
    if data.len > 0:
      data[^1] = data[^1] and 0xF0
  var decoded = ""
  huffmanDecode(data, decoded)

fuzzCategory("Dynamic table overflow with many large entries", Iterations div 10):
  var dt = initHpackDynamicTable(4096)
  let numEntries = rng.rand(500) + 100
  for j in 0 ..< numEntries:
    let name = randomHeaderName() & "_" & $j
    let value = randomBytes(rng.rand(500) + 1)
    dt.add(name, value)
  assert dt.size <= dt.maxSize

fuzzCategory("Encode/decode roundtrip random headers", Iterations):
  var encoder = initHpackEncoder()
  var decoder = initHpackDecoder()
  let numHeaders = rng.rand(10) + 1
  var headers: seq[(string, string)]
  for j in 0 ..< numHeaders:
    headers.add((randomHeaderName(), randomHeaderValue()))
  var buf = ""
  hpackEncode(encoder, headers, buf)
  let data = cast[seq[byte]](buf)
  let decoded = hpackDecode(decoder, data)
  if decoded.len != headers.len:
    fail("roundtrip_" & $i, "header count mismatch: " & $headers.len & " vs " & $decoded.len)
  else:
    for j in 0 ..< headers.len:
      if decoded[j][0] != headers[j][0] or decoded[j][1] != headers[j][1]:
        fail("roundtrip_" & $i, "header mismatch at " & $j)
        break

fuzzCategory("Static table index boundaries", Iterations):
  var decoder = initHpackDecoder()
  let indices = [0, 1, 2, 61, 62, 1000]
  let idx = indices[rng.rand(indices.high)]
  var buf = ""
  hpackEncodeInt(buf, idx, 7, 0x80)
  let data = cast[seq[byte]](buf)
  discard hpackDecode(decoder, data)

fuzzCategory("Mixed indexed/literal/never-indexed representations", Iterations):
  var decoder = initHpackDecoder()
  let numEntries = rng.rand(10) + 1
  var buf = ""
  for j in 0 ..< numEntries:
    let variant = rng.rand(4)
    case variant
    of 0:
      let idx = rng.rand(61) + 1
      hpackEncodeInt(buf, idx, 7, 0x80)
    of 1:
      hpackEncodeInt(buf, 0, 6, 0x40)
      hpackEncodeString(buf, randomHeaderName(), rng.rand(1) == 1)
      hpackEncodeString(buf, randomHeaderValue(), rng.rand(1) == 1)
    of 2:
      let idx = rng.rand(61) + 1
      hpackEncodeInt(buf, idx, 6, 0x40)
      hpackEncodeString(buf, randomHeaderValue(), rng.rand(1) == 1)
    of 3:
      hpackEncodeInt(buf, 0, 4, 0x10)
      hpackEncodeString(buf, randomHeaderName(), rng.rand(1) == 1)
      hpackEncodeString(buf, randomHeaderValue(), rng.rand(1) == 1)
    else:
      hpackEncodeInt(buf, 0, 4, 0x00)
      hpackEncodeString(buf, randomHeaderName(), rng.rand(1) == 1)
      hpackEncodeString(buf, randomHeaderValue(), rng.rand(1) == 1)
  let data = cast[seq[byte]](buf)
  discard hpackDecode(decoder, data)

fuzzCategory("Multiple dynamic table size updates in a single block", Iterations):
  var decoder = initHpackDecoder()
  var buf = ""
  let numUpdates = rng.rand(10) + 2
  for j in 0 ..< numUpdates:
    let newSize = rng.rand(65536)
    hpackEncodeInt(buf, newSize, 5, 0x20)
  hpackEncodeInt(buf, 0, 6, 0x40)
  hpackEncodeString(buf, "x-test", false)
  hpackEncodeString(buf, "val", false)
  let data = cast[seq[byte]](buf)
  discard hpackDecode(decoder, data)

fuzzCategory("Oversized total header list (SETTINGS_MAX_HEADER_LIST_SIZE)", Iterations):
  var encoder = initHpackEncoder()
  var decoder = initHpackDecoder()
  let numHeaders = rng.rand(100) + 50
  var headers: seq[(string, string)]
  for j in 0 ..< numHeaders:
    let name = "x-header-" & $j
    let value = randomBytes(rng.rand(500) + 100)
    headers.add((name, value))
  var buf = ""
  hpackEncode(encoder, headers, buf)
  let data = cast[seq[byte]](buf)
  discard hpackDecode(decoder, data)

fuzzCategory("Huffman encoded strings exceeding HpackMaxStringLen", Iterations div 10):
  var buf = ""
  let hugeLen = HpackMaxStringLen + rng.rand(10000) + 1
  hpackEncodeInt(buf, hugeLen, 7, 0x80)
  let filler = randomBytes(hugeLen)
  buf.add filler
  let data = cast[seq[byte]](buf)
  var pos = 0
  discard hpackDecodeString(data, pos)

fuzzCategory("Mixed indexed/literal/never-indexed rapid succession", Iterations):
  var encoder = initHpackEncoder()
  var decoder = initHpackDecoder()
  var buf = ""
  let numEntries = rng.rand(30) + 10
  for j in 0 ..< numEntries:
    let variant = rng.rand(5)
    case variant
    of 0:
      let idx = rng.rand(61) + 1
      hpackEncodeInt(buf, idx, 7, 0x80)
    of 1:
      hpackEncodeInt(buf, 0, 6, 0x40)
      hpackEncodeString(buf, randomHeaderName(), rng.rand(1) == 1)
      hpackEncodeString(buf, randomHeaderValue(), rng.rand(1) == 1)
    of 2:
      hpackEncodeInt(buf, 0, 4, 0x10)
      hpackEncodeString(buf, randomHeaderName(), rng.rand(1) == 1)
      hpackEncodeString(buf, randomHeaderValue(), rng.rand(1) == 1)
    of 3:
      hpackEncodeInt(buf, 0, 4, 0x00)
      hpackEncodeString(buf, randomHeaderName(), rng.rand(1) == 1)
      hpackEncodeString(buf, randomHeaderValue(), rng.rand(1) == 1)
    of 4:
      let newSize = rng.rand(4096)
      hpackEncodeInt(buf, newSize, 5, 0x20)
    else:
      let idx = rng.rand(61) + 1
      hpackEncodeInt(buf, idx, 6, 0x40)
      hpackEncodeString(buf, randomHeaderValue(), rng.rand(1) == 1)
  let data = cast[seq[byte]](buf)
  discard hpackDecode(decoder, data)

fuzzCategory("Concurrent encoder/decoder roundtrip (random headers)", Iterations):
  var encoder = initHpackEncoder()
  var decoder = initHpackDecoder()
  let rounds = rng.rand(5) + 1
  for r in 0 ..< rounds:
    let numHeaders = rng.rand(8) + 1
    var headers: seq[(string, string)]
    for j in 0 ..< numHeaders:
      headers.add((randomHeaderName(), randomHeaderValue()))
    var buf = ""
    hpackEncode(encoder, headers, buf)
    let data = cast[seq[byte]](buf)
    let decoded = hpackDecode(decoder, data)
    if decoded.len != headers.len:
      fail("concurrent_roundtrip_" & $i & "_r" & $r, "header count mismatch: " & $headers.len & " vs " & $decoded.len)
      break
    for j in 0 ..< headers.len:
      if decoded[j][0] != headers[j][0] or decoded[j][1] != headers[j][1]:
        fail("concurrent_roundtrip_" & $i & "_r" & $r, "header mismatch at " & $j)
        break

fuzzCategory("Empty header name and value edge cases", Iterations):
  var encoder = initHpackEncoder()
  var decoder = initHpackDecoder()
  let variant = rng.rand(3)
  var headers: seq[(string, string)]
  case variant
  of 0:
    headers = @[("", "somevalue")]
  of 1:
    headers = @[("x-key", "")]
  of 2:
    headers = @[("", "")]
  else:
    headers = @[("", randomHeaderValue()), (randomHeaderName(), "")]
  var buf = ""
  hpackEncode(encoder, headers, buf)
  let data = cast[seq[byte]](buf)
  let decoded = hpackDecode(decoder, data)
  if decoded.len != headers.len:
    fail("empty_header_" & $i, "count mismatch")
  else:
    for j in 0 ..< headers.len:
      if decoded[j][0] != headers[j][0] or decoded[j][1] != headers[j][1]:
        fail("empty_header_" & $i, "header mismatch at " & $j)
        break

echo ""
if failures.len > 0:
  echo "FAILURES: ", failures.len
  for f in failures:
    echo "---"
    echo f
  quit(1)
else:
  echo "All HPACK fuzz tests passed (", totalIterations, " total iterations)"
  quit(0)
