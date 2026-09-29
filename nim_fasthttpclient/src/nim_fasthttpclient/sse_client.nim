import std/[strutils]
import types
import validation

type
  SseParser* = object
    buf*: string
    currentEvent*: SseEvent
    lastEventId*: string
    retryMs*: int
    hasId*: bool
    bomChecked*: bool
    discardingEvent*: bool

## Creates a new Server-Sent Events parser with the default 3000 millisecond retry.
proc initSseParser*(): SseParser {.inline.} =
  result.retryMs = 3000
  result.currentEvent.retry = result.retryMs

proc resetEvent(parser: var SseParser) {.inline.} =
  parser.currentEvent = SseEvent(
    eventType: "",
    data: "",
    id: "",
    retry: parser.retryMs,
  )
  parser.hasId = false
  parser.discardingEvent = false

const SseMaxBufSize* = 1048576
const SseMaxEventSize* = 1048576

proc findSseLineEnd(buf: string): tuple[pos: int, nextPos: int] {.inline.} =
  result.pos = -1
  result.nextPos = -1
  for i, ch in buf:
    if ch == '\r' or ch == '\n':
      result.pos = i
      result.nextPos = i + 1
      if ch == '\r' and result.nextPos < buf.len and buf[result.nextPos] == '\n':
        inc result.nextPos
      return

## Feeds a chunk of a Server-Sent Events stream into the parser and returns the completed events.
proc feedData*(parser: var SseParser, data: string): seq[SseEvent] =
  result = @[]
  parser.buf.add data
  if not parser.bomChecked:
    if parser.buf.len < 3:
      let isBomPrefix =
        (parser.buf.len == 1 and parser.buf[0] == char(0xEF)) or
        (parser.buf.len == 2 and parser.buf[0] == char(0xEF) and parser.buf[1] == char(0xBB))
      if isBomPrefix:
        return
    parser.bomChecked = true
    if parser.buf.len >= 3 and parser.buf[0] == char(0xEF) and
       parser.buf[1] == char(0xBB) and parser.buf[2] == char(0xBF):
      parser.buf = parser.buf[3 ..< parser.buf.len]
  if parser.buf.len > SseMaxBufSize:
    parser.buf = parser.buf[parser.buf.len - SseMaxBufSize ..< parser.buf.len]
    let firstNewline = findSseLineEnd(parser.buf)
    if firstNewline.pos >= 0 and firstNewline.nextPos < parser.buf.len:
      parser.buf = parser.buf[firstNewline.nextPos ..< parser.buf.len]
    parser.resetEvent()
  while true:
    let lineEnd = findSseLineEnd(parser.buf)
    if lineEnd.pos < 0:
      break
    let line = parser.buf[0 ..< lineEnd.pos]
    parser.buf = parser.buf[lineEnd.nextPos ..< parser.buf.len]

    if line.len == 0:
      if parser.hasId:
        parser.lastEventId = parser.currentEvent.id
      if parser.currentEvent.data.len > 0:
        if parser.currentEvent.data.len > 0 and parser.currentEvent.data[^1] == '\n':
          parser.currentEvent.data = parser.currentEvent.data[0 ..< parser.currentEvent.data.len - 1]
        result.add parser.currentEvent
      parser.resetEvent()
      continue

    if line[0] == ':':
      continue
    if parser.discardingEvent:
      continue

    let colonPos = line.find(':')
    var fieldName, fieldValue: string
    if colonPos < 0:
      fieldName = line
      fieldValue = ""
    else:
      fieldName = line[0 ..< colonPos]
      fieldValue = line[colonPos + 1 ..< line.len]
      if fieldValue.len > 0 and fieldValue[0] == ' ':
        fieldValue = fieldValue[1 ..< fieldValue.len]

    case fieldName
    of "event":
      parser.currentEvent.eventType = fieldValue
    of "data":
      if parser.currentEvent.data.len + fieldValue.len + 1 > SseMaxEventSize:
        parser.resetEvent()
        parser.discardingEvent = true
        continue
      parser.currentEvent.data.add fieldValue
      parser.currentEvent.data.add '\n'
    of "id":
      if '\0' notin fieldValue:
        parser.currentEvent.id = fieldValue
        parser.hasId = true
    of "retry":
      var allDigits = true
      for c in fieldValue:
        if c < '0' or c > '9':
          allDigits = false
          break
      if allDigits and fieldValue.len > 0 and fieldValue.len <= 9:
        parser.retryMs = parseInt(fieldValue)
        parser.currentEvent.retry = parser.retryMs
    else:
      discard

## Builds the HTTP/1.1 GET request for an SSE endpoint, including an optional Last-Event-ID header.
proc buildSseRequest*(host: string, path: string, port: uint16, lastEventId: string = "",
                      useSsl: bool = false): string =
  if not isValidPath(path):
    return ""
  if not isValidHost(host):
    return ""
  result = newStringOfCap(256)
  result.add "GET "
  result.add path
  result.add " HTTP/1.1\r\n"
  result.add "Host: "
  result.add authorityForRequest(host, port, useSsl)
  result.add "\r\nAccept: text/event-stream\r\nCache-Control: no-cache\r\n"
  if lastEventId.len > 0 and isValidHeaderValue(lastEventId):
    result.add "Last-Event-ID: "
    result.add lastEventId
    result.add "\r\n"
  result.add "\r\n"
