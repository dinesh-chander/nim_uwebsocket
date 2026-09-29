## Output cache middleware with tag invalidation

import std/[asyncdispatch, tables, sets, strutils, times]
import common

type
  ## Resolves the invalidation tags for a cached response. Expected
  ## cardinality is small (<= 16 tags per response); larger results are
  ## truncated.
  CacheTagResolver* = proc(req: Req): seq[string] {.closure.}

  OutputCachePolicy* = object
    ttlSeconds*: int
    varyByHeaders*: seq[string]
    varyByQuery*: bool
    bypassAuthSensitive*: bool
    cacheableStatuses*: seq[int]
    maxBodyBytes*: int
    maxEntries*: int
    maxTotalBytes*: int
    tagResolver*: CacheTagResolver

  OutputCacheEntry* = object
    statusCode*: int
    header*: string
    body*: string
    tags*: seq[string]
    expiresAtMs*: int64
    storedBytes*: int

  ## .. NOTE:: NOT thread-safe. Create one store per worker/thread/process
  ##    (e.g. inside each ``runCluster``/``runThreaded`` child); do not share a
  ##    single store across threads.
  OutputCacheStore* = ref object
    entries*: Table[string, OutputCacheEntry]
    order*: seq[string]
    totalBytes*: int
    lastPurgeMs*: int64

## Policy with production-safe defaults for the output cache middleware.
proc initOutputCachePolicy*(
  ttlSeconds: int = 30,
  varyByHeaders: seq[string] = @["accept-encoding"],
  varyByQuery: bool = true,
  bypassAuthSensitive: bool = true,
  cacheableStatuses: seq[int] = @[200],
  maxBodyBytes: int = 1024 * 1024,
  maxEntries: int = 2048,
  tagResolver: CacheTagResolver = nil,
  maxTotalBytes: int = 64 * 1024 * 1024
): OutputCachePolicy {.inline.} =
  result.ttlSeconds = max(1, ttlSeconds)
  result.varyByHeaders = @[]
  for token in varyByHeaders:
    let normalized = token.strip().toLowerAscii()
    if normalized.len > 0 and normalized notin result.varyByHeaders:
      result.varyByHeaders.add(normalized)
  if not bypassAuthSensitive:
    # Authenticated responses are cached, so the key must vary by credential
    # headers; otherwise one user's response could be served to another user.
    for authHeader in @["authorization", "cookie"]:
      if authHeader notin result.varyByHeaders:
        result.varyByHeaders.add(authHeader)
  result.varyByQuery = varyByQuery
  result.bypassAuthSensitive = bypassAuthSensitive
  result.cacheableStatuses = if cacheableStatuses.len > 0: cacheableStatuses else: @[200]
  result.maxBodyBytes = max(1, maxBodyBytes)
  result.maxEntries = max(1, maxEntries)
  result.maxTotalBytes = max(1, maxTotalBytes)
  result.tagResolver = tagResolver

## Create an empty output cache store.
proc newOutputCacheStore*(): OutputCacheStore =
  new(result)
  result.entries = initTable[string, OutputCacheEntry]()
  result.order = @[]
  result.totalBytes = 0
  result.lastPurgeMs = 0

## Number of entries currently held in the store.
proc outputCacheEntryCount*(store: OutputCacheStore): int {.inline.} =
  if store == nil:
    return 0
  store.entries.len

proc removeFromOrder(store: OutputCacheStore, key: string) {.inline.} =
  if store == nil or store.order.len == 0:
    return
  for i in 0 ..< store.order.len:
    if store.order[i] == key:
      if i < store.order.len - 1:
        for j in i ..< store.order.len - 1:
          store.order[j] = store.order[j + 1]
      store.order.setLen(store.order.len - 1)
      return

proc touchOrder(store: OutputCacheStore, key: string) {.inline.} =
  if store == nil or not store.order.contains(key):
    return
  store.removeFromOrder(key)
  store.order.add(key)

proc removeCacheKey(store: OutputCacheStore, key: string): bool {.inline.} =
  if store == nil or key.len == 0 or not store.entries.hasKey(key):
    return false
  let entry = store.entries[key]
  store.totalBytes = max(0, store.totalBytes - entry.storedBytes)
  store.entries.del(key)
  store.removeFromOrder(key)
  true

proc purgeExpiredEntries(store: OutputCacheStore, nowMs: int64) =
  if store == nil or store.order.len == 0:
    return
  var expiredKeys: seq[string] = @[]
  for key in store.order:
    if not store.entries.hasKey(key):
      continue
    let entry = store.entries[key]
    if entry.expiresAtMs <= nowMs:
      expiredKeys.add(key)
  for key in expiredKeys:
    discard store.removeCacheKey(key)

proc storeCacheEntry(
  store: OutputCacheStore,
  key: string,
  entry: OutputCacheEntry,
  maxEntries: int,
  maxTotalBytes: int
) =
  if store == nil or key.len == 0:
    return
  if store.entries.hasKey(key):
    discard store.removeCacheKey(key)
  store.entries[key] = entry
  store.totalBytes += entry.storedBytes
  store.order.add(key)
  while store.order.len > maxEntries or store.totalBytes > maxTotalBytes:
    if store.order.len == 0:
      break
    let evictKey = store.order[0]
    discard store.removeCacheKey(evictKey)

proc normalizeTag(tag: string): string {.inline.} =
  tag.strip().toLowerAscii()

const maxTagsPerEntry = 16

proc resolveCacheTags(req: Req, policy: OutputCachePolicy): seq[string] =
  if policy.tagResolver != nil:
    for token in policy.tagResolver(req):
      if result.len >= maxTagsPerEntry:
        break
      let normalized = normalizeTag(token)
      if normalized.len > 0:
        result.add(normalized)
  if result.len == 0 and req != nil:
    result.add("path:" & req.path.toLowerAscii())

## Invalidate all cached entries with the given tag; returns the count removed.
proc invalidateOutputCacheTag*(store: OutputCacheStore, tag: string): int {.discardable.} =
  if store == nil:
    return 0
  let normalizedTag = normalizeTag(tag)
  if normalizedTag.len == 0:
    return 0
  var keysToDelete: seq[string] = @[]
  for key in store.order:
    if not store.entries.hasKey(key):
      continue
    let entry = store.entries[key]
    for entryTag in entry.tags:
      if entryTag == normalizedTag:
        keysToDelete.add(key)
        break
  for key in keysToDelete:
    if store.removeCacheKey(key):
      inc result

## Invalidate cached entries matching any of the given tags; returns the count removed.
proc invalidateOutputCacheTags*(store: OutputCacheStore, tags: openArray[string]): int {.discardable.} =
  if store == nil or tags.len == 0:
    return 0
  var keysToDelete = initHashSet[string]()
  for tag in tags:
    let normalizedTag = normalizeTag(tag)
    if normalizedTag.len == 0:
      continue
    for key in store.order:
      if not store.entries.hasKey(key):
        continue
      let entry = store.entries[key]
      for entryTag in entry.tags:
        if entryTag == normalizedTag:
          keysToDelete.incl(key)
          break
  # Iterate the collected set (not store.order) because removeCacheKey
  # mutates store.order while iterating.
  for key in keysToDelete:
    if store.removeCacheKey(key):
      inc result

## Remove all entries from the store.
proc clearOutputCache*(store: OutputCacheStore) =
  if store == nil:
    return
  store.entries.clear()
  store.order.setLen(0)
  store.totalBytes = 0

proc parseStatusCodeFromCapturedHeader(header: string, fallback: int): int {.inline.} =
  let lineEnd = header.find("\r\n")
  if lineEnd <= 0:
    return fallback
  let firstLine = header[0 ..< lineEnd]
  let tokens = firstLine.splitWhitespace()
  if tokens.len < 2:
    return fallback
  try:
    parseInt(tokens[1])
  except ValueError:
    fallback

proc parseCapturedHeaders(header: string): Table[string, string] =
  result = initTable[string, string]()
  if header.len == 0:
    return
  let lines = header.split("\r\n")
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.len == 0:
      continue
    let sep = line.find(':')
    if sep <= 0:
      continue
    let key = line[0 ..< sep].strip().toLowerAscii()
    if key.len == 0:
      continue
    let value = line[sep + 1 .. ^1].strip()
    if result.hasKey(key):
      result[key] = result[key] & ", " & value
    else:
      result[key] = value

proc headerContainsToken(value: string, token: string): bool {.inline.} =
  if value.len == 0 or token.len == 0:
    return false
  let target = token.toLowerAscii()
  for part in value.split(','):
    if part.strip().toLowerAscii() == target:
      return true
  false

proc responseVaryCovered(responseHeaders: Table[string, string], policy: OutputCachePolicy): bool {.inline.} =
  let vary = responseHeaders.getOrDefault("vary", "")
  if vary.len == 0:
    return true
  for part in vary.split(','):
    let token = part.strip().toLowerAscii()
    if token.len == 0:
      continue
    if token == "*":
      return false
    if token notin policy.varyByHeaders:
      return false
  true

proc responseEligibleForCache(
  req: Req,
  statusCode: int,
  responseBodyLen: int,
  responseHeaders: Table[string, string],
  policy: OutputCachePolicy
): bool =
  var statusAllowed = false
  for code in policy.cacheableStatuses:
    if statusCode == code:
      statusAllowed = true
      break
  if not statusAllowed:
    return false
  if responseBodyLen > policy.maxBodyBytes:
    return false
  if not responseVaryCovered(responseHeaders, policy):
    return false
  if headerContainsToken(responseHeaders.getOrDefault("transfer-encoding", "").toLowerAscii(), "chunked"):
    return false
  if responseHeaders.getOrDefault("content-type", "").toLowerAscii().contains("text/event-stream"):
    return false
  let cacheControl = responseHeaders.getOrDefault("cache-control", "").toLowerAscii()
  if headerContainsToken(cacheControl, "no-store") or
     headerContainsToken(cacheControl, "no-cache") or
     headerContainsToken(cacheControl, "private"):
    return false
  if responseHeaders.hasKey("set-cookie"):
    return false
  if policy.bypassAuthSensitive:
    if req != nil and (
      req.get("authorization").len > 0 or req.get("cookie").len > 0
    ):
      return false
  true

proc requestBypassesCache(req: Req, policy: OutputCachePolicy): bool {.inline.} =
  if req == nil:
    return true
  if req.methodKind notin {hmGet, hmHead}:
    return true
  if headerContainsToken(req.get("cache-control").toLowerAscii(), "no-cache"):
    return true
  if req.get("accept").toLowerAscii().contains("text/event-stream"):
    return true
  if policy.bypassAuthSensitive and (
    req.get("authorization").len > 0 or req.get("cookie").len > 0
  ):
    return true
  false

proc buildOutputCacheKey(req: Req, policy: OutputCachePolicy): string {.inline.} =
  if req == nil:
    return ""
  result = $req.methodKind & "|" & req.path
  if policy.varyByQuery and req.native != nil and req.native.queryStringRaw.len > 0:
    result.add("?")
    result.add(req.native.queryStringRaw)
  if policy.varyByHeaders.len > 0:
    for headerName in policy.varyByHeaders:
      result.add("|h:")
      result.add(headerName)
      result.add("=")
      result.add(req.get(headerName))

## ``store`` is shared by reference across every middleware instance created
## from it; create one store per application.
proc outputCache*(store: OutputCacheStore, policy: OutputCachePolicy = initOutputCachePolicy()): AsyncMiddleware =
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if store == nil or requestBypassesCache(req, policy):
      await next()
      return

    let key = buildOutputCacheKey(req, policy)
    if key.len == 0:
      await next()
      return

    let nowMs = int64(epochTime() * 1000.0)
    # Amortized expiry sweep: at most one full scan per second; per-entry
    # expiry is still enforced on the hit path below.
    if nowMs - store.lastPurgeMs >= 1000'i64:
      store.lastPurgeMs = nowMs
      purgeExpiredEntries(store, nowMs)

    let liveNative = res.native
    if store.entries.hasKey(key):
      let entry = store.entries[key]
      if entry.expiresAtMs > nowMs:
        touchOrder(store, key)
        if liveNative != nil:
          liveNative.sendPreparedResponse(entry.header, entry.body)
        res.statusCode = entry.statusCode
        res.finished = true
        return
      discard removeCacheKey(store, key)

    var captureNative: HttpResponse
    new(captureNative)
    captureNative.requestMethod = req.methodKind
    captureNative.requestIsHttp11 = true
    captureNative.captureForward = liveNative
    res.native = captureNative
    res.finished = false

    var handlerError: ref Exception = nil
    try:
      await next()
    except CatchableError as e:
      handlerError = e
    finally:
      # Always restore the live native to prevent pointer leak.
      res.native = liveNative

    if handlerError != nil:
      # Handler failed; re-raise without caching.
      raise handlerError

    let capturedHeader = captureNative.capturedHeader
    let capturedBody = captureNative.capturedBody
    let capturedRaw = captureNative.capturedRaw
    let statusCode = parseStatusCodeFromCapturedHeader(capturedHeader, res.statusCode)
    let responseHeaders = parseCapturedHeaders(capturedHeader)

    if captureNative.captureBypassCache:
      return

    if capturedHeader.len > 0:
      if liveNative != nil:
        liveNative.sendPreparedResponse(capturedHeader, capturedBody)
      res.statusCode = statusCode
      res.finished = true
      let responseTags = resolveCacheTags(req, policy)
      var storedBytes = capturedHeader.len + capturedBody.len
      for tag in responseTags:
        storedBytes += tag.len
      if storedBytes <= policy.maxTotalBytes and
         responseEligibleForCache(req, statusCode, capturedBody.len, responseHeaders, policy):
        let responseGeneratedMs = int64(epochTime() * 1000.0)
        storeCacheEntry(
          store,
          key,
          OutputCacheEntry(
            statusCode: statusCode,
            header: capturedHeader,
            body: capturedBody,
            tags: responseTags,
            expiresAtMs: responseGeneratedMs + int64(policy.ttlSeconds) * 1000'i64,
            storedBytes: storedBytes
          ),
          policy.maxEntries,
          policy.maxTotalBytes
        )
      return

    if capturedRaw.len > 0 and liveNative != nil:
      liveNative.send(capturedRaw)
      res.finished = true
