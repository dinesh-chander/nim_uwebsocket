import std/[tables, options]
import types
import validation
from ../../../nim_usockets/src/nim_usockets/hpack import
  hpackEncode, hpackDecode, updateEncoderMaxSize
from ../../../nim_usockets/src/nim_usockets/h2_protocol as h2p import
  parseH2Frame, serializeHeaders, serializeData, serializeSettings,
  serializeSettingsAck, serializePing, serializeGoaway, serializeWindowUpdate,
  serializeRstStream, hasFlag, readU32BE, extractHeaderBlock,
  stripPadding, validateFrameLength, applySettings, serializeFrameHeader,
  ftContinuation, FlagEndHeaders

type
  H2ConnectionState* = enum
    h2csPreface
    h2csActive
    h2csGoaway
    h2csClosed

  H2HeaderApplyStatus = enum
    hasOk
    hasCompressionError
    hasProtocolError

  H2ClientConnection* = object
    state*: H2ConnectionState
    localConnectionError*: bool
    localSettings*: H2Settings
    remoteSettings*: H2Settings
    localWindow*: int32
    remoteWindow*: int32
    nextStreamId*: uint32
    streams*: Table[uint32, H2Stream]
    encoder*: HpackEncoder
    decoder*: HpackDecoder
    recvBuf*: string
    sendBuf*: string
    lastStreamId*: uint32
    continuationStreamId*: uint32
    continuationIsPushPromise: bool
    headerBlockBuf*: string

## Creates a new client-side HTTP/2 connection in the preface state with default settings.
proc initH2ClientConnection*(): H2ClientConnection {.inline.} =
  result.state = h2csPreface
  result.localSettings = DefaultH2Settings
  result.remoteSettings = DefaultH2Settings
  result.localWindow = DefaultWindowSize
  result.remoteWindow = DefaultWindowSize
  result.nextStreamId = 1
  result.streams = initTable[uint32, H2Stream]()
  result.encoder = initHpackEncoder()
  result.decoder = initHpackDecoder()

## Appends the client connection preface and the initial SETTINGS frame to the send buffer.
proc writeConnectionPreface*(conn: var H2ClientConnection, buf: var string) =
  buf.add H2ConnectionPreface
  var settingsBuf = ""
  let s = h2p.H2Settings(
    headerTableSize: conn.localSettings.headerTableSize,
    enablePush: conn.localSettings.enablePush,
    maxConcurrentStreams: conn.localSettings.maxConcurrentStreams,
    initialWindowSize: conn.localSettings.initialWindowSize,
    maxFrameSize: conn.localSettings.maxFrameSize,
    maxHeaderListSize: conn.localSettings.maxHeaderListSize,
  )
  serializeSettings(s, settingsBuf)
  buf.add settingsBuf

## Returns true if a new stream may be opened under the remote concurrency limit.
proc canAllocateStream*(conn: H2ClientConnection): bool {.inline.} =
  conn.state != h2csGoaway and conn.state != h2csClosed and
    uint32(conn.streams.len) < conn.remoteSettings.maxConcurrentStreams

## Allocates the next odd client stream id and registers the stream, returning 0 if allocation is not possible.
proc allocateStream*(conn: var H2ClientConnection): uint32 {.inline.} =
  if not conn.canAllocateStream():
    return 0
  if conn.nextStreamId > 2147483645'u32:
    conn.state = h2csGoaway
    return 0
  result = conn.nextStreamId
  conn.nextStreamId += 2
  conn.streams[result] = H2Stream(
    id: result,
    state: ssOpen,
    sendWindow: int32(conn.remoteSettings.initialWindowSize),
    recvWindow: DefaultWindowSize,
  )

## HPACK-encodes and emits a HEADERS frame for the stream, splitting large blocks into CONTINUATION frames.
proc sendHeaders*(conn: var H2ClientConnection, streamId: uint32, headers: openArray[(string, string)], endStream: bool, buf: var string) =
  var headerBlock = newStringOfCap(128)
  hpackEncode(conn.encoder, headers, headerBlock)
  let maxPayload = max(1, int(conn.remoteSettings.maxFrameSize))
  if headerBlock.len <= maxPayload:
    serializeHeaders(streamId, headerBlock, endStream, endHeaders = true, buf)
    return

  var offset = 0
  let firstLen = min(headerBlock.len, maxPayload)
  serializeHeaders(
    streamId,
    headerBlock[offset ..< offset + firstLen],
    endStream,
    endHeaders = firstLen == headerBlock.len,
    buf
  )
  offset += firstLen
  while offset < headerBlock.len:
    let chunkLen = min(headerBlock.len - offset, maxPayload)
    let flags = if offset + chunkLen == headerBlock.len: FlagEndHeaders else: 0'u8
    serializeFrameHeader(buf, uint32(chunkLen), ftContinuation, flags, streamId)
    let pos = buf.len
    buf.setLen(pos + chunkLen)
    copyMem(addr buf[pos], unsafeAddr headerBlock[offset], chunkLen)
    offset += chunkLen

## Sends DATA frames honoring the connection and stream flow-control windows, buffering the unsent remainder.
proc sendData*(conn: var H2ClientConnection, streamId: uint32, data: string, endStream: bool, buf: var string) =
  let maxPayload = int(conn.remoteSettings.maxFrameSize)
  var offset = 0
  while offset < data.len:
    let streamWindow = if streamId in conn.streams: conn.streams[streamId].sendWindow else: int32(maxPayload)
    let allowedByFlow = min(int(conn.remoteWindow), int(streamWindow))
    let chunkMax = min(maxPayload, max(allowedByFlow, 0))
    let chunkLen = min(data.len - offset, chunkMax)
    if chunkLen <= 0:
      break
    let isLast = offset + chunkLen == data.len
    serializeData(streamId, data[offset ..< offset + chunkLen], endStream and isLast, buf)
    conn.remoteWindow -= int32(chunkLen)
    if streamId in conn.streams:
      conn.streams[streamId].sendWindow -= int32(chunkLen)
    offset += chunkLen
  if streamId in conn.streams:
    if offset < data.len:
      if conn.streams[streamId].dataBuf.len == 0:
        conn.streams[streamId].dataBuf = data[offset ..< data.len]
      else:
        conn.streams[streamId].dataBuf.add data[offset ..< data.len]
      conn.streams[streamId].dataEndStreamPending = endStream
    elif endStream:
      conn.streams[streamId].dataEndStreamPending = false
      conn.streams[streamId].state = ssHalfClosedLocal

## Emits buffered DATA for a stream as flow-control windows permit, ending the stream when all pending data is sent.
proc flushPendingData*(conn: var H2ClientConnection, streamId: uint32, buf: var string) =
  if streamId notin conn.streams or conn.streams[streamId].dataBuf.len == 0:
    return
  let maxPayload = int(conn.remoteSettings.maxFrameSize)
  while conn.streams[streamId].dataBuf.len > 0:
    let allowedByFlow = min(int(conn.remoteWindow), int(conn.streams[streamId].sendWindow))
    let chunkMax = min(maxPayload, max(allowedByFlow, 0))
    let chunkLen = min(conn.streams[streamId].dataBuf.len, chunkMax)
    if chunkLen <= 0:
      return
    let isLast = chunkLen == conn.streams[streamId].dataBuf.len
    let endNow = conn.streams[streamId].dataEndStreamPending and isLast
    serializeData(streamId, conn.streams[streamId].dataBuf[0 ..< chunkLen], endNow, buf)
    conn.remoteWindow -= int32(chunkLen)
    conn.streams[streamId].sendWindow -= int32(chunkLen)
    if isLast:
      conn.streams[streamId].dataBuf.setLen(0)
      if endNow:
        conn.streams[streamId].dataEndStreamPending = false
        conn.streams[streamId].state = ssHalfClosedLocal
    else:
      conn.streams[streamId].dataBuf = conn.streams[streamId].dataBuf[chunkLen ..< conn.streams[streamId].dataBuf.len]

## Emits a WINDOW_UPDATE frame for the connection or a stream, skipping increments that would overflow the window.
proc sendWindowUpdate*(conn: var H2ClientConnection, streamId: uint32, increment: uint32, buf: var string) =
  if increment == 0 or increment > 2147483647'u32:
    return
  if streamId == 0:
    if not isValidH2WindowSize(int64(conn.localWindow) + int64(increment)):
      return
    serializeWindowUpdate(streamId, increment, buf)
    conn.localWindow += int32(increment)
  elif streamId in conn.streams:
    if not isValidH2WindowSize(int64(conn.streams[streamId].recvWindow) + int64(increment)):
      return
    serializeWindowUpdate(streamId, increment, buf)
    conn.streams[streamId].recvWindow += int32(increment)
  else:
    serializeWindowUpdate(streamId, increment, buf)

## Moves the connection to the GOAWAY state and emits a GOAWAY frame with the given error code.
proc sendGoaway*(conn: var H2ClientConnection, errorCode: uint32, buf: var string) =
  conn.state = h2csGoaway
  serializeGoaway(conn.lastStreamId, errorCode, buf)

## Emits a RST_STREAM frame for the stream and closes it locally.
proc sendRstStream*(conn: var H2ClientConnection, streamId: uint32, errorCode: uint32, buf: var string) =
  if streamId == 0:
    return
  serializeRstStream(streamId, errorCode, buf)
  if streamId in conn.streams:
    conn.streams[streamId].state = ssClosed

proc isH2ResponseForbiddenHeader(name: string): bool {.inline.} =
  name == "connection" or name == "keep-alive" or name == "proxy-connection" or
    name == "transfer-encoding" or name == "upgrade"

proc isH2TrailerForbiddenHeader(name: string): bool {.inline.} =
  name == "content-length" or isH2ResponseForbiddenHeader(name)

proc isLowercaseAscii(s: string): bool {.inline.} =
  for c in s:
    if c >= 'A' and c <= 'Z':
      return false
  true

proc validStatusValue(value: string): bool {.inline.} =
  if value.len != 3:
    return false
  var code = 0
  for c in value:
    if c < '0' or c > '9':
      return false
    code = code * 10 + (ord(c) - ord('0'))
  isValidStatusCode(code)

proc parseH2ContentLength(value: string, outVal: var int): bool {.inline.} =
  if value.len == 0:
    return false
  var parsed = 0
  for c in value:
    if c < '0' or c > '9':
      return false
    let digit = ord(c) - ord('0')
    if parsed > (MaxContentLengthVal - digit) div 10:
      return false
    parsed = parsed * 10 + digit
  if not isValidContentLength(parsed):
    return false
  outVal = parsed
  true

proc h2NoResponseBodyExpected(stream: H2Stream): bool {.inline.} =
  stream.request.`method` == hmHead or
    (stream.responseStatus >= 100 and stream.responseStatus < 200) or
    stream.responseStatus == 204 or stream.responseStatus == 304

proc h2ExpectedContentLength(stream: H2Stream): int {.inline.} =
  result = -1
  for header in stream.responseHeaders:
    if header.name == "content-length":
      var parsed = 0
      if parseH2ContentLength(header.value, parsed):
        return parsed
      return -2

proc applyDecodedHeaders(conn: var H2ClientConnection, sid: uint32, headerBlock: string, endStream: bool, completed: var seq[(uint32, H2Stream)]): H2HeaderApplyStatus =
  var headers: seq[(string, string)]
  try:
    headers = hpackDecode(conn.decoder, cast[seq[byte]](headerBlock))
  except CatchableError:
    return hasCompressionError
  let trailerBlock = sid in conn.streams and conn.streams[sid].responseStatus >= 200
  if trailerBlock and not endStream:
    return hasProtocolError
  var pastPseudo = trailerBlock
  var sawStatus = trailerBlock
  var statusCode = 0
  var contentLengthSeen = false
  var contentLengthValue = -1
  var decodedHeaders: seq[HttpHeader] = @[]
  for (name, value) in headers:
    if name.len == 0 or not isLowercaseAscii(name) or not isValidHeaderValue(value):
      return hasProtocolError
    if name.len > 0 and name[0] == ':':
      if trailerBlock:
        return hasProtocolError
      if pastPseudo:
        return hasProtocolError
      if name == ":status":
        if sawStatus or not validStatusValue(value):
          return hasProtocolError
        sawStatus = true
        statusCode =
          (ord(value[0]) - ord('0')) * 100 +
          (ord(value[1]) - ord('0')) * 10 +
          (ord(value[2]) - ord('0'))
      else:
        return hasProtocolError
    else:
      if not isValidHeaderName(name):
        return hasProtocolError
      pastPseudo = true
      if (trailerBlock and isH2TrailerForbiddenHeader(name)) or
         ((not trailerBlock) and isH2ResponseForbiddenHeader(name)):
        return hasProtocolError
      if not trailerBlock and name == "content-length":
        if contentLengthSeen:
          return hasProtocolError
        var parsedLength = 0
        if not parseH2ContentLength(value, parsedLength):
          return hasProtocolError
        contentLengthSeen = true
        contentLengthValue = parsedLength
      decodedHeaders.add HttpHeader(name: name, value: value)
  if not sawStatus:
    return hasProtocolError
  if statusCode > 0 and statusCode < 200:
    if endStream:
      return hasProtocolError
    return hasOk
  if statusCode > 0:
    conn.streams[sid].responseStatus = statusCode
  if contentLengthSeen and
     ((statusCode >= 100 and statusCode < 200) or statusCode == 204 or statusCode == 304) and
     contentLengthValue > 0:
    return hasProtocolError
  for header in decodedHeaders:
    conn.streams[sid].responseHeaders.add header
  if endStream:
    let expectedLength = conn.streams[sid].h2ExpectedContentLength()
    if expectedLength == -2:
      return hasProtocolError
    if expectedLength >= 0 and
       not conn.streams[sid].h2NoResponseBodyExpected() and
       conn.streams[sid].responseBody.len != expectedLength:
      return hasProtocolError
    conn.streams[sid].state = ssClosed
    completed.add((sid, conn.streams[sid]))
  hasOk

const MaxH2ResponseBodySize = 256 * 1024 * 1024

proc h2ConnectionError(conn: var H2ClientConnection, code: uint32, responseBuf: var string) {.inline.} =
  conn.state = h2csGoaway
  conn.localConnectionError = true
  conn.continuationStreamId = 0
  conn.continuationIsPushPromise = false
  conn.headerBlockBuf = ""
  serializeGoaway(conn.lastStreamId, code, responseBuf)

proc extractPushPromiseHeaderBlock(frame: h2p.H2Frame): tuple[promisedStreamId: uint32, headerBlock: string] =
  var offset = 0
  var padLen = 0
  if hasFlag(frame, FlagPadded):
    if frame.payload.len == 0:
      raise newException(ValueError, "invalid PUSH_PROMISE padding")
    padLen = int(frame.payload[0])
    offset = 1
  if frame.payload.len < offset + 4:
    raise newException(ValueError, "PUSH_PROMISE payload too short")
  if offset + 4 + padLen > frame.payload.len:
    raise newException(ValueError, "invalid PUSH_PROMISE padding")
  let promised =
    ((uint32(ord(frame.payload[offset])) shl 24) or
     (uint32(ord(frame.payload[offset + 1])) shl 16) or
     (uint32(ord(frame.payload[offset + 2])) shl 8) or
     uint32(ord(frame.payload[offset + 3]))) and 0x7FFFFFFF'u32
  if promised == 0 or (promised mod 2) != 0:
    raise newException(ValueError, "invalid PUSH_PROMISE promised stream id")
  result.promisedStreamId = promised
  let blockStart = offset + 4
  let blockEnd = frame.payload.len - padLen
  if blockStart < blockEnd:
    result.headerBlock = frame.payload[blockStart ..< blockEnd]
  else:
    result.headerBlock = ""

proc consumePushPromiseHeaderBlock(conn: var H2ClientConnection, headerBlock: string, responseBuf: var string): bool =
  try:
    discard hpackDecode(conn.decoder, cast[seq[byte]](headerBlock))
    true
  except CatchableError:
    conn.h2ConnectionError(uint32(h2p.ecCompressionError), responseBuf)
    false

proc h2StreamError(conn: var H2ClientConnection, sid: uint32, code: uint32, responseBuf: var string,
                   result: var seq[(uint32, H2Stream)]) {.inline.} =
  serializeRstStream(sid, code, responseBuf)
  if sid in conn.streams:
    conn.streams[sid].state = ssClosed
    conn.streams[sid].responseStatus = 0
    conn.streams[sid].responseBody.setLen(0)
    result.add((sid, conn.streams[sid]))

proc canConsumeWindow(conn: H2ClientConnection, sid: uint32, amount: uint32): bool {.inline.} =
  if amount > uint32(high(int32)):
    return false
  if int64(conn.localWindow) - int64(amount) < 0:
    return false
  if sid in conn.streams and int64(conn.streams[sid].recvWindow) - int64(amount) < 0:
    return false
  true

proc debitInboundDataWindow(conn: var H2ClientConnection, sid: uint32, amount: uint32) {.inline.} =
  conn.localWindow -= int32(amount)
  if sid in conn.streams:
    conn.streams[sid].recvWindow -= int32(amount)

proc refreshInboundDataWindows(conn: var H2ClientConnection, sid: uint32, responseBuf: var string,
                               includeStream: bool) {.inline.} =
  if conn.localWindow < DefaultWindowSize div 2:
    let inc = DefaultWindowSize - conn.localWindow
    serializeWindowUpdate(0, uint32(inc), responseBuf)
    conn.localWindow += inc
  if includeStream and sid in conn.streams and conn.streams[sid].recvWindow < DefaultWindowSize div 2:
    let inc = DefaultWindowSize - conn.streams[sid].recvWindow
    serializeWindowUpdate(sid, uint32(inc), responseBuf)
    conn.streams[sid].recvWindow += inc

## Processes one received HTTP/2 frame, updating connection and stream state and appending any response frames.
proc processFrame*(conn: var H2ClientConnection, frame: h2p.H2Frame, responseBuf: var string): seq[(uint32, H2Stream)] =
  result = @[]
  let ft = frame.frameType

  if frame.length > conn.localSettings.maxFrameSize:
    conn.h2ConnectionError(uint32(h2p.ecFrameSizeError), responseBuf)
    return
  if not validateFrameLength(frame, conn.localSettings.maxFrameSize):
    conn.h2ConnectionError(uint32(h2p.ecFrameSizeError), responseBuf)
    return
  if conn.state == h2csPreface:
    if ft != h2p.ftSettings or hasFlag(frame, FlagAck):
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
  if conn.state == h2csGoaway and ft in {h2p.ftHeaders, h2p.ftData, h2p.ftContinuation, h2p.ftPushPromise}:
    return

  if conn.continuationStreamId != 0 and ft != h2p.ftContinuation:
    conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
    return

  if ft == h2p.ftContinuation and conn.continuationStreamId == 0:
    conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
    return

  if ft == h2p.ftPushPromise:
    if frame.streamId == 0 or not conn.localSettings.enablePush:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    var headerBlock: string
    try:
      let pp = extractPushPromiseHeaderBlock(frame)
      headerBlock = pp.headerBlock
    except CatchableError:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    if hasFlag(frame, FlagEndHeaders):
      discard conn.consumePushPromiseHeaderBlock(headerBlock, responseBuf)
    else:
      conn.continuationStreamId = frame.streamId
      conn.continuationIsPushPromise = true
      conn.headerBlockBuf = headerBlock
    return

  if ft == h2p.ftSettings:
    if frame.streamId != 0:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    if hasFlag(frame, FlagAck):
      if frame.length != 0:
        conn.h2ConnectionError(uint32(h2p.ecFrameSizeError), responseBuf)
        return
    else:
      if frame.payload.len mod 6 != 0:
        conn.h2ConnectionError(uint32(h2p.ecFrameSizeError), responseBuf)
        return
      if frame.payload.len == 0:
        conn.state = h2csActive
        serializeSettingsAck(responseBuf)
        return
      try:
        var parsed = conn.remoteSettings
        applySettings(parsed, frame.payload)
        let oldWindowSize = int32(conn.remoteSettings.initialWindowSize)
        if parsed.headerTableSize != conn.remoteSettings.headerTableSize:
          try:
            conn.encoder.updateEncoderMaxSize(int(parsed.headerTableSize))
          except CatchableError:
            conn.h2ConnectionError(uint32(h2p.ecCompressionError), responseBuf)
            return
        conn.remoteSettings.headerTableSize = parsed.headerTableSize
        conn.remoteSettings.enablePush = parsed.enablePush
        conn.remoteSettings.maxConcurrentStreams = parsed.maxConcurrentStreams
        conn.remoteSettings.initialWindowSize = parsed.initialWindowSize
        conn.remoteSettings.maxFrameSize = parsed.maxFrameSize
        conn.remoteSettings.maxHeaderListSize = parsed.maxHeaderListSize
        let delta = int32(parsed.initialWindowSize) - oldWindowSize
        var streamIds: seq[uint32] = @[]
        if delta != 0:
          for sid in conn.streams.keys:
            streamIds.add sid
          for sid in streamIds:
            let newWindow = int64(conn.streams[sid].sendWindow) + int64(delta)
            if newWindow < int64(low(int32)) or newWindow > int64(high(int32)):
              conn.h2ConnectionError(uint32(h2p.ecFlowControlError), responseBuf)
              return
            conn.streams[sid].sendWindow = int32(newWindow)
        if delta > 0:
          if streamIds.len == 0:
            for sid in conn.streams.keys:
              streamIds.add sid
          for sid in streamIds:
            conn.flushPendingData(sid, responseBuf)
      except CatchableError:
        conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
        return
      conn.state = h2csActive
      serializeSettingsAck(responseBuf)
  elif ft == h2p.ftHeaders:
    let sid = frame.streamId
    if not isValidH2StreamId(sid):
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    if (sid mod 2) == 0:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    if sid notin conn.streams:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    if conn.streams[sid].state == ssClosed:
      serializeRstStream(sid, uint32(h2p.ecStreamClosed), responseBuf)
      return
    conn.lastStreamId = max(conn.lastStreamId, sid)
    var headerBlock: string
    try:
      headerBlock = extractHeaderBlock(frame)
    except CatchableError:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    let endStream = hasFlag(frame, FlagEndStream)
    if hasFlag(frame, FlagEndHeaders):
      case conn.applyDecodedHeaders(sid, headerBlock, endStream, result)
      of hasOk:
        discard
      of hasCompressionError:
        conn.h2ConnectionError(uint32(h2p.ecCompressionError), responseBuf)
      of hasProtocolError:
        conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
    else:
      conn.continuationStreamId = sid
      conn.continuationIsPushPromise = false
      conn.headerBlockBuf = headerBlock
      conn.streams[sid].headerBuf = if endStream: "ES" else: ""
  elif ft == h2p.ftContinuation:
    if conn.continuationStreamId != 0 and conn.continuationStreamId != frame.streamId:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    if conn.continuationStreamId != 0 and conn.continuationStreamId == frame.streamId:
      if conn.headerBlockBuf.len + frame.payload.len > 65536:
        conn.continuationStreamId = 0
        conn.continuationIsPushPromise = false
        conn.headerBlockBuf = ""
        conn.h2ConnectionError(uint32(h2p.ecCompressionError), responseBuf)
        return
      conn.headerBlockBuf.add frame.payload
      if hasFlag(frame, FlagEndHeaders):
        let sid = conn.continuationStreamId
        if conn.continuationIsPushPromise:
          discard conn.consumePushPromiseHeaderBlock(conn.headerBlockBuf, responseBuf)
        else:
          let endStream = sid in conn.streams and conn.streams[sid].headerBuf == "ES"
          case conn.applyDecodedHeaders(sid, conn.headerBlockBuf, endStream, result)
          of hasOk:
            discard
          of hasCompressionError:
            conn.h2ConnectionError(uint32(h2p.ecCompressionError), responseBuf)
          of hasProtocolError:
            conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
        conn.continuationStreamId = 0
        conn.continuationIsPushPromise = false
        conn.headerBlockBuf = ""
  elif ft == h2p.ftData:
    let sid = frame.streamId
    if not isValidH2StreamId(sid):
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    if sid notin conn.streams:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    if not conn.canConsumeWindow(sid, frame.length):
      conn.h2ConnectionError(uint32(h2p.ecFlowControlError), responseBuf)
      return
    conn.debitInboundDataWindow(sid, frame.length)
    if conn.streams[sid].state == ssClosed:
      serializeRstStream(sid, uint32(h2p.ecStreamClosed), responseBuf)
      conn.refreshInboundDataWindows(sid, responseBuf, includeStream = false)
      return
    else:
      if conn.streams[sid].responseStatus <= 0:
        conn.h2StreamError(sid, uint32(h2p.ecProtocolError), responseBuf, result)
        conn.refreshInboundDataWindows(sid, responseBuf, includeStream = false)
        return
      var dataPayload: string
      if hasFlag(frame, FlagPadded):
        try:
          dataPayload = h2p.stripPadding(frame)
        except CatchableError:
          conn.h2StreamError(sid, uint32(h2p.ecProtocolError), responseBuf, result)
          conn.refreshInboundDataWindows(sid, responseBuf, includeStream = false)
          return
      else:
        dataPayload = frame.payload
      if dataPayload.len > 0 and conn.streams[sid].h2NoResponseBodyExpected():
        conn.h2StreamError(sid, uint32(h2p.ecProtocolError), responseBuf, result)
        conn.refreshInboundDataWindows(sid, responseBuf, includeStream = false)
        return
      let expectedLength = conn.streams[sid].h2ExpectedContentLength()
      if expectedLength == -2:
        conn.h2StreamError(sid, uint32(h2p.ecProtocolError), responseBuf, result)
        conn.refreshInboundDataWindows(sid, responseBuf, includeStream = false)
        return
      if expectedLength >= 0 and conn.streams[sid].responseBody.len + dataPayload.len > expectedLength:
        conn.h2StreamError(sid, uint32(h2p.ecProtocolError), responseBuf, result)
        conn.refreshInboundDataWindows(sid, responseBuf, includeStream = false)
        return
      if conn.streams[sid].responseBody.len + dataPayload.len > MaxH2ResponseBodySize:
        conn.h2StreamError(sid, uint32(h2p.ecCancel), responseBuf, result)
        conn.refreshInboundDataWindows(sid, responseBuf, includeStream = false)
        return
      conn.streams[sid].responseBody.add dataPayload
      conn.refreshInboundDataWindows(sid, responseBuf, includeStream = true)
      if hasFlag(frame, FlagEndStream):
        if expectedLength >= 0 and
           not conn.streams[sid].h2NoResponseBodyExpected() and
           conn.streams[sid].responseBody.len != expectedLength:
          conn.h2StreamError(sid, uint32(h2p.ecProtocolError), responseBuf, result)
          return
        conn.streams[sid].state = ssClosed
        result.add((sid, conn.streams[sid]))
  elif ft == h2p.ftPing:
    if frame.payload.len != 8:
      conn.state = h2csGoaway
      conn.localConnectionError = true
      serializeGoaway(conn.lastStreamId, uint32(h2p.ecFrameSizeError), responseBuf)
      return
    if frame.streamId != 0:
      conn.state = h2csGoaway
      conn.localConnectionError = true
      serializeGoaway(conn.lastStreamId, uint32(h2p.ecProtocolError), responseBuf)
      return
    if not hasFlag(frame, FlagAck):
      var pingData: array[8, byte]
      copyMem(addr pingData[0], unsafeAddr frame.payload[0], 8)
      serializePing(pingData, ack = true, responseBuf)
  elif ft == h2p.ftGoaway:
    if frame.streamId != 0:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return
    conn.state = h2csGoaway
    if frame.payload.len >= 8:
      let payBytes = cast[ptr UncheckedArray[byte]](unsafeAddr frame.payload[0])
      let peerLastStreamId = readU32BE(payBytes.toOpenArray(0, frame.payload.len - 1), 0) and 0x7FFFFFFF'u32
      for sid in conn.streams.keys:
        if sid > peerLastStreamId and sid mod 2 == 1:
          if conn.streams[sid].state != ssClosed:
            conn.streams[sid].state = ssClosed
            conn.streams[sid].responseStatus = 0
            conn.streams[sid].responseBody.setLen(0)
            result.add((sid, conn.streams[sid]))
  elif ft == h2p.ftWindowUpdate:
    if frame.payload.len != 4:
      conn.state = h2csGoaway
      conn.localConnectionError = true
      serializeGoaway(conn.lastStreamId, uint32(h2p.ecFrameSizeError), responseBuf)
      return
    let payBytes = cast[ptr UncheckedArray[byte]](unsafeAddr frame.payload[0])
    let increment = int32(readU32BE(payBytes.toOpenArray(0, 3), 0) and 0x7FFFFFFF'u32)
    if increment == 0:
      if frame.streamId == 0:
        conn.state = h2csGoaway
        conn.localConnectionError = true
        serializeGoaway(conn.lastStreamId, uint32(h2p.ecProtocolError), responseBuf)
        return
      else:
        serializeRstStream(frame.streamId, uint32(h2p.ecProtocolError), responseBuf)
        if frame.streamId in conn.streams:
          conn.streams[frame.streamId].state = ssClosed
          result.add((frame.streamId, conn.streams[frame.streamId]))
    elif frame.streamId == 0:
      if not isValidH2WindowSize(int64(conn.remoteWindow) + int64(increment)):
        conn.state = h2csGoaway
        conn.localConnectionError = true
        serializeGoaway(conn.lastStreamId, uint32(h2p.ecFlowControlError), responseBuf)
        return
      else:
        conn.remoteWindow += increment
        var streamIds: seq[uint32] = @[]
        for sid in conn.streams.keys:
          streamIds.add sid
        for sid in streamIds:
          conn.flushPendingData(sid, responseBuf)
    elif frame.streamId in conn.streams:
      if not isValidH2WindowSize(int64(conn.streams[frame.streamId].sendWindow) + int64(increment)):
        conn.streams[frame.streamId].state = ssClosed
        conn.streams[frame.streamId].responseStatus = 0
        conn.streams[frame.streamId].responseBody.setLen(0)
        result.add((frame.streamId, conn.streams[frame.streamId]))
      else:
        conn.streams[frame.streamId].sendWindow += increment
        conn.flushPendingData(frame.streamId, responseBuf)
  elif ft == h2p.ftRstStream:
    if frame.payload.len != 4:
      conn.state = h2csGoaway
      conn.localConnectionError = true
      serializeGoaway(conn.lastStreamId, uint32(h2p.ecFrameSizeError), responseBuf)
      return
    if frame.streamId == 0:
      conn.state = h2csGoaway
      conn.localConnectionError = true
      serializeGoaway(conn.lastStreamId, uint32(h2p.ecProtocolError), responseBuf)
      return
    let sid = frame.streamId
    if sid in conn.streams:
      conn.streams[sid].state = ssClosed
      conn.streams[sid].responseStatus = 0
      conn.streams[sid].responseBody.setLen(0)
      result.add((sid, conn.streams[sid]))
  elif ft == h2p.ftPriority:
    if frame.streamId == 0:
      conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
      return

const MaxH2RecvBufSize = int(MaxH2FrameSizeVal) + H2FrameHeaderSize

## Feeds raw bytes into the connection, parses complete frames, and returns the streams that finished.
proc feedData*(conn: var H2ClientConnection, data: openArray[byte], responseBuf: var string): seq[(uint32, H2Stream)] =
  result = @[]
  let oldLen = conn.recvBuf.len
  if oldLen + data.len > MaxH2RecvBufSize:
    conn.state = h2csGoaway
    conn.localConnectionError = true
    serializeGoaway(conn.lastStreamId, uint32(h2p.ecEnhanceYourCalm), responseBuf)
    return
  conn.recvBuf.setLen(oldLen + data.len)
  if data.len > 0:
    copyMem(addr conn.recvBuf[oldLen], unsafeAddr data[0], data.len)
  var pos = 0
  let bufData = cast[seq[byte]](conn.recvBuf)
  while true:
    let beforeParse = pos
    let frame = parseH2Frame(bufData, pos)
    if frame.isNone:
      if pos > beforeParse:
        if conn.continuationStreamId != 0:
          conn.h2ConnectionError(uint32(h2p.ecProtocolError), responseBuf)
          return
        continue
      break
    let completed = conn.processFrame(frame.get, responseBuf)
    result.add completed
  if pos > 0:
    if pos >= conn.recvBuf.len:
      conn.recvBuf.setLen(0)
    else:
      let remaining = conn.recvBuf.len - pos
      moveMem(addr conn.recvBuf[0], addr conn.recvBuf[pos], remaining)
      conn.recvBuf.setLen(remaining)
