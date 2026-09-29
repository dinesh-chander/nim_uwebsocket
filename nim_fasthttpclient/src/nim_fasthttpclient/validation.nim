const MaxChunkSize* = 16 * 1024 * 1024
const MaxContentLengthVal* = 256 * 1024 * 1024
const MaxH2FrameSizeVal* = 16777215'u32
const MaxHeaderNameLen* = 256
const MaxHeaderValueLen* = 64 * 1024

## Returns true if the string contains a CR, LF, or NUL byte.
proc containsCRLF*(s: string): bool {.inline.} =
  for c in s:
    if c == '\r' or c == '\n' or c == '\0':
      return true
  false

## Returns true if the string contains an embedded NUL byte.
proc containsNullByte*(s: string): bool {.inline.} =
  for c in s:
    if c == '\0':
      return true
  false

proc isHeaderTokenChar(c: char): bool {.inline.} =
  (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
    (c >= '0' and c <= '9') or c == '!' or c == '#' or c == '$' or
    c == '%' or c == '&' or c == '\'' or c == '*' or c == '+' or
    c == '-' or c == '.' or c == '^' or c == '_' or c == '`' or
    c == '|' or c == '~'

## Returns true if the string is a valid HTTP header name token within the length limit.
proc isValidHeaderName*(name: string): bool {.inline.} =
  if name.len == 0 or name.len > MaxHeaderNameLen:
    return false
  for c in name:
    if not isHeaderTokenChar(c):
      return false
  true

## Returns true if the string is a safe HTTP header value with no CR, LF, or control bytes.
proc isValidHeaderValue*(value: string): bool {.inline.} =
  if value.len > MaxHeaderValueLen:
    return false
  for c in value:
    if c == '\r' or c == '\n' or c == '\0':
      return false
    if c < ' ' and c != '\t':
      return false
  true

## Returns true if the string is a syntactically valid DNS host name.
proc isValidHost*(host: string): bool {.inline.} =
  if host.len == 0 or host.len > 253:
    return false
  var labelLen = 0
  var lastWasDot = false
  var labelStart = true
  var lastChar = '\0'
  for c in host:
    if c == '\r' or c == '\n' or c == '\0' or c <= ' ' or c > '~':
      return false
    if c == '/' or c == '\\' or c == '@' or c == ':' or c == '[' or c == ']' or
       c == '?' or c == '#':
      return false
    if c == '.':
      if labelLen == 0 or lastChar == '-':
        return false
      labelLen = 0
      lastWasDot = true
      labelStart = true
      lastChar = c
      continue
    if not ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-'):
      return false
    inc labelLen
    if labelLen > 63:
      return false
    if labelStart and c == '-':
      return false
    labelStart = false
    lastWasDot = false
    lastChar = c
  if lastWasDot or lastChar == '-':
    return false
  true

## Returns true if the string is a safe origin-form HTTP path without control or fragment characters.
proc isValidPath*(path: string): bool {.inline.} =
  if path.len == 0 or path[0] != '/':
    return false
  for c in path:
    if c <= ' ' or c == '\x7f' or c == '#':
      return false
  true

## Returns true if the scheme is http or https.
proc isValidUrlScheme*(scheme: string): bool {.inline.} =
  scheme == "http" or scheme == "https"

## Returns true if the port is within the valid TCP port range.
proc isValidPort*(port: uint16): bool {.inline.} =
  port >= 1 and port <= 65535

## Returns true if the code is a three-digit HTTP status code.
proc isValidStatusCode*(code: int): bool {.inline.} =
  code >= 100 and code <= 999

## Returns true if the stream id is a valid HTTP/2 stream identifier.
proc isValidH2StreamId*(id: uint32): bool {.inline.} =
  id >= 1 and id <= 2147483647'u32

## Returns true if the window size fits the HTTP/2 31-bit flow-control range.
proc isValidH2WindowSize*(size: int64): bool {.inline.} =
  size >= 0 and size <= 2147483647'i64

## Returns true if the payload length is valid for the WebSocket opcode, capping control frames at 125 bytes.
proc isValidWsPayloadLen*(opcode: int, len: int): bool {.inline.} =
  if opcode >= 8:
    return len <= 125
  true

## Returns true if the WebSocket opcode denotes a control frame.
proc isControlFrame*(opcode: int): bool {.inline.} =
  opcode >= 8

## Returns true if the chunk size is within the maximum allowed chunk size.
proc isValidChunkSize*(size: int): bool {.inline.} =
  size >= 0 and size <= MaxChunkSize

## Returns true if the content length is within the maximum allowed body size.
proc isValidContentLength*(cl: int): bool {.inline.} =
  cl >= 0 and cl <= MaxContentLengthVal

## Returns true if the body size is within the maximum allowed body size.
proc isValidBodySize*(size: int): bool {.inline.} =
  size >= 0 and size <= MaxContentLengthVal

## Returns true if the HTTP/2 frame size is within the allowed 16 KiB to 16 MiB range.
proc isValidH2FrameSize*(size: uint32): bool {.inline.} =
  size >= 16384'u32 and size <= MaxH2FrameSizeVal

## Returns a log-safe copy of the string with control bytes replaced and long input truncated.
proc sanitizeForLog*(s: string, maxLen: int = 128): string =
  let truncLen = min(s.len, maxLen)
  result = newStringOfCap(truncLen)
  for i in 0 ..< truncLen:
    let c = s[i]
    if ord(c) < 32 or ord(c) == 127:
      result.add '?'
    else:
      result.add c
  if s.len > maxLen:
    result.add "..."
