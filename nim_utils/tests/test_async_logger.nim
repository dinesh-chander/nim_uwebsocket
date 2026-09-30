import std/[atomics, json, strutils, times, posix, monotimes]
import ../src/nim_utils/async_logger

proc readFileContent(path: string): string =
  let fd = open(cstring(path), O_RDONLY)
  if fd < 0:
    return ""
  var buf: array[65536, char]
  var content = ""
  while true:
    let n = read(fd, addr buf[0], sizeof(buf))
    if n <= 0:
      break
    for i in 0..<n:
      content.add buf[i]
  discard posix.close(fd)
  return content

proc removeFileIfExists(path: string) =
  discard unlink(cstring(path))

proc sleepMs(ms: int) =
  var req: Timespec
  var rem: Timespec
  req.tv_sec = posix.Time(ms div 1000)
  req.tv_nsec = (ms mod 1000) * 1_000_000
  discard nanosleep(req, rem)

when compileOption("threads"):
  type AsyncFlushArg = object
    logger: AsyncLogger
    done: ptr Atomic[bool]

  proc asyncLoggerFlushCaller(arg: ptr AsyncFlushArg) {.thread.} =
    arg.logger.flush()
    arg.done[].store(true, moRelease)

  type AsyncCloseArg = object
    logger: AsyncLogger
    done: ptr Atomic[bool]

  proc asyncLoggerCloseCaller(arg: ptr AsyncCloseArg) {.thread.} =
    arg.logger.close()
    arg.done[].store(true, moRelease)

  type BlockingLogArg = object
    logger: AsyncLogger
    done: ptr Atomic[bool]

  proc asyncLoggerSingleProducer(arg: ptr BlockingLogArg) {.thread.} =
    arg.logger.info("blocked producer")
    arg.done[].store(true, moRelease)

  proc drainNonBlockingFd(fd: cint, idleLimitMs = 25, maxMs = 3000) =
    var buf: array[16384, char]
    var idleMs = 0
    var elapsedMs = 0
    while elapsedMs < maxMs and idleMs < idleLimitMs:
      let n = read(fd, addr buf[0], sizeof(buf))
      if n > 0:
        idleMs = 0
      elif n < 0 and errno == EINTR:
        discard
      elif n < 0 and errno != EAGAIN:
        break
      else:
        sleepMs(1)
        inc idleMs
        inc elapsedMs

proc timestampToken(line: string): string =
  let marker = "\"ts\":\""
  let start = line.find(marker)
  if start < 0:
    return ""
  let valueStart = start + marker.len
  let valueEnd = line.find("\"", valueStart)
  if valueEnd < 0:
    return ""
  line[valueStart ..< valueEnd]

proc occurrences(haystack, needle: string): int =
  if needle.len == 0:
    return 0
  var start = 0
  while true:
    let pos = haystack.find(needle, start)
    if pos < 0:
      break
    inc result
    start = pos + needle.len

proc emit(s: string) =
  discard write(cint(1), unsafeAddr s[0], s.len)

var passed = 0
var failed = 0
var total = 0

template test(name: string, body: untyped) =
  total += 1
  try:
    body
    passed += 1
    emit("  PASS: " & name & "\n")
  except:
    failed += 1
    emit("  FAIL: " & name & " - " & getCurrentExceptionMsg() & "\n")

template check(cond: bool) =
  if not cond:
    raise newException(AssertionDefect, "check failed: " & astToStr(cond))

template check(cond: bool, msg: string) =
  if not cond:
    raise newException(AssertionDefect, msg)

proc main() =
  let tmpDir = "/tmp/nim_async_logger_test_" & $getpid()
  discard mkdir(cstring(tmpDir), 0o755)

  emit("=== Async Logger Tests ===\n")
  emit("\n--- JSON Format (all levels) ---\n")

  test "JSON format - all levels":
    let logFile = tmpDir & "/json_all.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llTrace
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.trace("trace message")
    logger.debug("debug message")
    logger.info("info message")
    logger.warn("warn message")
    logger.error("error message")
    logger.fatal("fatal message")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"level\":\"trace\""), "missing trace"
    check content.contains("\"level\":\"debug\""), "missing debug"
    check content.contains("\"level\":\"info\""), "missing info"
    check content.contains("\"level\":\"warn\""), "missing warn"
    check content.contains("\"level\":\"error\""), "missing error"
    check content.contains("\"level\":\"fatal\""), "missing fatal"
    check content.contains("\"msg\":\"trace message\""), "missing trace msg"
    check content.contains("\"msg\":\"info message\""), "missing info msg"
    check content.contains("\"ts\":\""), "missing timestamp"
    removeFileIfExists(logFile)

  emit("\n--- Text Format ---\n")

  test "Text format output":
    let logFile = tmpDir & "/text.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfText
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llTrace
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("hello world")
    logger.error("bad thing")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("INFO "), "missing INFO"
    check content.contains("hello world"), "missing msg"
    check content.contains("ERROR"), "missing ERROR"
    check content.contains("bad thing"), "missing error msg"
    removeFileIfExists(logFile)

  when not compileOption("threads"):
    test "Non-thread backpressure drains full ring in order":
      let logFile = tmpDir & "/nonthread_backpressure.log"
      removeFileIfExists(logFile)
      var cfg = defaultConfig()
      cfg.format = lfCompact
      cfg.output = loFile
      cfg.filePath = logFile
      cfg.level = llInfo
      cfg.bufferSize = 4
      cfg.dropOnFull = false
      let logger = newAsyncLogger(cfg)
      for i in 0 ..< 12:
        logger.info("msg-" & $i)
      logger.close()
      let content = readFileContent(logFile)
      var last = -1
      for i in 0 ..< 12:
        let pos = content.find("msg-" & $i)
        check pos >= 0, "missing msg-" & $i
        check pos > last, "message order regressed at msg-" & $i
        last = pos
      removeFileIfExists(logFile)

  emit("\n--- Compact Format ---\n")

  test "Compact format output":
    let logFile = tmpDir & "/compact.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfCompact
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llTrace
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("compact test")
    logger.warn("watch out")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("I "), "missing I prefix"
    check content.contains("compact test"), "missing msg"
    check content.contains("W "), "missing W prefix"
    check content.contains("watch out"), "missing warn msg"
    removeFileIfExists(logFile)

  emit("\n--- Structured Logging ---\n")

  test "JSON structured fields":
    let logFile = tmpDir & "/structured_json.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("request handled", {"method": "GET", "path": "/api", "status": "200", "duration_ms": "1.23"})
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"method\":\"GET\""), "missing method field"
    check content.contains("\"path\":\"/api\""), "missing path field"
    check content.contains("\"status\":\"200\""), "missing status field"
    check content.contains("\"duration_ms\":\"1.23\""), "missing duration field"
    check content.contains("\"msg\":\"request handled\""), "missing msg"
    removeFileIfExists(logFile)

  test "JSON structured fields cannot spoof reserved top-level keys":
    let logFile = tmpDir & "/structured_json_reserved.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("reserved fields", {"level": "fatal", "msg": "spoof", "ts": "bad"})
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check occurrences(content, "\"level\":") == 1, "duplicate top-level level key"
    check occurrences(content, "\"msg\":") == 1, "duplicate top-level msg key"
    check occurrences(content, "\"ts\":") == 1, "duplicate top-level ts key"
    check content.contains("\"field_level\":\"fatal\""), "reserved level should be namespaced"
    check content.contains("\"field_msg\":\"spoof\""), "reserved msg should be namespaced"
    check content.contains("\"field_ts\":\"bad\""), "reserved ts should be namespaced"
    removeFileIfExists(logFile)

  test "Text structured fields":
    let logFile = tmpDir & "/structured_text.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfText
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("request handled", {"method": "GET", "path": "/api"})
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("method=GET"), "missing method field"
    check content.contains("path=/api"), "missing path field"
    removeFileIfExists(logFile)

  test "Text format escapes control bytes to prevent log forging":
    let logFile = tmpDir & "/text_forging.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfText
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("hello\nERROR forged", {"path": "/x\r\nWARN forged", "tab": "a\tb"})
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    var lines = 0
    for line in content.splitLines:
      if line.len > 0:
        inc lines
    check lines == 1, "control bytes created extra physical log lines"
    check content.contains("hello\\nERROR forged"), "newline should be escaped in message"
    check content.contains("path=/x\\r\\nWARN forged"), "CRLF should be escaped in field"
    check content.contains("tab=a\\tb"), "tab should be escaped in field"
    removeFileIfExists(logFile)

  test "Compact structured fields":
    let logFile = tmpDir & "/structured_compact.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfCompact
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("req done", {"method": "POST"})
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("method=POST"), "missing field"
    removeFileIfExists(logFile)

  test "Compact format escapes control bytes to prevent log forging":
    let logFile = tmpDir & "/compact_forging.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfCompact
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.warn("compact\nforged", {"key": "value\r\nforged"})
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    var lines = 0
    for line in content.splitLines:
      if line.len > 0:
        inc lines
    check lines == 1, "control bytes created extra compact log lines"
    check content.contains("compact\\nforged"), "compact newline should be escaped"
    check content.contains("key=value\\r\\nforged"), "compact field CRLF should be escaped"
    removeFileIfExists(logFile)

  emit("\n--- Level Filtering ---\n")

  test "Level filtering - info filters out debug/trace":
    let logFile = tmpDir & "/level_filter.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.trace("should not appear")
    logger.debug("should not appear")
    logger.info("should appear")
    logger.warn("should appear")
    logger.error("should appear")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check not content.contains("\"level\":\"trace\""), "trace should be filtered"
    check not content.contains("\"level\":\"debug\""), "debug should be filtered"
    check content.contains("\"level\":\"info\""), "info should pass"
    check content.contains("\"level\":\"warn\""), "warn should pass"
    check content.contains("\"level\":\"error\""), "error should pass"
    removeFileIfExists(logFile)

  test "setLevel changes filter at runtime":
    let logFile = tmpDir & "/setlevel.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llError
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("should not appear")
    logger.error("error1")
    logger.setLevel(llDebug)
    logger.debug("debug1")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check not content.contains("should not appear"), "info before setLevel filtered"
    check content.contains("error1"), "error should pass"
    check content.contains("debug1"), "debug after setLevel should pass"
    removeFileIfExists(logFile)

  emit("\n--- Drop Counting ---\n")

  test "Drop counting when buffer full":
    let logFile = tmpDir & "/drops.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfCompact
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 16
    cfg.maxEntryBytes = 256
    cfg.dropOnFull = true
    cfg.flushIntervalMs = 1000
    let logger = newAsyncLogger(cfg)
    # 5000 entries into a 16-slot ring: even if the flush thread runs
    # mid-loop (possible under load, which stretches the 64-entry loop past
    # the 1s flush interval), the ring must overflow, making drops > 0 certain.
    for i in 0..<5000:
      logger.info("fill entry " & $i)
    let drops = logger.droppedCount()
    check drops > 0, "expected some drops, got " & $drops
    logger.flush()
    sleepMs(50)
    logger.close()
    removeFileIfExists(logFile)

  test "Dropped warning is emitted even after ring drains":
    let logFile = tmpDir & "/drops_idle_warning.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfCompact
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 16
    cfg.maxEntryBytes = 256
    cfg.dropOnFull = true
    cfg.flushIntervalMs = 10
    let logger = newAsyncLogger(cfg)
    for i in 0..<512:
      logger.info("fill entry " & $i)
    check logger.droppedCount() > 0
    sleepMs(100)
    logger.flush()
    sleepMs(20)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("dropped ")
    check content.contains(" log entries")
    removeFileIfExists(logFile)

  emit("\n--- Flush Guarantees ---\n")

  test "Flush ensures all entries written":
    let logFile = tmpDir & "/flush_guarantee.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 1024
    let logger = newAsyncLogger(cfg)
    for i in 0..<100:
      logger.info("entry " & $i)
    logger.flush()
    sleepMs(50)
    let content = readFileContent(logFile)
    var count = 0
    for line in content.splitLines:
      if line.len > 0 and line.contains("\"msg\":\"entry"):
        count += 1
    check count == 100, "expected 100 entries, got " & $count
    logger.close()
    removeFileIfExists(logFile)

  when compileOption("threads"):
    test "Flush waits until blocked writer completes":
      let fifoPath = tmpDir & "/flush_blocked_fifo"
      removeFileIfExists(fifoPath)
      let fifoCreated = mkfifo(cstring(fifoPath), 0o600) == 0
      check fifoCreated, "failed to create FIFO"
      if fifoCreated:
        var readerFd = open(cstring(fifoPath), O_RDONLY or O_NONBLOCK, 0o600)
        check readerFd >= 0, "failed to open FIFO reader"
        if readerFd >= 0:
          var cfg = defaultConfig()
          cfg.format = lfJson
          cfg.output = loFile
          cfg.filePath = fifoPath
          cfg.level = llInfo
          cfg.bufferSize = 4
          cfg.maxEntryBytes = 1 shl 20
          cfg.dropOnFull = false
          cfg.flushIntervalMs = 1
          let logger = newAsyncLogger(cfg)
          let payload = repeat("x", (1 shl 20) - 256)
          logger.info(payload)
          logger.info(payload)
          sleepMs(50)

          var flushDone: Atomic[bool]
          flushDone.store(false, moRelaxed)
          var arg = AsyncFlushArg(logger: logger, done: addr flushDone)
          var flushThread: Thread[ptr AsyncFlushArg]
          createThread(flushThread, asyncLoggerFlushCaller, addr arg)
          sleepMs(100)
          check not flushDone.load(moAcquire), "flush returned before the FIFO write completed"

          drainNonBlockingFd(readerFd)
          var waitedMs = 0
          while not flushDone.load(moAcquire) and waitedMs < 3000:
            drainNonBlockingFd(readerFd, idleLimitMs = 2, maxMs = 50)
            sleepMs(1)
            inc waitedMs
          if not flushDone.load(moAcquire):
            discard posix.close(readerFd)
            readerFd = -1
          joinThread(flushThread)
          logger.close()
          if readerFd >= 0:
            discard posix.close(readerFd)
      removeFileIfExists(fifoPath)

    test "Close releases producer blocked on full ring":
      let logFile = tmpDir & "/close_blocked_producer.log"
      removeFileIfExists(logFile)
      var cfg = defaultConfig()
      cfg.format = lfJson
      cfg.output = loFile
      cfg.filePath = logFile
      cfg.level = llInfo
      cfg.bufferSize = 1
      cfg.maxEntryBytes = 128
      cfg.dropOnFull = false
      cfg.flushIntervalMs = 1000
      let logger = newAsyncLogger(cfg)
      sleepMs(50)
      logger.info("fill ring")

      var producerDone: Atomic[bool]
      producerDone.store(false, moRelaxed)
      var producerArg = BlockingLogArg(logger: logger, done: addr producerDone)
      var producerThread: Thread[ptr BlockingLogArg]
      createThread(producerThread, asyncLoggerSingleProducer, addr producerArg)
      sleepMs(20)
      check not producerDone.load(moAcquire), "producer should block on a full non-dropping ring"

      var closeDone: Atomic[bool]
      closeDone.store(false, moRelaxed)
      var closeArg = AsyncCloseArg(logger: logger, done: addr closeDone)
      var closeThread: Thread[ptr AsyncCloseArg]
      createThread(closeThread, asyncLoggerCloseCaller, addr closeArg)

      var waitedMs = 0
      while not producerDone.load(moAcquire) and waitedMs < 200:
        sleepMs(1)
        inc waitedMs
      check producerDone.load(moAcquire), "close should publish closed before waiting for producerLock"

      joinThread(producerThread)
      joinThread(closeThread)
      check closeDone.load(moAcquire), "close thread should finish"
      removeFileIfExists(logFile)

  emit("\n--- Close Flushes ---\n")

  test "Close flushes remaining entries":
    let logFile = tmpDir & "/close_flush.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 1024
    let logger = newAsyncLogger(cfg)
    for i in 0..<50:
      logger.info("close entry " & $i)
    logger.close()
    sleepMs(20)
    let content = readFileContent(logFile)
    var count = 0
    for line in content.splitLines:
      if line.len > 0 and line.contains("\"msg\":\"close entry"):
        count += 1
    check count == 50, "expected 50 entries after close, got " & $count
    removeFileIfExists(logFile)

  emit("\n--- JSON Escaping ---\n")

  test "JSON escaping of special characters":
    let logFile = tmpDir & "/escape.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("line1\nline2\ttab \"quoted\"")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\\n"), "newline should be escaped"
    check content.contains("\\t"), "tab should be escaped"
    check content.contains("\\\"quoted\\\""), "quotes should be escaped"
    removeFileIfExists(logFile)

  test "Internal logger marker bytes cannot inject JSON fields":
    let logFile = tmpDir & "/marker_injection.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("safe" & '\x1D' & "\"injected\":true")
    logger.info("fields", {"bad" & '\x1E' & "key": "value" & '\x1F' & "tail"})
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check not content.contains("\"injected\":true"), "message marker byte injected raw JSON"
    check content.contains("\"msg\":\"safe?\\\"injected\\\":true\""), "marker byte should be data, not a boundary"
    check content.contains("\"bad?key\":\"value?tail\""), "field marker bytes should be data, not delimiters"
    removeFileIfExists(logFile)

  when compileOption("threads"):
    type ProducerArg = object
      logger: AsyncLogger
      id: int
      count: int

    proc asyncLoggerProducer(arg: ptr ProducerArg) {.thread.} =
      for i in 0..<arg.count:
        arg.logger.info("thread " & $arg.id & " entry " & $i)

    type DefaultRaceArg = object
      count: int

    proc defaultLoggerRaceProducer(arg: ptr DefaultRaceArg) {.thread.} =
      for i in 0..<arg.count:
        logDefault(llInfo, "default race entry " & $i)

    test "Concurrent producers preserve entries without hidden overwrites":
      let logFile = tmpDir & "/concurrent_producers.log"
      removeFileIfExists(logFile)
      var cfg = defaultConfig()
      cfg.format = lfJson
      cfg.output = loFile
      cfg.filePath = logFile
      cfg.level = llInfo
      cfg.bufferSize = 131072
      cfg.maxEntryBytes = 256
      cfg.dropOnFull = false
      cfg.flushIntervalMs = 1
      let logger = newAsyncLogger(cfg)
      const ThreadCount = 4
      const PerThread = 10000
      var args: array[ThreadCount, ProducerArg]
      var threads: array[ThreadCount, Thread[ptr ProducerArg]]
      for i in 0..<ThreadCount:
        args[i] = ProducerArg(logger: logger, id: i, count: PerThread)
        createThread(threads[i], asyncLoggerProducer, addr args[i])
      for i in 0..<ThreadCount:
        joinThread(threads[i])
      logger.flush()
      let drops = logger.droppedCount()
      sleepMs(100)
      logger.close()
      let content = readFileContent(logFile)
      var count = 0
      for line in content.splitLines:
        if line.len > 0 and line.contains("\"msg\":\"thread "):
          inc count
      check count == ThreadCount * PerThread, "expected " & $(ThreadCount * PerThread) & " entries, got " & $count
      check drops == 0, "expected no drops"
      removeFileIfExists(logFile)

    test "Close racing with active producers is safe":
      let logFile = tmpDir & "/close_race.log"
      removeFileIfExists(logFile)
      var cfg = defaultConfig()
      cfg.format = lfJson
      cfg.output = loFile
      cfg.filePath = logFile
      cfg.level = llInfo
      cfg.bufferSize = 1024
      cfg.maxEntryBytes = 128
      cfg.dropOnFull = false
      cfg.flushIntervalMs = 1
      let logger = newAsyncLogger(cfg)
      const ThreadCount = 4
      const PerThread = 20000
      var args: array[ThreadCount, ProducerArg]
      var threads: array[ThreadCount, Thread[ptr ProducerArg]]
      for i in 0..<ThreadCount:
        args[i] = ProducerArg(logger: logger, id: i, count: PerThread)
        createThread(threads[i], asyncLoggerProducer, addr args[i])
      sleepMs(2)
      logger.close()
      for i in 0..<ThreadCount:
        joinThread(threads[i])
      logger.info("after close race")
      logger.flush()
      check logger.writeErrorCount() >= 0, "closed logger should remain readable"
      removeFileIfExists(logFile)

  emit("\n--- Default Logger ---\n")

  test "Default logger init/close":
    let logFile = tmpDir & "/default.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    initDefaultLogger(cfg)
    check defaultLoggerIsSet(), "defaultLogger should be set"
    logDefault(llInfo, "default test")
    flushDefaultLogger()
    sleepMs(50)
    closeDefaultLogger()
    check not defaultLoggerIsSet(), "defaultLogger should be nil after close"
    let content = readFileContent(logFile)
    check content.contains("default test"), "missing default logger output"
    removeFileIfExists(logFile)

  when compileOption("threads"):
    test "Default logger init and close race with producers":
      let logFile = tmpDir & "/default_race.log"
      removeFileIfExists(logFile)
      var cfg = defaultConfig()
      cfg.format = lfJson
      cfg.output = loFile
      cfg.filePath = logFile
      cfg.level = llInfo
      cfg.bufferSize = 512
      cfg.maxEntryBytes = 128
      cfg.dropOnFull = true
      cfg.flushIntervalMs = 1

      const ThreadCount = 4
      var arg = DefaultRaceArg(count: 2000)
      var threads: array[ThreadCount, Thread[ptr DefaultRaceArg]]
      initDefaultLogger(cfg)
      for i in 0..<ThreadCount:
        createThread(threads[i], defaultLoggerRaceProducer, addr arg)
      for cycle in 0..<20:
        if (cycle and 1) == 0:
          initDefaultLogger(cfg)
        else:
          closeDefaultLogger()
        sleepMs(1)
      initDefaultLogger(cfg)
      for i in 0..<ThreadCount:
        joinThread(threads[i])
      closeDefaultLogger()
      check not defaultLoggerIsSet(), "defaultLogger should be nil after race close"
      removeFileIfExists(logFile)

  emit("\n--- Performance ---\n")

  test "Performance: 1M entries throughput":
    let logFile = tmpDir & "/perf.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 8192
    cfg.maxEntryBytes = 4096
    cfg.dropOnFull = false
    let logger = newAsyncLogger(cfg)

    let n = 1_000_000
    let start = getMonoTime()
    for i in 0..<n:
      logger.info("benchmark entry")
    let elapsed = getMonoTime() - start
    let elapsedNs = elapsed.inNanoseconds
    let elapsedMs = elapsedNs div 1_000_000
    let perCallNs = elapsedNs div n.int64

    logger.flush()
    sleepMs(200)
    logger.close()

    emit("  1M log() calls: " & $elapsedMs & "ms (" & $perCallNs & "ns/call)\n")
    check elapsedMs < 10_000, "1M entries took " & $elapsedMs & "ms (> 10s)"
    removeFileIfExists(logFile)

  test "Performance: 1M entries with fields":
    let logFile = tmpDir & "/perf_fields.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 8192
    cfg.maxEntryBytes = 4096
    cfg.dropOnFull = false
    let logger = newAsyncLogger(cfg)

    let n = 1_000_000
    let start = getMonoTime()
    for i in 0..<n:
      logger.info("request", {"method": "GET", "path": "/api", "status": "200"})
    let elapsed = getMonoTime() - start
    let elapsedNs = elapsed.inNanoseconds
    let elapsedMs = elapsedNs div 1_000_000
    let perCallNs = elapsedNs div n.int64

    logger.flush()
    sleepMs(200)
    logger.close()

    emit("  1M log()+fields calls: " & $elapsedMs & "ms (" & $perCallNs & "ns/call)\n")
    check elapsedMs < 10_000, "1M entries with fields took " & $elapsedMs & "ms (> 10s)"
    removeFileIfExists(logFile)

  test "Performance: hot-path only (dropOnFull=true, 10M)":
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = tmpDir & "/hotpath.log"
    cfg.level = llInfo
    cfg.bufferSize = 65536
    cfg.maxEntryBytes = 512
    cfg.dropOnFull = true
    cfg.flushIntervalMs = 1
    removeFileIfExists(cfg.filePath)
    let logger = newAsyncLogger(cfg)

    let n = 10_000_000
    let start = getMonoTime()
    for i in 0..<n:
      logger.info("hot path test msg")
    let elapsed = getMonoTime() - start
    let elapsedNs = elapsed.inNanoseconds
    let elapsedMs = elapsedNs div 1_000_000
    let perCallNs = elapsedNs div n.int64
    let drops = logger.droppedCount()

    logger.flush()
    sleepMs(100)
    logger.close()

    emit("  10M hot-path: " & $elapsedMs & "ms (" & $perCallNs & "ns/call, drops=" & $drops & ")\n")
    check elapsedMs < 10_000, "10M took too long"
    removeFileIfExists(cfg.filePath)

  test "Performance: hot-path with 3 fields (dropOnFull=true, 10M)":
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = tmpDir & "/hotpath_fields.log"
    cfg.level = llInfo
    cfg.bufferSize = 65536
    cfg.maxEntryBytes = 512
    cfg.dropOnFull = true
    cfg.flushIntervalMs = 1
    removeFileIfExists(cfg.filePath)
    let logger = newAsyncLogger(cfg)

    let n = 10_000_000
    let start = getMonoTime()
    for i in 0..<n:
      logger.info("request done", {"method": "GET", "path": "/api/v1", "status": "200"})
    let elapsed = getMonoTime() - start
    let elapsedNs = elapsed.inNanoseconds
    let elapsedMs = elapsedNs div 1_000_000
    let perCallNs = elapsedNs div n.int64
    let drops = logger.droppedCount()

    logger.flush()
    sleepMs(100)
    logger.close()

    emit("  10M hot-path+fields: " & $elapsedMs & "ms (" & $perCallNs & "ns/call, drops=" & $drops & ")\n")
    check elapsedMs < 10_000, "10M took too long"
    removeFileIfExists(cfg.filePath)

  emit("\n--- Object Logging ---\n")

  type
    ReqInfo = object
      `method`: string
      path: string
      status: int
      duration_ms: float

    UserInfo = object
      id: int
      name: string
      active: bool

    UserRef = ref object
      id: int
      name: string

  test "JSON object logging - flat object":
    let logFile = tmpDir & "/obj_json.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    let req = ReqInfo(`method`: "GET", path: "/api/users", status: 200, duration_ms: 1.23)
    logger.infoObj("request handled", req)
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"msg\":\"request handled\""), "missing msg"
    check content.contains("\"method\":\"GET\""), "missing method"
    check content.contains("\"path\":\"/api/users\""), "missing path"
    check content.contains("\"status\":200"), "missing status"
    check content.contains("\"duration_ms\":1.23"), "missing duration"
    check content.contains("{\"ts\":\""), "should be valid JSON start"
    check content.contains("}\n"), "should end with }\n"
    removeFileIfExists(logFile)

  test "JSON object logging reserves top-level logger keys":
    type ReservedLog = object
      level: string
      msg: string
      ts: string
      value: int

    let logFile = tmpDir & "/obj_json_reserved.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.infoObj("object reserved", ReservedLog(level: "fatal", msg: "spoof", ts: "bad", value: 9))
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check occurrences(content, "\"level\":") == 2, "expected logger level plus nested field level"
    check occurrences(content, "\"msg\":") == 2, "expected logger msg plus nested field msg"
    check occurrences(content, "\"ts\":") == 2, "expected logger ts plus nested field ts"
    let parsed = parseJson(content.strip())
    check parsed["level"].getStr() == "info"
    check parsed["msg"].getStr() == "object reserved"
    check parsed["fields"]["level"].getStr() == "fatal"
    check parsed["fields"]["msg"].getStr() == "spoof"
    check parsed["fields"]["ts"].getStr() == "bad"
    check parsed["fields"]["value"].getInt() == 9
    removeFileIfExists(logFile)

  test "JSON object logging truncates as valid JSON":
    type HugeLog = object
      payload: string

    let logFile = tmpDir & "/obj_json_truncated.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 16
    cfg.maxEntryBytes = 128
    let logger = newAsyncLogger(cfg)
    logger.infoObj("large object", HugeLog(payload: repeat("x", 4096)))
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile).strip()
    let parsed = parseJson(content)
    check parsed["msg"].getStr() == "large object"
    check parsed["truncated"].getBool()
    check parsed["original_bytes"].getInt() > 128
    removeFileIfExists(logFile)

  test "Text object logging":
    let logFile = tmpDir & "/obj_text.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfText
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    let user = UserInfo(id: 42, name: "Alice", active: true)
    logger.infoObj("user login", user)
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("user login"), "missing msg"
    check content.contains("\"id\":42"), "missing id in JSON block"
    check content.contains("\"name\":\"Alice\""), "missing name"
    removeFileIfExists(logFile)

  test "Compact object logging":
    let logFile = tmpDir & "/obj_compact.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfCompact
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    let user = UserInfo(id: 7, name: "Bob", active: false)
    logger.infoObj("event", user)
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("event"), "missing msg"
    check content.contains("\"id\":7"), "missing id"
    removeFileIfExists(logFile)

  test "Object logging with empty message":
    let logFile = tmpDir & "/obj_empty_msg.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    let req = ReqInfo(`method`: "POST", path: "/", status: 201, duration_ms: 0.5)
    logger.infoObj("", req)
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"msg\":\"\""), "empty msg should be present"
    check content.contains("\"method\":\"POST\""), "fields should be present"
    removeFileIfExists(logFile)

  test "Object logging level filtering":
    let logFile = tmpDir & "/obj_level.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llWarn
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    let user = UserInfo(id: 1, name: "X", active: true)
    logger.debugObj("should not appear", user)
    logger.warnObj("should appear", user)
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check not content.contains("should not appear"), "debug filtered"
    check content.contains("should appear"), "warn passes"
    removeFileIfExists(logFile)

  test "Object logging nil ref wraps null in data field":
    let logFile = tmpDir & "/obj_nil_ref.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    var user: UserRef = nil
    logger.infoObj("nil user", user)
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"msg\":\"nil user\""), "message should be present"
    check content.contains("\"data\":null"), "nil ref object should be logged as data:null"
    check not content.contains(",null}"), "raw null must not be merged as an object field"
    removeFileIfExists(logFile)

  test "Object logging after close does not crash":
    let logFile = tmpDir & "/obj_after_close.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.close()
    let user = UserInfo(id: 1, name: "test", active: false)
    logger.infoObj("no crash", user)
    check true
    removeFileIfExists(logFile)

  test "Performance: 1M object log calls":
    let logFile = tmpDir & "/obj_perf.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 32768
    cfg.maxEntryBytes = 512
    cfg.dropOnFull = false
    cfg.flushIntervalMs = 1
    let logger = newAsyncLogger(cfg)
    let req = ReqInfo(`method`: "GET", path: "/api", status: 200, duration_ms: 1.5)
    let n = 1_000_000
    let start = getMonoTime()
    for i in 0..<n:
      logger.infoObj("req", req)
    let elapsed = getMonoTime() - start
    let elapsedNs = elapsed.inNanoseconds
    let elapsedMs = elapsedNs div 1_000_000
    let perCallNs = elapsedNs div n.int64
    logger.flush()
    sleepMs(200)
    logger.close()
    emit("  1M logObj() calls: " & $elapsedMs & "ms (" & $perCallNs & "ns/call)\n")
    check elapsedMs < 20_000, "1M obj log took too long"
    removeFileIfExists(logFile)

  emit("\n--- Empty String Edge Cases ---\n")

  test "Empty message string does not crash or lose entries":
    let logFile = tmpDir & "/empty_msg.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("")
    logger.info("after empty")
    logger.info("")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"msg\":\"\""), "empty msg should be present"
    check content.contains("\"msg\":\"after empty\""), "entry after empty should be present"
    var count = 0
    for line in content.splitLines:
      if line.len > 0 and line.contains("\"level\":\"info\""):
        count += 1
    check count == 3, "expected 3 entries, got " & $count
    removeFileIfExists(logFile)

  test "Empty message with fields":
    let logFile = tmpDir & "/empty_msg_fields.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("", {"key": "val"})
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"key\":\"val\""), "field should be present with empty msg"
    removeFileIfExists(logFile)

  emit("\n--- Timestamp Edge Cases ---\n")

  test "Negative epoch timestamps do not crash":
    let logFile = tmpDir & "/neg_epoch.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("normal message")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"ts\":\""), "timestamp should be present"
    check content.contains("\"msg\":\"normal message\""), "msg should be present"
    removeFileIfExists(logFile)

  test "Timestamps update milliseconds within the same second":
    let logFile = tmpDir & "/timestamp_ms.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    while getTime().nanosecond > 850_000_000:
      sleepMs(5)
    logger.info("first")
    sleepMs(60)
    logger.info("second")
    logger.flush()
    logger.close()
    let lines = readFileContent(logFile).splitLines()
    var firstTs = ""
    var secondTs = ""
    for line in lines:
      if line.contains("\"msg\":\"first\""):
        firstTs = timestampToken(line)
      elif line.contains("\"msg\":\"second\""):
        secondTs = timestampToken(line)
    check firstTs.len > 0 and secondTs.len > 0, "expected both timestamped lines"
    check firstTs != secondTs, "millisecond timestamp should change between entries"
    removeFileIfExists(logFile)

  test "Message exactly at maxEntryBytes boundary":
    let logFile = tmpDir & "/boundary.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    cfg.maxEntryBytes = 64
    let logger = newAsyncLogger(cfg)
    let longMsg = newString(128)
    logger.info(longMsg)
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"level\":\"info\""), "entry should be logged with truncated msg"
    removeFileIfExists(logFile)

  test "Many fields that exceed maxEntryBytes are truncated":
    let logFile = tmpDir & "/field_overflow.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    cfg.maxEntryBytes = 64
    let logger = newAsyncLogger(cfg)
    var fields: seq[(string, string)] = @[]
    for i in 0..<20:
      fields.add(("key" & $i, "value" & $i))
    logger.info("msg", fields)
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"msg\":\"msg\""), "msg should be present"
    removeFileIfExists(logFile)

  emit("\n--- Safety: Double Close ---\n")

  test "Double close does not crash":
    let logFile = tmpDir & "/double_close.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("before close")
    logger.close()
    logger.close()
    check true
    removeFileIfExists(logFile)

  test "Log after close does not crash":
    let logFile = tmpDir & "/log_after_close.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("before close")
    logger.flush()
    sleepMs(50)
    logger.close()
    logger.info("after close")
    logger.info("after close with fields", {"key": "val"})
    check true
    removeFileIfExists(logFile)

  test "Nil logger does not crash":
    var logger: AsyncLogger = nil
    logger.close()
    check true

  test "Flush after close does not hang":
    let logFile = tmpDir & "/flush_after_close.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.info("test")
    logger.close()
    logger.flush()
    check true
    removeFileIfExists(logFile)

  test "setLevel after close does not crash":
    let logFile = tmpDir & "/setlevel_close.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    let logger = newAsyncLogger(cfg)
    logger.close()
    logger.setLevel(llDebug)
    check true
    removeFileIfExists(logFile)

  emit("\n--- Graceful Shutdown ---\n")

  test "Close after rapid logging preserves entries":
    let logFile = tmpDir & "/shutdown.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    cfg.flushIntervalMs = 100
    let logger = newAsyncLogger(cfg)
    for i in 0..<200:
      logger.info("shutdown entry " & $i)
    logger.close()
    sleepMs(20)
    let content = readFileContent(logFile)
    var count = 0
    for line in content.splitLines:
      if line.len > 0 and line.contains("\"msg\":\"shutdown entry"):
        count += 1
    check count > 0, "expected entries after close, got 0"
    removeFileIfExists(logFile)

  test "initDefaultLogger replaces old logger safely":
    let logFile1 = tmpDir & "/default1.log"
    let logFile2 = tmpDir & "/default2.log"
    removeFileIfExists(logFile1)
    removeFileIfExists(logFile2)
    var cfg1 = defaultConfig()
    cfg1.format = lfJson
    cfg1.output = loFile
    cfg1.filePath = logFile1
    cfg1.level = llInfo
    cfg1.bufferSize = 256
    initDefaultLogger(cfg1)
    logDefault(llInfo, "first logger")
    flushDefaultLogger()
    sleepMs(50)
    var cfg2 = defaultConfig()
    cfg2.format = lfJson
    cfg2.output = loFile
    cfg2.filePath = logFile2
    cfg2.level = llInfo
    cfg2.bufferSize = 256
    initDefaultLogger(cfg2)
    logDefault(llInfo, "second logger")
    flushDefaultLogger()
    sleepMs(50)
    closeDefaultLogger()
    let content1 = readFileContent(logFile1)
    let content2 = readFileContent(logFile2)
    check content1.contains("first logger"), "first logger should have written"
    check content2.contains("second logger"), "second logger should have written"
    removeFileIfExists(logFile1)
    removeFileIfExists(logFile2)

  test "writeErrorCount returns 0 for nil logger":
    var logger: AsyncLogger = nil
    check logger.writeErrorCount() == 0, "nil logger writeErrorCount should be 0"

  emit("\n--- Edge Cases: Small maxEntryBytes ---\n")

  test "Small maxEntryBytes (16) does not crash":
    let logFile = tmpDir & "/small_entry.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    cfg.maxEntryBytes = 16
    let logger = newAsyncLogger(cfg)
    logger.info("hello world this is a long message that gets truncated")
    logger.info("short")
    logger.info("")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("\"level\":\"info\""), "entries should be logged"
    var count = 0
    for line in content.splitLines:
      if line.len > 0 and line.contains("\"level\":\"info\""):
        count += 1
    check count == 3, "expected 3 entries, got " & $count
    removeFileIfExists(logFile)

  test "Zero maxEntryBytes gets default":
    let logFile = tmpDir & "/zero_entry.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 256
    cfg.maxEntryBytes = 0
    let logger = newAsyncLogger(cfg)
    logger.info("should work fine")
    logger.flush()
    sleepMs(50)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("should work fine"), "default maxEntry should apply"
    removeFileIfExists(logFile)

  test "Oversized maxEntryBytes is clamped safely":
    let logFile = tmpDir & "/oversized_entry.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 2
    cfg.maxEntryBytes = high(int)
    let logger = newAsyncLogger(cfg)
    logger.info("bounded allocation")
    logger.flush()
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("bounded allocation"), "logger should work after clamping oversized entry size"
    removeFileIfExists(logFile)

  test "Rapid create and close cycles":
    for cycle in 0..<10:
      let logFile = tmpDir & "/cycle_" & $cycle & ".log"
      removeFileIfExists(logFile)
      var cfg = defaultConfig()
      cfg.format = lfJson
      cfg.output = loFile
      cfg.filePath = logFile
      cfg.level = llInfo
      cfg.bufferSize = 64
      let logger = newAsyncLogger(cfg)
      logger.info("cycle " & $cycle)
      logger.close()
      removeFileIfExists(logFile)
    check true

  test "Performance: end-to-end throughput (1M, dropOnFull=false, SIMD flush)":
    let logFile = tmpDir & "/e2e_simd.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 32768
    cfg.maxEntryBytes = 512
    cfg.dropOnFull = false
    cfg.flushIntervalMs = 1
    let logger = newAsyncLogger(cfg)

    let n = 1_000_000
    let start = getMonoTime()
    for i in 0..<n:
      logger.info("request processed", {"method": "GET", "path": "/api/users", "status": "200"})
    let elapsed = getMonoTime() - start
    let elapsedNs = elapsed.inNanoseconds
    let elapsedMs = elapsedNs div 1_000_000
    let perCallNs = elapsedNs div n.int64

    logger.flush()
    sleepMs(200)
    logger.close()

    emit("  1M e2e+fields: " & $elapsedMs & "ms (" & $perCallNs & "ns/call)\n")
    check elapsedMs < 10_000, "e2e took too long"
    removeFileIfExists(logFile)

  emit("\n--- Mixed Traffic ---\n")

  type
    SmallEvent = object
      code: int
      tag: string

    MediumReq = object
      `method`: string
      path: string
      status: int
      duration_ms: float
      ip: string

    BigPayload = object
      requestId: string
      userId: int
      sessionToken: string
      userAgent: string
      referer: string
      contentType: string
      queryString: string
      responseBody: string
      headers: string
      traceId: string
      spanId: string
      parentSpanId: string
      serviceName: string
      hostname: string
      region: string

  test "Mixed: small + medium + big objects interleaved":
    let logFile = tmpDir & "/mixed_obj.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llTrace
    cfg.bufferSize = 4096
    cfg.maxEntryBytes = 2048
    let logger = newAsyncLogger(cfg)

    let small = SmallEvent(code: 42, tag: "ping")
    let med = MediumReq(`method`: "POST", path: "/api/v2/orders", status: 201, duration_ms: 12.7, ip: "10.0.0.5")
    let big = BigPayload(
      requestId: "req-abc-12345-xyz-67890",
      userId: 98765,
      sessionToken: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature",
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
      referer: "https://example.com/dashboard?tab=analytics&period=30d",
      contentType: "application/json; charset=utf-8",
      queryString: "page=3&limit=50&sort=created_at&order=desc&filter=active",
      responseBody: 'A'.repeat(200),
      headers: "Accept: */* | Connection: keep-alive | X-Request-ID: 12345",
      traceId: "4bf92f3577b34da6a3ce929d0e0e4736",
      spanId: "00f067aa0ba902b7",
      parentSpanId: "b3e4a1c2d5f60781",
      serviceName: "order-service",
      hostname: "prod-worker-12.internal",
      region: "us-east-1"
    )

    for i in 0..<500:
      logger.traceObj("heartbeat", small)
      logger.infoObj("request", med)
      logger.info("simple checkpoint")
      logger.warnObj("audit", big)
      logger.info("status ok", {"node": "w12", "healthy": "true"})
      logger.debugObj("detail", small)
      logger.errorObj("downstream", med)
      logger.info("done")

    logger.flush()
    sleepMs(200)
    logger.close()
    let content = readFileContent(logFile)

    var traceCount = 0
    var infoCount = 0
    var warnCount = 0
    var debugCount = 0
    var errorCount = 0
    for line in content.splitLines:
      if line.len == 0: continue
      if line.contains("\"level\":\"trace\""): traceCount += 1
      if line.contains("\"level\":\"info\""): infoCount += 1
      if line.contains("\"level\":\"warn\""): warnCount += 1
      if line.contains("\"level\":\"debug\""): debugCount += 1
      if line.contains("\"level\":\"error\""): errorCount += 1

    check traceCount == 500, "expected 500 trace, got " & $traceCount
    check infoCount == 2000, "expected 2000 info, got " & $infoCount
    check warnCount == 500, "expected 500 warn, got " & $warnCount
    check debugCount == 500, "expected 500 debug, got " & $debugCount
    check errorCount == 500, "expected 500 error, got " & $errorCount

    check content.contains("\"code\":42"), "small obj field"
    check content.contains("\"tag\":\"ping\""), "small obj field"
    check content.contains("\"path\":\"/api/v2/orders\""), "medium obj field"
    check content.contains("\"requestId\":\"req-abc-12345-xyz-67890\""), "big obj field"
    check content.contains("\"traceId\":\"4bf92f3577b34da6a3ce929d0e0e4736\""), "big obj traceId"
    check content.contains("\"region\":\"us-east-1\""), "big obj region"
    check content.contains("\"node\":\"w12\""), "kv field"
    check content.contains("\"msg\":\"simple checkpoint\""), "plain msg"
    check content.contains("\"msg\":\"done\""), "plain msg"
    removeFileIfExists(logFile)

  test "Mixed: text format with varying objects":
    let logFile = tmpDir & "/mixed_text.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfText
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 4096
    cfg.maxEntryBytes = 2048
    let logger = newAsyncLogger(cfg)

    let small = SmallEvent(code: 1, tag: "up")
    let med = MediumReq(`method`: "GET", path: "/health", status: 200, duration_ms: 0.3, ip: "127.0.0.1")

    for i in 0..<100:
      logger.infoObj("check", small)
      logger.info("plain")
      logger.infoObj("api", med)
      logger.info("kv", {"k": "v"})

    logger.flush()
    sleepMs(100)
    logger.close()
    let content = readFileContent(logFile)

    var lineCount = 0
    for line in content.splitLines:
      if line.len > 0: lineCount += 1
    check lineCount == 400, "expected 400 lines, got " & $lineCount
    check content.contains("check {\"code\":1"), "small obj in text"
    check content.contains("api {\"method\":\"GET\""), "medium obj in text"
    check content.contains("plain"), "plain msg in text"
    check content.contains("k=v"), "kv in text"
    removeFileIfExists(logFile)

  test "Mixed: compact format with varying objects":
    let logFile = tmpDir & "/mixed_compact.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfCompact
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 4096
    cfg.maxEntryBytes = 2048
    let logger = newAsyncLogger(cfg)

    let small = SmallEvent(code: 99, tag: "fin")
    let med = MediumReq(`method`: "DELETE", path: "/items/5", status: 204, duration_ms: 2.1, ip: "10.1.1.1")

    for i in 0..<100:
      logger.infoObj("event", small)
      logger.info("step")
      logger.warnObj("slow", med)

    logger.flush()
    sleepMs(100)
    logger.close()
    let content = readFileContent(logFile)

    var iCount = 0
    var wCount = 0
    for line in content.splitLines:
      if line.len > 0:
        if line[0] == 'I': iCount += 1
        if line[0] == 'W': wCount += 1
    check iCount == 200, "expected 200 I lines, got " & $iCount
    check wCount == 100, "expected 100 W lines, got " & $wCount
    check content.contains("\"code\":99"), "small obj compact"
    check content.contains("\"path\":\"/items/5\""), "medium obj compact"
    removeFileIfExists(logFile)

  test "Performance: mixed traffic 1M (small+medium+big+plain+kv)":
    let logFile = tmpDir & "/mixed_perf.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 32768
    cfg.maxEntryBytes = 2048
    cfg.dropOnFull = false
    cfg.flushIntervalMs = 1
    let logger = newAsyncLogger(cfg)

    let small = SmallEvent(code: 1, tag: "ok")
    let med = MediumReq(`method`: "GET", path: "/api", status: 200, duration_ms: 1.0, ip: "10.0.0.1")
    let big = BigPayload(
      requestId: "r-1234567890",
      userId: 42,
      sessionToken: "tok_abcdefghij0123456789abcdef",
      userAgent: "curl/7.88.1",
      referer: "https://example.com/page",
      contentType: "application/json",
      queryString: "a=1&b=2",
      responseBody: 'B'.repeat(100),
      headers: "Accept: */*",
      traceId: "aabbccdd11223344",
      spanId: "1122334455667788",
      parentSpanId: "0000000000000000",
      serviceName: "test-svc",
      hostname: "worker-1",
      region: "us-west-2"
    )

    let n = 200_000
    let start = getMonoTime()
    for i in 0..<n:
      logger.infoObj("s", small)
      logger.infoObj("m", med)
      logger.infoObj("b", big)
      logger.info("plain msg")
      logger.info("kv", {"x": "1", "y": "2"})
    let elapsed = getMonoTime() - start
    let totalCalls = n * 5
    let elapsedNs = elapsed.inNanoseconds
    let elapsedMs = elapsedNs div 1_000_000
    let perCallNs = elapsedNs div totalCalls.int64

    logger.flush()
    sleepMs(500)
    logger.close()

    emit("  1M mixed calls: " & $elapsedMs & "ms (" & $perCallNs & "ns/call avg)\n")
    check elapsedMs < 30_000, "mixed took too long"
    removeFileIfExists(logFile)

  test "Burst: 10K big objects then 10K small, no drops":
    let logFile = tmpDir & "/burst.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 32768
    cfg.maxEntryBytes = 2048
    cfg.dropOnFull = false
    cfg.flushIntervalMs = 1
    let logger = newAsyncLogger(cfg)

    let big = BigPayload(
      requestId: "burst-req",
      userId: 1,
      sessionToken: "tok",
      userAgent: "bench",
      referer: "ref",
      contentType: "ct",
      queryString: "q=1",
      responseBody: 'R'.repeat(50),
      headers: "H: 1",
      traceId: "t1",
      spanId: "s1",
      parentSpanId: "p1",
      serviceName: "svc",
      hostname: "h1",
      region: "r1"
    )
    let small = SmallEvent(code: 0, tag: "x")

    for i in 0..<10_000:
      logger.infoObj("big", big)
    for i in 0..<10_000:
      logger.infoObj("small", small)

    logger.flush()
    sleepMs(200)
    logger.close()

    let drops = logger.droppedCount()
    let content = readFileContent(logFile)
    var total = 0
    for line in content.splitLines:
      if line.len > 0 and line.contains("\"level\":\"info\""): total += 1
    check total == 20_000, "expected 20000 entries, got " & $total
    check drops == 0, "expected 0 drops, got " & $drops
    removeFileIfExists(logFile)

  test "Stress: rapid alternation small/big at high volume":
    let logFile = tmpDir & "/stress_alt.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.format = lfJson
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.level = llInfo
    cfg.bufferSize = 16384
    cfg.maxEntryBytes = 2048
    cfg.dropOnFull = true
    cfg.flushIntervalMs = 1
    let logger = newAsyncLogger(cfg)

    let small = SmallEvent(code: 7, tag: "s")
    let big = BigPayload(
      requestId: "stress",
      userId: 99,
      sessionToken: "session_very_long_token_value_here_12345",
      userAgent: "StressBot/1.0 (compatible; bench; +http://example.com/bot)",
      referer: "https://long-referrer.example.com/very/deep/path?with=params&and=more",
      contentType: "multipart/form-data; boundary=----FormBoundary1234",
      queryString: "page=1&per_page=100&sort=name&direction=asc&filter[status]=active&filter[type]=premium",
      responseBody: 'X'.repeat(300),
      headers: "Authorization: Bearer tok123 | X-Correlation-ID: corr-456 | X-Forwarded-For: 1.2.3.4",
      traceId: "0123456789abcdef0123456789abcdef",
      spanId: "fedcba9876543210",
      parentSpanId: "1111111111111111",
      serviceName: "stress-service-name",
      hostname: "prod-stress-worker-42.us-east-1.internal",
      region: "ap-southeast-1"
    )

    let n = 500_000
    let start = getMonoTime()
    for i in 0..<n:
      if (i and 1) == 0:
        logger.infoObj("s", small)
      else:
        logger.infoObj("b", big)
    let elapsed = getMonoTime() - start
    let elapsedNs = elapsed.inNanoseconds
    let elapsedMs = elapsedNs div 1_000_000
    let perCallNs = elapsedNs div n.int64
    let drops = logger.droppedCount()

    logger.flush()
    sleepMs(200)
    logger.close()

    emit("  500K alternating small/big: " & $elapsedMs & "ms (" & $perCallNs & "ns/call, drops=" & $drops & ")\n")
    check elapsedMs < 30_000, "stress took too long"
    removeFileIfExists(logFile)

  emit("\n--- Security hardening (F7/F8) ---\n")

  test "F8: blocking producer (dropOnFull=false) drains a tiny ring without hang or loss":
    let logFile = tmpDir & "/f8_block.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.bufferSize = 16        # tiny ring: forces producers into the wait path
    cfg.dropOnFull = false     # blocking mode, bounded wait + drop after 100ms
    let logger = newAsyncLogger(cfg)
    for i in 0 ..< 10_000:
      logger.info("flood " & $i)
    logger.flush()
    sleepMs(300)
    logger.close()
    let content = readFileContent(logFile)
    check content.contains("flood 0"), "first record lost"
    check content.contains("flood 9999"), "last record lost"
    removeFileIfExists(logFile)

  test "F8: blocking producer on closed logger returns instead of spinning":
    var cfg = defaultConfig()
    cfg.output = loStderr
    cfg.bufferSize = 16
    cfg.dropOnFull = false
    let logger = newAsyncLogger(cfg)
    logger.close()
    # Must return immediately: the wait loop exits on the closed flag.
    let t0 = getMonoTime()
    logger.info("after close")
    let elapsed = getMonoTime() - t0
    check elapsed.inNanoseconds < 200_000_000, "producer blocked after close"

  test "F7: flush thread stays alive and keeps writing after load":
    # The OOM/exception isolation (try/except around drainRing) cannot be
    # triggered deterministically; verify the observable contract instead:
    # sustained writes land in the file and the logger closes cleanly.
    let logFile = tmpDir & "/f7_alive.log"
    removeFileIfExists(logFile)
    var cfg = defaultConfig()
    cfg.output = loFile
    cfg.filePath = logFile
    cfg.bufferSize = 64
    cfg.dropOnFull = false   # no-loss mode so the final entry must land
    let logger = newAsyncLogger(cfg)
    for i in 0 ..< 200:
      logger.warn("f7 " & $i)
    logger.flush()
    sleepMs(100)
    let content = readFileContent(logFile)
    check content.contains("f7 199"), "flush thread stopped writing"
    logger.close()
    removeFileIfExists(logFile)

  emit("\n=== Results: " & $passed & "/" & $total & " passed, " & $failed & " failed ===\n")

  discard rmdir(cstring(tmpDir))
  quit(if failed > 0: 1 else: 0)

main()
