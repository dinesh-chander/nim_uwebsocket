## Session middleware with pluggable store callbacks.

import std/[asyncdispatch, strutils, sysrand, times, tables]
import common

type
  SessionData* = FastMap[string]

  SessionStoreLoadProc* = proc(sessionId: string): tuple[found: bool, data: SessionData]
  SessionStoreSaveProc* = proc(sessionId: string, data: SessionData, ttlSeconds: int)
  SessionStoreDeleteProc* = proc(sessionId: string)

  SessionStore* = object
    load*: SessionStoreLoadProc
    save*: SessionStoreSaveProc
    delete*: SessionStoreDeleteProc

  SessionOptions* = object
    cookieName*: string
    ttlSeconds*: int
    secureCookie*: bool
    httpOnlyCookie*: bool
    sameSite*: string
    path*: string
    domain*: string
    rolling*: bool
    saveUninitialized*: bool
    store*: SessionStore
    allowInsecureCookie*: bool
    allowClientReadableCookie*: bool
    maxValueLen*: int
    maxSessionSize*: int

const
  SessionPrefix = "session_"
  SessionIdLocal* = "_session_id"
  SessionDestroyLocal* = "_session_destroy"
  SessionMaxValueLenLocal = "_session_max_value_len"
  SessionMaxSizeLocal = "_session_max_session_size"
  MaxInMemorySessions* = 100_000
  SessionCreationRateLimit* = 10
  SessionCreationRateWindowSeconds* = 60
  DefaultMaxSessionValueLen* = 4096
  DefaultMaxSessionSize* = 65_536

type
  IpSessionRateEntry = object
    count: int
    windowStart: int64

when defined(singleThread):
  var
    memSessions: Table[string, SessionData]
    memSessionExpiry: Table[string, int64]
    memSessionTick: int
    memStoreInitialized: bool
    sessionCreationRates: Table[string, IpSessionRateEntry]
    defaultMemStore: SessionStore
else:
  var
    memSessions {.threadvar.}: Table[string, SessionData]
    memSessionExpiry {.threadvar.}: Table[string, int64]
    memSessionTick {.threadvar.}: int
    memStoreInitialized {.threadvar.}: bool
    sessionCreationRates {.threadvar.}: Table[string, IpSessionRateEntry]
    defaultMemStore {.threadvar.}: SessionStore

proc pruneStaleRateEntries(now: int64, windowSeconds: int): int =
  var stale: seq[string] = @[]
  for ip, entry in sessionCreationRates:
    if now - entry.windowStart >= int64(windowSeconds):
      stale.add(ip)
  for ip in stale:
    sessionCreationRates.del(ip)
  stale.len

proc checkSessionCreationRate(ip: string, maxRate: int = SessionCreationRateLimit, windowSeconds: int = SessionCreationRateWindowSeconds): bool =
  if ip.len == 0:
    return true
  let now = getTime().toUnix()
  if sessionCreationRates.hasKey(ip):
    var entry = sessionCreationRates[ip]
    if now - entry.windowStart >= int64(windowSeconds):
      entry.windowStart = now
      entry.count = 1
      sessionCreationRates[ip] = entry
      return true
    if entry.count >= maxRate:
      return false
    inc entry.count
    sessionCreationRates[ip] = entry
    return true
  if sessionCreationRates.len > 100_000:
    discard pruneStaleRateEntries(now, windowSeconds)
    if sessionCreationRates.len > 100_000:
      sessionCreationRates.clear()
  sessionCreationRates[ip] = IpSessionRateEntry(count: 1, windowStart: now)
  true

proc copyStringMap(source: FastMap[string]): FastMap[string] =
  result = newFastMap[string]()
  if source == nil:
    discard result.reserve(8)
    return
  discard result.reserve(max(8, source.len * 2))
  for key, value in source:
    result[key] = value

proc ensureMemStore() =
  if not memStoreInitialized:
    memSessions = initTable[string, SessionData]()
    memSessionExpiry = initTable[string, int64]()
    memSessionTick = 1
    memStoreInitialized = true

proc evictExpiredSessions() =
  ensureMemStore()
  inc memSessionTick
  if (memSessionTick mod 128) != 0:
    return
  let nowTs = getTime().toUnix()
  var stale: seq[string] = @[]
  for sessionId, expiresAt in memSessionExpiry:
    if expiresAt <= nowTs:
      stale.add(sessionId)
  for sessionId in stale:
    memSessions.del(sessionId)
    memSessionExpiry.del(sessionId)

proc buildInMemoryStore(): SessionStore =
  SessionStore(
    load: proc(sessionId: string): tuple[found: bool, data: SessionData] =
      evictExpiredSessions()
      if not memSessions.hasKey(sessionId):
        return (false, nil)
      let expiresAt = memSessionExpiry.getOrDefault(sessionId, 0'i64)
      if expiresAt > 0 and getTime().toUnix() >= expiresAt:
        memSessions.del(sessionId)
        memSessionExpiry.del(sessionId)
        return (false, nil)
      (true, copyStringMap(memSessions[sessionId])),
    save: proc(sessionId: string, data: SessionData, ttlSeconds: int) =
      ensureMemStore()
      if memSessions.len >= MaxInMemorySessions and not memSessions.hasKey(sessionId):
        let nowTs = getTime().toUnix()
        var stale: seq[string] = @[]
        for sid, expiresAt in memSessionExpiry:
          if expiresAt <= nowTs:
            stale.add(sid)
        for sid in stale:
          memSessions.del(sid)
          memSessionExpiry.del(sid)
        if memSessions.len >= MaxInMemorySessions:
          return
      memSessions[sessionId] = copyStringMap(data)
      let expiresAt = getTime().toUnix() + int64(max(1, ttlSeconds))
      memSessionExpiry[sessionId] = expiresAt,
    delete: proc(sessionId: string) =
      ensureMemStore()
      memSessions.del(sessionId)
      memSessionExpiry.del(sessionId)
  )

## Backed by per-thread tables: sessions are not visible across worker
## threads, so use an external store (Redis/DB) with `runThreaded` or
## `runCluster`.
proc inMemorySessionStore*(): SessionStore =
  if defaultMemStore.load == nil:
    defaultMemStore = buildInMemoryStore()
  defaultMemStore

## Production-safe defaults for the session middleware.
proc defaultSessionOptions*(): SessionOptions =
  SessionOptions(
    cookieName: "sid",
    ttlSeconds: 86400,
    secureCookie: true,
    httpOnlyCookie: true,
    sameSite: "Lax",
    path: "/",
    domain: "",
    rolling: false,
    saveUninitialized: false,
    store: inMemorySessionStore(),
    allowInsecureCookie: false,
    allowClientReadableCookie: false,
    maxValueLen: DefaultMaxSessionValueLen,
    maxSessionSize: DefaultMaxSessionSize
  )

## Merges partial option literals with production-safe defaults.
proc normalizeSessionOptions*(options: SessionOptions): SessionOptions =
  let defaults = defaultSessionOptions()
  result = options
  if result.cookieName.len == 0:
    result.cookieName = defaults.cookieName
  if result.ttlSeconds <= 0:
    result.ttlSeconds = defaults.ttlSeconds
  if result.sameSite.len == 0:
    result.sameSite = defaults.sameSite
  if result.path.len == 0:
    result.path = defaults.path
  if result.store.load == nil and result.store.save == nil and result.store.delete == nil:
    result.store = defaults.store
  if not result.allowInsecureCookie:
    result.secureCookie = true
  if not result.allowClientReadableCookie:
    result.httpOnlyCookie = true
  if result.maxValueLen <= 0:
    result.maxValueLen = defaults.maxValueLen
  if result.maxSessionSize <= 0:
    result.maxSessionSize = defaults.maxSessionSize

proc buildSessionId(): string =
  var bytes: array[24, byte]
  result = newStringOfCap(48)
  if urandom(bytes):
    for b in bytes:
      result.add(b.toHex(2))

proc isSafeSessionId(value: string): bool {.inline.} =
  if value.len < 24 or value.len > 128:
    return false
  for c in value:
    case c
    of 'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.':
      discard
    else:
      return false
  true

proc isSafeSessionKey(key: string): bool {.inline.} =
  if key.len == 0:
    return false
  for c in key:
    case c
    of 'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.':
      discard
    else:
      return false
  true

proc intLocalOrDefault(locals: FastMap[string], key: string, fallback: int): int {.inline.} =
  let raw = locals.getOrDefault(key, "")
  if raw.len == 0:
    return fallback
  result = 0
  for c in raw:
    if c < '0' or c > '9':
      return fallback
    result = result * 10 + (c.int - '0'.int)
  if result <= 0:
    result = fallback

## Read a session value by key, returning the default when unset.
proc sessionGet*(req: Req, key: string, default: string = ""): string {.inline.} =
  if req == nil or not key.isSafeSessionKey():
    return default
  req.locals.getOrDefault(SessionPrefix & key, default)

## Store a session value by key, respecting per-value and per-session size limits.
proc sessionSet*(req: Req, key: string, value: string) {.inline.} =
  if req == nil or not key.isSafeSessionKey():
    return
  if value.len > intLocalOrDefault(
      req.locals, SessionMaxValueLenLocal, DefaultMaxSessionValueLen):
    return
  let fullKey = SessionPrefix & key
  var total = 0
  for k, v in req.locals:
    if k.len > SessionPrefix.len and k.startsWith(SessionPrefix):
      if k != fullKey:
        total += k.len + v.len
  if total + fullKey.len + value.len > intLocalOrDefault(
      req.locals, SessionMaxSizeLocal, DefaultMaxSessionSize):
    return
  req.locals[fullKey] = value

## Remove a single key from the current session.
proc sessionDelete*(req: Req, key: string) {.inline.} =
  if req == nil or not key.isSafeSessionKey():
    return
  discard req.locals.del(SessionPrefix & key)

## Mark the current session for deletion when the response finalizes.
proc destroySession*(req: Req) {.inline.} =
  if req == nil:
    return
  req.locals[SessionDestroyLocal] = "1"

proc canSetSessionCookie(req: Req, res: Res): bool {.inline.} =
  if req == nil or res == nil or res.finished:
    return false
  if req.requestCancelled() or req.requestReleased():
    return false
  if res.native != nil and (res.native.headersSent or res.native.bodySent):
    return false
  true

proc setSessionCookie(req: Req, res: Res, opts: SessionOptions, sessionId: string) {.inline.} =
  if not canSetSessionCookie(req, res):
    return
  discard res.cookie(
    opts.cookieName,
    sessionId,
    maxAge = max(1, opts.ttlSeconds),
    path = opts.path,
    domain = opts.domain,
    secure = opts.secureCookie,
    httpOnly = opts.httpOnlyCookie,
    sameSite = opts.sameSite
  )

## Rotate the session id, delete the old entry, and set a fresh cookie.
proc regenerateSessionId*(req: Req, res: Res, opts: SessionOptions): bool =
  if not canSetSessionCookie(req, res):
    return false
  let opts = normalizeSessionOptions(opts)
  let oldId = req.locals.getOrDefault(SessionIdLocal, "")
  let newId = buildSessionId()
  if newId.len == 0:
    return false
  if oldId.len > 0 and opts.store.delete != nil:
    try:
      opts.store.delete(oldId)
    except CatchableError:
      discard
  req.locals[SessionIdLocal] = newId
  setSessionCookie(req, res, opts, newId)
  true

proc collectSessionData(req: Req): FastMap[string] =
  result = newFastMap[string]()
  discard result.reserve(8)
  for key, value in req.locals:
    if not key.startsWith(SessionPrefix):
      continue
    if key.len <= SessionPrefix.len:
      continue
    let sessionKey = key[SessionPrefix.len..^1]
    if sessionKey.isSafeSessionKey():
      result[sessionKey] = value

## Session middleware that loads and saves session data via the configured store.
proc session*(
  options: SessionOptions = defaultSessionOptions()
): AsyncMiddleware =
  let opts = normalizeSessionOptions(options)
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if options.maxValueLen > 0:
      req.locals[SessionMaxValueLenLocal] = $options.maxValueLen
    if options.maxSessionSize > 0:
      req.locals[SessionMaxSizeLocal] = $options.maxSessionSize
    var sessionId = req.cookie(opts.cookieName)
    var created = false
    if not isSafeSessionId(sessionId):
      let clientIp = if req.native != nil: req.native.remoteIp else: ""
      if not checkSessionCreationRate(clientIp):
        res.status(429).send("Too Many Requests")
        return
      sessionId = buildSessionId()
      created = true
      if sessionId.len == 0:
        res.status(500).send("Internal Server Error")
        return
    req.locals[SessionIdLocal] = sessionId

    if opts.store.load != nil:
      var loaded: tuple[found: bool, data: SessionData]
      try:
        loaded = opts.store.load(sessionId)
      except CatchableError:
        loaded = (false, nil)
      if loaded.found and loaded.data != nil:
        for key, value in loaded.data:
          if value.len > opts.maxValueLen:
            continue
          req.locals[SessionPrefix & key] = value
      elif not created:
        let clientIp = if req.native != nil: req.native.remoteIp else: ""
        if not checkSessionCreationRate(clientIp):
          res.status(429).send("Too Many Requests")
          return
        let rotated = buildSessionId()
        if rotated.len == 0:
          res.status(500).send("Internal Server Error")
          return
        sessionId = rotated
        req.locals[SessionIdLocal] = sessionId
        created = true
    elif not created:
      let clientIp = if req.native != nil: req.native.remoteIp else: ""
      if not checkSessionCreationRate(clientIp):
        res.status(429).send("Too Many Requests")
        return
      sessionId = buildSessionId()
      if sessionId.len == 0:
        res.status(500).send("Internal Server Error")
        return
      req.locals[SessionIdLocal] = sessionId
      created = true

    if created and opts.saveUninitialized:
      setSessionCookie(req, res, opts, sessionId)

    var finalized = false
    proc finalizeSession() =
      if finalized:
        return
      finalized = true
      if req.locals.getOrDefault(SessionDestroyLocal, "") == "1":
        if opts.store.delete != nil and sessionId.len > 0:
          try:
            opts.store.delete(sessionId)
          except CatchableError:
            discard
        if canSetSessionCookie(req, res):
          discard res.clearCookie(opts.cookieName, path = opts.path, domain = opts.domain)
        return

      let data = collectSessionData(req)
      if data.len == 0 and not opts.saveUninitialized:
        if opts.rolling and not created and sessionId.len > 0:
          setSessionCookie(req, res, opts, sessionId)
        return

      if opts.store.save != nil and sessionId.len > 0:
        try:
          opts.store.save(sessionId, data, max(1, opts.ttlSeconds))
        except CatchableError as e:
          stderr.writeLine("[session] save error: ", e.msg)
      if (created and not opts.saveUninitialized) or opts.rolling:
        setSessionCookie(req, res, opts, sessionId)

    res.addBeforeFinalizeHook(proc() =
      finalizeSession()
    )

    try:
      await next()
    finally:
      finalizeSession()

when defined(nimExpressSessionImprovementsTest):
  ## Test-only: build a fresh random session id.
  proc sessionBuildIdForTest*(): string = buildSessionId()
  ## Test-only: check whether a session id contains only safe characters.
  proc sessionIsSafeIdForTest*(value: string): bool = isSafeSessionId(value)
  ## Test-only: check whether a session key contains only safe characters.
  proc sessionIsSafeKeyForTest*(key: string): bool = isSafeSessionKey(key)
  ## Test-only: collect session data from request locals.
  proc sessionCollectDataForTest*(req: Req): FastMap[string] = collectSessionData(req)
  ## Test-only: copy a session data map.
  proc sessionCopyStringMapForTest*(source: FastMap[string]): FastMap[string] =
    copyStringMap(source)
  ## Test-only: check the per-IP session creation rate limit.
  proc sessionCheckCreationRateForTest*(
    ip: string,
    maxRate: int = SessionCreationRateLimit,
    windowSeconds: int = SessionCreationRateWindowSeconds
  ): bool = checkSessionCreationRate(ip, maxRate, windowSeconds)
  ## Test-only: seed a per-IP creation rate entry.
  proc sessionRateSeedForTest*(ip: string, windowStartAgoSeconds: int64) =
    sessionCreationRates[ip] = IpSessionRateEntry(
      count: 1, windowStart: getTime().toUnix() - windowStartAgoSeconds)
  ## Test-only: number of tracked per-IP rate entries.
  proc sessionRateLenForTest*(): int = sessionCreationRates.len
  ## Test-only: check whether a per-IP rate entry exists.
  proc sessionRateHasForTest*(ip: string): bool = sessionCreationRates.hasKey(ip)
