import ../src/nim_usockets/hpack

var passed = 0
var failed = 0

template check(label: string, cond: bool) =
  if cond:
    inc passed
  else:
    inc failed
    echo "FAIL: ", label

echo "=== HPACK Tests ==="

block staticTable:
  echo "--- Static Table ---"
  check("entry 1", HpackStaticTable[1].name == ":authority")
  check("entry 2", HpackStaticTable[2].name == ":method" and HpackStaticTable[2].value == "GET")
  check("entry 3", HpackStaticTable[3].name == ":method" and HpackStaticTable[3].value == "POST")
  check("entry 4", HpackStaticTable[4].name == ":path" and HpackStaticTable[4].value == "/")
  check("entry 8", HpackStaticTable[8].name == ":status" and HpackStaticTable[8].value == "200")
  check("entry 16", HpackStaticTable[16].name == "accept-encoding" and HpackStaticTable[16].value == "gzip, deflate")
  check("entry 61", HpackStaticTable[61].name == "www-authenticate")
  check("static lookup full match", lookupStatic(":method", "GET").index == 2)
  check("static lookup name only", lookupStatic(":status", "201").nameMatch == true)
  check("static lookup miss", lookupStatic("x-custom", "foo").index == 0)

block integerEncoding:
  echo "--- Integer Encoding ---"
  var buf = ""
  hpackEncodeInt(buf, 10, 5, 0x00)
  check("int 10 prefix 5", buf == "\x0a")

  buf = ""
  hpackEncodeInt(buf, 1337, 5, 0x00)
  check("int 1337 prefix 5 len", buf.len == 3)
  check("int 1337 prefix 5 byte0", ord(buf[0]) == 0x1f)
  check("int 1337 prefix 5 byte1", ord(buf[1]) == 0x9a)
  check("int 1337 prefix 5 byte2", ord(buf[2]) == 0x0a)

  var pos = 0
  var data = [0x0a'u8]
  check("decode int 10", hpackDecodeInt(data, pos, 5) == 10)

  pos = 0
  var data2 = [0x1f'u8, 0x9a'u8, 0x0a'u8]
  check("decode int 1337", hpackDecodeInt(data2, pos, 5) == 1337)

block dynamicTable:
  echo "--- Dynamic Table ---"
  var dt = initHpackDynamicTable(256)
  dt.add("custom-key", "custom-value")
  check("dt len 1", dt.len == 1)
  check("dt get 0", dt.get(0).name == "custom-key")
  check("dt entry size", dt.size == 10 + 12 + 32)

  dt.add("another", "header")
  check("dt len 2", dt.len == 2)
  check("dt newest first", dt.get(0).name == "another")
  check("dt oldest second", dt.get(1).name == "custom-key")

  let (idx, nameOnly) = dt.lookup("custom-key", "custom-value")
  check("dt lookup full", idx == 63 and not nameOnly)

  let (idx2, nameOnly2) = dt.lookup("custom-key", "other-value")
  check("dt lookup name only", idx2 == 63 and nameOnly2)

  dt.setMaxSize(0)
  check("dt evict all", dt.len == 0)

block huffmanCoding:
  echo "--- Huffman Coding ---"
  var encoded = ""
  let testStr = "www.example.com"
  huffmanEncode(cast[seq[byte]](testStr), encoded)
  check("huffman encode non-empty", encoded.len > 0)
  check("huffman encode smaller", encoded.len < testStr.len)

  var decoded = ""
  huffmanDecode(cast[seq[byte]](encoded), decoded)
  check("huffman roundtrip", decoded == testStr)

  let testStr2 = "no-cache"
  let enc2 = huffmanEncodeStr(testStr2)
  let dec2 = huffmanDecodeStr(cast[seq[byte]](enc2))
  check("huffman roundtrip 2", dec2 == testStr2)

  for s in ["", "a", "GET", "/index.html", "application/json; charset=utf-8", "Mon, 21 Oct 2013 20:13:22 GMT"]:
    let e = huffmanEncodeStr(s)
    let d = huffmanDecodeStr(cast[seq[byte]](e))
    check("huffman roundtrip: " & s, d == s)

block encodeDecodeRoundtrip:
  echo "--- Encode/Decode Roundtrip ---"
  var encoder = initHpackEncoder(huffman = false)
  var decoder = initHpackDecoder()

  var buf = ""
  let headers = [
    (":method", "GET"),
    (":path", "/"),
    (":scheme", "https"),
    (":authority", "www.example.com"),
    ("accept", "*/*"),
  ]
  hpackEncode(encoder, headers, buf)
  check("encode non-empty", buf.len > 0)

  let decoded = hpackDecode(decoder, cast[seq[byte]](buf))
  check("decode count", decoded.len == headers.len)
  for i in 0 ..< headers.len:
    check("header " & $i & " name", decoded[i][0] == headers[i][0])
    check("header " & $i & " value", decoded[i][1] == headers[i][1])

block encodeDecodeHuffman:
  echo "--- Encode/Decode with Huffman ---"
  var encoder = initHpackEncoder(huffman = true)
  var decoder = initHpackDecoder()

  var buf = ""
  let headers = [
    (":method", "GET"),
    (":path", "/index.html"),
    (":scheme", "https"),
    (":authority", "www.example.com"),
    ("custom-key", "custom-value"),
  ]
  hpackEncode(encoder, headers, buf)

  let decoded = hpackDecode(decoder, cast[seq[byte]](buf))
  check("huffman decode count", decoded.len == headers.len)
  for i in 0 ..< headers.len:
    check("huffman header " & $i, decoded[i][0] == headers[i][0] and decoded[i][1] == headers[i][1])

block rfc7541C1:
  echo "--- RFC 7541 C.1: Integer Representation Examples ---"
  var buf1 = ""
  hpackEncodeInt(buf1, 10, 5, 0x00)
  var pos1 = 0
  var d1 = cast[seq[byte]](buf1)
  check("C.1.1: encode 10 prefix 5", hpackDecodeInt(d1, pos1, 5) == 10)

  var buf2 = ""
  hpackEncodeInt(buf2, 1337, 5, 0x00)
  var pos2 = 0
  var d2 = cast[seq[byte]](buf2)
  check("C.1.2: encode 1337 prefix 5", hpackDecodeInt(d2, pos2, 5) == 1337)

  var buf3 = ""
  hpackEncodeInt(buf3, 42, 8, 0x00)
  var pos3 = 0
  var d3 = cast[seq[byte]](buf3)
  check("C.1.3: encode 42 prefix 8", hpackDecodeInt(d3, pos3, 8) == 42)

block multipleRequests:
  echo "--- Multiple Requests (Dynamic Table Evolution) ---"
  var encoder = initHpackEncoder(huffman = false)
  var decoder = initHpackDecoder()

  var buf1 = ""
  hpackEncode(encoder, [
    (":method", "GET"),
    (":path", "/"),
    (":authority", "www.example.com"),
  ], buf1)
  let dec1 = hpackDecode(decoder, cast[seq[byte]](buf1))
  check("req1 count", dec1.len == 3)
  check("req1 method", dec1[0] == (":method", "GET"))
  check("req1 path", dec1[1] == (":path", "/"))

  var buf2 = ""
  hpackEncode(encoder, [
    (":method", "GET"),
    (":path", "/resource"),
    (":authority", "www.example.com"),
  ], buf2)
  check("req2 smaller", buf2.len <= buf1.len + 15)
  let dec2 = hpackDecode(decoder, cast[seq[byte]](buf2))
  check("req2 count", dec2.len == 3)
  check("req2 path", dec2[1] == (":path", "/resource"))

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
else:
  quit(0)
