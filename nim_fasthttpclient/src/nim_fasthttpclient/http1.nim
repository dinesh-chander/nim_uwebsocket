import std/[strutils]
import types
import validation

# Optional SSE2 CRLF (\r\n) finder via nimsimd for the per-line response scan.
# Portable byte scan is the fallback (and the default under -d:nimHttp1CrlfPortable).
const http1CrlfUseSse2* =
  (hostCPU == "amd64" or hostCPU == "i386") and
  (defined(gcc) or defined(clang)) and
  not defined(js) and not defined(nimHttp1CrlfPortable)

when http1CrlfUseSse2:
  import nimsimd/sse2

const MethodStrings*: array[HttpMethod, string] = [
  hmGet: "GET",
  hmHead: "HEAD",
  hmPost: "POST",
  hmPut: "PUT",
  hmDelete: "DELETE",
  hmPatch: "PATCH",
  hmOptions: "OPTIONS",
]

## Builds the raw HTTP/1.1 request line, validated headers, and body for ``req``, returning an empty string if the path or host is invalid.
proc serializeRequest*(req: HttpRequest): string {.inline.} =
  let pathStr = if req.path.len > 0: req.path else: "/"
  if containsCRLF(pathStr):
    return ""
  if not isValidHost(req.host):
    return ""
  result = newStringOfCap(256 + req.body.len)
  result.add MethodStrings[req.`method`]
  result.add ' '
  result.add pathStr
  result.add " HTTP/1.1\r\nHost: "
  result.add authorityForRequest(req.host, req.port, req.useSsl)
  result.add "\r\n"
  for h in req.headers:
    if not isValidHeaderName(h.name):
      continue
    if not isValidHeaderValue(h.value):
      continue
    let lowerName = h.name.toLowerAscii()
    if lowerName == "host" or lowerName == "content-length" or lowerName == "transfer-encoding":
      continue
    result.add h.name
    result.add ": "
    result.add h.value
    result.add "\r\n"
  if req.body.len > 0:
    result.add "Content-Length: "
    result.addInt req.body.len
    result.add "\r\n"
  result.add "\r\n"
  if req.body.len > 0:
    result.add req.body

type
  Http1ParseState* = enum
    psStatusLine
    psHeaders
    psBody
    psChunkedBody
    psChunkedData
    psChunkedDataCrlf
    psChunkedTrailers
    psDone
    psError

  Http1Parser* = object
    state*: Http1ParseState
    response*: HttpResponse
    contentLength*: int
    chunked*: bool
    transferEncodingSeen*: bool
    bodyRead*: int
    chunkRemaining*: int
    keepAlive*: bool
    headerCount*: int
    headerBytes*: int
    hasContentLength*: bool
    noBodyExpected*: bool

const
  MaxHeaderCount = 256
  MaxHttp1StatusLineLen* = 1024
  MaxHttp1HeaderLineLen* = 8192
  MaxHttp1HeaderBytes* = 64 * 1024

## Creates a new ``Http1Parser`` in the initial status-line state with keep-alive enabled.
proc initHttp1Parser*(): Http1Parser {.inline.} =
  result.state = psStatusLine
  result.contentLength = -1
  result.keepAlive = true

proc parseStatusLine(parser: var Http1Parser, line: string): bool {.inline.} =
  if line.len < 12:
    return false
  if line[0] != 'H' or line[1] != 'T' or line[2] != 'T' or line[3] != 'P' or line[4] != '/':
    return false
  if line[5] != '1' or line[6] != '.' or (line[7] != '0' and line[7] != '1'):
    return false
  if line[8] != ' ':
    return false
  var code = 0
  var i = 9
  while i < 12:
    if line[i] < '0' or line[i] > '9':
      return false
    code = code * 10 + (ord(line[i]) - ord('0'))
    i += 1
  if i < line.len and line[i] != ' ':
    return false
  if not isValidStatusCode(code):
    return false
  parser.response.statusCode = code
  if i < line.len and line[i] == ' ':
    i += 1
  parser.response.statusText = if i < line.len: line[i ..< line.len] else: ""
  if line[7] == '1':
    parser.response.version = Http11
  elif line[7] == '0':
    parser.response.version = Http10
    parser.keepAlive = false
  true

proc toLowerInPlace(s: var string) {.inline.} =
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z':
      s[i] = chr(ord(c) + 32)

proc findCrLf(data: string, start: int): int {.inline.} =
  ## Find the next \r\n at/after `start`, or -1. SSE2 (nimsimd) tests 16 byte
  ## pairs per vector; a scalar tail resolves the short remainder. The SIMD
  ## loop only runs while 17 bytes remain, so short lines use the tail only.
  var i = start
  let len = data.len
  when http1CrlfUseSse2:
    while i + 17 <= len:
      let vcr = mm_loadu_si128(cast[ptr uint64](unsafeAddr data[i]))
      let vlf = mm_loadu_si128(cast[ptr uint64](unsafeAddr data[i + 1]))
      let hit = mm_and_si128(mm_cmpeq_epi8(vcr, mm_set1_epi8(13.uint8)),
                             mm_cmpeq_epi8(vlf, mm_set1_epi8(10.uint8)))
      var m = mm_movemask_epi8(hit)
      if m != 0:
        var b = 0
        while (m and 1) == 0: m = m shr 1; inc b
        return i + b
      i += 16
  let limit = len - 1
  while i < limit:
    if data[i] == '\r' and data[i + 1] == '\n':
      return i
    i += 1
  -1

proc asciiEq(data: string, start: int, token: string): bool {.inline.} =
  if start < 0 or start + token.len > data.len:
    return false
  for i in 0 ..< token.len:
    let a = data[start + i]
    let b = token[i]
    if a == b:
      continue
    if a >= 'A' and a <= 'Z' and chr(ord(a) + 32) == b:
      continue
    return false
  true

proc containsToken(data: string, startPos: int, endPos: int, token: string): bool {.inline.} =
  var pos = startPos
  while pos <= endPos:
    while pos < endPos and (data[pos] == ' ' or data[pos] == '\t' or data[pos] == ','):
      inc pos
    let tokStart = pos
    while pos < endPos and data[pos] != ',':
      inc pos
    var tokEnd = pos
    while tokEnd > tokStart and (data[tokEnd - 1] == ' ' or data[tokEnd - 1] == '\t'):
      dec tokEnd
    if tokEnd - tokStart == token.len and asciiEq(data, tokStart, token):
      return true
    inc pos
  false

proc finalTokenIs(data: string, startPos: int, endPos: int, token: string): bool {.inline.} =
  var pos = endPos
  while pos > startPos and (data[pos - 1] == ' ' or data[pos - 1] == '\t'):
    dec pos
  var tokStart = pos
  while tokStart > startPos and data[tokStart - 1] != ',':
    dec tokStart
  while tokStart < pos and (data[tokStart] == ' ' or data[tokStart] == '\t'):
    inc tokStart
  pos - tokStart == token.len and asciiEq(data, tokStart, token)

proc parseContentLengthValue(data: string, valStart: int, lineEnd: int, outVal: var int): bool {.inline.} =
  var j = valStart
  while j < lineEnd and (data[j] == ' ' or data[j] == '\t'):
    inc j
  if j >= lineEnd:
    return false
  var cl = 0
  while j < lineEnd and data[j] >= '0' and data[j] <= '9':
    let digit = ord(data[j]) - ord('0')
    if cl > (MaxContentLengthVal - digit) div 10:
      return false
    cl = cl * 10 + digit
    inc j
  while j < lineEnd and (data[j] == ' ' or data[j] == '\t'):
    inc j
  if j != lineEnd:
    return false
  outVal = cl
  isValidContentLength(cl)

proc isValidTrailerLine(data: string, lineStart: int, lineEnd: int): bool {.inline.} =
  var colonPos = -1
  var i = lineStart
  while i < lineEnd:
    if data[i] == ':':
      colonPos = i
      break
    inc i
  if colonPos <= lineStart:
    return false
  let name = data[lineStart ..< colonPos]
  var valStart = colonPos + 1
  while valStart < lineEnd and (data[valStart] == ' ' or data[valStart] == '\t'):
    inc valStart
  let value = data[valStart ..< lineEnd]
  if not isValidHeaderName(name) or not isValidHeaderValue(value):
    return false
  let lowerName = name.toLowerAscii()
  lowerName != "content-length" and lowerName != "transfer-encoding" and
    lowerName != "host"

proc parseHeaderInline(parser: var Http1Parser, data: string, lineStart: int, lineEnd: int): bool {.inline.} =
  let lineLen = lineEnd - lineStart
  if lineLen > MaxHttp1HeaderLineLen:
    return false
  parser.headerBytes += lineLen + 2
  if parser.headerBytes > MaxHttp1HeaderBytes:
    return false
  parser.headerCount += 1
  if parser.headerCount > MaxHeaderCount:
    return false
  var colonPos = -1
  var i = lineStart
  while i < lineEnd:
    if data[i] == ':':
      colonPos = i
      break
    i += 1
  if colonPos <= lineStart:
    return false
  let nameLen = colonPos - lineStart
  var name = data[lineStart ..< colonPos]
  toLowerInPlace(name)
  var valStart = colonPos + 1
  while valStart < lineEnd and (data[valStart] == ' ' or data[valStart] == '\t'):
    valStart += 1
  let value = data[valStart ..< lineEnd]
  if not isValidHeaderName(name) or not isValidHeaderValue(value):
    return false
  parser.response.headers.add HttpHeader(name: name, value: value)
  if nameLen == 14 and name[0] == 'c' and name == "content-length":
    if parser.transferEncodingSeen:
      return false
    if parser.hasContentLength:
      return false
    parser.hasContentLength = true
    var cl = 0
    if parseContentLengthValue(data, valStart, lineEnd, cl):
      parser.contentLength = cl
    else:
      return false
  elif nameLen == 17 and name[0] == 't' and name == "transfer-encoding":
    if parser.hasContentLength:
      return false
    parser.transferEncodingSeen = true
    if finalTokenIs(data, valStart, lineEnd, "chunked"):
      parser.chunked = true
  elif nameLen == 10 and name[0] == 'c' and name == "connection":
    if containsToken(data, valStart, lineEnd, "close"):
      parser.keepAlive = false
  true

proc parseChunkSizeLine(data: string, pos: int, lineEnd: int, chunkSize: var int): bool {.inline.} =
  var chunkLineEnd = lineEnd
  for ci in pos ..< lineEnd:
    if data[ci] == ';':
      chunkLineEnd = ci
      break
  var i = pos
  while i < chunkLineEnd and (data[i] == ' ' or data[i] == '\t'):
    inc i
  if i >= chunkLineEnd:
    return false
  var size = 0
  var digits = 0
  while i < chunkLineEnd:
    let c = data[i]
    var digit = -1
    if c >= '0' and c <= '9':
      digit = ord(c) - ord('0')
    elif c >= 'a' and c <= 'f':
      digit = ord(c) - ord('a') + 10
    elif c >= 'A' and c <= 'F':
      digit = ord(c) - ord('A') + 10
    elif c == ' ' or c == '\t':
      while i < chunkLineEnd and (data[i] == ' ' or data[i] == '\t'):
        inc i
      if i != chunkLineEnd:
        return false
      break
    else:
      return false
    if size > (MaxChunkSize - digit) div 16:
      return false
    size = size * 16 + digit
    inc digits
    inc i
  if digits == 0 or not isValidChunkSize(size):
    return false
  chunkSize = size
  true

## Feeds a chunk of response bytes into ``parser`` and returns true once the full response or an error is finalized, recording the number of bytes taken in ``consumed``. On incomplete data ``consumed`` reports the bytes already parsed so callers can compact the buffer; parser state carries the partial line across calls.
proc feedData*(parser: var Http1Parser, data: string, consumed: var int): bool =
  consumed = 0
  var pos = 0
  while pos < data.len:
    case parser.state
    of psStatusLine:
      let lineEnd = findCrLf(data, pos)
      if lineEnd < 0:
        if data.len - pos > MaxHttp1StatusLineLen:
          parser.state = psError
          consumed = pos
          return true
        consumed = pos
        return false
      if lineEnd - pos > MaxHttp1StatusLineLen:
        parser.state = psError
        consumed = pos
        return true
      if not parser.parseStatusLine(data[pos ..< lineEnd]):
        parser.state = psError
        return true
      parser.state = psHeaders
      pos = lineEnd + 2
    of psHeaders:
      let lineEnd = findCrLf(data, pos)
      if lineEnd < 0:
        if data.len - pos > MaxHttp1HeaderLineLen or
            parser.headerBytes + (data.len - pos) > MaxHttp1HeaderBytes:
          parser.state = psError
          consumed = pos
          return true
        consumed = pos
        return false
      if lineEnd == pos:
        pos += 2
        consumed = pos
        let noBodyStatus =
          (parser.response.statusCode >= 100 and parser.response.statusCode < 200) or
          parser.response.statusCode == 204 or parser.response.statusCode == 304
        let informationalStatus =
          parser.response.statusCode >= 100 and parser.response.statusCode < 200 and
          parser.response.statusCode != 101
        if informationalStatus:
          let preserveNoBodyExpected = parser.noBodyExpected
          parser = initHttp1Parser()
          parser.noBodyExpected = preserveNoBodyExpected
          continue
        if noBodyStatus or parser.noBodyExpected:
          if noBodyStatus and (parser.contentLength > 0 or parser.transferEncodingSeen or parser.chunked):
            parser.keepAlive = false
          parser.state = psDone
          return true
        elif parser.chunked:
          parser.state = psChunkedBody
        elif parser.transferEncodingSeen:
          parser.keepAlive = false
          parser.state = psBody
          parser.response.body = ""
        elif parser.contentLength > 0:
          parser.state = psBody
          parser.response.body = newStringOfCap(parser.contentLength)
        elif parser.contentLength == 0:
          parser.state = psDone
          return true
        else:
          parser.state = psBody
          parser.response.body = ""
        continue
      if not parseHeaderInline(parser, data, pos, lineEnd):
        parser.state = psError
        consumed = pos
        return true
      pos = lineEnd + 2
    of psBody:
      if parser.contentLength > 0:
        let remaining = parser.contentLength - parser.bodyRead
        let available = data.len - pos
        let toRead = min(remaining, available)
        parser.response.body.add data[pos ..< pos + toRead]
        parser.bodyRead += toRead
        pos += toRead
        consumed = pos
        if parser.bodyRead >= parser.contentLength:
          parser.state = psDone
          return true
      else:
        if parser.response.body.len + (data.len - pos) > 64 * 1024 * 1024:
          parser.state = psError
          return true
        parser.response.body.add data[pos ..< data.len]
        consumed = data.len
        return false
    of psChunkedBody:
      let lineEnd = data.find("\r\n", pos)
      if lineEnd < 0:
        consumed = pos
        return false
      var chunkSize = 0
      if not parseChunkSizeLine(data, pos, lineEnd, chunkSize):
        parser.state = psError
        consumed = pos
        return true
      pos = lineEnd + 2
      if chunkSize == 0:
        parser.state = psChunkedTrailers
        continue
      if parser.response.body.len + chunkSize > MaxContentLengthVal:
        parser.state = psError
        consumed = pos
        return true
      parser.chunkRemaining = chunkSize
      parser.state = psChunkedData
    of psChunkedData:
      let available = data.len - pos
      let toRead = min(parser.chunkRemaining, available)
      parser.response.body.add data[pos ..< pos + toRead]
      parser.chunkRemaining -= toRead
      pos += toRead
      consumed = pos
      if parser.chunkRemaining > 0:
        return false
      parser.state = psChunkedDataCrlf
    of psChunkedDataCrlf:
      let available = data.len - pos
      if available < 2:
        consumed = pos
        return false
      if data[pos] != '\r' or data[pos + 1] != '\n':
        parser.state = psError
        consumed = pos
        return true
      pos += 2
      consumed = pos
      parser.state = psChunkedBody
    of psChunkedTrailers:
      let lineEnd = findCrLf(data, pos)
      if lineEnd < 0:
        consumed = pos
        return false
      if lineEnd == pos:
        pos += 2
        parser.state = psDone
        consumed = pos
        return true
      if not isValidTrailerLine(data, pos, lineEnd):
        parser.state = psError
        return true
      pos = lineEnd + 2
      consumed = pos
    of psDone, psError:
      return true
  consumed = pos
  false
