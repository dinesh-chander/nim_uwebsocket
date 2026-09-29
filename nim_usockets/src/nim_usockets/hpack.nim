import std/deques

type
  HpackEntry* = object
    name*: string
    value*: string

  HpackDynamicTable* = object
    entries*: Deque[HpackEntry]
    size*: int
    maxSize*: int

  HpackEncoder* = object
    dynamicTable*: HpackDynamicTable
    huffman*: bool
    pendingSizeUpdate*: bool
    pendingMaxSize*: int

  HpackDecoder* = object
    dynamicTable*: HpackDynamicTable
    settingsMaxSize*: int
    pendingSizeUpdate*: bool

  HpackError* = object of CatchableError

const
  MaxHpackDynamicTableSize = 65535

  HpackStaticTable*: array[62, HpackEntry] = [
    HpackEntry(name: "", value: ""),
    HpackEntry(name: ":authority", value: ""),
    HpackEntry(name: ":method", value: "GET"),
    HpackEntry(name: ":method", value: "POST"),
    HpackEntry(name: ":path", value: "/"),
    HpackEntry(name: ":path", value: "/index.html"),
    HpackEntry(name: ":scheme", value: "http"),
    HpackEntry(name: ":scheme", value: "https"),
    HpackEntry(name: ":status", value: "200"),
    HpackEntry(name: ":status", value: "204"),
    HpackEntry(name: ":status", value: "206"),
    HpackEntry(name: ":status", value: "304"),
    HpackEntry(name: ":status", value: "400"),
    HpackEntry(name: ":status", value: "404"),
    HpackEntry(name: ":status", value: "500"),
    HpackEntry(name: "accept-charset", value: ""),
    HpackEntry(name: "accept-encoding", value: "gzip, deflate"),
    HpackEntry(name: "accept-language", value: ""),
    HpackEntry(name: "accept-ranges", value: ""),
    HpackEntry(name: "accept", value: ""),
    HpackEntry(name: "access-control-allow-origin", value: ""),
    HpackEntry(name: "age", value: ""),
    HpackEntry(name: "allow", value: ""),
    HpackEntry(name: "authorization", value: ""),
    HpackEntry(name: "cache-control", value: ""),
    HpackEntry(name: "content-disposition", value: ""),
    HpackEntry(name: "content-encoding", value: ""),
    HpackEntry(name: "content-language", value: ""),
    HpackEntry(name: "content-length", value: ""),
    HpackEntry(name: "content-location", value: ""),
    HpackEntry(name: "content-range", value: ""),
    HpackEntry(name: "content-type", value: ""),
    HpackEntry(name: "cookie", value: ""),
    HpackEntry(name: "date", value: ""),
    HpackEntry(name: "etag", value: ""),
    HpackEntry(name: "expect", value: ""),
    HpackEntry(name: "expires", value: ""),
    HpackEntry(name: "from", value: ""),
    HpackEntry(name: "host", value: ""),
    HpackEntry(name: "if-match", value: ""),
    HpackEntry(name: "if-modified-since", value: ""),
    HpackEntry(name: "if-none-match", value: ""),
    HpackEntry(name: "if-range", value: ""),
    HpackEntry(name: "if-unmodified-since", value: ""),
    HpackEntry(name: "last-modified", value: ""),
    HpackEntry(name: "link", value: ""),
    HpackEntry(name: "location", value: ""),
    HpackEntry(name: "max-forwards", value: ""),
    HpackEntry(name: "proxy-authenticate", value: ""),
    HpackEntry(name: "proxy-authorization", value: ""),
    HpackEntry(name: "range", value: ""),
    HpackEntry(name: "referer", value: ""),
    HpackEntry(name: "refresh", value: ""),
    HpackEntry(name: "retry-after", value: ""),
    HpackEntry(name: "server", value: ""),
    HpackEntry(name: "set-cookie", value: ""),
    HpackEntry(name: "strict-transport-security", value: ""),
    HpackEntry(name: "transfer-encoding", value: ""),
    HpackEntry(name: "user-agent", value: ""),
    HpackEntry(name: "vary", value: ""),
    HpackEntry(name: "via", value: ""),
    HpackEntry(name: "www-authenticate", value: ""),
  ]

  HuffmanEncodeTable*: array[257, tuple[code: uint32, bits: uint8]] = [
    (0x1ff8'u32, 13'u8), (0x7fffd8'u32, 23'u8), (0xfffffe2'u32, 28'u8), (0xfffffe3'u32, 28'u8),
    (0xfffffe4'u32, 28'u8), (0xfffffe5'u32, 28'u8), (0xfffffe6'u32, 28'u8), (0xfffffe7'u32, 28'u8),
    (0xfffffe8'u32, 28'u8), (0xffffea'u32, 24'u8), (0x3ffffffc'u32, 30'u8), (0xfffffe9'u32, 28'u8),
    (0xfffffea'u32, 28'u8), (0x3ffffffd'u32, 30'u8), (0xfffffeb'u32, 28'u8), (0xfffffec'u32, 28'u8),
    (0xfffffed'u32, 28'u8), (0xfffffee'u32, 28'u8), (0xfffffef'u32, 28'u8), (0xffffff0'u32, 28'u8),
    (0xffffff1'u32, 28'u8), (0xffffff2'u32, 28'u8), (0x3ffffffe'u32, 30'u8), (0xffffff3'u32, 28'u8),
    (0xffffff4'u32, 28'u8), (0xffffff5'u32, 28'u8), (0xffffff6'u32, 28'u8), (0xffffff7'u32, 28'u8),
    (0xffffff8'u32, 28'u8), (0xffffff9'u32, 28'u8), (0xffffffa'u32, 28'u8), (0xffffffb'u32, 28'u8),
    (0x14'u32, 6'u8),       (0x3f8'u32, 10'u8),     (0x3f9'u32, 10'u8),     (0xffa'u32, 12'u8),
    (0x1ff9'u32, 13'u8),    (0x15'u32, 6'u8),        (0xf8'u32, 8'u8),       (0x7fa'u32, 11'u8),
    (0x3fa'u32, 10'u8),     (0x3fb'u32, 10'u8),      (0xf9'u32, 8'u8),       (0x7fb'u32, 11'u8),
    (0xfa'u32, 8'u8),       (0x16'u32, 6'u8),        (0x17'u32, 6'u8),       (0x18'u32, 6'u8),
    (0x0'u32, 5'u8),        (0x1'u32, 5'u8),         (0x2'u32, 5'u8),        (0x19'u32, 6'u8),
    (0x1a'u32, 6'u8),       (0x1b'u32, 6'u8),        (0x1c'u32, 6'u8),       (0x1d'u32, 6'u8),
    (0x1e'u32, 6'u8),       (0x1f'u32, 6'u8),        (0x5c'u32, 7'u8),       (0xfb'u32, 8'u8),
    (0x7ffc'u32, 15'u8),    (0x20'u32, 6'u8),        (0xffb'u32, 12'u8),     (0x3fc'u32, 10'u8),
    (0x1ffa'u32, 13'u8),    (0x21'u32, 6'u8),        (0x5d'u32, 7'u8),       (0x5e'u32, 7'u8),
    (0x5f'u32, 7'u8),       (0x60'u32, 7'u8),        (0x61'u32, 7'u8),       (0x62'u32, 7'u8),
    (0x63'u32, 7'u8),       (0x64'u32, 7'u8),        (0x65'u32, 7'u8),       (0x66'u32, 7'u8),
    (0x67'u32, 7'u8),       (0x68'u32, 7'u8),        (0x69'u32, 7'u8),       (0x6a'u32, 7'u8),
    (0x6b'u32, 7'u8),       (0x6c'u32, 7'u8),        (0x6d'u32, 7'u8),       (0x6e'u32, 7'u8),
    (0x6f'u32, 7'u8),       (0x70'u32, 7'u8),        (0x71'u32, 7'u8),       (0x72'u32, 7'u8),
    (0xfc'u32, 8'u8),       (0x73'u32, 7'u8),        (0xfd'u32, 8'u8),       (0x1ffb'u32, 13'u8),
    (0x7fff0'u32, 19'u8),   (0x1ffc'u32, 13'u8),     (0x3ffc'u32, 14'u8),    (0x22'u32, 6'u8),
    (0x7ffd'u32, 15'u8),    (0x3'u32, 5'u8),         (0x23'u32, 6'u8),       (0x4'u32, 5'u8),
    (0x24'u32, 6'u8),       (0x5'u32, 5'u8),         (0x25'u32, 6'u8),       (0x26'u32, 6'u8),
    (0x27'u32, 6'u8),       (0x6'u32, 5'u8),         (0x74'u32, 7'u8),       (0x75'u32, 7'u8),
    (0x28'u32, 6'u8),       (0x29'u32, 6'u8),        (0x2a'u32, 6'u8),       (0x7'u32, 5'u8),
    (0x2b'u32, 6'u8),       (0x76'u32, 7'u8),        (0x2c'u32, 6'u8),       (0x8'u32, 5'u8),
    (0x9'u32, 5'u8),        (0x2d'u32, 6'u8),        (0x77'u32, 7'u8),       (0x78'u32, 7'u8),
    (0x79'u32, 7'u8),       (0x7a'u32, 7'u8),        (0x7b'u32, 7'u8),       (0x7ffe'u32, 15'u8),
    (0x7fc'u32, 11'u8),     (0x3ffd'u32, 14'u8),     (0x1ffd'u32, 13'u8),    (0xffffffc'u32, 28'u8),
    (0xfffe6'u32, 20'u8),   (0x3fffd2'u32, 22'u8),   (0xfffe7'u32, 20'u8),   (0xfffe8'u32, 20'u8),
    (0x3fffd3'u32, 22'u8),  (0x3fffd4'u32, 22'u8),   (0x3fffd5'u32, 22'u8),  (0x7fffd9'u32, 23'u8),
    (0x3fffd6'u32, 22'u8),  (0x7fffda'u32, 23'u8),   (0x7fffdb'u32, 23'u8),  (0x7fffdc'u32, 23'u8),
    (0x7fffdd'u32, 23'u8),  (0x7fffde'u32, 23'u8),   (0xffffeb'u32, 24'u8),  (0x7fffdf'u32, 23'u8),
    (0xffffec'u32, 24'u8),  (0xffffed'u32, 24'u8),    (0x3fffd7'u32, 22'u8),  (0x7fffe0'u32, 23'u8),
    (0xffffee'u32, 24'u8),  (0x7fffe1'u32, 23'u8),    (0x7fffe2'u32, 23'u8),  (0x7fffe3'u32, 23'u8),
    (0x7fffe4'u32, 23'u8),  (0x1fffdc'u32, 21'u8),    (0x3fffd8'u32, 22'u8),  (0x7fffe5'u32, 23'u8),
    (0x3fffd9'u32, 22'u8),  (0x7fffe6'u32, 23'u8),    (0x7fffe7'u32, 23'u8),  (0xffffef'u32, 24'u8),
    (0x3fffda'u32, 22'u8),  (0x1fffdd'u32, 21'u8),    (0xfffe9'u32, 20'u8),   (0x3fffdb'u32, 22'u8),
    (0x3fffdc'u32, 22'u8),  (0x7fffe8'u32, 23'u8),    (0x7fffe9'u32, 23'u8),  (0x1fffde'u32, 21'u8),
    (0x7fffea'u32, 23'u8),  (0x3fffdd'u32, 22'u8),    (0x3fffde'u32, 22'u8),  (0xfffff0'u32, 24'u8),
    (0x1fffdf'u32, 21'u8),  (0x3fffdf'u32, 22'u8),    (0x7fffeb'u32, 23'u8),  (0x7fffec'u32, 23'u8),
    (0x1fffe0'u32, 21'u8),  (0x1fffe1'u32, 21'u8),    (0x3fffe0'u32, 22'u8),  (0x1fffe2'u32, 21'u8),
    (0x7fffed'u32, 23'u8),  (0x3fffe1'u32, 22'u8),    (0x7fffee'u32, 23'u8),  (0x7fffef'u32, 23'u8),
    (0xfffea'u32, 20'u8),   (0x3fffe2'u32, 22'u8),    (0x3fffe3'u32, 22'u8),  (0x3fffe4'u32, 22'u8),
    (0x7ffff0'u32, 23'u8),  (0x3fffe5'u32, 22'u8),    (0x3fffe6'u32, 22'u8),  (0x7ffff1'u32, 23'u8),
    (0x3ffffff0'u32, 26'u8),(0x3ffffff1'u32, 26'u8),   (0xfffeb'u32, 20'u8),   (0x7fff1'u32, 19'u8),
    (0x3fffe7'u32, 22'u8),  (0x7ffff2'u32, 23'u8),    (0x3fffe8'u32, 22'u8),  (0x1ffffec'u32, 25'u8),
    (0x3ffffff2'u32, 26'u8),(0x3ffffff3'u32, 26'u8),   (0x3ffffff4'u32, 26'u8),(0x7ffffde'u32, 27'u8),
    (0x7ffffdf'u32, 27'u8),(0x3ffffff5'u32, 26'u8),    (0xfffff1'u32, 24'u8),  (0x1ffffed'u32, 25'u8),
    (0x7fff2'u32, 19'u8),   (0x1fffe3'u32, 21'u8),    (0x3ffffff6'u32, 26'u8),(0x7ffffe0'u32, 27'u8),
    (0x7ffffe1'u32, 27'u8),(0x3ffffff7'u32, 26'u8),    (0x7ffffe2'u32, 27'u8),(0xfffff2'u32, 24'u8),
    (0x1fffe4'u32, 21'u8), (0x1fffe5'u32, 21'u8),     (0x3ffffff8'u32, 26'u8),(0x3ffffff9'u32, 26'u8),
    (0xffffffd'u32, 28'u8),(0x7ffffe3'u32, 27'u8),     (0x7ffffe4'u32, 27'u8),(0x7ffffe5'u32, 27'u8),
    (0xfffec'u32, 20'u8),  (0xfffff3'u32, 24'u8),      (0xfffed'u32, 20'u8),  (0x1fffe6'u32, 21'u8),
    (0x3fffe9'u32, 22'u8), (0x1fffe7'u32, 21'u8),      (0x1fffe8'u32, 21'u8), (0x7ffff3'u32, 23'u8),
    (0x3fffea'u32, 22'u8), (0x3fffeb'u32, 22'u8),      (0x1ffffee'u32, 25'u8),(0x1ffffef'u32, 25'u8),
    (0xfffff4'u32, 24'u8), (0xfffff5'u32, 24'u8),      (0x3ffffffa'u32, 26'u8),(0x7ffff4'u32, 23'u8),
    (0x3ffffffb'u32, 26'u8),(0x7ffffe6'u32, 27'u8),    (0x3ffffffc'u32, 26'u8),(0x3ffffffd'u32, 26'u8),
    (0x7ffffe7'u32, 27'u8),(0x7ffffe8'u32, 27'u8),     (0x7ffffe9'u32, 27'u8),(0x7ffffea'u32, 27'u8),
    (0x7ffffeb'u32, 27'u8),(0xffffffe'u32, 28'u8),     (0x7ffffec'u32, 27'u8),(0x7ffffed'u32, 27'u8),
    (0x7ffffee'u32, 27'u8),(0x7ffffef'u32, 27'u8),     (0x7fffff0'u32, 27'u8),(0x3ffffee'u32, 26'u8),
    (0x3fffffff'u32, 30'u8),
  ]

proc entrySize(name, value: string): int {.inline.} =
  name.len + value.len + 32

## Creates a new HPACK dynamic table with the given maximum size in bytes.
proc initHpackDynamicTable*(maxSize: int = 4096): HpackDynamicTable {.inline.} =
  HpackDynamicTable(entries: initDeque[HpackEntry](), size: 0, maxSize: maxSize)

proc evict(dt: var HpackDynamicTable) {.inline.} =
  while dt.size > dt.maxSize and dt.entries.len > 0:
    let e = dt.entries.popLast()
    dt.size -= entrySize(e.name, e.value)

## Adds a header field to the dynamic table, evicting oldest entries to fit the size limit.
proc add*(dt: var HpackDynamicTable, name, value: string) =
  let es = entrySize(name, value)
  if es > dt.maxSize:
    dt.entries = initDeque[HpackEntry]()
    dt.size = 0
    return
  dt.size += es
  dt.entries.addFirst(HpackEntry(name: name, value: value))
  dt.evict()

## Updates the dynamic table size limit, raising `HpackError` for invalid values, then evicts excess entries.
proc setMaxSize*(dt: var HpackDynamicTable, newMax: int, limit: int = -1) =
  if newMax < 0:
    raise newException(HpackError, "HPACK dynamic table size update negative: " & $newMax)
  if newMax > MaxHpackDynamicTableSize:
    raise newException(HpackError, "HPACK dynamic table size update exceeds implementation limit: " & $newMax)
  if limit >= 0 and newMax > limit:
    raise newException(HpackError, "HPACK dynamic table size update exceeds limit: " & $newMax & " > " & $limit)
  dt.maxSize = newMax
  dt.evict()

## Returns the number of entries currently stored in the dynamic table.
proc len*(dt: HpackDynamicTable): int {.inline.} = dt.entries.len

## Returns the dynamic table entry at the given zero-based position.
proc get*(dt: HpackDynamicTable, idx: int): HpackEntry {.inline.} =
  if idx < 0 or idx >= dt.entries.len:
    raise newException(HpackError, "dynamic table index out of range")
  dt.entries[idx]

## Finds a header field in the dynamic table, returning an index offset by 62 and a name-only match flag.
proc lookup*(dt: HpackDynamicTable, name, value: string): tuple[index: int, nameMatch: bool] {.inline.} =
  for i in 0 ..< dt.entries.len:
    if dt.entries[i].name == name:
      if dt.entries[i].value == value:
        return (62 + i, false)
      if result.index == 0:
        result = (62 + i, true)

proc staticNameHash(s: string): uint32 {.inline.} =
  var h: uint32 = 2166136261'u32
  for c in s:
    h = h xor uint32(c)
    h = h * 16777619'u32
  h

const StaticBucketCount = 128

type StaticNameEntry = object
  nameHash: uint32
  firstIndex: int16
  lastIndex: int16

const StaticNameMap: array[StaticBucketCount, StaticNameEntry] = block:
  var m: array[StaticBucketCount, StaticNameEntry]
  for i in 0 ..< StaticBucketCount:
    m[i] = StaticNameEntry(nameHash: 0, firstIndex: -1, lastIndex: -1)
  for i in 1 .. 61:
    let h = staticNameHash(HpackStaticTable[i].name)
    let slot = int(h and uint32(StaticBucketCount - 1))
    if m[slot].firstIndex < 0:
      m[slot] = StaticNameEntry(nameHash: h, firstIndex: int16(i), lastIndex: int16(i))
    else:
      m[slot].lastIndex = int16(i)
  m

## Finds a header field in the RFC 7541 static table, returning its index and match quality.
proc lookupStatic*(name, value: string): tuple[index: int, nameMatch: bool] {.inline.} =
  let h = staticNameHash(name)
  let slot = int(h and uint32(StaticBucketCount - 1))
  let entry = StaticNameMap[slot]
  if entry.firstIndex < 0:
    return (0, false)
  for i in entry.firstIndex .. entry.lastIndex:
    if HpackStaticTable[i].name == name:
      if HpackStaticTable[i].value == value:
        return (int(i), false)
      if result.index == 0:
        result = (int(i), true)

## Resolves a one-based HPACK table index across the static and dynamic tables into an entry.
proc getEntry*(dt: HpackDynamicTable, index: int): HpackEntry =
  if index < 1:
    raise newException(HpackError, "invalid HPACK index 0")
  if index <= 61:
    return HpackStaticTable[index]
  let dynIdx = index - 62
  if dynIdx >= dt.entries.len:
    raise newException(HpackError, "HPACK index " & $index & " out of range")
  dt.entries[dynIdx]

## Creates a new HPACK encoder with Huffman coding enabled by default.
proc initHpackEncoder*(huffman: bool = true): HpackEncoder {.inline.} =
  HpackEncoder(dynamicTable: initHpackDynamicTable(), huffman: huffman,
               pendingSizeUpdate: false, pendingMaxSize: 4096)

## Schedules a dynamic table size update to be emitted on the next `hpackEncode` call.
proc updateEncoderMaxSize*(encoder: var HpackEncoder, newMax: int) =
  if newMax < 0:
    raise newException(HpackError, "HPACK encoder table size update negative: " & $newMax)
  let boundedMax = min(newMax, MaxHpackDynamicTableSize)
  encoder.pendingMaxSize = boundedMax
  encoder.pendingSizeUpdate = true
  encoder.dynamicTable.setMaxSize(boundedMax)

## Creates a new HPACK decoder whose dynamic table allows the given maximum size.
proc initHpackDecoder*(maxSize: int = 4096): HpackDecoder {.inline.} =
  HpackDecoder(dynamicTable: initHpackDynamicTable(maxSize), settingsMaxSize: maxSize, pendingSizeUpdate: false)

## Applies a SETTINGS header table size update, requiring a decoder size update on the next block.
proc updateSettingsMaxSize*(decoder: var HpackDecoder, newMax: int) =
  if newMax < decoder.settingsMaxSize:
    decoder.pendingSizeUpdate = true
  decoder.settingsMaxSize = newMax

## Encodes an integer using the HPACK variable-length integer format into the buffer.
proc hpackEncodeInt*(buf: var string, value: int, prefix: int, prefixByte: uint8) =
  let maxVal = (1 shl prefix) - 1
  if value < maxVal:
    buf.add char(prefixByte or uint8(value))
  else:
    buf.add char(prefixByte or uint8(maxVal))
    var v = value - maxVal
    while v >= 128:
      buf.add char((v and 0x7F) or 0x80)
      v = v shr 7
    buf.add char(v)

## Decodes a HPACK variable-length integer from the data, advancing the position past it.
proc hpackDecodeInt*(data: openArray[byte], pos: var int, prefix: int): int =
  if pos >= data.len:
    raise newException(HpackError, "unexpected end of HPACK data")
  let maxVal = (1 shl prefix) - 1
  result = int(data[pos]) and maxVal
  inc pos
  if result < maxVal:
    return
  var shift = 0
  while true:
    if pos >= data.len:
      raise newException(HpackError, "unexpected end of HPACK integer")
    if shift > 28:
      raise newException(HpackError, "HPACK integer overflow: too many continuation bytes")
    let b = int(data[pos])
    inc pos
    let addend = (b and 0x7F) shl shift
    if addend > 268_435_455 - result:
      raise newException(HpackError, "HPACK integer overflow")
    result += addend
    shift += 7
    if (b and 0x80) == 0:
      break

## Encodes bytes with the HPACK Huffman code table, appending the encoded bits to the buffer.
proc huffmanEncode*(src: openArray[byte], buf: var string) =
  var bitBuf: uint64 = 0
  var bitsLeft = 0
  for b in src:
    let entry = HuffmanEncodeTable[int(b)]
    bitBuf = (bitBuf shl entry.bits) or uint64(entry.code)
    bitsLeft += int(entry.bits)
    while bitsLeft >= 8:
      bitsLeft -= 8
      buf.add char((bitBuf shr bitsLeft) and 0xFF)
  if bitsLeft > 0:
    let padding = 8 - bitsLeft
    bitBuf = (bitBuf shl padding) or ((1'u64 shl padding) - 1)
    buf.add char(bitBuf and 0xFF)

## Returns the HPACK Huffman encoding of a string.
proc huffmanEncodeStr*(src: string): string =
  result = newStringOfCap(src.len)
  huffmanEncode(cast[seq[byte]](src), result)

## Returns the byte length of the Huffman encoding of the input without performing the encoding.
proc huffmanEncodedLen*(src: openArray[byte]): int =
  var bits = 0
  for b in src:
    bits += int(HuffmanEncodeTable[int(b)].bits)
  result = (bits + 7) div 8

type
  HuffmanNode = object
    children: array[2, int16]
    sym: int16
    isLeaf: bool

const HuffmanTreeMaxNodes = 1024

const HuffmanTreeData: tuple[nodes: array[HuffmanTreeMaxNodes, HuffmanNode], count: int] = block:
  var nodes: array[HuffmanTreeMaxNodes, HuffmanNode]
  var count = 1
  nodes[0] = HuffmanNode(children: [-1'i16, -1'i16], sym: -1, isLeaf: false)
  for sym in 0 .. 256:
    let entry = HuffmanEncodeTable[sym]
    var node = 0
    for bitIdx in countdown(int(entry.bits) - 1, 0):
      let bit = int((entry.code shr bitIdx) and 1)
      if nodes[node].children[bit] < 0:
        nodes[count] = HuffmanNode(children: [-1'i16, -1'i16], sym: -1, isLeaf: false)
        nodes[node].children[bit] = int16(count)
        inc count
      node = int(nodes[node].children[bit])
    nodes[node].isLeaf = true
    nodes[node].sym = int16(sym)
  (nodes, count)

const HuffmanMaxDecodedLen* = 65536

## Decodes HPACK Huffman-encoded bytes into the buffer, validating the code stream and padding.
proc huffmanDecode*(data: openArray[byte], buf: var string) =
  if data.len == 0:
    return
  var node = 0
  var bitsSinceLastSym = 0
  var decoded = 0
  for byteIdx in 0 ..< data.len:
    let b = data[byteIdx]
    for bitIdx in countdown(7, 0):
      let bit = int((b shr bitIdx) and 1)
      let child = int(HuffmanTreeData.nodes[node].children[bit])
      if child < 0:
        raise newException(HpackError, "invalid Huffman code")
      node = child
      bitsSinceLastSym += 1
      if HuffmanTreeData.nodes[node].isLeaf:
        if HuffmanTreeData.nodes[node].sym == 256:
          raise newException(HpackError, "Huffman EOS symbol decoded")
        decoded += 1
        if decoded > HuffmanMaxDecodedLen:
          raise newException(HpackError, "Huffman decoded output exceeds limit")
        buf.add char(HuffmanTreeData.nodes[node].sym)
        node = 0
        bitsSinceLastSym = 0
  if node != 0:
    if bitsSinceLastSym > 7:
      raise newException(HpackError, "incomplete Huffman code")
    if data.len > 0:
      let lastByte = data[data.len - 1]
      let paddingMask = uint8((1 shl bitsSinceLastSym) - 1)
      if (lastByte and paddingMask) != paddingMask:
        raise newException(HpackError, "invalid Huffman padding bits")

## Returns the string decoded from HPACK Huffman-encoded bytes.
proc huffmanDecodeStr*(data: openArray[byte]): string =
  result = newStringOfCap(data.len * 2)
  huffmanDecode(data, result)

## Encodes a literal HPACK string with a length prefix, using Huffman coding when requested.
proc hpackEncodeString*(buf: var string, s: string, useHuffman: bool) =
  if useHuffman:
    let encodedLen = huffmanEncodedLen(cast[seq[byte]](s))
    hpackEncodeInt(buf, encodedLen, 7, 0x80)
    if encodedLen > 0:
      let startPos = buf.len
      buf.setLen(startPos + encodedLen)
      var bitBuf: uint64 = 0
      var bitsLeft = 0
      var writePos = startPos
      for i in 0 ..< s.len:
        let entry = HuffmanEncodeTable[int(s[i])]
        bitBuf = (bitBuf shl entry.bits) or uint64(entry.code)
        bitsLeft += int(entry.bits)
        while bitsLeft >= 8:
          bitsLeft -= 8
          buf[writePos] = char((bitBuf shr bitsLeft) and 0xFF)
          inc writePos
      if bitsLeft > 0:
        let padding = 8 - bitsLeft
        bitBuf = (bitBuf shl padding) or ((1'u64 shl padding) - 1)
        buf[writePos] = char(bitBuf and 0xFF)
  else:
    hpackEncodeInt(buf, s.len, 7, 0x00)
    if s.len > 0:
      let pos = buf.len
      buf.setLen(pos + s.len)
      copyMem(addr buf[pos], unsafeAddr s[0], s.len)

const
  HpackMaxStringLen* = 65536
  HpackMaxHeaderCount* = 4096
  HpackMaxHeaderListBytes* = 1024 * 1024

## Decodes a length-prefixed literal HPACK string, applying Huffman decoding when flagged.
proc hpackDecodeString*(data: openArray[byte], pos: var int): string =
  if pos >= data.len:
    raise newException(HpackError, "unexpected end of HPACK string")
  let huffmanFlag = (data[pos] and 0x80) != 0
  let strLen = hpackDecodeInt(data, pos, 7)
  if strLen > HpackMaxStringLen:
    raise newException(HpackError, "HPACK string length exceeds limit: " & $strLen)
  if pos + strLen > data.len:
    raise newException(HpackError, "HPACK string length exceeds data")
  if huffmanFlag:
    result = huffmanDecodeStr(data.toOpenArray(pos, pos + strLen - 1))
  else:
    result = newString(strLen)
    if strLen > 0:
      copyMem(addr result[0], unsafeAddr data[pos], strLen)
  pos += strLen

## Encodes a header block into the buffer using indexed, literal, and dynamic table entries.
proc hpackEncode*(encoder: var HpackEncoder, headers: openArray[(string, string)], buf: var string) =
  if encoder.pendingSizeUpdate:
    hpackEncodeInt(buf, encoder.pendingMaxSize, 5, 0x20)
    encoder.pendingSizeUpdate = false
  for (name, value) in headers:
    let staticResult = lookupStatic(name, value)

    if staticResult.index > 0 and not staticResult.nameMatch:
      hpackEncodeInt(buf, staticResult.index, 7, 0x80)
      continue

    let dynLen = encoder.dynamicTable.entries.len
    var dynIndex = 0
    var dynNameMatch = false
    for i in 0 ..< min(dynLen, 16):
      if encoder.dynamicTable.entries[i].name == name:
        if encoder.dynamicTable.entries[i].value == value:
          dynIndex = 62 + i
          dynNameMatch = false
          break
        if dynIndex == 0:
          dynIndex = 62 + i
          dynNameMatch = true
    if dynIndex == 0 and dynLen > 16:
      for i in 16 ..< dynLen:
        if encoder.dynamicTable.entries[i].name == name:
          if encoder.dynamicTable.entries[i].value == value:
            dynIndex = 62 + i
            dynNameMatch = false
            break
          if dynIndex == 0:
            dynIndex = 62 + i
            dynNameMatch = true

    if dynIndex > 0 and not dynNameMatch:
      hpackEncodeInt(buf, dynIndex, 7, 0x80)
    elif staticResult.index > 0:
      hpackEncodeInt(buf, staticResult.index, 6, 0x40)
      hpackEncodeString(buf, value, encoder.huffman)
      encoder.dynamicTable.add(name, value)
    elif dynIndex > 0 and dynNameMatch:
      hpackEncodeInt(buf, dynIndex, 6, 0x40)
      hpackEncodeString(buf, value, encoder.huffman)
      encoder.dynamicTable.add(name, value)
    else:
      hpackEncodeInt(buf, 0, 6, 0x40)
      hpackEncodeString(buf, name, encoder.huffman)
      hpackEncodeString(buf, value, encoder.huffman)
      encoder.dynamicTable.add(name, value)

## Decodes a full HPACK header block into a sequence of name and value pairs.
proc hpackDecode*(decoder: var HpackDecoder, data: openArray[byte]): seq[(string, string)] =
  result = newSeqOfCap[(string, string)](8)
  var pos = 0
  var sizeUpdateAllowed = true
  var sizeUpdateSeen = false
  var totalDecodedBytes = 0
  template addDecodedBytes(amount: int) =
    totalDecodedBytes += amount
    if totalDecodedBytes > HpackMaxHeaderListBytes:
      raise newException(HpackError, "HPACK decoded header list size exceeds limit")

  while pos < data.len:
    if result.len >= HpackMaxHeaderCount:
      raise newException(HpackError, "HPACK header count exceeds limit")
    let b = data[pos]
    if (b and 0xE0) == 0x20:
      if not sizeUpdateAllowed:
        raise newException(HpackError, "HPACK dynamic table size update after header entry")
      let newSize = hpackDecodeInt(data, pos, 5)
      if newSize > decoder.settingsMaxSize:
        raise newException(HpackError, "HPACK dynamic table size update exceeds SETTINGS_HEADER_TABLE_SIZE")
      decoder.dynamicTable.setMaxSize(newSize)
      sizeUpdateSeen = true
      decoder.pendingSizeUpdate = false
      continue
    if decoder.pendingSizeUpdate and not sizeUpdateSeen:
      raise newException(HpackError, "HPACK: mandatory dynamic table size update missing after SETTINGS change")
    sizeUpdateAllowed = false
    if (b and 0x80) != 0:
      let index = hpackDecodeInt(data, pos, 7)
      if index == 0:
        raise newException(HpackError, "indexed header field index 0")
      let entry = decoder.dynamicTable.getEntry(index)
      addDecodedBytes(entry.name.len + entry.value.len + 32)
      result.add((entry.name, entry.value))
    elif (b and 0xC0) == 0x40:
      let index = hpackDecodeInt(data, pos, 6)
      var name, value: string
      if index > 0:
        name = decoder.dynamicTable.getEntry(index).name
      else:
        name = hpackDecodeString(data, pos)
      value = hpackDecodeString(data, pos)
      addDecodedBytes(name.len + value.len + 32)
      decoder.dynamicTable.add(name, value)
      result.add((name, value))
    elif (b and 0xF0) == 0x00 or (b and 0xF0) == 0x10:
      let index = hpackDecodeInt(data, pos, 4)
      var name, value: string
      if index > 0:
        name = decoder.dynamicTable.getEntry(index).name
      else:
        name = hpackDecodeString(data, pos)
      value = hpackDecodeString(data, pos)
      addDecodedBytes(name.len + value.len + 32)
      result.add((name, value))
    else:
      raise newException(HpackError, "unknown HPACK prefix byte: " & $b)
