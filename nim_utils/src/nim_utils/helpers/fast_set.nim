## Fast set helpers for nim_express.
## Pure-Nim Swiss-table string-key sets with portable SWAR group probes.

import std/os
import std/bitops
import ./swar_group
from ./fast_map import hashBytes, syncFastMapCSeed

# Install the shared per-process seed for this module's hash helpers.
syncFastMapCSeed()

type
  FastSetStorageKind = enum
    fsskNim
    fsskArena

const
  DefaultFastSetArenaChunkSize = 4096
  UseNimStringFastSetBackend = not defined(nxFastSetLegacyStringBackend)
  FastSetCtrlEmpty = 0xFF'u8
  FastSetCtrlDeleted = 0x80'u8
  FastSetMaxInlineStringLen = int(high(uint16))
  FastSetSwGroupSize = 16
  FastSetArenaDefaultChunkSize = 256 * 1024
  FastSetArenaMinChunkSize = 64

type
  FastStringView* = object
    data*: pointer
    len*: int

  FastSetStringNimEntry = object
    keyPtr: pointer
    keyLen: uint16

  FastSetBumpArena = object
    chunks: seq[pointer]
    current: pointer
    remaining: int
    chunkSize: int
    usedBytes: int
    ramp: int
    firstChunkSize: int

  FastSetStringNimStorage = ref object
    count: int
    used: int
    capacity: int
    growAt: int
    rebuildAt: int
    ctrl: pointer
    entries: pointer
    arena: FastSetBumpArena
    liveBytes: int

  FastSetStorageObj = object
    raw: pointer
    kind: FastSetStorageKind
    nimString: FastSetStringNimStorage

  FastSet* = ref object
    storage: FastSetStorageObj

  FastHashSet* = FastSet


proc c_strlen(value: cstring): csize_t {.importc: "strlen", header: "<string.h>".}
proc c_malloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc c_memset(p: pointer, val: cint, size: csize_t): pointer {.importc: "memset", header: "<string.h>", discardable.}
proc c_calloc(count: csize_t, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}

proc stringPtr(value: string): pointer {.inline.} =
  if value.len == 0: nil else: cast[pointer](unsafeAddr value[0])

proc cstringPtr(value: cstring): pointer {.inline.} =
  cast[pointer](value)

proc cstringLen(value: cstring): csize_t {.inline.} =
  if value == nil: 0 else: c_strlen(value)

proc initFastStringView(data: cstring, len: csize_t): FastStringView {.inline.} =
  result.data = cast[pointer](data)
  result.len = int(len)

## Builds a `FastStringView` over the Nim string `value` without copying.
proc toFastStringView*(value: string): FastStringView {.inline.} =
  result.data = value.stringPtr
  result.len = value.len

## Builds a `FastStringView` over the C string `value` without copying.
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

const
  FastSetMaxEntryCapacity = high(int) div sizeof(FastSetStringNimEntry)
  FastSetMaxThresholdCapacity = high(int) div 8
  FastSetMaxCtrlCapacity = high(int) - FastSetSwGroupSize
  FastSetMaxCapacity = min(FastSetMaxEntryCapacity,
    min(FastSetMaxThresholdCapacity, FastSetMaxCtrlCapacity))

proc raiseFastSetCapacityOverflow() {.noinline.} =
  raise newException(OverflowDefect, "FastSet capacity exceeds supported maximum")

proc raiseFastSetOutOfMem() {.noinline.} =
  raise newException(OutOfMemDefect, "FastSet allocation failed")

proc nextFastSetPow2(n: int): int {.inline.} =
  if n < 0 or n > FastSetMaxCapacity:
    raiseFastSetCapacityOverflow()
  result = FastSetSwGroupSize
  while result < n:
    if result > (FastSetMaxCapacity shr 1):
      raiseFastSetCapacityOverflow()
    result = result shl 1

proc desiredFastSetStringNimCap(count: int): int {.inline.} =
  if count < 0:
    raiseFastSetCapacityOverflow()
  let extra = count div 3
  if count > high(int) - extra - 1:
    raiseFastSetCapacityOverflow()
  let minSlots = max(FastSetSwGroupSize, count + extra + 1)
  nextFastSetPow2(minSlots)

proc hashFastSetString(key: string): uint64 {.inline.} =
  hashBytes(key.stringPtr, key.len)

proc hashFastSetRaw(kPtr: pointer, kLen: int): uint64 {.inline.} =
  hashBytes(kPtr, kLen)

when defined(nimUtilsHashSeedTest):
  ## Exposes the internal FastSet string hash for test verification.
  proc fastSetHashForTest*(key: string): uint64 {.inline.} =
    hashFastSetString(key)

proc arenaGrow(arena: var FastSetBumpArena, minSize: int) {.inline.} =
  if minSize < 0 or arena.chunkSize < 0:
    raiseFastSetCapacityOverflow()
  # Geometric ramp: start small so thousands of small sets do not each pin a
  # full chunk, then double until the configured chunk size cap is reached.
  var sz = arena.chunkSize
  if arena.ramp > 0 and arena.ramp < sz:
    sz = arena.ramp
  elif arena.ramp == 0 and sz > FastSetArenaMinChunkSize:
    sz = FastSetArenaMinChunkSize
  if sz < minSize:
    sz = minSize
  let chunk = c_malloc(csize_t(sz))
  if chunk == nil:
    raiseFastSetOutOfMem()
  if arena.chunks.len == 0:
    arena.firstChunkSize = sz
  arena.chunks.add(chunk)
  arena.current = chunk
  arena.remaining = sz
  arena.ramp = sz shl 1

proc arenaAlloc(arena: var FastSetBumpArena, size: int): pointer {.inline.} =
  if size < 0:
    raiseFastSetCapacityOverflow()
  if size > arena.remaining:
    arenaGrow(arena, size)
  result = arena.current
  arena.current = cast[pointer](cast[uint](arena.current) + uint(size))
  arena.remaining -= size
  arena.usedBytes += size

proc arenaFreeAll(arena: var FastSetBumpArena) =
  for chunk in arena.chunks:
    c_free(chunk)
  arena.chunks.setLen(0)
  arena.current = nil
  arena.remaining = 0
  arena.usedBytes = 0
  arena.ramp = 0
  arena.firstChunkSize = 0

proc arenaReset(arena: var FastSetBumpArena) =
  if arena.chunks.len == 0:
    return
  for i in 1..<arena.chunks.len:
    c_free(arena.chunks[i])
  let firstChunk = arena.chunks[0]
  arena.chunks.setLen(1)
  arena.current = firstChunk
  arena.remaining = arena.firstChunkSize
  arena.usedBytes = 0
  arena.ramp = arena.firstChunkSize shl 1

proc arenaStrDup(arena: var FastSetBumpArena, src: pointer, len: int): pointer {.inline.} =
  if len <= 0:
    return nil
  let buf = arenaAlloc(arena, len + 1)
  if src != nil:
    copyMem(buf, src, len)
  cast[ptr UncheckedArray[char]](buf)[len] = '\0'
  buf

proc entryStorageBytes(keyLen: int): int {.inline.} =
  if keyLen < 0 or keyLen > high(int) - 1:
    raiseFastSetCapacityOverflow()
  keyLen + 1

proc rawStrToView(p: pointer, len: int32): FastStringView {.inline.} =
  result.data = p
  result.len = int(len)

proc swH2(hash: uint64): uint8 {.inline.} =
  uint8(hash and 0x7F'u64)

proc swH1(hash: uint64, mask: int): int {.inline.} =
  int((hash shr 7) and uint64(mask))

proc swCtrlPtr(storage: FastSetStringNimStorage, idx: int): ptr uint8 {.inline.} =
  cast[ptr uint8](cast[uint](storage.ctrl) + uint(idx))

proc swCtrlAt(storage: FastSetStringNimStorage, idx: int): uint8 {.inline.} =
  cast[ptr UncheckedArray[uint8]](storage.ctrl)[idx]

proc swSetCtrl(storage: FastSetStringNimStorage, idx: int, val: uint8) {.inline.} =
  cast[ptr UncheckedArray[uint8]](storage.ctrl)[idx] = val
  if idx < FastSetSwGroupSize:
    cast[ptr UncheckedArray[uint8]](storage.ctrl)[storage.capacity + idx] = val

proc swEntryAt(storage: FastSetStringNimStorage, idx: int): ptr FastSetStringNimEntry {.inline.} =
  cast[ptr FastSetStringNimEntry](cast[uint](storage.entries) + uint(idx * sizeof(FastSetStringNimEntry)))

proc swAllocTables(storage: FastSetStringNimStorage, cap: int) =
  if cap <= 0 or cap > FastSetMaxCapacity:
    raiseFastSetCapacityOverflow()
  let ctrlSize = cap + FastSetSwGroupSize
  let ctrl = c_malloc(csize_t(ctrlSize))
  if ctrl == nil:
    raiseFastSetOutOfMem()
  let entries = c_calloc(csize_t(cap), csize_t(sizeof(FastSetStringNimEntry)))
  if entries == nil:
    c_free(ctrl)
    raiseFastSetOutOfMem()
  storage.ctrl = ctrl
  c_memset(storage.ctrl, 0xFF.cint, csize_t(ctrlSize))
  storage.entries = entries
  storage.capacity = cap

proc swFreeTables(storage: FastSetStringNimStorage) =
  if storage.ctrl != nil:
    c_free(storage.ctrl)
    storage.ctrl = nil
  if storage.entries != nil:
    c_free(storage.entries)
    storage.entries = nil
  storage.capacity = 0

proc initFastSetStringNimStorage(): FastSetStringNimStorage =
  new(result)
  result.arena.chunkSize = FastSetArenaDefaultChunkSize

proc updateFastSetStringThresholds(storage: FastSetStringNimStorage) {.inline.} =
  if storage == nil or storage.capacity == 0:
    if storage != nil:
      storage.growAt = 0
      storage.rebuildAt = 0
    return
  if storage.capacity > FastSetMaxCapacity:
    raiseFastSetCapacityOverflow()
  storage.growAt = max(1, (storage.capacity * 3) div 4)
  storage.rebuildAt = max(1, (storage.capacity * 7) div 8)

proc compactFastSetStringArena(storage: FastSetStringNimStorage) =
  if storage == nil or storage.count == 0:
    if storage != nil:
      arenaReset(storage.arena)
      storage.liveBytes = 0
    return

  var nextArena: FastSetBumpArena
  nextArena.chunkSize = storage.arena.chunkSize
  var nextLive = 0
  try:
    let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
    let entries = cast[ptr UncheckedArray[FastSetStringNimEntry]](storage.entries)
    for i in 0..<storage.capacity:
      if ctrl[i] <= 0x7F'u8:
        let entry = addr entries[i]
        let keyLen = int(entry.keyLen)
        entry.keyPtr = arenaStrDup(nextArena, entry.keyPtr, keyLen)
        nextLive += entryStorageBytes(keyLen)
  except:
    arenaFreeAll(nextArena)
    raise

  arenaFreeAll(storage.arena)
  storage.arena = nextArena
  storage.liveBytes = nextLive

proc shouldCompactFastSetStringArena(storage: FastSetStringNimStorage): bool {.inline.} =
  if storage == nil or storage.arena.usedBytes <= storage.arena.chunkSize * 2:
    return false
  storage.liveBytes <= storage.arena.usedBytes div 4

proc maybeCompactFastSetStringArena(storage: FastSetStringNimStorage) {.inline.} =
  if shouldCompactFastSetStringArena(storage):
    compactFastSetStringArena(storage)

proc setEntryKey(entry: var FastSetStringNimEntry, key: string, arena: var FastSetBumpArena) {.inline.} =
  if key.len > FastSetMaxInlineStringLen:
    raise newException(ValueError, "FastSet key exceeds maximum length of 65535")
  entry.keyLen = uint16(key.len)
  entry.keyPtr = arenaStrDup(arena, key.stringPtr, key.len)

proc setEntryKeyRaw(entry: var FastSetStringNimEntry, keyPtr: pointer, keyLen: int, arena: var FastSetBumpArena) {.inline.} =
  if keyLen > FastSetMaxInlineStringLen:
    raise newException(ValueError, "FastSet key exceeds maximum length of 65535")
  entry.keyLen = uint16(keyLen)
  entry.keyPtr = arenaStrDup(arena, keyPtr, keyLen)

proc zeroEntry(entry: var FastSetStringNimEntry) {.inline.} =
  entry.keyPtr = nil
  entry.keyLen = 0'u16

proc moveEntry(dst: var FastSetStringNimEntry, src: var FastSetStringNimEntry) {.inline.} =
  dst.keyPtr = src.keyPtr
  dst.keyLen = src.keyLen
  src.keyPtr = nil
  src.keyLen = 0'u16

proc findFastSetStringFoundIdx(storage: FastSetStringNimStorage, key: string, hash: uint64): int {.inline.} =
  if storage == nil or storage.capacity == 0:
    return -1
  let mask = storage.capacity - 1
  let kLen = key.len
  if kLen > FastSetMaxInlineStringLen:
    return -1
  let kPtr = if kLen == 0: nil else: cast[pointer](unsafeAddr key[0])
  let h2 = swH2(hash)
  var offset = swH1(hash, mask)
  var stride = 0
  while true:
    let ctrlBase = swCtrlPtr(storage, offset)
    var matchMask = swarMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = int(swarFirstSlot(matchMask))
      let idx = (offset + slotOff) and mask
      let entry = swEntryAt(storage, idx)
      if entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return idx
      matchMask = swarClearLowest(matchMask)
    if swarMatchEmpty16(ctrlBase) != 0:
      return -1
    stride += FastSetSwGroupSize
    offset = (offset + stride) and mask

proc findFastSetRawFoundIdx(storage: FastSetStringNimStorage, kPtr: pointer, kLen: int, hash: uint64): int {.inline.} =
  if storage == nil or storage.capacity == 0:
    return -1
  if kLen > FastSetMaxInlineStringLen:
    return -1
  let mask = storage.capacity - 1
  let h2 = swH2(hash)
  var offset = swH1(hash, mask)
  var stride = 0
  while true:
    let ctrlBase = swCtrlPtr(storage, offset)
    var matchMask = swarMatch16(ctrlBase, h2)
    while matchMask != 0:
      let slotOff = int(swarFirstSlot(matchMask))
      let idx = (offset + slotOff) and mask
      let entry = swEntryAt(storage, idx)
      if entry.keyLen == uint16(kLen) and
          (kLen == 0 or equalMem(entry.keyPtr, kPtr, kLen)):
        return idx
      matchMask = swarClearLowest(matchMask)
    if swarMatchEmpty16(ctrlBase) != 0:
      return -1
    stride += FastSetSwGroupSize
    offset = (offset + stride) and mask

proc rehashFastSetStringNim(storage: FastSetStringNimStorage, newCap: int)
proc ensureFastSetStringCapacity(storage: FastSetStringNimStorage, targetCount: int)
proc clearFastSetString(storage: FastSetStringNimStorage)

proc findOrInsertFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int, hash: uint64, foundExisting: var bool): int =
  if storage == nil:
    foundExisting = false
    return -1

  while true:
    if storage.capacity == 0:
      ensureFastSetStringCapacity(storage, storage.count + 1)

    # Fused scan: a single group walk records the first empty-or-deleted slot
    # while verifying h2 matches, replacing the separate find + insert-slot
    # probes. Keys are impossible past the first empty slot, so stopping there
    # yields exactly the slot a standalone insert scan would pick.
    let mask = storage.capacity - 1
    let h2 = swH2(hash)
    var offset = swH1(hash, mask)
    var stride = 0
    var insertIdx = -1
    let scanMatches = keyLen <= FastSetMaxInlineStringLen
    while true:
      let ctrlBase = swCtrlPtr(storage, offset)
      if scanMatches:
        var matchMask = swarMatch16(ctrlBase, h2)
        while matchMask != 0:
          let slotOff = int(swarFirstSlot(matchMask))
          let idx = (offset + slotOff) and mask
          let entry = swEntryAt(storage, idx)
          if entry.keyLen == uint16(keyLen) and
              (keyLen == 0 or equalMem(entry.keyPtr, keyPtr, keyLen)):
            foundExisting = true
            return idx
          matchMask = swarClearLowest(matchMask)
      let freeMask = swarMatchEmptyOrDel16(ctrlBase)
      if freeMask != 0 and insertIdx < 0:
        insertIdx = (offset + int(swarFirstSlot(freeMask))) and mask
      if swarMatchEmpty16(ctrlBase) != 0:
        break
      stride += FastSetSwGroupSize
      offset = (offset + stride) and mask

    if storage.count + 1 > storage.growAt or storage.used > storage.rebuildAt:
      ensureFastSetStringCapacity(storage, storage.count + 1)
      continue

    foundExisting = false
    return insertIdx

proc findOrInsertFastSetString(storage: FastSetStringNimStorage, key: string, hash: uint64, foundExisting: var bool): int {.inline.} =
  if storage == nil:
    foundExisting = false
    return -1
  let kPtr = if key.len == 0: nil else: cast[pointer](unsafeAddr key[0])
  findOrInsertFastSetRaw(storage, kPtr, key.len, hash, foundExisting)

proc ensureFastSetStringCapacity(storage: FastSetStringNimStorage, targetCount: int) =
  if storage.capacity == 0 or targetCount > storage.growAt:
    rehashFastSetStringNim(storage, targetCount)
  elif storage.used > storage.rebuildAt:
    rehashFastSetStringNim(storage, storage.count)

proc rehashFastSetStringNim(storage: FastSetStringNimStorage, newCap: int) =
  let targetCap = desiredFastSetStringNimCap(max(1, newCap))
  let oldCtrl = storage.ctrl
  let oldEntries = storage.entries
  let oldCap = storage.capacity

  swAllocTables(storage, targetCap)
  storage.count = 0
  storage.used = 0
  updateFastSetStringThresholds(storage)

  if oldCap == 0 or oldCtrl == nil:
    return

  let oldCtrlArr = cast[ptr UncheckedArray[uint8]](oldCtrl)
  let oldEntryArr = cast[ptr UncheckedArray[FastSetStringNimEntry]](oldEntries)
  let mask = storage.capacity - 1

  for i in 0..<oldCap:
    if (oldCtrlArr[i] and 0x80'u8) == 0:
      let e = addr oldEntryArr[i]
      let hash = hashFastSetRaw(e.keyPtr, int(e.keyLen))
      let h2 = swH2(hash)
      var offset = swH1(hash, mask)
      var stride = 0
      while true:
        let ctrlBase = swCtrlPtr(storage, offset)
        let emptyMask = swarMatchEmpty16(ctrlBase)
        if emptyMask != 0:
          let slotOff = int(swarFirstSlot(emptyMask))
          let idx = (offset + slotOff) and mask
          moveEntry(swEntryAt(storage, idx)[], oldEntryArr[i])
          swSetCtrl(storage, idx, h2)
          inc storage.count
          inc storage.used
          break
        stride += FastSetSwGroupSize
        offset = (offset + stride) and mask

  c_free(oldCtrl)
  c_free(oldEntries)

proc reserveFastSetString(storage: FastSetStringNimStorage, n: int): bool =
  if storage == nil or n < 0:
    return false
  if n == 0:
    return true
  if storage.capacity < desiredFastSetStringNimCap(n):
    rehashFastSetStringNim(storage, n)
  true

proc lenFastSetString(storage: FastSetStringNimStorage): int {.inline.} =
  if storage == nil: 0 else: storage.count

proc inclFastSetString(storage: FastSetStringNimStorage, key: string): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastSetString(key)
  var foundExisting = false
  let idx = findOrInsertFastSetString(storage, key, hash, foundExisting)
  if idx < 0:
    return false
  if foundExisting:
    return true
  let wasDeleted = swCtrlAt(storage, idx) == FastSetCtrlDeleted
  setEntryKey(swEntryAt(storage, idx)[], key, storage.arena)
  storage.liveBytes += entryStorageBytes(key.len)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  true

proc inclFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastSetRaw(keyPtr, keyLen)
  var foundExisting = false
  let idx = findOrInsertFastSetRaw(storage, keyPtr, keyLen, hash, foundExisting)
  if idx < 0:
    return false
  if foundExisting:
    return true
  let wasDeleted = swCtrlAt(storage, idx) == FastSetCtrlDeleted
  setEntryKeyRaw(swEntryAt(storage, idx)[], keyPtr, keyLen, storage.arena)
  storage.liveBytes += entryStorageBytes(keyLen)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  true

proc containsFastSetString(storage: FastSetStringNimStorage, key: string): bool {.inline.} =
  if storage == nil or storage.capacity == 0:
    return false
  findFastSetStringFoundIdx(storage, key, hashFastSetString(key)) >= 0

proc containsFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int): bool {.inline.} =
  if storage == nil or storage.capacity == 0:
    return false
  findFastSetRawFoundIdx(storage, keyPtr, keyLen, hashFastSetRaw(keyPtr, keyLen)) >= 0

proc containsOrInclFastSetString(storage: FastSetStringNimStorage, key: string): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastSetString(key)
  var foundExisting = false
  let idx = findOrInsertFastSetString(storage, key, hash, foundExisting)
  if idx < 0:
    return false
  if foundExisting:
    return true
  let wasDeleted = swCtrlAt(storage, idx) == FastSetCtrlDeleted
  setEntryKey(swEntryAt(storage, idx)[], key, storage.arena)
  storage.liveBytes += entryStorageBytes(key.len)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  false

proc containsOrInclFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int): bool {.inline.} =
  if storage == nil:
    return false
  let hash = hashFastSetRaw(keyPtr, keyLen)
  var foundExisting = false
  let idx = findOrInsertFastSetRaw(storage, keyPtr, keyLen, hash, foundExisting)
  if idx < 0:
    return false
  if foundExisting:
    return true
  let wasDeleted = swCtrlAt(storage, idx) == FastSetCtrlDeleted
  setEntryKeyRaw(swEntryAt(storage, idx)[], keyPtr, keyLen, storage.arena)
  storage.liveBytes += entryStorageBytes(keyLen)
  swSetCtrl(storage, idx, swH2(hash))
  inc storage.count
  if not wasDeleted:
    inc storage.used
  false

proc exclFastSetString(storage: FastSetStringNimStorage, key: string): bool =
  if storage == nil or storage.capacity == 0:
    return false
  let idx = findFastSetStringFoundIdx(storage, key, hashFastSetString(key))
  if idx < 0:
    return false
  dec storage.count
  storage.liveBytes -= entryStorageBytes(int(swEntryAt(storage, idx).keyLen))
  zeroEntry(swEntryAt(storage, idx)[])
  swSetCtrl(storage, idx, FastSetCtrlDeleted)
  if storage.count == 0:
    clearFastSetString(storage)
  else:
    maybeCompactFastSetStringArena(storage)
  true

proc exclFastSetRaw(storage: FastSetStringNimStorage, keyPtr: pointer, keyLen: int): bool =
  if storage == nil or storage.capacity == 0:
    return false
  let idx = findFastSetRawFoundIdx(storage, keyPtr, keyLen, hashFastSetRaw(keyPtr, keyLen))
  if idx < 0:
    return false
  dec storage.count
  storage.liveBytes -= entryStorageBytes(int(swEntryAt(storage, idx).keyLen))
  zeroEntry(swEntryAt(storage, idx)[])
  swSetCtrl(storage, idx, FastSetCtrlDeleted)
  if storage.count == 0:
    clearFastSetString(storage)
  else:
    maybeCompactFastSetStringArena(storage)
  true

proc clearFastSetString(storage: FastSetStringNimStorage) =
  if storage == nil:
    return
  if storage.capacity > 0 and storage.ctrl != nil:
    c_memset(storage.ctrl, FastSetCtrlEmpty.cint, csize_t(storage.capacity + FastSetSwGroupSize))
    zeroMem(storage.entries, storage.capacity * sizeof(FastSetStringNimEntry))
  storage.count = 0
  storage.used = 0
  storage.liveBytes = 0
  arenaReset(storage.arena)

proc nextFastSetStringOccupiedIdx(storage: FastSetStringNimStorage, idx: var int): bool {.inline.} =
  if storage == nil or storage.capacity == 0:
    return false
  let ctrl = cast[ptr UncheckedArray[uint8]](storage.ctrl)
  let cap = storage.capacity
  const allMsb = 0x8080808080808080'u64
  while idx + 8 <= cap:
    var word: uint64
    copyMem(addr word, addr ctrl[idx], 8)
    let occupied = (not word) and allMsb
    if occupied != 0:
      idx = idx + (countTrailingZeroBits(occupied) shr 3)
      return true
    idx += 8
  while idx < cap:
    if (ctrl[idx] and 0x80'u8) == 0:
      return true
    inc idx
  false

proc releaseFastSetStorage(storage: var FastSetStorageObj) =
  if storage.raw == nil and storage.nimString.isNil:
    return
  case storage.kind
  of fsskNim, fsskArena:
    if not storage.nimString.isNil:
      swFreeTables(storage.nimString)
      arenaFreeAll(storage.nimString.arena)
    storage.nimString = nil
  storage.raw = nil

proc `=destroy`(storage: var FastSetStorageObj) =
  releaseFastSetStorage(storage)

## Creates an empty `FastSet` with the default storage backend.
proc newFastSet*(): FastSet =
  new(result)
  result.storage.kind = fsskNim
  result.storage.nimString = initFastSetStringNimStorage()
## Creates an empty `FastSet` pre-sized for roughly `initialSize` keys.
proc newFastSet*(initialSize: Natural): FastSet =
  result = newFastSet()
  if result == nil:
    return
  case result.storage.kind
  of fsskNim:
    discard reserveFastSetString(result.storage.nimString, int(initialSize))
  of fsskArena:
    discard

## Creates a `FastSet` pre-filled with the keys in `keys`.
proc newFastSet*(keys: openArray[string]): FastSet =
  result = newFastSet()
  if result == nil:
    return
  case result.storage.kind
  of fsskNim:
    discard reserveFastSetString(result.storage.nimString, keys.len)
    for key in keys:
      discard inclFastSetString(result.storage.nimString, key)
  of fsskArena:
    discard

## Creates an empty `FastHashSet` with the default storage backend.
proc newFastHashSet*(): FastHashSet {.inline.} = newFastSet()
## Creates an empty `FastHashSet` pre-sized for roughly `initialSize` keys.
proc newFastHashSet*(initialSize: Natural): FastHashSet {.inline.} = newFastSet(initialSize)
## Creates a `FastHashSet` pre-filled with the keys in `keys`.
proc newFastHashSet*(keys: openArray[string]): FastHashSet {.inline.} = newFastSet(keys)

## Creates an arena-backed `FastSet` with `arenaChunkSize` chunk size.
proc newFastArenaSet*(arenaChunkSize = DefaultFastSetArenaChunkSize): FastSet =
  new(result)
  result.storage.kind = fsskArena
  result.storage.nimString = initFastSetStringNimStorage()
  result.storage.nimString.arena.chunkSize = max(64, arenaChunkSize)

## Creates an arena-backed `FastSet` pre-filled with the keys in `keys`.
proc newFastArenaSet*(keys: openArray[string], arenaChunkSize = DefaultFastSetArenaChunkSize): FastSet =
  result = newFastArenaSet(arenaChunkSize)
  if result != nil and result.storage.nimString != nil:
    discard reserveFastSetString(result.storage.nimString, keys.len)
    for key in keys:
      discard inclFastSetString(result.storage.nimString, key)

## Creates an arena-backed `FastHashSet` with `arenaChunkSize` chunk size.
proc newFastArenaHashSet*(arenaChunkSize = DefaultFastSetArenaChunkSize): FastHashSet {.inline.} =
  newFastArenaSet(arenaChunkSize)

## Creates an arena-backed `FastHashSet` pre-filled with the keys in `keys`.
proc newFastArenaHashSet*(keys: openArray[string], arenaChunkSize = DefaultFastSetArenaChunkSize): FastHashSet {.inline.} =
  newFastArenaSet(keys, arenaChunkSize)

## Releases all storage owned by `setObj`.
proc close*(setObj: FastSet) {.inline.} =
  if setObj == nil:
    return
  releaseFastSetStorage(setObj.storage)

## Returns the number of keys stored in `setObj`.
proc len*(setObj: FastSet): int {.inline.} =
  if setObj == nil:
    return 0
  case setObj.storage.kind
  of fsskNim, fsskArena:
    lenFastSetString(setObj.storage.nimString)
## Grows `setObj` to fit at least `n` keys so inserts avoid rehashing.
proc reserve*(setObj: FastSet, n: int): bool {.inline.} =
  if setObj == nil or n < 0:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    reserveFastSetString(setObj.storage.nimString, n)
## Inserts `key` into `setObj` and returns true when the insert succeeded,
## whether or not the key was already present.
proc incl*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    inclFastSetString(setObj.storage.nimString, key)
## Inserts the C string `key` into `setObj` and returns true when the insert
## succeeded, whether or not the key was already present.
proc inclC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    inclFastSetRaw(setObj.storage.nimString, key.cstringPtr, int(key.cstringLen))
## Inserts the `FastStringView` `key` into `setObj` and returns true when the
## insert succeeded, whether or not the key was already present.
proc inclView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return false
  if not key.isValidFastStringView:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    inclFastSetRaw(setObj.storage.nimString, key.toFastStringViewPtr, key.len)
## Returns true when `setObj` already holds `key`.
proc contains*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    containsFastSetString(setObj.storage.nimString, key)
## Returns true when `setObj` holds the C string `key`.
proc containsC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    containsFastSetRaw(setObj.storage.nimString, key.cstringPtr, int(key.cstringLen))
## Returns true when `setObj` holds the `FastStringView` `key`.
proc containsView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return false
  if not key.isValidFastStringView:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    containsFastSetRaw(setObj.storage.nimString, key.toFastStringViewPtr, key.len)
## Removes `key` from `setObj` and returns true when it was present.
proc excl*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    exclFastSetString(setObj.storage.nimString, key)
## Removes the C string `key` from `setObj` and returns true when it was present.
proc exclC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    exclFastSetRaw(setObj.storage.nimString, key.cstringPtr, int(key.cstringLen))
## Removes the `FastStringView` `key` from `setObj` and returns true when it was present.
proc exclView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return false
  if not key.isValidFastStringView:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    exclFastSetRaw(setObj.storage.nimString, key.toFastStringViewPtr, key.len)
## Removes all keys from `setObj`.
proc clear*(setObj: FastSet) {.inline.} =
  if setObj == nil:
    return
  case setObj.storage.kind
  of fsskNim, fsskArena:
    clearFastSetString(setObj.storage.nimString)
## Reversed-argument form of `contains` for fluent call syntax.
proc contains*(key: string, setObj: FastSet): bool {.inline.} =
  setObj.contains(key)

## Returns true when `key` is already in `setObj`, inserting it otherwise.
proc containsOrIncl*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    containsOrInclFastSetString(setObj.storage.nimString, key)
## Returns true when the C string `key` is in `setObj`, inserting it otherwise.
proc containsOrInclC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    containsOrInclFastSetRaw(setObj.storage.nimString, key.cstringPtr, int(key.cstringLen))
## Returns true when the `FastStringView` `key` is in `setObj`, inserting it otherwise.
proc containsOrInclView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return false
  if not key.isValidFastStringView:
    return false
  case setObj.storage.kind
  of fsskNim, fsskArena:
    containsOrInclFastSetRaw(setObj.storage.nimString, key.toFastStringViewPtr, key.len)
## Removes `key` from `setObj` and returns true when it was missing.
proc missingOrExcl*(setObj: FastSet, key: string): bool {.inline.} =
  if setObj == nil:
    return true
  not setObj.excl(key)

## Removes the C string `key` from `setObj` and returns true when it was missing.
proc missingOrExclC*(setObj: FastSet, key: cstring): bool {.inline.} =
  if setObj == nil:
    return true
  not setObj.exclC(key)

## Removes the `FastStringView` `key` from `setObj` and returns true when it was missing.
proc missingOrExclView*(setObj: FastSet, key: FastStringView): bool {.inline.} =
  if setObj == nil:
    return true
  not setObj.exclView(key)

## Iterates the keys of `setObj` as borrowed `FastStringView` values without copying.
iterator itemsView*(setObj: FastSet): FastStringView =
  if setObj != nil:
    case setObj.storage.kind
    of fsskNim, fsskArena:
      var idx = 0
      while nextFastSetStringOccupiedIdx(setObj.storage.nimString, idx):
        let entry = swEntryAt(setObj.storage.nimString, idx)
        yield rawStrToView(entry.keyPtr, int32(entry.keyLen))
        inc idx
## Collects all keys of `setObj` into a newly allocated sequence of strings.
proc itemsSeq*(setObj: FastSet): seq[string] =
  result = newSeqOfCap[string](setObj.len)
  for itemView in setObj.itemsView():
    result.add($itemView)

## Iterates the keys of `setObj` as copied Nim strings.
iterator items*(setObj: FastSet): string =
  for itemView in setObj.itemsView():
    yield $itemView

proc `$`*(setObj: FastSet): string =
  if setObj.isNil or setObj.len == 0:
    return "{}"

  result = "{"
  for item in setObj.items():
    if result.len > 1:
      result.add(", ")
    result.addQuoted(item)
  result.add("}")

proc `==`*(a, b: FastSet): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.len != b.len:
    return false
  for itemView in a.itemsView():
    if not b.containsView(itemView):
      return false
  true
