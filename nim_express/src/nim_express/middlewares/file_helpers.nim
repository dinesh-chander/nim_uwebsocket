## File serving helper procs

import std/[asyncdispatch, asyncfile, strutils, os, times]
import common
import ../compression_codec

const
  DefaultStaticFallbackMaxBytes* = 8 * 1024 * 1024
  DefaultStaticFallbackOversizeStatus* = 413

proc generateFileETag(fileInfo: FileInfo): string =
  ## Weak ETag derived from stable file metadata (avoids full file read/hash).
  "W/\"" & $fileInfo.size & "-" & $fileInfo.lastWriteTime.toUnix() & "\""

proc buildHeaderBlock(res: Res, closeAfterWrite: bool): string =
  var headerBlock = newStringOfCap(256)
  headerBlock.add(getStatusLine(res.statusCode))

  var hasConnection = false
  if res.headersInited and res.headers.len > 0:
    for k, v in res.headers:
      let key = sanitizeHeaderName(k)
      if key.len == 0:
        continue
      let safeValue = sanitizeHeaderValue(v)
      if v.len > 0 and safeValue.len == 0:
        continue
      headerBlock.add(key)
      headerBlock.add(": ")
      headerBlock.add(safeValue)
      headerBlock.add("\r\n")
      if key == "connection":
        hasConnection = true
  if res.setCookies.len > 0:
    for cookie in res.setCookies:
      let safeCookie = sanitizeHeaderValue(cookie)
      if cookie.len > 0 and safeCookie.len == 0:
        continue
      headerBlock.add("set-cookie: ")
      headerBlock.add(safeCookie)
      headerBlock.add("\r\n")

  if not hasConnection:
    if closeAfterWrite:
      headerBlock.add("connection: close\r\n")
    else:
      headerBlock.add("connection: keep-alive\r\n")

  headerBlock.add("\r\n")
  headerBlock

## Returns the MIME type for a filename based on its extension, defaulting to application/octet-stream.
proc getMimeType*(filename: string): string =
  let ext = filename.splitFile().ext.toLowerAscii()
  case ext
  of ".html", ".htm": "text/html"
  of ".css": "text/css"
  of ".js": "application/javascript"
  of ".json": "application/json"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".pdf": "application/pdf"
  of ".zip": "application/zip"
  of ".woff": "font/woff"
  of ".woff2": "font/woff2"
  of ".ttf": "font/ttf"
  of ".ico": "image/x-icon"
  else: "application/octet-stream"

proc selectPrecompressedVariant(req: Req, filePath: string): tuple[path: string, encoding: string] =
  let acceptEncoding = req.get("accept-encoding")
  for enc in acceptedEncodingsInPreferenceOrder(acceptEncoding):
    case enc
    of ceZstd:
      let zstPath = filePath & ".zst"
      if fileExists(zstPath):
        return (zstPath, "zstd")
    of ceBrotli:
      let brPath = filePath & ".br"
      if fileExists(brPath):
        return (brPath, "br")
    of ceGzip:
      let gzPath = filePath & ".gz"
      if fileExists(gzPath):
        return (gzPath, "gzip")
    else:
      discard
  (filePath, "")

proc isPathUnderRoot(path: string, root: string): bool =
  if root.len == 0:
    return true
  let absRoot = root.expandFilename()
  let absPath = path.expandFilename()
  absPath == absRoot or absPath.isRelativeTo(absRoot)

proc isSymlinkPath(path: string): bool =
  try:
    let info = getFileInfo(path, followSymlink = false)
    return info.kind in {pcLinkToFile, pcLinkToDir}
  except CatchableError:
    return true

proc hasSymlinkComponent(contentPath: string, trustedRoot: string): bool =
  let absRoot = trustedRoot.expandFilename()
  let absPath = contentPath.expandFilename()
  if absPath == absRoot:
    return absPath.isSymlinkPath()
  if not absPath.isRelativeTo(absRoot):
    return true

  let relPath = relativePath(absPath, absRoot)
  var current = absRoot
  for part in relPath.split({'/', '\\'}):
    if part.len == 0 or part == ".":
      continue
    if part == "..":
      return true
    current = current / part
    if current.isSymlinkPath():
      return true
  false

proc validateStaticContentPath(contentPath: string, trustedRoot: string): bool =
  if trustedRoot.len == 0:
    return true
  try:
    if not contentPath.isPathUnderRoot(trustedRoot):
      return false
    if contentPath.hasSymlinkComponent(trustedRoot):
      return false
    true
  except CatchableError:
    false

proc fallbackMaxBytes(res: Res): int64 =
  if res == nil or res.app == nil:
    return DefaultStaticFallbackMaxBytes.int64
  let raw = res.app.settings.get("static_fallback_max_bytes", "")
  if raw.len == 0:
    return DefaultStaticFallbackMaxBytes.int64
  try:
    return int64(max(0, parseInt(raw)))
  except ValueError:
    return DefaultStaticFallbackMaxBytes.int64

proc fallbackOversizeStatus(res: Res): int =
  if res == nil or res.app == nil:
    return DefaultStaticFallbackOversizeStatus
  let raw = res.app.settings.get("static_fallback_oversize_status", "")
  if raw.len == 0:
    return DefaultStaticFallbackOversizeStatus
  try:
    let parsed = parseInt(raw)
    if parsed == 503:
      return 503
    return 413
  except ValueError:
    return DefaultStaticFallbackOversizeStatus

proc sendFallbackContentBounded(res: Res, contentPath: string, fileSize: int64): Future[void] {.async.} =
  let capBytes = fallbackMaxBytes(res)
  if capBytes > 0 and fileSize > capBytes:
    res.status(fallbackOversizeStatus(res))
    res.send("static fallback payload too large")
    return
  let maxBytesToSend =
    if capBytes > 0:
      min(capBytes, fileSize)
    else:
      fileSize
  if maxBytesToSend < 0:
    res.status(404).send("Not Found")
    return
  var startedChunked = false
  try:
    startedChunked = res.startChunked(getMimeType(contentPath.extractFilename()))
    if not startedChunked:
      res.status(503).send("static fallback unavailable")
      return
    let file = openAsync(contentPath, fmRead)
    var sentBytes = 0'i64
    var chunk = newString(64 * 1024)
    var flushed = true
    try:
      while sentBytes < maxBytesToSend:
        let remaining = maxBytesToSend - sentBytes
        let want = min(chunk.len, int(remaining))
        if want <= 0:
          break
        let readBytes = await file.readBuffer(addr chunk[0], want)
        if readBytes <= 0:
          break
        if not res.writeChunk(chunk[0..<readBytes]):
          flushed = false
          break
        sentBytes += int64(readBytes)

      # Guard against racy growth beyond the expected stat size/cap.
      if capBytes > 0 and sentBytes >= maxBytesToSend:
        var probe: array[1, char]
        let extra = await file.readBuffer(addr probe[0], 1)
        if extra > 0:
          discard res.endChunked(closeAfterWrite = true)
          return
      discard res.endChunked(closeAfterWrite = not flushed)
    finally:
      file.close()
  except CatchableError:
    if startedChunked:
      discard res.endChunked(closeAfterWrite = true)
    else:
      res.notFound()

proc parseByteRange(rangeHeader: string, fileSize: int64): tuple[ok: bool, start: int64, stop: int64] =
  if rangeHeader.len == 0:
    return (false, 0'i64, 0'i64)
  let lower = rangeHeader.strip()
  if not lower.startsWith("bytes="):
    return (false, 0'i64, 0'i64)
  let spec = lower[6..^1].strip()
  if spec.len == 0 or ',' in spec:
    return (false, 0'i64, 0'i64)
  let dashIdx = spec.find('-')
  if dashIdx < 0:
    return (false, 0'i64, 0'i64)
  let startPart = spec[0..<dashIdx].strip()
  let endPart = spec[(dashIdx + 1)..^1].strip()
  if startPart.len == 0 and endPart.len == 0:
    return (false, 0'i64, 0'i64)
  try:
    if startPart.len == 0:
      let suffixLen = parseInt(endPart).int64
      if suffixLen <= 0:
        return (false, 0'i64, 0'i64)
      let s = max(0'i64, fileSize - suffixLen)
      return (true, s, fileSize - 1)
    let s = parseInt(startPart).int64
    if s < 0 or s >= fileSize:
      return (false, 0'i64, 0'i64)
    if endPart.len == 0:
      return (true, s, fileSize - 1)
    let e = parseInt(endPart).int64
    if e < s or e < 0:
      return (false, 0'i64, 0'i64)
    return (true, s, min(e, fileSize - 1))
  except ValueError:
    return (false, 0'i64, 0'i64)

proc sendPartialContent(res: Res, contentPath: string, rangeStart: int64, rangeEnd: int64, fileSize: int64): Future[void] {.async.} =
  let length = rangeEnd - rangeStart + 1
  if length <= 0:
    res.status(416)
    res.set("Content-Range", "bytes */" & $fileSize)
    res.send("")
    return
  let capBytes = fallbackMaxBytes(res)
  if capBytes > 0 and length > capBytes:
    res.status(fallbackOversizeStatus(res))
    res.send("static fallback payload too large")
    return
  res.status(206)
  res.set("Content-Range", "bytes " & $rangeStart & "-" & $rangeEnd & "/" & $fileSize)
  res.set("Content-Length", $length)
  try:
    let file = openAsync(contentPath, fmRead)
    try:
      file.setFilePos(rangeStart)
      let data = await file.read(int(length))
      res.send(data)
    finally:
      file.close()
  except CatchableError:
    if not res.finished:
      res.status(500).send("Internal Server Error")

## Sends a file with content type, ETag, Last-Modified, range request, and precompressed variant support.
proc sendFile*(res: Res, req: Req, filePath: string, trustedRoot: string = ""): Future[void] {.async.} =
  if not fileExists(filePath):
    res.notFound()
    return
  if not validateStaticContentPath(filePath, trustedRoot):
    res.forbidden()
    return

  let filename = filePath.extractFilename()
  let selected = selectPrecompressedVariant(req, filePath)
  let contentPath = selected.path
  if not validateStaticContentPath(contentPath, trustedRoot):
    res.forbidden()
    return
  var fileInfo: FileInfo
  try:
    fileInfo = getFileInfo(contentPath)
  except CatchableError:
    res.notFound()
    return

  res.set("Content-Type", getMimeType(filename))
  res.set("Content-Length", $fileInfo.size)
  res.set("Accept-Ranges", "bytes")
  if selected.encoding.len > 0:
    res.set("Content-Encoding", selected.encoding)
  # Always set Vary: Accept-Encoding so caches know the response
  # could differ when precompressed variants exist.
  res.append("Vary", "Accept-Encoding")

  let tag = generateFileETag(fileInfo)
  res.set("ETag", tag)
  let lastMod = fileInfo.lastWriteTime.utc.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
  res.set("Last-Modified", lastMod)

  let rangeHeader = req.get("range")
  if rangeHeader.len > 0 and selected.encoding.len == 0:
    let byteRange = parseByteRange(rangeHeader, int64(fileInfo.size))
    if byteRange.ok:
      await sendPartialContent(res, contentPath, byteRange.start, byteRange.stop, int64(fileInfo.size))
      return
    else:
      res.status(416)
      res.set("Content-Range", "bytes */" & $fileInfo.size)
      res.send("")
      return

  if req.fresh(etag = tag, lastModified = lastMod):
    res.status(304)
    res.send("")
  elif req.methodKind == hmHead:
    res.send("")
  elif (when defined(macosx) or defined(linux): true else: false) and res.native.ssl == 0:
    let shouldClose = res.native.connectionCloseEnabled()
    let headerBlock = buildHeaderBlock(res, shouldClose)
    if res.native.sendFilePreparedResponse(headerBlock, contentPath, fileInfo.size, shouldClose):
      res.native.markBodySent()
      res.finished = true
      return
    await sendFallbackContentBounded(res, contentPath, int64(fileInfo.size))
  else:
    await sendFallbackContentBounded(res, contentPath, int64(fileInfo.size))

## Sends a file as an attachment with a sanitized Content-Disposition filename.
proc download*(res: Res, req: Req, filePath: string, filename: string = ""): Future[void] {.async.} =
  let rawName = if filename.len > 0: filename else: filePath.extractFilename()
  var safeName = newStringOfCap(rawName.len)
  for c in rawName:
    if c == '\r' or c == '\n' or c == '\0':
      continue
    if c == '"' or c == '\\':
      safeName.add('_')
    else:
      safeName.add(c)
  if safeName.len == 0:
    safeName = "download"
  res.set("Content-Disposition", "attachment; filename=\"" & safeName & "\"")
  await sendFile(res, req, filePath)
