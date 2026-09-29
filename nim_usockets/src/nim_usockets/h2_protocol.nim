import std/options
export options

type
  H2FrameType* = enum
    ftData = 0x0
    ftHeaders = 0x1
    ftPriority = 0x2
    ftRstStream = 0x3
    ftSettings = 0x4
    ftPushPromise = 0x5
    ftPing = 0x6
    ftGoaway = 0x7
    ftWindowUpdate = 0x8
    ftContinuation = 0x9

  H2ErrorCode* = enum
    ecNoError = 0x0
    ecProtocolError = 0x1
    ecInternalError = 0x2
    ecFlowControlError = 0x3
    ecSettingsTimeout = 0x4
    ecStreamClosed = 0x5
    ecFrameSizeError = 0x6
    ecRefusedStream = 0x7
    ecCancel = 0x8
    ecCompressionError = 0x9
    ecConnectError = 0xa
    ecEnhanceYourCalm = 0xb
    ecInadequateSecurity = 0xc
    ecHttp11Required = 0xd

  H2SettingsId* = enum
    siHeaderTableSize = 0x1
    siEnablePush = 0x2
    siMaxConcurrentStreams = 0x3
    siInitialWindowSize = 0x4
    siMaxFrameSize = 0x5
    siMaxHeaderListSize = 0x6

  H2StreamState* = enum
    ssIdle
    ssReservedLocal
    ssReservedRemote
    ssOpen
    ssHalfClosedLocal
    ssHalfClosedRemote
    ssClosed

  H2Frame* = object
    length*: uint32
    frameType*: H2FrameType
    flags*: uint8
    streamId*: uint32
    payload*: string

  H2Settings* = object
    headerTableSize*: uint32
    enablePush*: bool
    maxConcurrentStreams*: uint32
    initialWindowSize*: uint32
    maxFrameSize*: uint32
    maxHeaderListSize*: uint32

const
  H2FrameHeaderSize* = 9
  H2ConnectionPreface* = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  DefaultWindowSize*: int32 = 65535
  H2MaxPriorityDepth* = 32

  FlagEndStream*: uint8 = 0x1
  FlagAck*: uint8 = 0x1
  FlagEndHeaders*: uint8 = 0x4
  FlagPadded*: uint8 = 0x8
  FlagPriority*: uint8 = 0x20

  DefaultH2Settings* = H2Settings(
    headerTableSize: 4096,
    enablePush: false,
    maxConcurrentStreams: 100,
    initialWindowSize: 65535,
    maxFrameSize: 16384,
    maxHeaderListSize: high(uint32),
  )

## Returns the HTTP/2 default settings values per the RFC defaults.
proc defaultH2Settings*(): H2Settings {.inline.} = DefaultH2Settings

## Appends a 24-bit big-endian unsigned value to buf.
proc writeU24BE*(buf: var string, val: uint32) {.inline.} =
  let pos = buf.len
  buf.setLen(pos + 3)
  buf[pos] = char((val shr 16) and 0xFF)
  buf[pos + 1] = char((val shr 8) and 0xFF)
  buf[pos + 2] = char(val and 0xFF)

## Appends a 32-bit big-endian unsigned value to buf.
proc writeU32BE*(buf: var string, val: uint32) {.inline.} =
  let pos = buf.len
  buf.setLen(pos + 4)
  buf[pos] = char((val shr 24) and 0xFF)
  buf[pos + 1] = char((val shr 16) and 0xFF)
  buf[pos + 2] = char((val shr 8) and 0xFF)
  buf[pos + 3] = char(val and 0xFF)

## Appends a 16-bit big-endian unsigned value to buf.
proc writeU16BE*(buf: var string, val: uint16) {.inline.} =
  let pos = buf.len
  buf.setLen(pos + 2)
  buf[pos] = char((val shr 8) and 0xFF)
  buf[pos + 1] = char(val and 0xFF)

## Reads a 24-bit big-endian unsigned value from data at pos.
proc readU24BE*(data: openArray[byte], pos: int): uint32 {.inline.} =
  (uint32(data[pos]) shl 16) or (uint32(data[pos + 1]) shl 8) or uint32(data[pos + 2])

## Reads a 32-bit big-endian unsigned value from data at pos.
proc readU32BE*(data: openArray[byte], pos: int): uint32 {.inline.} =
  (uint32(data[pos]) shl 24) or (uint32(data[pos + 1]) shl 16) or
  (uint32(data[pos + 2]) shl 8) or uint32(data[pos + 3])

## Reads a 16-bit big-endian unsigned value from data at pos.
proc readU16BE*(data: openArray[byte], pos: int): uint16 {.inline.} =
  (uint16(data[pos]) shl 8) or uint16(data[pos + 1])

## Appends a 9-byte HTTP/2 frame header with length, type, flags and masked stream id.
proc serializeFrameHeader*(buf: var string, length: uint32, frameType: H2FrameType, flags: uint8, streamId: uint32) {.inline.} =
  let pos = buf.len
  buf.setLen(pos + 9)
  let maskedId = streamId and 0x7FFFFFFF'u32
  buf[pos] = char((length shr 16) and 0xFF)
  buf[pos + 1] = char((length shr 8) and 0xFF)
  buf[pos + 2] = char(length and 0xFF)
  buf[pos + 3] = char(uint8(ord(frameType)))
  buf[pos + 4] = char(flags)
  buf[pos + 5] = char((maskedId shr 24) and 0xFF)
  buf[pos + 6] = char((maskedId shr 16) and 0xFF)
  buf[pos + 7] = char((maskedId shr 8) and 0xFF)
  buf[pos + 8] = char(maskedId and 0xFF)

## Parses one HTTP/2 frame from data at pos, returning none when the buffer is incomplete.
proc parseH2Frame*(data: openArray[byte], pos: var int): Option[H2Frame] =
  let available = data.len - pos
  if available < H2FrameHeaderSize:
    return none(H2Frame)

  let length = readU24BE(data, pos)
  let frameTypeByte = data[pos + 3]
  let flags = data[pos + 4]
  let streamId = readU32BE(data, pos + 5) and 0x7FFFFFFF'u32

  if length > 16777215'u32:
    return none(H2Frame)

  let totalSize = H2FrameHeaderSize + int(length)
  if available < totalSize:
    return none(H2Frame)

  var ft: H2FrameType
  if frameTypeByte <= 9:
    ft = H2FrameType(frameTypeByte)
  else:
    pos += totalSize
    return none(H2Frame)

  var payload = ""
  if length > 0:
    payload = newString(int(length))
    copyMem(addr payload[0], unsafeAddr data[pos + H2FrameHeaderSize], int(length))

  pos += totalSize
  result = some(H2Frame(
    length: length,
    frameType: ft,
    flags: flags,
    streamId: streamId,
    payload: payload,
  ))

## Serializes a parsed HTTP/2 frame, header and payload, into buf.
proc serializeH2Frame*(frame: H2Frame, buf: var string) =
  let payloadLen = uint32(frame.payload.len)
  serializeFrameHeader(buf, payloadLen, frame.frameType, frame.flags, frame.streamId)
  if frame.payload.len > 0:
    buf.add frame.payload

## Serializes a SETTINGS frame containing all six settings values into buf.
proc serializeSettings*(settings: H2Settings, buf: var string) =
  const payloadLen = 36'u32
  serializeFrameHeader(buf, payloadLen, ftSettings, 0, 0)

  writeU16BE(buf, uint16(ord(siHeaderTableSize)))
  writeU32BE(buf, settings.headerTableSize)

  writeU16BE(buf, uint16(ord(siEnablePush)))
  writeU32BE(buf, if settings.enablePush: 1'u32 else: 0'u32)

  writeU16BE(buf, uint16(ord(siMaxConcurrentStreams)))
  writeU32BE(buf, settings.maxConcurrentStreams)

  writeU16BE(buf, uint16(ord(siInitialWindowSize)))
  writeU32BE(buf, settings.initialWindowSize)

  writeU16BE(buf, uint16(ord(siMaxFrameSize)))
  writeU32BE(buf, settings.maxFrameSize)

  writeU16BE(buf, uint16(ord(siMaxHeaderListSize)))
  writeU32BE(buf, settings.maxHeaderListSize)

## Appends an empty SETTINGS ACK frame to buf.
proc serializeSettingsAck*(buf: var string) {.inline.} =
  let pos = buf.len
  buf.setLen(pos + 9)
  buf[pos] = '\0'
  buf[pos + 1] = '\0'
  buf[pos + 2] = '\0'
  buf[pos + 3] = char(uint8(ord(ftSettings)))
  buf[pos + 4] = char(FlagAck)
  buf[pos + 5] = '\0'
  buf[pos + 6] = '\0'
  buf[pos + 7] = '\0'
  buf[pos + 8] = '\0'

## Serializes a PING frame with 8 payload bytes, optionally with the ACK flag set.
proc serializePing*(data: array[8, byte], ack: bool, buf: var string) =
  let flags = if ack: FlagAck else: 0'u8
  serializeFrameHeader(buf, 8, ftPing, flags, 0)
  let pos = buf.len
  buf.setLen(pos + 8)
  copyMem(addr buf[pos], unsafeAddr data[0], 8)

## Serializes a GOAWAY frame with the last stream id and error code.
proc serializeGoaway*(lastStreamId: uint32, errorCode: uint32, buf: var string) =
  serializeFrameHeader(buf, 8, ftGoaway, 0, 0)
  writeU32BE(buf, lastStreamId and 0x7FFFFFFF'u32)
  writeU32BE(buf, errorCode)

## Serializes a WINDOW_UPDATE frame with the window size increment.
proc serializeWindowUpdate*(streamId: uint32, increment: uint32, buf: var string) =
  serializeFrameHeader(buf, 4, ftWindowUpdate, 0, streamId)
  writeU32BE(buf, increment and 0x7FFFFFFF'u32)

## Serializes an RST_STREAM frame with the stream error code.
proc serializeRstStream*(streamId: uint32, errorCode: uint32, buf: var string) =
  serializeFrameHeader(buf, 4, ftRstStream, 0, streamId)
  writeU32BE(buf, errorCode)

## Serializes a HEADERS frame with a header block and optional END_STREAM and END_HEADERS flags.
proc serializeHeaders*(streamId: uint32, headerBlock: string, endStream: bool, endHeaders: bool, buf: var string) =
  var flags: uint8 = 0
  if endStream: flags = flags or FlagEndStream
  if endHeaders: flags = flags or FlagEndHeaders
  serializeFrameHeader(buf, uint32(headerBlock.len), ftHeaders, flags, streamId)
  if headerBlock.len > 0:
    let pos = buf.len
    buf.setLen(pos + headerBlock.len)
    copyMem(addr buf[pos], unsafeAddr headerBlock[0], headerBlock.len)

## Serializes a DATA frame with payload and optional END_STREAM flag.
proc serializeData*(streamId: uint32, data: string, endStream: bool, buf: var string) =
  var flags: uint8 = 0
  if endStream: flags = flags or FlagEndStream
  serializeFrameHeader(buf, uint32(data.len), ftData, flags, streamId)
  if data.len > 0:
    let pos = buf.len
    buf.setLen(pos + data.len)
    copyMem(addr buf[pos], unsafeAddr data[0], data.len)

## Serializes a DATA frame from a char view without allocating a payload copy.
proc serializeDataView*(streamId: uint32, data: openArray[char], endStream: bool, buf: var string) {.inline.} =
  var flags: uint8 = 0
  if endStream: flags = flags or FlagEndStream
  serializeFrameHeader(buf, uint32(data.len), ftData, flags, streamId)
  if data.len > 0:
    let pos = buf.len
    buf.setLen(pos + data.len)
    copyMem(addr buf[pos], unsafeAddr data[0], data.len)

proc applySettingsInner(target: var H2Settings, data: ptr UncheckedArray[byte], payloadLen: int) {.inline.} =
  var pos = 0
  while pos + 6 <= payloadLen:
    let id = (uint16(data[pos]) shl 8) or uint16(data[pos + 1])
    let val = (uint32(data[pos + 2]) shl 24) or (uint32(data[pos + 3]) shl 16) or
              (uint32(data[pos + 4]) shl 8) or uint32(data[pos + 5])
    pos += 6
    case id
    of uint16(ord(siHeaderTableSize)):
      target.headerTableSize = val
    of uint16(ord(siEnablePush)):
      if val > 1:
        raise newException(ValueError, "SETTINGS_ENABLE_PUSH must be 0 or 1")
      target.enablePush = val != 0
    of uint16(ord(siMaxConcurrentStreams)):
      target.maxConcurrentStreams = val
    of uint16(ord(siInitialWindowSize)):
      if val > 2147483647'u32:
        raise newException(ValueError, "SETTINGS_INITIAL_WINDOW_SIZE exceeds 2^31-1")
      target.initialWindowSize = val
    of uint16(ord(siMaxFrameSize)):
      if val < 16384'u32 or val > 16777215'u32:
        raise newException(ValueError, "SETTINGS_MAX_FRAME_SIZE out of range")
      target.maxFrameSize = val
    of uint16(ord(siMaxHeaderListSize)):
      target.maxHeaderListSize = val
    else:
      discard

## Parses a SETTINGS payload into H2Settings starting from the defaults.
proc parseSettings*(payload: string): H2Settings =
  result = DefaultH2Settings
  if payload.len == 0 or payload.len mod 6 != 0:
    return
  applySettingsInner(result, cast[ptr UncheckedArray[byte]](unsafeAddr payload[0]), payload.len)

## Applies a SETTINGS payload on top of the current H2Settings values.
proc applySettings*(current: var H2Settings, payload: string) =
  if payload.len == 0 or payload.len mod 6 != 0:
    return
  applySettingsInner(current, cast[ptr UncheckedArray[byte]](unsafeAddr payload[0]), payload.len)

## Returns whether the given flag bit is set on the frame.
proc hasFlag*(frame: H2Frame, flag: uint8): bool {.inline.} =
  (frame.flags and flag) != 0

## Extracts the raw header block from a HEADERS frame, handling padding and priority fields.
proc extractHeaderBlock*(frame: H2Frame): string {.inline.} =
  if (frame.flags and FlagPadded) != 0:
    if frame.payload.len == 0:
      raise newException(ValueError, "invalid HEADERS padding")
    let padLen = int(frame.payload[0])
    var offset = 1
    if (frame.flags and FlagPriority) != 0:
      offset += 5
    if padLen >= frame.payload.len or offset + padLen > frame.payload.len:
      raise newException(ValueError, "invalid HEADERS padding")
    return frame.payload[offset ..< frame.payload.len - padLen]
  elif (frame.flags and FlagPriority) != 0:
    if frame.payload.len < 5:
      raise newException(ValueError, "HEADERS PRIORITY too short")
    return frame.payload[5 ..< frame.payload.len]
  else:
    return frame.payload

## Removes the padding prefix and suffix from a padded DATA frame payload.
proc stripPadding*(frame: H2Frame): string {.inline.} =
  if (frame.flags and FlagPadded) != 0:
    if frame.payload.len == 0:
      raise newException(ValueError, "invalid DATA padding")
    let padLen = int(frame.payload[0])
    if 1 + padLen > frame.payload.len:
      raise newException(ValueError, "invalid DATA padding")
    return frame.payload[1 ..< frame.payload.len - padLen]
  return frame.payload

## Validates the frame length against the per-type length rules and the max frame size.
proc validateFrameLength*(frame: H2Frame, maxFrameSize: uint32 = 16384): bool =
  case frame.frameType
  of ftSettings:
    if (frame.flags and FlagAck) != 0:
      return frame.length == 0
    return frame.length mod 6 == 0
  of ftPing:
    return frame.length == 8
  of ftRstStream:
    return frame.length == 4
  of ftPriority:
    return frame.length == 5
  of ftWindowUpdate:
    return frame.length == 4
  of ftGoaway:
    return frame.length >= 8
  of ftData, ftHeaders, ftPushPromise:
    return frame.length <= maxFrameSize
  of ftContinuation:
    return frame.length <= maxFrameSize

## Serializes a trailers HEADERS frame with END_STREAM and END_HEADERS set.
proc serializeTrailers*(streamId: uint32, headerBlock: string, buf: var string) =
  serializeFrameHeader(buf, uint32(headerBlock.len), ftHeaders, FlagEndStream or FlagEndHeaders, streamId)
  if headerBlock.len > 0:
    let pos = buf.len
    buf.setLen(pos + headerBlock.len)
    copyMem(addr buf[pos], unsafeAddr headerBlock[0], headerBlock.len)

## Serializes a PUSH_PROMISE frame with the promised stream id and header block.
proc serializePushPromise*(streamId: uint32, promisedStreamId: uint32, headerBlock: string, buf: var string) =
  let payloadLen = uint32(4 + headerBlock.len)
  serializeFrameHeader(buf, payloadLen, ftPushPromise, FlagEndHeaders, streamId)
  writeU32BE(buf, promisedStreamId and 0x7FFFFFFF'u32)
  if headerBlock.len > 0:
    let pos = buf.len
    buf.setLen(pos + headerBlock.len)
    copyMem(addr buf[pos], unsafeAddr headerBlock[0], headerBlock.len)

## Reads the non-zero window size increment from a WINDOW_UPDATE payload.
proc parseWindowUpdate*(payload: string): uint32 {.inline.} =
  if payload.len < 4:
    raise newException(ValueError, "WINDOW_UPDATE payload too short")
  let data = cast[ptr UncheckedArray[byte]](unsafeAddr payload[0])
  result = readU32BE(data.toOpenArray(0, 3), 0) and 0x7FFFFFFF'u32
  if result == 0:
    raise newException(ValueError, "WINDOW_UPDATE increment must be non-zero")
