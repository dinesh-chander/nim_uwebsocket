## File serving helper procs

import std/[asyncdispatch, asyncfile, strutils, os, times]
import common
import ../compression_codec
import nim_utils/helpers/fast_map

const
  DefaultStaticFallbackMaxBytes* = 8 * 1024 * 1024
  DefaultStaticFallbackOversizeStatus* = 413

## Static file metadata cache.
##
## A request that serves a static file normally pays 8-10 stat syscalls
## (existence check, file info, precompressed variant probes, and one
## symlink probe per path component). For an unchanged file those results
## are identical, so we cache them per absolute content path for a short
## TTL. Serving a hot file then costs at most one full metadata pass per
## TTL window instead of per request.
##
## Security tradeoff (documented, TTL-bounded): a symlink planted inside
## the trusted root after a cache entry was populated is not detected for
## up to the TTL (2 s). Path traversal, root escape, and '..' components
## are still rejected on every request because validation happens before
## the cache lookup.
const
  StaticMetaCacheTtlSeconds* = 2
  StaticMetaCacheMaxEntries* = 4096

type StaticMeta* = object
  path*: string
  fileInfo*: FileInfo
  etag*: string
  lastModified*: string
  headerBlock*: string
  mtimeEpoch*: float64
  insertedAt*: float64

when defined(singleThread):
  var staticMetaCache: FastMap[StaticMeta]
else:
  var staticMetaCache {.threadvar.}: FastMap[StaticMeta]

proc initStaticMetaCache() {.inline.} =
  if staticMetaCache == nil:
    staticMetaCache = newFastMap[StaticMeta]()

## Cheap cache for expandFilename: std/os normalizes paths with heavy
## allocations (pathnorm), which dominated the static hot path (9.9M calls
## for ~10 paths). Keyed by input spelling; bounded; process-wide.
when defined(singleThread):
  var pathExpandCache: FastMap[string]
else:
  var pathExpandCache {.threadvar.}: FastMap[string]

const StaticPathExpandCacheMax* = 1024

## stat without std/os path normalization (fileExists/getFileInfo each pay
## a full normalizePath, ~1.2 us, per call). Raw syscall; no string work.
type RawFileStatus* = object
  ok*: bool
  isDir*: bool
  size*: BiggestInt
  mtimeEpoch*: float64

when defined(posix):
  # C shim (cshim/file_status.c): stat(2) with a scalar-only out struct.
  # Keeps the FFI boundary ABI-stable (no glibc struct stat layout coupling).
  type NimFsStatusOut = object
    mode*: uint32
    size*: int64
    mtimeSec*: int64
    mtimeNsec*: int64

  proc nimFsStat(path: cstring, buf: ptr NimFsStatusOut): cint {.
    importc: "nim_fs_stat".}
  # Compiled by nimble and by direct `nim c` builds alike.
  {.compile: "../cshim/file_status.c".}


proc fileStatusOrNone*(path: string): RawFileStatus =
  ## One stat(2) syscall; no path normalization, no allocations.
  when defined(posix):
    var st: NimFsStatusOut
    if nimFsStat(path.cstring, addr st) != 0:
      return RawFileStatus()
    let modeKind = st.mode and 0o170000.uint32
    result = RawFileStatus(
      ok: true,
      isDir: modeKind == 0o040000.uint32,
      size: st.size,
      mtimeEpoch: float64(st.mtimeSec) + float64(st.mtimeNsec) / 1.0e9)
  else:
    try:
      let fi = getFileInfo(path)
      result = RawFileStatus(
        ok: true, isDir: fi.kind == pcDir, size: fi.size,
        mtimeEpoch: float64(fi.lastWriteTime.toUnix))
    except CatchableError:
      result = RawFileStatus()

proc cachedExpandFilename(path: string): string {.inline.} =
  if pathExpandCache == nil:
    result = path.expandFilename()
    return
  if pathExpandCache.len > 0 and pathExpandCache.tryGet(path, result):
    return
  result = path.expandFilename()
  if pathExpandCache.len >= StaticPathExpandCacheMax:
    pathExpandCache.clear()
  discard pathExpandCache.put(path, result)

proc staticMetaLookup(path: string): bool {.inline.} =
  ## Return true with a fresh cached entry available via staticMetaTryGet.
  if staticMetaCache == nil or staticMetaCache.len == 0:
    return false
  var entry: StaticMeta
  if not staticMetaCache.tryGet(path, entry):
    return false
  if epochTime() - entry.insertedAt < float64(StaticMetaCacheTtlSeconds):
    return true
  discard staticMetaCache.del(path)
  false

proc staticMetaTryGet(path: string, entry: var StaticMeta): bool {.inline.} =
  staticMetaCache.tryGet(path, entry)

proc staticMetaInsert(path: string, meta: StaticMeta) {.inline.} =
  initStaticMetaCache()
  if staticMetaCache.len >= StaticMetaCacheMaxEntries:
    staticMetaCache.clear()
  var entry = meta
  entry.insertedAt = epochTime()
  discard staticMetaCache.put(path, entry)

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
      if fileStatusOrNone(zstPath).ok:
        return (zstPath, "zstd")
    of ceBrotli:
      let brPath = filePath & ".br"
      if fileStatusOrNone(brPath).ok:
        return (brPath, "br")
    of ceGzip:
      let gzPath = filePath & ".gz"
      if fileStatusOrNone(gzPath).ok:
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
## Slow tail of `sendFile`: per-request header building and the rare
## branches (range requests, 304/HEAD, non-sendfile fallbacks). Kept async
## so the steady-state path stays a plain synchronous proc (no future
## allocation, no async dispatch) in the hot loop.
proc sendFileSlow(res: Res, req: Req, filename: string, contentPath: string,
    selectedEncoding: string, fileInfo: FileInfo, tag: string,
    lastMod: string): Future[void] {.async.} =
  let rangeHeader = req.get("range")
  let isFresh = req.fresh(etag = tag, lastModified = lastMod)
  let isHead = req.methodKind == hmHead
  res.set("Content-Type", getMimeType(filename))
  res.set("Content-Length", $fileInfo.size)
  res.set("Accept-Ranges", "bytes")
  if selectedEncoding.len > 0:
    res.set("Content-Encoding", selectedEncoding)
  # Always set Vary: Accept-Encoding so caches know the response
  # could differ when precompressed variants exist.
  res.append("Vary", "Accept-Encoding")
  res.set("ETag", tag)
  res.set("Last-Modified", lastMod)

  if rangeHeader.len > 0 and selectedEncoding.len == 0:
    let byteRange = parseByteRange(rangeHeader, int64(fileInfo.size))
    if byteRange.ok:
      await sendPartialContent(res, contentPath, byteRange.start, byteRange.stop, int64(fileInfo.size))
      return
    else:
      res.status(416)
      res.set("Content-Range", "bytes */" & $fileInfo.size)
      res.send("")
      return

  if isFresh:
    res.status(304)
    res.send("")
  elif isHead:
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


type SendFileOutcome* = object
  done*: bool
  contentPath*: string
  encoding*: string
  fileInfo*: FileInfo
  etag*: string
  lastModified*: string

proc sendFileCore(res: Res, req: Req, filePath: string, trustedRoot: string): SendFileOutcome =
  ## Synchronous core of `sendFile`/`sendFileDirect`. done=true means the
  ## response is fully sent (steady-state fast path: cache hit, plain GET,
  ## sendfile) or a terminal error was sent; done=false means the async slow
  ## tail (`sendFileSlow`) must run with the returned metadata.
  # Canonical absolute path is cache key: callers may pass the same file
  # with different relative spellings, and validation canonicalizes too.
  let cacheKey = cachedExpandFilename(filePath)
  let filename = filePath.extractFilename()
  var contentPath = filePath
  var selectedEncoding = ""
  var fileInfo: FileInfo
  var tag = ""
  var lastMod = ""
  var cachedMeta: StaticMeta
  var cachedMetaUsed = false
  if staticMetaLookup(cacheKey) and staticMetaTryGet(cacheKey, cachedMeta):
    # Steady-state fast path: one raw stat confirms file + mtime unchanged.
    # The entry was path-validated when inserted and stays trusted for its
    # TTL window (<= StaticMetaCacheTtlSeconds), bounding symlink/traversal
    # staleness to the same window the metadata itself trusts.
    let nowStatus = fileStatusOrNone(cachedMeta.path)
    if nowStatus.ok and not nowStatus.isDir and
        nowStatus.mtimeEpoch == cachedMeta.mtimeEpoch:
      let meta = cachedMeta
      contentPath = meta.path
      selectedEncoding = ""
      fileInfo = meta.fileInfo
      tag = meta.etag
      lastMod = meta.lastModified
      cachedMetaUsed = true
  if not cachedMetaUsed:
    # stat without path normalization; std fileExists normalizes (~1.2 us).
    if not fileStatusOrNone(filePath).ok:
      res.notFound()
      return SendFileOutcome(done: true)
    if not validateStaticContentPath(filePath, trustedRoot):
      res.forbidden()
      return SendFileOutcome(done: true)
    let selected = selectPrecompressedVariant(req, filePath)
    contentPath = selected.path
    selectedEncoding = selected.encoding
    if trustedRoot.len > 0 and not validateStaticContentPath(contentPath, trustedRoot):
      res.forbidden()
      return SendFileOutcome(done: true)
    try:
      fileInfo = getFileInfo(contentPath)
    except CatchableError:
      res.notFound()
      return SendFileOutcome(done: true)
    tag = generateFileETag(fileInfo)
    lastMod = fileInfo.lastWriteTime.utc.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
    # Only the plain variant is cached: a precompressed hit depends on the
    # client's Accept-Encoding, so it may not be served to every request.
    if selectedEncoding.len == 0:
      # Prebuild the 200 header block once per file (keep-alive form); the
      # steady-state fast path sends it as a constant instead of rebuilding
      # headers per request.
      var hb = newStringOfCap(256)
      hb.add(getStatusLine(200))
      hb.add("content-type: ")
      hb.add(getMimeType(filename))
      hb.add("\r\ncontent-length: ")
      hb.add($fileInfo.size)
      hb.add("\r\naccept-ranges: bytes\r\n")
      hb.add("vary: Accept-Encoding\r\netag: ")
      hb.add(tag)
      hb.add("\r\nlast-modified: ")
      hb.add(lastMod)
      hb.add("\r\nconnection: keep-alive\r\n\r\n")
      staticMetaInsert(cacheKey, StaticMeta(
        path: contentPath, fileInfo: fileInfo,
        etag: tag, lastModified: lastMod, headerBlock: hb,
        mtimeEpoch: fileStatusOrNone(contentPath).mtimeEpoch))

  let rangeHeader = req.get("range")
  let isFresh = req.fresh(etag = tag, lastModified = lastMod)
  let isHead = req.methodKind == hmHead

  # Steady-state fast path: a cache entry means we prebuilt the full 200
  # header block once, so a plain GET with no Range/freshness negotiation
  # skips all per-request header work and goes straight to sendfile.
  if cachedMetaUsed and not isHead and rangeHeader.len == 0 and not isFresh:
    if (when defined(macosx) or defined(linux): true else: false) and
        res.native.ssl == 0:
      let shouldClose = res.native.connectionCloseEnabled()
      if not shouldClose:
        if res.native.sendFilePreparedResponse(cachedMeta.headerBlock, contentPath,
            int64(fileInfo.size), false):
          res.native.markBodySent()
          res.finished = true
          return SendFileOutcome(done: true)

  result.contentPath = contentPath
  result.encoding = selectedEncoding
  result.fileInfo = fileInfo
  result.etag = tag
  result.lastModified = lastMod


## Async public API: runs the synchronous core and, only when the fast path
## did not finish the response, the async slow tail (range/304/HEAD/fallback).
proc sendFile*(res: Res, req: Req, filePath: string, trustedRoot: string = ""): Future[void] {.async.} =
  let outc = sendFileCore(res, req, filePath, trustedRoot)
  if not outc.done:
    await sendFileSlow(res, req, filePath.extractFilename(), outc.contentPath,
        outc.encoding, outc.fileInfo, outc.etag, outc.lastModified)

## Synchronous route handler: zero async machinery on the steady-state path.
## Plain GET on a cached file is answered entirely synchronously via the
## sendfile fast path; everything else is delegated to the async slow tail.
proc sendFileDirect*(res: Res, req: Req, filePath: string, trustedRoot: string = "") =
  let outc = sendFileCore(res, req, filePath, trustedRoot)
  if not outc.done:
    discard sendFileSlow(res, req, filePath.extractFilename(), outc.contentPath,
        outc.encoding, outc.fileInfo, outc.etag, outc.lastModified)


