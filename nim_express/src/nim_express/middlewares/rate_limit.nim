## Rate limit middleware
##
## Fixed-window in-memory limiter. The store lives in the middleware
## instance, so under runThreaded/runCluster (one app factory per worker)
## the effective limit is multiplied by the worker count; run a single
## worker or use an external store for a global limit.
##
## Keying on forwarded headers honours the app-level proxy trust settings.
## Hop-count-only trust without a trustedProxyAllowlist lets a directly
## connected client rotate X-Forwarded-For to mint fresh buckets; configure
## an allowlist when rate limiting behind proxies.

import std/[asyncdispatch, math, strutils]
import common

const
  CleanupInterval = 256
  MaxRateLimitKeyLen = 128
  DefaultMaxRateLimitTrackedKeys* = 8192
  MaxRateLimitWindowMs = int64(2_592_000_000)

type
  RateLimitPreset* = enum
    rlpApiDefault
    rlpAuthStrict
    rlpBurst

  ## Not thread-safe: one store per event loop. runThreaded/runCluster build
  ## a fresh middleware (and store) per worker via the app factory.
  RateLimitStore = ref object
    counts: FastMap[int64]
    resetAtMs: FastMap[int64]
    keyIndex: FastMap[int64]
    keys: seq[string]
    tick: int
    capacityDrops: int64
    keyEvictions: int64
    scanPos: int

when defined(singleThread):
  var lastRateLimitStoreForTest: RateLimitStore
else:
  var lastRateLimitStoreForTest {.threadvar.}: RateLimitStore

proc newRateLimitStore(): RateLimitStore =
  new(result)
  result.counts = newFastMap[int64]()
  result.resetAtMs = newFastMap[int64]()
  result.keyIndex = newFastMap[int64]()
  discard result.counts.reserve(512)
  discard result.resetAtMs.reserve(512)
  discard result.keyIndex.reserve(512)

proc evictKeyAt(store: RateLimitStore, idx: int) =
  if store == nil or idx < 0 or idx >= store.keys.len:
    return
  let key = store.keys[idx]
  discard store.counts.del(key)
  discard store.resetAtMs.del(key)
  discard store.keyIndex.del(key)

  let last = store.keys.len - 1
  if idx != last:
    let moved = store.keys[last]
    store.keys[idx] = moved
    discard store.keyIndex.put(moved, idx.int64)
  store.keys.setLen(last)

proc cleanupExpired(store: RateLimitStore, nowMs: int64) =
  if store == nil:
    return
  var i = 0
  while i < store.keys.len:
    let key = store.keys[i]
    let resetMs = store.resetAtMs.get(key, 0'i64)
    if resetMs == 0'i64 or nowMs >= resetMs:
      evictKeyAt(store, i)
    else:
      inc i

proc evictOneExpired(store: RateLimitStore, nowMs: int64): bool =
  # At most CleanupInterval keys can have been added since the last periodic
  # sweep, so a bounded rotating probe finds any expired key in a few calls
  # without scanning the whole table.
  if store == nil or store.keys.len == 0:
    return false
  let probes = min(CleanupInterval, store.keys.len)
  var i = 0
  while i < probes:
    let idx = (store.scanPos + i) mod store.keys.len
    let key = store.keys[idx]
    let resetMs = store.resetAtMs.get(key, 0'i64)
    if resetMs == 0'i64 or nowMs >= resetMs:
      evictKeyAt(store, idx)
      inc store.keyEvictions
      store.scanPos = (idx + 1) mod max(1, store.keys.len)
      return true
    inc i
  store.scanPos = (store.scanPos + probes) mod store.keys.len
  return false

proc sanitizeRateLimitKey(raw: string): string {.inline.} =
  let value = raw.strip()
  if value.len == 0:
    return ""
  if value.len <= MaxRateLimitKeyLen:
    var clean = true
    for c in value:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '_', ':', '[', ']'}:
        clean = false
        break
    if clean:
      return value
  result = newStringOfCap(min(MaxRateLimitKeyLen, value.len))
  for c in value:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '_', ':', '[', ']'}:
      result.add(c)
      if result.len >= MaxRateLimitKeyLen:
        break

## Number of keys tracked by the most recently created rate limit store.
proc rateLimitTrackedKeyCount*(): int {.inline.} =
  if lastRateLimitStoreForTest == nil:
    return 0
  lastRateLimitStoreForTest.keys.len

## Count of new keys dropped because the store reached its tracked-key capacity.
proc rateLimitKeyCapacityDrops*(): int64 {.inline.} =
  if lastRateLimitStoreForTest == nil:
    return 0'i64
  lastRateLimitStoreForTest.capacityDrops

## Count of expired keys evicted to make room for new keys.
proc rateLimitKeyEvictions*(): int64 {.inline.} =
  if lastRateLimitStoreForTest == nil:
    return 0'i64
  lastRateLimitStoreForTest.keyEvictions

## Test-only: clear all state in the most recently created rate limit store.
proc resetRateLimitStoreForTest*() =
  let store = lastRateLimitStoreForTest
  if store == nil:
    return
  store.counts.clear()
  store.resetAtMs.clear()
  store.keyIndex.clear()
  store.keys.setLen(0)
  store.tick = 0
  store.capacityDrops = 0'i64
  store.keyEvictions = 0'i64

## Fixed-window rate limit middleware keyed by trusted client IP.
proc rateLimit*(
  maxRequests: int = 100,
  windowMs: int = 60000,
  trustProxy: bool = false,
  maxTrackedKeys: int = DefaultMaxRateLimitTrackedKeys,
  rejectNewKeyWhenFull: bool = true
): AsyncMiddleware =
  let store = newRateLimitStore()
  lastRateLimitStoreForTest = store
  let limitStr = $maxRequests
  # rejectNewKeyWhenFull is kept for API compatibility: when the table is
  # full only expired keys are ever evicted, and new keys are rejected
  # when none are expired.
  result = proc(req: Req, res: Res, next: NextProc): Future[void] {.async.} =
    if req == nil or req.native == nil:
      return
    var key: string
    let trustForwarded = trustProxy or req.trustProxyEnabled
    if req.forwardedHeadersTrusted(trustForwarded):
      key = sanitizeRateLimitKey(req.trustedClientIp(trustProxyEnabled = trustForwarded))
    else:
      key = sanitizeRateLimitKey(req.native.remoteIp)
    if key.len == 0:
      key = "local"

    let nowMs = getCachedEpochMs()
    let windowMs64 = min(int64(max(1, windowMs)), MaxRateLimitWindowMs)
    let trackedCap = max(1, maxTrackedKeys)

    inc store.tick
    if (store.tick and (CleanupInterval - 1)) == 0 and store.keys.len > 0:
      cleanupExpired(store, nowMs)

    var count = store.counts.get(key, 0'i64)
    if count > 0:
      var resetMs = store.resetAtMs.get(key, 0'i64)
      if nowMs >= resetMs:
        # Window expired: start a fresh window.
        count = 1
        resetMs = nowMs + windowMs64
      else:
        inc count
      discard store.counts.put(key, count)
      discard store.resetAtMs.put(key, resetMs)

      if count > maxRequests.int64:
        let retryAfter = max(1, int(ceil((resetMs - nowMs).float / 1000.0)))
        res.set("Retry-After", $retryAfter)
        res.set("X-RateLimit-Limit", limitStr)
        res.set("X-RateLimit-Remaining", "0")
        res.set("X-RateLimit-Reset", $(resetMs div 1000))
        res.status(429)
        res.json(%*{"error": "Too many requests"})
        return

      res.set("X-RateLimit-Limit", limitStr)
      res.set("X-RateLimit-Remaining", $max(0'i64, maxRequests.int64 - count))
      res.set("X-RateLimit-Reset", $(resetMs div 1000))
    else:
      if not store.keyIndex.contains(key):
        if store.keys.len >= trackedCap and not evictOneExpired(store, nowMs):
          inc store.capacityDrops
          res.set("Retry-After", "1")
          res.set("X-RateLimit-Limit", limitStr)
          res.set("X-RateLimit-Remaining", "0")
          res.set("X-RateLimit-Reset", $((nowMs + 1000) div 1000))
          res.status(429)
          res.json(%*{"error": "Too many unique clients"})
          return
        let idx = store.keys.len
        store.keys.add(key)
        discard store.keyIndex.put(key, idx.int64)

      discard store.counts.put(key, 1'i64)
      discard store.resetAtMs.put(key, nowMs + windowMs64)

      if 1'i64 > maxRequests.int64:
        let resetMs = nowMs + windowMs64
        let retryAfter = max(1, int(ceil((resetMs - nowMs).float / 1000.0)))
        res.set("Retry-After", $retryAfter)
        res.set("X-RateLimit-Limit", limitStr)
        res.set("X-RateLimit-Remaining", "0")
        res.set("X-RateLimit-Reset", $(resetMs div 1000))
        res.status(429)
        res.json(%*{"error": "Too many requests"})
        return

      res.set("X-RateLimit-Limit", limitStr)
      res.set("X-RateLimit-Remaining", $max(0, maxRequests - 1))
      res.set("X-RateLimit-Reset", $((nowMs + windowMs64) div 1000))

    await next()

## Rate limit middleware built from a named preset profile.
proc rateLimitPreset*(
  preset: RateLimitPreset,
  trustProxy: bool = false,
  maxTrackedKeys: int = DefaultMaxRateLimitTrackedKeys
): AsyncMiddleware =
  case preset
  of rlpApiDefault:
    rateLimit(
      maxRequests = 120,
      windowMs = 60_000,
      trustProxy = trustProxy,
      maxTrackedKeys = maxTrackedKeys
    )
  of rlpAuthStrict:
    rateLimit(
      maxRequests = 20,
      windowMs = 60_000,
      trustProxy = trustProxy,
      maxTrackedKeys = maxTrackedKeys
    )
  of rlpBurst:
    rateLimit(
      maxRequests = 400,
      windowMs = 60_000,
      trustProxy = trustProxy,
      maxTrackedKeys = maxTrackedKeys,
      rejectNewKeyWhenFull = false
    )

when defined(nimExpressRateLimitTest):
  type RateLimitStoreForTest* = RateLimitStore

  ## Test-only: create a fresh in-memory rate limit store.
  proc rateLimitNewStoreForTest*(): RateLimitStoreForTest = newRateLimitStore()

  ## Test-only: sanitize a raw rate limit key.
  proc rateLimitSanitizeKeyForTest*(raw: string): string =
    sanitizeRateLimitKey(raw)

  ## Test-only: sweep expired keys from the store.
  proc rateLimitCleanupExpiredForTest*(store: RateLimitStoreForTest, nowMs: int64) =
    cleanupExpired(store, nowMs)

  ## Test-only: evict at most one expired key from the store.
  proc rateLimitEvictOneExpiredForTest*(store: RateLimitStoreForTest, nowMs: int64): bool =
    evictOneExpired(store, nowMs)

  ## Test-only: number of tracked keys in the store.
  proc rateLimitStoreKeyCount*(store: RateLimitStoreForTest): int =
    store.keys.len

  ## Test-only: check whether a key is tracked by the store.
  proc rateLimitStoreHasKey*(store: RateLimitStoreForTest, key: string): bool =
    store.keyIndex.contains(key)

  ## Test-only: current request count for a key.
  proc rateLimitStoreCount*(store: RateLimitStoreForTest, key: string): int64 =
    store.counts.get(key, 0'i64)

  ## Test-only: insert a key with a count and window reset time.
  proc rateLimitStoreInsert*(store: RateLimitStoreForTest, key: string, count: int64, resetMs: int64) =
    store.keys.add(key)
    discard store.keyIndex.put(key, store.keys.len.int64 - 1)
    discard store.counts.put(key, count)
    discard store.resetAtMs.put(key, resetMs)
