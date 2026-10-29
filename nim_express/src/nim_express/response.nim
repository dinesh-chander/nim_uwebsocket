## Response helpers for nim_express
## Optimized with fast JSON serialization using nim_fastjson

import std/[strutils, json, os, asyncdispatch]
import std/times as stdtimes
import types
import request
import json_utils
import nim_utils/helpers/fast_map
import windowing
import paged_buffer
import compression_codec
import offload

export types

when defined(singleThread):
  var cachedDateLine: string
  var cachedDateSecond: int64
else:
  var cachedDateLine {.threadvar.}: string
  var cachedDateSecond {.threadvar.}: int64

proc getDateHeaderLine(): lent string {.inline.} =
  let now = getCachedEpochMs() div 1000
  if now != cachedDateSecond:
    cachedDateSecond = now
    let dt = stdtimes.fromUnix(now).utc()
    cachedDateLine = "date: " & dt.format("ddd, dd MMM yyyy HH:mm:ss") & " GMT\r\n"
  cachedDateLine

# Compression settings
const
  ## Minimum body size in bytes before compression is attempted.
  MinCompressSize* = 860  # Minimum bytes to compress (MTU - headers)
  ## Default compression level; 1-9, higher gives better but slower compression.
  CompressLevel* = 6      # 1-9, higher = better but slower
  ## Default payload size in bytes at which ``PageBuffer`` sends switch to chunked framing.
  DefaultChunkedPageBufferThreshold* = 256 * 1024
  ## Default byte threshold for adaptive contiguous single-write ``PageBuffer`` sends.
  DefaultAdaptiveContiguousPageBufferThreshold* = 96 * 1024
  ## Default byte threshold for adaptive chunked ``PageBuffer`` sends; equals ``DefaultChunkedPageBufferThreshold``.
  DefaultAdaptiveChunkedPageBufferThreshold* = DefaultChunkedPageBufferThreshold
  # Throughput-biased policy: prefer fixed-length framed writes; chunk only for very large payloads.
  ## Throughput-biased threshold: payloads at or below this use one contiguous framed write.
  DefaultThroughputContiguousPageBufferThreshold* = 32 * 1024
  ## Throughput-biased threshold: payloads at or above this use chunked transfer framing.
  DefaultThroughputChunkedPageBufferThreshold* = 32 * 1024 * 1024
  ## Default max compiled template plans kept in the per-thread template cache.
  DefaultTemplateCacheMaxEntries* = 256
  ## Default max bytes retained in the per-thread template cache.
  DefaultTemplateCacheMaxBytes* = 8 * 1024 * 1024
  ## Default max loaded view files kept in the per-thread view cache.
  DefaultViewCacheMaxEntries* = 256
  ## Default max bytes retained in the per-thread view cache.
  DefaultViewCacheMaxBytes* = 16 * 1024 * 1024
  HeaderContentType = "content-type"
  HeaderConnection = "connection"
  HeaderTransferEncoding = "transfer-encoding"
  HeaderSetCookie = "set-cookie"
  HeaderContentLength = "content-length"
  HeaderContentEncoding = "content-encoding"
  HeaderContentRange = "content-range"
  HeaderETag = "etag"
  HeaderIfNoneMatch = "if-none-match"
  HeaderCacheControl = "cache-control"
  HeaderXAccelBuffering = "x-accel-buffering"
  MimeTextUtf8 = "text/plain; charset=utf-8"
  MimeHtmlUtf8 = "text/html; charset=utf-8"
  MimeJsonUtf8 = "application/json; charset=utf-8"
  MimeProblemJsonUtf8 = "application/problem+json; charset=utf-8"
  MimeXmlUtf8 = "application/xml; charset=utf-8"
  MimeEventStreamUtf8 = "text/event-stream; charset=utf-8"
  HeaderLineTextContentType = "content-type: text/plain; charset=utf-8\r\n"
  HeaderLineJsonContentType = "content-type: application/json; charset=utf-8\r\n"
  HeaderLineHtmlContentType = "content-type: text/html; charset=utf-8\r\n"
  HeaderLineConnectionClose = "connection: close\r\n"
  HeaderLineConnectionKeepAlive = "connection: keep-alive\r\n"
  HeaderLineContentLengthPrefix = "content-length: "
  HeaderLineContentLengthZero = "content-length: 0\r\n"
  ResponseTemplate200TextKeepAlive = "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\nconnection: keep-alive\r\ncontent-length: "
  ResponseTemplate200TextClose = "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\nconnection: close\r\ncontent-length: "
  ResponseTemplate200JsonKeepAlive = "HTTP/1.1 200 OK\r\ncontent-type: application/json; charset=utf-8\r\nconnection: keep-alive\r\ncontent-length: "
  ResponseTemplate200JsonClose = "HTTP/1.1 200 OK\r\ncontent-type: application/json; charset=utf-8\r\nconnection: close\r\ncontent-length: "
  ResponseTemplate200HtmlKeepAlive = "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\nconnection: keep-alive\r\ncontent-length: "
  ResponseTemplate200HtmlClose = "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\nconnection: close\r\ncontent-length: "
  LocalEtagEnabled = "_etag_enabled"
  LocalEtagMode = "_etag_mode"
  LocalEtagAllowedMethods = "_etag_allowed_methods"
  LocalEtagRespectExisting = "_etag_respect_existing"
  LocalServerTimingEnabled = "_server_timing_enabled"
  LocalServerTimingStart = "_server_timing_start"
  LocalCompressMinBytes = "_compress_min_bytes"
  LocalCompressSkipPrecompressed = "_compress_skip_precompressed"

type
  ## Extra key/value member added to an RFC 7807 problem JSON body.
  ProblemDetailExtension* = tuple[key: string, value: string]

  ## Framing mode used when sending a ``PageBuffer`` body.
  PageBufferSendMode* = enum
    pbsmAuto
    pbsmContiguous
    pbsmTryEnd
    pbsmChunked

  ## Thresholds and mode controlling how a ``PageBuffer`` body is framed and sent.
  PageBufferSendPolicy* = object
    ## Framing mode; ``pbsmAuto`` selects from the byte thresholds below.
    mode*: PageBufferSendMode
    ## Payloads at or below this size use a single contiguous write.
    contiguousThresholdBytes*: int
    ## Payloads at or above this size use chunked transfer framing.
    chunkedThresholdBytes*: int

  ## Fast JSON string builder that avoids ``JsonNode`` overhead.
  JsonBuilder* = object
    buf: string

# Pre-computed status lines for fast response building
## Pre-computed HTTP/1.1 status lines indexed by status code 100..599.
const StatusLines*: array[100..599, string] = block:
  var arr: array[100..599, string]
  arr[100] = "HTTP/1.1 100 Continue\r\n"
  arr[101] = "HTTP/1.1 101 Switching Protocols\r\n"
  arr[200] = "HTTP/1.1 200 OK\r\n"
  arr[201] = "HTTP/1.1 201 Created\r\n"
  arr[204] = "HTTP/1.1 204 No Content\r\n"
  arr[205] = "HTTP/1.1 205 Reset Content\r\n"
  arr[206] = "HTTP/1.1 206 Partial Content\r\n"
  arr[301] = "HTTP/1.1 301 Moved Permanently\r\n"
  arr[302] = "HTTP/1.1 302 Found\r\n"
  arr[304] = "HTTP/1.1 304 Not Modified\r\n"
  arr[307] = "HTTP/1.1 307 Temporary Redirect\r\n"
  arr[308] = "HTTP/1.1 308 Permanent Redirect\r\n"
  arr[400] = "HTTP/1.1 400 Bad Request\r\n"
  arr[401] = "HTTP/1.1 401 Unauthorized\r\n"
  arr[403] = "HTTP/1.1 403 Forbidden\r\n"
  arr[404] = "HTTP/1.1 404 Not Found\r\n"
  arr[405] = "HTTP/1.1 405 Method Not Allowed\r\n"
  arr[409] = "HTTP/1.1 409 Conflict\r\n"
  arr[410] = "HTTP/1.1 410 Gone\r\n"
  arr[413] = "HTTP/1.1 413 Content Too Large\r\n"
  arr[415] = "HTTP/1.1 415 Unsupported Media Type\r\n"
  arr[416] = "HTTP/1.1 416 Range Not Satisfiable\r\n"
  arr[422] = "HTTP/1.1 422 Unprocessable Content\r\n"
  arr[426] = "HTTP/1.1 426 Upgrade Required\r\n"
  arr[429] = "HTTP/1.1 429 Too Many Requests\r\n"
  arr[451] = "HTTP/1.1 451 Unavailable For Legal Reasons\r\n"
  arr[500] = "HTTP/1.1 500 Internal Server Error\r\n"
  arr[501] = "HTTP/1.1 501 Not Implemented\r\n"
  arr[502] = "HTTP/1.1 502 Bad Gateway\r\n"
  arr[503] = "HTTP/1.1 503 Service Unavailable\r\n"
  arr[504] = "HTTP/1.1 504 Gateway Timeout\r\n"
  arr[505] = "HTTP/1.1 505 HTTP Version Not Supported\r\n"
  arr

## Append ``n`` to ``buf`` as a decimal integer with no intermediate string.
proc fastIntToStr*(n: int, buf: var string) {.inline.} =
  if n == 0:
    buf.add('0')
    return
  var num = n.int64
  if num < 0:
    if num == low(int64):
      buf.add("-9223372036854775808")
      return
    buf.add('-')
    num = -num
  var digits: array[24, char]
  var p = 0
  while num >= 10:
    let d = int(num mod 10)
    digits[p] = char(ord('0') + d)
    inc p
    num = num div 10
  digits[p] = char(ord('0') + int(num))
  inc p
  let at = buf.len
  buf.setLen(at + p)
  var dst = at
  var i = p - 1
  while i >= 0:
    buf[dst] = digits[i]
    inc dst
    dec i

## Return the pre-computed HTTP/1.1 status line for ``code``.
proc getStatusLine*(code: int): string {.inline.} =
  if code >= 100 and code <= 599 and StatusLines[code].len > 0:
    return StatusLines[code]
  var line = newStringOfCap(32)
  line.add("HTTP/1.1 ")
  fastIntToStr(code, line)
  line.add(" Unknown\r\n")
  return line

proc ensureHeadersInited(res: Response) {.inline.} =
  if not res.headersInited:
    res.headers = newFastMap[string]()
    discard res.headers.reserve(8)
    res.headersInited = true

proc applyServerTimingHeader(res: Response) {.inline.} =
  if res == nil or res.request == nil:
    return
  if res.request.locals == nil or res.request.locals.len == 0:
    return
  let startRaw = res.request.locals.getOrDefault(LocalServerTimingStart, "")
  if startRaw.len == 0:
    return
  let enabledRaw = res.request.locals.getOrDefault(LocalServerTimingEnabled, "")
  if enabledRaw != "1":
    return
  try:
    let startMicros = parseInt(startRaw)
    let totalMs = float(getCachedEpochMicros() - int64(startMicros)) / 1000.0
    let durStr = if totalMs < 0.001: "0.001"
                 elif totalMs < 1000.0: formatFloat(totalMs, ffDecimal, 3)
                 else: formatFloat(totalMs, ffDecimal, 1)
    res.ensureHeadersInited()
    res.headers["server-timing"] = "total;dur=" & durStr
  except ValueError:
    discard

proc hasHeaderToken(value, token: string): bool {.inline.} =
  if value.len == 0 or token.len == 0:
    return false
  var i = 0
  while i < value.len:
    while i < value.len and (value[i] == ' ' or value[i] == '\t' or value[i] == ','):
      inc i
    if i >= value.len:
      break

    let start = i
    while i < value.len and value[i] != ',':
      inc i
    var last = i - 1
    while last >= start and (value[last] == ' ' or value[last] == '\t'):
      dec last

    if last >= start and (last - start + 1) == token.len:
      var matched = true
      for j in 0..<token.len:
        if value[start + j].toLowerAscii() != token[j]:
          matched = false
          break
      if matched:
        return true
  false

proc hasHeaderToken(value: fast_map.FastStringView, token: string): bool {.inline.} =
  if value.len == 0 or token.len == 0 or value.data == nil:
    return false
  let chars = cast[ptr UncheckedArray[char]](value.data)
  var i = 0
  while i < value.len:
    while i < value.len and (chars[i] == ' ' or chars[i] == '\t' or chars[i] == ','):
      inc i
    if i >= value.len:
      break

    let start = i
    while i < value.len and chars[i] != ',':
      inc i
    var last = i - 1
    while last >= start and (chars[last] == ' ' or chars[last] == '\t'):
      dec last

    if last >= start and (last - start + 1) == token.len:
      var matched = true
      for j in 0..<token.len:
        var c = chars[start + j]
        if c in 'A'..'Z':
          c = chr(ord(c) + 32)
        if c != token[j]:
          matched = false
          break
      if matched:
        return true
  false

proc stableHash64(content: string): uint64 =
  var h = 0xcbf29ce484222325'u64
  for c in content:
    h = h xor uint64(ord(c))
    h = h * 0x100000001b3'u64
  h

proc stripWeakPrefix(etag: string): string {.inline.} =
  let trimmed = etag.strip()
  if trimmed.len >= 2 and (trimmed.startsWith("W/") or trimmed.startsWith("w/")):
    return trimmed[2..^1].strip()
  trimmed

proc weakEtagEqual(a, b: string): bool {.inline.} =
  stripWeakPrefix(a) == stripWeakPrefix(b)

proc ifNoneMatchMatches(ifNoneMatch, etag: string): bool =
  let header = ifNoneMatch.strip()
  if header.len == 0 or etag.len == 0:
    return false
  if header == "*":
    return true
  for token in header.split(','):
    let candidate = token.strip()
    if candidate.len == 0:
      continue
    if candidate == "*":
      return true
    if weakEtagEqual(candidate, etag):
      return true
  false

proc methodToken(methodKind: HttpMethod): string {.inline.} =
  case methodKind
  of hmGet: "GET"
  of hmPost: "POST"
  of hmPut: "PUT"
  of hmDelete: "DELETE"
  of hmPatch: "PATCH"
  of hmHead: "HEAD"
  of hmOptions: "OPTIONS"
  of hmConnect: "CONNECT"
  of hmTrace: "TRACE"

proc methodAllowedByCsv(methodKind: HttpMethod, allowedCsv: string): bool =
  if allowedCsv.len == 0:
    return methodKind == hmGet or methodKind == hmHead
  let token = methodToken(methodKind)
  for entry in allowedCsv.split(','):
    if entry.strip().cmpIgnoreCase(token) == 0:
      return true
  false

proc generateBodyEtag(body: string, strong: bool): string =
  var payload = newStringOfCap(32)
  fastIntToStr(body.len, payload)
  payload.add(':')
  payload.add(toHex(stableHash64(body), 16))
  if strong:
    "\"" & payload & "\""
  else:
    "W/\"" & payload & "\""

proc applyEtagPolicy(
  res: Response,
  validatorBody: string,
  body: var string,
  noBody: var bool
) =
  if res == nil or res.request == nil:
    return
  if res.statusCode < 200 or res.statusCode >= 300:
    return

  var middlewareEnabled = false
  var strong = false
  var allowedCsv = ""
  var respectExisting = true
  if res.locals != nil and res.locals.len > 0:
    middlewareEnabled = res.locals.getOrDefault(LocalEtagEnabled, "") == "1"
    strong = res.locals.getOrDefault(LocalEtagMode, "") == "strong"
    allowedCsv = res.locals.getOrDefault(LocalEtagAllowedMethods, "")
    let respectRaw = res.locals.getOrDefault(LocalEtagRespectExisting, "")
    respectExisting = respectRaw.len == 0 or respectRaw != "0"

  var hasExplicit = false
  var etagValue = ""
  if res.headersInited:
    hasExplicit = res.headers.contains(HeaderETag)
    if hasExplicit:
      etagValue = res.headers.getOrDefault(HeaderETag, "")

  if not middlewareEnabled and not hasExplicit:
    return
  if not methodAllowedByCsv(res.requestMethodKind, allowedCsv):
    return

  if not (hasExplicit and respectExisting):
    etagValue = generateBodyEtag(validatorBody, strong)
    res.ensureHeadersInited()
    res.headers[HeaderETag] = etagValue
    hasExplicit = true

  if not hasExplicit or etagValue.len == 0:
    return

  res.request.bindHeaders()
  let ifNoneMatch = res.request.headers.getOrDefault(HeaderIfNoneMatch, "")
  if ifNoneMatchMatches(ifNoneMatch, etagValue):
    res.statusCode = 304
    noBody = true
    body.setLen(0)
    if res.headersInited:
      discard res.headers.del(HeaderContentLength)
      discard res.headers.del(HeaderTransferEncoding)
      discard res.headers.del(HeaderContentType)

proc isSetCookieHeader(header: string): bool {.inline.} =
  header.len == HeaderSetCookie.len and header.cmpIgnoreCase(HeaderSetCookie) == 0

proc isTransferEncodingHeader(header: string): bool {.inline.} =
  header.len == HeaderTransferEncoding.len and header.cmpIgnoreCase(HeaderTransferEncoding) == 0

proc isHeaderTokenChar(c: char): bool {.inline.} =
  (c >= 'a' and c <= 'z') or
  (c >= 'A' and c <= 'Z') or
  (c >= '0' and c <= '9') or
  c in {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'}

## Return ``header`` lowercased if it is a valid header token, else "".
proc sanitizeHeaderName*(header: string): string {.inline.} =
  if header.len == 0:
    return ""
  var hasUpper = false
  for c in header:
    if not c.isHeaderTokenChar():
      return ""
    if c in 'A'..'Z':
      hasUpper = true
  if hasUpper:
    header.toLowerAscii()
  else:
    header

proc hasUnsafeHeaderValueBytes(value: string): bool {.inline.} =
  for c in value:
    # RFC 9110 field-value bytes: HTAB / SP / VCHAR / obs-text.
    # Reject all other control bytes (including NUL, CR, LF, DEL).
    let b = ord(c)
    if b == 0x09 or b == 0x20:
      continue
    if b >= 0x21 and b <= 0x7E:
      continue
    if b >= 0x80:
      continue
    return true
  false

## Return ``value`` if it is a safe header field-value, else "".
proc sanitizeHeaderValue*(value: string): string {.inline.} =
  if value.hasUnsafeHeaderValueBytes():
    return ""
  value

proc sanitizeCookieName(name: string): string {.inline.} =
  if name.len == 0:
    return ""
  for c in name:
    if not c.isHeaderTokenChar():
      return ""
  name

proc sanitizeCookieValue(value: string): string {.inline.} =
  for c in value:
    if c == '\r' or c == '\n' or c == '\0' or c == ';':
      return ""
  value

proc sanitizeCookieAttrValue(value: string): string {.inline.} =
  for c in value:
    if c == '\r' or c == '\n' or c == '\0' or c == ';':
      return ""
  value

proc appendSetCookieHeaders(response: var string, res: Response) {.inline.} =
  if res.setCookies.len == 0:
    return
  for cookie in res.setCookies:
    if cookie.hasUnsafeHeaderValueBytes():
      continue
    response.add(HeaderSetCookie)
    response.add(": ")
    response.add(cookie)
    response.add("\r\n")

proc statusDisallowsBody(code: int): bool {.inline.} =
  (code >= 100 and code < 200) or code == 204 or code == 205 or code == 304

proc responseDisallowsBody(res: Response): bool {.inline.} =
  # RFC 9110 §6.4.1 and §9.3.2 / §9.3.6:
  # no content for HEAD, 1xx, 204, 205, 304, and successful CONNECT.
  if res.statusCode.statusDisallowsBody():
    return true
  let methodKind = res.requestMethodKind
  if methodKind == hmHead:
    return true
  methodKind == hmConnect and res.statusCode >= 200 and res.statusCode < 300

proc headRepresentationLength(res: Response, bodyLen: int): int {.inline.} =
  if res != nil and res.requestMethodKind == hmHead and not res.statusCode.statusDisallowsBody():
    bodyLen
  else:
    -1

proc omitContentTypeForNoBody(res: Response, noBody: bool): bool {.inline.} =
  noBody and res != nil and res.requestMethodKind != hmHead

proc selectResponseTemplate(
  defaultContentTypeLine: string,
  shouldClose: bool
): string {.inline.} =
  if defaultContentTypeLine.len == HeaderLineTextContentType.len and
     defaultContentTypeLine == HeaderLineTextContentType:
    if shouldClose: ResponseTemplate200TextClose
    else: ResponseTemplate200TextKeepAlive
  elif defaultContentTypeLine.len == HeaderLineJsonContentType.len and
       defaultContentTypeLine == HeaderLineJsonContentType:
    if shouldClose: ResponseTemplate200JsonClose
    else: ResponseTemplate200JsonKeepAlive
  elif defaultContentTypeLine.len == HeaderLineHtmlContentType.len and
       defaultContentTypeLine == HeaderLineHtmlContentType:
    if shouldClose: ResponseTemplate200HtmlClose
    else: ResponseTemplate200HtmlKeepAlive
  else:
    ""

proc trySendSimpleFramedResponse(
  res: Response,
  body: string,
  noBody: bool,
  defaultContentTypeLine: string,
  representationLength: int = -1
): bool {.inline.} =
  if res == nil or res.native == nil:
    return false
  if res.headersInited or res.setCookies.len > 0:
    return false

  let shouldClose = res.native.connectionCloseEnabled()
  let dateLine = getDateHeaderLine()
  let contentTypeLine =
    if res.omitContentTypeForNoBody(noBody): ""
    else: defaultContentTypeLine

  if res.statusCode == 200 and not noBody:
    let tmpl = selectResponseTemplate(defaultContentTypeLine, shouldClose)
    if tmpl.len > 0:
      res.headerBuf.setLen(tmpl.len)
      copyMem(addr res.headerBuf[0], unsafeAddr tmpl[0], tmpl.len)
      fastIntToStr(body.len, res.headerBuf)
      var pos = res.headerBuf.len
      let tailLen = dateLine.len + 4
      res.headerBuf.setLen(pos + tailLen)
      res.headerBuf[pos] = '\r'; res.headerBuf[pos + 1] = '\n'; pos += 2
      if dateLine.len > 0:
        copyMem(addr res.headerBuf[pos], unsafeAddr dateLine[0], dateLine.len)
        pos += dateLine.len
      res.headerBuf[pos] = '\r'; res.headerBuf[pos + 1] = '\n'; pos += 2
      res.native.sendPreparedResponse(res.headerBuf, body, shouldClose)
      res.native.markBodySent()
      return true

  let statusLine = if res.statusCode == 200: StatusLines[200] else: getStatusLine(res.statusCode)
  let connLine = if shouldClose: HeaderLineConnectionClose else: HeaderLineConnectionKeepAlive
  let clPrefix = if noBody and res.statusCode == 205: HeaderLineContentLengthZero
                 elif noBody and representationLength >= 0: HeaderLineContentLengthPrefix
                 elif noBody: ""
                 else: HeaderLineContentLengthPrefix

  res.headerBuf.setLen(statusLine.len + contentTypeLine.len + connLine.len)
  var pos = 0
  if statusLine.len > 0:
    copyMem(addr res.headerBuf[pos], unsafeAddr statusLine[0], statusLine.len)
    pos += statusLine.len
  if contentTypeLine.len > 0:
    copyMem(addr res.headerBuf[pos], unsafeAddr contentTypeLine[0], contentTypeLine.len)
    pos += contentTypeLine.len
  if connLine.len > 0:
    copyMem(addr res.headerBuf[pos], unsafeAddr connLine[0], connLine.len)
    pos += connLine.len
  res.headerBuf.setLen(pos)
  if clPrefix.len > 0 and not noBody:
    res.headerBuf.add(clPrefix)
    fastIntToStr(body.len, res.headerBuf)
    res.headerBuf.add("\r\n")
  elif noBody and representationLength >= 0:
    res.headerBuf.add(clPrefix)
    fastIntToStr(representationLength, res.headerBuf)
    res.headerBuf.add("\r\n")
  elif noBody and res.statusCode == 205:
    res.headerBuf.add(clPrefix)
  pos = res.headerBuf.len
  let tailLen = dateLine.len + 2
  res.headerBuf.setLen(pos + tailLen)
  if dateLine.len > 0:
    copyMem(addr res.headerBuf[pos], unsafeAddr dateLine[0], dateLine.len)
    pos += dateLine.len
  res.headerBuf[pos] = '\r'; res.headerBuf[pos + 1] = '\n'; pos += 2
  res.headerBuf.setLen(pos)
  if noBody:
    res.native.sendPreparedResponse(res.headerBuf, "", shouldClose)
  else:
    res.native.sendPreparedResponse(res.headerBuf, body, shouldClose)
  res.native.markBodySent()
  true

proc shouldDropLateWrite(res: Response): bool {.inline.} =
  if res == nil or res.native == nil:
    return true
  if res.request != nil and (res.request.requestCancelled() or res.request.requestReleased()):
    inc res.droppedLateWrites
    return true
  false

## Register a closure to run once, just before the response is finalized.
proc addBeforeFinalizeHook*(res: Response, hook: proc() {.closure.}) {.inline.} =
  if res == nil or hook == nil:
    return
  res.beforeFinalizeHooks.add(hook)

proc runBeforeFinalizeHooks(res: Response) {.inline.} =
  if res == nil or res.beforeFinalizeHooks.len == 0:
    return
  let hooks = res.beforeFinalizeHooks
  res.beforeFinalizeHooks.setLen(0)
  for hook in hooks:
    if hook == nil:
      continue
    try:
      hook()
    except CatchableError:
      discard

## Number of writes dropped because the client connection was already gone.
proc droppedLateWritesCount*(res: Response): int {.inline.} =
  if res == nil:
    return 0
  res.droppedLateWrites

## Terminal writer: send ``body`` as text/plain and finalize the response; later writes are dropped.
proc send*(res: Response, body: sink string = "")
## Terminal writer: send ``body`` as text/html and finalize the response; later writes are dropped.
proc sendHtmlBody*(res: Response, body: sink string) {.inline.}

# Status setting
## Set the response status code; returns ``res`` for chaining.
proc status*(res: Response, code: int): Response {.inline, discardable.} =
  if res.finished:
    return res
  res.statusCode = code
  return res

proc reasonPhraseFromStatusCode(code: int): string {.inline.} =
  let statusLine = getStatusLine(code)
  let firstSpace = statusLine.find(' ')
  if firstSpace < 0:
    return "Unknown"
  let secondSpace = statusLine.find(' ', firstSpace + 1)
  if secondSpace < 0:
    return "Unknown"
  var finish = statusLine.len
  if finish >= 2 and statusLine[finish - 2] == '\r' and statusLine[finish - 1] == '\n':
    finish -= 2
  if secondSpace + 1 >= finish:
    return "Unknown"
  statusLine[secondSpace + 1 ..< finish]

proc isReservedProblemKey(key: string): bool {.inline.} =
  let normalized = key.toLowerAscii()
  normalized == "type" or normalized == "title" or normalized == "status" or
    normalized == "detail" or normalized == "instance"

# Header methods
## Set response header ``header`` to ``value``, replacing any existing value.
proc set*(res: Response, header: string, value: string): Response {.inline, discardable.} =
  if res.finished:
    return res
  let key = sanitizeHeaderName(header)
  if key.len == 0:
    return res
  let safeValue = sanitizeHeaderValue(value)
  if value.len > 0 and safeValue.len == 0:
    return res
  if key.isSetCookieHeader():
    res.setCookies.setLen(0)
    res.setCookies.add(safeValue)
    return res
  if key.isTransferEncodingHeader():
    return res
  res.ensureHeadersInited()
  res.headers[key] = safeValue
  return res

## Like ``set`` but for pre-validated values; skips value sanitization.
proc setTrusted*(res: Response, key: string, value: string): Response {.inline, discardable.} =
  if res.finished:
    return res
  let safeKey = sanitizeHeaderName(key)
  if safeKey.len == 0 or safeKey.isTransferEncodingHeader():
    return res
  for c in value:
    if c == '\r' or c == '\n' or c == '\0':
      return res
  if safeKey.isSetCookieHeader():
    res.setCookies.setLen(0)
    res.setCookies.add(value)
    return res
  res.ensureHeadersInited()
  res.headers[safeKey] = value
  return res

## Return the current value of response header ``header``, or "" if unset.
proc fastContentTypeValue(kind: FastContentType): string {.inline.} =
  case kind
  of fctNone: ""
  of fctJson: MimeJsonUtf8

proc get*(res: Response, header: string): string {.inline.} =
  let key = sanitizeHeaderName(header)
  if key.len == 0:
    return ""
  if key.isSetCookieHeader():
    if res.setCookies.len > 0:
      return res.setCookies[0]
    return ""
  if res.headersInited and res.headers.contains(key):
    return res.headers.getOrDefault(key, "")
  if key == HeaderContentType:
    return res.defaultContentType.fastContentTypeValue()
  ""

## Return a zero-copy view of response header ``header``.
proc getView*(res: Response, header: string): fast_map.FastStringView {.inline.} =
  let key = sanitizeHeaderName(header)
  if key.len == 0:
    return default(fast_map.FastStringView)
  if key.isSetCookieHeader():
    if res.setCookies.len == 0:
      return default(fast_map.FastStringView)
    return fast_map.toFastStringView(res.setCookies[0])
  if res.headersInited and res.headers.contains(key):
    return res.headers.getView(key)
  if key == HeaderContentType and res.defaultContentType == fctJson:
    return fast_map.toFastStringView(MimeJsonUtf8)
  default(fast_map.FastStringView)

## Append ``value`` to response header ``header``, comma-joining with any existing value.
proc append*(res: Response, header: string, value: string): Response {.inline, discardable.} =
  if res.finished:
    return res
  let key = sanitizeHeaderName(header)
  if key.len == 0:
    return res
  let safeValue = sanitizeHeaderValue(value)
  if value.len > 0 and safeValue.len == 0:
    return res
  if key.isSetCookieHeader():
    res.setCookies.add(safeValue)
    return res
  if key.isTransferEncodingHeader():
    return res
  let existing =
    if not res.headersInited: ""
    else: res.headers.getOrDefault(key, "")
  res.ensureHeadersInited()
  if existing.len > 0:
    res.headers[key] = existing & ", " & safeValue
  else:
    res.headers[key] = safeValue
  return res

## Set or append RFC 8288 Link header values from (rel, url) pairs.
proc links*(res: Response, entries: openArray[(string, string)]): Response {.discardable.} =
  if res.finished:
    return res
  var first = true
  for entry in entries:
    let rel = entry[0].strip()
    let url = entry[1].strip()
    if rel.len == 0 or url.len == 0:
      continue
    var safeRel = newStringOfCap(rel.len)
    for c in rel:
      if c == '"' or c == '\\':
        safeRel.add('\\')
      safeRel.add(c)
    var safeUrl = newStringOfCap(url.len)
    for c in url:
      if c == '>' or c == '<':
        continue
      safeUrl.add(c)
    let value = "<" & safeUrl & ">; rel=\"" & safeRel & "\""
    if first:
      discard res.set("Link", value)
      first = false
    else:
      discard res.append("Link", value)
  res

## Content-negotiate the Accept header against ``handlers`` and run the first matching handler.
proc format*(
  res: Response,
  req: Request,
  handlers: openArray[(string, proc() {.closure.})],
  defaultHandler: proc() {.closure.} = nil
): bool =
  ## Content negotiation helper similar to Express res.format().
  if req == nil:
    if defaultHandler != nil:
      defaultHandler()
      return true
    res.status(406)
    res.send("Not Acceptable")
    return false
  var offers: seq[string] = @[]
  for handler in handlers:
    let mime = handler[0].toLowerAscii().strip()
    if mime.len == 0:
      continue
    offers.add(mime)

  let selected = req.accepts(offers)
  if selected.len > 0:
    let selectedLower = selected.toLowerAscii()
    for handler in handlers:
      let mime = handler[0].toLowerAscii().strip()
      if mime == selectedLower:
        handler[1]()
        return true
  if defaultHandler != nil:
    defaultHandler()
    return true
  res.status(406)
  res.send("Not Acceptable")
  false

## Remove response header ``header``; for Set-Cookie this clears all queued cookies.
proc removeHeader*(res: Response, header: string): Response {.inline, discardable.} =
  if res.finished:
    return res
  let key = sanitizeHeaderName(header)
  if key.len == 0:
    return res
  if key.isSetCookieHeader():
    res.setCookies.setLen(0)
    return res
  if key == HeaderContentType:
    res.defaultContentType = fctNone
  if res.headersInited:
    discard res.headers.del(key)
  return res

## Set the Content-Type response header to ``ct``.
proc contentType*(res: Response, ct: string): Response {.inline, discardable.} =
  if res.finished:
    return res
  res.set(HeaderContentType, ct)

# Cookie setting
## Queue a Set-Cookie header with the given name, value, and cookie attributes.
proc cookie*(res: Response, name: string, value: string,
             maxAge: int = 0, path: string = "/",
             domain: string = "", secure: bool = false,
             httpOnly: bool = true, sameSite: string = "Lax"): Response {.discardable.} =
  if res.finished:
    return res
  let safeName = sanitizeCookieName(name)
  if safeName.len == 0:
    return res
  let safeValue = sanitizeCookieValue(value)
  if value.len > 0 and safeValue.len == 0:
    return res
  let safePath = sanitizeCookieAttrValue(path)
  if safePath.len == 0:
    return res
  let safeDomain =
    if domain.len == 0:
      ""
    else:
      sanitizeCookieAttrValue(domain)
  if domain.len > 0 and safeDomain.len == 0:
    return res
  let safeSameSite =
    if sameSite.len == 0:
      ""
    else:
      sanitizeCookieAttrValue(sameSite)
  if sameSite.len > 0 and safeSameSite.len == 0:
    return res

  var cookie = safeName & "=" & safeValue
  if maxAge != 0:
    cookie.add("; Max-Age=")
    fastIntToStr(maxAge, cookie)
    if maxAge <= 0:
      cookie.add("; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
  cookie.add("; Path=" & safePath)
  if safeDomain.len > 0:
    cookie.add("; Domain=" & safeDomain)
  if secure:
    cookie.add("; Secure")
  if httpOnly:
    cookie.add("; HttpOnly")
  if safeSameSite.len > 0:
    cookie.add("; SameSite=" & safeSameSite)
  res.append(HeaderSetCookie, cookie)
  return res

## Queue a Set-Cookie header that expires ``name`` via a past Max-Age.
proc clearCookie*(
  res: Response,
  name: string,
  path: string = "/",
  domain: string = ""
): Response {.inline, discardable.} =
  res.cookie(name, "", maxAge = -1, path = path, domain = domain)

proc emitCompressionBypass(app: ExpressApp, req: Request, reason: string) {.inline.} =
  if app != nil and app.compressionBypassHook != nil:
    try:
      app.compressionBypassHook(req, reason)
    except CatchableError:
      discard

proc compressPayloadWithPolicy(
  res: Response,
  req: Request,
  body: string,
  encoding: CompressionEncoding,
  level: int,
  contentType: string
): tuple[ok: bool, compressed: string] =
  result.ok = true
  result.compressed = compressPayload(body, encoding, level, contentType)

proc responseHasExistingContentEncoding(res: Response): bool {.inline.} =
  if res == nil or not res.headersInited:
    return false
  let contentEncoding = res.headers.getOrDefault(HeaderContentEncoding, "")
  if contentEncoding.len == 0:
    return false
  let lower = contentEncoding.strip().toLowerAscii()
  if lower == "identity":
    return false
  # Strip `;param` suffixes before matching tokens.
  for part in lower.split(','):
    var tok = part.strip()
    let semi = tok.find(';')
    if semi >= 0:
      tok = tok[0..<semi].strip()
    if tok.len > 0 and tok != "identity":
      return true
  false

proc responseShouldSkipPrecompressedMime(res: Response, contentType: string): bool {.inline.} =
  if contentType.len == 0:
    return false
  let local =
    if res != nil and res.locals != nil:
      res.locals.getOrDefault(LocalCompressSkipPrecompressed, "")
    else:
      ""
  if local == "0":
    return false
  let token = contentTypeToken(contentType)
  for mime in PrecompressedMimeTypes:
    if token == mime:
      return true
  false

proc responseCompressionForbiddenByHeaders(res: Response): string {.inline.} =
  if res == nil:
    return ""
  if res.statusCode == 206:
    return "partial_content"
  if res.headersInited:
    if res.headers.getOrDefault(HeaderContentRange, "").len > 0:
      return "content_range"
    if hasHeaderToken(res.headers.getView(HeaderCacheControl), "no-transform"):
      return "no_transform"
  ""

proc responseLocalCompressionMinBytes(res: Response): int {.inline.} =
  if res == nil or res.locals == nil:
    return 0
  let raw = res.locals.getOrDefault(LocalCompressMinBytes, "")
  if raw.len == 0:
    return 0
  try:
    max(0, parseInt(raw))
  except ValueError:
    0

proc maybeCompressBody(res: Response, body: string, contentType: string = ""): string =
  result = body
  if res == nil or body.len == 0 or res.responseDisallowsBody():
    return
  if not res.compress:
    return
  if res.responseHasExistingContentEncoding():
    emitCompressionBypass(res.app, nil, "already_encoded")
    return
  let forbiddenReason = res.responseCompressionForbiddenByHeaders()
  if forbiddenReason.len > 0:
    emitCompressionBypass(res.app, nil, forbiddenReason)
    return
  if res.responseShouldSkipPrecompressedMime(contentType):
    emitCompressionBypass(res.app, nil, "precompressed_mime")
    return

  let app = res.app
  if app != nil and not app.compressionPolicy.enabled:
    emitCompressionBypass(app, nil, "disabled_policy")
    return

  let localMin = res.responseLocalCompressionMinBytes()
  let minBytes =
    if localMin > 0:
      localMin
    elif app != nil and app.compressionPolicy.minBytes > 0:
      app.compressionPolicy.minBytes
    else:
      MinCompressSize
  if body.len < minBytes:
    emitCompressionBypass(app, nil, "body_too_small")
    return

  var hookReq: Request = nil
  let nativeReq = if res.native != nil: res.native.requestHandle() else: nil
  if app != nil:
    let needsCompressionHookRequest =
      app.shouldCompressHook != nil or app.selectCompressionProfileHook != nil or
      app.compressionResultHook != nil or app.compressionBypassHook != nil
    if needsCompressionHookRequest:
      hookReq =
        if res.request != nil:
          res.request
        elif nativeReq != nil:
          acquireBorrowedRequest(nativeReq)
        else:
          nil
  defer:
    if hookReq != nil and hookReq != res.request:
      releaseRequest(hookReq)

  if app != nil and app.shouldCompressHook != nil:
    var shouldCompress = false
    try:
      shouldCompress = app.shouldCompressHook(hookReq, contentType, body.len)
    except CatchableError:
      app.emitCompressionBypass(hookReq, "hook_error")
      return
    if not shouldCompress:
      app.emitCompressionBypass(hookReq, "hook_rejected")
      return

  var level = if app != nil and app.compressionPolicy.level > 0: app.compressionPolicy.level else: CompressLevel
  if app != nil and app.selectCompressionProfileHook != nil:
    var profile = ""
    try:
      profile = app.selectCompressionProfileHook(hookReq, contentType, body.len).toLowerAscii()
    except CatchableError:
      app.emitCompressionBypass(hookReq, "profile_hook_error")
      return
    case profile
    of "fast": level = 3
    of "balanced": level = 6
    of "best": level = 9
    else: discard

  var encoding =
    if res.compressEncoding.len > 0:
      encodingFromToken(res.compressEncoding)
    else:
      ceGzip
  if encoding == ceNone:
    app.emitCompressionBypass(hookReq, "unsupported_encoding")
    return

  let startedMicros = getCachedEpochMicros()
  try:
    let compression = compressPayloadWithPolicy(res, hookReq, body, encoding, level, contentType)
    if not compression.ok:
      return
    let compressed = compression.compressed

    if compressed.len >= body.len:
      app.emitCompressionBypass(hookReq, "no_savings")
      return

    let ratio = float(body.len - compressed.len) / float(body.len)
    if app != nil and app.compressionPolicy.minSavingsRatio > 0 and ratio < app.compressionPolicy.minSavingsRatio:
      app.emitCompressionBypass(hookReq, "savings_below_threshold")
      return

    res.ensureHeadersInited()
    res.headers[HeaderContentEncoding] = headerValue(encoding)
    let varyExisting = res.headers.getView("vary")
    if varyExisting.data == nil or varyExisting.len == 0:
      res.headers["vary"] = "Accept-Encoding"
    elif not hasHeaderToken(varyExisting, "accept-encoding"):
      res.headers["vary"] = $varyExisting & ", Accept-Encoding"
    if app != nil and app.compressionResultHook != nil:
      let elapsed = max(0'i64, getCachedEpochMicros() - startedMicros)
      try:
        app.compressionResultHook(hookReq, body.len, compressed.len, elapsed, ratio)
      except CatchableError:
        discard
    result = compressed
  except CatchableError:
    app.emitCompressionBypass(hookReq, "compress_error")

# Core send with optional gzip compression
## Terminal writer: send ``body`` as text/plain and finalize the response; later writes are dropped.
proc send*(res: Response, body: sink string = "") =
  if res.shouldDropLateWrite():
    return
  if res.finished:
    return
  res.runBeforeFinalizeHooks()
  res.finished = true
  res.applyServerTimingHeader()

  var outputBody = body
  var noBody = res.responseDisallowsBody()
  if not noBody:
    let ct = if res.headersInited: res.headers.getOrDefault(HeaderContentType, MimeTextUtf8) else: MimeTextUtf8
    outputBody = res.maybeCompressBody(body, ct)
  let representationLength = res.headRepresentationLength(outputBody.len)
  var validatorBody = outputBody
  if noBody and res.requestMethodKind == hmHead:
    validatorBody = body
  res.applyEtagPolicy(validatorBody, outputBody, noBody)
  if noBody:
    outputBody = ""
  if res.trySendSimpleFramedResponse(outputBody, noBody, HeaderLineTextContentType, representationLength):
    return

  res.headerBuf.setLen(0)
  res.headerBuf.add(getStatusLine(res.statusCode))

  var hasContentType = false
  var hasContentLength = false
  var hasConnection = false
  var shouldClose = res.native.connectionCloseEnabled()
  let preserveExplicitContentLength = noBody and res.requestMethodKind == hmHead
  let omitContentType = res.omitContentTypeForNoBody(noBody)

  if res.headersInited and res.headers.len > 0:
    for k, v in res.headers:
      if k == HeaderTransferEncoding:
        continue
      if k == HeaderContentType and omitContentType:
        continue
      if k == HeaderContentLength and not preserveExplicitContentLength:
        continue
      res.headerBuf.add(k)
      res.headerBuf.add(": ")
      res.headerBuf.add(v)
      res.headerBuf.add("\r\n")
      if k == HeaderContentType:
        hasContentType = true
      elif k == HeaderContentLength:
        hasContentLength = true
      elif k == HeaderConnection:
        hasConnection = true
        shouldClose = hasHeaderToken(v, "close")
  appendSetCookieHeaders(res.headerBuf, res)

  if not hasContentType and not omitContentType:
    res.headerBuf.add(HeaderLineTextContentType)
  if not hasConnection:
    if shouldClose:
      res.headerBuf.add(HeaderLineConnectionClose)
    else:
      res.headerBuf.add(HeaderLineConnectionKeepAlive)

  if noBody:
    if res.statusCode == 205:
      res.headerBuf.add(HeaderLineContentLengthZero)
    elif representationLength >= 0 and not hasContentLength:
      res.headerBuf.add(HeaderLineContentLengthPrefix)
      fastIntToStr(representationLength, res.headerBuf)
      res.headerBuf.add("\r\n")
  else:
    res.headerBuf.add(HeaderLineContentLengthPrefix)
    fastIntToStr(outputBody.len, res.headerBuf)
    res.headerBuf.add("\r\n")

  res.headerBuf.add(getDateHeaderLine())
  res.headerBuf.add("\r\n")
  res.native.sendPreparedResponse(res.headerBuf, outputBody, shouldClose)
  res.native.markBodySent()

# ============================================
# FAST JSON SERIALIZATION
# ============================================

# Fast JSON string builder - avoids JsonNode overhead
## Create a ``JsonBuilder`` with the given initial buffer capacity.
proc initJsonBuilder*(capacity: int = 256): JsonBuilder =
  result.buf = newStringOfCap(capacity)

## Append raw JSON text ``s`` to the builder without escaping.
proc add*(b: var JsonBuilder, s: string) {.inline.} =
  b.buf.add(s)

proc addJsonUnicodeEscape(b: var JsonBuilder, ch: char) {.inline.} =
  const HexDigits = "0123456789abcdef"
  let code = ord(ch)
  b.buf.add("\\u00")
  b.buf.add(HexDigits[(code shr 4) and 0x0f])
  b.buf.add(HexDigits[code and 0x0f])

proc appendCopy(buf: var string, src: string, startPos, length: int) {.inline.} =
  if length <= 0:
    return
  let dstPos = buf.len
  buf.setLen(dstPos + length)
  when nimvm:
    for i in 0 ..< length:
      buf[dstPos + i] = src[startPos + i]
  else:
    copyMem(addr buf[dstPos], unsafeAddr src[startPos], length)

## Append ``s`` to the ``JsonBuilder`` buffer with JSON string escaping.
proc addEscaped*(b: var JsonBuilder, s: string) =
  ## Add string with JSON escaping
  b.buf.add('"')
  var copyStart = 0
  var i = 0

  template flushCopy() =
    if i > copyStart:
      appendCopy(b.buf, s, copyStart, i - copyStart)

  while i < s.len:
    let c = s[i]
    if (cast[uint8](c) and 0b1000_0000'u8) == 0'u8:
      case c
      of '"':
        flushCopy()
        b.buf.add("\\\"")
        inc i
        copyStart = i
      of '\\':
        flushCopy()
        b.buf.add("\\\\")
        inc i
        copyStart = i
      of '\n':
        flushCopy()
        b.buf.add("\\n")
        inc i
        copyStart = i
      of '\r':
        flushCopy()
        b.buf.add("\\r")
        inc i
        copyStart = i
      of '\t':
        flushCopy()
        b.buf.add("\\t")
        inc i
        copyStart = i
      else:
        if ord(c) < 0x20:
          flushCopy()
          b.addJsonUnicodeEscape(c)
          inc i
          copyStart = i
        else:
          inc i
    else:
      inc i

  flushCopy()
  b.buf.add('"')

## Append an escaped JSON string key followed by a colon.
proc addKey*(b: var JsonBuilder, key: string) {.inline.} =
  b.addEscaped(key)
  b.buf.add(':')

## Append ``v`` as a JSON number.
proc addInt*(b: var JsonBuilder, v: int) {.inline.} =
  fastIntToStr(v, b.buf)

## Append ``v`` as a JSON floating-point number.
proc addFloat*(b: var JsonBuilder, v: float) {.inline.} =
  b.buf.add($v)

## Append ``v`` as a JSON boolean.
proc addBool*(b: var JsonBuilder, v: bool) {.inline.} =
  b.buf.add(if v: "true" else: "false")

## Append the JSON null literal.
proc addNull*(b: var JsonBuilder) {.inline.} =
  b.buf.add("null")

## Consume the builder and return the built JSON string.
proc finish*(b: sink JsonBuilder): string {.inline.} =
  move(b.buf)

## Build an RFC 7807 problem details JSON body for ``statusCode`` with ``code`` and ``detail``.
proc buildProblemDetailsBody*(
  statusCode: int,
  code: string,
  detail: string
): string =
  ## RFC 7807 Problem Details body shape.
  var builder = initJsonBuilder(128 + code.len + detail.len)
  builder.add("{\"type\":\"about:blank\",\"title\":")
  builder.addEscaped(reasonPhraseFromStatusCode(statusCode))
  builder.add(",\"status\":")
  builder.addInt(statusCode)
  builder.add(",\"code\":")
  builder.addEscaped(code)
  builder.add(",\"detail\":")
  builder.addEscaped(detail)
  builder.add("}")
  builder.finish()

## Build an RFC 7807 problem JSON body with optional type, title, instance and extension members.
proc buildRfc7807ProblemBody*(
  statusCode: int,
  detail: string,
  typeUri: string = "about:blank",
  title: string = "",
  instance: string = "",
  extensions: seq[ProblemDetailExtension] = @[]
): string =
  ## RFC 7807 body with optional type/title/instance and extension members.
  let resolvedType = if typeUri.len > 0: typeUri else: "about:blank"
  let resolvedTitle = if title.len > 0: title else: reasonPhraseFromStatusCode(statusCode)
  var builder = initJsonBuilder(
    160 + resolvedType.len + resolvedTitle.len + detail.len + instance.len + (extensions.len * 32)
  )
  builder.add("{")
  builder.addKey("type")
  builder.addEscaped(resolvedType)
  builder.add(",")
  builder.addKey("title")
  builder.addEscaped(resolvedTitle)
  builder.add(",")
  builder.addKey("status")
  builder.addInt(statusCode)
  if detail.len > 0:
    builder.add(",")
    builder.addKey("detail")
    builder.addEscaped(detail)
  if instance.len > 0:
    builder.add(",")
    builder.addKey("instance")
    builder.addEscaped(instance)
  for extension in extensions:
    let key = extension.key.strip()
    if key.len == 0 or key.isReservedProblemKey():
      continue
    builder.add(",")
    builder.addKey(key)
    builder.addEscaped(extension.value)
  builder.add("}")
  builder.finish()

# Fast JSON response - direct string output (single syscall)
## Terminal writer: send pre-serialized JSON with an application/json content type; later writes are dropped.
proc jsonRaw*(res: Response, jsonStr: sink string) {.inline.} =
  if res.shouldDropLateWrite():
    return
  if res.finished:
    return
  res.runBeforeFinalizeHooks()
  res.finished = true
  res.applyServerTimingHeader()

  var body = jsonStr

  var noBody = res.responseDisallowsBody()
  if not noBody:
    body = res.maybeCompressBody(jsonStr, MimeJsonUtf8)
  let representationLength = res.headRepresentationLength(body.len)
  var validatorBody = body
  if noBody and res.requestMethodKind == hmHead:
    validatorBody = jsonStr
  res.applyEtagPolicy(validatorBody, body, noBody)
  if noBody:
    body.setLen(0)
  if not res.omitContentTypeForNoBody(noBody) and
      not (res.headersInited and res.headers.contains(HeaderContentType)):
    res.defaultContentType = fctJson
  if res.trySendSimpleFramedResponse(body, noBody, HeaderLineJsonContentType, representationLength):
    return

  res.headerBuf.setLen(0)
  if res.statusCode == 200:
    res.headerBuf.add(StatusLines[200])
  else:
    res.headerBuf.add(getStatusLine(res.statusCode))

  var hasConnection = false
  var hasContentType = false
  var hasContentLength = false
  var shouldClose = res.native.connectionCloseEnabled()
  let preserveExplicitContentLength = noBody and res.requestMethodKind == hmHead
  let omitContentType = res.omitContentTypeForNoBody(noBody)

  if res.headersInited and res.headers.len > 0:
    for k, v in res.headers:
      if k == HeaderTransferEncoding:
        continue
      if k == HeaderContentType and omitContentType:
        continue
      if k == HeaderContentLength and not preserveExplicitContentLength:
        continue
      res.headerBuf.add(k)
      res.headerBuf.add(": ")
      res.headerBuf.add(v)
      res.headerBuf.add("\r\n")
      if k == HeaderContentType:
        hasContentType = true
      elif k == HeaderContentLength:
        hasContentLength = true
      elif k == HeaderConnection:
        hasConnection = true
        shouldClose = hasHeaderToken(v, "close")
  appendSetCookieHeaders(res.headerBuf, res)

  if not hasContentType and not omitContentType:
    res.headerBuf.add(HeaderLineJsonContentType)
  if noBody:
    if res.statusCode == 205:
      res.headerBuf.add(HeaderLineContentLengthZero)
    elif representationLength >= 0 and not hasContentLength:
      res.headerBuf.add(HeaderLineContentLengthPrefix)
      fastIntToStr(representationLength, res.headerBuf)
      res.headerBuf.add("\r\n")
  else:
    res.headerBuf.add(HeaderLineContentLengthPrefix)
    fastIntToStr(body.len, res.headerBuf)
    res.headerBuf.add("\r\n")
  if not hasConnection:
    if shouldClose:
      res.headerBuf.add(HeaderLineConnectionClose)
    else:
      res.headerBuf.add(HeaderLineConnectionKeepAlive)
  res.headerBuf.add(getDateHeaderLine())
  res.headerBuf.add("\r\n")
  res.native.sendPreparedResponse(res.headerBuf, body, shouldClose)
  res.native.markBodySent()

# Standard JSON response (JsonNode - slower but dynamic)
## Terminal writer: serialize ``data`` to JSON and send it; later writes are dropped.
## Uses the ``jsonRaw`` framing path, so the content type is emitted from the
## precomputed header line instead of a ``headers`` map insert.
proc json*(res: Response, data: JsonNode) =
  if data.isNil:
    res.jsonRaw("null")
  else:
    res.jsonRaw($data)

## Send pre-serialized ``data`` as application/json without parsing; finalizes the response.
proc json*(res: Response, data: sink string) =
  ## Send JSON string directly (no parsing)
  res.jsonRaw(move(data))

## Serialize ``data`` with nim_fastjson and send it as application/json; finalizes the response.
proc json*[T](res: Response, data: T, sizeHint: int = 128) {.inline.} =
  ## Serialize typed data to JSON using nim_fastjson.
  ## The `string` and `JsonNode` overloads above remain the direct paths.
  when T is string or T is JsonNode:
    discard sizeHint
    {.error: "typed json overload should not be instantiated for string or JsonNode".}
  else:
    if res.shouldDropLateWrite():
      return
    if res.finished:
      return
    res.runBeforeFinalizeHooks()
    res.finished = true
    res.applyServerTimingHeader()

    let jsonStr = serializeReusable(data)
    var body = jsonStr

    var noBody = res.responseDisallowsBody()
    if not noBody:
      body = res.maybeCompressBody(jsonStr, MimeJsonUtf8)
    let representationLength = res.headRepresentationLength(body.len)
    var validatorBody = body
    if noBody and res.requestMethodKind == hmHead:
      validatorBody = jsonStr
    res.applyEtagPolicy(validatorBody, body, noBody)
    if noBody:
      body.setLen(0)
    if res.trySendSimpleFramedResponse(body, noBody, HeaderLineJsonContentType, representationLength):
      return

    res.headerBuf.setLen(0)
    if res.statusCode == 200:
      res.headerBuf.add(StatusLines[200])
    else:
      res.headerBuf.add(getStatusLine(res.statusCode))

    var hasConnection = false
    var hasContentType = false
    var hasContentLength = false
    var shouldClose = res.native.connectionCloseEnabled()
    let preserveExplicitContentLength = noBody and res.requestMethodKind == hmHead
    let omitContentType = res.omitContentTypeForNoBody(noBody)

    if res.headersInited and res.headers.len > 0:
      for k, v in res.headers:
        if k == HeaderTransferEncoding:
          continue
        if k == HeaderContentType and omitContentType:
          continue
        if k == HeaderContentLength and not preserveExplicitContentLength:
          continue
        res.headerBuf.add(k)
        res.headerBuf.add(": ")
        res.headerBuf.add(v)
        res.headerBuf.add("\r\n")
        if k == HeaderContentType:
          hasContentType = true
        elif k == HeaderContentLength:
          hasContentLength = true
        elif k == HeaderConnection:
          hasConnection = true
          shouldClose = hasHeaderToken(v, "close")
    appendSetCookieHeaders(res.headerBuf, res)

    if not hasContentType and not omitContentType:
      res.headerBuf.add(HeaderLineJsonContentType)
    if noBody:
      if res.statusCode == 205:
        res.headerBuf.add(HeaderLineContentLengthZero)
      elif representationLength >= 0 and not hasContentLength:
        res.headerBuf.add(HeaderLineContentLengthPrefix)
        fastIntToStr(representationLength, res.headerBuf)
        res.headerBuf.add("\r\n")
    else:
      res.headerBuf.add(HeaderLineContentLengthPrefix)
      fastIntToStr(body.len, res.headerBuf)
      res.headerBuf.add("\r\n")
    if not hasConnection:
      if shouldClose:
        res.headerBuf.add(HeaderLineConnectionClose)
      else:
        res.headerBuf.add(HeaderLineConnectionKeepAlive)
    res.headerBuf.add(getDateHeaderLine())
    res.headerBuf.add("\r\n")
    res.native.sendPreparedResponse(res.headerBuf, body, shouldClose)
    res.native.markBodySent()

## Backward-compatible alias: send ``data`` as a JSON response.
proc jsonify*(res: Response, data: JsonNode) {.inline.} =
  ## Backward-compatible alias for JSON responses.
  res.json(data)

## Backward-compatible alias: send the pre-serialized JSON string ``data`` as a response.
proc jsonify*(res: Response, data: sink string) {.inline.} =
  ## Backward-compatible alias for JSON responses.
  res.json(move(data))

## Backward-compatible alias: serialize ``data`` and send it as a JSON response.
proc jsonify*[T](res: Response, data: T, sizeHint: int = 128) {.inline.} =
  ## Backward-compatible alias for typed JSON responses.
  res.json(data, sizeHint)

## Send an RFC 7807 problem JSON body for ``statusCode`` with ``code`` and ``detail``; finalizes the response.
proc problem*(res: Response, statusCode: int, code: string, detail: string): Response {.discardable.} =
  if res == nil:
    return res
  discard res.status(statusCode)
  discard res.set(HeaderContentType, MimeProblemJsonUtf8)
  res.jsonRaw(buildProblemDetailsBody(statusCode, code, detail))
  res

## Send a full RFC 7807 problem JSON body with optional type, title, instance, and extensions.
proc problemDetails*(
  res: Response,
  statusCode: int,
  detail: string,
  typeUri: string = "about:blank",
  title: string = "",
  instance: string = "",
  extensions: seq[ProblemDetailExtension] = @[]
): Response {.discardable.} =
  if res == nil:
    return res
  discard res.status(statusCode)
  discard res.set(HeaderContentType, MimeProblemJsonUtf8)
  res.jsonRaw(buildRfc7807ProblemBody(
    statusCode = statusCode,
    detail = detail,
    typeUri = typeUri,
    title = title,
    instance = instance,
    extensions = extensions
  ))
  res

# ============================================
# RESPONSE HELPERS
# ============================================

proc isPathInside(baseDir, candidatePath: string): bool =
  if candidatePath.len < baseDir.len:
    return false
  if candidatePath == baseDir:
    return true
  if baseDir.len == 0:
    return false
  if baseDir[^1] == DirSep:
    return candidatePath.startsWith(baseDir)
  candidatePath.startsWith(baseDir & $DirSep)

proc hasUnsafePathSegment(path: string): bool =
  let normalized = path.replace('\\', '/')
  if normalized.len == 0:
    return true
  if normalized[0] == '/':
    return true
  for part in normalized.split('/'):
    if part == "..":
      return true
  false

when defined(singleThread):
  var resolvedViewPathCache: FastMap[string]
  var resolvedViewPathCacheInited: bool
else:
  var resolvedViewPathCache {.threadvar.}: FastMap[string]
  var resolvedViewPathCacheInited {.threadvar.}: bool

proc resolveViewPathUncached(baseDir: string, viewName: string, viewExt: string): string =
  var requested = viewName.strip()
  if hasUnsafePathSegment(requested):
    return ""

  while requested.startsWith("./"):
    requested = requested[2..^1]
  if requested.len == 0:
    return ""

  var candidates: seq[string] = @[requested]
  if splitFile(requested).ext.len == 0:
    if viewExt.len > 0:
      candidates.add(requested & viewExt)
    candidates.add(requested & ".html")
    candidates.add(requested & ".htm")
    candidates.add(requested & ".tmpl")

  var safeBase = baseDir
  try:
    safeBase = expandFilename(safeBase)
  except OSError:
    discard
  normalizePath(safeBase)

  for relativePath in candidates:
    var fullPath = joinPath(safeBase, relativePath)
    normalizePath(fullPath)
    if not isPathInside(safeBase, fullPath):
      continue
    if fileExists(fullPath):
      return fullPath
  ""

proc resolveViewPath(res: Response, viewName: string): string =
  if not resolvedViewPathCacheInited:
    resolvedViewPathCache = newFastMap[string]()
    resolvedViewPathCacheInited = true

  let cacheKey = res.viewsDir & "\0" & res.viewExt & "\0" & viewName
  if resolvedViewPathCache.tryGet(cacheKey, result):
    return

  let baseDir = res.viewsDir
  result = resolveViewPathUncached(baseDir, viewName, res.viewExt)
  if result.len > 0:
    discard resolvedViewPathCache.put(cacheKey, result)

type
  TemplatePlan = ref object
    parts: seq[string]
    keys: seq[string]
    rawTokens: seq[string]
    rawFlags: seq[bool]

  CachedHttpResponse = object
    headerKeepAlive: string
    headerClose: string
    body: string
    valid: bool
    pairsHash: uint64

  ## Compiled view template holding its source, render plan, and cached render state.
  CompiledTemplate* = ref object
    source: string
    plan: TemplatePlan
    ## Cached rendered HTML body for the repeat-send fast path.
    cachedRender*: string
    cachedResponse: CachedHttpResponse

  ## Closure that resolves a template key to a value, returning whether one was found.
  RenderValueLookup* = proc(key: string, value: var string): bool {.closure.}
  ## Closure invoked once per row with a value lookup for that row.
  RowEmitProc* = proc(lookup: RenderValueLookup): bool {.closure.}
  ## Closure that streams rows by calling ``emitRow`` for each; returns the count emitted.
  RowStreamAdapter* = proc(emitRow: RowEmitProc): int {.closure.}

  ## Compiled row template plan for repeated row renders.
  CompiledRenderPlan* = ref object
    plan: TemplatePlan

  TemplateRenderPair = tuple[key: string, value: string]

when defined(singleThread):
  var
    templatePlanCacheIndex: FastMap[int64]
    templatePlanCacheEntries: seq[TemplatePlan]
    viewContentCache: FastMap[string]
    templatePlanCacheBytes: int64
    viewContentCacheBytes: int64
    templateCacheHits: int64
    templateCacheMisses: int64
    templateCacheEvictions: int64
    viewCacheHits: int64
    viewCacheMisses: int64
    viewCacheEvictions: int64
else:
  var
    templatePlanCacheIndex {.threadvar.}: FastMap[int64]
    templatePlanCacheEntries {.threadvar.}: seq[TemplatePlan]
    viewContentCache {.threadvar.}: FastMap[string]
    templatePlanCacheBytes {.threadvar.}: int64
    viewContentCacheBytes {.threadvar.}: int64
    templateCacheHits {.threadvar.}: int64
    templateCacheMisses {.threadvar.}: int64
    templateCacheEvictions {.threadvar.}: int64
    viewCacheHits {.threadvar.}: int64
    viewCacheMisses {.threadvar.}: int64
    viewCacheEvictions {.threadvar.}: int64
var
  templateCacheMaxEntries = DefaultTemplateCacheMaxEntries
  templateCacheMaxBytes = DefaultTemplateCacheMaxBytes.int64
  viewCacheMaxEntries = DefaultViewCacheMaxEntries
  viewCacheMaxBytes = DefaultViewCacheMaxBytes.int64

proc useViewCache(res: Response): bool {.inline.} =
  if res == nil or res.app == nil:
    return true
  let raw = res.app.settings.get("view_cache", "true")
  not (raw == "false" or raw == "0" or raw == "off")

proc ensureTemplatePlanCache() {.inline.} =
  if templatePlanCacheIndex == nil:
    templatePlanCacheIndex = newFastMap[int64]()
    discard templatePlanCacheIndex.reserve(64)
  if templatePlanCacheEntries.len == 0:
    templatePlanCacheEntries = @[]

proc ensureViewContentCache() {.inline.} =
  if viewContentCache == nil:
    viewContentCache = newFastMap[string]()
    discard viewContentCache.reserve(64)

proc clearTemplatePlanCacheOnly() =
  if templatePlanCacheIndex != nil:
    templatePlanCacheIndex.clear()
  templatePlanCacheEntries.setLen(0)
  templatePlanCacheBytes = 0'i64

proc clearViewContentCacheOnly() =
  if viewContentCache != nil:
    viewContentCache.clear()
  viewContentCacheBytes = 0'i64

## Set the max entries and bytes for the per-thread template and view caches.
proc setTemplateViewCachePolicy*(
  templateMaxEntries: int = DefaultTemplateCacheMaxEntries,
  templateMaxBytes: int64 = DefaultTemplateCacheMaxBytes.int64,
  viewMaxEntries: int = DefaultViewCacheMaxEntries,
  viewMaxBytes: int64 = DefaultViewCacheMaxBytes.int64
) =
  templateCacheMaxEntries = max(0, templateMaxEntries)
  templateCacheMaxBytes = max(0'i64, templateMaxBytes)
  viewCacheMaxEntries = max(0, viewMaxEntries)
  viewCacheMaxBytes = max(0'i64, viewMaxBytes)

## Reset all template and view cache hit, miss, and eviction counters to zero.
proc resetTemplateViewCacheStats*() =
  templateCacheHits = 0'i64
  templateCacheMisses = 0'i64
  templateCacheEvictions = 0'i64
  viewCacheHits = 0'i64
  viewCacheMisses = 0'i64
  viewCacheEvictions = 0'i64

## Return template and view cache counters and sizes as a ``FastMap`` of int64.
proc templateViewCacheStats*(): FastMap[int64] =
  result = newFastMap[int64]()
  discard result.reserve(16)
  discard result.put("template_hits", templateCacheHits)
  discard result.put("template_misses", templateCacheMisses)
  discard result.put("template_evictions", templateCacheEvictions)
  discard result.put("template_entries", templatePlanCacheEntries.len.int64)
  discard result.put("template_bytes", templatePlanCacheBytes)
  discard result.put("view_hits", viewCacheHits)
  discard result.put("view_misses", viewCacheMisses)
  discard result.put("view_evictions", viewCacheEvictions)
  discard result.put("view_entries", if viewContentCache == nil: 0'i64 else: viewContentCache.len.int64)
  discard result.put("view_bytes", viewContentCacheBytes)

## Clear per-thread compiled template and loaded view caches.
proc clearTemplateCaches*() =
  ## Clears per-thread compiled template and loaded view caches.
  clearTemplatePlanCacheOnly()
  clearViewContentCacheOnly()

## Invalidate one cached view by resolved path, or all cached views when ``resolvedPath`` is empty.
proc invalidateViewCache*(resolvedPath: string = "") =
  ## Invalidate one cached view by absolute path (or all when empty).
  if viewContentCache == nil:
    return
  if resolvedPath.len == 0:
    clearViewContentCacheOnly()
  else:
    var cached: string
    if viewContentCache.tryGet(resolvedPath, cached):
      viewContentCacheBytes = max(0'i64, viewContentCacheBytes - int64(resolvedPath.len + cached.len))
    discard viewContentCache.del(resolvedPath)

proc compileTemplatePlan(content: string): TemplatePlan =
  new(result)
  result.parts = @[]
  result.keys = @[]
  result.rawTokens = @[]
  result.rawFlags = @[]

  var cursor = 0
  var i = 0
  while i + 1 < content.len:
    if content[i] == '{' and content[i + 1] == '{':
      let tokenStart = i
      let rawToken = i + 2 < content.len and content[i + 2] == '{'
      let openLen = if rawToken: 3 else: 2
      let closeLen = if rawToken: 3 else: 2
      i += openLen
      while true:
        if rawToken:
          if i + 2 >= content.len:
            break
          if content[i] == '}' and content[i + 1] == '}' and content[i + 2] == '}':
            break
        else:
          if i + 1 >= content.len:
            break
          if content[i] == '}' and content[i + 1] == '}':
            break
        inc i
      if i + closeLen - 1 >= content.len:
        break
      let tokenEnd = i + closeLen
      result.parts.add(content[cursor..<tokenStart])
      result.rawTokens.add(content[tokenStart..<tokenEnd])

      var keyStart = tokenStart + openLen
      var keyEnd = i
      while keyStart < keyEnd and content[keyStart] in {' ', '\t'}:
        inc keyStart
      while keyEnd > keyStart and content[keyEnd - 1] in {' ', '\t'}:
        dec keyEnd
      result.keys.add(
        if keyEnd > keyStart:
          content[keyStart..<keyEnd]
        else:
          ""
      )
      result.rawFlags.add(rawToken)
      cursor = tokenEnd
      i = tokenEnd
    else:
      inc i
  if cursor < content.len:
    result.parts.add(content[cursor..^1])
  else:
    result.parts.add("")

proc getTemplatePlan(cacheKey: string, content: string): TemplatePlan =
  if cacheKey.len > 0:
    ensureTemplatePlanCache()
    var idx: int64
    if templatePlanCacheIndex.tryGet(cacheKey, idx):
      let i = int(idx)
      if i >= 0 and i < templatePlanCacheEntries.len:
        inc templateCacheHits
        return templatePlanCacheEntries[i]
    inc templateCacheMisses
  let plan = compileTemplatePlan(content)
  if cacheKey.len > 0:
    let entryBytes = int64(cacheKey.len + content.len)
    if templateCacheMaxBytes > 0 and entryBytes > templateCacheMaxBytes:
      return plan
    let entryCapExceeded =
      templateCacheMaxEntries > 0 and templatePlanCacheEntries.len >= templateCacheMaxEntries
    let byteCapExceeded =
      templateCacheMaxBytes > 0 and templatePlanCacheBytes + entryBytes > templateCacheMaxBytes
    if entryCapExceeded or byteCapExceeded:
      if templatePlanCacheEntries.len > 0:
        templateCacheEvictions += templatePlanCacheEntries.len.int64
      clearTemplatePlanCacheOnly()
    let entryIdx = templatePlanCacheEntries.len
    templatePlanCacheEntries.add(plan)
    discard templatePlanCacheIndex.put(cacheKey, int64(entryIdx))
    templatePlanCacheBytes += entryBytes
  plan

proc escapeHtml(value: string): string =
  var needsEscape = false
  for c in value:
    if c == '&' or c == '<' or c == '>' or c == '"' or c == '\'':
      needsEscape = true
      break
  if not needsEscape:
    return value

  result = newStringOfCap(value.len + 8)
  for c in value:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&#39;")
    else: result.add(c)

proc escapeHtmlTo(buf: var string, value: string) {.inline.} =
  var needsEscape = false
  for c in value:
    if c == '&' or c == '<' or c == '>' or c == '"' or c == '\'':
      needsEscape = true
      break
  if not needsEscape:
    buf.add(value)
    return
  for c in value:
    case c
    of '&': buf.add("&amp;")
    of '<': buf.add("&lt;")
    of '>': buf.add("&gt;")
    of '"': buf.add("&quot;")
    of '\'': buf.add("&#39;")
    else: buf.add(c)

proc needsHtmlEscape(value: string): bool {.inline.} =
  for c in value:
    if c == '&' or c == '<' or c == '>' or c == '"' or c == '\'':
      return true
  false

when defined(singleThread):
  var renderBuf: string
  var renderBufInited: bool
  var renderFragments: seq[string]
  var renderFragmentsInited: bool
else:
  var renderBuf {.threadvar.}: string
  var renderBufInited {.threadvar.}: bool
  var renderFragments {.threadvar.}: seq[string]
  var renderFragmentsInited {.threadvar.}: bool

proc prepareRenderFragments() {.inline.} =
  if not renderFragmentsInited:
    renderFragments = newSeqOfCap[string](32)
    renderFragmentsInited = true
  renderFragments.setLen(0)

proc addRenderFragment(fragment: string, totalBodyBytes: var int) {.inline.} =
  if fragment.len == 0:
    return
  totalBodyBytes += fragment.len
  renderFragments.add(fragment)

proc escapeHtmlFragment(value: string): string {.inline.} =
  if value.len == 0:
    return ""
  if not needsHtmlEscape(value):
    return value
  result = newStringOfCap(value.len + 16)
  escapeHtmlTo(result, value)

proc renderTemplatePlanToBuffer(
  plan: TemplatePlan,
  fallbackContent: string,
  locals: FastMap[string]
): string =
  if plan == nil:
    return fallbackContent
  if plan.keys.len == 0:
    return fallbackContent
  if not renderBufInited:
    renderBuf = newStringOfCap(4096)
    renderBufInited = true
  renderBuf.setLen(0)
  var i = 0
  while i < plan.keys.len:
    renderBuf.add(plan.parts[i])
    var value = ""
    if locals != nil and plan.keys[i].len > 0 and locals.tryGet(plan.keys[i], value):
      if plan.rawFlags[i]:
        renderBuf.add(value)
      else:
        escapeHtmlTo(renderBuf, value)
    else:
      renderBuf.add(plan.rawTokens[i])
    inc i
  renderBuf.add(plan.parts[^1])
  result = move(renderBuf)
  renderBuf = newStringOfCap(4096)

proc renderTemplatePlanToString(
  plan: TemplatePlan,
  fallbackContent: string,
  locals: FastMap[string]
): string =
  renderTemplatePlanToBuffer(plan, fallbackContent, locals)

## Parse ``content`` into a ``CompiledTemplate`` with a ready render plan.
proc compileTemplate*(content: string): CompiledTemplate =
  new(result)
  result.source = content
  result.plan = compileTemplatePlan(content)

## Read and compile the template at ``templatePath``; returns ok, compiled template, or error.
proc compileTemplateFile*(
  templatePath: string
): tuple[ok: bool, compiled: CompiledTemplate, error: string] =
  try:
    let source = readFile(templatePath)
    result.ok = true
    result.compiled = compileTemplate(source)
  except CatchableError:
    result.error = "Failed to compile template file"

## Render ``compiled`` with ``locals`` values, escaping non-raw placeholders, and return the HTML.
proc renderTemplate*(compiled: CompiledTemplate, locals: FastMap[string]): string =
  if compiled == nil:
    return ""
  renderTemplatePlanToString(compiled.plan, compiled.source, locals)

## Render ``compiled`` using (key, value) pairs instead of a ``FastMap`` of locals.
proc renderTemplateWithPairs*(compiled: CompiledTemplate, pairs: openArray[(string, string)]): string =
  if compiled == nil:
    return ""
  let plan = compiled.plan
  if plan == nil or plan.keys.len == 0:
    return compiled.source
  result = newStringOfCap(compiled.source.len + 128)
  var i = 0
  while i < plan.keys.len:
    result.add(plan.parts[i])
    let key = plan.keys[i]
    var found = false
    if key.len > 0:
      for j in 0..<pairs.len:
        if pairs[j][0] == key:
          if plan.rawFlags[i]:
            result.add(pairs[j][1])
          else:
            escapeHtmlTo(result, pairs[j][1])
          found = true
          break
    if not found:
      result.add(plan.rawTokens[i])
    inc i
  result.add(plan.parts[^1])

proc copyOwnedString(raw: string): string {.inline.} =
  if raw.len == 0:
    return ""
  result = newStringOfCap(raw.len)
  result.add(raw)

proc packTemplatePairs(pairs: openArray[TemplateRenderPair]): string =
  result = newStringOfCap(max(16, pairs.len * 48))
  for pair in pairs:
    fastIntToStr(pair.key.len, result)
    result.add(':')
    result.add(pair.key)
    fastIntToStr(pair.value.len, result)
    result.add(':')
    result.add(pair.value)

proc unpackNextTemplateToken(data: string, pos: var int): string =
  if pos >= data.len:
    return ""
  var tokenLen = 0
  while pos < data.len and data[pos] != ':':
    let ch = data[pos]
    if ch < '0' or ch > '9':
      return ""
    tokenLen = tokenLen * 10 + ord(ch) - ord('0')
    inc pos
  if pos >= data.len or data[pos] != ':':
    return ""
  inc pos
  if tokenLen <= 0:
    return ""
  let endPos = min(data.len, pos + tokenLen)
  result = data[pos ..< endPos]
  pos = endPos

proc unpackTemplatePairs(data: string): seq[TemplateRenderPair] =
  result = @[]
  var pos = 0
  while pos < data.len:
    let key = unpackNextTemplateToken(data, pos)
    let value = unpackNextTemplateToken(data, pos)
    if key.len == 0 and value.len == 0:
      break
    result.add((key, value))

proc renderTemplateOffThread(
  content: string,
  packedPairs: string
): string {.gcsafe.} =
  let pairs = unpackTemplatePairs(packedPairs)
  let compiled = compileTemplate(content)
  renderTemplateWithPairs(compiled, pairs)

## Compile a single row template into a ``CompiledRenderPlan`` for repeated row renders.
proc compileRenderPlan*(templateRow: string): CompiledRenderPlan =
  new(result)
  result.plan = compileTemplatePlan(templateRow)

## Render one row from ``plan`` using ``locals`` values, returning the HTML string.
proc renderRenderPlan*(plan: CompiledRenderPlan, locals: FastMap[string]): string =
  if plan == nil:
    return ""
  renderTemplatePlanToString(plan.plan, "", locals)

## Append one rendered row from ``plan`` to ``buf``, resolving values via ``lookup``.
proc appendRenderPlan*(
  buf: var PageBuffer,
  plan: CompiledRenderPlan,
  lookup: RenderValueLookup
) =
  if plan == nil or plan.plan == nil:
    return
  let templatePlan = plan.plan
  var i = 0
  while i < templatePlan.keys.len:
    buf.add(templatePlan.parts[i])
    var value = ""
    let hasValue =
      lookup != nil and
      templatePlan.keys[i].len > 0 and
      lookup(templatePlan.keys[i], value)
    if hasValue:
      if templatePlan.rawFlags[i]:
        buf.add(value)
      else:
        buf.addHtmlEscaped(value)
    else:
      buf.add(templatePlan.rawTokens[i])
    inc i
  buf.add(templatePlan.parts[^1])

## Append one rendered row from ``plan`` to ``buf``, resolving values from ``locals``.
proc appendRenderPlan*(
  buf: var PageBuffer,
  plan: CompiledRenderPlan,
  locals: FastMap[string]
) =
  if plan == nil:
    return
  buf.appendRenderPlan(
    plan,
    proc(key: string, value: var string): bool =
      locals != nil and locals.tryGet(key, value)
  )

## Append one rendered row per ``FastMap`` in ``rows`` to ``buf``.
proc appendRenderPlanRows*(
  buf: var PageBuffer,
  plan: CompiledRenderPlan,
  rows: openArray[FastMap[string]]
) =
  for row in rows:
    buf.appendRenderPlan(plan, row)

## Stream rows via ``adapter``, rendering each into ``buf``; returns the count emitted.
proc streamRenderPlanRows*(
  buf: var PageBuffer,
  plan: CompiledRenderPlan,
  adapter: RowStreamAdapter
): int =
  if adapter == nil or plan == nil:
    return 0
  let bufPtr = addr buf
  adapter(proc(lookup: RenderValueLookup): bool =
    bufPtr[].appendRenderPlan(plan, lookup)
    true
  )

proc renderTemplatePlanWithLocalsToSend(
  res: Response,
  plan: TemplatePlan,
  fallbackContent: string,
  locals: FastMap[string]
) {.inline.}

proc cacheViewContentIfAllowed(path: string, content: string) =
  ensureViewContentCache()
  let entryBytes = int64(path.len + content.len)
  if viewCacheMaxBytes > 0 and entryBytes > viewCacheMaxBytes:
    return
  var previous: string
  let replacingExisting = viewContentCache.tryGet(path, previous)
  if replacingExisting:
    viewContentCacheBytes = max(0'i64, viewContentCacheBytes - int64(path.len + previous.len))
  let entryCapExceeded =
    not replacingExisting and viewCacheMaxEntries > 0 and viewContentCache.len >= viewCacheMaxEntries
  let byteCapExceeded = viewCacheMaxBytes > 0 and viewContentCacheBytes + entryBytes > viewCacheMaxBytes
  if entryCapExceeded or byteCapExceeded:
    if viewContentCache.len > 0:
      viewCacheEvictions += viewContentCache.len.int64
    clearViewContentCacheOnly()
  discard viewContentCache.put(path, content)
  viewContentCacheBytes += entryBytes

## Preload ``viewName`` and compile its template plan into thread-local caches; returns success.
proc precompileViewTemplate*(
  viewsDir: string,
  viewExt: string,
  viewName: string
): bool =
  ## Preload view content and compile its template plan into thread-local caches.
  let probe = newResponse(nil, viewsDir, viewExt)
  let resolvedPath = resolveViewPath(probe, viewName)
  if resolvedPath.len == 0:
    return false
  try:
    let content = readFile(resolvedPath)
    discard getTemplatePlan(resolvedPath, content)
    cacheViewContentIfAllowed(resolvedPath, content)
    true
  except CatchableError:
    false

## Precompile each view in ``viewNames`` into the thread-local caches; returns how many succeeded.
proc precompileViewTemplates*(
  viewsDir: string,
  viewExt: string,
  viewNames: openArray[string]
): int =
  for name in viewNames:
    if precompileViewTemplate(viewsDir, viewExt, name):
      inc result

## Load a view file or embedded view by name; returns ok, path, content, or error.
proc loadView*(res: Response, viewName: string): tuple[ok: bool, path: string, content: string, error: string] =
  if res.app != nil and res.app.embeddedViews != nil:
    if res.app.embeddedViews.tryGet(viewName, result.content):
      result.path = viewName
      result.ok = true
      return

  let resolvedPath = resolveViewPath(res, viewName)
  if resolvedPath.len == 0:
    result.error = "View not found: " & viewName
    return
  let cacheEnabled = useViewCache(res)
  if cacheEnabled:
    ensureViewContentCache()
    if viewContentCache.tryGet(resolvedPath, result.content):
      inc viewCacheHits
      result.path = resolvedPath
      result.ok = true
      return
    inc viewCacheMisses
  try:
    result.path = resolvedPath
    result.content = readFile(resolvedPath)
    if cacheEnabled:
      cacheViewContentIfAllowed(resolvedPath, result.content)
    result.ok = true
  except CatchableError:
    result.error = "Failed to load view"

## Render view ``viewName`` with ``locals`` and send the HTML response; finalizes the response.
proc render*(res: Response, viewName: string, locals: FastMap[string]) =
  if res.app != nil and res.app.embeddedViewPlans != nil:
    var p: pointer
    if res.app.embeddedViewPlans.tryGet(viewName, p):
      let compiled = cast[CompiledTemplate](p)
      if locals == nil or locals.len == 0:
        res.sendHtmlBody(compiled.source)
      else:
        renderTemplatePlanWithLocalsToSend(res, compiled.plan, compiled.source, locals)
      return

  let loaded = res.loadView(viewName)
  if not loaded.ok:
    if res.app != nil and res.app.errorHook != nil:
      res.app.errorHook(loaded.error)
    res.status(500)
    res.jsonRaw("""{"error":"Internal Server Error"}""")
    return

  if locals == nil or locals.len == 0:
    res.sendHtmlBody(loaded.content)
    return

  renderTemplatePlanWithLocalsToSend(
    res, getTemplatePlan(loaded.path, loaded.content), loaded.content, locals)

## Send view ``viewName`` unrendered as an HTML response; finalizes the response.
proc render*(res: Response, viewName: string) =
  res.render(viewName, nil)

proc buildHtmlHeaderBuf(
  res: Response,
  bodyLen: int,
  shouldClose: bool,
  omitEntityHeaders: bool = false
) {.inline.} =
  res.headerBuf.setLen(0)
  if res.statusCode == 200:
    res.headerBuf.add(StatusLines[200])
  else:
    res.headerBuf.add(getStatusLine(res.statusCode))

  var hasConnection = false

  if res.headersInited and res.headers.len > 0:
    for k, v in res.headers:
      if k == HeaderTransferEncoding or k == HeaderContentLength:
        continue
      if k == HeaderContentType:
        continue
      res.headerBuf.add(k)
      res.headerBuf.add(": ")
      res.headerBuf.add(v)
      res.headerBuf.add("\r\n")
      if k == HeaderConnection:
        hasConnection = true
  appendSetCookieHeaders(res.headerBuf, res)

  if not omitEntityHeaders:
    res.headerBuf.add(HeaderLineHtmlContentType)
  if not hasConnection:
    if shouldClose:
      res.headerBuf.add(HeaderLineConnectionClose)
    else:
      res.headerBuf.add(HeaderLineConnectionKeepAlive)

  if not omitEntityHeaders:
    res.headerBuf.add(HeaderLineContentLengthPrefix)
    fastIntToStr(bodyLen, res.headerBuf)
    res.headerBuf.add("\r\n")
  res.headerBuf.add(getDateHeaderLine())
  res.headerBuf.add("\r\n")

proc htmlFinalizationNeeded(res: Response): bool {.inline.} =
  if res == nil:
    return false
  if res.beforeFinalizeHooks.len > 0:
    return true
  if res.responseDisallowsBody() or res.compress:
    return true
  if res.locals != nil and res.locals.len > 0:
    if res.locals.getOrDefault(LocalEtagEnabled, "") == "1":
      return true
  if res.request != nil and res.request.locals != nil and res.request.locals.len > 0:
    if res.request.locals.getOrDefault(LocalServerTimingEnabled, "") == "1" and
       res.request.locals.getOrDefault(LocalServerTimingStart, "").len > 0:
      return true
  false

proc sendCachedHtmlResponse(res: Response, cached: var CachedHttpResponse) {.inline.} =
  if res.shouldDropLateWrite():
    return
  if res.finished:
    return
  if res.htmlFinalizationNeeded():
    var body = cached.body
    res.sendHtmlBody(move(body))
    return
  res.finished = true
  let shouldClose = res.native.connectionCloseEnabled()
  let header = if shouldClose: cached.headerClose else: cached.headerKeepAlive
  res.native.sendPreparedResponse(header, cached.body, shouldClose)
  res.native.markBodySent()

## Terminal writer: send ``body`` as text/html and finalize the response; later writes are dropped.
proc sendHtmlBody*(res: Response, body: sink string) {.inline.} =
  if res.shouldDropLateWrite():
    return
  if res.finished:
    return
  res.runBeforeFinalizeHooks()
  res.finished = true
  res.applyServerTimingHeader()

  var outputBody = body
  var noBody = res.responseDisallowsBody()
  if not noBody:
    outputBody = res.maybeCompressBody(body, MimeHtmlUtf8)
  let representationLength = res.headRepresentationLength(outputBody.len)
  var validatorBody = outputBody
  if noBody and res.requestMethodKind == hmHead:
    validatorBody = body
  res.applyEtagPolicy(validatorBody, outputBody, noBody)
  if noBody:
    outputBody.setLen(0)

  if not res.headersInited and res.setCookies.len == 0:
    let shouldClose = res.native.connectionCloseEnabled()
    if res.statusCode == 200:
      let tmpl = if shouldClose: ResponseTemplate200HtmlClose
                 else: ResponseTemplate200HtmlKeepAlive
      res.headerBuf.setLen(0)
      res.headerBuf.add(tmpl)
      fastIntToStr(if representationLength >= 0: representationLength else: outputBody.len, res.headerBuf)
      res.headerBuf.add("\r\n")
      res.headerBuf.add(getDateHeaderLine())
      res.headerBuf.add("\r\n")
      res.native.sendPreparedResponse(res.headerBuf, outputBody, shouldClose)
      res.native.markBodySent()
      return

  let shouldClose = res.native.connectionCloseEnabled()
  let omitEntityHeaders =
    noBody and res.requestMethodKind != hmHead and res.statusCode != 205
  buildHtmlHeaderBuf(
    res,
    if representationLength >= 0: representationLength else: outputBody.len,
    shouldClose,
    omitEntityHeaders
  )
  res.native.sendPreparedResponse(res.headerBuf, outputBody, shouldClose)
  res.native.markBodySent()

proc sendHtmlFragments(
  res: Response,
  fragments: openArray[string],
  totalBodyBytes: int
) {.inline.} =
  if res.shouldDropLateWrite():
    return
  if res.finished:
    return
  if res.htmlFinalizationNeeded():
    var body = newStringOfCap(totalBodyBytes)
    for fragment in fragments:
      body.add(fragment)
    res.sendHtmlBody(move(body))
    return
  res.finished = true

  let shouldClose = res.native.connectionCloseEnabled()
  if not res.headersInited and res.setCookies.len == 0 and res.statusCode == 200:
    let tmpl = if shouldClose: ResponseTemplate200HtmlClose
               else: ResponseTemplate200HtmlKeepAlive
    res.headerBuf.setLen(0)
    res.headerBuf.add(tmpl)
    fastIntToStr(totalBodyBytes, res.headerBuf)
    res.headerBuf.add("\r\n")
    res.headerBuf.add(getDateHeaderLine())
    res.headerBuf.add("\r\n")
    res.native.sendPreparedResponseFragments(
      res.headerBuf,
      fragments,
      totalBodyBytes,
      shouldClose
    )
    res.native.markBodySent()
    return

  buildHtmlHeaderBuf(res, totalBodyBytes, shouldClose)
  res.native.sendPreparedResponseFragments(
    res.headerBuf,
    fragments,
    totalBodyBytes,
    shouldClose
  )
  res.native.markBodySent()

proc sendHtmlBodyAndCache(res: Response, body: sink string, cached: var CachedHttpResponse) {.inline.} =
  if res.shouldDropLateWrite():
    return
  if res.finished:
    return
  if res.htmlFinalizationNeeded():
    res.sendHtmlBody(move(body))
    return

  if not res.headersInited and res.setCookies.len == 0 and res.statusCode == 200:
    res.finished = true
    let shouldClose = res.native.connectionCloseEnabled()
    let tmpl = if shouldClose: ResponseTemplate200HtmlClose
               else: ResponseTemplate200HtmlKeepAlive
    res.headerBuf.setLen(0)
    res.headerBuf.add(tmpl)
    fastIntToStr(body.len, res.headerBuf)
    res.headerBuf.add("\r\n")
    res.headerBuf.add(getDateHeaderLine())
    res.headerBuf.add("\r\n")
    cached.body = body
    cached.headerKeepAlive = ResponseTemplate200HtmlKeepAlive & $body.len & "\r\n\r\n"
    cached.headerClose = ResponseTemplate200HtmlClose & $body.len & "\r\n\r\n"
    cached.valid = true
    res.native.sendPreparedResponse(res.headerBuf, body, shouldClose)
    res.native.markBodySent()
    return

  cached.valid = false
  res.sendHtmlBody(move(body))

proc renderTemplatePlanWithLocalsToSend(
  res: Response,
  plan: TemplatePlan,
  fallbackContent: string,
  locals: FastMap[string]
) {.inline.} =
  if plan == nil or plan.keys.len == 0:
    res.sendHtmlBody(fallbackContent)
    return

  prepareRenderFragments()
  var totalBodyBytes = 0
  var i = 0
  while i < plan.keys.len:
    addRenderFragment(plan.parts[i], totalBodyBytes)
    var value = ""
    if locals != nil and plan.keys[i].len > 0 and locals.tryGet(plan.keys[i], value):
      if plan.rawFlags[i]:
        addRenderFragment(value, totalBodyBytes)
      else:
        let escaped = escapeHtmlFragment(value)
        addRenderFragment(escaped, totalBodyBytes)
    else:
      addRenderFragment(plan.rawTokens[i], totalBodyBytes)
    inc i
  addRenderFragment(plan.parts[^1], totalBodyBytes)
  res.sendHtmlFragments(renderFragments, totalBodyBytes)

proc renderTemplatePlanWithPairsToSend(
  res: Response,
  plan: TemplatePlan,
  fallbackContent: string,
  pairs: openArray[(string, string)]
) {.inline.} =
  if plan == nil or plan.keys.len == 0:
    res.sendHtmlBody(fallbackContent)
    return

  prepareRenderFragments()
  var totalBodyBytes = 0
  var i = 0
  while i < plan.keys.len:
    addRenderFragment(plan.parts[i], totalBodyBytes)
    let key = plan.keys[i]
    var found = false
    if key.len > 0:
      for j in 0..<pairs.len:
        if pairs[j][0] == key:
          if plan.rawFlags[i]:
            addRenderFragment(pairs[j][1], totalBodyBytes)
          else:
            let escaped = escapeHtmlFragment(pairs[j][1])
            addRenderFragment(escaped, totalBodyBytes)
          found = true
          break
    if not found:
      addRenderFragment(plan.rawTokens[i], totalBodyBytes)
    inc i
  addRenderFragment(plan.parts[^1], totalBodyBytes)
  res.sendHtmlFragments(renderFragments, totalBodyBytes)

## Render view ``viewName`` with (key, value) ``pairs`` and send the HTML response; finalizes the response.
proc render*(res: Response, viewName: string, pairs: openArray[(string, string)]) =
  if res.app != nil and res.app.embeddedViewPlans != nil:
    var p: pointer
    if res.app.embeddedViewPlans.tryGet(viewName, p):
      let compiled = cast[CompiledTemplate](p)
      if compiled.cachedRender.len > 0:
        if compiled.cachedResponse.valid:
          res.sendCachedHtmlResponse(compiled.cachedResponse)
        else:
          res.sendHtmlBodyAndCache(compiled.cachedRender, compiled.cachedResponse)
          compiled.cachedResponse.pairsHash = 0
        return
      renderTemplatePlanWithPairsToSend(res, compiled.plan, compiled.source, pairs)
      return

  let loaded = res.loadView(viewName)
  if not loaded.ok:
    if res.app != nil and res.app.errorHook != nil:
      res.app.errorHook(loaded.error)
    res.status(500)
    res.jsonRaw("""{"error":"Internal Server Error"}""")
    return

  renderTemplatePlanWithPairsToSend(
    res, getTemplatePlan(loaded.path, loaded.content), loaded.content, pairs)

proc renderOffloadSeq(
  res: Response,
  viewName: string,
  pairs: seq[(string, string)]
): Future[void] {.async.} =
  if res == nil:
    return

  if pairs.len == 0:
    res.render(viewName)
    return

  if res.app != nil and res.app.embeddedViewPlans != nil:
    var p: pointer
    if res.app.embeddedViewPlans.tryGet(viewName, p):
      let compiled = cast[CompiledTemplate](p)
      if compiled.cachedRender.len > 0:
        if compiled.cachedResponse.valid:
          res.sendCachedHtmlResponse(compiled.cachedResponse)
        else:
          res.sendHtmlBodyAndCache(compiled.cachedRender, compiled.cachedResponse)
          compiled.cachedResponse.pairsHash = 0
        return
      let contentSnapshot = copyOwnedString(compiled.source)
      let packedPairs = packTemplatePairs(pairs)
      let body = await runOffload(renderTemplateOffThread(contentSnapshot, packedPairs))
      res.sendHtmlBody(body)
      return

  let loaded = res.loadView(viewName)
  if not loaded.ok:
    if res.app != nil and res.app.errorHook != nil:
      res.app.errorHook(loaded.error)
    res.status(500)
    res.jsonRaw("""{"error":"Internal Server Error"}""")
    return

  let contentSnapshot = copyOwnedString(loaded.content)
  let packedPairs = packTemplatePairs(pairs)
  let body = await runOffload(renderTemplateOffThread(contentSnapshot, packedPairs))
  res.sendHtmlBody(body)

## Async template: render ``viewName`` with ``pairs`` on an offload thread and send the HTML.
template renderOffload*(res: Response, viewName: string, pairs: openArray[(string, string)]): untyped =
  block:
    var renderOffloadPairsSeq = newSeqOfCap[(string, string)](pairs.len)
    for renderOffloadPair in pairs:
      renderOffloadPairsSeq.add(renderOffloadPair)
    renderOffloadSeq(res, viewName, move(renderOffloadPairsSeq))

## Terminal writer: send ``content`` as text/html and finalize the response; later writes are dropped.
proc html*(res: Response, content: sink string) {.inline.} =
  res.sendHtmlBody(move(content))

proc primeNativeStreamingResponse(
  res: Response,
  defaultContentType: string,
  stripFramingHeaders: bool = false
): bool {.inline.} =
  res.native.applyStatusCode(res.statusCode)
  var shouldClose = res.native.connectionCloseEnabled()
  var hasContentType = false

  if res.headersInited and res.headers.len > 0:
    for k, v in res.headers:
      if stripFramingHeaders and (k == HeaderTransferEncoding or k == HeaderContentLength):
        continue
      res.native.setHeader(k, v)
      if k == HeaderConnection:
        shouldClose = hasHeaderToken(v, "close")
      elif k == HeaderContentType:
        hasContentType = true

  if defaultContentType.len > 0 and not hasContentType:
    res.native.setHeader(HeaderContentType, defaultContentType)
  if res.setCookies.len > 0:
    for cookie in res.setCookies:
      res.native.setHeader(HeaderSetCookie, cookie)
  shouldClose

## Begin a chunked transfer-encoding response with ``contentType``; returns whether it started.
proc startChunked*(res: Response, contentType: string = MimeTextUtf8): bool =
  ## Begin chunked transfer encoding response.
  if res.shouldDropLateWrite():
    return false
  if res.finished:
    return false

  let shouldClose = res.primeNativeStreamingResponse(contentType, stripFramingHeaders = true)
  res.native.setConnectionCloseEnabled(shouldClose)
  let started = res.native.startChunkedStream(contentType)
  if started:
    res.finished = true
  started

## Begin a chunked response with a text/html content type.
proc startChunkedHtml*(res: Response): bool {.inline.} =
  res.startChunked(MimeHtmlUtf8)

## Write one chunk to the started chunked stream; returns whether the write was accepted.
proc writeChunk*(res: Response, chunk: sink string): bool {.inline.} =
  if res.shouldDropLateWrite():
    return false
  if not res.finished:
    return false
  res.native.writeChunkedStream(move(chunk))

## Finish the chunked stream, optionally closing the connection after the final chunk.
proc endChunked*(res: Response, closeAfterWrite: bool = false): bool {.inline.} =
  if res.shouldDropLateWrite():
    return false
  if not res.finished:
    return false
  res.native.finishChunkedStream(closeAfterWrite)

## Begin a server-sent events stream with no-buffer/no-cache defaults and an optional retry hint.
proc sseStart*(res: Response, retryMs: int = -1): bool =
  ## Begin an SSE stream with conservative no-buffer/no-cache defaults.
  if res.shouldDropLateWrite():
    return false
  if res.finished:
    return false
  discard res.set(HeaderCacheControl, "no-cache")
  discard res.set(HeaderConnection, "keep-alive")
  discard res.set(HeaderXAccelBuffering, "no")
  if not res.startChunked(MimeEventStreamUtf8):
    return false
  if retryMs >= 0:
    var retryLine = newStringOfCap(24)
    retryLine.add("retry: ")
    fastIntToStr(retryMs, retryLine)
    retryLine.add("\n\n")
    return res.writeChunk(retryLine)
  true

## Write an SSE comment line to the stream; returns whether the write was accepted.
proc sseComment*(res: Response, comment: string): bool {.inline.} =
  if res.shouldDropLateWrite():
    return false
  if not res.finished:
    return false
  var sanitized = newStringOfCap(comment.len + 16)
  sanitized.add(": ")
  var i = 0
  while i < comment.len:
    let c = comment[i]
    if c == '\r':
      if i + 1 < comment.len and comment[i + 1] == '\n':
        inc i
      sanitized.add("\n: ")
    elif c == '\n':
      sanitized.add("\n: ")
    else:
      sanitized.add(c)
    inc i
  sanitized.add("\n\n")
  res.writeChunk(sanitized)

when defined(singleThread):
  var sseChunkBuf: string
else:
  var sseChunkBuf {.threadvar.}: string

proc hasNewline(s: string): bool {.inline.} =
  for i in 0 ..< s.len:
    if s[i] == '\n' or s[i] == '\r':
      return true
  false

proc formatSseIdSafe(chunk: var string, id: string) {.inline.} =
  var hasNull = false
  for c in id:
    if c == '\0':
      hasNull = true
      break
  if not hasNull:
    chunk.add("id: ")
    if not id.hasNewline():
      chunk.add(id)
    else:
      for c in id:
        if c != '\n' and c != '\r':
          chunk.add(c)
    chunk.add('\n')

proc formatSseEventName(chunk: var string, event: string) {.inline.} =
  chunk.add("event: ")
  if not event.hasNewline():
    chunk.add(event)
  else:
    for c in event:
      if c != '\n' and c != '\r':
        chunk.add(c)
  chunk.add('\n')

proc formatSseData(chunk: var string, data: string) {.inline.} =
  if data.len == 0:
    chunk.add("data:\n")
    return
  if not data.hasNewline():
    chunk.add("data: ")
    chunk.add(data)
    chunk.add('\n')
    return
  var lineStart = 0
  var i = 0
  while i < data.len:
    if data[i] == '\n' or data[i] == '\r':
      chunk.add("data: ")
      if i > lineStart:
        chunk.add(data[lineStart ..< i])
      chunk.add('\n')
      if data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n':
        inc i
      lineStart = i + 1
    inc i
  if lineStart < data.len:
    chunk.add("data: ")
    chunk.add(data[lineStart ..< data.len])
    chunk.add('\n')

## Write one SSE event with optional event name, id, and retry; returns success.
proc sseEvent*(
  res: Response,
  data: string,
  event: string = "",
  id: string = "",
  retryMs: int = -1
): bool =
  if res.shouldDropLateWrite():
    return false
  if not res.finished:
    return false
  sseChunkBuf.setLen(0)
  if id.len > 0:
    formatSseIdSafe(sseChunkBuf, id)
  if event.len > 0:
    formatSseEventName(sseChunkBuf, event)
  if retryMs >= 0:
    sseChunkBuf.add("retry: ")
    fastIntToStr(retryMs, sseChunkBuf)
    sseChunkBuf.add('\n')
  formatSseData(sseChunkBuf, data)
  sseChunkBuf.add('\n')
  res.writeChunk(sseChunkBuf)

## Return the thread-local batch buffer for composing multiple SSE events.
proc sseBatchStart*(res: Response): var string =
  sseChunkBuf.setLen(0)
  sseChunkBuf

## Append one SSE event to the batch buffer without sending it.
proc sseBatchEvent*(
  buf: var string,
  data: string,
  event: string = "",
  id: string = "",
  retryMs: int = -1
) =
  if id.len > 0:
    formatSseIdSafe(buf, id)
  if event.len > 0:
    formatSseEventName(buf, event)
  if retryMs >= 0:
    buf.add("retry: ")
    fastIntToStr(retryMs, buf)
    buf.add('\n')
  formatSseData(buf, data)
  buf.add('\n')

## Send the accumulated SSE batch buffer as one chunk and clear it.
proc sseBatchFlush*(res: Response, buf: var string): bool =
  if res.shouldDropLateWrite():
    return false
  if not res.finished:
    return false
  if buf.len == 0:
    return true
  let ok = res.writeChunk(buf)
  buf.setLen(0)
  ok

## End the SSE chunked stream, optionally closing the connection after the write.
proc sseEnd*(res: Response, closeAfterWrite: bool = true): bool {.inline.} =
  if res.shouldDropLateWrite():
    return false
  if not res.finished:
    return false
  res.endChunked(closeAfterWrite = closeAfterWrite)

## Adaptive ``PageBufferSendPolicy`` using the default contiguous/chunked byte thresholds.
proc defaultPageBufferSendPolicy*(): PageBufferSendPolicy {.inline.} =
  PageBufferSendPolicy(
    mode: pbsmAuto,
    contiguousThresholdBytes: DefaultAdaptiveContiguousPageBufferThreshold,
    chunkedThresholdBytes: DefaultAdaptiveChunkedPageBufferThreshold
  )

## Throughput-biased adaptive page buffer send policy with reduced chunk framing overhead.
proc throughputPageBufferSendPolicy*(
  contiguousThresholdBytes: int = DefaultThroughputContiguousPageBufferThreshold,
  chunkedThresholdBytes: int = DefaultThroughputChunkedPageBufferThreshold
): PageBufferSendPolicy {.inline.} =
  ## Throughput-biased adaptive policy tuned to reduce chunk framing/copy overhead.
  PageBufferSendPolicy(
    mode: pbsmAuto,
    contiguousThresholdBytes: max(0, contiguousThresholdBytes),
    chunkedThresholdBytes: max(0, chunkedThresholdBytes)
  )

proc selectPageBufferSendMode(
  policy: PageBufferSendPolicy,
  payloadBytes: int
): PageBufferSendMode {.inline.} =
  if policy.mode != pbsmAuto:
    return policy.mode

  let contiguousThreshold = max(0, policy.contiguousThresholdBytes)
  if contiguousThreshold > 0 and payloadBytes <= contiguousThreshold:
    return pbsmContiguous

  let chunkedThreshold = max(0, policy.chunkedThresholdBytes)
  if chunkedThreshold > 0 and payloadBytes >= chunkedThreshold:
    return pbsmChunked

  pbsmTryEnd

proc selectContentTypeLine(contentType: string): string {.inline.} =
  if contentType.len == MimeHtmlUtf8.len and contentType == MimeHtmlUtf8:
    HeaderLineHtmlContentType
  elif contentType.len == MimeTextUtf8.len and contentType == MimeTextUtf8:
    HeaderLineTextContentType
  elif contentType.len == MimeJsonUtf8.len and contentType == MimeJsonUtf8:
    HeaderLineJsonContentType
  else:
    ""

proc pageBufferNeedsFinalizedBody(res: Response): bool {.inline.} =
  if res == nil:
    return false
  if res.beforeFinalizeHooks.len > 0:
    return true
  if res.compress or res.responseDisallowsBody():
    return true
  if res.headersInited and res.headers.contains(HeaderETag):
    return true
  if res.locals != nil and res.locals.getOrDefault(LocalEtagEnabled, "") == "1":
    return true
  if res.request != nil and res.request.locals != nil:
    return res.request.locals.getOrDefault(LocalServerTimingEnabled, "") == "1" and
      res.request.locals.getOrDefault(LocalServerTimingStart, "").len > 0
  false

when defined(singleThread):
  var
    cachedPageBufHeaderPrefix: string
    cachedPageBufHeaderPrefixHash: uint64
else:
  var
    cachedPageBufHeaderPrefix {.threadvar.}: string
    cachedPageBufHeaderPrefixHash {.threadvar.}: uint64

proc buildPageBufferHeaderPrefix(
  res: Response,
  ctLine: string,
  shouldClose: bool
): string {.inline.} =
  result = newStringOfCap(512)
  result.add(StatusLines[200])
  result.add(ctLine)
  if shouldClose:
    result.add(HeaderLineConnectionClose)
  else:
    result.add(HeaderLineConnectionKeepAlive)
  if res.headersInited and res.headers.len > 0:
    for kv, vv in res.headers.pairsView():
      if kv.equalsAscii(HeaderContentType) or kv.equalsAscii(HeaderConnection) or
         kv.equalsAscii(HeaderContentLength) or kv.equalsAscii(HeaderTransferEncoding):
        continue
      result.appendRawPtr(kv.data, kv.len)
      result.add(": ")
      result.appendRawPtr(vv.data, vv.len)
      result.add("\r\n")
  result.add(HeaderLineContentLengthPrefix)

proc headerPrefixCacheKey(
  res: Response,
  ctLine: string,
  shouldClose: bool
): uint64 {.inline.} =
  var h = uint64(ctLine.len)
  h = h xor (uint64(shouldClose.ord) shl 8)
  h = h xor (uint64(res.headers.len) shl 16)
  h

proc trySendPageBufferZeroCopy(
  res: Response,
  content: var PageBuffer,
  contentType: string
): bool {.inline.} =
  if res.native == nil:
    return false
  if res.statusCode != 200:
    return false
  if res.setCookies.len > 0:
    return false
  if res.compress:
    return false
  if not content.isSinglePage():
    return false

  let ctLine = selectContentTypeLine(contentType)
  if ctLine.len == 0:
    return false

  let shouldClose = res.native.connectionCloseEnabled()
  let canUsePrefixCache = not (res.headersInited and res.headers.len > 0)
  let cacheKey =
    if canUsePrefixCache:
      headerPrefixCacheKey(res, ctLine, shouldClose)
    else:
      0'u64

  var prefix: string
  if canUsePrefixCache and cachedPageBufHeaderPrefix.len > 0 and cachedPageBufHeaderPrefixHash == cacheKey:
    prefix = cachedPageBufHeaderPrefix
  else:
    prefix = buildPageBufferHeaderPrefix(res, ctLine, shouldClose)
    if canUsePrefixCache:
      cachedPageBufHeaderPrefix = prefix
      cachedPageBufHeaderPrefixHash = cacheKey

  let bodyLen = content.buffered
  res.headerBuf.setLen(0)
  res.headerBuf.add(prefix)
  fastIntToStr(bodyLen, res.headerBuf)
  res.headerBuf.add("\r\n")
  res.headerBuf.add(getDateHeaderLine())
  res.headerBuf.add("\r\n")

  let pageData = content.firstPageData()
  res.native.sendPreparedResponseRawBody(res.headerBuf, pageData.dataPtr, pageData.dataLen, shouldClose)
  res.native.markBodySent()
  content.clear()
  res.finished = true
  true

## Send a ``PageBuffer`` body using the policy's framing mode; returns whether it was sent.
proc sendPageBuffer*(
  res: Response,
  content: var PageBuffer,
  contentType: string = MimeTextUtf8,
  policy: PageBufferSendPolicy = defaultPageBufferSendPolicy()
): bool =
  if res.shouldDropLateWrite():
    return false
  if res.finished:
    return false

  if content.buffered <= 0:
    if contentType.len > 0:
      res.contentType(contentType)
    res.send("")
    return true

  if res.pageBufferNeedsFinalizedBody():
    let body = content.takeStringAndClear()
    content.release()
    if contentType.len > 0:
      res.contentType(contentType)
    res.send(body)
    return true

  if res.trySendPageBufferZeroCopy(content, contentType):
    content.release()
    return true

  let mode = selectPageBufferSendMode(policy, content.buffered)

  case mode
  of pbsmContiguous:
    let body = content.takeStringAndClear()
    content.release()
    if contentType.len > 0:
      res.contentType(contentType)
    res.send(body)
    return true
  of pbsmChunked:
    if not res.startChunked(contentType):
      return res.sendPageBuffer(
        content,
        contentType,
        PageBufferSendPolicy(
          mode: pbsmTryEnd,
          contiguousThresholdBytes: policy.contiguousThresholdBytes,
          chunkedThresholdBytes: policy.chunkedThresholdBytes
        )
      )
    let flushed = content.flushToRaw(proc(segmentPtr: pointer, segmentLen: int): bool =
      if segmentLen <= 0:
        return true
      var segment = newString(segmentLen)
      copyMem(addr segment[0], segmentPtr, segmentLen)
      res.writeChunk(segment)
    )
    content.release()
    discard res.endChunked(closeAfterWrite = not flushed)
    return flushed
  of pbsmTryEnd:
    let shouldClose = res.primeNativeStreamingResponse(contentType, stripFramingHeaders = true)
    res.native.setConnectionCloseEnabled(shouldClose)

    let totalSize = uint64(content.buffered)
    let queued = content.flushToRaw(proc(segmentPtr: pointer, segmentLen: int): bool =
      if segmentLen <= 0:
        return true
      let outcome = res.native.tryEndRaw(segmentPtr, segmentLen, totalSize, false)
      outcome.ok
    )
    content.release()
    if not queued:
      res.finished = true
      res.native.markBodySent()
      return false
    res.finished = true
    return true
  of pbsmAuto:
    return false

## Send HTML from a ``PageBuffer`` using the adaptive send policy; returns whether it completed.
proc htmlFromPageBuffer*(
  res: Response,
  content: var PageBuffer,
  chunkedThreshold: int = DefaultChunkedPageBufferThreshold
): bool =
  ## Backward-compatible HTML wrapper around adaptive PageBuffer send policy.
  var policy = defaultPageBufferSendPolicy()
  policy.chunkedThresholdBytes = chunkedThreshold
  res.sendPageBuffer(content, MimeHtmlUtf8, policy)

## Terminal writer: send ``content`` as text/plain and finalize the response; later writes are dropped.
proc text*(res: Response, content: sink string) {.inline.} =
  if res.shouldDropLateWrite():
    return
  if res.finished:
    return
  res.runBeforeFinalizeHooks()
  res.finished = true
  res.applyServerTimingHeader()

  let hasMiddlewareState = res.locals != nil and res.locals.len > 0
  if res.statusCode == 200 and not res.compress and
     not hasMiddlewareState and
     not res.headersInited and res.setCookies.len == 0 and
     res.requestMethodKind != hmHead:
    if res.trySendSimpleFramedResponse(content, false, HeaderLineTextContentType):
      return

  var body = content

  var noBody = res.responseDisallowsBody()
  if not noBody:
    body = res.maybeCompressBody(content, MimeTextUtf8)
  let representationLength = res.headRepresentationLength(body.len)
  var validatorBody = body
  if noBody and res.requestMethodKind == hmHead:
    validatorBody = content
  res.applyEtagPolicy(validatorBody, body, noBody)
  if noBody:
    body.setLen(0)
  if res.trySendSimpleFramedResponse(body, noBody, HeaderLineTextContentType, representationLength):
    return

  res.headerBuf.setLen(0)
  if res.statusCode == 200:
    res.headerBuf.add(StatusLines[200])
  else:
    res.headerBuf.add(getStatusLine(res.statusCode))

  var hasConnection = false
  var hasContentType = false
  var hasContentLength = false
  var shouldClose = res.native.connectionCloseEnabled()
  let preserveExplicitContentLength = noBody and res.requestMethodKind == hmHead
  let omitContentType = res.omitContentTypeForNoBody(noBody)

  if res.headersInited and res.headers.len > 0:
    for k, v in res.headers:
      if k == HeaderTransferEncoding:
        continue
      if k == HeaderContentType and omitContentType:
        continue
      if k == HeaderContentLength and not preserveExplicitContentLength:
        continue
      res.headerBuf.add(k)
      res.headerBuf.add(": ")
      res.headerBuf.add(v)
      res.headerBuf.add("\r\n")
      if k == HeaderContentType:
        hasContentType = true
      elif k == HeaderContentLength:
        hasContentLength = true
      elif k == HeaderConnection:
        hasConnection = true
        shouldClose = hasHeaderToken(v, "close")
  appendSetCookieHeaders(res.headerBuf, res)

  if not hasContentType and not omitContentType:
    res.headerBuf.add(HeaderLineTextContentType)
  if noBody:
    if res.statusCode == 205:
      res.headerBuf.add(HeaderLineContentLengthZero)
    elif representationLength >= 0 and not hasContentLength:
      res.headerBuf.add(HeaderLineContentLengthPrefix)
      fastIntToStr(representationLength, res.headerBuf)
      res.headerBuf.add("\r\n")
  else:
    res.headerBuf.add(HeaderLineContentLengthPrefix)
    fastIntToStr(body.len, res.headerBuf)
    res.headerBuf.add("\r\n")
  if not hasConnection:
    if shouldClose:
      res.headerBuf.add(HeaderLineConnectionClose)
    else:
      res.headerBuf.add(HeaderLineConnectionKeepAlive)
  res.headerBuf.add(getDateHeaderLine())
  res.headerBuf.add("\r\n")
  res.native.sendPreparedResponse(res.headerBuf, body, shouldClose)
  res.native.markBodySent()

## Terminal writer: send ``content`` with an application/xml content type; later writes are dropped.
proc xml*(res: Response, content: sink string) =
  res.contentType(MimeXmlUtf8)
  res.send(move(content))

## Set the status code and send the standard reason phrase as a text body.
proc sendStatus*(res: Response, code: int) {.inline.} =
  res.status(code)
  if code.statusDisallowsBody():
    res.send("")
    return
  let message = case code
    of 200: "OK"
    of 201: "Created"
    of 301: "Moved Permanently"
    of 302: "Found"
    of 400: "Bad Request"
    of 401: "Unauthorized"
    of 403: "Forbidden"
    of 404: "Not Found"
    of 405: "Method Not Allowed"
    of 500: "Internal Server Error"
    else: "Unknown"
  res.send(message)

## Respond with ``statusCode`` (default 302), a Location header, and an HTML redirect page.
proc redirect*(res: Response, url: string, statusCode: int = 302) {.inline.} =
  res.status(statusCode)
  res.set("location", url)
  let safeUrl = escapeHtml(url)
  res.contentType(MimeHtmlUtf8)
  res.send("<html><body><p>Redirecting to <a href=\"" & safeUrl & "\">" & safeUrl & "</a></p></body></html>")

## Send a 404 response with a JSON error body; finalizes the response.
proc notFound*(res: Response) {.inline.} =
  res.status(404)
  res.jsonRaw("""{"error":"Not Found"}""")

## Send a 400 response with a JSON error body containing ``message``.
proc badRequest*(res: Response, message: string = "Bad Request") {.inline.} =
  res.status(400)
  var b = initJsonBuilder(64)
  b.add("""{"error":""")
  b.addEscaped(message)
  b.add("}")
  res.jsonRaw(b.finish())

proc coercionSourceLabel(source: RequestFieldSource): string {.inline.} =
  case source
  of rfsQuery: "query"
  of rfsParam: "param"
  of rfsHeader: "header"
  of rfsCookie: "cookie"
  of rfsLocal: "local"
  of rfsBody: "body"

## Send a deterministic 400 JSON error for a typed request coercion failure.
proc badRequest*(res: Response, coercion: RequestCoercionError) {.inline.} =
  ## Deterministic 400 mapping for typed request coercion helpers.
  res.status(400)
  var b = initJsonBuilder(192)
  b.add("""{"error":"Bad Request","source":""")
  b.addEscaped(coercionSourceLabel(coercion.source))
  b.add("""","field":""")
  b.addEscaped(coercion.field)
  b.add("""","reason":""")
  b.addEscaped(coercion.reason)
  if coercion.rawValue.len > 0:
    b.add("""","value":""")
    b.addEscaped(coercion.rawValue)
  b.add(""""}""")
  res.jsonRaw(b.finish())

## Send a 401 response with a JSON error body containing ``message``.
proc unauthorized*(res: Response, message: string = "Unauthorized") {.inline.} =
  res.status(401)
  var b = initJsonBuilder(64)
  b.add("""{"error":""")
  b.addEscaped(message)
  b.add("}")
  res.jsonRaw(b.finish())

## Send a 403 response with a JSON error body containing ``message``.
proc forbidden*(res: Response, message: string = "Forbidden") {.inline.} =
  res.status(403)
  var b = initJsonBuilder(64)
  b.add("""{"error":""")
  b.addEscaped(message)
  b.add("}")
  res.jsonRaw(b.finish())

## Send a 500 response with a JSON error body containing ``message``.
proc serverError*(res: Response, message: string = "Internal Server Error") {.inline.} =
  res.status(500)
  var b = initJsonBuilder(64)
  b.add("""{"error":""")
  b.addEscaped(message)
  b.add("}")
  res.jsonRaw(b.finish())

# HTMX helpers
## Set the hx-trigger response header for HTMX; returns ``res`` for chaining.
proc htmxTrigger*(res: Response, event: string): Response {.inline, discardable.} =
  res.set("hx-trigger", event)

## Set the hx-redirect response header for HTMX; returns ``res`` for chaining.
proc htmxRedirect*(res: Response, url: string): Response {.inline, discardable.} =
  res.set("hx-redirect", url)

## Set the hx-refresh response header for HTMX; returns ``res`` for chaining.
proc htmxRefresh*(res: Response): Response {.inline, discardable.} =
  res.set("hx-refresh", "true")

## Terminal writer: send an HTMX HTML fragment with a text/html content type; later writes are dropped.
proc fragment*(res: Response, html: sink string) {.inline.} =
  res.contentType("text/html; charset=utf-8")
  res.send(move(html))

## Append ``field`` to the Vary response header.
proc vary*(res: Response, field: string): Response {.inline, discardable.} =
  res.append("vary", field)

## Set the Accept-Ranges response header to ``unit`` (default "bytes").
proc acceptRanges*(res: Response, unit: string = "bytes"): Response {.inline, discardable.} =
  res.set("accept-ranges", unit)

## Set a Content-Range response header for a partial (206) response.
proc contentRange*(
  res: Response,
  unit: string,
  startPos: int,
  endPos: int,
  total: int
): Response {.inline, discardable.} =
  if startPos < 0 or endPos < startPos:
    return res
  res.set("content-range", contentRangeValue(unit, startPos, endPos, total))

## Set an unsatisfied Content-Range header (416) for the given total size.
proc contentRangeUnsatisfied*(res: Response, unit: string, total: int): Response {.inline, discardable.} =
  res.set("content-range", unsatisfiedContentRangeValue(unit, total))

## Apply the windowed-items range decision status and range headers to ``res``.
proc applyWindowedItemsDecision*(
  res: Response,
  decision: WindowedItemsDecision,
  unit: string = "items",
  includeVaryRange: bool = true
): Response {.discardable.} =
  ## Apply range-window status and headers consistently.
  discard res.acceptRanges(unit)
  if includeVaryRange:
    discard res.vary("range")
  case decision.statusCode
  of 206:
    discard res.status(206)
    discard res.contentRange(unit, decision.start, decision.finish, decision.total)
  of 416:
    discard res.status(416)
    discard res.contentRangeUnsatisfied(unit, decision.total)
  of 400:
    discard res.status(400)
  else:
    discard res.status(max(200, decision.statusCode))
  res

## Register a writable callback for progressive ``tryEnd`` writes; returns ``res`` for chaining.
proc onWritable*(res: Response, handler: HttpWritableHandler): Response {.inline, discardable.} =
  ## Register writable callback for progressive tryEnd responses.
  if res != nil and res.native != nil:
    discard res.native.onWritable(handler)
  res

## Return the current write offset used by progressive ``tryEnd`` writes.
proc getWriteOffset*(res: Response): uint64 {.inline.} =
  ## Return current offset for tryEnd progressive writes.
  if res == nil or res.native == nil:
    return 0'u64
  res.native.getWriteOffset()

## Progressive response write API similar to uWS tryEnd; returns completion and responded state.
proc tryEnd*(
  res: Response,
  chunk: string,
  totalSize: uint64,
  closeAfterWrite: bool = false
): tuple[ok: bool, hasResponded: bool] {.inline.} =
  ## Progressive response write API similar to uWS tryEnd.
  if res == nil or res.native == nil:
    return (false, false)
  let outcome = res.native.tryEnd(chunk, totalSize, closeAfterWrite)
  if outcome.hasResponded:
    res.finished = true
  outcome

## Pause HTTP request parsing on this connection; returns ``res`` for chaining.
proc pauseRead*(res: Response): Response {.inline, discardable.} =
  ## Pause HTTP request parsing on this connection.
  if res != nil and res.native != nil:
    res.native.pauseRead()
  res

## Resume HTTP request parsing and process buffered input; returns ``res`` for chaining.
proc resumeRead*(res: Response): Response {.inline, discardable.} =
  ## Resume HTTP request parsing and process buffered input.
  if res != nil and res.native != nil:
    res.native.resumeRead()
  res

## Whether HTTP request parsing is currently paused on this connection.
proc isReadPaused*(res: Response): bool {.inline.} =
  if res == nil or res.native == nil:
    return false
  res.native.isReadPaused()
