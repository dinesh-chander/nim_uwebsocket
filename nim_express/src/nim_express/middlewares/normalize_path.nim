## Path normalization middleware.
## Trims or appends trailing slashes and merges duplicate slashes.

import std/[asyncdispatch, strutils]
import common

type
  TrailingSlashMode* = enum
    tsmTrim
    tsmAppend

  NormalizePathOptions* = object
    trailingSlash*: TrailingSlashMode
    mergeDuplicateSlashes*: bool
    redirectCode*: int

## Returns defaults: trim trailing slash, merge duplicate slashes, 301 redirect.
proc defaultNormalizePathOptions*(): NormalizePathOptions {.inline.} =
  NormalizePathOptions(
    trailingSlash: tsmTrim,
    mergeDuplicateSlashes: true,
    redirectCode: 301
  )

## Resolves dot segments "." and ".." in `path` per RFC 3986, returning an absolute path.
proc resolveDotSegments*(path: string): string {.inline, noSideEffect.} =
  ## Resolves RFC 3986 dot segments ("." and "..").
  ## Segments are kept as (start, len) slices into `path` and the result
  ## is built in a single preallocated buffer, avoiding per-segment string
  ## copies and the intermediate join string.
  if path.len == 0:
    return "/"
  var segments: seq[tuple[start, len: int]] = @[]
  var i = 0
  let hasLeadingSlash = path[0] == '/'
  if hasLeadingSlash:
    i = 1
  while i <= path.len:
    var j = i
    while j < path.len and path[j] != '/':
      inc j
    let segLen = j - i
    if segLen > 0:
      if segLen == 2 and path[i] == '.' and path[i + 1] == '.':
        if segments.len > 0:
          segments.setLen(segments.len - 1)
      elif not (segLen == 1 and path[i] == '.'):
        segments.add((i, segLen))
    i = j + 1
  var totalLen = 1
  if segments.len > 0:
    totalLen += segments[0].len
    for k in 1 ..< segments.len:
      inc totalLen, 1 + segments[k].len
  result = newStringOfCap(totalLen)
  result.setLen(totalLen)
  result[0] = '/'
  var pos = 1
  for k in 0 ..< segments.len:
    if k > 0:
      result[pos] = '/'
      inc pos
    copyMem(addr result[pos], addr path[segments[k].start], segments[k].len)
    inc pos, segments[k].len

## Collapses runs of consecutive slashes into a single slash.
proc mergeSlashes*(path: string): string {.inline, noSideEffect.} =
  result = newStringOfCap(path.len)
  var prevSlash = false
  for c in path:
    if c == '/':
      if not prevSlash:
        result.add(c)
      prevSlash = true
    else:
      result.add(c)
      prevSlash = false

## Async middleware that rewrites the request path per `options` and redirects when it changes.
proc normalizePath*(
  options: NormalizePathOptions = defaultNormalizePathOptions()
): AsyncMiddleware =
  let opts = options
  let validCode = opts.redirectCode == 301 or opts.redirectCode == 302 or
    opts.redirectCode == 307 or opts.redirectCode == 308
  doAssert(validCode,
    "normalizePath: redirectCode must be 301, 302, 307, or 308, got " &
    $opts.redirectCode)
  let code = if validCode: opts.redirectCode else: 301

  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    # Borrow the request path read-only; the owned copy below is only
    # materialized when a rewrite is actually needed.
    let path = req.path
    var changed = false
    var p: string

    # req.path is expected to start with "/" per HTTP/1.1; the relative
    # dot forms (./foo, ../bar) are also detected as defense in depth.
    if path.len > 1 and (
      path.startsWith("./") or path.startsWith("../") or
      "/./" in path or "/../" in path or
      path.endsWith("/..") or path.endsWith("/.") or
      path == ".." or path == "."
    ):
      let resolved = resolveDotSegments(path)
      if resolved != path:
        p = resolved
        changed = true

    # resolveDotSegments skips empty segments, so its output never
    # contains "//"; merging is only needed when no rewrite happened.
    if opts.mergeDuplicateSlashes and not changed and path.len > 1 and
        "//" in path:
      p = mergeSlashes(path)
      changed = true

    if changed:
      if p.len > 1:
        case opts.trailingSlash
        of tsmTrim:
          if p[^1] == '/':
            p = p[0..^2]
        of tsmAppend:
          let lastSlash = p.rfind('/')
          let lastSegment = if lastSlash >= 0: p[lastSlash + 1..^1] else: p
          if p[^1] != '/' and '.' notin lastSegment:
            p.add('/')
    elif path.len > 1:
      case opts.trailingSlash
      of tsmTrim:
        if path[^1] == '/':
          p = path[0..^2]
          changed = true
      of tsmAppend:
        let lastSlash = path.rfind('/')
        let lastSegment = if lastSlash >= 0: path[lastSlash + 1..^1] else: path
        if path[^1] != '/' and '.' notin lastSegment:
          p = path & "/"
          changed = true

    if changed:
      # Safety net: with mergeDuplicateSlashes disabled, "//" is never
      # collapsed, so a rewrite (e.g. trailing slash append) can still
      # leave a leading "//" here.
      if p.len >= 2 and p[0] == '/' and p[1] == '/':
        p = "/" & p.strip(chars = {'/'}, trailing = false)
      let rawQuery = req.rawQuery()
      let location =
        if rawQuery.len > 0: p & "?" & rawQuery
        else: p
      res.status(code)
      res.set("Location", location)
      res.send("")
      return

    await next()

## Shorthand for `normalizePath` with a specific `trailingSlash` mode, merging slashes and redirecting with 301.
proc normalizePath*(trailingSlash: TrailingSlashMode): AsyncMiddleware =
  normalizePath(NormalizePathOptions(
    trailingSlash: trailingSlash,
    mergeDuplicateSlashes: true,
    redirectCode: 301
  ))
