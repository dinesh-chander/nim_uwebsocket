import std/[monotimes, times, strformat, strutils]

const
  MinDurationNs = 1_000_000_000'i64
  WarmupIters = 5_000

type
  WebSocketOpcode = enum
    wsText = 0x1
    wsBinary = 0x2
    wsClose = 0x8
    wsPing = 0x9
    wsPong = 0xA

  BenchResult = object
    name: string
    iterations: int64
    totalNs: int64
    nsPerOp: float64
    opsPerSec: float64
    bytesPerOp: int
    throughputMBs: float64

proc newStringUninit(len: int): string {.inline.} =
  result = newString(len)

proc wsFrameHeaderLen(payloadLen: int): int {.inline.} =
  if payloadLen < 126: 2
  elif payloadLen < 65536: 4
  else: 10

proc wsFrameTotalLen(payloadLen: int): int {.inline, used.} =
  wsFrameHeaderLen(payloadLen) + payloadLen

proc buildWsFrame(opcode: WebSocketOpcode, payload: string, rsv1: bool = false): string {.inline.} =
  let length = payload.len
  let hdrLen = wsFrameHeaderLen(length)
  result = newStringUninit(hdrLen + length)
  result[0] = char(0x80 or ord(opcode) or (if rsv1: 0x40 else: 0))
  if length < 126:
    result[1] = char(length)
  elif length < 65536:
    result[1] = char(126)
    result[2] = char((length shr 8) and 0xFF)
    result[3] = char(length and 0xFF)
  else:
    result[1] = char(127)
    for i in 0..7:
      result[2 + i] = char((length shr ((7 - i) * 8)) and 0xFF)
  if length > 0:
    copyMem(addr result[hdrLen], unsafeAddr payload[0], length)

when defined(singleThread) or not compileOption("threads"):
  var wsFrameReuseBuf: string
else:
  var wsFrameReuseBuf {.threadvar.}: string

proc buildWsFrameReuse(opcode: WebSocketOpcode, payload: string, rsv1: bool = false): string {.inline.} =
  let length = payload.len
  let hdrLen = wsFrameHeaderLen(length)
  let totalLen = hdrLen + length
  if wsFrameReuseBuf.len < totalLen:
    wsFrameReuseBuf = newStringOfCap(max(totalLen, 4096))
  wsFrameReuseBuf.setLen(totalLen)
  wsFrameReuseBuf[0] = char(0x80 or ord(opcode) or (if rsv1: 0x40 else: 0))
  if length < 126:
    wsFrameReuseBuf[1] = char(length)
  elif length < 65536:
    wsFrameReuseBuf[1] = char(126)
    wsFrameReuseBuf[2] = char((length shr 8) and 0xFF)
    wsFrameReuseBuf[3] = char(length and 0xFF)
  else:
    wsFrameReuseBuf[1] = char(127)
    for i in 0..7:
      wsFrameReuseBuf[2 + i] = char((length shr ((7 - i) * 8)) and 0xFF)
  if length > 0:
    copyMem(addr wsFrameReuseBuf[hdrLen], unsafeAddr payload[0], length)
  wsFrameReuseBuf

proc unmaskInPlace(
  data: var openArray[byte],
  payloadPos: int,
  payloadLen: int,
  k0, k1, k2, k3: byte
) {.inline.} =
  if payloadLen <= 0:
    return
  var i = 0
  let maskKeys = [k0, k1, k2, k3]
  when cpuEndian == littleEndian:
    let m32 = uint32(k0) or
              (uint32(k1) shl 8) or
              (uint32(k2) shl 16) or
              (uint32(k3) shl 24)
    let m64 = uint64(m32) or (uint64(m32) shl 32)
    let base = cast[uint](addr data[payloadPos])
    let misalign = int(base and 7'u)
    if misalign != 0:
      let headBytes = min(8 - misalign, payloadLen)
      while i < headBytes:
        data[payloadPos + i] = data[payloadPos + i] xor maskKeys[i and 3]
        inc i
    if i + 8 <= payloadLen:
      let rotAmount = i and 3
      var rm64 = m64
      if rotAmount != 0:
        let rm32 = (m32 shr uint32(rotAmount * 8)) or (m32 shl uint32((4 - rotAmount) * 8))
        rm64 = uint64(rm32) or (uint64(rm32) shl 32)
      let p64 = cast[ptr UncheckedArray[uint64]](addr data[payloadPos + i])
      var j = 0
      let count64 = (payloadLen - i) shr 3
      while j < count64:
        p64[j] = p64[j] xor rm64
        inc j
      i += count64 shl 3
    if i + 4 <= payloadLen:
      let rotAmount = i and 3
      var rm32 = m32
      if rotAmount != 0:
        rm32 = (m32 shr uint32(rotAmount * 8)) or (m32 shl uint32((4 - rotAmount) * 8))
      let p32 = cast[ptr UncheckedArray[uint32]](addr data[payloadPos + i])
      p32[0] = p32[0] xor rm32
      i += 4
  else:
    while i + 4 <= payloadLen:
      data[payloadPos + i] = data[payloadPos + i] xor k0
      data[payloadPos + i + 1] = data[payloadPos + i + 1] xor k1
      data[payloadPos + i + 2] = data[payloadPos + i + 2] xor k2
      data[payloadPos + i + 3] = data[payloadPos + i + 3] xor k3
      i += 4
  while i < payloadLen:
    data[payloadPos + i] = data[payloadPos + i] xor maskKeys[i and 3]
    inc i

proc unmaskWebSocketPayload(
  data: openArray[byte],
  payloadPos: int,
  payloadLen: int,
  k0, k1, k2, k3: byte
): string {.inline.} =
  result = newStringUninit(payloadLen)
  if payloadLen <= 0:
    return
  var i = 0
  let maskKeys = [k0, k1, k2, k3]
  when cpuEndian == littleEndian:
    let m32 = uint32(k0) or
              (uint32(k1) shl 8) or
              (uint32(k2) shl 16) or
              (uint32(k3) shl 24)
    let m64 = uint64(m32) or (uint64(m32) shl 32)
    let dstBase = cast[uint](addr result[0])
    let dstMisalign = int(dstBase and 7'u)
    if dstMisalign != 0 and payloadLen >= 8:
      let headBytes = min(8 - dstMisalign, payloadLen)
      while i < headBytes:
        result[i] = char(data[payloadPos + i] xor maskKeys[i and 3])
        inc i
    if i + 8 <= payloadLen:
      let rotAmount = i and 3
      var rm64 = m64
      if rotAmount != 0:
        let rm32 = (m32 shr uint32(rotAmount * 8)) or (m32 shl uint32((4 - rotAmount) * 8))
        rm64 = uint64(rm32) or (uint64(rm32) shl 32)
      let dst64 = cast[ptr UncheckedArray[uint64]](addr result[i])
      var j = 0
      let count64 = (payloadLen - i) shr 3
      let srcP = cast[uint](unsafeAddr data[payloadPos + i])
      let srcAligned = (srcP and 7'u) == 0'u
      if srcAligned:
        let src64 = cast[ptr UncheckedArray[uint64]](unsafeAddr data[payloadPos + i])
        while j < count64:
          dst64[j] = src64[j] xor rm64
          inc j
      else:
        var tmp64: uint64
        while j < count64:
          copyMem(addr tmp64, unsafeAddr data[payloadPos + i + j * 8], 8)
          dst64[j] = tmp64 xor rm64
          inc j
      i += count64 shl 3
    if i + 4 <= payloadLen:
      let rotAmount = i and 3
      var rm32 = m32
      if rotAmount != 0:
        rm32 = (m32 shr uint32(rotAmount * 8)) or (m32 shl uint32((4 - rotAmount) * 8))
      var tmp32: uint32
      copyMem(addr tmp32, unsafeAddr data[payloadPos + i], 4)
      tmp32 = tmp32 xor rm32
      copyMem(addr result[i], addr tmp32, 4)
      i += 4
  else:
    while i + 4 <= payloadLen:
      result[i] = char(data[payloadPos + i] xor k0)
      result[i + 1] = char(data[payloadPos + i + 1] xor k1)
      result[i + 2] = char(data[payloadPos + i + 2] xor k2)
      result[i + 3] = char(data[payloadPos + i + 3] xor k3)
      i += 4
  while i < payloadLen:
    result[i] = char(data[payloadPos + i] xor maskKeys[i and 3])
    inc i

proc unmaskWebSocketPayloadInPlace(
  data: var openArray[byte],
  payloadPos: int,
  payloadLen: int,
  k0, k1, k2, k3: byte,
  payload: var string
) {.inline.} =
  unmaskInPlace(data, payloadPos, payloadLen, k0, k1, k2, k3)
  payload = newStringUninit(payloadLen)
  if payloadLen > 0:
    copyMem(addr payload[0], addr data[payloadPos], payloadLen)

proc wsClosePayload(code: int, reason: string = ""): string {.inline.} =
  let reasonLen = min(reason.len, 123)
  result = newStringUninit(2 + reasonLen)
  result[0] = char((code shr 8) and 0xFF)
  result[1] = char(code and 0xFF)
  if reasonLen > 0:
    copyMem(addr result[2], unsafeAddr reason[0], reasonLen)

proc isAsciiOnly(data: string): bool {.inline.} =
  if data.len == 0:
    return true
  var i = 0
  when cpuEndian == littleEndian:
    let p = cast[uint](unsafeAddr data[0])
    while i + 8 <= data.len:
      var w: uint64
      copyMem(addr w, cast[pointer](p + uint(i)), 8)
      if (w and 0x8080808080808080'u64) != 0:
        return false
      i += 8
  while i < data.len:
    if ord(data[i]) > 127:
      return false
    inc i
  true

proc isAsciiOnlyBytes(data: openArray[byte], start: int, length: int): bool {.inline, used.} =
  if length == 0:
    return true
  var i = 0
  when cpuEndian == littleEndian:
    let p = cast[uint](unsafeAddr data[start])
    while i + 8 <= length:
      var w: uint64
      copyMem(addr w, cast[pointer](p + uint(i)), 8)
      if (w and 0x8080808080808080'u64) != 0:
        return false
      i += 8
  while i < length:
    if data[start + i] > 127:
      return false
    inc i
  true

proc validateUtf8Bytes(data: openArray[byte], start: int, length: int): int {.inline.} =
  if length == 0:
    return -1
  var i = 0
  while i < length:
    let b = data[start + i]
    if b <= 0x7F'u8:
      inc i
    elif (b and 0xE0'u8) == 0xC0'u8:
      if i + 1 >= length:
        return i
      if (data[start + i + 1] and 0xC0'u8) != 0x80'u8:
        return i
      let cp = (uint32(b and 0x1F'u8) shl 6) or uint32(data[start + i + 1] and 0x3F'u8)
      if cp < 0x80'u32:
        return i
      i += 2
    elif (b and 0xF0'u8) == 0xE0'u8:
      if i + 2 >= length:
        return i
      if (data[start + i + 1] and 0xC0'u8) != 0x80'u8:
        return i
      if (data[start + i + 2] and 0xC0'u8) != 0x80'u8:
        return i
      let cp = (uint32(b and 0x0F'u8) shl 12) or
               (uint32(data[start + i + 1] and 0x3F'u8) shl 6) or
               uint32(data[start + i + 2] and 0x3F'u8)
      if cp < 0x800'u32:
        return i
      if cp >= 0xD800'u32 and cp <= 0xDFFF'u32:
        return i
      i += 3
    elif (b and 0xF8'u8) == 0xF0'u8:
      if i + 3 >= length:
        return i
      if (data[start + i + 1] and 0xC0'u8) != 0x80'u8:
        return i
      if (data[start + i + 2] and 0xC0'u8) != 0x80'u8:
        return i
      if (data[start + i + 3] and 0xC0'u8) != 0x80'u8:
        return i
      let cp = (uint32(b and 0x07'u8) shl 18) or
               (uint32(data[start + i + 1] and 0x3F'u8) shl 12) or
               (uint32(data[start + i + 2] and 0x3F'u8) shl 6) or
               uint32(data[start + i + 3] and 0x3F'u8)
      if cp < 0x10000'u32 or cp > 0x10FFFF'u32:
        return i
      i += 4
    else:
      return i
  -1

proc decodeWebSocketFrame(
  data: var openArray[byte],
  start: int,
  opcode: var int,
  payload: var string,
  consumed: var int,
  fin: var bool,
  compressed: var bool,
  allowCompressed: bool
): int {.inline.} =
  let dataLen = data.len - start
  if dataLen < 2:
    return 0
  var pos = start
  let byte1 = int(data[pos])
  fin = (byte1 and 0x80) != 0
  let rsv1 = (byte1 and 0x40) != 0
  if (byte1 and 0x30) != 0:
    return -1
  opcode = byte1 and 0x0F
  if rsv1:
    if not allowCompressed or opcode == 0x0 or opcode >= 0x8:
      return -1
    compressed = true
  else:
    compressed = false
  inc pos
  let byte2 = int(data[pos])
  if (byte2 and 0x80) == 0:
    return -2
  var payloadLen = byte2 and 0x7F
  inc pos
  if payloadLen < 126:
    if opcode >= 0x8 and (not fin or compressed):
      return -1
    let frameBytes = 2 + 4 + payloadLen
    if dataLen < frameBytes:
      return 0
    let k0 = data[pos]
    let k1 = data[pos + 1]
    let k2 = data[pos + 2]
    let k3 = data[pos + 3]
    unmaskWebSocketPayloadInPlace(data, pos + 4, payloadLen, k0, k1, k2, k3, payload)
    consumed = frameBytes
    return 1
  if payloadLen == 126:
    if dataLen < pos - start + 2:
      return 0
    payloadLen = (int(data[pos]) shl 8) or int(data[pos + 1])
    pos += 2
  elif payloadLen == 127:
    if dataLen < pos - start + 8:
      return 0
    payloadLen = 0
    for i in 0..<8:
      if payloadLen > (high(int) shr 8):
        return -1
      payloadLen = (payloadLen shl 8) or int(data[pos + i])
    pos += 8
  if opcode >= 0x8:
    if not fin or payloadLen > 125 or compressed:
      return -1
  if dataLen < pos - start + 4:
    return 0
  let k0 = data[pos]
  let k1 = data[pos + 1]
  let k2 = data[pos + 2]
  let k3 = data[pos + 3]
  pos += 4
  if dataLen < pos - start + payloadLen:
    return 0
  unmaskWebSocketPayloadInPlace(data, pos, payloadLen, k0, k1, k2, k3, payload)
  consumed = pos + payloadLen - start
  1

proc buildMaskedFrame(opcode: WebSocketOpcode, payload: string, mask: array[4, byte]): seq[byte] =
  let length = payload.len
  var hdrLen = 2 + 4
  if length >= 126 and length < 65536:
    hdrLen = 4 + 4
  elif length >= 65536:
    hdrLen = 10 + 4
  result = newSeq[byte](hdrLen + length)
  result[0] = byte(0x80 or ord(opcode))
  if length < 126:
    result[1] = byte(0x80 or length)
    result[2] = mask[0]
    result[3] = mask[1]
    result[4] = mask[2]
    result[5] = mask[3]
    for i in 0 ..< length:
      result[6 + i] = byte(payload[i]) xor mask[i and 3]
  elif length < 65536:
    result[1] = byte(0x80 or 126)
    result[2] = byte((length shr 8) and 0xFF)
    result[3] = byte(length and 0xFF)
    result[4] = mask[0]
    result[5] = mask[1]
    result[6] = mask[2]
    result[7] = mask[3]
    for i in 0 ..< length:
      result[8 + i] = byte(payload[i]) xor mask[i and 3]
  else:
    result[1] = byte(0x80 or 127)
    for i in 0..7:
      result[2 + i] = byte((length shr ((7 - i) * 8)) and 0xFF)
    result[10] = mask[0]
    result[11] = mask[1]
    result[12] = mask[2]
    result[13] = mask[3]
    for i in 0 ..< length:
      result[14 + i] = byte(payload[i]) xor mask[i and 3]

template benchmark(benchName: string, bpo: int, body: untyped) {.dirty.} =
  block:
    for _ in 0 ..< WarmupIters:
      body
    var totalOps = 0'i64
    let startTime = getMonoTime()
    var elapsed: int64 = 0
    while elapsed < MinDurationNs:
      for _ in 0 ..< 10_000:
        body
      totalOps += 10_000
      elapsed = (getMonoTime() - startTime).inNanoseconds
    let nsOp = float64(elapsed) / float64(totalOps)
    let ops = 1e9 / nsOp
    let tput = if bpo > 0: float64(bpo) * ops / (1024.0 * 1024.0) else: 0.0
    results.add BenchResult(
      name: benchName,
      iterations: totalOps,
      totalNs: elapsed,
      nsPerOp: nsOp,
      opsPerSec: ops,
      bytesPerOp: bpo,
      throughputMBs: tput
    )

proc formatOps(ops: float64): string =
  if ops >= 1e6: fmt"{ops / 1e6:.2f}M"
  elif ops >= 1e3: fmt"{ops / 1e3:.2f}K"
  else: fmt"{ops:.2f}"

proc formatThroughput(mbps: float64): string =
  if mbps >= 1024.0: fmt"{mbps / 1024.0:.2f} GB/s"
  else: fmt"{mbps:.2f} MB/s"

proc report(r: BenchResult) =
  let nameField = r.name & ":"
  if r.bytesPerOp > 0:
    echo fmt"  {nameField:<45s} {formatOps(r.opsPerSec):>10s} ops/sec  ({r.nsPerOp:>8.1f} ns/op)  {formatThroughput(r.throughputMBs):>12s}"
  else:
    echo fmt"  {nameField:<45s} {formatOps(r.opsPerSec):>10s} ops/sec  ({r.nsPerOp:>8.1f} ns/op)"

proc makePayload(size: int, ch: char = 'A'): string =
  result = newString(size)
  for i in 0 ..< size:
    result[i] = ch

proc makeMixedUtf8(size: int): string =
  let pattern = "Hello \xC3\xA9\xC3\xA0\xC3\xBC \xE4\xB8\x96\xE7\x95\x8C \xF0\x9F\x98\x80 world! "
  result = newStringOfCap(size)
  while result.len < size:
    let remaining = size - result.len
    if remaining >= pattern.len:
      result.add(pattern)
    else:
      result.add(pattern[0 ..< remaining])

proc makeAlignedBuffer(size: int, offset: int = 0): seq[byte] {.used.} =
  result = newSeq[byte](size + offset + 16)
  let base = cast[uint](addr result[0])
  let alignOffset = int((8'u - (base and 7'u)) and 7'u) + offset
  result = newSeq[byte](size + alignOffset)

proc main() =
  var results: seq[BenchResult]

  let payload32 = makePayload(32)
  let payload1k = makePayload(1024)
  let payload64k = makePayload(65536)
  let payload64b = makePayload(64)

  echo ""
  echo "WebSocket Benchmarks"
  echo "===================="
  echo fmt"  Platform: macOS ARM64 | Nim {NimVersion}"
  echo fmt"  Min duration: {MinDurationNs div 1_000_000}ms per benchmark"
  echo ""

  echo "--- buildWsFrame (allocating) ---"
  benchmark("buildWsFrame (32B text)", 32):
    let f {.used.} = buildWsFrame(wsText, payload32)
  benchmark("buildWsFrame (1KB binary)", 1024):
    let f {.used.} = buildWsFrame(wsBinary, payload1k)
  benchmark("buildWsFrame (64KB binary)", 65536):
    let f {.used.} = buildWsFrame(wsBinary, payload64k)
  for r in results: report(r)
  results.setLen(0)
  echo ""

  echo "--- buildWsFrameReuse (buffer reuse) ---"
  benchmark("buildWsFrameReuse (32B text)", 32):
    let f {.used.} = buildWsFrameReuse(wsText, payload32)
  benchmark("buildWsFrameReuse (1KB binary)", 1024):
    let f {.used.} = buildWsFrameReuse(wsBinary, payload1k)
  benchmark("buildWsFrameReuse (64KB binary)", 65536):
    let f {.used.} = buildWsFrameReuse(wsBinary, payload64k)
  for r in results: report(r)
  results.setLen(0)
  echo ""

  echo "--- Frame building by opcode ---"
  benchmark("buildWsFrame text opcode", 32):
    let f {.used.} = buildWsFrame(wsText, payload32)
  benchmark("buildWsFrame binary opcode", 32):
    let f {.used.} = buildWsFrame(wsBinary, payload32)
  benchmark("buildWsFrame ping opcode", 0):
    let f {.used.} = buildWsFrame(wsPing, "")
  benchmark("buildWsFrame pong opcode", 0):
    let f {.used.} = buildWsFrame(wsPong, "")
  benchmark("buildWsFrame close opcode", 2):
    let f {.used.} = buildWsFrame(wsClose, "\x03\xe8")
  for r in results: report(r)
  results.setLen(0)
  echo ""

  echo "--- unmaskInPlace (alignment-aware XOR) ---"
  let mask: array[4, byte] = [0xAA'u8, 0xBB, 0xCC, 0xDD]

  block:
    var buf64 = newSeq[byte](64)
    for i in 0 ..< 64: buf64[i] = byte(i)
    var bufCopy64 = buf64
    benchmark("unmaskInPlace (64B aligned)", 64):
      copyMem(addr buf64[0], addr bufCopy64[0], 64)
      unmaskInPlace(buf64, 0, 64, mask[0], mask[1], mask[2], mask[3])
    for r in results: report(r)
    results.setLen(0)

  block:
    var buf1k = newSeq[byte](1024)
    for i in 0 ..< 1024: buf1k[i] = byte(i and 0xFF)
    var bufCopy1k = buf1k
    benchmark("unmaskInPlace (1KB aligned)", 1024):
      copyMem(addr buf1k[0], addr bufCopy1k[0], 1024)
      unmaskInPlace(buf1k, 0, 1024, mask[0], mask[1], mask[2], mask[3])
    for r in results: report(r)
    results.setLen(0)

  block:
    var buf1kU = newSeq[byte](1024 + 3)
    for i in 0 ..< 1024: buf1kU[3 + i] = byte(i and 0xFF)
    var bufCopy1kU = buf1kU
    benchmark("unmaskInPlace (1KB unaligned +3)", 1024):
      copyMem(addr buf1kU[0], addr bufCopy1kU[0], buf1kU.len)
      unmaskInPlace(buf1kU, 3, 1024, mask[0], mask[1], mask[2], mask[3])
    for r in results: report(r)
    results.setLen(0)

  block:
    var buf64k = newSeq[byte](65536)
    for i in 0 ..< 65536: buf64k[i] = byte(i and 0xFF)
    var bufCopy64k = buf64k
    benchmark("unmaskInPlace (64KB aligned)", 65536):
      copyMem(addr buf64k[0], addr bufCopy64k[0], 65536)
      unmaskInPlace(buf64k, 0, 65536, mask[0], mask[1], mask[2], mask[3])
    for r in results: report(r)
    results.setLen(0)

  echo ""

  echo "--- unmaskWebSocketPayload (copy-unmask) ---"
  block:
    var src64 = newSeq[byte](64)
    for i in 0 ..< 64: src64[i] = byte(i) xor mask[i and 3]
    benchmark("unmaskPayload (64B)", 64):
      let s {.used.} = unmaskWebSocketPayload(src64, 0, 64, mask[0], mask[1], mask[2], mask[3])
    for r in results: report(r)
    results.setLen(0)

  block:
    var src1k = newSeq[byte](1024)
    for i in 0 ..< 1024: src1k[i] = byte(i and 0xFF) xor mask[i and 3]
    benchmark("unmaskPayload (1KB)", 1024):
      let s {.used.} = unmaskWebSocketPayload(src1k, 0, 1024, mask[0], mask[1], mask[2], mask[3])
    for r in results: report(r)
    results.setLen(0)

  block:
    var src64k = newSeq[byte](65536)
    for i in 0 ..< 65536: src64k[i] = byte(i and 0xFF) xor mask[i and 3]
    benchmark("unmaskPayload (64KB)", 65536):
      let s {.used.} = unmaskWebSocketPayload(src64k, 0, 65536, mask[0], mask[1], mask[2], mask[3])
    for r in results: report(r)
    results.setLen(0)

  echo ""

  echo "--- decodeWsFrame (full decode pipeline) ---"
  let frameMask: array[4, byte] = [0x37'u8, 0xFA, 0x21, 0x3D]

  block:
    let rawFrame64 = buildMaskedFrame(wsText, payload64b, frameMask)
    var frameData64 = rawFrame64
    var opcode: int
    var payload: string
    var consumed: int
    var fin: bool
    var compressed: bool
    benchmark("decodeWsFrame (64B text masked)", 64):
      copyMem(addr frameData64[0], unsafeAddr rawFrame64[0], rawFrame64.len)
      let r {.used.} = decodeWebSocketFrame(frameData64, 0, opcode, payload, consumed, fin, compressed, false)
    for r in results: report(r)
    results.setLen(0)

  block:
    let rawFrame1k = buildMaskedFrame(wsText, payload1k, frameMask)
    var frameData1k = rawFrame1k
    var opcode: int
    var payload: string
    var consumed: int
    var fin: bool
    var compressed: bool
    benchmark("decodeWsFrame (1KB text masked)", 1024):
      copyMem(addr frameData1k[0], unsafeAddr rawFrame1k[0], rawFrame1k.len)
      let r {.used.} = decodeWebSocketFrame(frameData1k, 0, opcode, payload, consumed, fin, compressed, false)
    for r in results: report(r)
    results.setLen(0)

  block:
    let rawFrame64k = buildMaskedFrame(wsBinary, payload64k, frameMask)
    var frameData64k = rawFrame64k
    var opcode: int
    var payload: string
    var consumed: int
    var fin: bool
    var compressed: bool
    benchmark("decodeWsFrame (64KB binary masked)", 65536):
      copyMem(addr frameData64k[0], unsafeAddr rawFrame64k[0], rawFrame64k.len)
      let r {.used.} = decodeWebSocketFrame(frameData64k, 0, opcode, payload, consumed, fin, compressed, false)
    for r in results: report(r)
    results.setLen(0)

  echo ""

  echo "--- wsClosePayload ---"
  benchmark("wsClosePayload (code only)", 0):
    let p {.used.} = wsClosePayload(1000)
  benchmark("wsClosePayload (code + reason)", 0):
    let p {.used.} = wsClosePayload(1000, "normal closure")
  benchmark("wsClosePayload (code + max reason)", 0):
    let p {.used.} = wsClosePayload(1001, makePayload(123, 'x'))
  for r in results: report(r)
  results.setLen(0)
  echo ""

  echo "--- isAsciiOnly (fast ASCII detection) ---"
  let ascii64 = makePayload(64, 'Z')
  let ascii1k = makePayload(1024, 'Z')
  let ascii64k = makePayload(65536, 'Z')
  var nonAscii1k = makePayload(1024, 'Z')
  nonAscii1k[512] = '\x80'
  benchmark("isAsciiOnly (64B all-ASCII)", 64):
    let v {.used.} = isAsciiOnly(ascii64)
  benchmark("isAsciiOnly (1KB all-ASCII)", 1024):
    let v {.used.} = isAsciiOnly(ascii1k)
  benchmark("isAsciiOnly (64KB all-ASCII)", 65536):
    let v {.used.} = isAsciiOnly(ascii64k)
  benchmark("isAsciiOnly (1KB non-ASCII mid)", 1024):
    let v {.used.} = isAsciiOnly(nonAscii1k)
  for r in results: report(r)
  results.setLen(0)
  echo ""

  echo "--- UTF-8 validation (state machine) ---"
  let asciiBytes1k = cast[seq[byte]](makePayload(1024, 'A'))
  let mixedUtf8_1k = makeMixedUtf8(1024)
  let mixedBytes1k = cast[seq[byte]](mixedUtf8_1k)
  let asciiBytes64k = cast[seq[byte]](makePayload(65536, 'A'))
  let mixedUtf8_64k = makeMixedUtf8(65536)
  let mixedBytes64k = cast[seq[byte]](mixedUtf8_64k)
  benchmark("validateUtf8 (1KB ASCII)", 1024):
    let v {.used.} = validateUtf8Bytes(asciiBytes1k, 0, asciiBytes1k.len)
  benchmark("validateUtf8 (1KB mixed UTF-8)", 1024):
    let v {.used.} = validateUtf8Bytes(mixedBytes1k, 0, mixedBytes1k.len)
  benchmark("validateUtf8 (64KB ASCII)", 65536):
    let v {.used.} = validateUtf8Bytes(asciiBytes64k, 0, asciiBytes64k.len)
  benchmark("validateUtf8 (64KB mixed UTF-8)", 65536):
    let v {.used.} = validateUtf8Bytes(mixedBytes64k, 0, mixedBytes64k.len)
  for r in results: report(r)
  results.setLen(0)
  echo ""

  echo "--- buildWsFrame vs buildWsFrameReuse parity ---"
  benchmark("buildWsFrame (32B) [alloc]", 32):
    let f {.used.} = buildWsFrame(wsText, payload32)
  benchmark("buildWsFrameReuse (32B) [reuse]", 32):
    let f {.used.} = buildWsFrameReuse(wsText, payload32)
  benchmark("buildWsFrame (1KB) [alloc]", 1024):
    let f {.used.} = buildWsFrame(wsBinary, payload1k)
  benchmark("buildWsFrameReuse (1KB) [reuse]", 1024):
    let f {.used.} = buildWsFrameReuse(wsBinary, payload1k)
  for r in results: report(r)
  results.setLen(0)
  echo ""

  echo "--- moveMem queue compaction simulation ---"
  block:
    var queue = newSeq[byte](4096)
    for i in 0 ..< queue.len: queue[i] = byte(i and 0xFF)
    benchmark("moveMem compact (1KB from 4KB queue)", 1024):
      moveMem(addr queue[0], addr queue[1024], 1024)
    for r in results: report(r)
    results.setLen(0)

  block:
    var queue = newSeq[byte](65536)
    for i in 0 ..< queue.len: queue[i] = byte(i and 0xFF)
    benchmark("moveMem compact (32KB from 64KB queue)", 32768):
      moveMem(addr queue[0], addr queue[32768], 32768)
    for r in results: report(r)
    results.setLen(0)

  echo ""
  echo "===================="
  echo "  Benchmarks complete."
  echo ""

main()
