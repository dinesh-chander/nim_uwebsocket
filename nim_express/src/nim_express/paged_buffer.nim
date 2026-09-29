## Paged text buffer inspired by Kestrel-style pooled page writers.
## Optimized for repeated HTML rendering without building one giant string.

const
  DefaultPageBufferSize* = 4096
  DefaultPagePoolLimit* = 1024
  HtmlEscapeLookup*: array[256, bool] = block:
    var lut: array[256, bool]
    lut[ord('&')] = true
    lut[ord('<')] = true
    lut[ord('>')] = true
    lut[ord('"')] = true
    lut[ord('\'')] = true
    lut

type
  Page = object
    data: string
    used: int

  PageBuffer* = object
    pageSize*: int
    buffered*: int
    pages: seq[Page]
    poolPtr: ptr seq[string]
    maxRetainedPages: int
    maxRetainedBytes: int64

  PagePoolMetrics* = object
    hitCount*: int64
    missCount*: int64
    retainedBytes*: int64
    retainedPages*: int

  PagePoolPolicy* = object
    maxRetainedPages*: int
    maxRetainedBytes*: int64

when defined(singleThread) or defined(pagepool_single_thread):
  var
    pagePool: seq[string]
    pagePoolHitCount: int64
    pagePoolMissCount: int64
    pagePoolRetainedBytes: int64
    pagePoolMaxRetainedPages: int
    pagePoolMaxRetainedBytes: int64
    pagePoolPolicyInitialized: bool
else:
  var
    pagePool {.threadvar.}: seq[string]
    pagePoolHitCount {.threadvar.}: int64
    pagePoolMissCount {.threadvar.}: int64
    pagePoolRetainedBytes {.threadvar.}: int64
    pagePoolMaxRetainedPages {.threadvar.}: int
    pagePoolMaxRetainedBytes {.threadvar.}: int64
    pagePoolPolicyInitialized {.threadvar.}: bool

{.push stackTrace: off, checks: off.}

template bumpPagePoolHit() =
  when defined(pagepool_metrics):
    inc pagePoolHitCount

template bumpPagePoolMiss() =
  when defined(pagepool_metrics):
    inc pagePoolMissCount

proc ensurePoolPolicyInitialized() {.inline.} =
  if not pagePoolPolicyInitialized:
    pagePoolMaxRetainedPages = DefaultPagePoolLimit
    pagePoolMaxRetainedBytes = 0
    pagePoolPolicyInitialized = true

proc normalizeMaxRetainedPages(value: int): int {.inline.} =
  if value < 0:
    DefaultPagePoolLimit
  else:
    value

proc normalizeMaxRetainedBytes(value: int64): int64 {.inline.} =
  if value < 0'i64:
    0'i64
  else:
    value

proc refreshRetainedBytesFromPool() {.inline.} =
  pagePoolRetainedBytes = 0'i64
  for slot in pagePool:
    inc pagePoolRetainedBytes, slot.len.int64

## Returns hit, miss, and retention metrics for the shared page pool.
proc pagePoolMetrics*(): PagePoolMetrics {.inline.} =
  ensurePoolPolicyInitialized()
  when defined(pagepool_metrics):
    result.hitCount = pagePoolHitCount
    result.missCount = pagePoolMissCount
  else:
    result.hitCount = 0
    result.missCount = 0
  result.retainedBytes = pagePoolRetainedBytes
  result.retainedPages = pagePool.len

## Resets the page pool hit and miss counters.
proc resetPagePoolMetrics*() {.inline.} =
  when defined(pagepool_metrics):
    pagePoolHitCount = 0
    pagePoolMissCount = 0

## Returns the current page pool retention policy.
proc pagePoolPolicy*(): PagePoolPolicy {.inline.} =
  ensurePoolPolicyInitialized()
  result.maxRetainedPages = pagePoolMaxRetainedPages
  result.maxRetainedBytes = pagePoolMaxRetainedBytes

## Trims the shared page pool down to `retainPages` pages or `retainBytes` bytes.
proc trimPagePool*(retainPages: int = -1, retainBytes: int64 = -1'i64): int =
  ensurePoolPolicyInitialized()
  let targetPages =
    if retainPages >= 0:
      max(0, retainPages)
    else:
      max(0, pagePoolMaxRetainedPages)
  let enforceBytes = (retainBytes >= 0'i64) or (pagePoolMaxRetainedBytes > 0'i64)
  let targetBytes =
    if retainBytes >= 0'i64:
      max(0'i64, retainBytes)
    else:
      pagePoolMaxRetainedBytes

  if enforceBytes:
    refreshRetainedBytesFromPool()

  while pagePool.len > 0:
    let overPages = pagePool.len > targetPages
    let overBytes = enforceBytes and pagePoolRetainedBytes > targetBytes
    if not overPages and not overBytes:
      break
    let idx = pagePool.high
    dec pagePoolRetainedBytes, pagePool[idx].len.int64
    if pagePoolRetainedBytes < 0'i64:
      pagePoolRetainedBytes = 0'i64
    pagePool.setLen(idx)
    inc result

## Configures the page pool retention limits and optionally trims immediately.
proc setPagePoolEvictionPolicy*(
  maxRetainedPages: int = DefaultPagePoolLimit,
  maxRetainedBytes: int64 = 0'i64,
  trimNow: bool = false,
  trimTargetPages: int = -1,
  trimTargetBytes: int64 = -1'i64
): int =
  ensurePoolPolicyInitialized()
  pagePoolMaxRetainedPages = normalizeMaxRetainedPages(maxRetainedPages)
  pagePoolMaxRetainedBytes = normalizeMaxRetainedBytes(maxRetainedBytes)
  if pagePoolMaxRetainedBytes > 0'i64:
    refreshRetainedBytesFromPool()
  else:
    pagePoolRetainedBytes = 0'i64
  if trimNow:
    result = trimPagePool(trimTargetPages, trimTargetBytes)

proc ensurePoolPtrSlow(buf: var PageBuffer): ptr seq[string] {.noinline.} =
  if buf.poolPtr == nil:
    buf.poolPtr = addr pagePool
  buf.poolPtr

template ensurePoolPtr(buf: var PageBuffer): ptr seq[string] =
  (if buf.poolPtr != nil: buf.poolPtr else: ensurePoolPtrSlow(buf))

proc acquirePage(buf: var PageBuffer, pool: ptr seq[string]): Page {.inline.} =
  if pool[].len > 0:
    result.data = pool[][^1]
    let pooledLen = result.data.len
    if result.data.len != buf.pageSize:
      result.data.setLen(buf.pageSize)
    pool[].setLen(pool[].len - 1)
    bumpPagePoolHit()
    if buf.maxRetainedBytes > 0'i64:
      dec pagePoolRetainedBytes, pooledLen.int64
      if pagePoolRetainedBytes < 0'i64:
        pagePoolRetainedBytes = 0'i64
    result.used = 0
    return
  bumpPagePoolMiss()
  result.data = newString(buf.pageSize)
  result.used = 0

## Initializes a `PageBuffer` that draws pages of `pageSize` bytes from the shared pool.
proc initPageBuffer*(pageSize: int = DefaultPageBufferSize): PageBuffer =
  ensurePoolPolicyInitialized()
  result.pageSize = if pageSize > 0: pageSize else: DefaultPageBufferSize
  result.buffered = 0
  result.pages = @[]
  result.poolPtr = addr pagePool
  result.maxRetainedPages = pagePoolMaxRetainedPages
  result.maxRetainedBytes = pagePoolMaxRetainedBytes

## Pre-acquire `count` pages for `buf` from the shared pool to reduce page growth churn in hot render paths.
proc reservePages*(buf: var PageBuffer, count: int) {.inline.} =
  ## Pre-acquire writable pages from pool to reduce growth churn in hot render paths.
  if count <= 0:
    return
  let pool = buf.ensurePoolPtr()
  let target = max(0, count)
  while buf.pages.len < target:
    buf.pages.add(buf.acquirePage(pool))

proc ensureWritablePage(buf: var PageBuffer, pool: ptr seq[string]) {.inline.} =
  if buf.pages.len == 0 or buf.pages[^1].used >= buf.pageSize:
    buf.pages.add(buf.acquirePage(pool))

proc appendRaw(buf: var PageBuffer, pool: ptr seq[string], src: pointer, len: int) {.inline.} =
  if len <= 0:
    return

  var copied = 0
  let srcBase = cast[uint](src)
  while copied < len:
    buf.ensureWritablePage(pool)
    let idx = buf.pages.high
    let pageFree = buf.pageSize - buf.pages[idx].used
    let take = min(pageFree, len - copied)
    let oldLen = buf.pages[idx].used
    copyMem(addr buf.pages[idx].data[oldLen], cast[pointer](srcBase + cast[uint](copied)), take)
    buf.pages[idx].used = oldLen + take
    copied += take
    buf.buffered += take

proc addWithPool(buf: var PageBuffer, pool: ptr seq[string], text: string) {.inline.} =
  if text.len == 0:
    return
  buf.ensureWritablePage(pool)
  let idx = buf.pages.high
  let pageFree = buf.pageSize - buf.pages[idx].used
  if text.len <= pageFree:
    let oldLen = buf.pages[idx].used
    copyMem(addr buf.pages[idx].data[oldLen], unsafeAddr text[0], text.len)
    buf.pages[idx].used = oldLen + text.len
    buf.buffered += text.len
  else:
    buf.appendRaw(pool, unsafeAddr text[0], text.len)

proc addSliceWithPool(buf: var PageBuffer, pool: ptr seq[string], text: string, startPos, endPos: int) {.inline.} =
  if startPos < 0 or endPos <= startPos or endPos > text.len:
    return
  let sliceLen = endPos - startPos
  buf.ensureWritablePage(pool)
  let idx = buf.pages.high
  let pageFree = buf.pageSize - buf.pages[idx].used
  if sliceLen <= pageFree:
    let oldLen = buf.pages[idx].used
    copyMem(
      addr buf.pages[idx].data[oldLen],
      cast[pointer](cast[uint](unsafeAddr text[0]) + cast[uint](startPos)),
      sliceLen
    )
    buf.pages[idx].used = oldLen + sliceLen
    buf.buffered += sliceLen
  else:
    buf.appendRaw(
      pool,
      cast[pointer](cast[uint](unsafeAddr text[0]) + cast[uint](startPos)),
      sliceLen
    )

## Appends `text` into `buf` across pooled pages.
proc add*(buf: var PageBuffer, text: string) {.inline.} =
  let pool = buf.ensurePoolPtr()
  buf.addWithPool(pool, text)

## Append raw bytes from the external memory region `src` into the paged buffer `buf`.
proc appendRawPtr*(buf: var PageBuffer, src: pointer, len: int) {.inline.} =
  ## Append raw bytes from external memory directly into paged storage.
  if src == nil or len <= 0:
    return
  let pool = buf.ensurePoolPtr()
  buf.appendRaw(pool, src, len)

## Append raw bytes from `src` into the Nim string `dst` without intermediate copies.
proc appendRawPtr*(dst: var string, src: pointer, len: int) {.inline.} =
  ## Append raw bytes into a Nim string without intermediate copies.
  if src == nil or len <= 0:
    return
  let oldLen = dst.len
  dst.setLen(oldLen + len)
  copyMem(addr dst[oldLen], src, len)

## Ensure at least `requiredBytes` contiguous free bytes on the current page of `buf`; returns false when `requiredBytes` exceeds the page size.
proc ensureContiguousWritable*(buf: var PageBuffer, requiredBytes: int): bool {.inline.} =
  ## Ensure at least requiredBytes contiguous free bytes in the current page.
  ## Returns false when requiredBytes exceeds page size.
  if requiredBytes <= 0:
    return true
  if requiredBytes > buf.pageSize:
    return false
  let pool = buf.ensurePoolPtr()
  if buf.pages.len == 0 or (buf.pageSize - buf.pages[^1].used) < requiredBytes:
    buf.pages.add(buf.acquirePage(pool))
  true

## Copy raw bytes from `src` directly into the current page of `buf`; caller must ensure contiguous capacity first.
proc appendRawContiguousUnsafe*(buf: var PageBuffer, src: pointer, len: int) {.inline.} =
  ## Append bytes directly into current page.
  ## Caller must ensure contiguous capacity first.
  if src == nil or len <= 0:
    return
  if buf.pages.len == 0:
    let pool = buf.ensurePoolPtr()
    buf.ensureWritablePage(pool)
  let idx = buf.pages.high
  let oldLen = buf.pages[idx].used
  copyMem(addr buf.pages[idx].data[oldLen], src, len)
  buf.pages[idx].used = oldLen + len
  buf.buffered += len

## Reserve `requiredBytes` contiguous bytes on the current page of `buf` and return the destination pointer, or nil when the request is invalid.
proc reserveContiguousWritable*(buf: var PageBuffer, requiredBytes: int): pointer {.inline.} =
  ## Reserve contiguous bytes in current page and return destination pointer.
  ## Returns nil when requiredBytes is invalid or exceeds page size.
  if requiredBytes <= 0:
    return nil
  if not buf.ensureContiguousWritable(requiredBytes):
    return nil
  let idx = buf.pages.high
  let oldLen = buf.pages[idx].used
  result = addr buf.pages[idx].data[oldLen]
  buf.pages[idx].used = oldLen + requiredBytes
  buf.buffered += requiredBytes

## Append `text` directly into the current page of `buf`; caller must ensure contiguous capacity first.
proc appendStringContiguousUnsafe*(buf: var PageBuffer, text: string) {.inline.} =
  ## Append string directly into current page.
  ## Caller must ensure contiguous capacity first.
  if text.len <= 0:
    return
  buf.appendRawContiguousUnsafe(unsafeAddr text[0], text.len)
## Appends the slice of `text` between `startPos` and `endPos` into `buf`.
proc addSlice*(buf: var PageBuffer, text: string, startPos, endPos: int) {.inline.} =
  let pool = buf.ensurePoolPtr()
  buf.addSliceWithPool(pool, text, startPos, endPos)

## Appends the single character `c` into `buf`.
proc add*(buf: var PageBuffer, c: char) {.inline.} =
  let pool = buf.ensurePoolPtr()
  buf.ensureWritablePage(pool)
  let idx = buf.pages.high
  if buf.pages[idx].used >= buf.pageSize:
    buf.pages.add(buf.acquirePage(pool))
  let dstIdx = buf.pages.high
  let pos = buf.pages[dstIdx].used
  buf.pages[dstIdx].data[pos] = c
  buf.pages[dstIdx].used = pos + 1
  inc buf.buffered

## Encode integer `n` as ASCII digits into caller-provided `storage` and return the active window.
proc encodeIntAscii*(n: int, storage: var openArray[char]): tuple[start: int, len: int] {.inline.} =
  ## Encode int as ASCII into caller-provided storage and return active window.
  if storage.len == 0:
    return (0, 0)

  var value = n
  var pos = storage.len

  if value == low(int):
    let minText = $value
    if minText.len > storage.len:
      return (0, 0)
    pos = storage.len - minText.len
    copyMem(addr storage[pos], unsafeAddr minText[0], minText.len)
    return (pos, minText.len)

  var negative = false
  if value < 0:
    negative = true
    value = -value

  if value == 0:
    dec pos
    storage[pos] = '0'
  else:
    while value > 0:
      dec pos
      storage[pos] = char(ord('0') + (value mod 10))
      value = value div 10

  if negative:
    dec pos
    storage[pos] = '-'

  (pos, storage.len - pos)

## Appends the decimal ASCII representation of `n` into `buf`.
proc addInt*(buf: var PageBuffer, n: int) {.inline.} =
  var digits: array[24, char]
  let encoded = encodeIntAscii(n, digits)
  if encoded.len <= 0:
    return
  let pool = buf.ensurePoolPtr()
  buf.appendRaw(pool, addr digits[encoded.start], encoded.len)

## Scans raw text and returns true when it contains characters needing HTML escaping.
proc hasHtmlEscapes*(textPtr: pointer, textLen: int): bool {.inline.} =
  if textPtr == nil or textLen <= 0:
    return false
  let textChars = cast[ptr UncheckedArray[uint8]](textPtr)
  var i = 0
  while i < textLen:
    if HtmlEscapeLookup[textChars[i]]:
      return true
    inc i
  false

## Appends `text` into `buf` with HTML special characters escaped.
proc addHtmlEscaped*(buf: var PageBuffer, text: string) =
  let pool = buf.ensurePoolPtr()
  var segmentStart = 0
  for i, c in text:
    case c
    of '&':
      buf.addSliceWithPool(pool, text, segmentStart, i)
      buf.addWithPool(pool, "&amp;")
      segmentStart = i + 1
    of '<':
      buf.addSliceWithPool(pool, text, segmentStart, i)
      buf.addWithPool(pool, "&lt;")
      segmentStart = i + 1
    of '>':
      buf.addSliceWithPool(pool, text, segmentStart, i)
      buf.addWithPool(pool, "&gt;")
      segmentStart = i + 1
    of '"':
      buf.addSliceWithPool(pool, text, segmentStart, i)
      buf.addWithPool(pool, "&quot;")
      segmentStart = i + 1
    of '\'':
      buf.addSliceWithPool(pool, text, segmentStart, i)
      buf.addWithPool(pool, "&#39;")
      segmentStart = i + 1
    else:
      discard
  if segmentStart < text.len:
    buf.addSliceWithPool(pool, text, segmentStart, text.len)

## Appends the raw text at `textPtr` into `buf` with HTML special characters escaped.
proc addHtmlEscaped*(buf: var PageBuffer, textPtr: pointer, textLen: int) =
  if textPtr == nil or textLen <= 0:
    return

  let pool = buf.ensurePoolPtr()
  let src = cast[ptr UncheckedArray[char]](textPtr)
  var segmentStart = 0

  for i in 0..<textLen:
    case src[i]
    of '&':
      if i > segmentStart:
        buf.appendRaw(
          pool,
          cast[pointer](cast[uint](textPtr) + cast[uint](segmentStart)),
          i - segmentStart
        )
      buf.addWithPool(pool, "&amp;")
      segmentStart = i + 1
    of '<':
      if i > segmentStart:
        buf.appendRaw(
          pool,
          cast[pointer](cast[uint](textPtr) + cast[uint](segmentStart)),
          i - segmentStart
        )
      buf.addWithPool(pool, "&lt;")
      segmentStart = i + 1
    of '>':
      if i > segmentStart:
        buf.appendRaw(
          pool,
          cast[pointer](cast[uint](textPtr) + cast[uint](segmentStart)),
          i - segmentStart
        )
      buf.addWithPool(pool, "&gt;")
      segmentStart = i + 1
    of '"':
      if i > segmentStart:
        buf.appendRaw(
          pool,
          cast[pointer](cast[uint](textPtr) + cast[uint](segmentStart)),
          i - segmentStart
        )
      buf.addWithPool(pool, "&quot;")
      segmentStart = i + 1
    of '\'':
      if i > segmentStart:
        buf.appendRaw(
          pool,
          cast[pointer](cast[uint](textPtr) + cast[uint](segmentStart)),
          i - segmentStart
        )
      buf.addWithPool(pool, "&#39;")
      segmentStart = i + 1
    else:
      discard

  if segmentStart < textLen:
    buf.appendRaw(
      pool,
      cast[pointer](cast[uint](textPtr) + cast[uint](segmentStart)),
      textLen - segmentStart
    )

## Appends the escaped raw text at `textPtr` directly into the Nim string `dst`.
proc addHtmlEscaped*(dst: var string, textPtr: pointer, textLen: int) {.inline.} =
  if textPtr == nil or textLen <= 0:
    return

  let src = cast[ptr UncheckedArray[char]](textPtr)
  var segmentStart = 0
  var i = 0
  while i < textLen:
    let ch = src[i]
    var replacement = ""
    case ch
    of '&':
      replacement = "&amp;"
    of '<':
      replacement = "&lt;"
    of '>':
      replacement = "&gt;"
    of '"':
      replacement = "&quot;"
    of '\'':
      replacement = "&#39;"
    else:
      discard

    if replacement.len > 0:
      if i > segmentStart:
        dst.appendRawPtr(
          cast[pointer](cast[uint](textPtr) + cast[uint](segmentStart)),
          i - segmentStart
        )
      dst.add(replacement)
      segmentStart = i + 1
    inc i

  if segmentStart < textLen:
    dst.appendRawPtr(
      cast[pointer](cast[uint](textPtr) + cast[uint](segmentStart)),
      textLen - segmentStart
    )

## Returns true when `buf` holds its data on exactly one page.
proc isSinglePage*(buf: PageBuffer): bool {.inline.} =
  buf.pages.len == 1 and buf.pages[0].used > 0

## Returns a pointer and length for the used region of the first page.
proc firstPageData*(buf: PageBuffer): tuple[dataPtr: pointer, dataLen: int] {.inline.} =
  if buf.pages.len > 0 and buf.pages[0].used > 0:
    result.dataPtr = addr buf.pages[0].data[0]
    result.dataLen = buf.pages[0].used
  else:
    result.dataPtr = nil
    result.dataLen = 0

## Writes each used page through `writeSegment` and returns false on the first failure.
proc flushTo*(buf: var PageBuffer, writeSegment: proc(segment: string): bool {.closure.}): bool =
  for i in 0..<buf.pages.len:
    if buf.pages[i].used == 0:
      continue
    let oldLen = buf.pages[i].data.len
    if oldLen != buf.pages[i].used:
      buf.pages[i].data.setLen(buf.pages[i].used)
    if not writeSegment(buf.pages[i].data):
      if oldLen != buf.pages[i].used:
        buf.pages[i].data.setLen(oldLen)
      return false
    if oldLen != buf.pages[i].used:
      buf.pages[i].data.setLen(oldLen)
    buf.pages[i].used = 0
  buf.buffered = 0
  true

## Writes each used page through the raw `writeSegment` callback without string conversion.
proc flushToRaw*(
  buf: var PageBuffer,
  writeSegment: proc(segmentPtr: pointer, segmentLen: int): bool {.closure.}
): bool =
  for i in 0..<buf.pages.len:
    let used = buf.pages[i].used
    if used <= 0:
      continue
    if not writeSegment(addr buf.pages[i].data[0], used):
      return false
    buf.pages[i].used = 0
  buf.buffered = 0
  true

## Joins all buffered page data into a single string and resets `buf`.
proc takeStringAndClear*(buf: var PageBuffer): string =
  if buf.buffered == 0:
    return ""
  result = newStringOfCap(buf.buffered)
  for i in 0..<buf.pages.len:
    if buf.pages[i].used > 0:
      let oldLen = buf.pages[i].data.len
      if oldLen != buf.pages[i].used:
        buf.pages[i].data.setLen(buf.pages[i].used)
      result.add(buf.pages[i].data)
      if oldLen != buf.pages[i].used:
        buf.pages[i].data.setLen(oldLen)
      buf.pages[i].used = 0
  buf.buffered = 0

## Resets all page usage counters in `buf` without releasing the pages.
proc clear*(buf: var PageBuffer) =
  for i in 0..<buf.pages.len:
    buf.pages[i].used = 0
  buf.buffered = 0

## Returns the pages of `buf` to the shared pool up to its retention limits.
proc release*(buf: var PageBuffer) =
  let pool = buf.ensurePoolPtr()
  let maxPages = buf.maxRetainedPages
  let maxBytes = buf.maxRetainedBytes
  for i in 0..<buf.pages.len:
    let pageBytes = buf.pages[i].data.len.int64
    var canRetain = maxPages > 0 and pool[].len < maxPages
    if canRetain and maxBytes > 0'i64:
      canRetain = (pagePoolRetainedBytes + pageBytes) <= maxBytes
    if canRetain:
      pool[].add(move buf.pages[i].data)
      if maxBytes > 0'i64:
        inc pagePoolRetainedBytes, pageBytes
    buf.pages[i].used = 0
  buf.pages.setLen(0)
  buf.buffered = 0

{.pop.}
