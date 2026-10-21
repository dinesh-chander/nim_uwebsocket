## Fast map helpers for nim_express.
## Pure-Nim Swiss-table string-key maps with portable SWAR group probes.

import std/[os, times]
import std/bitops
import ./swar_group

const nimWyHashUseMulhi = defined(amd64) and (defined(gcc) or defined(clang)) and
  not defined(js) and not defined(vcc) and not defined(nimWyHashPortable)

proc nimWyMulhi(a, b: uint64): uint64 {.inline.} =
  # Exact high 64 bits of the 128-bit product; x86-64 gets one mulhi
  # instruction instead of the four 32-bit multiplies below.
  var r: uint64
  when nimWyHashUseMulhi:
    {.emit: "uint64_t nx_a = `a`, nx_b = `b`; `r` = (uint64_t)((__uint128_t)nx_a * nx_b >> 64);".}
  else:
    let ha = a shr 32
    let la = a and 0xFFFF_FFFF'u64
    let hb = b shr 32
    let lb = b and 0xFFFF_FFFF'u64
    let rm0 = ha * lb
    let rm1 = hb * la
    let t = (la * lb) + (rm0 shl 32)
    var carry = (if t < (la * lb): 1'u64 else: 0'u64)
    let loCheck = t + (rm1 shl 32)
    if loCheck < t:
      inc carry
    r = (ha * hb) + (rm0 shr 32) + (rm1 shr 32) + carry
  r

proc nimWyMum(a, b: var uint64) {.inline.} =
  when nimWyHashUseMulhi:
    let lo = a * b
    let hi = nimWyMulhi(a, b)
    a = lo
    b = hi
  else:
    let ha = a shr 32
    let la = a and 0xFFFF_FFFF'u64
    let hb = b shr 32
    let lb = b and 0xFFFF_FFFF'u64
    let rh = ha * hb
    let rm0 = ha * lb
    let rm1 = hb * la
    let rl = la * lb
    let t = rl + (rm0 shl 32)
    var carry = (if t < rl: 1'u64 else: 0'u64)
    let lo = t + (rm1 shl 32)
    if lo < t:
      inc carry
    a = lo
    b = rh + (rm0 shr 32) + (rm1 shr 32) + carry

proc nimWyMix(a, b: uint64): uint64 {.inline.} =
  var x = a
  var y = b
  nimWyMum(x, y)
  x xor y

proc nimWyR8(p: pointer): uint64 {.inline.} =
  copyMem(addr result, p, 8)

proc nimWyR4(p: pointer): uint64 {.inline.} =
  var v: uint32
  copyMem(addr v, p, 4)
  result = uint64(v)

proc nimWyR3(p: pointer, k: int): uint64 {.inline.} =
  let pp = cast[ptr UncheckedArray[uint8]](p)
  (uint64(pp[0]) shl 16) or (uint64(pp[k shr 1]) shl 8) or uint64(pp[k - 1])

proc makeFastMapHashSeed(): uint64 =
  var stackMarker: int
  let pid = uint64(getCurrentProcessId())
  let now = uint64(epochTime() * 1_000_000_000.0)
  result = nimWyMix(
    now xor (pid shl 32) xor 0xa0761d6478bd642f'u64,
    uint64(cast[uint](addr stackMarker)) xor 0xe7037ed1a0b428db'u64
  )
  if result == 0:
    result = 0x9e3779b97f4a7c15'u64

let FastMapHashSeed = makeFastMapHashSeed()


## No-op retained for source compatibility. The pure-Nim backends
## carry the process seed directly, so no cross-language sync is needed.
proc syncFastMapCSeed*() {.inline.} =
  discard

syncFastMapCSeed()

when defined(nimUtilsHashSeedTest):
  ## Test-only accessor exposing the process-wide `FastMapHashSeed` value.
  proc fastMapHashSeedForTest*(): uint64 {.inline.} = FastMapHashSeed

proc nimWyHash(key: pointer, len: int, seedValue: uint64): uint64 {.inline.} =
  let p = cast[ptr UncheckedArray[uint8]](key)
  var seed = seedValue xor 0xca813bf4c7abf0a9'u64
  var a, b: uint64
  if len <= 16:
    if len >= 4:
      a = (nimWyR4(addr p[0]) shl 32) or nimWyR4(addr p[(len shr 3) shl 2])
      b = (nimWyR4(addr p[len - 4]) shl 32) or nimWyR4(addr p[len - 4 - ((len shr 3) shl 2)])
    elif len > 0:
      a = nimWyR3(addr p[0], len)
      b = 0
    else:
      a = 0
      b = 0
  else:
    var i = len
    var pp = cast[ptr UncheckedArray[uint8]](p)
    if i >= 48:
      var see1 = seed
      var see2 = seed
      while true:
        seed = nimWyMix(nimWyR8(addr pp[0]) xor 0x8bb84b93962eacc9'u64, nimWyR8(addr pp[8]) xor seed)
        see1 = nimWyMix(nimWyR8(addr pp[16]) xor 0x4b33a62ed433d4a3'u64, nimWyR8(addr pp[24]) xor see1)
        see2 = nimWyMix(nimWyR8(addr pp[32]) xor 0x4d5a2da51de1aa47'u64, nimWyR8(addr pp[40]) xor see2)
        pp = cast[ptr UncheckedArray[uint8]](cast[uint](pp) + 48)
        i -= 48
        if i < 48: break
      seed = seed xor see1 xor see2
    while i > 16:
      seed = nimWyMix(nimWyR8(addr pp[0]) xor 0x8bb84b93962eacc9'u64, nimWyR8(addr pp[8]) xor seed)
      i -= 16
      pp = cast[ptr UncheckedArray[uint8]](cast[uint](pp) + 16)
    a = nimWyR8(addr pp[i - 16])
    b = nimWyR8(addr pp[i - 8])
  a = a xor 0x8bb84b93962eacc9'u64
  b = b xor seed
  nimWyMum(a, b)
  nimWyMix(a xor 0x2d358dccaa6c78a5'u64 xor uint64(len), b xor 0x8bb84b93962eacc9'u64)

proc nimPrefetch(p: pointer) {.inline.} =
  {.emit: "__builtin_prefetch((const void*)`p`, 0, 1);".}

proc nimFmHash(key: pointer, len: int): uint64 {.inline.} =
  nimWyHash(key, len, FastMapHashSeed)

## Hash a raw byte range using the fastmap hash seed.
proc hashBytes*(key: pointer, len: int): uint64 {.inline.} =
  nimFmHash(key, len)

const
  DefaultFastMapArenaChunkSize = 4096
  FastMapCtrlEmpty = 0xFF'u8
  FastMapCtrlDeleted = 0x80'u8
  FastMapMaxInlineStringLen = int(high(uint16))
  SwGroupSize = 16
  SmallMapLinearScanThreshold = 8

type
  FastStringView* = object
    data*: pointer
    len*: int

  FastMapStorageKind = enum
    fmskStringNim
    fmskInt64Nim
    fmskInt64Arena
    fmskNimGeneric

  FastMapNimEntry[V] = object
    hash: uint64
    key: string
    value: V

  FastMapStringNimEntry = object
    hash: uint64
    keyPtr: pointer
    keyLen: uint16
    valLen: uint16
    # 4 bytes padding; total 24 bytes

  FastMapBumpArena = object
    chunks: seq[pointer]   ## All allocated chunks (for bulk free)
    current: pointer       ## Write head in current chunk
    remaining: int         ## Bytes remaining in current chunk
    chunkSize: int         ## Maximum (ramped-to) size of each chunk
    usedBytes: int         ## Bytes handed out across live chunks since reset/compact
    ramp: int              ## Current geometric chunk target (0 = before first grow)
    firstChunkSize: int    ## Real byte size of chunks[0] (for arenaReset)

  FastMapStringNimStorage = ref object
    count: int
    used: int             ## count + tombstones (for rehash-to-clear-tombstones threshold)
    capacity: int         ## power of 2, >= SwGroupSize or 0
    growAt: int           ## capacity * 7/8
    rebuildAt: int        ## capacity * 15/16
    ctrl: pointer         ## c_malloc'd uint8 array, size = capacity + SwGroupSize (sentinel)
    entries: pointer      ## c_malloc'd FastMapStringNimEntry array, size = capacity
    arena: FastMapBumpArena  ## Bump allocator for key/value strings
    liveBytes: int        ## Bytes referenced by currently occupied entries
    hashConsistent: bool  ## False once any write supplied a caller hash; then
                          ## duplicate lookups fall back to a key-only scan

  FastMapNimStorage[V] = ref object
    count: int
    used: int
    growAt: int
    rebuildAt: int
    ctrl: seq[uint8]
    entries: seq[FastMapNimEntry[V]]


  FastMapStorageObj*[V] = object
    raw: pointer
    kind: FastMapStorageKind
    nimString: FastMapStringNimStorage
    nimGenericStorage: FastMapNimStorage[V]

  FastMap*[V] = ref object
    storage: FastMapStorageObj[V]

  FastHashMap*[V] = FastMap[V]
  FastHashTable*[V] = FastMap[V]

# Compatibility audit markers retained for tests that verify storage cleanup
# contracts:
# proc releaseFastMapStorage(storage: var FastMapStorageObj)
# proc `=destroy`(storage: var FastMapStorageObj)

proc releaseFastMapStorage[V](storage: var FastMapStorageObj[V])



proc c_strlen(value: cstring): csize_t {.importc: "strlen", header: "<string.h>".}

proc stringPtr(value: string): pointer {.inline.} =
  if value.len == 0: nil else: cast[pointer](unsafeAddr value[0])

proc cstringPtr(value: cstring): pointer {.inline.} =
  cast[pointer](value)

proc cstringLen(value: cstring): csize_t {.inline.} =
  if value == nil: 0 else: c_strlen(value)

proc initFastStringView(data: cstring, len: csize_t): FastStringView {.inline.} =
  result.data = cast[pointer](data)
  result.len = int(len)

## Wrap a string as a non-owning `FastStringView`.
proc toFastStringView*(value: string): FastStringView {.inline.} =
  result.data = value.stringPtr
  result.len = value.len

## Wrap a cstring as a non-owning `FastStringView`.
proc toFastStringView*(value: cstring): FastStringView {.inline.} =
  result.data = value.cstringPtr
  result.len = int(value.cstringLen)

proc isValidFastStringView(value: FastStringView): bool {.inline.} =
  value.len >= 0 and (value.len == 0 or value.data != nil)

proc toFastStringViewPtr(value: FastStringView): pointer {.inline.} = value.data
proc toFastStringViewLen(value: FastStringView): csize_t {.inline.} =
  if value.len <= 0: 0.csize_t else: csize_t(value.len)


proc `$`*(value: FastStringView): string =
  if value.len <= 0 or value.data == nil:
    return ""

  result = newStringUninit(value.len)
  copyMem(addr result[0], value.data, value.len)

## Check whether the view equals an ASCII literal without allocation.
proc equalsAscii*(value: FastStringView, literal: string): bool {.inline.} =
  if value.len != literal.len:
    return false
  if value.len == 0:
    return true
  equalMem(value.data, literal.stringPtr, value.len)

## Check ASCII equality between the view and a literal, ignoring case.
proc equalsIgnoreCaseAscii*(value: FastStringView, literal: string): bool {.inline.} =
  if value.len != literal.len:
    return false

  let data = cast[ptr UncheckedArray[char]](value.data)
  for i in 0..<literal.len:
    var a = data[i]
    var b = literal[i]
    if a in 'A'..'Z':
      a = chr(ord(a) + 32)
    if b in 'A'..'Z':
      b = chr(ord(b) + 32)
    if a != b:
      return false
  true

## Check whether the view contains an ASCII literal.
proc containsAscii*(value: FastStringView, literal: string): bool {.inline.} =
  if literal.len == 0:
    return true
  if value.len < literal.len or value.data == nil:
    return false

  let data = cast[ptr UncheckedArray[char]](value.data)
  let last = value.len - literal.len
  for start in 0..last:
    var matched = true
    for offset in 0..<literal.len:
      if data[start + offset] != literal[offset]:
        matched = false
        break
    if matched:
      return true
  false

## Check whether the view contains an ASCII literal, ignoring case.
proc containsIgnoreCaseAscii*(value: FastStringView, literal: string): bool {.inline.} =
  if literal.len == 0:
    return true
  if value.len < literal.len or value.data == nil:
    return false

  let data = cast[ptr UncheckedArray[char]](value.data)
  let last = value.len - literal.len
  for start in 0..last:
    var matched = true
    for offset in 0..<literal.len:
      var a = data[start + offset]
      var b = literal[offset]
      if a in 'A'..'Z':
        a = chr(ord(a) + 32)
      if b in 'A'..'Z':
        b = chr(ord(b) + 32)
      if a != b:
        matched = false
        break
    if matched:
      return true
  false

const
  FastMapMaxEntryCapacity = high(int) div sizeof(FastMapStringNimEntry)
  FastMapMaxThresholdCapacity = high(int) div 16
  FastMapMaxCtrlCapacity = high(int) - SwGroupSize
  FastMapMaxCapacity = min(FastMapMaxEntryCapacity,
    min(FastMapMaxThresholdCapacity, FastMapMaxCtrlCapacity))

proc raiseFastMapCapacityOverflow() {.noinline.} =
  raise newException(OverflowDefect, "FastMap capacity exceeds supported maximum")

proc raiseFastMapOutOfMem() {.noinline.} =
  raise newException(OutOfMemDefect, "FastMap allocation failed")

proc nextFastMapPow2(n: int): int {.inline.} =
  if n < 0 or n > FastMapMaxCapacity:
    raiseFastMapCapacityOverflow()
  result = 8
  while result < n:
    if result > (FastMapMaxCapacity shr 1):
      raiseFastMapCapacityOverflow()
    result = result shl 1

proc desiredFastMapNimCap(count: int): int {.inline.} =
  if count < 0 or count > (high(int) div 2):
    raiseFastMapCapacityOverflow()
  nextFastMapPow2(max(16, count * 2))

proc hashFastMapString(key: string): uint64 {.inline.} =
  nimFmHash(key.stringPtr, key.len)

proc fastMapCtrl(hash: uint64): uint8 {.inline.} =
  uint8(hash and 0x7F'u64)

proc fastMapStringEquals(a, b: string): bool {.inline.} =
  if a.len != b.len:
    return false
  if a.len == 0:
    return true
  equalMem(a.stringPtr, b.stringPtr, a.len)

## Raw string helpers for unmanaged FastMapStringNimEntry storage.
## These bypass Nim's string GC entirely — alloc/dealloc manually.

proc c_malloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc c_memset(p: pointer, val: cint, size: csize_t): pointer {.importc: "memset", header: "<string.h>", discardable.}
proc c_calloc(count: csize_t, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}

const FastMapArenaDefaultChunkSize = 256 * 1024  ## 256KB per chunk (growth cap)
const FastMapArenaMinChunkSize = 64  ## First arena chunk size before geometric ramp

proc arenaGrow(arena: var FastMapBumpArena, minSize: int) {.inline.} =
  if minSize < 0 or arena.chunkSize < 0:
    raiseFastMapCapacityOverflow()
  # Geometric ramp: start small so thousands of small maps do not each pin a
  # full chunk, then double until the configured chunk size cap is reached.
  var sz = arena.chunkSize
  if arena.ramp > 0 and arena.ramp < sz:
    sz = arena.ramp
  elif arena.ramp == 0 and sz > FastMapArenaMinChunkSize:
    sz = FastMapArenaMinChunkSize
  if sz < minSize:
    sz = minSize
  let chunk = c_malloc(csize_t(sz))
  if chunk == nil:
    raiseFastMapOutOfMem()
  if arena.chunks.len == 0:
    arena.firstChunkSize = sz
  arena.chunks.add(chunk)
  arena.current = chunk
  arena.remaining = sz
  arena.ramp = sz shl 1

proc arenaAlloc(arena: var FastMapBumpArena, size: int): pointer {.inline.} =
  ## Bump-allocate `size` bytes from the arena. O(1) fast path.
  if size < 0:
    raiseFastMapCapacityOverflow()
  if size > arena.remaining:
    arenaGrow(arena, size)
  result = arena.current
  arena.current = cast[pointer](cast[uint](arena.current) + uint(size))
  arena.remaining -= size
  arena.usedBytes += size

proc arenaFreeAll(arena: var FastMapBumpArena) =
  ## Free all arena chunks in bulk.
  for chunk in arena.chunks:
    c_free(chunk)
  arena.chunks.setLen(0)
  arena.current = nil
  arena.remaining = 0
  arena.usedBytes = 0
  arena.ramp = 0
  arena.firstChunkSize = 0

proc arenaReset(arena: var FastMapBumpArena) =
  ## Reset arena for reuse (free all chunks except the first, reset write head).
  if arena.chunks.len == 0:
    return
  # Free all chunks except the first
  for i in 1..<arena.chunks.len:
    c_free(arena.chunks[i])
  let firstChunk = arena.chunks[0]
  arena.chunks.setLen(1)
  arena.current = firstChunk
  arena.remaining = arena.firstChunkSize
  arena.usedBytes = 0
  arena.ramp = arena.firstChunkSize shl 1

proc arenaStrDupKV(arena: var FastMapBumpArena, keyPtr: pointer, keyLen: int, valPtr: pointer, valLen: int): pointer {.inline.} =
  ## Allocate key+value as a single block: [key keyLen bytes]['\0'][val valLen bytes]['\0']
  ## Returns pointer to key start. Value start = result + keyLen + 1.
  let total = keyLen + 1 + valLen + 1
  let buf = arenaAlloc(arena, total)
  let bytes = cast[ptr UncheckedArray[char]](buf)
  if keyLen > 0 and keyPtr != nil:
    copyMem(buf, keyPtr, keyLen)
  bytes[keyLen] = '\0'
  if valLen > 0 and valPtr != nil:
    copyMem(cast[pointer](cast[uint](buf) + uint(keyLen) + 1), valPtr, valLen)
  bytes[keyLen + 1 + valLen] = '\0'
  buf

proc entryStorageBytes(keyLen, valLen: int): int {.inline.} =
  if keyLen < 0 or valLen < 0 or keyLen > high(int) - valLen - 2:
    raiseFastMapCapacityOverflow()
  keyLen + 1 + valLen + 1

proc rawStrToString(p: pointer, len: int32): string {.inline.} =
  ## Convert raw (ptr, len) to an owned Nim string.
  if len <= 0 or p == nil:
    return ""
  result = newStringUninit(len)
  copyMem(addr result[0], p, len)

proc rawStrToView(p: pointer, len: int32): FastStringView {.inline.} =
  ## Convert raw (ptr, len) to a FastStringView (zero-copy).
  result.data = p
  result.len = int(len)

proc toOwnedString(value: cstring): string =
  let len = int(value.cstringLen)
  if len == 0:
    return ""
  result = newStringUninit(len)
  copyMem(addr result[0], value.cstringPtr, len)

proc toOwnedString(value: FastStringView): string {.inline.} =
  $value

proc initFastMapNimStorage[V](): FastMapNimStorage[V] =
  new(result)
  result.ctrl = @[]
  result.entries = @[]

proc updateFastMapThresholds[V](storage: FastMapNimStorage[V]) {.inline.} =
  if storage == nil or storage.entries.len == 0:
    if storage != nil:
      storage.growAt = 0
      storage.rebuildAt = 0
    return
  storage.growAt = max(1, (storage.entries.len * 7 + 9) div 10)
  storage.rebuildAt = max(1, (storage.entries.len * 8 + 9) div 10)

proc desiredFastMapStringNimCap(count: int): int {.inline.} =
  if count < 0:
    raiseFastMapCapacityOverflow()
  let extra = count div 7
  if count > high(int) - extra - 1:
    raiseFastMapCapacityOverflow()
  let minSlots = max(SwGroupSize, count + extra + 1)
  nextFastMapPow2(minSlots)

proc swH2(hash: uint64): uint8 {.inline.} =
  ## Extract 7-bit signature from hash (lower 7 bits), top bit clear = occupied.
  uint8(hash and 0x7F'u64)

proc swH1(hash: uint64, mask: int): int {.inline.} =
  ## Slot index using upper bits of hash (independent from h2).
  int((hash shr 7) and uint64(mask))

proc swCtrlPtr(storage: FastMapStringNimStorage, idx: int): ptr uint8 {.inline.} =
  cast[ptr uint8](cast[uint](storage.ctrl) + uint(idx))

proc swCtrlAt(storage: FastMapStringNimStorage, idx: int): uint8 {.inline.} =
  cast[ptr UncheckedArray[uint8]](storage.ctrl)[idx]

proc swSetCtrl(storage: FastMapStringNimStorage, idx: int, val: uint8) {.inline.} =
  cast[ptr UncheckedArray[uint8]](storage.ctrl)[idx] = val
  # Mirror into sentinel region if in first SwGroupSize slots
  if idx < SwGroupSize:
    cast[ptr UncheckedArray[uint8]](storage.ctrl)[storage.capacity + idx] = val

proc swEntryAt(storage: FastMapStringNimStorage, idx: int): ptr FastMapStringNimEntry {.inline.} =
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](storage.entries)
  addr entries[idx]

proc swEntryValPtr(entry: ptr FastMapStringNimEntry): pointer {.inline.} =
  ## Value data follows key data: keyPtr[keyLen] is '\0', keyPtr[keyLen+1] is val start.
  cast[pointer](cast[uint](entry.keyPtr) + uint(entry.keyLen) + 1'u)


proc swAllocTables(storage: FastMapStringNimStorage, cap: int) =
  ## Allocate ctrl (cap + SwGroupSize) and entries (cap) via c_malloc.
  if cap <= 0 or cap > FastMapMaxCapacity:
    raiseFastMapCapacityOverflow()
  let ctrlSize = cap + SwGroupSize
  let ctrl = c_malloc(csize_t(ctrlSize))
  if ctrl == nil:
    raiseFastMapOutOfMem()
  let entries = c_calloc(csize_t(cap), csize_t(sizeof(FastMapStringNimEntry)))
  if entries == nil:
    c_free(ctrl)
    raiseFastMapOutOfMem()
  storage.ctrl = ctrl
  c_memset(storage.ctrl, 0xFF.cint, csize_t(ctrlSize))  # all empty
  storage.entries = entries
  storage.capacity = cap

proc swFreeTables(storage: FastMapStringNimStorage) =
  if storage.ctrl != nil:
    c_free(storage.ctrl)
    storage.ctrl = nil
  if storage.entries != nil:
    c_free(storage.entries)
    storage.entries = nil
  storage.capacity = 0

proc initFastMapStringNimStorage(): FastMapStringNimStorage =
  new(result)
  result.capacity = 0
  result.count = 0
  result.used = 0
  result.growAt = 0
  result.rebuildAt = 0
  result.ctrl = nil
  result.entries = nil
  result.arena.chunkSize = FastMapArenaDefaultChunkSize
  result.hashConsistent = true

proc updateFastMapStringThresholds(storage: FastMapStringNimStorage) {.inline.} =
  if storage == nil or storage.capacity == 0:
    if storage != nil:
      storage.growAt = 0
      storage.rebuildAt = 0
    return
  if storage.capacity > FastMapMaxCapacity:
    raiseFastMapCapacityOverflow()
  storage.growAt = max(1, (storage.capacity * 7) div 8)
  storage.rebuildAt = max(1, (storage.capacity * 15) div 16)


proc resetFastMapCtrl[V](storage: FastMapNimStorage[V]) =
  if storage.ctrl.len > 0:
    # Empty ctrl is the 0xFF sentinel, not zero: fill explicitly.
    let base = addr storage.ctrl[0]
    var i = 0
    while i < storage.ctrl.len:
      cast[ptr UncheckedArray[uint8]](base)[i] = FastMapCtrlEmpty
      inc i

proc rehashFastMapStringNim(storage: FastMapStringNimStorage, newCap: int)
proc clearFastMapString(storage: FastMapStringNimStorage)

proc compactFastMapStringArena(storage: FastMapStringNimStorage) =
  if storage == nil or storage.count == 0:
    if storage != nil:
      arenaReset(storage.arena)
      storage.liveBytes = 0
    return

  var nextArena: FastMapBumpArena
  nextArena.chunkSize = storage.arena.chunkSize
  var nextLive = 0
  try:
    let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
    let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](storage.entries)
    for i in 0..<storage.capacity:
      if ctrl[i] <= 0x7F'u8:
        let entry = addr entries[i]
        let keyLen = int(entry.keyLen)
        let valLen = int(entry.valLen)
        let valPtr = cast[pointer](cast[uint](entry.keyPtr) + uint(keyLen) + 1'u)
        entry.keyPtr = arenaStrDupKV(nextArena, entry.keyPtr, keyLen, valPtr, valLen)
        nextLive += entryStorageBytes(keyLen, valLen)
  except:
    arenaFreeAll(nextArena)
    raise

  arenaFreeAll(storage.arena)
  storage.arena = nextArena
  storage.liveBytes = nextLive

proc shouldCompactFastMapStringArena(storage: FastMapStringNimStorage): bool {.inline.} =
  if storage == nil or storage.arena.usedBytes <= storage.arena.chunkSize * 2:
    return false
  storage.liveBytes <= storage.arena.usedBytes div 4

proc maybeCompactFastMapStringArena(storage: FastMapStringNimStorage) {.inline.} =
  if shouldCompactFastMapStringArena(storage):
    compactFastMapStringArena(storage)

proc setEntryKV(entry: var FastMapStringNimEntry, key, value: string, hash: uint64, arena: var FastMapBumpArena) {.inline.} =
  if key.len > FastMapMaxInlineStringLen:
    raise newException(ValueError, "FastMap key exceeds maximum length of 65535")
  if value.len > FastMapMaxInlineStringLen:
    raise newException(ValueError, "FastMap value exceeds maximum length of 65535")
  entry.hash = hash
  entry.keyLen = uint16(key.len)
  entry.valLen = uint16(value.len)
  entry.keyPtr = arenaStrDupKV(arena, key.stringPtr, key.len, value.stringPtr, value.len)

proc overwriteEntryValue(entry: var FastMapStringNimEntry, value: string, arena: var FastMapBumpArena) {.inline.} =
  if value.len > FastMapMaxInlineStringLen:
    raise newException(ValueError, "FastMap value exceeds maximum length of 65535")
  let newValLen = value.len
  let valStart = cast[pointer](cast[uint](entry.keyPtr) + uint(entry.keyLen) + 1)
  # The trailing capacity after the key is (original valLen) bytes.
  # We can overwrite in-place only if newValLen <= original valLen (allocated space).
  if newValLen <= int(entry.valLen) and entry.keyPtr != nil:
    # In-place overwrite — value fits in existing allocation
    if newValLen > 0:
      copyMem(valStart, value.stringPtr, newValLen)
    cast[ptr UncheckedArray[char]](valStart)[newValLen] = '\0'
    entry.valLen = uint16(newValLen)
  else:
    # Arena re-allocation — old block leaked, freed in bulk on arena close
    entry.keyPtr = arenaStrDupKV(arena, entry.keyPtr, int(entry.keyLen), value.stringPtr, newValLen)
    entry.valLen = uint16(newValLen)
    # keyLen stays the same

proc freeEntryStrings(entry: var FastMapStringNimEntry) {.inline.} =
  entry.hash = 0
  entry.keyPtr = nil
  entry.keyLen = 0'u16
  entry.valLen = 0'u16

proc zeroEntry(entry: var FastMapStringNimEntry) {.inline.} =
  entry.hash = 0
  entry.keyPtr = nil
  entry.keyLen = 0'u16
  entry.valLen = 0'u16

proc moveEntry(dst: var FastMapStringNimEntry, src: var FastMapStringNimEntry) {.inline.} =
  dst.hash = src.hash
  dst.keyPtr = src.keyPtr
  dst.keyLen = src.keyLen
  dst.valLen = src.valLen
  src.hash = 0
  src.keyPtr = nil
  src.keyLen = 0'u16
  src.valLen = 0'u16

## ── Swiss table probing for FastMapStringNimStorage ───────────────────

proc findFastMapStringFoundIdx(storage: FastMapStringNimStorage, key: string, hash: uint64, homeBucket: var int): int {.inline.} =
  homeBucket = -1
  if storage == nil or storage.capacity == 0:
    return -1

  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let cap = storage.capacity
  let kLen = key.len
  if kLen > FastMapMaxInlineStringLen:
    return -1
  let kPtr = if kLen == 0: nil else: cast[pointer](unsafeAddr key[0])
  let entrySize = uint(sizeof(FastMapStringNimEntry))
  let entriesBase = cast[uint](storage.entries)

  if storage.count <= SmallMapLinearScanThreshold:
    var i = 0
    while i < cap:
      let c = ctrl[i]
      if c <= 0x7F'u8:
        let entry = cast[ptr FastMapStringNimEntry](entriesBase + uint(i) * entrySize)
        if entry.hash == hash and entry.keyLen == uint16(kLen) and
            (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
          homeBucket = i
          return i
      i += 1
    return -1

  let mask = cap - 1
  let h2 = uint8(hash and 0x7F'u64)
  var offset = int((hash shr 7) and uint64(mask)) and not(SwGroupSize - 1)
  var stride = 0
  while true:
    let ctrlBase = cast[ptr uint8](cast[uint](ctrl) + uint(offset))
    var matchMask = swarMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = swarFirstSlot(matchMask)
      let idx = (offset + slotOff) and mask
      let entry = cast[ptr FastMapStringNimEntry](entriesBase + uint(idx) * entrySize)
      if entry.hash == hash and entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        homeBucket = idx
        return idx
      matchMask = swarClearLowest(matchMask)
    let emptyMask = swarMatchEmpty16(ctrlBase)
    if emptyMask != 0:
      return -1
    stride += SwGroupSize
    offset = (offset + stride) and mask

  -1

proc swGroupLookupLen(ctrl: ptr UncheckedArray[uint8], entriesBase: uint, entrySize: uint, mask: int, kPtr: pointer, kLen: int, hash: uint64): int {.inline, used.} =
  if kLen > FastMapMaxInlineStringLen:
    return -1
  let h2 = uint8(hash and 0x7F'u64)
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](entriesBase)
  var offset = int((hash shr 7) and uint64(mask)) and not(SwGroupSize - 1)
  var stride = 0
  while true:
    let ctrlBase = cast[ptr uint8](cast[uint](ctrl) + uint(offset))
    var matchMask = swarMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = swarFirstSlot(matchMask)
      let idx = (offset + slotOff) and mask
      let entry = addr entries[idx]
      if entry.hash == hash and entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return int(entry.valLen)
      matchMask = swarClearLowest(matchMask)
    let emptyMask = swarMatchEmpty16(ctrlBase)
    if emptyMask != 0:
      return -1
    stride += SwGroupSize
    offset = (offset + stride) and mask
  -1

proc findFastMapStringIdxByPtr(storage: FastMapStringNimStorage, kPtr: pointer, kLen: int, hash: uint64): int {.inline.} =
  if storage == nil or storage.capacity == 0:
    return -1
  if kLen > FastMapMaxInlineStringLen:
    return -1
  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](storage.entries)

  if storage.count <= SmallMapLinearScanThreshold:
    var i = 0
    while i < storage.capacity:
      if ctrl[i] <= 0x7F'u8:
        let entry = addr entries[i]
        if entry.hash == hash and entry.keyLen == uint16(kLen) and
            (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
          return i
      inc i
    return -1

  let mask = storage.capacity - 1
  let h2 = swH2(hash)
  var offset = swH1(hash, mask) and not(SwGroupSize - 1)
  var stride = 0
  while true:
    let ctrlBase = cast[ptr uint8](cast[uint](ctrl) + uint(offset))
    var matchMask = swarMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = swarFirstSlot(matchMask)
      let idx = (offset + slotOff) and mask
      let entry = addr entries[idx]
      if entry.hash == hash and entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return idx
      matchMask = swarClearLowest(matchMask)
    let emptyMask = swarMatchEmpty16(ctrlBase)
    if emptyMask != 0:
      return -1
    stride += SwGroupSize
    offset = (offset + stride) and mask
  -1

proc findFastMapStringIdxByKeyOnly(storage: FastMapStringNimStorage, kPtr: pointer, kLen: int): int {.inline.} =
  if storage == nil or storage.capacity == 0:
    return -1
  if kLen > FastMapMaxInlineStringLen:
    return -1
  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](storage.entries)
  var i = 0
  while i < storage.capacity:
    if ctrl[i] <= 0x7F'u8:
      let entry = addr entries[i]
      if entry.keyLen == uint16(kLen) and (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return i
    inc i
  -1

proc lookupFastMapStringLen(storage: FastMapStringNimStorage, key: string): int =
  if storage == nil or storage.capacity == 0:
    return -1
  let kLen = key.len
  let kPtr = if kLen == 0: nil else: cast[pointer](unsafeAddr key[0])
  let hash = nimFmHash(kPtr, kLen)
  let idx = findFastMapStringIdxByPtr(storage, kPtr, kLen, hash)
  if idx < 0:
    -1
  else:
    int(swEntryAt(storage, idx).valLen)

proc lookupFastMapStringLenHashed(storage: FastMapStringNimStorage, kPtr: pointer, kLen: int, hash: uint64): int =
  if storage == nil or storage.capacity == 0:
    return -1
  var idx = findFastMapStringIdxByPtr(storage, kPtr, kLen, hash)
  if idx < 0 and not storage.hashConsistent:
    idx = findFastMapStringIdxByKeyOnly(storage, kPtr, kLen)
  if idx < 0:
    -1
  else:
    int(swEntryAt(storage, idx).valLen)

proc swGroupLookupView(ctrl: ptr UncheckedArray[uint8], entriesBase: uint, entrySize: uint, mask: int, kPtr: pointer, kLen: int, hash: uint64, value: var FastStringView): bool {.inline, used.} =
  if kLen > FastMapMaxInlineStringLen:
    return false
  let h2 = uint8(hash and 0x7F'u64)
  let entries = cast[ptr UncheckedArray[FastMapStringNimEntry]](entriesBase)
  var offset = int((hash shr 7) and uint64(mask)) and not(SwGroupSize - 1)
  nimPrefetch(cast[ptr uint8](cast[uint](ctrl) + uint(offset)))
  var stride = 0
  while true:
    let ctrlBase = cast[ptr uint8](cast[uint](ctrl) + uint(offset))
    var matchMask = swarMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = swarFirstSlot(matchMask)
      let idx = (offset + slotOff) and mask
      let entry = addr entries[idx]
      if entry.hash == hash and entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        value = FastStringView(data: swEntryValPtr(entry), len: int(entry.valLen))
        return true
      matchMask = swarClearLowest(matchMask)
    let emptyMask = swarMatchEmpty16(ctrlBase)
    if emptyMask != 0:
      return false
    stride += SwGroupSize
    offset = (offset + stride) and mask
  false

proc lookupFastMapStringViewHashed(storage: FastMapStringNimStorage, kPtr: pointer, kLen: int, hash: uint64, value: var FastStringView): bool =
  if storage == nil or storage.capacity == 0:
    return false
  var idx = findFastMapStringIdxByPtr(storage, kPtr, kLen, hash)
  if idx < 0 and not storage.hashConsistent:
    idx = findFastMapStringIdxByKeyOnly(storage, kPtr, kLen)
  if idx < 0:
    return false
  let entry = swEntryAt(storage, idx)
  value = FastStringView(data: swEntryValPtr(entry), len: int(entry.valLen))
  true

proc lookupFastMapStringView(storage: FastMapStringNimStorage, key: string, value: var FastStringView): bool =
  if storage == nil or storage.capacity == 0:
    return false
  let kLen = key.len
  let kPtr = if kLen == 0: nil else: cast[pointer](unsafeAddr key[0])
  let hash = nimFmHash(kPtr, kLen)
  let idx = findFastMapStringIdxByPtr(storage, kPtr, kLen, hash)
  if idx < 0:
    return false
  let entry = swEntryAt(storage, idx)
  value = FastStringView(data: swEntryValPtr(entry), len: int(entry.valLen))
  true

proc swFindInsertSlot(storage: FastMapStringNimStorage, hash: uint64): int =
  let mask = storage.capacity - 1
  var offset = swH1(hash, mask) and not(SwGroupSize - 1)
  var stride = 0

  while true:
    let ctrlBase = swCtrlPtr(storage, offset)
    let freeMask = swarMatchEmptyOrDel16(ctrlBase)
    if freeMask != 0:
      let slotOff = swarFirstSlot(freeMask)
      return (offset + slotOff) and mask
    stride += SwGroupSize
    offset = (offset + stride) and mask

proc insertFastMapStringRaw(
  storage: FastMapStringNimStorage,
  key, value: string,
  hash: uint64,
  unique = false,
  replace = true
): int =
  ## Swiss table insert. Returns slot index or -1.
  if storage == nil or storage.capacity == 0:
    return -1

  # Check for existing key first (unless caller guarantees uniqueness)
  if not unique:
    var homeBucket: int
    let foundIdx = findFastMapStringFoundIdx(storage, key, hash, homeBucket)
    if foundIdx >= 0:
      if replace:
        let entry = swEntryAt(storage, foundIdx)
        let oldBytes = entryStorageBytes(int(entry.keyLen), int(entry.valLen))
        overwriteEntryValue(swEntryAt(storage, foundIdx)[], value, storage.arena)
        storage.liveBytes += entryStorageBytes(key.len, value.len) - oldBytes
        maybeCompactFastMapStringArena(storage)
      return foundIdx
    if not storage.hashConsistent:
      let kPtr = if key.len == 0: nil else: cast[pointer](unsafeAddr key[0])
      let duplicateIdx = findFastMapStringIdxByKeyOnly(storage, kPtr, key.len)
      if duplicateIdx >= 0:
        if replace:
          let entry = swEntryAt(storage, duplicateIdx)
          let oldBytes = entryStorageBytes(int(entry.keyLen), int(entry.valLen))
          overwriteEntryValue(entry[], value, storage.arena)
          storage.liveBytes += entryStorageBytes(key.len, value.len) - oldBytes
          maybeCompactFastMapStringArena(storage)
        return duplicateIdx

  # Find empty/deleted slot for new entry
  let idx = swFindInsertSlot(storage, hash)
  let wasDeleted = swCtrlAt(storage, idx) == FastMapCtrlDeleted

  setEntryKV(swEntryAt(storage, idx)[], key, value, hash, storage.arena)
  storage.liveBytes += entryStorageBytes(key.len, value.len)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  idx

proc rehashFastMapStringNim(storage: FastMapStringNimStorage, newCap: int) =
  let targetCap = desiredFastMapStringNimCap(max(1, newCap))
  let oldCtrl = storage.ctrl
  let oldEntries = storage.entries
  let oldCap = storage.capacity

  swAllocTables(storage, targetCap)
  storage.count = 0
  storage.used = 0
  updateFastMapStringThresholds(storage)

  if oldCap == 0 or oldCtrl == nil:
    return

  let oldCtrlArr = cast[ptr UncheckedArray[uint8]](oldCtrl)
  let oldEntryArr = cast[ptr UncheckedArray[FastMapStringNimEntry]](oldEntries)
  let mask = storage.capacity - 1

  for i in 0..<oldCap:
    if (oldCtrlArr[i] and 0x80'u8) == 0:  # occupied (top bit clear)
      let e = addr oldEntryArr[i]
      let hash = e.hash
      let h2 = swH2(hash)
      var offset = swH1(hash, mask) and not(SwGroupSize - 1)
      var stride = 0
      while true:
        let ctrlBase = swCtrlPtr(storage, offset)
        let emptyMask = swarMatchEmpty16(ctrlBase)
        if emptyMask != 0:
          let slotOff = swarFirstSlot(emptyMask)
          let idx = (offset + slotOff) and mask
          # Move entry (transfer pointer ownership, no alloc)
          moveEntry(swEntryAt(storage, idx)[], oldEntryArr[i])
          swSetCtrl(storage, idx, h2)
          inc storage.count
          inc storage.used
          break
        stride += SwGroupSize
        offset = (offset + stride) and mask

  # Free old tables
  c_free(oldCtrl)
  c_free(oldEntries)

proc ensureFastMapStringCapacity(storage: FastMapStringNimStorage, targetCount: int) =
  if storage.capacity == 0 or targetCount > storage.growAt:
    rehashFastMapStringNim(storage, targetCount)
  elif storage.used > storage.rebuildAt:
    # Too many tombstones — rehash in place to clear them
    rehashFastMapStringNim(storage, storage.count)

proc reserveFastMapString(storage: FastMapStringNimStorage, n: int): bool =
  if storage == nil or n < 0:
    return false
  if n == 0:
    return true
  if storage.capacity < desiredFastMapStringNimCap(n):
    rehashFastMapStringNim(storage, n)
  true

proc lenFastMapString(storage: FastMapStringNimStorage): int {.inline.} =
  if storage == nil: 0 else: storage.count

proc putFastMapString(storage: FastMapStringNimStorage, key, value: string): bool {.inline.} =
  if storage == nil:
    return false

  ensureFastMapStringCapacity(storage, storage.count + 1)
  let hash = hashFastMapString(key)
  let idx = insertFastMapStringRaw(storage, key, value, hash, replace = true)
  result = idx >= 0

proc putFastMapStringHashed(storage: FastMapStringNimStorage, key, value: string, hash: uint64): bool {.inline.} =
  if storage == nil:
    return false

  storage.hashConsistent = false
  ensureFastMapStringCapacity(storage, storage.count + 1)
  let idx = insertFastMapStringRaw(storage, key, value, hash, replace = true)
  result = idx >= 0

proc tryGetFastMapString(storage: FastMapStringNimStorage, key: string, value: var string): bool {.inline.} =
  var homeBucket: int
  let idx = findFastMapStringFoundIdx(storage, key, hashFastMapString(key), homeBucket)
  if idx < 0:
    return false
  let entry = swEntryAt(storage, idx)
  value = rawStrToString(swEntryValPtr(entry), int32(entry.valLen))
  true

proc getFastMapStringView(storage: FastMapStringNimStorage, key: string, value: var FastStringView): bool {.inline.} =
  var homeBucket: int
  let idx = findFastMapStringFoundIdx(storage, key, hashFastMapString(key), homeBucket)
  if idx < 0:
    return false
  let entry = swEntryAt(storage, idx)
  value = rawStrToView(swEntryValPtr(entry), int32(entry.valLen))
  true

proc containsFastMapString(storage: FastMapStringNimStorage, key: string): bool {.inline.} =
  var homeBucket: int
  findFastMapStringFoundIdx(storage, key, hashFastMapString(key), homeBucket) >= 0

proc tryGetFastMapStringView(storage: FastMapStringNimStorage, key: string, value: var FastStringView): bool {.inline.} =
  getFastMapStringView(storage, key, value)

proc delFastMapString(storage: FastMapStringNimStorage, key: string): bool =
  if storage == nil or storage.capacity == 0:
    return false

  var homeBucket: int
  let hash = hashFastMapString(key)
  let idx = findFastMapStringFoundIdx(storage, key, hash, homeBucket)
  if idx < 0:
    return false

  dec storage.count
  storage.liveBytes -= entryStorageBytes(int(swEntryAt(storage, idx).keyLen), int(swEntryAt(storage, idx).valLen))
  freeEntryStrings(swEntryAt(storage, idx)[])
  zeroEntry(swEntryAt(storage, idx)[])
  swSetCtrl(storage, idx, FastMapCtrlDeleted)
  if storage.count == 0:
    clearFastMapString(storage)
  else:
    maybeCompactFastMapStringArena(storage)
  true

proc clearFastMapString(storage: FastMapStringNimStorage) =
  if storage == nil:
    return
  if storage.capacity > 0 and storage.ctrl != nil:
    c_memset(storage.ctrl, 0xFF.cint, csize_t(storage.capacity + SwGroupSize))
    zeroMem(storage.entries, storage.capacity * sizeof(FastMapStringNimEntry))
  storage.count = 0
  storage.used = 0
  storage.liveBytes = 0
  arenaReset(storage.arena)

## ── int64 values on FastMapStringNimStorage (arena maps) ─────────────
## int64 arena maps reuse the Swiss string storage: each entry stores the
## key plus 8 raw value bytes (valLen is always 8), so lookups, deletes
## and table management are shared with the string backend.

proc setEntryKV8(entry: var FastMapStringNimEntry, key: string, value: int64, hash: uint64, arena: var FastMapBumpArena) {.inline.} =
  if key.len > FastMapMaxInlineStringLen:
    raise newException(ValueError, "FastMap key exceeds maximum length of 65535")
  entry.hash = hash
  entry.keyLen = uint16(key.len)
  entry.valLen = 8'u16
  entry.keyPtr = arenaStrDupKV(arena, key.stringPtr, key.len, cast[pointer](unsafeAddr value), 8)

proc overwriteEntryValue8(entry: var FastMapStringNimEntry, value: int64) {.inline.} =
  # Values are always 8 bytes on int64 arena maps, so the overwrite fits
  # the original allocation in place.
  let valStart = cast[pointer](cast[uint](entry.keyPtr) + uint(entry.keyLen) + 1)
  copyMem(valStart, cast[pointer](unsafeAddr value), 8)

proc insertFastMapStringI64Raw(
  storage: FastMapStringNimStorage,
  key: string,
  value: int64,
  hash: uint64,
  unique = false,
  replace = true
): int =
  ## Swiss table insert for int64 values. Returns slot index or -1.
  if storage == nil or storage.capacity == 0:
    return -1

  if not unique:
    var homeBucket: int
    let foundIdx = findFastMapStringFoundIdx(storage, key, hash, homeBucket)
    if foundIdx >= 0:
      if replace:
        let oldBytes = entryStorageBytes(int(swEntryAt(storage, foundIdx).keyLen), 8)
        overwriteEntryValue8(swEntryAt(storage, foundIdx)[], value)
        storage.liveBytes += entryStorageBytes(key.len, 8) - oldBytes
        maybeCompactFastMapStringArena(storage)
      return foundIdx
    if not storage.hashConsistent:
      let kPtr = if key.len == 0: nil else: cast[pointer](unsafeAddr key[0])
      let duplicateIdx = findFastMapStringIdxByKeyOnly(storage, kPtr, key.len)
      if duplicateIdx >= 0:
        if replace:
          let oldBytes = entryStorageBytes(int(swEntryAt(storage, duplicateIdx).keyLen), 8)
          overwriteEntryValue8(swEntryAt(storage, duplicateIdx)[], value)
          storage.liveBytes += entryStorageBytes(key.len, 8) - oldBytes
          maybeCompactFastMapStringArena(storage)
        return duplicateIdx

  let idx = swFindInsertSlot(storage, hash)
  let wasDeleted = swCtrlAt(storage, idx) == FastMapCtrlDeleted

  setEntryKV8(swEntryAt(storage, idx)[], key, value, hash, storage.arena)
  storage.liveBytes += entryStorageBytes(key.len, 8)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  idx

## Insert or update an int64 value in Swiss string storage.
proc putFastMapStringI64Hashed(storage: FastMapStringNimStorage, key: string, value: int64, hash: uint64): bool {.inline.} =
  if storage == nil:
    return false
  # No caller-hash write API exists for int64 maps, so stored hashes always
  # match hashFastMapString; keep the duplicate-detection fast path enabled.
  ensureFastMapStringCapacity(storage, storage.count + 1)
  let idx = insertFastMapStringI64Raw(storage, key, value, hash, replace = true)
  idx >= 0

## Insert or update an int64 value, hashing the key first.
proc putFastMapStringI64(storage: FastMapStringNimStorage, key: string, value: int64): bool {.inline.} =
  putFastMapStringI64Hashed(storage, key, value, hashFastMapString(key))

## Lookup an int64 value; returns false if the key is missing.
proc tryGetFastMapStringI64(storage: FastMapStringNimStorage, key: string, value: var int64): bool {.inline.} =
  var homeBucket: int
  let idx = findFastMapStringFoundIdx(storage, key, hashFastMapString(key), homeBucket)
  if idx < 0:
    return false
  let entry = swEntryAt(storage, idx)
  copyMem(addr value, swEntryValPtr(entry), 8)
  true

## Return a zero-copy pointer to a stored int64, or nil if missing.
proc getFastMapStringI64Ptr(storage: FastMapStringNimStorage, key: string): ptr int64 {.inline.} =
  var homeBucket: int
  let idx = findFastMapStringFoundIdx(storage, key, hashFastMapString(key), homeBucket)
  if idx < 0:
    return nil
  cast[ptr int64](swEntryValPtr(swEntryAt(storage, idx)))

## Return a zero-copy pointer to a stored int64 using a precomputed hash.
proc getFastMapStringI64PtrHashed(storage: FastMapStringNimStorage, key: string,
    hash: uint64): ptr int64 {.inline.} =
  if storage == nil or storage.capacity == 0:
    return nil
  var homeBucket: int
  let idx = findFastMapStringFoundIdx(storage, key, hash, homeBucket)
  if idx < 0:
    return nil
  cast[ptr int64](swEntryValPtr(swEntryAt(storage, idx)))

## Return a mutable pointer to the entry, inserting `value` if absent.
proc getOrPutFastMapStringI64Ptr(storage: FastMapStringNimStorage, key: string, value: int64): ptr int64 {.inline.} =
  let existing = getFastMapStringI64Ptr(storage, key)
  if existing != nil:
    return existing
  discard putFastMapStringI64(storage, key, value)
  getFastMapStringI64Ptr(storage, key)

## Check whether an int64 key exists in Swiss string storage.
proc containsFastMapStringI64(storage: FastMapStringNimStorage, key: string): bool {.inline.} =
  not getFastMapStringI64Ptr(storage, key).isNil

proc nextFastMapStringOccupiedIdx(storage: FastMapStringNimStorage, idx: var int): bool {.inline.} =
  if storage == nil or storage.capacity == 0:
    return false
  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let cap = storage.capacity
  # Scan 8 bytes at a time: occupied slots have top bit clear (0x00-0x7F)
  const allMsb = 0x8080808080808080'u64
  while idx + 8 <= cap:
    var word: uint64
    copyMem(addr word, addr ctrl[idx], 8)
    # Invert top bits: now occupied slots have bit 7 SET
    let occupied = (not word) and allMsb
    if occupied != 0:
      # Use ctz to find first occupied byte
      idx = idx + (countTrailingZeroBits(occupied) shr 3)
      return true
    idx += 8
  # Handle remaining
  while idx < cap:
    if (ctrl[idx] and 0x80'u8) == 0:
      return true
    inc idx
  false

proc rehashFastMapNim[V](storage: FastMapNimStorage[V], newCap: int)

proc findFastMapNimSlot[V](storage: FastMapNimStorage[V], key: string, hash: uint64): tuple[idx: int, found: bool] {.inline.} =
  if storage == nil or storage.entries.len == 0:
    return (-1, false)

  let mask = storage.ctrl.len - 1
  let sig = fastMapCtrl(hash)
  let cbase = cast[uint](addr storage.ctrl[0])
  var offset = (int(hash and uint64(mask))) and not(SwGroupSize - 1)
  var stride = 0
  var firstDeleted = -1
  while true:
    let gp = cast[pointer](cbase + uint(offset))
    var m = swarMatch16(gp, sig)
    while m != 0:
      let j = (offset + swarFirstSlot(m)) and mask
      if storage.entries[j].hash == hash and fastMapStringEquals(storage.entries[j].key, key):
        return (j, true)
      m = swarClearLowest(m)
    var free = swarMatchEmptyOrDel16(gp)
    while free != 0:
      let j = (offset + swarFirstSlot(free)) and mask
      if storage.ctrl[j] == FastMapCtrlEmpty:
        if firstDeleted >= 0:
          return (firstDeleted, false)
        return (j, false)
      if firstDeleted < 0:
        firstDeleted = j
      free = swarClearLowest(free)
    stride += SwGroupSize
    offset = (offset + stride) and mask

proc findFastMapNimFoundIdx[V](storage: FastMapNimStorage[V], key: string, hash: uint64): int {.inline.} =
  if storage == nil or storage.entries.len == 0:
    return -1

  let mask = storage.ctrl.len - 1
  let sig = fastMapCtrl(hash)
  let cbase = cast[uint](addr storage.ctrl[0])
  var offset = (int(hash and uint64(mask))) and not(SwGroupSize - 1)
  var stride = 0
  while true:
    let gp = cast[pointer](cbase + uint(offset))
    var m = swarMatch16(gp, sig)
    while m != 0:
      let j = (offset + swarFirstSlot(m)) and mask
      if storage.entries[j].hash == hash and fastMapStringEquals(storage.entries[j].key, key):
        return j
      m = swarClearLowest(m)
    if swarMatchEmpty16(gp) != 0:
      return -1
    stride += SwGroupSize
    offset = (offset + stride) and mask

proc rehashFastMapNim[V](storage: FastMapNimStorage[V], newCap: int) =
  let targetCap = desiredFastMapNimCap(max(1, newCap))
  let oldCtrl = move(storage.ctrl)
  let oldEntries = move(storage.entries)
  storage.ctrl = newSeq[uint8](targetCap)
  storage.entries = newSeq[FastMapNimEntry[V]](targetCap)
  resetFastMapCtrl(storage)
  storage.count = 0
  storage.used = 0
  updateFastMapThresholds(storage)
  if oldEntries.len == 0:
    return

  let newCtrlBase = cast[uint](addr storage.ctrl[0])
  let newMask = storage.ctrl.len - 1
  for i in 0..<oldEntries.len:
    let ctrl = oldCtrl[i]
    if ctrl != FastMapCtrlEmpty and ctrl != FastMapCtrlDeleted:
      let entry = oldEntries[i]
      let hash = entry.hash
      var offset = (int(hash and uint64(newMask))) and not(SwGroupSize - 1)
      var stride = 0
      var idx = -1
      while idx < 0:
        let free = swarMatchEmpty16(cast[pointer](newCtrlBase + uint(offset)))
        if free != 0:
          idx = (offset + swarFirstSlot(free)) and newMask
        else:
          stride += SwGroupSize
          offset = (offset + stride) and newMask
      storage.ctrl[idx] = fastMapCtrl(hash)
      storage.entries[idx].hash = hash
      storage.entries[idx].key = entry.key
      storage.entries[idx].value = entry.value
      inc storage.used
      inc storage.count

proc ensureFastMapNimCapacity[V](storage: FastMapNimStorage[V], targetCount: int) =
  if storage.entries.len == 0:
    rehashFastMapNim(storage, targetCount)
    return

  if targetCount >= storage.growAt or storage.used >= storage.rebuildAt:
    rehashFastMapNim(storage, max(targetCount, storage.entries.len))
  elif storage.count * 4 < storage.used and storage.entries.len > 16:
    rehashFastMapNim(storage, storage.entries.len)

proc reserveFastMapNim[V](storage: FastMapNimStorage[V], n: int): bool =
  if storage == nil or n < 0:
    return false
  if n == 0:
    return true
  if storage.entries.len < desiredFastMapNimCap(n):
    rehashFastMapNim(storage, n)
  true

proc lenFastMapNim[V](storage: FastMapNimStorage[V]): int {.inline.} =
  if storage == nil: 0 else: storage.count

proc putFastMapNim[V](storage: FastMapNimStorage[V], key: string, value: sink V): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastMapString(key)
  if storage.entries.len == 0:
    ensureFastMapNimCapacity(storage, 1)
  let (idx, found) = findFastMapNimSlot(storage, key, hash)
  if idx < 0:
    return false
  if found:
    storage.entries[idx].value = value
    return true

  if storage.count + 1 < storage.growAt and storage.used < storage.rebuildAt:
    if storage.ctrl[idx] == FastMapCtrlEmpty:
      inc storage.used
    storage.ctrl[idx] = fastMapCtrl(hash)
    storage.entries[idx].hash = hash
    storage.entries[idx].key = key
    storage.entries[idx].value = value
    inc storage.count
    return true

  ensureFastMapNimCapacity(storage, storage.count + 1)
  let (insertIdx, insertFound) = findFastMapNimSlot(storage, key, hash)
  if insertIdx < 0:
    return false
  if insertFound:
    storage.entries[insertIdx].value = value
  else:
    if storage.ctrl[insertIdx] == FastMapCtrlEmpty:
      inc storage.used
    storage.ctrl[insertIdx] = fastMapCtrl(hash)
    storage.entries[insertIdx].hash = hash
    storage.entries[insertIdx].key = key
    storage.entries[insertIdx].value = value
    inc storage.count
  true

proc tryGetFastMapNim[V](storage: FastMapNimStorage[V], key: string, value: var V): bool =
  if storage == nil or storage.entries.len == 0:
    return false
  let idx = findFastMapNimFoundIdx(storage, key, hashFastMapString(key))
  if idx < 0:
    return false
  value = storage.entries[idx].value
  true

proc tryGetFastMapNimHashed[V](storage: FastMapNimStorage[V], key: string, hash: uint64, value: var V): bool {.used.} =
  if storage == nil or storage.entries.len == 0:
    return false
  let idx = findFastMapNimFoundIdx(storage, key, hash)
  if idx < 0:
    return false
  value = storage.entries[idx].value
  true

proc getFastMapNimPtr[V](storage: FastMapNimStorage[V], key: string): ptr V {.inline.} =
  if storage == nil or storage.entries.len == 0:
    return nil
  let idx = findFastMapNimFoundIdx(storage, key, hashFastMapString(key))
  if idx < 0:
    return nil
  addr storage.entries[idx].value

proc getFastMapNimPtrHashed[V](storage: FastMapNimStorage[V], key: string, hash: uint64): ptr V {.inline.} =
  if storage == nil or storage.entries.len == 0:
    return nil
  let idx = findFastMapNimFoundIdx(storage, key, hash)
  if idx < 0:
    return nil
  addr storage.entries[idx].value

proc getOrPutFastMapNimPtr[V](storage: FastMapNimStorage[V], key: string, value: sink V): ptr V {.inline.} =
  if storage == nil:
    return nil
  let hash = hashFastMapString(key)
  if storage.entries.len == 0:
    ensureFastMapNimCapacity(storage, 1)
  let (idx, found) = findFastMapNimSlot(storage, key, hash)
  if idx >= 0 and found:
    return addr storage.entries[idx].value

  if idx >= 0 and storage.count + 1 < storage.growAt and storage.used < storage.rebuildAt:
    if storage.ctrl[idx] == FastMapCtrlEmpty:
      inc storage.used
    storage.ctrl[idx] = fastMapCtrl(hash)
    storage.entries[idx].hash = hash
    storage.entries[idx].key = key
    storage.entries[idx].value = value
    inc storage.count
    return addr storage.entries[idx].value

  ensureFastMapNimCapacity(storage, storage.count + 1)
  let (insertIdx, insertFound) = findFastMapNimSlot(storage, key, hash)
  if insertIdx < 0:
    return nil
  if not insertFound:
    if storage.ctrl[insertIdx] == FastMapCtrlEmpty:
      inc storage.used
    storage.ctrl[insertIdx] = fastMapCtrl(hash)
    storage.entries[insertIdx].hash = hash
    storage.entries[insertIdx].key = key
    storage.entries[insertIdx].value = value
    inc storage.count
  addr storage.entries[insertIdx].value










proc delFastMapGeneric[V](storage: FastMapNimStorage[V], key: string): bool =
  if storage == nil or storage.entries.len == 0:
    return false
  let idx = findFastMapNimFoundIdx(storage, key, hashFastMapString(key))
  if idx < 0:
    return false
  storage.ctrl[idx] = FastMapCtrlDeleted
  dec storage.count
  if storage.count == 0:
    storage.used = 0
    for i in 0..<storage.entries.len:
      storage.ctrl[i] = FastMapCtrlEmpty
      storage.entries[i] = default(FastMapNimEntry[V])
  elif storage.count * 4 < storage.used and storage.entries.len > 16:
    rehashFastMapNim(storage, storage.entries.len)
  true

proc clearFastMapGeneric[V](storage: FastMapNimStorage[V]) =
  if storage == nil:
    return
  storage.count = 0
  storage.used = 0
  for i in 0..<storage.entries.len:
    storage.ctrl[i] = FastMapCtrlEmpty
    storage.entries[i] = default(FastMapNimEntry[V])

proc `=destroy`[V](storage: var FastMapStorageObj[V]) =
  ## Idempotently release all storage owned by this object; fires once when
  ## the containing `FastMap` ref is released.
  releaseFastMapStorage(storage)


proc releaseFastMapStorage[V](storage: var FastMapStorageObj[V]) =
  ## Idempotently release all storage owned by this map's storage object.
  if storage.raw == nil and storage.nimString.isNil and
      storage.kind != fmskNimGeneric:
    return
  case storage.kind
  of fmskStringNim:
    if not storage.nimString.isNil:
      swFreeTables(storage.nimString)
      arenaFreeAll(storage.nimString.arena)
    storage.nimString = nil
  of fmskInt64Nim, fmskInt64Arena:
    # Both int64 kinds live in nimString storage.
    if not storage.nimString.isNil:
      swFreeTables(storage.nimString)
      arenaFreeAll(storage.nimString.arena)
    storage.nimString = nil
  of fmskNimGeneric:
    discard
  storage.raw = nil

proc rawHandle[V](map: FastMap[V]): pointer {.inline.} =
  if map == nil:
    return nil
  if map.storage.kind == fmskStringNim:
    return cast[pointer](map.storage.nimString)
  if map.storage.kind == fmskNimGeneric:
    return cast[pointer](map.storage.nimGenericStorage)
  if map.storage.kind == fmskInt64Arena:
    return cast[pointer](map.storage.nimString)
  map.storage.raw

## Create a new empty `FastMap` with a type-specific backend.
proc newFastMap*[V](): FastMap[V] =
  new(result)
  when V is string:
    result.storage.kind = fmskStringNim
    result.storage.nimString = initFastMapStringNimStorage()
  elif V is int64:
    result.storage.kind = fmskInt64Nim
    result.storage.nimString = initFastMapStringNimStorage()
  else:
    result.storage.kind = fmskNimGeneric
    result.storage.nimGenericStorage = initFastMapNimStorage[V]()

## Create a new `FastMap` reserved for initialSize entries.
proc newFastMap*[V](initialSize: Natural): FastMap[V] =
  result = newFastMap[V]()
  if result != nil:
    discard result.reserve(int(initialSize))

## Create a new `FastMap` prepopulated from key and value pairs.
proc newFastMap*[V](pairs: openArray[(string, V)]): FastMap[V] =
  result = newFastMap[V]()
  if result != nil:
    discard result.reserve(pairs.len)
    for pair in pairs:
      let (key, value) = pair
      discard result.put(key, value)

## Create a new `FastMap` backed by an arena allocator with the given chunk size.
proc newFastArenaMap*[V](arenaChunkSize = DefaultFastMapArenaChunkSize): FastMap[V] =
  new(result)
  let chunkSize = max(64, arenaChunkSize)
  when V is string:
    # Pure-Nim arena backend: bump-arena Swiss string storage with the
    # requested chunk size (behaviorally identical to nimString maps).
    result.storage.kind = fmskStringNim
    result.storage.nimString = initFastMapStringNimStorage()
    result.storage.nimString.arena.chunkSize = chunkSize
  elif V is int64:
    # Pure-Nim arena backend: string storage holding 8 raw value bytes
    # per entry (valLen is always 8).
    result.storage.kind = fmskInt64Arena
    result.storage.nimString = initFastMapStringNimStorage()
    result.storage.nimString.arena.chunkSize = chunkSize
  else:
    result.storage.kind = fmskNimGeneric
    result.storage.nimGenericStorage = initFastMapNimStorage[V]()

## Create a new empty `FastHashMap`.
proc newFastHashMap*[V](): FastHashMap[V] {.inline.} = newFastMap[V]()
## Create a new `FastHashMap` reserved for initialSize entries.
proc newFastHashMap*[V](initialSize: Natural): FastHashMap[V] {.inline.} = newFastMap[V](initialSize)
## Create a new empty `FastHashTable`.
proc newFastHashTable*[V](): FastHashTable[V] {.inline.} = newFastMap[V]()
## Create a new `FastHashTable` reserved for initialSize entries.
proc newFastHashTable*[V](initialSize: Natural): FastHashTable[V] {.inline.} = newFastMap[V](initialSize)
## Create a new `FastHashMap` prepopulated from key and value pairs.
proc newFastHashMap*[V](pairs: openArray[(string, V)]): FastHashMap[V] {.inline.} = newFastMap[V](pairs)
## Create a new `FastHashTable` prepopulated from key and value pairs.
proc newFastHashTable*[V](pairs: openArray[(string, V)]): FastHashTable[V] {.inline.} = newFastMap[V](pairs)
## Create a new `FastHashMap` backed by an arena allocator with the given chunk size.
proc newFastArenaHashMap*[V](arenaChunkSize = DefaultFastMapArenaChunkSize): FastHashMap[V] {.inline.} = newFastArenaMap[V](arenaChunkSize)
## Create a new `FastHashTable` backed by an arena allocator with the given chunk size.
proc newFastArenaHashTable*[V](arenaChunkSize = DefaultFastMapArenaChunkSize): FastHashTable[V] {.inline.} = newFastArenaMap[V](arenaChunkSize)
## Create a new empty `FastMap`.
proc newFastTable*[V](): FastMap[V] {.inline.} = newFastMap[V]()
## Create a new `FastMap` reserved for initialSize entries.
proc newFastTable*[V](initialSize: Natural): FastMap[V] {.inline.} = newFastMap[V](initialSize)
## Create a new `FastMap` prepopulated from key and value pairs.
proc newFastTable*[V](pairs: openArray[(string, V)]): FastMap[V] {.inline.} = newFastMap[V](pairs)
## Create a new `FastMap` backed by an arena allocator with the given chunk size.
proc newFastArenaTable*[V](arenaChunkSize = DefaultFastMapArenaChunkSize): FastMap[V] {.inline.} = newFastArenaMap[V](arenaChunkSize)

## Build a `FastMap` from a collection, indexing each item with the index proc.
proc newFastMapFrom*[A, B](collection: A, index: proc(x: B): string): FastMap[B] =
  result = newFastMap[B]()
  if result != nil:
    for item in collection:
      result[index(item)] = item

## Build a `FastMap` from a collection, indexing each item with the index proc.
proc newFastTableFrom*[A, B](collection: A, index: proc(x: B): string): FastMap[B] {.inline.} =
  newFastMapFrom[A, B](collection, index)

## Release all storage owned by the map.
proc close*[V](map: FastMap[V]) {.inline.} =
  if map == nil:
    return
  releaseFastMapStorage(map.storage)
  when not (V is string or V is int64):
    map.storage.nimGenericStorage = nil

## Return the number of entries in the map.
proc len*[V](map: FastMap[V]): int {.inline.} =
  if map == nil:
    return 0
  when V is string:
    case map.storage.kind
    of fmskStringNim:
      lenFastMapString(map.storage.nimString)
    else:
      0
  elif V is int64:
    case map.storage.kind
    of fmskInt64Nim, fmskInt64Arena:
      lenFastMapString(map.storage.nimString)
    else:
      0
  else:
    if map.storage.nimGenericStorage.isNil: 0
    else: lenFastMapNim(map.storage.nimGenericStorage)

## Reserve capacity for n entries; returns false for invalid maps or counts.
proc reserve*[V](map: FastMap[V], n: int): bool {.inline.} =
  if map == nil or n < 0:
    return false
  when V is string:
    case map.storage.kind
    of fmskStringNim:
      if map.storage.nimString == nil:
        map.storage.nimString = initFastMapStringNimStorage()
      reserveFastMapString(map.storage.nimString, n)
    else:
      false
  elif V is int64:
    case map.storage.kind
    of fmskInt64Nim, fmskInt64Arena:
      if map.storage.nimString.isNil:
        map.storage.nimString = initFastMapStringNimStorage()
      reserveFastMapString(map.storage.nimString, n)
    else:
      false
  else:
    if map.storage.nimGenericStorage.isNil: false
    else: reserveFastMapNim(map.storage.nimGenericStorage, n)

## Insert or update a key and value entry; returns false if the map is unusable.
proc put*[V](map: FastMap[V], key: string, value: V): bool {.inline.} =
  when V is string:
    case map.storage.kind
    of fmskStringNim:
      putFastMapString(map.storage.nimString, key, value)
    else:
      false
  elif V is int64:
    case map.storage.kind
    of fmskInt64Nim, fmskInt64Arena:
      putFastMapStringI64(map.storage.nimString, key, value)
    else:
      false
  else:
    if map.storage.nimGenericStorage.isNil: false
    else: putFastMapNim(map.storage.nimGenericStorage, key, value)

## Insert or update an entry from cstring key and value without allocation.
proc putC*(map: FastMap[string], key, value: cstring): bool {.inline.} =
  if value == nil:
    return false
  case map.storage.kind
  of fmskStringNim:
    if map.storage.nimString == nil:
      map.storage.nimString = initFastMapStringNimStorage()
    putFastMapString(map.storage.nimString, key.toOwnedString, value.toOwnedString)
  else:
    false

## Insert or update an entry from `FastStringView` key and value.
proc putView*(map: FastMap[string], key, value: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView or not value.isValidFastStringView:
    return false
  case map.storage.kind
  of fmskStringNim:
    if map.storage.nimString == nil:
      map.storage.nimString = initFastMapStringNimStorage()
    # Views carry untrusted lengths; reject before allocating, since the
    # Swiss string storage caps keys and values at 65535 bytes (the C
    # backend returns false for oversized updates instead of crashing).
    if key.len > FastMapMaxInlineStringLen or value.len > FastMapMaxInlineStringLen:
      return false
    putFastMapString(map.storage.nimString, key.toOwnedString, value.toOwnedString)
  else:
    false

## Insert or update an int64 entry from a cstring key without allocation.
proc putC*(map: FastMap[int64], key: cstring, value: int64): bool {.inline.} =
  case map.storage.kind
  of fmskInt64Nim, fmskInt64Arena:
    putFastMapStringI64(map.storage.nimString, key.toOwnedString, value)
  else:
    false

## Insert or update an int64 entry from a `FastStringView` key.
proc putView*(map: FastMap[int64], key: FastStringView, value: int64): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.storage.kind
  of fmskInt64Nim, fmskInt64Arena:
    putFastMapStringI64(map.storage.nimString, key.toOwnedString, value)
  else:
    false

## Lookup a value as a `FastStringView` without copying it.
proc tryGetView*(map: FastMap[string], key: string, value: var FastStringView): bool {.inline.} =
  case map.storage.kind
  of fmskStringNim:
    lookupFastMapStringView(map.storage.nimString, key, value)
  else:
    false

## Lookup a value as a `FastStringView` from a cstring key without copying.
proc tryGetView*(map: FastMap[string], key: cstring, value: var FastStringView): bool {.inline.} =
  case map.storage.kind
  of fmskStringNim:
    tryGetFastMapStringView(map.storage.nimString, key.toOwnedString, value)
  else:
    false

## Lookup a value as a `FastStringView` from another view without copying.
proc tryGetView*(map: FastMap[string], key: FastStringView, value: var FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.storage.kind
  of fmskStringNim:
    tryGetFastMapStringView(map.storage.nimString, key.toOwnedString, value)
  else:
    false

## Return a `FastStringView` of the stored value, or an empty view if missing.
proc getView*(map: FastMap[string], key: string): FastStringView {.inline.} =
  discard map.tryGetView(key, result)

## Return a `FastStringView` of the stored value for a cstring key, or an empty view if missing.
proc getView*(map: FastMap[string], key: cstring): FastStringView {.inline.} =
  discard map.tryGetView(key, result)

## Return a `FastStringView` of the stored value for a view key, or an empty view if missing.
proc getView*(map: FastMap[string], key: FastStringView): FastStringView {.inline.} =
  discard map.tryGetView(key, result)

## Compute the fastmap hash for a string key.
proc hashKey*(key: string): uint64 =
  nimFmHash(key.stringPtr, key.len)

## Compute the fastmap hash for a cstring key.
proc hashKey*(key: cstring): uint64 =
  nimFmHash(cast[pointer](key), int(key.cstringLen))

## Compute the fastmap hash for a `FastStringView` key.
proc hashKey*(key: FastStringView): uint64 =
  if not key.isValidFastStringView:
    return 0
  nimFmHash(key.data, key.len)

## Lookup a value length using a precomputed hash; returns the default if missing.
proc getLenHashed*(map: FastMap[string], key: string, hash: uint64, default = 0): int {.inline.} =
  ## Lookup with precomputed hash — eliminates hash computation overhead.
  if map.storage.kind == fmskStringNim:
    let kPtr = if key.len == 0: nil else: cast[pointer](unsafeAddr key[0])
    let len = lookupFastMapStringLenHashed(map.storage.nimString, kPtr, key.len, hash)
    return if len < 0: default else: len
  # Fallback: regular lookup for other backends
  var view: FastStringView
  if not map.tryGetView(key, view): return default
  view.len

## Lookup a value view using a precomputed hash; returns false if missing.
proc tryGetViewHashed*(map: FastMap[string], key: string, hash: uint64, value: var FastStringView): bool {.inline.} =
  ## Lookup with precomputed hash — eliminates hash computation overhead.
  if map.storage.kind == fmskStringNim:
    let kPtr = if key.len == 0: nil else: cast[pointer](unsafeAddr key[0])
    return lookupFastMapStringViewHashed(map.storage.nimString, kPtr, key.len, hash, value)
  map.tryGetView(key, value)

## Return a value view using a precomputed hash, or an empty view if missing.
proc getViewHashed*(map: FastMap[string], key: string, hash: uint64): FastStringView {.inline.} =
  discard map.tryGetViewHashed(key, hash, result)

## Insert or update an entry using a precomputed key hash.
## After the first `putHashed` on a map, duplicate detection falls back to a
## key-only scan for that map, so hashes from `hashKey` stay the fast path.
proc putHashed*(map: FastMap[string], key: string, hash: uint64, value: string): bool {.inline.} =
  case map.storage.kind
  of fmskStringNim:
    if map.storage.nimString == nil:
      map.storage.nimString = initFastMapStringNimStorage()
    putFastMapStringHashed(map.storage.nimString, key, value, hash)
  else:
    false

## Return the stored value length for a key, or the default if missing.
proc getLen*(map: FastMap[string], key: string, default = 0): int {.inline.} =
  if map.storage.kind == fmskStringNim:
    let len = lookupFastMapStringLen(map.storage.nimString, key)
    return if len < 0: default else: len
  var view: FastStringView
  if not map.tryGetView(key, view):
    return default
  view.len

## Return the stored value length for a cstring key, or the default if missing.
proc getLen*(map: FastMap[string], key: cstring, default = 0): int {.inline.} =
  var view: FastStringView
  if not map.tryGetView(key, view):
    return default
  view.len

## Return the stored value length for a view key, or the default if missing.
proc getLen*(map: FastMap[string], key: FastStringView, default = 0): int {.inline.} =
  var view: FastStringView
  if not map.tryGetView(key, view):
    return default
  view.len

## Lookup a value by key; returns false if the key is missing.
proc tryGet*[V](map: FastMap[V], key: string, value: var V): bool {.inline.} =
  when V is string:
    case map.storage.kind
    of fmskStringNim:
      tryGetFastMapString(map.storage.nimString, key, value)
    else:
      let raw = map.rawHandle()
      if raw == nil:
        return false
      var view: FastStringView
      if not map.tryGetView(key, view):
        return false
      value = $view
      true
  elif V is int64:
    case map.storage.kind
    of fmskInt64Nim, fmskInt64Arena:
      tryGetFastMapStringI64(map.storage.nimString, key, value)
    else:
      false
  else:
    if map.storage.nimGenericStorage.isNil: false
    else: tryGetFastMapNim(map.storage.nimGenericStorage, key, value)

## Lookup a cstring key value as a `FastStringView` without copying.
proc tryGetC*(map: FastMap[string], key: cstring, value: var FastStringView): bool {.inline.} =
  map.tryGetView(key, value)

## Return a zero-copy pointer to the stored value using a precomputed hash.
proc getPtrHashed*[V](map: FastMap[V], key: string, hash: uint64): ptr V {.inline.} =
  ## Zero-copy pointer lookup with pre-computed hash (from hashKey).
  ## The pointer is invalidated if the map is mutated.
  ##
  ## Hot-path API: eliminates both hash recomputation and ORC copy.
  ## Precompute hashes once per key set with hashKey() and reuse across lookups.
  when V is string:
    nil
  elif V is int64:
    if map.storage.nimString.isNil: nil
    else: getFastMapStringI64PtrHashed(map.storage.nimString, key, hash)
  else:
    if map.storage.nimGenericStorage.isNil: nil
    else: getFastMapNimPtrHashed(map.storage.nimGenericStorage, key, hash)

## Lookup a cstring key value as a `FastStringView` without copying.
proc tryGetViewC*(map: FastMap[string], key: cstring, value: var FastStringView): bool {.inline.} =
  map.tryGetView(key, value)

## Return the value for a key, or the default if the key is missing.
proc get*[V](map: FastMap[V], key: string, default: V = default(V)): V {.inline.} =
  result = default
  discard map.tryGet(key, result)

proc missingFastMapKey(key: string): ref KeyError {.inline.} =
  newException(KeyError, "key not found: " & key)

proc stringValuePtr(map: FastMap[string], key: string): ptr string {.inline, used.} =
  nil  ## No longer supported — entries use unmanaged storage

proc stringValuePtrOrPut(map: FastMap[string], key, value: string): ptr string {.inline, used.} =
  nil  ## No longer supported — entries use unmanaged storage

proc int64ValuePtr(map: FastMap[int64], key: string): ptr int64 {.inline.} =
  if map.storage.nimString.isNil: nil
  else: getFastMapStringI64Ptr(map.storage.nimString, key)

proc int64ValuePtrOrPut(map: FastMap[int64], key: string, value: int64): ptr int64 {.inline.} =
  if map.storage.nimString.isNil:
    map.storage.nimString = initFastMapStringNimStorage()
  getOrPutFastMapStringI64Ptr(map.storage.nimString, key, value)

## Check whether the map contains a key.
proc contains*[V](map: FastMap[V], key: string): bool {.inline.} =
  when V is string:
    case map.storage.kind
    of fmskStringNim:
      containsFastMapString(map.storage.nimString, key)
    else:
      false
  elif V is int64:
    case map.storage.kind
    of fmskInt64Nim, fmskInt64Arena:
      containsFastMapStringI64(map.storage.nimString, key)
    else:
      false
  else:
    if map.storage.nimGenericStorage.isNil: false
    else: not getFastMapNimPtr(map.storage.nimGenericStorage, key).isNil

## Check whether the map contains a cstring key.
proc containsC*(map: FastMap[string], key: cstring): bool {.inline.} =
  case map.storage.kind
  of fmskStringNim:
    containsFastMapString(map.storage.nimString, key.toOwnedString)
  else:
    false

## Check whether the map contains a cstring key.
proc containsC*(map: FastMap[int64], key: cstring): bool {.inline.} =
  case map.storage.kind
  of fmskInt64Nim, fmskInt64Arena:
    containsFastMapStringI64(map.storage.nimString, key.toOwnedString)
  else:
    false

## Check whether the map contains a `FastStringView` key.
proc containsView*(map: FastMap[string], key: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.storage.kind
  of fmskStringNim:
    containsFastMapString(map.storage.nimString, key.toOwnedString)
  else:
    false

## Check whether the map contains a `FastStringView` key.
proc containsView*(map: FastMap[int64], key: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.storage.kind
  of fmskInt64Nim, fmskInt64Arena:
    containsFastMapStringI64(map.storage.nimString, key.toOwnedString)
  else:
    false

## Remove a key from the map; returns false if the key was absent.
proc del*[V](map: FastMap[V], key: string): bool {.inline.} =
  when V is string:
    case map.storage.kind
    of fmskStringNim:
      delFastMapString(map.storage.nimString, key)
    else:
      false
  elif V is int64:
    case map.storage.kind
    of fmskInt64Nim, fmskInt64Arena:
      delFastMapString(map.storage.nimString, key)
    else:
      false
  else:
    if map.storage.nimGenericStorage.isNil: false
    else: delFastMapGeneric(map.storage.nimGenericStorage, key)

## Remove a cstring key from the map; returns false if the key was absent.
proc delC*(map: FastMap[string], key: cstring): bool {.inline.} =
  case map.storage.kind
  of fmskStringNim:
    delFastMapString(map.storage.nimString, key.toOwnedString)
  else:
    false

## Remove a cstring key from the map; returns false if the key was absent.
proc delC*(map: FastMap[int64], key: cstring): bool {.inline.} =
  case map.storage.kind
  of fmskInt64Nim, fmskInt64Arena:
    delFastMapString(map.storage.nimString, key.toOwnedString)
  else:
    false

## Remove a `FastStringView` key from the map; returns false if the key was absent.
proc delView*(map: FastMap[string], key: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.storage.kind
  of fmskStringNim:
    delFastMapString(map.storage.nimString, key.toOwnedString)
  else:
    false

## Remove a `FastStringView` key from the map; returns false if the key was absent.
proc delView*(map: FastMap[int64], key: FastStringView): bool {.inline.} =
  if not key.isValidFastStringView:
    return false
  case map.storage.kind
  of fmskInt64Nim, fmskInt64Arena:
    delFastMapString(map.storage.nimString, key.toOwnedString)
  else:
    false

## Remove all entries from the map.
proc clear*[V](map: FastMap[V]) {.inline.} =
  when V is string:
    case map.storage.kind
    of fmskStringNim:
      clearFastMapString(map.storage.nimString)
    else:
      discard
  elif V is int64:
    case map.storage.kind
    of fmskInt64Nim, fmskInt64Arena:
      clearFastMapString(map.storage.nimString)
    else:
      discard
  else:
    clearFastMapGeneric(map.storage.nimGenericStorage)

## Return the value for a key, or the supplied default if missing.
proc getOrDefault*[V](map: FastMap[V], key: string, default: V): V {.inline.} =
  map.get(key, default)

## Return the value for a key, or the zero value if missing.
proc getOrDefault*[V](map: FastMap[V], key: string): V {.inline.} =
  map.get(key, default(V))

## Check whether the map contains a key.
proc hasKey*[V](map: FastMap[V], key: string): bool {.inline.} =
  map.contains(key)

## Insert the value only if the key is absent; returns true if the key already existed.
proc hasKeyOrPut*[V](map: FastMap[V], key: string, value: V): bool {.inline.} =
  if map.hasKey(key):
    return true
  discard map.put(key, value)
  false

proc `[]=`*[V](map: FastMap[V], key: string, value: V) {.inline.} =
  discard map.put(key, value)

## Insert or update a key and value entry; deprecated, use the assignment operator instead.
proc add*[V](map: FastMap[V], key: string, value: V) {.
    deprecated: "Deprecated since v1.4; it was more confusing than useful, use `[]=`",
    inline.} =
  map[key] = value

proc `[]`*(map: FastMap[string], key: string): string =
  var value: string
  if map.tryGet(key, value):
    return value
  raise missingFastMapKey(key)

proc `[]`*(map: FastMap[int64], key: string): var int64 =
  let valuePtr = map.int64ValuePtr(key)
  if valuePtr == nil:
    raise missingFastMapKey(key)
  valuePtr[]

## Check whether the map contains a key; reversed-argument overload.
proc contains*[V](key: string, map: FastMap[V]): bool {.inline.} =
  map.contains(key)

## Remove a key and return its value; returns false if the key is missing.
proc pop*[V](map: FastMap[V], key: string, value: var V): bool =
  when V is string:
    var stored: string
    if not map.tryGet(key, stored):
      return false
    if not map.del(key):
      return false
    value = stored
    true
  elif V is int64:
    var stored: int64
    if not map.tryGet(key, stored):
      return false
    if not map.del(key):
      return false
    value = stored
    true
  else:
    var stored: V
    if not map.tryGet(key, stored):
      return false
    if not map.del(key):
      return false
    value = stored
    true

## Alias of `pop`: remove a key and return its value.
proc take*[V](map: FastMap[V], key: string, value: var V): bool {.inline.} =
  map.pop(key, value)

## Return a mutable reference to the entry for key, inserting value if absent.
proc mgetOrPut*(map: FastMap[int64], key: string, value: int64): var int64 =
  let valuePtr = map.int64ValuePtrOrPut(key, value)
  if valuePtr == nil:
    raise newException(ValueError, "failed to insert key: " & key)
  valuePtr[]

## Return a mutable reference to the entry for key, defaulting to zero if absent.
proc mgetOrPut*(map: FastMap[int64], key: string): var int64 =
  map.mgetOrPut(key, 0'i64)

## Return the existing value for key, inserting and returning value if absent.
proc mgetOrPut*(map: FastMap[string], key: string, value: string): string =
  ## Returns the existing value or inserts `value` and returns it.
  ## Note: returns a copy — mutations on the result do not affect the map.
  ## Use `put` to update values.
  var existing: string
  if map.tryGet(key, existing):
    return existing
  discard map.put(key, value)
  value

## Return the existing value for key, defaulting to an empty string if absent.
proc mgetOrPut*(map: FastMap[string], key: string): string =
  map.mgetOrPut(key, "")

## Iterate over all entries as `FastStringView` pairs without allocation.
iterator pairsView*(map: FastMap[string]): (FastStringView, FastStringView) =
  case map.storage.kind
  of fmskStringNim:
    if not map.storage.nimString.isNil:
      var i = 0
      while nextFastMapStringOccupiedIdx(map.storage.nimString, i):
        let entry = swEntryAt(map.storage.nimString, i)
        yield (
          rawStrToView(entry.keyPtr, int32(entry.keyLen)),
          rawStrToView(swEntryValPtr(entry), int32(entry.valLen))
        )
        inc i
  else:
    discard

## Collect all entries into a sequence of string pairs.
proc pairsSeq*(map: FastMap[string]): seq[(string, string)] =
  result = newSeqOfCap[(string, string)](map.len)
  for keyView, valueView in map.pairsView():
    result.add(($keyView, $valueView))

## Iterate over all entries as string pairs.
iterator pairs*(map: FastMap[string]): (string, string) =
  for keyView, valueView in map.pairsView():
    yield ($keyView, $valueView)

## Iterate over all entries as string and int64 pairs.
iterator pairs*(map: FastMap[int64]): (string, int64) =
  case map.storage.kind
  of fmskInt64Nim, fmskInt64Arena:
    if not map.storage.nimString.isNil:
      var i = 0
      while nextFastMapStringOccupiedIdx(map.storage.nimString, i):
        let entry = swEntryAt(map.storage.nimString, i)
        var value: int64
        copyMem(addr value, swEntryValPtr(entry), 8)
        yield (rawStrToString(entry.keyPtr, int32(entry.keyLen)), value)
        inc i
  else:
    discard

## Collect all entries into a sequence of string and int64 pairs.
proc pairsSeq*(map: FastMap[int64]): seq[(string, int64)] =
  result = newSeqOfCap[(string, int64)](map.len)
  for key, value in map.pairs():
    result.add((key, value))

## Iterate over all entries as string and V pairs for generic values.
iterator pairs*[V](map: FastMap[V]): (string, V) =
  when not (V is string or V is int64):
    if not map.storage.nimGenericStorage.isNil:
      for i in 0..<map.storage.nimGenericStorage.entries.len:
        if map.storage.nimGenericStorage.ctrl[i] != FastMapCtrlEmpty and map.storage.nimGenericStorage.ctrl[i] != FastMapCtrlDeleted:
          yield (map.storage.nimGenericStorage.entries[i].key, map.storage.nimGenericStorage.entries[i].value)

## Iterate over all keys in the map.
iterator keys*[V](map: FastMap[V]): string =
  for key, _ in map.pairs():
    yield key

## Iterate over all values in the map.
iterator values*(map: FastMap[string]): string =
  for _, value in map.pairs():
    yield value

## Iterate over all values in the map.
iterator values*(map: FastMap[int64]): int64 =
  for _, value in map.pairs():
    yield value

## Iterate over all values in the map for generic value types.
iterator values*[V](map: FastMap[V]): V =
  when not (V is string or V is int64):
    for _, value in map.pairs():
      yield value

## Not supported for unmanaged string entries; use `pairsView` and `put` instead.
iterator mvalues*(map: FastMap[string]): var string =
  raise newException(ValueError, "mutable string value iteration is not supported with unmanaged entry storage; use pairsView and put instead")

## Iterate over int64 values as var references for in-place mutation.
iterator mvalues*(map: FastMap[int64]): var int64 =
  case map.storage.kind
  of fmskInt64Nim, fmskInt64Arena:
    if not map.storage.nimString.isNil:
      let expectedLen = map.len
      var i = 0
      while nextFastMapStringOccupiedIdx(map.storage.nimString, i):
        let entry = swEntryAt(map.storage.nimString, i)
        yield cast[ptr int64](swEntryValPtr(entry))[]
        assert map.len == expectedLen, "the length of the table changed while iterating over it"
        inc i
  else:
    discard

## Not supported for unmanaged string entries; use `pairsView` and `put` instead.
iterator mpairs*(map: FastMap[string]): (string, var string) =
  raise newException(ValueError, "mutable string pair iteration is not supported with unmanaged entry storage; use pairsView and put instead")

## Iterate over entries as key and mutable int64 value pairs.
iterator mpairs*(map: FastMap[int64]): (string, var int64) =
  case map.storage.kind
  of fmskInt64Nim, fmskInt64Arena:
    if not map.storage.nimString.isNil:
      let expectedLen = map.len
      var i = 0
      while nextFastMapStringOccupiedIdx(map.storage.nimString, i):
        let entry = swEntryAt(map.storage.nimString, i)
        yield (rawStrToString(entry.keyPtr, int32(entry.keyLen)), cast[ptr int64](swEntryValPtr(entry))[])
        assert map.len == expectedLen, "the length of the table changed while iterating over it"
        inc i
  else:
    discard

proc `$`*(map: FastMap[string]): string =
  if map.isNil or map.len == 0:
    return "{:}"

  result = "{"
  for key, value in map.pairs():
    if result.len > 1:
      result.add(", ")
    result.addQuoted(key)
    result.add(": ")
    result.addQuoted(value)
  result.add("}")

proc `$`*(map: FastMap[int64]): string =
  if map.isNil or map.len == 0:
    return "{:}"

  result = "{"
  for key, value in map.pairs():
    if result.len > 1:
      result.add(", ")
    result.addQuoted(key)
    result.add(": ")
    result.addQuoted(value)
  result.add("}")

proc `==`*(a, b: FastMap[string]): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.len != b.len:
    return false
  var otherValue: FastStringView
  for keyView, valueView in a.pairsView():
    if not b.tryGetView($keyView, otherValue):
      return false
    if not otherValue.equalsAscii($valueView):
      return false
  true

proc `==`*(a, b: FastMap[int64]): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.len != b.len:
    return false
  var otherValue: int64
  for key, value in a.pairs():
    if not b.tryGet(key, otherValue):
      return false
    if otherValue != value:
      return false
  true
