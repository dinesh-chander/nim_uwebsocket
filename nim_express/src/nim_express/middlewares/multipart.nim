## Multipart form-data parser middleware (bounded, opt-in).

import std/[asyncdispatch, os, strutils, sysrand, tables]
import common

type
  MultipartOptions* = object
    maxBodyBytes*: int
    maxFields*: int
    maxFiles*: int
    maxFieldBytes*: int
    maxFileBytes*: int
    uploadDir*: string

## Returns a `MultipartOptions` with 10MiB body, 64KiB field, and 8MiB file
## limits, 128 fields, 16 files, and no persisted upload directory.
proc defaultMultipartOptions*(): MultipartOptions {.inline.} =
  MultipartOptions(
    maxBodyBytes: 10 * 1024 * 1024,
    maxFields: 128,
    maxFiles: 16,
    maxFieldBytes: 64 * 1024,
    maxFileBytes: 8 * 1024 * 1024,
    uploadDir: ""
  )

## Generates a 24-character hex upload token from 12 random bytes, returning
## an empty string when the random source fails.
proc buildUploadToken(): string =
  var bytes: array[12, byte]
  result = newStringOfCap(24)
  if urandom(bytes):
    for b in bytes:
      result.add(b.toHex(2))

## Extracts the boundary value from a multipart content-type header, handling
## whitespace and quoted values.
proc contentTypeBoundary(contentType: string): string {.inline.} =
  const ws = {' ', '\t', '\r', '\n', '\f', '\v'}
  const prefix = "boundary"
  let len = contentType.len
  var segStart = 0
  while true:
    var segEnd = contentType.find(';', segStart)
    if segEnd < 0:
      segEnd = len
    var s = segStart
    while s < segEnd and contentType[s] in ws: inc s
    var e = segEnd - 1
    while e >= s and contentType[e] in ws: dec e
    if e - s + 1 >= 9:
      var k = 0
      while k < prefix.len and toLowerAscii(contentType[s + k]) == prefix[k]:
        inc k
      if k == prefix.len:
        var eq = -1
        var m = s
        while m <= e:
          if contentType[m] == '=':
            eq = m
            break
          inc m
        if eq >= 0 and eq + 1 <= e:
          var vs = eq + 1
          var ve = e
          while vs <= ve and contentType[vs] in ws: inc vs
          while ve >= vs and contentType[ve] in ws: dec ve
          if vs <= ve:
            var value = contentType[vs .. ve]
            if value.len >= 2 and value[0] == '"' and value[^1] == '"':
              value = value[1 .. ^2]
            return value
    if segEnd >= len:
      break
    segStart = segEnd + 1
  ""

## Finds `attrName` in a content-disposition value and returns its quoted or
## semicolon-terminated value.
proc extractQuotedAttr(headerValue: string, attrName: string): string {.inline.} =
  let key = attrName & "="
  let lowerKey = key.toLowerAscii()
  var idx = -1
  if headerValue.len >= key.len:
    var i = 0
    while i + key.len <= headerValue.len:
      var j = 0
      while j < key.len and toLowerAscii(headerValue[i + j]) == lowerKey[j]:
        inc j
      if j == key.len:
        idx = i
        break
      inc i
  if idx < 0:
    return ""
  var pos = idx + key.len
  if pos >= headerValue.len:
    return ""
  if headerValue[pos] == '"':
    inc pos
    let endPos = headerValue.find('"', pos)
    if endPos < 0:
      return ""
    return headerValue[pos ..< endPos]
  let endPos = headerValue.find(';', pos)
  if endPos < 0:
    return headerValue[pos .. ^1].strip()
  headerValue[pos ..< endPos].strip()

## Keeps only alphanumerics, underscores, hyphens, dots, and square brackets
## from a form field name.
proc sanitizeFieldName(fieldName: string): string {.inline.} =
  if fieldName.len == 0:
    return ""
  result = newStringOfCap(fieldName.len)
  for c in fieldName:
    case c
    of 'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '[', ']':
      result.add(c)
    else:
      discard

## Validates a per-part content type, rejecting values over 256 characters or
## containing line breaks or NUL bytes.
proc sanitizePartContentType(ct: string): string {.inline.} =
  if ct.len == 0 or ct.len > 256:
    return "application/octet-stream"
  for c in ct:
    if c == '\r' or c == '\n' or c == '\0':
      return "application/octet-stream"
  ct

## Strips path separators from an upload filename and replaces parent-dir
## sequences with underscores.
proc sanitizeUploadFilename(name: string): string {.inline.} =
  if name.len == 0:
    return ""
  result = newStringOfCap(name.len)
  for c in name:
    case c
    of '/', '\\', '\0':
      discard
    else:
      result.add(c)
  result = result.replace("..", "_")

## Expands a possibly home-relative upload directory, creates it, and returns
## the absolute path, or an empty string on failure.
proc resolveUploadDir(uploadDir: string): string =
  if uploadDir.len == 0:
    return ""
  var dir = uploadDir
  if dir == "~":
    dir = getHomeDir()
  elif dir.startsWith("~/"):
    let home = getHomeDir()
    if home.len > 0:
      let rest =
        if dir.len > 2: dir[2 .. ^1]
        else: ""
      dir =
        if rest.len > 0: home / rest
        else: home
  try:
    let absDir = absolutePath(dir)
    createDir(absDir)
    if dirExists(absDir):
      return absDir
  except OSError:
    discard
  ""

## Stores an in-memory file upload's name, type, payload, and size in
## `req.locals` under the `fieldName` prefix.
proc setFileDataLocals(req: Req, fieldName, fileName, partContentType, payload: string) =
  req.locals["file_" & fieldName & "_name"] = fileName
  req.locals["file_" & fieldName & "_type"] = partContentType
  req.locals["file_" & fieldName & "_data"] = payload
  req.locals["file_" & fieldName & "_size"] = $payload.len

## Stores an in-memory file upload for the `idx`-th value of a repeated file
## field in `req.locals`.
proc setFileDataIndexLocals(req: Req, fieldName: string, idx: int, fileName, partContentType, payload: string) =
  let prefix = "file_" & fieldName & "_" & $idx & "_"
  req.locals[prefix & "name"] = fileName
  req.locals[prefix & "type"] = partContentType
  req.locals[prefix & "data"] = payload
  req.locals[prefix & "size"] = $payload.len

## Stores a persisted file upload's name, type, path, and size in
## `req.locals` under the `fieldName` prefix.
proc setFilePathLocals(req: Req, fieldName, fileName, partContentType, outPath: string, size: int) =
  req.locals["file_" & fieldName & "_name"] = fileName
  req.locals["file_" & fieldName & "_type"] = partContentType
  req.locals["file_" & fieldName & "_path"] = outPath
  req.locals["file_" & fieldName & "_size"] = $size

## Stores a persisted file upload for the `idx`-th value of a repeated file
## field in `req.locals`.
proc setFilePathIndexLocals(req: Req, fieldName: string, idx: int, fileName, partContentType, outPath: string, size: int) =
  let prefix = "file_" & fieldName & "_" & $idx & "_"
  req.locals[prefix & "name"] = fileName
  req.locals[prefix & "type"] = partContentType
  req.locals[prefix & "path"] = outPath
  req.locals[prefix & "size"] = $size

## Copies the last single-valued file locals for `fieldName` into the indexed
## locals so repeated file fields expose both views.
proc backfillFileIndexLocals(req: Req, fieldName: string, idx: int) =
  let prefix = "file_" & fieldName & "_"
  let indexed = "file_" & fieldName & "_" & $idx & "_"
  for suffix in ["name", "type", "data", "path", "size"]:
    let value = req.locals.getOrDefault(prefix & suffix, "")
    if value.len > 0:
      req.locals[indexed & suffix] = value

type
  BoundaryMatch = object
    found: bool
    pos: int
    prefixLen: int
    nextPos: int
    final: bool

# Bound the marker matches examined per search: legitimate bodies contain at
# most maxFields + maxFiles + 1 delimiters, and a delimiter appearing in part
# content is invalid per RFC 2046.
const maxBoundaryMatches = 4096

## Finds the next multipart boundary marker after `startPos`, classifying it
## as final or ordinary; bounds the number of markers examined.
proc findNextBoundary(body, marker: string, startPos: int): BoundaryMatch =
  var search = max(0, startPos)
  var matches = 0
  while search < body.len:
    let pos = body.find(marker, search)
    if pos < 0:
      return
    inc matches
    if matches > maxBoundaryMatches:
      return

    var prefixLen = -1
    if pos == 0:
      prefixLen = 0
    elif pos >= 2 and body[pos - 2] == '\r' and body[pos - 1] == '\n':
      prefixLen = 2
    elif body[pos - 1] == '\n':
      prefixLen = 1

    if prefixLen >= 0:
      let after = pos + marker.len
      if after + 1 < body.len and body[after] == '-' and body[after + 1] == '-':
        var nextPos = after + 2
        if nextPos == body.len:
          return BoundaryMatch(found: true, pos: pos, prefixLen: prefixLen, nextPos: nextPos, final: true)
        if body[nextPos] == '\r' and nextPos + 1 < body.len and body[nextPos + 1] == '\n':
          inc nextPos, 2
          return BoundaryMatch(found: true, pos: pos, prefixLen: prefixLen, nextPos: nextPos, final: true)
        if body[nextPos] == '\n':
          inc nextPos
          return BoundaryMatch(found: true, pos: pos, prefixLen: prefixLen, nextPos: nextPos, final: true)
      elif after < body.len and body[after] == '\r' and after + 1 < body.len and body[after + 1] == '\n':
        return BoundaryMatch(found: true, pos: pos, prefixLen: prefixLen, nextPos: after + 2, final: false)
      elif after < body.len and body[after] == '\n':
        return BoundaryMatch(found: true, pos: pos, prefixLen: prefixLen, nextPos: after + 1, final: false)

    search = pos + 1

## Parses one multipart part into a form field or file upload, enforcing the
## field and file limits in `opts`.
proc parseMultipartPart(
  req: Req,
  res: Res,
  opts: MultipartOptions,
  persistedUploadDir: string,
  part: string,
  fieldCount: var int,
  fileCount: var int,
  fileFieldCounts: var Table[string, int]
): bool =
  if part.len == 0:
    return true

  var rawHeaders = ""
  var payload = ""
  var lineSep = "\r\n"
  let headerEnd = part.find("\r\n\r\n")
  if headerEnd >= 0:
    rawHeaders = part[0 ..< headerEnd]
    payload =
      if headerEnd + 4 < part.len: part[(headerEnd + 4) .. ^1]
      else: ""
  else:
    let lfEnd = part.find("\n\n")
    if lfEnd < 0:
      res.status(400).send("Bad Request")
      return false
    rawHeaders = part[0 ..< lfEnd]
    payload =
      if lfEnd + 2 < part.len: part[(lfEnd + 2) .. ^1]
      else: ""
    lineSep = "\n"

  var disposition = ""
  var partContentType = "application/octet-stream"
  for line in rawHeaders.split(lineSep):
    let sep = line.find(':')
    if sep < 0:
      continue
    let name = line[0 ..< sep].strip().toLowerAscii()
    let value = line[(sep + 1) .. ^1].strip()
    if name == "content-disposition":
      disposition = value
    elif name == "content-type":
      partContentType = sanitizePartContentType(value)

  if disposition.len == 0:
    return true

  let fieldName = sanitizeFieldName(extractQuotedAttr(disposition, "name"))
  if fieldName.len == 0:
    return true
  let fileName = sanitizeUploadFilename(extractQuotedAttr(disposition, "filename"))

  if fileName.len == 0:
    inc fieldCount
    if fieldCount > opts.maxFields or payload.len > opts.maxFieldBytes:
      res.status(413).send("Payload Too Large")
      return false
    req.locals["form_" & fieldName] = payload
    return true

  inc fileCount
  if fileCount > opts.maxFiles or payload.len > opts.maxFileBytes:
    res.status(413).send("Payload Too Large")
    return false

  let fileIdx = fileFieldCounts.getOrDefault(fieldName, 0)
  if fileIdx > 0:
    backfillFileIndexLocals(req, fieldName, fileIdx - 1)
  fileFieldCounts[fieldName] = fileIdx + 1

  if persistedUploadDir.len == 0:
    setFileDataLocals(req, fieldName, fileName, partContentType, payload)
    if fileIdx > 0:
      setFileDataIndexLocals(req, fieldName, fileIdx, fileName, partContentType, payload)
      req.locals["file_" & fieldName & "_count"] = $(fileIdx + 1)
    return true

  let ext = splitFile(fileName).ext
  let safeExt =
    if ext.len > 0 and ext.len <= 16: ext
    else: ""
  let token = buildUploadToken()
  if token.len == 0:
    res.status(500).send("Internal Server Error")
    return false
  let outName = token & safeExt
  let outPath = persistedUploadDir / outName
  try:
    # Known limitation: synchronous write blocks the event loop; async I/O
    # (offload) would require broader changes.
    writeFile(outPath, payload)
  except CatchableError:
    res.status(500).send("Internal Server Error")
    return false
  when defined(posix):
    try:
      setFilePermissions(outPath, {fpUserRead, fpUserWrite})
    except CatchableError:
      discard
  setFilePathLocals(req, fieldName, fileName, partContentType, outPath, payload.len)
  if fileIdx > 0:
    setFilePathIndexLocals(req, fieldName, fileIdx, fileName, partContentType, outPath, payload.len)
    req.locals["file_" & fieldName & "_count"] = $(fileIdx + 1)
  true

## Returns an async middleware that parses multipart/form-data bodies into
## `req.locals`, persisting files when `uploadDir` is configured.
proc multipart*(
  options: MultipartOptions = defaultMultipartOptions()
): AsyncMiddleware =
  let opts = options
  let persistedUploadDir = resolveUploadDir(opts.uploadDir)

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    let contentType = req.get("content-type")
    if "multipart/form-data" notin contentType.toLowerAscii():
      await next()
      return

    let boundary = contentTypeBoundary(contentType)
    if boundary.len == 0 or boundary.len > 256:
      res.status(400).send("Bad Request")
      return

    if opts.maxBodyBytes > 0:
      let clRaw = req.get("content-length").strip()
      if clRaw.len > 0:
        try:
          let cl = parseInt(clRaw)
          if cl < 0:
            res.status(400).send("Bad Request")
            return
          if cl > opts.maxBodyBytes:
            res.status(413).send("Payload Too Large")
            return
        except ValueError:
          res.status(400).send("Bad Request")
          return

      let sizeHint = req.rawBodySizeHint()
      if sizeHint > opts.maxBodyBytes:
        res.status(413).send("Payload Too Large")
        return

    let body = req.rawBody()
    if body.len == 0:
      await next()
      return
    if opts.maxBodyBytes > 0 and body.len > opts.maxBodyBytes:
      res.status(413).send("Payload Too Large")
      return

    try:
      let marker = "--" & boundary
      var fieldCount = 0
      var fileCount = 0
      var fileFieldCounts: Table[string, int]
      var current = findNextBoundary(body, marker, 0)
      if not current.found:
        res.status(400).send("Bad Request")
        return
      if not current.final:
        var partStart = current.nextPos
        while true:
          let nextBoundary = findNextBoundary(body, marker, partStart)
          if not nextBoundary.found:
            res.status(400).send("Bad Request")
            return
          let partEnd = max(partStart, nextBoundary.pos - nextBoundary.prefixLen)
          if partEnd > partStart:
            let part = body[partStart ..< partEnd]
            if not parseMultipartPart(req, res, opts, persistedUploadDir, part, fieldCount, fileCount, fileFieldCounts):
              return
          if nextBoundary.final:
            break
          partStart = nextBoundary.nextPos
    except CatchableError:
      res.status(400).send("Bad Request")
      return

    await next()
