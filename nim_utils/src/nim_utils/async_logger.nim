import std/[atomics, posix]
import ./nim_fastjson/direct_engine

when compileOption("threads"):
  import std/locks

{.compile: "logger_simd.c".}
proc log_json_escape(src: ptr byte, len: csize_t, dst: ptr byte): csize_t {.importc, cdecl.}
proc log_needs_escape(src: ptr byte, len: csize_t): cint {.importc, cdecl.}

var sigpipeState {.global.}: Atomic[int]

when compileOption("threads"):
  var defaultLoggerLock {.global.}: Lock
  var defaultLoggerLockState {.global.}: Atomic[int]

  proc ensureDefaultLoggerLock() =
    if defaultLoggerLockState.load(moAcquire) == 2:
      return
    var expected = 0
    if defaultLoggerLockState.compareExchange(expected, 1, moAcquireRelease, moAcquire):
      initLock(defaultLoggerLock)
      defaultLoggerLockState.store(2, moRelease)
    else:
      while defaultLoggerLockState.load(moAcquire) != 2:
        discard

proc ignoreSigpipe() =
  if sigpipeState.load(moAcquire) == 2:
    return
  var expected = 0
  if sigpipeState.compareExchange(expected, 1, moAcquireRelease, moAcquire):
    var sa: Sigaction
    sa.sa_handler = SIG_IGN
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = 0
    discard sigaction(SIGPIPE, sa, nil)
    sigpipeState.store(2, moRelease)
  else:
    while sigpipeState.load(moAcquire) != 2:
      discard

type
  LogLevel* = enum
    llTrace, llDebug, llInfo, llWarn, llError, llFatal

  LogOutput* = enum
    loStdout, loStderr, loFile

  LogFormat* = enum
    lfJson, lfText, lfCompact

  AsyncLoggerConfig* = object
    level*: LogLevel
    format*: LogFormat
    output*: LogOutput
    filePath*: string
    bufferSize*: int
    maxEntryBytes*: int
    flushIntervalMs*: int
    dropOnFull*: bool
    includeSource*: bool
    colorize*: bool

const
  DefaultBufSize = 8192
  DefaultMaxEntry = 4096
  DefaultFlushMs = 2
  MaxBufSize = 1 shl 20
  MaxEntryBytes = 1 shl 20
  MaxRingBytes = 64 * 1024 * 1024
  MaxFlushBufBytes = 16 * 1024 * 1024
  FieldSep = '\x1F'
  KvSep = '\x1E'
  RawJsonSep = '\x1D'

  LevelStrJson: array[LogLevel, string] = [
    "trace", "debug", "info", "warn", "error", "fatal"
  ]
  LevelStrText: array[LogLevel, string] = [
    "TRACE", "DEBUG", "INFO ", "WARN ", "ERROR", "FATAL"
  ]
  LevelStrCompact: array[LogLevel, string] = [
    "T", "D", "I", "W", "E", "F"
  ]

  AnsiColors: array[LogLevel, string] = [
    "\x1b[90m", "\x1b[36m", "\x1b[32m", "\x1b[33m", "\x1b[31m", "\x1b[35m"
  ]
  AnsiReset = "\x1b[0m"

  JsonPre = "{\"ts\":\""
  JsonMidLevel = "\",\"level\":\""
  JsonMidMsg = "\",\"msg\":\""

type
  RingSlot = object
    len: Atomic[int32]
    level: uint8
    tsec: int64
    tnsec: int64

  FlushBuf = object
    data: ptr UncheckedArray[byte]
    cap: int
    pos: int
    escapeBuf: ptr UncheckedArray[byte]
    escapeCap: int

  AsyncLoggerObj = object
    config: AsyncLoggerConfig
    slotData: ptr UncheckedArray[byte]
    slots: ptr UncheckedArray[RingSlot]
    mask: int
    maxEntry: int
    head: Atomic[int]
    tail: Atomic[int]
    flushedTail: Atomic[int]
    dropped: Atomic[int64]
    writeErrors: Atomic[int64]
    stopFlag: Atomic[bool]
    closed: Atomic[bool]
    level: Atomic[int]
    fd: cint
    cachedTsSec: int64
    cachedTsMs: int
    cachedTsFull: array[32, byte]
    cachedTsFullLen: int8
    cachedTsCompact: array[12, byte]
    cachedTsCompactLen: int8
    when compileOption("threads"):
      flushThread: Thread[ptr AsyncLoggerObj]
      flushLock: Lock
      flushCond: Cond
      producerLock: Lock

  AsyncLogger* = ptr AsyncLoggerObj

## Returns a default ``AsyncLoggerConfig`` with info level, JSON format, and stdout output.
proc defaultConfig*(): AsyncLoggerConfig =
  result.level = llInfo
  result.format = lfJson
  result.output = loStdout
  result.filePath = ""
  result.bufferSize = DefaultBufSize
  result.maxEntryBytes = DefaultMaxEntry
  result.flushIntervalMs = DefaultFlushMs
  result.dropOnFull = true
  result.includeSource = false
  result.colorize = false

proc nextPow2(n: int): int {.inline.} =
  result = 1
  while result < n and result > 0: result = result shl 1
  if result <= 0: result = 1 shl 30

proc prevPow2(n: int): int {.inline.} =
  if n <= 1:
    return 1
  result = 1
  while result <= n div 2:
    result = result shl 1

proc normalizeConfig(cfg: var AsyncLoggerConfig) =
  if cfg.bufferSize <= 0:
    cfg.bufferSize = DefaultBufSize
  elif cfg.bufferSize > MaxBufSize:
    cfg.bufferSize = MaxBufSize
  cfg.bufferSize = nextPow2(cfg.bufferSize)

  if cfg.maxEntryBytes < 16:
    cfg.maxEntryBytes = DefaultMaxEntry
  elif cfg.maxEntryBytes > MaxEntryBytes:
    cfg.maxEntryBytes = MaxEntryBytes

  let maxSlotsForEntry = max(1, MaxRingBytes div cfg.maxEntryBytes)
  if cfg.bufferSize > maxSlotsForEntry:
    cfg.bufferSize = prevPow2(maxSlotsForEntry)
  if cfg.flushIntervalMs <= 0:
    cfg.flushIntervalMs = DefaultFlushMs

proc cappedFlushCap(maxEntry: int, bufSize: int): int {.inline.} =
  let boundedEntry = clamp(maxEntry, 16, MaxEntryBytes)
  let boundedSlots = clamp(bufSize, 1, 64)
  let desired =
    if boundedEntry > MaxFlushBufBytes div (12 * boundedSlots):
      MaxFlushBufBytes
    else:
      boundedEntry * 12 * boundedSlots
  max(4096, min(MaxFlushBufBytes, desired))

proc sleepNs(ns: int) {.inline.} =
  if ns <= 0: return
  var req: Timespec
  var rem: Timespec
  req.tv_sec = posix.Time(ns div 1_000_000_000)
  req.tv_nsec = ns mod 1_000_000_000
  discard nanosleep(req, rem)

proc writeAll(fd: cint, buf: pointer, count: int): bool {.inline.} =
  if fd < 0 or count <= 0: return count <= 0
  var written = 0
  while written < count:
    let n = write(fd, cast[pointer](cast[int](buf) + written), count - written)
    if n < 0:
      if errno == EINTR: continue
      return false
    if n == 0: return false
    written += n.int
  return true

proc writeDigits2(buf: ptr UncheckedArray[byte], pos: int, val: int) {.inline.} =
  buf[pos] = byte(ord('0') + val div 10)
  buf[pos + 1] = byte(ord('0') + val mod 10)

proc writeDigits3(buf: ptr UncheckedArray[byte], pos: int, val: int) {.inline.} =
  buf[pos] = byte(ord('0') + val div 100)
  buf[pos + 1] = byte(ord('0') + (val div 10) mod 10)
  buf[pos + 2] = byte(ord('0') + val mod 10)

proc writeDigits4(buf: ptr UncheckedArray[byte], pos: int, val: int) {.inline.} =
  buf[pos] = byte(ord('0') + val div 1000)
  buf[pos + 1] = byte(ord('0') + (val div 100) mod 10)
  buf[pos + 2] = byte(ord('0') + (val div 10) mod 10)
  buf[pos + 3] = byte(ord('0') + val mod 10)

proc floorDiv(a, b: int64): int64 {.inline.} =
  let d = a div b
  if (a xor b) < 0 and d * b != a: d - 1 else: d

proc floorMod(a, b: int64): int64 {.inline.} =
  let r = a mod b
  if r < 0: r + b else: r

proc formatTsFromEpoch(sec: int64, nsec: int64, full: ptr UncheckedArray[byte], fullLen: var int8,
                       compact: ptr UncheckedArray[byte], compactLen: var int8) =
  let ms = clamp((floorMod(nsec, 1_000_000_000) div 1_000_000).int, 0, 999)
  let daysSinceEpoch = floorDiv(sec, 86400)
  let secOfDay = floorMod(sec, 86400)
  let h = (secOfDay div 3600).int
  let m = ((secOfDay mod 3600) div 60).int
  let s = (secOfDay mod 60).int
  var z = daysSinceEpoch + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = (z - era * 146097).int
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let y = yoe.int + era.int * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let mo = (if mp < 10: mp + 3 else: mp - 9)
  let yr = clamp((if mo <= 2: y + 1 else: y), 0, 9999)
  writeDigits4(full, 0, yr); full[4] = byte('-')
  writeDigits2(full, 5, mo); full[7] = byte('-')
  writeDigits2(full, 8, d); full[10] = byte('T')
  writeDigits2(full, 11, h); full[13] = byte(':')
  writeDigits2(full, 14, m); full[16] = byte(':')
  writeDigits2(full, 17, s); full[19] = byte('.')
  writeDigits3(full, 20, ms); full[23] = byte('Z')
  fullLen = 24
  writeDigits2(compact, 0, h); compact[2] = byte(':')
  writeDigits2(compact, 3, m); compact[5] = byte(':')
  writeDigits2(compact, 6, s)
  compactLen = 8

proc refreshTs(logger: AsyncLogger, sec: int64, nsec: int64) {.inline.} =
  let ms = clamp((floorMod(nsec, 1_000_000_000) div 1_000_000).int, 0, 999)
  if sec == logger.cachedTsSec and ms == logger.cachedTsMs: return
  logger.cachedTsSec = sec
  logger.cachedTsMs = ms
  formatTsFromEpoch(sec, nsec,
    cast[ptr UncheckedArray[byte]](addr logger.cachedTsFull[0]), logger.cachedTsFullLen,
    cast[ptr UncheckedArray[byte]](addr logger.cachedTsCompact[0]), logger.cachedTsCompactLen)

proc initFlushBuf(maxEntry: int, bufSize: int): FlushBuf =
  let dataCap = cappedFlushCap(maxEntry, bufSize)
  result.cap = dataCap
  result.data = cast[ptr UncheckedArray[byte]](alloc(dataCap))
  result.pos = 0
  result.escapeCap = clamp(maxEntry, 16, MaxEntryBytes) * 6 + 16
  result.escapeBuf = cast[ptr UncheckedArray[byte]](alloc(result.escapeCap))

proc deinitFlushBuf(fb: var FlushBuf) =
  if fb.data != nil: dealloc(fb.data)
  if fb.escapeBuf != nil: dealloc(fb.escapeBuf)
  fb.data = nil
  fb.escapeBuf = nil

proc ensureCap(fb: var FlushBuf, needed: int) {.inline.} =
  if fb.pos + needed > fb.cap:
    let newCap = min(MaxFlushBufBytes, max(fb.cap * 2, fb.pos + needed))
    let newData = cast[ptr UncheckedArray[byte]](alloc(newCap))
    copyMem(addr newData[0], addr fb.data[0], fb.pos)
    dealloc(fb.data)
    fb.data = newData
    fb.cap = newCap

proc putBytes(fb: var FlushBuf, src: pointer, len: int) {.inline.} =
  if len <= 0: return
  ensureCap(fb, len)
  copyMem(addr fb.data[fb.pos], src, len)
  fb.pos += len

proc putStr(fb: var FlushBuf, s: string) {.inline.} =
  if s.len > 0:
    putBytes(fb, unsafeAddr s[0], s.len)

proc putByte(fb: var FlushBuf, b: byte) {.inline.} =
  ensureCap(fb, 1)
  fb.data[fb.pos] = b
  fb.pos += 1

proc putJsonEscaped(fb: var FlushBuf, src: ptr byte, srcLen: int) {.inline.} =
  if srcLen <= 0: return
  if log_needs_escape(src, csize_t(srcLen)) == 0:
    putBytes(fb, src, srcLen)
  else:
    let maxOut = srcLen * 6
    if maxOut > fb.escapeCap:
      dealloc(fb.escapeBuf)
      fb.escapeCap = maxOut + 16
      fb.escapeBuf = cast[ptr UncheckedArray[byte]](alloc(fb.escapeCap))
    let written = log_json_escape(src, csize_t(srcLen), cast[ptr byte](fb.escapeBuf)).int
    putBytes(fb, addr fb.escapeBuf[0], written)

proc putTextEscaped(fb: var FlushBuf, src: ptr UncheckedArray[byte], srcLen: int) {.inline.} =
  if srcLen <= 0:
    return
  var i = 0
  while i < srcLen:
    let b = src[i]
    case b
    of byte('\n'):
      putStr(fb, "\\n")
    of byte('\r'):
      putStr(fb, "\\r")
    of byte('\t'):
      putStr(fb, "\\t")
    else:
      if b < 0x20'u8 or b == 0x7f'u8:
        putByte(fb, byte('?'))
      else:
        putByte(fb, b)
    inc i

proc isReservedLogFieldKey(dataPtr: ptr UncheckedArray[byte], start, len: int): bool {.inline.} =
  if len == 2:
    return dataPtr[start] == byte('t') and dataPtr[start + 1] == byte('s')
  if len == 3:
    return dataPtr[start] == byte('m') and dataPtr[start + 1] == byte('s') and dataPtr[start + 2] == byte('g')
  if len == 5:
    return dataPtr[start] == byte('l') and dataPtr[start + 1] == byte('e') and
      dataPtr[start + 2] == byte('v') and dataPtr[start + 3] == byte('e') and
      dataPtr[start + 4] == byte('l')
  if len == 6:
    return dataPtr[start] == byte('f') and dataPtr[start + 1] == byte('i') and
      dataPtr[start + 2] == byte('e') and dataPtr[start + 3] == byte('l') and
      dataPtr[start + 4] == byte('d') and dataPtr[start + 5] == byte('s')
  false

proc rawJsonHasReservedTopLevelKey(dataPtr: ptr UncheckedArray[byte], start, len: int): bool =
  let stop = start + len
  var i = start
  var depth = 0
  var inString = false
  var escaped = false
  var expectKey = true
  while i < stop:
    let b = dataPtr[i]
    if inString:
      if escaped:
        escaped = false
      elif b == byte('\\'):
        escaped = true
      elif b == byte('"'):
        inString = false
      inc i
      continue

    case b
    of byte('"'):
      if depth == 0 and expectKey:
        let keyStart = i + 1
        var j = keyStart
        var keyEscaped = false
        while j < stop:
          let kb = dataPtr[j]
          if keyEscaped:
            keyEscaped = false
          elif kb == byte('\\'):
            keyEscaped = true
          elif kb == byte('"'):
            break
          inc j
        if j >= stop:
          return false
        var colon = j + 1
        while colon < stop and (dataPtr[colon] == byte(' ') or dataPtr[colon] == byte('\t') or dataPtr[colon] == byte('\r') or dataPtr[colon] == byte('\n')):
          inc colon
        if colon < stop and dataPtr[colon] == byte(':') and not keyEscaped and
           isReservedLogFieldKey(dataPtr, keyStart, j - keyStart):
          return true
        expectKey = false
        i = j + 1
        continue
      inString = true
    of byte('{'), byte('['):
      inc depth
    of byte('}'), byte(']'):
      if depth > 0:
        dec depth
    of byte(','):
      if depth == 0:
        expectKey = true
    else:
      discard
    inc i
  false

proc flushBuffered(logger: AsyncLogger, fb: var FlushBuf) {.inline.} =
  if fb.pos <= 0:
    return
  if not writeAll(logger.fd, addr fb.data[0], fb.pos):
    discard logger.writeErrors.fetchAdd(1, moRelaxed)
  fb.pos = 0

proc flushBeforeWorstCaseEntry(logger: AsyncLogger, fb: var FlushBuf) {.inline.} =
  let worstCaseEntry = clamp(logger.maxEntry * 6 + 2048, 4096, MaxFlushBufBytes)
  if fb.pos > 0 and fb.pos > MaxFlushBufBytes - worstCaseEntry:
    flushBuffered(logger, fb)

proc hasLogMarkerBytes(src: string, srcLen: int): bool {.inline.} =
  var i = 0
  while i < srcLen:
    let c = src[i]
    if c == FieldSep or c == KvSep or c == RawJsonSep:
      return true
    inc i
  false

proc copyLogBytes(dst: ptr UncheckedArray[byte], pos: var int, src: string, srcLen: int) {.inline.} =
  if srcLen <= 0:
    return
  if not src.hasLogMarkerBytes(srcLen):
    copyMem(addr dst[pos], unsafeAddr src[0], srcLen)
    pos += srcLen
    return
  var i = 0
  while i < srcLen:
    let c = src[i]
    dst[pos + i] =
      if c == FieldSep or c == KvSep or c == RawJsonSep: byte('?')
      else: byte(c)
    inc i
  pos += srcLen

proc drainRing(logger: AsyncLogger, fb: var FlushBuf)

## Forward declaration of the no-field ``log`` overload.
proc log*(logger: AsyncLogger, level: LogLevel, msg: string) {.inline.}
## Forward declaration of the field-carrying ``log`` overload.
proc log*(logger: AsyncLogger, level: LogLevel, msg: string,
          fields: openArray[(string, string)]) {.inline.}

## Enqueues ``msg`` at ``level`` into the ``AsyncLogger`` ring buffer.
proc log*(logger: AsyncLogger, level: LogLevel, msg: string) {.inline.} =
  if logger == nil or logger.closed.load(moAcquire): return
  if ord(level) < logger.level.load(moRelaxed): return
  var ts: Timespec
  discard clock_gettime(CLOCK_REALTIME, ts)
  when compileOption("threads"):
    acquire(logger.producerLock)
    defer: release(logger.producerLock)
    if logger.closed.load(moAcquire): return
  let head = logger.head.load(moRelaxed)
  let tail = logger.tail.load(moAcquire)
  if head - tail >= logger.config.bufferSize:
    if logger.config.dropOnFull:
      discard logger.dropped.fetchAdd(1, moRelaxed)
      return
    else:
      when compileOption("threads"):
        var spins = 0
        while logger.head.load(moRelaxed) - logger.tail.load(moAcquire) >= logger.config.bufferSize:
          if logger.closed.load(moAcquire): return
          # Bounded wait (<=100ms): a stalled flusher must not hang producers
          # forever; the record is dropped after the window.
          if spins >= 1000:
            discard logger.dropped.fetchAdd(1, moRelaxed)
            return
          inc spins
          sleepNs(100_000)
      else:
        var fb = initFlushBuf(logger.maxEntry, 64)
        drainRing(logger, fb)
        deinitFlushBuf(fb)
        if logger.head.load(moRelaxed) - logger.tail.load(moAcquire) >= logger.config.bufferSize:
          discard logger.dropped.fetchAdd(1, moRelaxed)
          return
  let idx = head and logger.mask
  let maxE = logger.maxEntry
  let dataPtr = cast[ptr UncheckedArray[byte]](
    cast[int](logger.slotData) + idx * maxE)
  var pos = 0
  let copyLen = min(msg.len, maxE - 1)
  copyLogBytes(dataPtr, pos, msg, copyLen)
  logger.slots[idx].level = uint8(ord(level))
  logger.slots[idx].tsec = ts.tv_sec.int64
  logger.slots[idx].tnsec = ts.tv_nsec.int64
  logger.slots[idx].len.store(int32(pos + 1), moRelease)
  logger.head.store(head + 1, moRelease)

## Enqueues ``msg`` with key-value ``fields`` at ``level`` into the ring buffer.
proc log*(logger: AsyncLogger, level: LogLevel, msg: string,
          fields: openArray[(string, string)]) {.inline.} =
  if logger == nil or logger.closed.load(moAcquire): return
  if ord(level) < logger.level.load(moRelaxed): return
  var ts: Timespec
  discard clock_gettime(CLOCK_REALTIME, ts)
  when compileOption("threads"):
    acquire(logger.producerLock)
    defer: release(logger.producerLock)
    if logger.closed.load(moAcquire): return
  let head = logger.head.load(moRelaxed)
  let tail = logger.tail.load(moAcquire)
  if head - tail >= logger.config.bufferSize:
    if logger.config.dropOnFull:
      discard logger.dropped.fetchAdd(1, moRelaxed)
      return
    else:
      when compileOption("threads"):
        var spins = 0
        while logger.head.load(moRelaxed) - logger.tail.load(moAcquire) >= logger.config.bufferSize:
          if logger.closed.load(moAcquire): return
          # Bounded wait (<=100ms): a stalled flusher must not hang producers
          # forever; the record is dropped after the window.
          if spins >= 1000:
            discard logger.dropped.fetchAdd(1, moRelaxed)
            return
          inc spins
          sleepNs(100_000)
      else:
        var fb = initFlushBuf(logger.maxEntry, 64)
        drainRing(logger, fb)
        deinitFlushBuf(fb)
        if logger.head.load(moRelaxed) - logger.tail.load(moAcquire) >= logger.config.bufferSize:
          discard logger.dropped.fetchAdd(1, moRelaxed)
          return
  let idx = head and logger.mask
  let maxE = logger.maxEntry
  let dataPtr = cast[ptr UncheckedArray[byte]](
    cast[int](logger.slotData) + idx * maxE)
  var pos = 0
  let msgLen = min(msg.len, maxE - 1)
  copyLogBytes(dataPtr, pos, msg, msgLen)
  for (k, v) in fields:
    if pos + k.len + v.len + 2 >= maxE: break
    dataPtr[pos] = byte(FieldSep); pos += 1
    copyLogBytes(dataPtr, pos, k, k.len)
    dataPtr[pos] = byte(KvSep); pos += 1
    copyLogBytes(dataPtr, pos, v, v.len)
  logger.slots[idx].level = uint8(ord(level))
  logger.slots[idx].tsec = ts.tv_sec.int64
  logger.slots[idx].tnsec = ts.tv_nsec.int64
  logger.slots[idx].len.store(int32(pos + 1), moRelease)
  logger.head.store(head + 1, moRelease)

## Logs ``msg`` at trace level through the ``AsyncLogger``.
proc trace*(logger: AsyncLogger, msg: string) {.inline.} = logger.log(llTrace, msg)
## Logs ``msg`` at debug level through the ``AsyncLogger``.
proc debug*(logger: AsyncLogger, msg: string) {.inline.} = logger.log(llDebug, msg)
## Logs ``msg`` at info level through the ``AsyncLogger``.
proc info*(logger: AsyncLogger, msg: string) {.inline.} = logger.log(llInfo, msg)
## Logs ``msg`` at warn level through the ``AsyncLogger``.
proc warn*(logger: AsyncLogger, msg: string) {.inline.} = logger.log(llWarn, msg)
## Logs ``msg`` at error level through the ``AsyncLogger``.
proc error*(logger: AsyncLogger, msg: string) {.inline.} = logger.log(llError, msg)
## Logs ``msg`` at fatal level through the ``AsyncLogger``.
proc fatal*(logger: AsyncLogger, msg: string) {.inline.} = logger.log(llFatal, msg)

## Logs ``msg`` with key-value ``fields`` at trace level through the ``AsyncLogger``.
proc trace*(logger: AsyncLogger, msg: string, fields: openArray[(string, string)]) {.inline.} = logger.log(llTrace, msg, fields)
## Logs ``msg`` with key-value ``fields`` at debug level through the ``AsyncLogger``.
proc debug*(logger: AsyncLogger, msg: string, fields: openArray[(string, string)]) {.inline.} = logger.log(llDebug, msg, fields)
## Logs ``msg`` with key-value ``fields`` at info level through the ``AsyncLogger``.
proc info*(logger: AsyncLogger, msg: string, fields: openArray[(string, string)]) {.inline.} = logger.log(llInfo, msg, fields)
## Logs ``msg`` with key-value ``fields`` at warn level through the ``AsyncLogger``.
proc warn*(logger: AsyncLogger, msg: string, fields: openArray[(string, string)]) {.inline.} = logger.log(llWarn, msg, fields)
## Logs ``msg`` with key-value ``fields`` at error level through the ``AsyncLogger``.
proc error*(logger: AsyncLogger, msg: string, fields: openArray[(string, string)]) {.inline.} = logger.log(llError, msg, fields)
## Logs ``msg`` with key-value ``fields`` at fatal level through the ``AsyncLogger``.
proc fatal*(logger: AsyncLogger, msg: string, fields: openArray[(string, string)]) {.inline.} = logger.log(llFatal, msg, fields)

## Logs ``msg`` at ``level`` and appends the JSON form of ``obj`` as raw fields.
proc logObj*[T: object | ref object](logger: AsyncLogger, level: LogLevel, msg: string, obj: T) {.inline.} =
  if logger == nil or logger.closed.load(moAcquire): return
  if ord(level) < logger.level.load(moRelaxed): return
  var ts: Timespec
  discard clock_gettime(CLOCK_REALTIME, ts)
  when compileOption("threads"):
    acquire(logger.producerLock)
    defer: release(logger.producerLock)
    if logger.closed.load(moAcquire): return
  let head = logger.head.load(moRelaxed)
  let tail = logger.tail.load(moAcquire)
  if head - tail >= logger.config.bufferSize:
    if logger.config.dropOnFull:
      discard logger.dropped.fetchAdd(1, moRelaxed)
      return
    else:
      when compileOption("threads"):
        var spins = 0
        while logger.head.load(moRelaxed) - logger.tail.load(moAcquire) >= logger.config.bufferSize:
          if logger.closed.load(moAcquire): return
          # Bounded wait (<=100ms): a stalled flusher must not hang producers
          # forever; the record is dropped after the window.
          if spins >= 1000:
            discard logger.dropped.fetchAdd(1, moRelaxed)
            return
          inc spins
          sleepNs(100_000)
      else:
        var fb = initFlushBuf(logger.maxEntry, 64)
        drainRing(logger, fb)
        deinitFlushBuf(fb)
        if logger.head.load(moRelaxed) - logger.tail.load(moAcquire) >= logger.config.bufferSize:
          discard logger.dropped.fetchAdd(1, moRelaxed)
          return
  var jsonBuf {.threadvar.}: string
  if jsonBuf.len == 0:
    jsonBuf = newStringOfCap(1024)
  serializeDirectInto(jsonBuf, obj)
  let idx = head and logger.mask
  let maxE = logger.maxEntry
  let dataPtr = cast[ptr UncheckedArray[byte]](
    cast[int](logger.slotData) + idx * maxE)
  var pos = 0
  let msgLen = min(msg.len, maxE - 4)
  copyLogBytes(dataPtr, pos, msg, msgLen)
  dataPtr[pos] = byte(RawJsonSep)
  pos += 1
  template copyTruncatedMarker(originalLen: int) =
    let marker = "\"truncated\":true,\"original_bytes\":" & $originalLen
    if marker.len <= maxE - pos - 1:
      copyMem(addr dataPtr[pos], unsafeAddr marker[0], marker.len)
      pos += marker.len
    else:
      let shortMarker = "\"truncated\":true"
      if shortMarker.len <= maxE - pos - 1:
        copyMem(addr dataPtr[pos], unsafeAddr shortMarker[0], shortMarker.len)
        pos += shortMarker.len

  if jsonBuf.len >= 2 and jsonBuf[0] == '{' and jsonBuf[jsonBuf.len - 1] == '}':
    let jsonLen = jsonBuf.len - 2
    if jsonLen <= maxE - pos - 1:
      copyMem(addr dataPtr[pos], addr jsonBuf[1], jsonLen)
      pos += jsonLen
    else:
      copyTruncatedMarker(jsonBuf.len)
  else:
    let dataPrefix = "\"data\":"
    if dataPrefix.len + jsonBuf.len <= maxE - pos - 1:
      copyMem(addr dataPtr[pos], unsafeAddr dataPrefix[0], dataPrefix.len)
      pos += dataPrefix.len
      if jsonBuf.len > 0:
        copyMem(addr dataPtr[pos], addr jsonBuf[0], jsonBuf.len)
        pos += jsonBuf.len
    else:
      copyTruncatedMarker(jsonBuf.len)
  logger.slots[idx].level = uint8(ord(level))
  logger.slots[idx].tsec = ts.tv_sec.int64
  logger.slots[idx].tnsec = ts.tv_nsec.int64
  logger.slots[idx].len.store(int32(pos + 1), moRelease)
  logger.head.store(head + 1, moRelease)

## Logs ``msg`` at trace level with the JSON form of ``obj`` appended.
proc traceObj*[T: object | ref object](logger: AsyncLogger, msg: string, obj: T) {.inline.} = logger.logObj(llTrace, msg, obj)
## Logs ``msg`` at debug level with the JSON form of ``obj`` appended.
proc debugObj*[T: object | ref object](logger: AsyncLogger, msg: string, obj: T) {.inline.} = logger.logObj(llDebug, msg, obj)
## Logs ``msg`` at info level with the JSON form of ``obj`` appended.
proc infoObj*[T: object | ref object](logger: AsyncLogger, msg: string, obj: T) {.inline.} = logger.logObj(llInfo, msg, obj)
## Logs ``msg`` at warn level with the JSON form of ``obj`` appended.
proc warnObj*[T: object | ref object](logger: AsyncLogger, msg: string, obj: T) {.inline.} = logger.logObj(llWarn, msg, obj)
## Logs ``msg`` at error level with the JSON form of ``obj`` appended.
proc errorObj*[T: object | ref object](logger: AsyncLogger, msg: string, obj: T) {.inline.} = logger.logObj(llError, msg, obj)
## Logs ``msg`` at fatal level with the JSON form of ``obj`` appended.
proc fatalObj*[T: object | ref object](logger: AsyncLogger, msg: string, obj: T) {.inline.} = logger.logObj(llFatal, msg, obj)

proc findFirstMarker(dataPtr: ptr UncheckedArray[byte], entryLen: int): tuple[pos: int, isRawJson: bool] {.inline.} =
  var i = 0
  while i < entryLen:
    if dataPtr[i] == byte(RawJsonSep): return (i, true)
    if dataPtr[i] == byte(FieldSep): return (i, false)
    i += 1
  return (entryLen, false)

proc formatSlotJson(logger: AsyncLogger, dataPtr: ptr UncheckedArray[byte],
                    entryLen: int, level: LogLevel, fb: var FlushBuf) =
  let (msgEnd, isRawJson) = findFirstMarker(dataPtr, entryLen)
  let tsLen = logger.cachedTsFullLen.int

  putStr(fb, JsonPre)
  putBytes(fb, addr logger.cachedTsFull[0], tsLen)
  putStr(fb, JsonMidLevel)
  putStr(fb, LevelStrJson[level])
  putStr(fb, JsonMidMsg)
  if msgEnd > 0:
    putJsonEscaped(fb, cast[ptr byte](addr dataPtr[0]), msgEnd)
  putByte(fb, byte('"'))

  if isRawJson:
    let jsonStart = msgEnd + 1
    let jsonLen = entryLen - jsonStart
    if jsonLen > 0:
      putByte(fb, byte(','))
      if rawJsonHasReservedTopLevelKey(dataPtr, jsonStart, jsonLen):
        putStr(fb, "\"fields\":{")
        putBytes(fb, addr dataPtr[jsonStart], jsonLen)
        putByte(fb, byte('}'))
      else:
        putBytes(fb, addr dataPtr[jsonStart], jsonLen)
  else:
    var i = msgEnd
    while i < entryLen:
      if dataPtr[i] == byte(FieldSep):
        i += 1
        var kStart = i
        while i < entryLen and dataPtr[i] != byte(KvSep): i += 1
        let kLen = i - kStart
        if i < entryLen: i += 1
        var vStart = i
        while i < entryLen and dataPtr[i] != byte(FieldSep): i += 1
        let vLen = i - vStart
        putByte(fb, byte(','))
        putByte(fb, byte('"'))
        if isReservedLogFieldKey(dataPtr, kStart, kLen):
          putStr(fb, "field_")
        if kLen > 0:
          putJsonEscaped(fb, cast[ptr byte](addr dataPtr[kStart]), kLen)
        putByte(fb, byte('"'))
        putByte(fb, byte(':'))
        putByte(fb, byte('"'))
        if vLen > 0:
          putJsonEscaped(fb, cast[ptr byte](addr dataPtr[vStart]), vLen)
        putByte(fb, byte('"'))
      else:
        i += 1
  putByte(fb, byte('}'))
  putByte(fb, byte('\n'))

proc formatSlotText(logger: AsyncLogger, dataPtr: ptr UncheckedArray[byte],
                    entryLen: int, level: LogLevel, colorize: bool, fb: var FlushBuf) =
  let (msgEnd, isRawJson) = findFirstMarker(dataPtr, entryLen)
  putBytes(fb, addr logger.cachedTsFull[0], logger.cachedTsFullLen.int)
  putByte(fb, byte(' '))
  if colorize: putStr(fb, AnsiColors[level])
  putStr(fb, LevelStrText[level])
  if colorize: putStr(fb, AnsiReset)
  putByte(fb, byte(' '))
  if msgEnd > 0:
    putTextEscaped(fb, dataPtr, msgEnd)
  if isRawJson:
    let jsonStart = msgEnd + 1
    let jsonLen = entryLen - jsonStart
    if jsonLen > 0:
      putByte(fb, byte(' '))
      putByte(fb, byte('{'))
      putTextEscaped(fb, cast[ptr UncheckedArray[byte]](addr dataPtr[jsonStart]), jsonLen)
      putByte(fb, byte('}'))
  else:
    var i = msgEnd
    while i < entryLen:
      if dataPtr[i] == byte(FieldSep):
        i += 1
        var kStart = i
        while i < entryLen and dataPtr[i] != byte(KvSep): i += 1
        let kLen = i - kStart
        if i < entryLen: i += 1
        var vStart = i
        while i < entryLen and dataPtr[i] != byte(FieldSep): i += 1
        let vLen = i - vStart
        putByte(fb, byte(' '))
        if kLen > 0: putTextEscaped(fb, cast[ptr UncheckedArray[byte]](addr dataPtr[kStart]), kLen)
        putByte(fb, byte('='))
        if vLen > 0: putTextEscaped(fb, cast[ptr UncheckedArray[byte]](addr dataPtr[vStart]), vLen)
      else:
        i += 1
  putByte(fb, byte('\n'))

proc formatSlotCompact(logger: AsyncLogger, dataPtr: ptr UncheckedArray[byte],
                       entryLen: int, level: LogLevel, colorize: bool, fb: var FlushBuf) =
  let (msgEnd, isRawJson) = findFirstMarker(dataPtr, entryLen)
  if colorize: putStr(fb, AnsiColors[level])
  putStr(fb, LevelStrCompact[level])
  if colorize: putStr(fb, AnsiReset)
  putByte(fb, byte(' '))
  putBytes(fb, addr logger.cachedTsCompact[0], logger.cachedTsCompactLen.int)
  putByte(fb, byte(' '))
  if msgEnd > 0:
    putTextEscaped(fb, dataPtr, msgEnd)
  if isRawJson:
    let jsonStart = msgEnd + 1
    let jsonLen = entryLen - jsonStart
    if jsonLen > 0:
      putByte(fb, byte(' '))
      putByte(fb, byte('{'))
      putTextEscaped(fb, cast[ptr UncheckedArray[byte]](addr dataPtr[jsonStart]), jsonLen)
      putByte(fb, byte('}'))
  else:
    var i = msgEnd
    while i < entryLen:
      if dataPtr[i] == byte(FieldSep):
        i += 1
        var kStart = i
        while i < entryLen and dataPtr[i] != byte(KvSep): i += 1
        let kLen = i - kStart
        if i < entryLen: i += 1
        var vStart = i
        while i < entryLen and dataPtr[i] != byte(FieldSep): i += 1
        let vLen = i - vStart
        putByte(fb, byte(' '))
        if kLen > 0: putTextEscaped(fb, cast[ptr UncheckedArray[byte]](addr dataPtr[kStart]), kLen)
        putByte(fb, byte('='))
        if vLen > 0: putTextEscaped(fb, cast[ptr UncheckedArray[byte]](addr dataPtr[vStart]), vLen)
      else:
        i += 1
  putByte(fb, byte('\n'))

proc emitDroppedWarning(logger: AsyncLogger, fb: var FlushBuf) =
  let d = logger.dropped.exchange(0, moRelaxed)
  if d <= 0:
    return
  if logger.cachedTsFullLen == 0 or logger.cachedTsCompactLen == 0:
    var ts: Timespec
    discard clock_gettime(CLOCK_REALTIME, ts)
    refreshTs(logger, ts.tv_sec.int64, ts.tv_nsec.int64)
  fb.pos = 0
  case logger.config.format
  of lfJson:
    putStr(fb, "{\"ts\":\"")
    putBytes(fb, addr logger.cachedTsFull[0], logger.cachedTsFullLen.int)
    putStr(fb, "\",\"level\":\"warn\",\"msg\":\"dropped ")
    var tmp: array[20, byte]
    var n = d
    var tl = 0
    if n == 0:
      tmp[0] = byte('0'); tl = 1
    else:
      while n > 0:
        tmp[tl] = byte(ord('0') + (n mod 10).int); n = n div 10; tl += 1
      for i in 0..<(tl div 2):
        let t = tmp[i]; tmp[i] = tmp[tl - 1 - i]; tmp[tl - 1 - i] = t
    putBytes(fb, addr tmp[0], tl)
    putStr(fb, " log entries\"}\n")
  of lfText:
    putBytes(fb, addr logger.cachedTsFull[0], logger.cachedTsFullLen.int)
    putStr(fb, " WARN  dropped ")
    putStr(fb, $d)
    putStr(fb, " log entries\n")
  of lfCompact:
    putStr(fb, "W ")
    putBytes(fb, addr logger.cachedTsCompact[0], logger.cachedTsCompactLen.int)
    putStr(fb, " dropped ")
    putStr(fb, $d)
    putStr(fb, " log entries\n")
  flushBuffered(logger, fb)

proc drainRing(logger: AsyncLogger, fb: var FlushBuf) =
  let tail = logger.tail.load(moAcquire)
  let head = logger.head.load(moAcquire)
  if tail == head:
    emitDroppedWarning(logger, fb)
    logger.flushedTail.store(head, moRelease)
    return

  fb.pos = 0
  let fmt = logger.config.format
  let colorize = logger.config.colorize
  var current = tail

  while current != head:
    flushBeforeWorstCaseEntry(logger, fb)
    let idx = current and logger.mask
    let rawLen = logger.slots[idx].len.load(moAcquire)
    if rawLen <= 0: break
    let entryLen = min((rawLen - 1).int, logger.maxEntry)
    let dataPtr = cast[ptr UncheckedArray[byte]](
      cast[int](logger.slotData) + idx * logger.maxEntry)
    let rawLevel = logger.slots[idx].level.int
    let level = if rawLevel >= ord(low(LogLevel)) and rawLevel <= ord(high(LogLevel)):
      LogLevel(rawLevel) else: llInfo
    refreshTs(logger, logger.slots[idx].tsec, logger.slots[idx].tnsec)

    case fmt
    of lfJson: formatSlotJson(logger, dataPtr, entryLen, level, fb)
    of lfText: formatSlotText(logger, dataPtr, entryLen, level, colorize, fb)
    of lfCompact: formatSlotCompact(logger, dataPtr, entryLen, level, colorize, fb)

    logger.slots[idx].len.store(0, moRelease)
    current += 1

  logger.tail.store(current, moRelease)

  flushBuffered(logger, fb)
  emitDroppedWarning(logger, fb)
  logger.flushedTail.store(current, moRelease)

when compileOption("threads"):
  proc flushThreadProc(loggerPtr: ptr AsyncLoggerObj) {.thread.} =
    let logger = cast[AsyncLogger](loggerPtr)
    let rawMs = logger.config.flushIntervalMs
    let sleepDurNs = if rawMs > 2000: 2_000_000_000 else: rawMs * 1_000_000
    var fb = initFlushBuf(logger.maxEntry, 64)
    while not logger.stopFlag.load(moAcquire):
      try:
        drainRing(logger, fb)
      except CatchableError:
        # A failure in the flush thread (e.g. OOM) drops the batch and keeps the
        # thread alive; it must never take down the host process.
        discard logger.writeErrors.fetchAdd(1, moRelaxed)
      sleepNs(sleepDurNs)
    for retry in 0..10:
      try:
        drainRing(logger, fb)
      except CatchableError:
        discard
      if logger.head.load(moAcquire) == logger.tail.load(moAcquire): break
      sleepNs(1_000_000)
    deinitFlushBuf(fb)

## Creates an ``AsyncLogger`` from ``config`` and starts its flush thread when threads are enabled.
proc newAsyncLogger*(config: AsyncLoggerConfig = defaultConfig()): AsyncLogger =
  ignoreSigpipe()
  var cfg = config
  normalizeConfig(cfg)
  let logger = cast[AsyncLogger](alloc0(sizeof(AsyncLoggerObj)))
  logger.config = cfg
  logger.mask = cfg.bufferSize - 1
  logger.maxEntry = cfg.maxEntryBytes
  logger.head.store(0, moRelaxed)
  logger.tail.store(0, moRelaxed)
  logger.flushedTail.store(0, moRelaxed)
  logger.dropped.store(0, moRelaxed)
  logger.writeErrors.store(0, moRelaxed)
  logger.stopFlag.store(false, moRelaxed)
  logger.closed.store(false, moRelaxed)
  logger.level.store(ord(cfg.level), moRelaxed)
  logger.cachedTsSec = -1
  logger.cachedTsMs = -1
  logger.slots = cast[ptr UncheckedArray[RingSlot]](
    alloc0(cfg.bufferSize * sizeof(RingSlot)))
  logger.slotData = cast[ptr UncheckedArray[byte]](
    alloc0(cfg.bufferSize * cfg.maxEntryBytes))
  case cfg.output
  of loStdout: logger.fd = cint(1)
  of loStderr: logger.fd = cint(2)
  of loFile:
    logger.fd = open(cstring(cfg.filePath), O_WRONLY or O_CREAT or O_APPEND, 0o644)
    if logger.fd < 0: logger.fd = cint(2)
  when compileOption("threads"):
    initLock(logger.flushLock)
    initCond(logger.flushCond)
    initLock(logger.producerLock)
    createThread(logger.flushThread, flushThreadProc, cast[ptr AsyncLoggerObj](logger))
  result = logger

## Stops the logger and waits for the flush thread to finish.
## File/stdout/stderr writes use blocking POSIX write semantics; if the
## target fd is a blocked FIFO/pipe/device, close can remain blocked until
## the fd accepts data or fails.
proc close*(logger: AsyncLogger) =
  if logger == nil: return
  when compileOption("threads"):
    var expected = false
    if not logger.closed.compareExchange(expected, true, moSequentiallyConsistent, moSequentiallyConsistent):
      return
    logger.stopFlag.store(true, moRelease)
    acquire(logger.producerLock)
    release(logger.producerLock)
  else:
    var expected = false
    if not logger.closed.compareExchange(expected, true, moSequentiallyConsistent, moSequentiallyConsistent):
      return
    logger.stopFlag.store(true, moRelease)
  when compileOption("threads"):
    joinThread(logger.flushThread)
    deinitLock(logger.flushLock)
    deinitCond(logger.flushCond)
    deinitLock(logger.producerLock)
  else:
    var fb = initFlushBuf(logger.maxEntry, 64)
    drainRing(logger, fb)
    deinitFlushBuf(fb)
  if logger.config.output == loFile and logger.fd > 2:
    discard posix.close(logger.fd)
    logger.fd = -1
  dealloc(logger.slotData)
  dealloc(logger.slots)
  logger.slotData = nil
  logger.slots = nil

## Closes ``logger`` and deallocates its storage, then sets the handle to nil.
proc destroy*(logger: var AsyncLogger) =
  let old = logger
  logger = nil
  if old == nil:
    return
  close(old)
  dealloc(old)

## Alias of ``destroy`` for idiomatic disposal of the ``AsyncLogger`` handle.
proc dispose*(logger: var AsyncLogger) {.inline.} =
  destroy(logger)

## Waits until all enqueued entries have been written to the output.
proc flush*(logger: AsyncLogger) =
  if logger == nil or logger.closed.load(moAcquire): return
  when compileOption("threads"):
    let target = logger.head.load(moAcquire)
    var spins = 0
    while logger.flushedTail.load(moAcquire) < target:
      if logger.stopFlag.load(moAcquire): break
      sleepNs(500_000)
      spins += 1
      if spins > 20000: break
  else:
    var fb = initFlushBuf(logger.maxEntry, 64)
    drainRing(logger, fb)
    deinitFlushBuf(fb)

## Returns how many entries were dropped because the ring buffer was full.
proc droppedCount*(logger: AsyncLogger): int64 =
  if logger == nil: return 0
  logger.dropped.load(moRelaxed)

## Returns how many times a write to the output fd failed.
proc writeErrorCount*(logger: AsyncLogger): int64 =
  if logger == nil: return 0
  logger.writeErrors.load(moRelaxed)

## Changes the minimum ``LogLevel`` that ``logger`` will emit.
proc setLevel*(logger: AsyncLogger, level: LogLevel) =
  if logger == nil or logger.closed.load(moAcquire): return
  logger.level.store(ord(level), moRelease)

var defaultLogger: AsyncLogger

## Installs a new default ``AsyncLogger`` built from ``config``, destroying the previous one.
proc initDefaultLogger*(config: AsyncLoggerConfig = defaultConfig()) =
  let next = newAsyncLogger(config)
  when compileOption("threads"):
    ensureDefaultLoggerLock()
    acquire(defaultLoggerLock)
    let old = defaultLogger
    defaultLogger = next
    release(defaultLoggerLock)
    if old != nil:
      var retired = old
      destroy(retired)
  else:
    var old = defaultLogger
    defaultLogger = next
    if old != nil:
      destroy(old)

## Closes and destroys the current default ``AsyncLogger``.
proc closeDefaultLogger*() =
  when compileOption("threads"):
    ensureDefaultLoggerLock()
    acquire(defaultLoggerLock)
    let old = defaultLogger
    defaultLogger = nil
    release(defaultLoggerLock)
    if old != nil:
      var retired = old
      destroy(retired)
  else:
    var old = defaultLogger
    defaultLogger = nil
    if old != nil: destroy(old)

## Return the current default logger as a borrowed pointer.
## Prefer logDefault/flushDefaultLogger for concurrent code because they hold
## the publication lock across the operation.
proc getDefaultLogger*(): AsyncLogger =
  when compileOption("threads"):
    ensureDefaultLoggerLock()
    acquire(defaultLoggerLock)
    result = defaultLogger
    release(defaultLoggerLock)
  else:
    defaultLogger

## Returns true when a default ``AsyncLogger`` is installed.
proc defaultLoggerIsSet*(): bool {.inline.} =
  getDefaultLogger() != nil

## Logs ``message`` at ``level`` through the current default ``AsyncLogger``.
proc logDefault*(level: LogLevel, message: string) =
  when compileOption("threads"):
    ensureDefaultLoggerLock()
    acquire(defaultLoggerLock)
    let logger = defaultLogger
    if logger != nil:
      logger.log(level, message)
    release(defaultLoggerLock)
  else:
    if defaultLogger != nil:
      defaultLogger.log(level, message)

## Flushes the current default ``AsyncLogger`` if one is installed.
proc flushDefaultLogger*() =
  when compileOption("threads"):
    ensureDefaultLoggerLock()
    acquire(defaultLoggerLock)
    let logger = defaultLogger
    if logger != nil:
      logger.flush()
    release(defaultLoggerLock)
  else:
    if defaultLogger != nil:
      defaultLogger.flush()
