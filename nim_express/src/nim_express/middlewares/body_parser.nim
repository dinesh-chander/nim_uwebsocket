## Body parser middlewares: json(), urlencoded(), text(), raw(), xml()
##
## All parsers read the full request body into memory before processing.
## Streaming body parsing is not supported. For large file uploads, use the
## multipart parser's maxFileSize limit to prevent out-of-memory conditions.

import std/[asyncdispatch, strutils]
import common
import nim_utils/nim_fastjson/direct_engine

const
  DefaultJsonLimitBytes* = 1024 * 1024
  DefaultTextLimitBytes* = 1024 * 1024
  DefaultRawLimitBytes* = 1024 * 1024
  DefaultUrlEncodedLimitBytes* = 512 * 1024
  DefaultUrlEncodedMaxPairs* = 256
  DefaultUrlEncodedMaxKeyBytes* = 1024
  DefaultUrlEncodedMaxValueBytes* = 8192
  DefaultXmlLimitBytes* = 1024 * 1024

type
  JsonParserOptions* = object
    limitBytes*: int
    strict*: bool
    allowEmpty*: bool
    acceptedMimeTypes*: seq[string]

  TextParserOptions* = object
    limitBytes*: int
    acceptedMimeTypes*: seq[string]
    requireUtf8*: bool

  RawParserOptions* = object
    limitBytes*: int
    acceptedMimeTypes*: seq[string]

  UrlEncodedParserOptions* = object
    limitBytes*: int
    maxPairs*: int
    maxKeyBytes*: int
    maxValueBytes*: int
    plusAsSpace*: bool

  XmlParserOptions* = object
    limitBytes*: int
    acceptedMimeTypes*: seq[string]

## Returns the default options for the JSON body parser.
proc defaultJsonParserOptions*(): JsonParserOptions {.inline.} =
  JsonParserOptions(
    limitBytes: DefaultJsonLimitBytes,
    strict: true,
    allowEmpty: false,
    acceptedMimeTypes: @["application/json", "application/*+json"]
  )

## Returns the default options for the text body parser.
proc defaultTextParserOptions*(): TextParserOptions {.inline.} =
  TextParserOptions(
    limitBytes: DefaultTextLimitBytes,
    acceptedMimeTypes: @["text/*"],
    requireUtf8: false
  )

## Returns the default options for the raw body parser.
proc defaultRawParserOptions*(): RawParserOptions {.inline.} =
  RawParserOptions(
    limitBytes: DefaultRawLimitBytes,
    acceptedMimeTypes: @["*/*"]
  )

## Returns the default options for the urlencoded body parser.
proc defaultUrlEncodedParserOptions*(): UrlEncodedParserOptions {.inline.} =
  UrlEncodedParserOptions(
    limitBytes: DefaultUrlEncodedLimitBytes,
    maxPairs: DefaultUrlEncodedMaxPairs,
    maxKeyBytes: DefaultUrlEncodedMaxKeyBytes,
    maxValueBytes: DefaultUrlEncodedMaxValueBytes,
    plusAsSpace: true
  )

## Returns the default options for the XML body parser.
proc defaultXmlParserOptions*(): XmlParserOptions {.inline.} =
  XmlParserOptions(
    limitBytes: DefaultXmlLimitBytes,
    acceptedMimeTypes: @["application/xml", "text/xml", "application/*+xml"]
  )

## Extracts the lowercased charset parameter from a Content-Type header value, or an empty string if absent.
proc contentTypeCharset*(contentType: string): string =
  let parts = contentType.split(';')
  if parts.len <= 1:
    return ""
  for i in 1 ..< parts.len:
    let part = parts[i].strip()
    if part.len < 8:
      continue
    if part[0..6].toLowerAscii() == "charset":
      let eq = part.find('=')
      if eq >= 0 and eq + 1 < part.len:
        var charset = part[eq + 1 .. ^1].strip().toLowerAscii()
        if charset.len >= 2 and charset[0] == '"' and charset[^1] == '"':
          charset = charset[1 .. ^2]
        return charset
  ""

proc headerContentLength(req: Req): int {.inline.} =
  let raw = req.get("content-length").strip()
  if raw.len == 0:
    return -1
  try:
    let v = parseInt(raw)
    if v < 0: -2
    else: v
  except ValueError:
    -2

proc rejectPayload(res: Res, message: string) {.inline.} =
  res.status(413).send(message)

proc readBodyWithLimit(
  req: Req,
  res: Res,
  limitBytes: int,
  payloadTooLargeMessage: string = "Payload Too Large"
): tuple[ok: bool, body: string] =
  let contentLength = headerContentLength(req)
  if contentLength < -1:
    res.status(400).send("Bad Request")
    return
  if limitBytes >= 0 and contentLength > limitBytes:
    rejectPayload(res, payloadTooLargeMessage)
    return

  let sizeHint = req.rawBodySizeHint()
  if limitBytes >= 0 and sizeHint > limitBytes:
    rejectPayload(res, payloadTooLargeMessage)
    return

  let body = req.rawBody()
  if limitBytes >= 0 and body.len > limitBytes:
    rejectPayload(res, payloadTooLargeMessage)
    return
  (true, body)

proc firstNonWhitespace(body: string): char {.inline.} =
  for c in body:
    if c != ' ' and c != '\t' and c != '\r' and c != '\n':
      return c
  '\0'

proc isHexDigit(c: char): bool {.inline.} =
  (c >= '0' and c <= '9') or
  (c >= 'a' and c <= 'f') or
  (c >= 'A' and c <= 'F')

proc hasMalformedPercentEscape(raw: string): bool {.inline.} =
  var i = 0
  while i < raw.len:
    if raw[i] == '%':
      if i + 2 >= raw.len or not raw[i + 1].isHexDigit() or not raw[i + 2].isHexDigit():
        return true
      i += 3
    else:
      inc i
  false

proc hexNibble(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - 48
  of 'a'..'f': ord(c) - 87
  else: ord(c) - 55

proc decodeUrlComponent(raw: string, plusAsSpace: bool): tuple[ok: bool, value: string] =
  if raw.hasMalformedPercentEscape():
    return (false, "")
  if raw.find('%') < 0 and not (plusAsSpace and raw.find('+') >= 0):
    return (true, raw)
  var value = newStringOfCap(raw.len)
  var i = 0
  while i < raw.len:
    let c = raw[i]
    if c == '%':
      value.add(char((raw[i + 1].hexNibble() shl 4) or raw[i + 2].hexNibble()))
      i += 3
    elif c == '+' and plusAsSpace:
      value.add(' ')
      inc i
    else:
      value.add(c)
      inc i
  (true, value)

proc parseJsonBody(req: Req, res: Res, body: string, opts: JsonParserOptions): bool =
  if body.len == 0:
    if not opts.allowEmpty:
      res.status(400).send("Bad Request")
      return false
    return true
  if opts.strict:
    let lead = firstNonWhitespace(body)
    if lead != '{' and lead != '[':
      res.status(400).send("Bad Request")
      return false
    if not isValidJsonDirect(body):
      res.status(400).send("Bad Request")
      return false
  try:
    req.cacheJsonBody(parseJson(body))
    req.locals["_json_valid"] = "1"
  except CatchableError:
    req.locals["_json_valid"] = "0"
  true

## Parses the body as JSON only when the request carries a JSON Content-Type.
## Requests without a Content-Type (or with a non-matching one) pass through to
## `next()` with the body left unprocessed.
proc json*(
  options: JsonParserOptions = defaultJsonParserOptions()
): AsyncMiddleware =
  let opts = options
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let contentType = contentTypeToken(req.get("content-type"))
    if not matchesAnyMime(contentType, opts.acceptedMimeTypes):
      await next()
      return

    let loaded = readBodyWithLimit(req, res, opts.limitBytes)
    if not loaded.ok:
      return
    if not parseJsonBody(req, res, loaded.body, opts):
      return
    await next()

## Parses the body as text when the Content-Type matches, storing it in the `body_text` request local.
proc text*(
  options: TextParserOptions = defaultTextParserOptions()
): AsyncMiddleware =
  let opts = options
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let rawContentType = req.get("content-type")
    let contentType = contentTypeToken(rawContentType)
    if not matchesAnyMime(contentType, opts.acceptedMimeTypes):
      await next()
      return

    if opts.requireUtf8:
      let charset = contentTypeCharset(rawContentType)
      if charset.len > 0 and charset.replace("-", "") != "utf8":
        res.status(415).send("Unsupported Media Type")
        return

    let loaded = readBodyWithLimit(req, res, opts.limitBytes)
    if not loaded.ok:
      return
    req.locals["body_text"] = loaded.body
    await next()

## Parses the body as raw bytes when the Content-Type matches, storing it in the `body_raw` request local.
proc raw*(
  options: RawParserOptions = defaultRawParserOptions()
): AsyncMiddleware =
  ## Reads the request body as raw bytes and stores it in `req.locals["body_raw"]`.
  ## Nim strings can hold arbitrary binary data (they are length-delimited, not
  ## null-terminated like C strings), so this works correctly for binary content.
  let opts = options
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let contentType = contentTypeToken(req.get("content-type"))
    if contentType.len == 0 or not matchesAnyMime(contentType, opts.acceptedMimeTypes):
      await next()
      return

    let loaded = readBodyWithLimit(req, res, opts.limitBytes)
    if not loaded.ok:
      return
    req.locals["body_raw"] = loaded.body
    await next()

proc parseUrlEncodedIntoLocals(req: Req, res: Res, body: string, opts: UrlEncodedParserOptions): bool =
  try:
    var parsedPairs = 0
    var startPos = 0
    var i = 0

    while true:
      if i >= body.len or body[i] == '&':
        if i > startPos:
          if parsedPairs >= opts.maxPairs:
            rejectPayload(res, "Payload Too Large")
            return false
          inc parsedPairs

          var sepPos = startPos
          while sepPos < i and body[sepPos] != '=':
            inc sepPos

          # A key-only segment (no '=') is treated as a key with an empty
          # value, matching standard urlencoded form semantics.
          let valueStart = if sepPos < i: sepPos + 1 else: i
          let keyRaw = body[startPos ..< sepPos]
          let valueRaw = body[valueStart ..< i]

          if keyRaw.len == 0:
            discard  # empty key ("=value"); skip
          elif keyRaw.len > opts.maxKeyBytes or valueRaw.len > opts.maxValueBytes:
            rejectPayload(res, "Payload Too Large")
            return false
          else:
            let decodedKey = decodeUrlComponent(keyRaw, opts.plusAsSpace)
            let decodedValue = decodeUrlComponent(valueRaw, opts.plusAsSpace)
            if not decodedKey.ok or not decodedValue.ok:
              res.status(400).send("Bad Request")
              return false
            let key = decodedKey.value
            let value = decodedValue.value
            # Skip empty keys and internal-namespace keys (keys starting with
            # '_' are reserved for middleware state; prevents form injection).
            if key.len > 0 and key[0] != '_':
              req.locals["form_" & key] = value

        if i >= body.len:
          break
        startPos = i + 1
      inc i
    true
  except CatchableError:
    if res.statusCode != 413:
      res.status(400).send("Bad Request")
    false

## Parses a urlencoded form body, storing each decoded field in a `form_`-prefixed request local.
proc urlencoded*(
  options: UrlEncodedParserOptions = defaultUrlEncodedParserOptions()
): AsyncMiddleware =
  let opts = options
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let contentType = contentTypeToken(req.get("content-type"))
    if contentType != "application/x-www-form-urlencoded":
      await next()
      return

    let loaded = readBodyWithLimit(req, res, opts.limitBytes)
    if not loaded.ok:
      return

    if not parseUrlEncodedIntoLocals(req, res, loaded.body, opts):
      return

    await next()

## Parses the body as XML text when the Content-Type matches, storing it in the `body_xml` request local.
proc xml*(
  options: XmlParserOptions = defaultXmlParserOptions()
): AsyncMiddleware =
  let opts = options
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let contentType = contentTypeToken(req.get("content-type"))
    if not matchesAnyMime(contentType, opts.acceptedMimeTypes):
      await next()
      return

    let loaded = readBodyWithLimit(req, res, opts.limitBytes)
    if not loaded.ok:
      return
    if loaded.body.len == 0:
      res.status(400).send("Bad Request")
      return
    req.locals["body_xml"] = loaded.body
    await next()

## Middleware that auto-detects JSON or urlencoded bodies and runs the matching parser before calling `next`.
proc bodyParser*(): AsyncMiddleware =
  let jsonMw = json()
  let urlencodedMw = urlencoded()
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let contentType = contentTypeToken(req.get("content-type"))
    if matchesAnyMime(contentType, @["application/json", "application/*+json"]):
      await jsonMw(req, res, next)
    elif contentType == "application/x-www-form-urlencoded":
      await urlencodedMw(req, res, next)
    else:
      await next()

## Synchronous variant of `bodyParser`. Supports JSON and urlencoded parsing
## only (no text/raw/xml). Kept inline for the sync hot path; if parsing
## behavior changes, update both this and the async `json()`/`urlencoded()`
## middlewares.
proc bodyParserSync*(): SyncNextMiddleware =
  let jsonOpts = defaultJsonParserOptions()
  let urlencodedOpts = defaultUrlEncodedParserOptions()
  result = proc(req: Req, res: Res, next: proc() {.closure.}) =
    let contentType = contentTypeToken(req.get("content-type"))
    if matchesAnyMime(contentType, jsonOpts.acceptedMimeTypes):
      let loaded = readBodyWithLimit(req, res, jsonOpts.limitBytes)
      if not loaded.ok:
        return
      if not parseJsonBody(req, res, loaded.body, jsonOpts):
        return
      next()
      return

    if contentType == "application/x-www-form-urlencoded":
      let loaded = readBodyWithLimit(req, res, urlencodedOpts.limitBytes)
      if not loaded.ok:
        return
      if not parseUrlEncodedIntoLocals(req, res, loaded.body, urlencodedOpts):
        return
      next()
      return

    next()
