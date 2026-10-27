## Static file middleware

import std/[asyncdispatch, strutils, os, uri]
import common
import file_helpers
import nim_utils/helpers/simd_str

type
  StaticCacheOptions* = object
    defaultMaxAgeSeconds*: int
    immutableMaxAgeSeconds*: int
    noCacheExtensions*: seq[string]
    immutableExtensions*: seq[string]

## Return the default `StaticCacheOptions` used when no cache options are passed to serveStatic.
proc defaultStaticCacheOptions*(): StaticCacheOptions {.inline.} =
  StaticCacheOptions(
    defaultMaxAgeSeconds: 300,
    immutableMaxAgeSeconds: 31536000,
    noCacheExtensions: @[".html", ".htm"],
    immutableExtensions: @[
      ".css", ".js", ".mjs", ".map",
      ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".ico",
      ".woff", ".woff2", ".ttf"
    ]
  )

proc extensionIn(ext: string, items: seq[string]): bool {.inline.} =
  for item in items:
    if ext == item:
      return true
  false

proc cacheControlForPath(filePath: string, cache: StaticCacheOptions): string =
  let ext = filePath.splitFile().ext.toLowerAscii()
  if extensionIn(ext, cache.noCacheExtensions):
    return "no-cache"
  if extensionIn(ext, cache.immutableExtensions):
    return "public, max-age=" & $max(0, cache.immutableMaxAgeSeconds) & ", immutable"
  "public, max-age=" & $max(0, cache.defaultMaxAgeSeconds)

## Create an async middleware that serves files under `root`, optionally mounted at `prefix`, setting Cache-Control from `cache`.
proc serveStatic*(
  root: string,
  prefix: string = "",
  cache: StaticCacheOptions = defaultStaticCacheOptions()
): AsyncMiddleware =
  var resolvedRoot = ""
  var rootAvailable = false
  try:
    resolvedRoot = root.expandFilename()
    rootAvailable = dirExists(resolvedRoot)
  except OSError:
    rootAvailable = false

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if not rootAvailable:
      await next()
      return

    if req.methodKind != hmGet and req.methodKind != hmHead:
      await next()
      return

    var path = req.path
    if prefix.len > 0:
      if path == prefix:
        path = "/"
      elif path.len > prefix.len and
           simdStrEquals(unsafeAddr path[0], unsafeAddr prefix[0], prefix.len) and
           path[prefix.len] == '/':
        path = path[prefix.len..^1]
      else:
        await next()
        return

    if '\0' in path:
      res.forbidden()
      return
    var decoded: string
    try:
      decoded = decodeUrl(path, decodePlus = false)
    except CatchableError:
      res.forbidden()
      return
    if '\0' in decoded or '\\' in decoded:
      res.forbidden()
      return
    for segment in decoded.split('/'):
      if segment == "..":
        res.forbidden()
        return

    let relPath = decoded.strip(chars = {'/'})
    if relPath.len == 0:
      await next()
      return
    let filePath = resolvedRoot / relPath

    if fileExists(filePath):
      var resolvedFile = ""
      try:
        resolvedFile = filePath.expandFilename()
      except OSError:
        res.forbidden()
        return

      if resolvedFile != resolvedRoot and not resolvedFile.isRelativeTo(resolvedRoot):
        res.forbidden()
        return

      if res.get("cache-control").len == 0:
        res.set("Cache-Control", cacheControlForPath(resolvedFile, cache))
      await sendFile(res, req, resolvedFile, resolvedRoot)
    else:
      await next()
