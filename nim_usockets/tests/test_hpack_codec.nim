import std/strutils
import ../src/nim_usockets/hpack

var passed = 0
var failed = 0

template check(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failed += 1
    echo "FAIL: ", msg

echo "=== HPACK Codec Tests ==="

echo "--- Encoder settings bounds ---"
block encoderCapsLargeHeaderTableSettings:
  var encoder = initHpackEncoder()
  updateEncoderMaxSize(encoder, 65536)
  check(encoder.dynamicTable.maxSize == 65535, "encoder caps 65536 table setting to implementation limit")
  check(encoder.pendingMaxSize == 65535, "pending size update is capped for 65536")

  updateEncoderMaxSize(encoder, 1_048_576)
  check(encoder.dynamicTable.maxSize == 65535, "encoder caps 1MB table setting to implementation limit")
  check(encoder.pendingMaxSize == 65535, "pending size update is capped for 1MB")

echo "--- Integer encoding/decoding ---"
block intRoundTrip5bit:
  var buf = ""
  hpackEncodeInt(buf, 10, 5, 0x00)
  var pos = 0
  let data = cast[seq[byte]](buf)
  let val = hpackDecodeInt(data, pos, 5)
  check(val == 10, "int 10 with 5-bit prefix round-trips")

block intRoundTrip7bit:
  var buf = ""
  hpackEncodeInt(buf, 127, 7, 0x00)
  var pos = 0
  let data = cast[seq[byte]](buf)
  let val = hpackDecodeInt(data, pos, 7)
  check(val == 127, "int 127 with 7-bit prefix round-trips")

block intRoundTripSmall:
  for v in [0, 1, 2, 3, 10, 30]:
    var buf = ""
    hpackEncodeInt(buf, v, 5, 0x00)
    var pos = 0
    let val = hpackDecodeInt(cast[seq[byte]](buf), pos, 5)
    check(val == v, "int " & $v & " with 5-bit prefix round-trips")

block intRoundTripBoundary:
  var buf = ""
  hpackEncodeInt(buf, 31, 5, 0x00)
  var pos = 0
  let val = hpackDecodeInt(cast[seq[byte]](buf), pos, 5)
  check(val == 31, "int 31 at 5-bit boundary round-trips")
  check(buf.len == 2, "int 31 with 5-bit prefix needs 2 bytes")

block intRoundTripLarge:
  var buf = ""
  hpackEncodeInt(buf, 1337, 5, 0x00)
  var pos = 0
  let val = hpackDecodeInt(cast[seq[byte]](buf), pos, 5)
  check(val == 1337, "int 1337 with 5-bit prefix round-trips")

block intRoundTripVeryLarge:
  var buf = ""
  hpackEncodeInt(buf, 100000, 7, 0x00)
  var pos = 0
  let val = hpackDecodeInt(cast[seq[byte]](buf), pos, 7)
  check(val == 100000, "int 100000 with 7-bit prefix round-trips")

block intPrefixByteMask:
  var buf = ""
  hpackEncodeInt(buf, 5, 5, 0xA0)
  check((byte(buf[0]) and 0xE0) == 0xA0, "prefix byte high bits preserved")
  var pos = 0
  let val = hpackDecodeInt(cast[seq[byte]](buf), pos, 5)
  check(val == 5, "int decoded correctly with prefix byte mask")

block intPrefixByte6bit:
  var buf = ""
  hpackEncodeInt(buf, 3, 6, 0x40)
  check((byte(buf[0]) and 0xC0) == 0x40, "6-bit prefix byte preserved")
  var pos = 0
  let val = hpackDecodeInt(cast[seq[byte]](buf), pos, 6)
  check(val == 3, "int with 6-bit prefix round-trips")

block intPrefixByte4bit:
  var buf = ""
  hpackEncodeInt(buf, 15, 4, 0x00)
  var pos = 0
  let val = hpackDecodeInt(cast[seq[byte]](buf), pos, 4)
  check(val == 15, "int 15 at 4-bit boundary round-trips")
  check(buf.len == 2, "int 15 with 4-bit prefix needs 2 bytes")

block intZero:
  var buf = ""
  hpackEncodeInt(buf, 0, 7, 0x80)
  check(buf.len == 1, "int 0 needs 1 byte")
  check(byte(buf[0]) == 0x80, "int 0 with 0x80 prefix is 0x80")
  var pos = 0
  let val = hpackDecodeInt(cast[seq[byte]](buf), pos, 7)
  check(val == 0, "int 0 round-trips")

block intDecodeEmptyFails:
  var pos = 0
  var gotError = false
  try:
    discard hpackDecodeInt(cast[seq[byte]](""), pos, 5)
  except HpackError:
    gotError = true
  check(gotError, "decode empty data raises HpackError")

block intDecodeTruncatedMultibyte:
  var buf = ""
  hpackEncodeInt(buf, 1337, 5, 0x00)
  var truncated = cast[seq[byte]](buf[0..1])
  var pos = 0
  var gotError = false
  try:
    discard hpackDecodeInt(truncated, pos, 5)
  except HpackError:
    gotError = true
  check(gotError, "truncated multi-byte int raises HpackError")

block intDecodeOverflow:
  var data: seq[byte] = @[0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F]
  var pos = 0
  var gotError = false
  try:
    discard hpackDecodeInt(data, pos, 8)
  except HpackError:
    gotError = true
  check(gotError, "integer overflow raises HpackError")

echo "--- String encoding/decoding ---"
block stringRoundTripPlain:
  var buf = ""
  hpackEncodeString(buf, "hello", false)
  var pos = 0
  let s = hpackDecodeString(cast[seq[byte]](buf), pos)
  check(s == "hello", "plain string round-trips")

block stringRoundTripHuffman:
  var buf = ""
  hpackEncodeString(buf, "hello", true)
  var pos = 0
  let s = hpackDecodeString(cast[seq[byte]](buf), pos)
  check(s == "hello", "huffman string round-trips")

block stringEmpty:
  var buf = ""
  hpackEncodeString(buf, "", false)
  var pos = 0
  let s = hpackDecodeString(cast[seq[byte]](buf), pos)
  check(s == "", "empty string round-trips")

block stringEmptyHuffman:
  var buf = ""
  hpackEncodeString(buf, "", true)
  var pos = 0
  let s = hpackDecodeString(cast[seq[byte]](buf), pos)
  check(s == "", "empty huffman string round-trips")

block stringLongPlain:
  let long = newString(500)
  var buf = ""
  hpackEncodeString(buf, long, false)
  var pos = 0
  let s = hpackDecodeString(cast[seq[byte]](buf), pos)
  check(s.len == 500, "long plain string round-trips")

block stringDecodeEmptyFails:
  var pos = 0
  var gotError = false
  try:
    discard hpackDecodeString(cast[seq[byte]](""), pos)
  except HpackError:
    gotError = true
  check(gotError, "decode empty string data raises HpackError")

block stringDecodeTruncated:
  var data: seq[byte] = @[5'u8, 0x68, 0x65]
  var pos = 0
  var gotError = false
  try:
    discard hpackDecodeString(data, pos)
  except HpackError:
    gotError = true
  check(gotError, "truncated string raises HpackError")

echo "--- Static table ---"
block staticTableSize:
  check(HpackStaticTable.len == 62, "static table has 62 entries (0-61)")

block staticTableIndex0:
  check(HpackStaticTable[0].name == "", "index 0 name is empty")
  check(HpackStaticTable[0].value == "", "index 0 value is empty")

block staticTableAuthority:
  check(HpackStaticTable[1].name == ":authority", "index 1 is :authority")
  check(HpackStaticTable[1].value == "", "index 1 value is empty")

block staticTableMethod:
  check(HpackStaticTable[2].name == ":method", "index 2 is :method")
  check(HpackStaticTable[2].value == "GET", "index 2 value is GET")
  check(HpackStaticTable[3].name == ":method", "index 3 is :method")
  check(HpackStaticTable[3].value == "POST", "index 3 value is POST")

block staticTablePath:
  check(HpackStaticTable[4].name == ":path", "index 4 is :path")
  check(HpackStaticTable[4].value == "/", "index 4 value is /")
  check(HpackStaticTable[5].name == ":path", "index 5 is :path")
  check(HpackStaticTable[5].value == "/index.html", "index 5 value is /index.html")

block staticTableScheme:
  check(HpackStaticTable[6].name == ":scheme", "index 6 is :scheme http")
  check(HpackStaticTable[6].value == "http", "index 6 value http")
  check(HpackStaticTable[7].name == ":scheme", "index 7 is :scheme https")
  check(HpackStaticTable[7].value == "https", "index 7 value https")

block staticTableStatus:
  check(HpackStaticTable[8].name == ":status", "index 8 is :status 200")
  check(HpackStaticTable[8].value == "200", "index 8 value 200")
  check(HpackStaticTable[14].name == ":status", "index 14 is :status 500")
  check(HpackStaticTable[14].value == "500", "index 14 value 500")

block staticTableLastEntry:
  check(HpackStaticTable[61].name == "www-authenticate", "index 61 is www-authenticate")
  check(HpackStaticTable[61].value == "", "index 61 value is empty")

echo "--- lookupStatic ---"
block lookupStaticExactMatch:
  let r = lookupStatic(":method", "GET")
  check(r.index == 2, "lookupStatic :method GET -> index 2")
  check(r.nameMatch == false, "lookupStatic exact match: nameMatch is false")

block lookupStaticNameOnlyMatch:
  let r = lookupStatic(":method", "PUT")
  check(r.index > 0, "lookupStatic :method PUT finds name match")
  check(r.nameMatch == true, "lookupStatic :method PUT is name-only match")

block lookupStaticNoMatch:
  let r = lookupStatic("x-custom-header", "value")
  check(r.index == 0, "lookupStatic unknown header returns 0")

block lookupStaticPath:
  let r = lookupStatic(":path", "/")
  check(r.index == 4, "lookupStatic :path / -> index 4")

block lookupStaticPathIndexHtml:
  let r = lookupStatic(":path", "/index.html")
  check(r.index == 5, "lookupStatic :path /index.html -> index 5")

block lookupStaticAcceptEncoding:
  let r = lookupStatic("accept-encoding", "gzip, deflate")
  check(r.index == 16, "lookupStatic accept-encoding exact -> index 16")

echo "--- Dynamic table ---"
block dynamicTableInit:
  let dt = initHpackDynamicTable(4096)
  check(dt.len == 0, "new dynamic table is empty")
  check(dt.size == 0, "new dynamic table size is 0")
  check(dt.maxSize == 4096, "new dynamic table maxSize is 4096")

block dynamicTableAdd:
  var dt = initHpackDynamicTable(4096)
  dt.add("custom-header", "custom-value")
  check(dt.len == 1, "dynamic table has 1 entry after add")
  check(dt.size == "custom-header".len + "custom-value".len + 32, "dynamic table size correct")
  let e = dt.get(0)
  check(e.name == "custom-header", "dynamic table entry name correct")
  check(e.value == "custom-value", "dynamic table entry value correct")

block dynamicTableFIFO:
  var dt = initHpackDynamicTable(4096)
  dt.add("first", "1")
  dt.add("second", "2")
  dt.add("third", "3")
  check(dt.len == 3, "dynamic table has 3 entries")
  check(dt.get(0).name == "third", "most recent entry at index 0")
  check(dt.get(1).name == "second", "second entry at index 1")
  check(dt.get(2).name == "first", "oldest entry at index 2")

block dynamicTableEviction:
  var dt = initHpackDynamicTable(100)
  dt.add("a", newString(50))
  check(dt.len == 1, "after first add: 1 entry")
  dt.add("b", newString(50))
  check(dt.len == 1, "after second add: evicted first, 1 entry")
  check(dt.get(0).name == "b", "evicted entry is 'a', remaining is 'b'")

block dynamicTableEvictionClearsAll:
  var dt = initHpackDynamicTable(100)
  dt.add("key", "val")
  dt.add("oversized", newString(200))
  check(dt.len == 0, "oversized entry clears table")
  check(dt.size == 0, "oversized entry: size is 0")

block dynamicTableSetMaxSize:
  var dt = initHpackDynamicTable(4096)
  dt.add("key1", "val1")
  dt.add("key2", "val2")
  check(dt.len == 2, "before resize: 2 entries")
  dt.setMaxSize(0)
  check(dt.len == 0, "setMaxSize(0) evicts all")
  check(dt.size == 0, "setMaxSize(0): size is 0")

block dynamicTableSetMaxSizeNegative:
  var dt = initHpackDynamicTable(4096)
  var gotError = false
  try:
    dt.setMaxSize(-1)
  except HpackError:
    gotError = true
  check(gotError, "setMaxSize(-1) raises HpackError")

block dynamicTableSetMaxSizeWithLimit:
  var dt = initHpackDynamicTable(4096)
  var gotError = false
  try:
    dt.setMaxSize(8192, limit = 4096)
  except HpackError:
    gotError = true
  check(gotError, "setMaxSize exceeding limit raises HpackError")

block dynamicTableSetMaxSizeWithinLimit:
  var dt = initHpackDynamicTable(4096)
  dt.setMaxSize(2048, limit = 4096)
  check(dt.maxSize == 2048, "setMaxSize within limit accepted")

block dynamicTableLookup:
  var dt = initHpackDynamicTable(4096)
  dt.add("custom", "value1")
  dt.add("custom", "value2")
  let r = dt.lookup("custom", "value1")
  check(r.index == 63, "lookup exact match in dynamic table (second position)")

block dynamicTableLookupNameOnly:
  var dt = initHpackDynamicTable(4096)
  dt.add("custom", "value1")
  let r = dt.lookup("custom", "other")
  check(r.index == 62, "lookup name-only match index")
  check(r.nameMatch == true, "lookup name-only match flag")

block dynamicTableLookupMiss:
  var dt = initHpackDynamicTable(4096)
  dt.add("custom", "value")
  let r = dt.lookup("other", "value")
  check(r.index == 0, "lookup miss returns 0")

echo "--- getEntry ---"
block getEntryStatic:
  let dt = initHpackDynamicTable(4096)
  let e = dt.getEntry(2)
  check(e.name == ":method", "getEntry(2) -> :method")
  check(e.value == "GET", "getEntry(2) -> GET")

block getEntryDynamic:
  var dt = initHpackDynamicTable(4096)
  dt.add("custom", "val")
  let e = dt.getEntry(62)
  check(e.name == "custom", "getEntry(62) -> first dynamic entry")
  check(e.value == "val", "getEntry(62) value correct")

block getEntryIndex0:
  let dt = initHpackDynamicTable(4096)
  var gotError = false
  try:
    discard dt.getEntry(0)
  except HpackError:
    gotError = true
  check(gotError, "getEntry(0) raises HpackError")

block getEntryOutOfRange:
  let dt = initHpackDynamicTable(4096)
  var gotError = false
  try:
    discard dt.getEntry(62)
  except HpackError:
    gotError = true
  check(gotError, "getEntry(62) with empty dynamic table raises HpackError")

block getEntryStaticBoundary:
  let dt = initHpackDynamicTable(4096)
  let e = dt.getEntry(61)
  check(e.name == "www-authenticate", "getEntry(61) -> last static entry")

echo "--- Encoder/Decoder ---"
block encoderInit:
  let enc = initHpackEncoder()
  check(enc.huffman == true, "default encoder uses huffman")
  check(enc.dynamicTable.maxSize == 4096, "default encoder table size 4096")

block encoderInitNoHuffman:
  let enc = initHpackEncoder(huffman = false)
  check(enc.huffman == false, "encoder without huffman")

block decoderInit:
  let dec = initHpackDecoder()
  check(dec.dynamicTable.maxSize == 4096, "default decoder table size 4096")
  check(dec.settingsMaxSize == 4096, "default decoder settings max 4096")

block encodeDecodeRoundTrip:
  var enc = initHpackEncoder(huffman = false)
  var dec = initHpackDecoder()
  let headers = @[
    (":method", "GET"),
    (":path", "/"),
    (":scheme", "https"),
    (":authority", "example.com"),
  ]
  var buf = ""
  hpackEncode(enc, headers, buf)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 4, "decoded 4 headers")
  check(decoded[0] == (":method", "GET"), "decoded :method GET")
  check(decoded[1] == (":path", "/"), "decoded :path /")
  check(decoded[2] == (":scheme", "https"), "decoded :scheme https")
  check(decoded[3] == (":authority", "example.com"), "decoded :authority example.com")

block encodeDecodeWithHuffman:
  var enc = initHpackEncoder(huffman = true)
  var dec = initHpackDecoder()
  let headers = @[
    (":method", "POST"),
    (":path", "/api/data"),
    ("content-type", "application/json"),
  ]
  var buf = ""
  hpackEncode(enc, headers, buf)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 3, "huffman: decoded 3 headers")
  check(decoded[0] == (":method", "POST"), "huffman: decoded :method POST")
  check(decoded[1] == (":path", "/api/data"), "huffman: decoded :path")
  check(decoded[2] == ("content-type", "application/json"), "huffman: decoded content-type")

block encodeDecodeMultipleRequests:
  var enc = initHpackEncoder(huffman = false)
  var dec = initHpackDecoder()

  var buf1 = ""
  hpackEncode(enc, @[
    (":method", "GET"),
    (":path", "/"),
    (":scheme", "https"),
    (":authority", "example.com"),
  ], buf1)
  let d1 = hpackDecode(dec, cast[seq[byte]](buf1))
  check(d1.len == 4, "request 1: 4 headers")

  var buf2 = ""
  hpackEncode(enc, @[
    (":method", "GET"),
    (":path", "/style.css"),
    (":scheme", "https"),
    (":authority", "example.com"),
  ], buf2)
  let d2 = hpackDecode(dec, cast[seq[byte]](buf2))
  check(d2.len == 4, "request 2: 4 headers")
  check(d2[1] == (":path", "/style.css"), "request 2: path changed")

  check(buf2.len <= buf1.len, "second request should be same or smaller (reuse)")

block encodeDecodeCustomHeaders:
  var enc = initHpackEncoder(huffman = false)
  var dec = initHpackDecoder()
  let headers = @[
    ("x-custom-1", "value1"),
    ("x-custom-2", "value2"),
    ("x-custom-3", "value3"),
  ]
  var buf = ""
  hpackEncode(enc, headers, buf)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 3, "custom: decoded 3 headers")
  check(decoded[0] == ("x-custom-1", "value1"), "custom: first header")
  check(decoded[1] == ("x-custom-2", "value2"), "custom: second header")
  check(decoded[2] == ("x-custom-3", "value3"), "custom: third header")

block encoderDynamicTableUsage:
  var enc = initHpackEncoder(huffman = false)
  var dec = initHpackDecoder()

  var buf1 = ""
  hpackEncode(enc, @[("x-custom", "myval")], buf1)
  discard hpackDecode(dec, cast[seq[byte]](buf1))

  var buf2 = ""
  hpackEncode(enc, @[("x-custom", "myval")], buf2)
  let d2 = hpackDecode(dec, cast[seq[byte]](buf2))
  check(d2.len == 1, "dynamic reuse: 1 header")
  check(d2[0] == ("x-custom", "myval"), "dynamic reuse: value correct")
  check(buf2.len < buf1.len, "dynamic reuse: second encoding smaller")

echo "--- Encoder size update ---"
block encoderSizeUpdate:
  var enc = initHpackEncoder(huffman = false)
  var dec = initHpackDecoder()

  updateEncoderMaxSize(enc, 2048)
  check(enc.pendingSizeUpdate, "encoder pending size update set")
  check(enc.dynamicTable.maxSize == 2048, "encoder table resized")

  var buf = ""
  hpackEncode(enc, @[(":method", "GET")], buf)
  check(not enc.pendingSizeUpdate, "encoder pending cleared after encode")

  updateSettingsMaxSize(dec, 2048)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 1, "decode with size update succeeds")
  check(decoded[0] == (":method", "GET"), "decoded header correct after size update")

echo "--- Decoder mandatory size update ---"
block decoderMandatorySizeUpdateRequired:
  var dec = initHpackDecoder(4096)
  updateSettingsMaxSize(dec, 2048)
  check(dec.pendingSizeUpdate, "pending update set after reduction")

  var buf = ""
  hpackEncodeInt(buf, 2, 7, 0x80)
  var gotError = false
  try:
    discard hpackDecode(dec, cast[seq[byte]](buf))
  except HpackError:
    gotError = true
  check(gotError, "missing mandatory size update raises error")

block decoderMandatorySizeUpdateProvided:
  var dec = initHpackDecoder(4096)
  updateSettingsMaxSize(dec, 2048)

  var buf = ""
  hpackEncodeInt(buf, 2048, 5, 0x20)
  hpackEncodeInt(buf, 2, 7, 0x80)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 1, "decode succeeds with size update")
  check(not dec.pendingSizeUpdate, "pending cleared after update")

block decoderSizeUpdateAfterHeader:
  var dec = initHpackDecoder(4096)

  var buf = ""
  hpackEncodeInt(buf, 2, 7, 0x80)
  hpackEncodeInt(buf, 2048, 5, 0x20)

  var gotError = false
  try:
    discard hpackDecode(dec, cast[seq[byte]](buf))
  except HpackError:
    gotError = true
  check(gotError, "size update after header entry raises error")

block decoderSizeUpdateExceedsSettings:
  var dec = initHpackDecoder(4096)

  var buf = ""
  hpackEncodeInt(buf, 8192, 5, 0x20)

  var gotError = false
  try:
    discard hpackDecode(dec, cast[seq[byte]](buf))
  except HpackError:
    gotError = true
  check(gotError, "size update exceeding SETTINGS raises error")

block decoderNoMandatoryOnIncrease:
  var dec = initHpackDecoder(4096)
  updateSettingsMaxSize(dec, 8192)
  check(not dec.pendingSizeUpdate, "no pending update on increase")

  var buf = ""
  hpackEncodeInt(buf, 2, 7, 0x80)
  var gotError = false
  try:
    discard hpackDecode(dec, cast[seq[byte]](buf))
  except HpackError:
    gotError = true
  check(not gotError, "decode succeeds without update after increase")

echo "--- HPACK decode: indexed header field ---"
block decodeIndexedStatic:
  var dec = initHpackDecoder()
  var buf = ""
  hpackEncodeInt(buf, 2, 7, 0x80)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 1, "indexed: 1 header")
  check(decoded[0][0] == ":method", "indexed: name is :method")
  check(decoded[0][1] == "GET", "indexed: value is GET")

block decodeIndexedZero:
  var dec = initHpackDecoder()
  var buf = ""
  hpackEncodeInt(buf, 0, 7, 0x80)
  var gotError = false
  try:
    discard hpackDecode(dec, cast[seq[byte]](buf))
  except HpackError:
    gotError = true
  check(gotError, "indexed header index 0 raises error")

block decodeIndexedOutOfRange:
  var dec = initHpackDecoder()
  var buf = ""
  hpackEncodeInt(buf, 200, 7, 0x80)
  var gotError = false
  try:
    discard hpackDecode(dec, cast[seq[byte]](buf))
  except HpackError:
    gotError = true
  check(gotError, "indexed header out of range raises error")

echo "--- HPACK decode: literal with incremental indexing ---"
block decodeLiteralNewName:
  var dec = initHpackDecoder()
  var buf = ""
  hpackEncodeInt(buf, 0, 6, 0x40)
  hpackEncodeString(buf, "x-new", false)
  hpackEncodeString(buf, "newval", false)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 1, "literal new name: 1 header")
  check(decoded[0][0] == "x-new", "literal new name: name correct")
  check(decoded[0][1] == "newval", "literal new name: value correct")
  check(dec.dynamicTable.len == 1, "literal new name: added to dynamic table")

block decodeLiteralIndexedName:
  var dec = initHpackDecoder()
  var buf = ""
  hpackEncodeInt(buf, 1, 6, 0x40)
  hpackEncodeString(buf, "example.com", false)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 1, "literal indexed name: 1 header")
  check(decoded[0][0] == ":authority", "literal indexed name: name from static table")
  check(decoded[0][1] == "example.com", "literal indexed name: value correct")

echo "--- HPACK decode: literal without indexing ---"
block decodeLiteralNoIndex:
  var dec = initHpackDecoder()
  var buf = ""
  hpackEncodeInt(buf, 0, 4, 0x00)
  hpackEncodeString(buf, "sensitive-key", false)
  hpackEncodeString(buf, "sensitive-val", false)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 1, "no-index: 1 header")
  check(decoded[0][0] == "sensitive-key", "no-index: name correct")
  check(decoded[0][1] == "sensitive-val", "no-index: value correct")
  check(dec.dynamicTable.len == 0, "no-index: NOT added to dynamic table")

echo "--- HPACK decode: literal never indexed ---"
block decodeLiteralNeverIndex:
  var dec = initHpackDecoder()
  var buf = ""
  hpackEncodeInt(buf, 0, 4, 0x10)
  hpackEncodeString(buf, "secret", false)
  hpackEncodeString(buf, "password", false)
  let decoded = hpackDecode(dec, cast[seq[byte]](buf))
  check(decoded.len == 1, "never-index: 1 header")
  check(decoded[0][0] == "secret", "never-index: name correct")
  check(decoded[0][1] == "password", "never-index: value correct")
  check(dec.dynamicTable.len == 0, "never-index: NOT added to dynamic table")

echo "--- entry size calculation (name.len + value.len + 32) ---"
block entrySizeCalc:
  var dt = initHpackDynamicTable(4096)
  dt.add("name", "value")
  check(dt.size == 4 + 5 + 32, "entry size = name.len + value.len + 32")

block entrySizeEmpty:
  var dt = initHpackDynamicTable(4096)
  dt.add("", "")
  check(dt.size == 32, "entry size of empty name+value = 32")

block entrySizeSingle:
  var dt = initHpackDynamicTable(4096)
  dt.add("a", "")
  check(dt.size == 33, "entry size of ('a','') = 33")

echo "--- Header count limit ---"
block headerCountLimit:
  check(HpackMaxHeaderCount == 4096, "HpackMaxHeaderCount is 4096")
  check(HpackMaxHeaderListBytes == 1024 * 1024, "HpackMaxHeaderListBytes is 1MB")
  check(HpackMaxStringLen == 65536, "HpackMaxStringLen is 65536")

block decodedHeaderListLimitAfterFinalHeader:
  var data = ""
  for i in 0..<16:
    data.add chr(0x00)
    hpackEncodeString(data, "x", false)
    hpackEncodeString(data, repeat("a", HpackMaxStringLen), false)
  var dec = initHpackDecoder()
  var gotError = false
  try:
    discard hpackDecode(dec, cast[seq[byte]](data))
  except HpackError:
    gotError = true
  check(gotError, "decoded header-list size is checked after final increment")

echo ""
echo "Results: ", passed, " passed, ", failed, " failed"
if failed > 0:
  quit(1)
