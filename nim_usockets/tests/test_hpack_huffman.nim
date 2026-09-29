import ../src/nim_usockets/hpack

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0..<s.len:
    result[i] = byte(s[i])

echo "=== HPACK Huffman Tests ==="

echo "--- huffmanEncode/Decode round-trip ---"
block roundTripEmpty:
  var encoded = ""
  huffmanEncode(toBytes(""), encoded)
  check(encoded.len == 0, "empty input encodes to empty")
  var decoded = ""
  huffmanDecode(toBytes(encoded), decoded)
  check(decoded == "", "empty round-trips")

block roundTripSingleChar:
  for ch in ['a', 'A', '0', ' ', '/', ':', '-', '.', '_']:
    var encoded = ""
    huffmanEncode(@[byte(ch)], encoded)
    var decoded = ""
    huffmanDecode(toBytes(encoded), decoded)
    check(decoded == $ch, "single char '" & $ch & "' round-trips")

block roundTripAlphaLower:
  let src = "abcdefghijklmnopqrstuvwxyz"
  var encoded = ""
  huffmanEncode(toBytes(src), encoded)
  var decoded = ""
  huffmanDecode(toBytes(encoded), decoded)
  check(decoded == src, "lowercase alphabet round-trips")

block roundTripAlphaUpper:
  let src = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  var encoded = ""
  huffmanEncode(toBytes(src), encoded)
  var decoded = ""
  huffmanDecode(toBytes(encoded), decoded)
  check(decoded == src, "uppercase alphabet round-trips")

block roundTripDigits:
  let src = "0123456789"
  var encoded = ""
  huffmanEncode(toBytes(src), encoded)
  var decoded = ""
  huffmanDecode(toBytes(encoded), decoded)
  check(decoded == src, "digits round-trip")

block roundTripCommonHeaders:
  let strs = [
    "www.example.com",
    "no-cache",
    "custom-key",
    "custom-value",
    "text/html; charset=utf-8",
    "application/json",
    "gzip, deflate",
    "/index.html",
    "Mon, 21 Oct 2013 20:13:22 GMT",
    "https://www.example.com",
  ]
  for s in strs:
    var encoded = ""
    huffmanEncode(toBytes(s), encoded)
    var decoded = ""
    huffmanDecode(toBytes(encoded), decoded)
    check(decoded == s, "common header '" & s & "' round-trips")

block roundTripSpecialChars:
  let src = "!@#$%^&*()+=[]{}|;:',.<>?/~`"
  var encoded = ""
  huffmanEncode(toBytes(src), encoded)
  var decoded = ""
  huffmanDecode(toBytes(encoded), decoded)
  check(decoded == src, "special chars round-trip")

block roundTripLongString:
  var src = ""
  for i in 0..999:
    src.add(char(32 + (i mod 95)))
  var encoded = ""
  huffmanEncode(toBytes(src), encoded)
  var decoded = ""
  huffmanDecode(toBytes(encoded), decoded)
  check(decoded == src, "1000-char string round-trips")
  check(decoded.len == src.len, "1000-char string length preserved")

block roundTripAllPrintableASCII:
  var src = ""
  for i in 32..126:
    src.add(char(i))
  var encoded = ""
  huffmanEncode(toBytes(src), encoded)
  var decoded = ""
  huffmanDecode(toBytes(encoded), decoded)
  check(decoded == src, "all printable ASCII round-trips")

block roundTripHighBytes:
  for ch in [128, 200, 255]:
    var src: seq[byte] = @[byte(ch)]
    var encoded = ""
    huffmanEncode(src, encoded)
    var decoded = ""
    huffmanDecode(toBytes(encoded), decoded)
    check(decoded.len == 1, "high byte " & $ch & " round-trip length")
    check(byte(decoded[0]) == byte(ch), "high byte " & $ch & " round-trips")

echo "--- huffmanEncodeStr ---"
block encodeStrRoundTrip:
  let src = "www.example.com"
  let encoded = huffmanEncodeStr(src)
  var decoded = ""
  huffmanDecode(toBytes(encoded), decoded)
  check(decoded == src, "huffmanEncodeStr round-trips")

echo "--- huffmanDecodeStr ---"
block decodeStrRoundTrip:
  var encoded = ""
  huffmanEncode(toBytes("hello"), encoded)
  let decoded = huffmanDecodeStr(toBytes(encoded))
  check(decoded == "hello", "huffmanDecodeStr round-trips")

echo "--- huffmanEncodedLen ---"
block encodedLenEmpty:
  check(huffmanEncodedLen(@[]) == 0, "encoded len of empty is 0")

block encodedLenSingle:
  let l = huffmanEncodedLen(@[byte('0')])
  check(l == 1, "encoded len of '0' (5-bit code) is 1 byte")

block encodedLenMultiple:
  let src = toBytes("www.example.com")
  let calculated = huffmanEncodedLen(src)
  var encoded = ""
  huffmanEncode(src, encoded)
  check(calculated == encoded.len, "huffmanEncodedLen matches actual encoded length")

block encodedLenVsActual:
  let strs = ["hello", "world", "/index.html", "application/json", "no-cache"]
  for s in strs:
    let src = toBytes(s)
    let calculated = huffmanEncodedLen(src)
    var encoded = ""
    huffmanEncode(src, encoded)
    check(calculated == encoded.len, "encodedLen matches actual for '" & s & "'")

echo "--- Huffman compression ratio ---"
block compressionEfficiency:
  let src = "www.example.com"
  var encoded = ""
  huffmanEncode(toBytes(src), encoded)
  check(encoded.len < src.len, "huffman encoding is shorter for typical header value")

block compressionLowercase:
  let src = "aaaaaaaaaa"
  var encoded = ""
  huffmanEncode(toBytes(src), encoded)
  check(encoded.len < src.len, "'a' repeated: huffman shorter")

echo "--- Huffman decode errors ---"
block decodeInvalidCode:
  let data: seq[byte] = @[0xFF'u8, 0xFF, 0xFF, 0xFC]
  var decoded = ""
  var gotError = false
  try:
    huffmanDecode(data, decoded)
  except HpackError:
    gotError = true
  check(gotError, "invalid Huffman code raises error")

block decodeEOSSymbol:
  let eos = HuffmanEncodeTable[256]
  var val = uint64(eos.code)
  let bits = int(eos.bits)
  val = val shl (32 - bits)
  var buf: seq[byte] = @[
    byte((val shr 24) and 0xFF),
    byte((val shr 16) and 0xFF),
    byte((val shr 8) and 0xFF),
    byte(val and 0xFF),
  ]
  var decoded = ""
  var gotError = false
  try:
    huffmanDecode(buf, decoded)
  except HpackError:
    gotError = true
  check(gotError, "EOS symbol raises error")

block decodeIncompletePaddingTooLong:
  var encoded = ""
  huffmanEncode(@[byte('a')], encoded)
  var data = toBytes(encoded)
  data.add(0xFF)
  var decoded = ""
  var gotError = false
  try:
    huffmanDecode(data, decoded)
  except HpackError:
    gotError = true
  check(gotError or decoded == "a", "extra padding byte handled")

block decodeNonOnePadding:
  var encoded = ""
  huffmanEncode(@[byte('a')], encoded)
  var data = toBytes(encoded)
  if data.len > 0:
    data[data.len - 1] = data[data.len - 1] and 0xF0
  var decoded = ""
  var gotError = false
  try:
    huffmanDecode(data, decoded)
  except HpackError:
    gotError = true
  check(gotError, "non-ones padding bits raises error")

echo "--- Huffman encode table structure ---"
block huffmanTableSize:
  check(HuffmanEncodeTable.len == 257, "Huffman table has 257 entries (0-255 + EOS)")

block huffmanTableBitWidths:
  for i in 0..256:
    let entry = HuffmanEncodeTable[i]
    check(entry.bits >= 5 and entry.bits <= 30, "entry " & $i & " bits in range 5-30")

block huffmanTableEOS:
  let eos = HuffmanEncodeTable[256]
  check(eos.bits == 30, "EOS symbol is 30 bits")
  check(eos.code == 0x3FFFFFFF'u32, "EOS code is 0x3FFFFFFF")

block huffmanTableSpace:
  let sp = HuffmanEncodeTable[32]
  check(sp.bits == 6, "space is 6 bits")

block huffmanTableZero:
  let z = HuffmanEncodeTable[48]
  check(z.bits == 5, "'0' is 5 bits")

block huffmanTableLowerA:
  let a = HuffmanEncodeTable[97]
  check(a.bits == 5, "'a' is 5 bits")

echo "--- Huffman max decoded length ---"
block maxDecodedLen:
  check(HuffmanMaxDecodedLen == 65536, "HuffmanMaxDecodedLen is 65536")

echo "--- Huffman with HPACK string codec ---"
block hpackStringHuffmanRoundTrip:
  let strs = [
    "www.example.com",
    "no-cache",
    "custom-key",
    "custom-value",
    "",
    "/",
    "text/html",
    "application/json",
  ]
  for s in strs:
    var buf = ""
    hpackEncodeString(buf, s, true)
    var pos = 0
    let decoded = hpackDecodeString(toBytes(buf), pos)
    check(decoded == s, "hpackString huffman round-trip: '" & s & "'")

block hpackStringPlainRoundTrip:
  let strs = [
    "www.example.com",
    "no-cache",
    "",
    "test",
  ]
  for s in strs:
    var buf = ""
    hpackEncodeString(buf, s, false)
    var pos = 0
    let decoded = hpackDecodeString(toBytes(buf), pos)
    check(decoded == s, "hpackString plain round-trip: '" & s & "'")

block hpackStringHuffmanFlag:
  var bufH = ""
  hpackEncodeString(bufH, "test", true)
  check((byte(bufH[0]) and 0x80) != 0, "huffman-encoded string has H bit set")

  var bufP = ""
  hpackEncodeString(bufP, "test", false)
  check((byte(bufP[0]) and 0x80) == 0, "plain string has H bit clear")

block hpackStringHuffmanShorter:
  var bufH = ""
  hpackEncodeString(bufH, "www.example.com", true)
  var bufP = ""
  hpackEncodeString(bufP, "www.example.com", false)
  check(bufH.len <= bufP.len, "huffman encoded string not longer than plain")

echo "--- RFC 7541 test vectors ---"
block rfc7541_c1_example:
  var buf = ""
  hpackEncodeInt(buf, 10, 5, 0x00)
  check(buf.len == 1, "RFC C.1.1: 10 in 5-bit prefix = 1 byte")
  check(byte(buf[0]) == 0x0A, "RFC C.1.1: value is 0x0A")

block rfc7541_c1_example2:
  var buf = ""
  hpackEncodeInt(buf, 1337, 5, 0x00)
  check(buf.len == 3, "RFC C.1.2: 1337 in 5-bit prefix = 3 bytes")
  check(byte(buf[0]) == 0x1F, "RFC C.1.2: first byte 0x1F")
  check(byte(buf[1]) == 0x9A, "RFC C.1.2: second byte 0x9A")
  check(byte(buf[2]) == 0x0A, "RFC C.1.2: third byte 0x0A")

block rfc7541_c1_example3:
  var buf = ""
  hpackEncodeInt(buf, 42, 8, 0x00)
  check(buf.len == 1, "RFC C.1.3: 42 in 8-bit prefix = 1 byte")
  check(byte(buf[0]) == 0x2A, "RFC C.1.3: value is 0x2A")

echo "--- Full HPACK encode/decode with huffman for various header patterns ---"
block encodeDecodeResponseHeaders:
  var enc = initHpackEncoder(huffman = true)
  var dec = initHpackDecoder()
  let headers = @[
    (":status", "200"),
    ("content-type", "text/html"),
    ("content-length", "1234"),
    ("server", "nim"),
    ("date", "Thu, 01 Jan 2026 00:00:00 GMT"),
  ]
  var buf = ""
  hpackEncode(enc, headers, buf)
  let decoded = hpackDecode(dec, toBytes(buf))
  check(decoded.len == 5, "response headers: 5 decoded")
  check(decoded[0] == (":status", "200"), "response: status 200")
  check(decoded[1] == ("content-type", "text/html"), "response: content-type")
  check(decoded[2] == ("content-length", "1234"), "response: content-length")
  check(decoded[3] == ("server", "nim"), "response: server")

block encodeDecodeEmptyValue:
  var enc = initHpackEncoder(huffman = true)
  var dec = initHpackDecoder()
  let headers = @[("x-empty", "")]
  var buf = ""
  hpackEncode(enc, headers, buf)
  let decoded = hpackDecode(dec, toBytes(buf))
  check(decoded.len == 1, "empty value: 1 header")
  check(decoded[0] == ("x-empty", ""), "empty value preserved")

block encodeDecodeLargeValue:
  var enc = initHpackEncoder(huffman = true)
  var dec = initHpackDecoder()
  let largeVal = newString(2000)
  let headers = @[("x-large", largeVal)]
  var buf = ""
  hpackEncode(enc, headers, buf)
  let decoded = hpackDecode(dec, toBytes(buf))
  check(decoded.len == 1, "large value: 1 header")
  check(decoded[0][0] == "x-large", "large value: name correct")
  check(decoded[0][1].len == 2000, "large value: length preserved")

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
