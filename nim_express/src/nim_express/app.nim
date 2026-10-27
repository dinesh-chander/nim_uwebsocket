## Main application for nim_express
## Optimized with route grouping and sync/async handler support
## Supports multi-threaded and multi-process modes for high throughput

import std/[asyncdispatch, tables, strutils, json, cpuinfo, atomics, sysrand, os, times]
import std/macros
when not defined(windows):
  import std/posix
import types, request, response, fast_hash, paged_buffer, offload
import http_clients
import nim_utils/helpers/simd_str

export types, request, response
export http_clients

const
  DefaultAsyncPumpIntervalMs = 1
  DefaultRestartStormWindowMs = 30_000
  AsyncPumpErrorReportIntervalMs = 5_000
  EmptyAsyncDispatcherMessage = "No handles or timers registered in dispatcher"
  ## Error message raised when the GCD backend runs off the macOS main thread.
  MacosGcdMainThreadError* =
    "macOS GCD backend must run on the process main thread; use runAuto/runThreaded fallback or scale with external process managers"

type
  ActiveAsyncRequest = object
    req: Request
    requestSeq: uint64
    socketKey: uint64

var correlationFallbackCounter: Atomic[uint64]
var clusterJitterFallbackCounter: Atomic[uint64]
when defined(singleThread):
  var asyncPumpPollErrorCount: int64
  var asyncPumpPollErrorSuppressed: int64
  var asyncPumpPollLastReportAtMs: int64
  var asyncPumpOwnerApp: ExpressApp
  var activeAsyncRequests: seq[ActiveAsyncRequest]
else:
  var asyncPumpPollErrorCount {.threadvar.}: int64
  var asyncPumpPollErrorSuppressed {.threadvar.}: int64
  var asyncPumpPollLastReportAtMs {.threadvar.}: int64
  var asyncPumpOwnerApp {.threadvar.}: ExpressApp
  var activeAsyncRequests {.threadvar.}: seq[ActiveAsyncRequest]

## Generate a fallback correlation id from a tick counter and epoch micros.
proc buildFallbackCorrelationId*(): string {.inline.} =
  let tick = correlationFallbackCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
  let micros = uint64(getCachedEpochMicros())
  result = newStringOfCap(32)
  const hexChars = "0123456789ABCDEF"
  for i in countdown(15, 0):
    result.add hexChars[int((micros shr (i * 4)) and 0xF)]
  for i in countdown(15, 0):
    result.add hexChars[int((tick shr (i * 4)) and 0xF)]

proc emitSafeErrorHook(app: ExpressApp, message: string) {.inline.} =
  if app == nil or app.errorHook == nil:
    return
  try:
    app.errorHook(message)
  except CatchableError:
    discard

proc reportHookFailure(app: ExpressApp, hookName: string, err: ref CatchableError) {.inline.} =
  if app == nil:
    return
  app.emitSafeErrorHook("hook=" & hookName & " error=" & err.msg)

## Emit an ``InspectorEvent`` to the app's inspector hook if one is installed.
proc emitInspectorEvent*(app: ExpressApp, event: InspectorEvent) {.inline.} =
  if app == nil or app.inspectorHook == nil:
    return
  try:
    app.inspectorHook(event)
  except CatchableError as err:
    app.emitSafeErrorHook("hook=inspectorHook error=" & err.msg)

## Install the inspector hook that receives ``InspectorEvent`` notifications.
proc onInspector*(app: ExpressApp, hook: InspectorHook) =
  if app == nil:
    return
  app.inspectorHook = hook

## Build a ``PluginDefinition`` from an id, dependencies, config, and hooks.
proc pluginDef*(
  id: string,
  dependsOn: seq[string] = @[],
  config: JsonNode = nil,
  initHook: PluginInitHook = nil,
  shutdownHook: PluginShutdownHook = nil
): PluginDefinition =
  result.id = id
  result.dependsOn = dependsOn
  result.config =
    if config.isNil:
      newJNull()
    else:
      config
  result.initHook = initHook
  result.shutdownHook = shutdownHook

proc normalizePluginId(id: string): string {.inline.} =
  id.strip().toLowerAscii()

## Register a plugin before ``listen`` starts. Returns ``false`` on invalid or duplicate ids.
proc registerPlugin*(app: ExpressApp, plugin: PluginDefinition): bool =
  if app == nil:
    return false
  if app.listenStarted:
    app.emitSafeErrorHook("plugin registration rejected after listen start: " & plugin.id)
    return false
  let normalizedId = normalizePluginId(plugin.id)
  if normalizedId.len == 0:
    app.emitSafeErrorHook("plugin registration rejected: empty id")
    return false
  for existing in app.plugins:
    if normalizePluginId(existing.id) == normalizedId:
      app.emitSafeErrorHook("plugin registration rejected: duplicate id=" & normalizedId)
      return false
  var normalized = plugin
  normalized.id = normalizedId
  var deps: seq[string] = @[]
  for dep in plugin.dependsOn:
    let depId = normalizePluginId(dep)
    if depId.len > 0 and depId != normalizedId:
      deps.add(depId)
  normalized.dependsOn = deps
  if normalized.config.isNil:
    normalized.config = newJNull()
  app.plugins.add(normalized)
  true

proc resolvePluginInitOrder(app: ExpressApp, order: var seq[int], reason: var string): bool =
  order.setLen(0)
  reason = ""
  if app == nil:
    return false
  let n = app.plugins.len
  if n == 0:
    return true

  var indexById = initTable[string, int]()
  for i in 0 ..< n:
    let id = normalizePluginId(app.plugins[i].id)
    if id.len == 0:
      reason = "plugin id must not be empty"
      return false
    if indexById.hasKey(id):
      reason = "duplicate plugin id: " & id
      return false
    indexById[id] = i

  var indegree = newSeq[int](n)
  var edges = newSeq[seq[int]](n)
  for i in 0 ..< n:
    for dep in app.plugins[i].dependsOn:
      if dep.len == 0:
        continue
      if not indexById.hasKey(dep):
        reason = "missing dependency: " & dep & " for plugin " & app.plugins[i].id
        return false
      let depIdx = indexById[dep]
      edges[depIdx].add(i)
      inc indegree[i]

  var queue: seq[int] = @[]
  for i in 0 ..< n:
    if indegree[i] == 0:
      queue.add(i)

  var head = 0
  while head < queue.len:
    let cur = queue[head]
    inc head
    order.add(cur)
    for nxt in edges[cur]:
      dec indegree[nxt]
      if indegree[nxt] == 0:
        queue.add(nxt)

  if order.len != n:
    reason = "plugin dependency cycle detected"
    return false
  true

proc unwindInitializedPlugins(app: ExpressApp, initializedOrder: seq[int]) =
  if app == nil:
    return
  if initializedOrder.len == 0:
    return
  for i in countdown(initializedOrder.len - 1, 0):
    let idx = initializedOrder[i]
    if idx < 0 or idx >= app.plugins.len:
      continue
    let plugin = app.plugins[idx]
    if plugin.shutdownHook == nil:
      continue
    try:
      plugin.shutdownHook()
    except CatchableError as err:
      app.emitSafeErrorHook("plugin init unwind failed: " & plugin.id & " error=" & err.msg)

## Initialize registered plugins in dependency order. Returns ``false`` on failure.
proc initializePlugins*(app: ExpressApp): bool =
  if app == nil:
    return false
  if app.pluginsInitialized:
    return true
  if app.plugins.len == 0:
    app.pluginsInitialized = true
    return true

  var order: seq[int] = @[]
  var reason = ""
  if not app.resolvePluginInitOrder(order, reason):
    app.pluginInitFailedReason = reason
    app.emitSafeErrorHook("plugin initialization failed: " & reason)
    return false

  var initializedOrder: seq[int] = @[]
  for idx in order:
    let plugin = app.plugins[idx]
    if plugin.initHook == nil:
      initializedOrder.add(idx)
      continue
    try:
      if not plugin.initHook():
        app.pluginInitFailedReason = "plugin init returned false: " & plugin.id
        app.emitSafeErrorHook(app.pluginInitFailedReason)
        app.unwindInitializedPlugins(initializedOrder)
        return false
      initializedOrder.add(idx)
    except CatchableError as err:
      app.pluginInitFailedReason = "plugin init raised for " & plugin.id & ": " & err.msg
      app.emitSafeErrorHook(app.pluginInitFailedReason)
      app.unwindInitializedPlugins(initializedOrder)
      return false

  app.pluginInitOrder = order
  app.pluginsInitialized = true
  app.pluginInitFailedReason = ""
  true

## Run plugin shutdown hooks in reverse initialization order.
proc shutdownPlugins*(app: ExpressApp) =
  if app == nil or not app.pluginsInitialized:
    return
  for i in countdown(app.pluginInitOrder.len - 1, 0):
    let idx = app.pluginInitOrder[i]
    if idx < 0 or idx >= app.plugins.len:
      continue
    let plugin = app.plugins[idx]
    if plugin.shutdownHook == nil:
      continue
    try:
      plugin.shutdownHook()
    except CatchableError as err:
      app.emitSafeErrorHook("plugin shutdown hook failed: " & plugin.id & " error=" & err.msg)
  app.pluginsInitialized = false

## Add an advice hook that runs before route matching and can short-circuit.
proc onBeforeRouteMatchAdvice*(app: ExpressApp, hook: BeforeRouteMatchAdviceHook) =
  if app == nil or hook == nil:
    return
  app.beforeRouteMatchAdvices.add(hook)
  app.hasBeforeRouteMatchAdvice = true

## Add an advice hook that runs after route match and before the handler.
proc onBeforeHandlerAdvice*(app: ExpressApp, hook: BeforeHandlerAdviceHook) =
  if app == nil or hook == nil:
    return
  app.beforeHandlerAdvices.add(hook)
  app.hasBeforeHandlerAdvice = true

## Add an advice hook that runs after the route handler completes.
proc onAfterHandlerAdvice*(app: ExpressApp, hook: AfterHandlerAdviceHook) =
  if app == nil or hook == nil:
    return
  app.afterHandlerAdvices.add(hook)
  app.hasAfterHandlerAdvice = true

## Add an advice hook that observes handler and middleware errors.
proc onErrorAdvice*(app: ExpressApp, hook: ErrorAdviceHook) =
  if app == nil or hook == nil:
    return
  app.errorAdvices.add(hook)
  app.hasErrorAdvices = true

proc runBeforeRouteMatchAdvices(app: ExpressApp, req: Request, res: Response): bool =
  if app == nil or not app.hasBeforeRouteMatchAdvice:
    return true
  for hook in app.beforeRouteMatchAdvices:
    if hook == nil:
      continue
    try:
      if not hook(req, res):
        return false
    except CatchableError as err:
      app.emitSafeErrorHook("beforeRouteMatch advice failed: " & err.msg)
      return false
  true

proc runBeforeHandlerAdvices(app: ExpressApp, req: Request, res: Response, routePattern: string): bool =
  if app == nil or not app.hasBeforeHandlerAdvice:
    return true
  for hook in app.beforeHandlerAdvices:
    if hook == nil:
      continue
    try:
      if not hook(req, res, routePattern):
        return false
    except CatchableError as err:
      app.emitSafeErrorHook("beforeHandler advice failed: " & err.msg)
      return false
  true

proc runAfterHandlerAdvices(app: ExpressApp, req: Request, res: Response) =
  if app == nil or not app.hasAfterHandlerAdvice:
    return
  for hook in app.afterHandlerAdvices:
    if hook == nil:
      continue
    try:
      hook(req, res)
    except CatchableError as err:
      app.emitSafeErrorHook("afterHandler advice failed: " & err.msg)

proc runErrorAdvices(app: ExpressApp, req: Request, res: Response, phase: string, message: string) =
  if app == nil:
    return
  app.emitInspectorEvent(InspectorEvent(
    kind: iekHandlerError,
    phase: phase,
    path: if req != nil: $req.path else: "",
    message: message,
    statusCode: if res != nil: res.statusCode else: 500,
    correlationId: if req != nil: req.correlationId else: "",
    remoteIp: ""
  ))
  if not app.hasErrorAdvices:
    return
  for hook in app.errorAdvices:
    if hook == nil:
      continue
    try:
      hook(req, res, phase, message)
    except CatchableError as err:
      app.emitSafeErrorHook("error advice failed: " & err.msg)

proc currentEpochMsForApp(): int64 {.inline.} =
  let cached = getCachedEpochMs()
  if cached > 0:
    cached
  else:
    int64(epochTime() * 1000.0)

## Count an async pump poll failure and report a throttled summary to the error hook.
proc recordAsyncPumpPollFailure*(app: ExpressApp, errMessage: string) =
  inc asyncPumpPollErrorCount
  let nowMs = currentEpochMsForApp()
  if nowMs - asyncPumpPollLastReportAtMs >= AsyncPumpErrorReportIntervalMs:
    let suppressed = asyncPumpPollErrorSuppressed
    asyncPumpPollErrorSuppressed = 0'i64
    asyncPumpPollLastReportAtMs = nowMs
    var msg = "class=async_pump_poll_failure count=" & $asyncPumpPollErrorCount
    if suppressed > 0:
      msg.add(" suppressed=" & $suppressed)
    if errMessage.len > 0:
      msg.add(" error=" & errMessage)
    app.emitSafeErrorHook(msg)
  else:
    inc asyncPumpPollErrorSuppressed

## Total async pump poll failures recorded so far.
proc asyncPumpPollFailureCount*(): int64 {.inline.} =
  asyncPumpPollErrorCount

## Reset async pump poll failure counters. For tests.
proc resetAsyncPumpPollTelemetryForTest*() =
  asyncPumpPollErrorCount = 0'i64
  asyncPumpPollErrorSuppressed = 0'i64
  asyncPumpPollLastReportAtMs = 0'i64

proc runAsyncPumpPollNow() {.gcsafe.} =
  try:
    asyncdispatch.poll(0)
  except CatchableError as err:
    if err.msg.contains(EmptyAsyncDispatcherMessage):
      return
    raise

proc runAsyncPumpTick() =
  let app = asyncPumpOwnerApp
  if app == nil:
    return
  try:
    runAsyncPumpPollNow()
    if app.server != nil:
      app.server.flushPendingWrites()
  except CatchableError as err:
    app.recordAsyncPumpPollFailure(err.msg)

when defined(macosx) and compileOption("threads"):
  proc flushAsyncPumpPendingWrites() {.gcsafe.} =
    let app = asyncPumpOwnerApp
    if app == nil or app.server == nil:
      return
    {.cast(gcsafe).}:
      app.server.flushPendingWrites()

  proc runAsyncPumpTickDeferred() {.gcsafe.} =
    try:
      runAsyncPumpPollNow()
      flushAsyncPumpPendingWrites()
    except CatchableError:
      inc asyncPumpPollErrorCount

  proc asyncPumpWakeWorker(appPtr: pointer) {.thread.} =
    let app = cast[ExpressApp](appPtr)
    while app != nil and app.asyncPumpWakeThreadRunning.load(moAcquire):
      sleep(max(1, app.asyncPumpIntervalMs))
      if app == nil or not app.asyncPumpWakeThreadRunning.load(moAcquire):
        break
      let server = app.server
      if server != nil:
        server.queueDeferredPreFromAnyThread(runAsyncPumpTickDeferred)

  proc startMacosAsyncPumpWakeThread(app: ExpressApp) =
    if app == nil or not app.asyncPumpInstalled or app.asyncPumpWakeThreadStarted:
      return
    app.asyncPumpWakeThreadRunning.store(true, moRelease)
    app.asyncPumpWakeThreadStarted = true
    createThread(app.asyncPumpWakeThread, asyncPumpWakeWorker, cast[pointer](app))

  proc stopMacosAsyncPumpWakeThread(app: ExpressApp) =
    if app == nil or not app.asyncPumpWakeThreadStarted:
      return
    app.asyncPumpWakeThreadRunning.store(false, moRelease)
    joinThread(app.asyncPumpWakeThread)
    app.asyncPumpWakeThreadStarted = false

when defined(macosx) and defined(LIBUS_USE_GCD):
  proc pthread_main_np(): cint {.importc, header: "<pthread.h>".}

## Raise ``ValueError`` with ``MacosGcdMainThreadError`` if not on the macOS main thread.
proc assertMacosGcdMainThread*(operation: string) =
  ## The uSockets GCD backend is process-main-thread bound. Starting it from a
  ## spawned Nim thread can leave timers and socket callbacks stranded on macOS.
  when defined(macosx) and defined(LIBUS_USE_GCD):
    if pthread_main_np() == 0.cint:
      raise newException(ValueError, operation & ": " & MacosGcdMainThreadError)
  else:
    discard operation

when defined(linux):
  const LinuxCpuSetWords = 16
  const LinuxCpuSetWordBits = sizeof(culong) * 8

  type LinuxCpuSet = object
    bits: array[LinuxCpuSetWords, culong]

  # Note: use `pointer` (C void*) for the mask so the generated C matches
  # sched.h's `const cpu_set_t *` on GCC 14+ (where incompatible pointer
  # types are hard errors, not warnings).
  proc sched_setaffinity(pid: Pid, cpusetsize: csize_t, mask: pointer): cint
    {.importc, header: "<sched.h>".}

  proc parseCpuList(cpuList: string): seq[int] =
    for tokenRaw in cpuList.split(','):
      let token = tokenRaw.strip()
      if token.len == 0:
        continue
      let dash = token.find('-')
      if dash > 0 and dash < token.len - 1:
        try:
          var startCpu = parseInt(token[0 ..< dash])
          var endCpu = parseInt(token[dash + 1 .. ^1])
          if endCpu < startCpu:
            swap(startCpu, endCpu)
          for cpu in startCpu..endCpu:
            if cpu >= 0:
              result.add(cpu)
        except ValueError:
          discard
      else:
        try:
          let cpu = parseInt(token)
          if cpu >= 0:
            result.add(cpu)
        except ValueError:
          discard

  proc cpusetAllowedCpuCount(): int =
    try:
      let status = readFile("/proc/self/status")
      for line in status.splitLines():
        if line.startsWith("Cpus_allowed_list:"):
          let cpuList = line.split(':', maxsplit = 1)[1].strip()
          return parseCpuList(cpuList).len
    except OSError:
      discard
    0

  proc applyLinuxWorkerAffinity(workerId: int): bool =
    let cpuListEnv = getEnv("NIM_EXPRESS_CPU_LIST", "").strip()
    if cpuListEnv.len == 0:
      return false
    let cpus = parseCpuList(cpuListEnv)
    if cpus.len == 0:
      return false
    let cpu = cpus[workerId mod cpus.len]
    if cpu < 0:
      return false
    let maxCpu = LinuxCpuSetWords * LinuxCpuSetWordBits
    if cpu >= maxCpu:
      return false
    var mask: LinuxCpuSet
    let wordIdx = cpu div LinuxCpuSetWordBits
    let bitIdx = cpu mod LinuxCpuSetWordBits
    mask.bits[wordIdx] = 1.culong shl bitIdx
    sched_setaffinity(0.Pid, sizeof(mask).csize_t, cast[pointer](addr mask)) == 0

# Default worker count: 40% of processors (minimum 1), unless Linux throughput profile is enabled.
## Default worker process count: 40% of processors (min 1); cpuset size on Linux throughput profile.
proc defaultWorkerCount*(): int =
  let processorCount = max(1, countProcessors())
  let baseline = max(1, (processorCount * 40) div 100)
  when defined(linux):
    let profile = getEnv("NIM_EXPRESS_PROFILE", "").toLowerAscii()
    if profile == "linux-throughput":
      let cpusetCount = cpusetAllowedCpuCount()
      if cpusetCount > 0:
        return cpusetCount
      return processorCount
  baseline

## Default worker thread count: 1 on macOS GCD, otherwise ``defaultWorkerCount``.
proc defaultThreadCount*(): int =
  when defined(macosx) and defined(LIBUS_USE_GCD):
    1
  else:
    defaultWorkerCount()

## False on the macOS GCD backend, which is main-thread bound; true elsewhere.
proc supportsMultiThreading*(): bool =
  when defined(macosx) and defined(LIBUS_USE_GCD):
    false
  else:
    true

# Route pattern parsing - done once at startup
proc parsePattern(pattern: string): seq[string] =
  var estimated = 0
  for c in pattern:
    if c == ':':
      inc estimated
  result = newSeqOfCap[string](estimated)
  var i = 0
  while i < pattern.len:
    if pattern[i] == ':':
      inc i
      var paramName = ""
      while i < pattern.len and pattern[i] notin {'/', '?', '#'}:
        paramName.add(pattern[i])
        inc i
      result.add(paramName)
    else:
      inc i

proc countPathSegments(path: string): int {.inline.} =
  var inSeg = false
  for c in path:
    if c == '?' or c == '#':
      break
    if c == '/':
      inSeg = false
    elif not inSeg:
      inSeg = true
      inc result

proc findFirstLiteralSegment(pattern: string): string =
  var i = 0
  while i < pattern.len and pattern[i] == '/':
    inc i
  if i >= pattern.len or pattern[i] == '?' or pattern[i] == '#':
    return ""
  let start = i
  while i < pattern.len and pattern[i] notin {'/', '?', '#'}:
    inc i
  let seg = pattern[start..<i]
  if seg.len > 0 and seg[0] != ':' and seg[0] != '*':
    return seg
  ""

proc compileRouteMeta(
  pattern: string
): tuple[staticPrefix: string, firstLiteralSegment: string, minSegmentCount: int16, maxSegmentCount: int16] =
  let wildcardPos = pattern.find('*')
  let dynamicPos = pattern.find(':')
  var staticEnd = pattern.len
  if wildcardPos >= 0:
    staticEnd = min(staticEnd, wildcardPos)
  if dynamicPos >= 0:
    staticEnd = min(staticEnd, dynamicPos)
  result.staticPrefix =
    if staticEnd > 0:
      pattern[0..<staticEnd]
    else:
      ""
  result.firstLiteralSegment = findFirstLiteralSegment(pattern)
  if wildcardPos >= 0:
    let beforeWildcard = pattern[0..<wildcardPos]
    result.minSegmentCount = int16(countPathSegments(beforeWildcard))
    result.maxSegmentCount = -1'i16
  else:
    let segCount = int16(countPathSegments(pattern))
    result.minSegmentCount = segCount
    result.maxSegmentCount = segCount

proc routePrefixBucketKey(pathOrPrefix: string): int16 {.inline.} =
  var i = 0
  while i < pathOrPrefix.len:
    let c = pathOrPrefix[i]
    if c == '?' or c == '#':
      break
    if c != '/':
      return int16(ord(c))
    inc i
  -1'i16

proc analyzePathSegments(path: string, segmentCount: var int, firstSegStart: var int, firstSegLen: var int) {.inline.} =
  segmentCount = 0
  firstSegStart = -1
  firstSegLen = 0
  var inSeg = false
  var segStart = 0
  var i = 0
  while i < path.len:
    let c = path[i]
    if c == '?' or c == '#':
      break
    if c == '/':
      if inSeg:
        if firstSegStart < 0:
          firstSegStart = segStart
          firstSegLen = i - segStart
        inSeg = false
      inc i
      continue
    if not inSeg:
      inSeg = true
      segStart = i
      inc segmentCount
    inc i
  if inSeg and firstSegStart < 0:
    firstSegStart = segStart
    firstSegLen = i - segStart

proc sliceEquals(path: string, startPos: int, segLen: int, value: string): bool {.inline.} =
  if segLen != value.len or startPos < 0:
    return false
  if segLen == 0:
    return true
  simdStrEquals(unsafeAddr path[startPos], unsafeAddr value[0], segLen)

proc routeFastReject(
  route: Route,
  path: string,
  pathSegCount: int,
  firstSegStart: int,
  firstSegLen: int
): bool {.inline.} =
  if route.staticPrefix.len > 0 and
      (path.len < route.staticPrefix.len or
       not simdStrEquals(unsafeAddr path[0], unsafeAddr route.staticPrefix[0],
                         route.staticPrefix.len)):
    return true
  if route.maxSegmentCount >= 0:
    if pathSegCount != route.maxSegmentCount.int:
      return true
  elif pathSegCount < route.minSegmentCount.int:
    return true
  if route.firstLiteralSegment.len > 0:
    if firstSegStart < 0:
      return true
    if not sliceEquals(path, firstSegStart, firstSegLen, route.firstLiteralSegment):
      return true
  false

# Optimized route matching - minimal allocations
proc matchRoutePattern(pattern: string, path: string): bool {.inline.} =
  var pi = 0
  var xi = 0

  if pi < pattern.len and pattern[pi] == '/': inc pi
  if xi < path.len and path[xi] == '/': inc xi

  while pi < pattern.len and xi < path.len:
    if pattern[pi] == ':':
      inc pi
      while pi < pattern.len and pattern[pi] != '/':
        inc pi
      while xi < path.len and path[xi] != '/':
        inc xi
      if pi < pattern.len and pattern[pi] == '/': inc pi
      if xi < path.len and path[xi] == '/': inc xi
    elif pattern[pi] == '*':
      return true
    elif pattern[pi] == path[xi]:
      inc pi
      inc xi
    else:
      return false

  while pi < pattern.len and pattern[pi] == '/': inc pi
  while xi < path.len and path[xi] == '/': inc xi
  pi >= pattern.len and xi >= path.len

proc materializeParams(pattern: string, paramNames: seq[string], path: string, params: var FastMap[string]) {.inline.} =
  params.clear()
  var pi = 0
  var xi = 0
  var paramIdx = 0

  if pi < pattern.len and pattern[pi] == '/': inc pi
  if xi < path.len and path[xi] == '/': inc xi

  while pi < pattern.len and xi < path.len:
    if pattern[pi] == ':':
      inc pi
      while pi < pattern.len and pattern[pi] != '/':
        inc pi
      let valueStart = xi
      while xi < path.len and path[xi] != '/':
        inc xi
      if paramIdx < paramNames.len:
        params[paramNames[paramIdx]] = path[valueStart..<xi]
      inc paramIdx
      if pi < pattern.len and pattern[pi] == '/': inc pi
      if xi < path.len and path[xi] == '/': inc xi
    elif pattern[pi] == '*':
      params["*"] = path[xi..^1]
      return
    else:
      inc pi
      inc xi

proc matchRoute(pattern: string, paramNames: seq[string], path: string, params: var FastMap[string]): bool {.inline, used.} =
  if not matchRoutePattern(pattern, path):
    return false
  materializeParams(pattern, paramNames, path, params)
  true

# ExpressApp methods
## Apply runtime tunables from ``NIM_EXPRESS_*`` environment variables.
proc applyRuntimeTunablesFromEnv*(app: ExpressApp) {.gcsafe.}
## Snapshot server counters used by perf and observability tooling.
proc optimizationMetrics*(app: ExpressApp): FastMap[int64]
## Enable or disable trust-proxy handling of client remote addresses.
proc setTrustProxy*(app: ExpressApp, enabled: bool)
## Set how many trusted proxy hops are counted from the connection.
proc setTrustedProxyHops*(app: ExpressApp, hops: int)
## Set a CSV allowlist of trusted proxy addresses.
proc setTrustedProxyAllowlist*(app: ExpressApp, allowlistCsv: string)

## Install a raw HTTP handler that bypasses routing and middleware.
proc useRawHandler*(app: ExpressApp, handler: HttpHandler) =
  app.server.rawHandler = handler

## Create a new Express-style application instance.
## Returns an ``ExpressApp`` with default configuration.
## Call ``loadAndApplyAppEnvConfig`` to load config from JSON/env vars.
proc newExpressApp*(): ExpressApp =
  new(result)
  result.server = newHttpServer()
  result.router = newRouter()
  result.middlewares = @[]
  result.syncMiddlewares = @[]
  result.orderedMiddlewares = @[]
  result.compiledBaseMiddlewares = @[]
  result.compiledBaseSyncMiddlewares = @[]
  result.settings = newFastMap[string]()
  discard result.settings.reserve(16)
  discard result.settings.put("views", absolutePath("views"))
  discard result.settings.put("view_ext", "")
  discard result.settings.put("view_cache", "true")
  discard result.settings.put("trust_proxy_hops", "0")
  discard result.settings.put("trust_proxy_allowlist", "")
  discard result.settings.put("static_fallback_max_bytes", "8388608")
  discard result.settings.put("static_fallback_oversize_status", "413")
  result.asyncPumpIntervalMs = DefaultAsyncPumpIntervalMs
  result.maxInflightAsyncRequests = 4096
  result.inflightAsyncRequests.store(0'i64, moRelaxed)
  result.contextPoolPrewarm = 64
  result.generateCorrelationIds = true
  result.startupWarmupHooks = @[]
  result.startupWarmupCursor = 0
  result.startupWarmupDone = false
  result.plugins = @[]
  result.pluginInitOrder = @[]
  result.pluginsInitialized = false
  result.pluginInitFailedReason = ""
  result.wsUpgradeValidator = nil
  result.wsAllowedOrigins = @[]
  result.wsAllowedPaths = @[]
  result.beforeRouteMatchAdvices = @[]
  result.beforeHandlerAdvices = @[]
  result.afterHandlerAdvices = @[]
  result.errorAdvices = @[]
  result.trustProxy = false
  result.allowedHosts = @[]
  result.listenStarted = false
  result.routeManifestOnStartup = false
  result.compressionPolicy = CompressionPolicyConfig(
    enabled: true,
    minBytes: 860,
    minSavingsRatio: 0.05,
    level: 6,
    memLevel: 8,
    windowBits: 15,
    serverNoContextTakeover: false,
    clientNoContextTakeover: false,
    resetContextEveryNMessages: 0,
    maxCompressMicrosPerSecond: 0,
    disableWhenBackpressureAboveBytes: 0,
    disableForBinary: false,
    disableForText: false,
    offloadThresholdBytes: 16 * 1024
  )
  result.applyRuntimeTunablesFromEnv()

## Set the max concurrent in-flight async requests; 0 disables the limit.
proc setMaxInflightAsyncRequests*(app: ExpressApp, maxRequests: int) =
  app.maxInflightAsyncRequests = max(0, maxRequests)

## Current max in-flight async request limit.
proc getMaxInflightAsyncRequests*(app: ExpressApp): int {.inline.} =
  app.maxInflightAsyncRequests

## Current number of in-flight async requests.
proc getInflightAsyncRequests*(app: ExpressApp): int {.inline.} =
  int(app.inflightAsyncRequests.load(moRelaxed))

## Set the request/response context pool entries to prewarm at startup.
proc setContextPoolPrewarm*(app: ExpressApp, entries: int) =
  app.contextPoolPrewarm = max(0, entries)

## Current context pool prewarm entry count.
proc getContextPoolPrewarm*(app: ExpressApp): int {.inline.} =
  app.contextPoolPrewarm

## Set the async pump poll interval in milliseconds (min 1).
proc setAsyncPumpIntervalMs*(app: ExpressApp, intervalMs: int) =
  app.asyncPumpIntervalMs = max(1, intervalMs)

## Current async pump poll interval in milliseconds.
proc getAsyncPumpIntervalMs*(app: ExpressApp): int {.inline.} =
  app.asyncPumpIntervalMs

## Set the max request body size in bytes; non-positive values are ignored.
proc setMaxBodySize*(app: ExpressApp, bytes: int) =
  if bytes > 0:
    app.server.options.maxBodySize = bytes

## Set the per-request memory budget in bytes.
proc setMaxRequestMemory*(app: ExpressApp, bytes: int) =
  app.server.setMaxRequestMemory(bytes)

## Set the idle connection timeout in seconds.
proc setConnectionTimeout*(app: ExpressApp, seconds: int) =
  app.server.options.connectionTimeout = max(0, seconds)

## Set the max concurrent connections; non-positive values are ignored.
proc setMaxConnections*(app: ExpressApp, maxConnections: int) =
  if maxConnections > 0:
    app.server.options.maxConnections = maxConnections

## Set the max pending unread bytes allowed per socket.
proc setMaxPendingBytesPerSocket*(app: ExpressApp, bytes: int) =
  app.server.setMaxPendingBytesPerSocket(bytes)

## Set the WebSocket keepalive ping interval in milliseconds.
proc setWsKeepaliveInterval*(app: ExpressApp, intervalMs: int) =
  app.server.options.wsKeepaliveInterval = max(0, intervalMs)

## Set the WebSocket idle timeout in seconds.
proc setWsIdleTimeout*(app: ExpressApp, seconds: int) =
  app.server.setWsIdleTimeout(seconds)

## Set the max WebSocket send backpressure in bytes.
proc setWsMaxBackpressure*(app: ExpressApp, bytes: int) =
  app.server.setWsMaxBackpressure(bytes)

## Set the WebSocket backpressure high-water mark in bytes.
proc setWsBackpressureHighWater*(app: ExpressApp, bytes: int) =
  app.server.setWsBackpressureHighWater(bytes)

## Set the action taken when WebSocket backpressure hits the high-water mark.
proc setWsBackpressureHighWaterAction*(app: ExpressApp, action: BackpressureHighWaterAction) =
  app.server.setWsBackpressureHighWaterAction(action)

## Enable dynamic per-connection WebSocket backpressure sizing.
proc setWsDynamicBackpressure*(
  app: ExpressApp,
  enabled: bool,
  expectedConnections: int,
  messageBytes: int,
  queueBudgetBytes: int,
  action: BackpressureHighWaterAction = bhwDropNewest,
  closeOnBackpressureLimit: bool = false
) =
  app.server.setWsDynamicBackpressure(
    enabled,
    expectedConnections,
    messageBytes,
    queueBudgetBytes,
    action,
    closeOnBackpressureLimit
  )

## Close the WebSocket when its send queue exceeds the backpressure limit.
proc setWsCloseOnBackpressureLimit*(app: ExpressApp, enabled: bool) =
  app.server.setWsCloseOnBackpressureLimit(enabled)

## Reset the WebSocket idle timeout on each outgoing send.
proc setWsResetIdleTimeoutOnSend*(app: ExpressApp, enabled: bool) =
  app.server.setWsResetIdleTimeoutOnSend(enabled)

## Enable or disable WebSocket permessage-deflate compression.
proc setWsCompressionEnabled*(app: ExpressApp, enabled: bool) =
  app.server.setWsCompressionEnabled(enabled)

## Min WebSocket message bytes before compression is applied.
proc setWsCompressionThreshold*(app: ExpressApp, bytes: int) =
  app.server.setWsCompressionThreshold(bytes)

## Min byte savings required to send a compressed WebSocket frame.
proc setWsCompressionMinSavings*(app: ExpressApp, bytes: int) =
  app.server.setWsCompressionMinSavings(bytes)

## Disable WebSocket compression for binary and/or text messages.
proc setWsCompressionBypass*(
  app: ExpressApp,
  disableForBinary: bool = false,
  disableForText: bool = false
) =
  app.server.setWsCompressionBypass(disableForBinary, disableForText)

## Disable WebSocket compression while backpressure exceeds the given bytes.
proc setWsCompressionBackpressureBypass*(app: ExpressApp, bytes: int) =
  app.server.setWsCompressionBackpressureBypass(bytes)

## Set the max bytes and frames coalesced per WebSocket write.
proc setWsWriteCoalesceLimits*(app: ExpressApp, maxBytes: int, maxFrames: int) =
  app.server.setWsWriteCoalesceLimits(maxBytes, maxFrames)

## Tune WebSocket socket recv/send buffers and notsent low-water mark.
proc setWsSocketTunables*(
  app: ExpressApp,
  recvBufferBytes: int = 0,
  sendBufferBytes: int = 0,
  notSentLowWaterBytes: int = 0
) =
  app.server.setWsSocketTunables(recvBufferBytes, sendBufferBytes, notSentLowWaterBytes)

## Send a message to all open WebSockets; returns the number of sockets sent.
proc broadcastWs*(app: ExpressApp, data: string, binary: bool = false): int =
  if app == nil or app.server == nil:
    return 0
  let prepared = prepareWsMessage(data, binary)
  app.server.broadcastPrepared(prepared)

## Broadcast a prepared WebSocket message to all open clients.
proc broadcastPreparedWs*(app: ExpressApp, msg: PreparedWsMessage): int =
  if app == nil or app.server == nil:
    return 0
  app.server.broadcastPrepared(msg)

## Enable minimal header parsing for plain HTTP clients.
proc setMinimalHeaderParsing*(app: ExpressApp, enabled: bool) =
  app.server.options.minimalHeaderParsing = enabled

## Enable graceful shutdown that drains active connections before exit.
proc setGracefulShutdown*(app: ExpressApp, enabled: bool) =
  app.server.options.gracefulShutdown = enabled

## Route macOS event loop work on the high QoS thread pool.
proc setMacosHighQos*(app: ExpressApp, enabled: bool) =
  app.server.setMacosHighQos(enabled)

## Set the byte threshold above which TLS writes are flattened to one buffer.
proc setTlsFlattenThreshold*(app: ExpressApp, bytes: int) =
  app.server.setTlsFlattenThreshold(bytes)

## Set the max bytes and responses coalesced per socket write.
proc setWriteCoalesceLimits*(app: ExpressApp, maxBytes: int, maxResponses: int) =
  app.server.setWriteCoalesceLimits(maxBytes, maxResponses)

## Select the write coalescing mode (latency, balanced, throughput, adaptive).
proc setWriteCoalesceMode*(app: ExpressApp, mode: WriteCoalesceMode) =
  app.server.setWriteCoalesceMode(mode)

## Set latency-tuned write coalescing limits for bytes and responses.
proc setWriteCoalesceLatencyLimits*(app: ExpressApp, maxBytes: int, maxResponses: int) =
  app.server.setWriteCoalesceLatencyLimits(maxBytes, maxResponses)

## Set throughput-tuned write coalescing limits for bytes and responses.
proc setWriteCoalesceThroughputLimits*(app: ExpressApp, maxBytes: int, maxResponses: int) =
  app.server.setWriteCoalesceThroughputLimits(maxBytes, maxResponses)

## Set small/large payload byte thresholds that steer coalescing behavior.
proc setWriteCoalescePayloadThresholds*(app: ExpressApp, smallPayloadBytes: int, largePayloadBytes: int) =
  app.server.setWriteCoalescePayloadThresholds(smallPayloadBytes, largePayloadBytes)

## Cap pending write bytes and responses to guard p99 latency.
proc setWriteCoalesceP99Guard*(app: ExpressApp, pendingBytes: int, pendingResponses: int) =
  app.server.setWriteCoalesceP99Guard(pendingBytes, pendingResponses)

## Enable or disable batching socket writes per event-loop iteration.
proc setLoopWriteBatching*(app: ExpressApp, enabled: bool) =
  app.server.setLoopWriteBatching(enabled)

## Tune the adaptive read buffer capacity range and shrink percent.
proc setAdaptiveReadBuffer*(
  app: ExpressApp,
  minCapacity: int,
  maxCapacity: int,
  shrinkPercent: int = 25
) =
  app.server.setAdaptiveReadBuffer(minCapacity, maxCapacity, shrinkPercent)

## Bound per-read request parsing by request and byte counts.
proc setParseFairnessBudget*(app: ExpressApp, requestsPerRead: int, bytesPerRead: int) =
  app.server.setParseFairnessBudget(requestsPerRead, bytesPerRead)

## Bound per-loop request dispatch by request and byte counts.
proc setLoopDispatchFairnessBudget*(app: ExpressApp, requestsPerLoop: int, bytesPerLoop: int) =
  app.server.setLoopDispatchFairnessBudget(requestsPerLoop, bytesPerLoop)

## Bound per-flush write iterations and bytes for connection fairness.
proc setWriteFairnessBudget*(app: ExpressApp, iterationsPerFlush: int, bytesPerFlush: int) =
  app.server.setWriteFairnessBudget(iterationsPerFlush, bytesPerFlush)

## Bound per-loop write bytes for connection fairness.
proc setLoopWriteFairnessBudget*(app: ExpressApp, bytesPerLoop: int) =
  app.server.setLoopWriteFairnessBudget(bytesPerLoop)

## Spill request bodies larger than ``thresholdBytes`` to ``spillDir``.
proc setBodySpillToDisk*(app: ExpressApp, thresholdBytes: int, spillDir: string = "") =
  app.server.setBodySpillToDisk(thresholdBytes, spillDir)

## Configure thread-local paged-buffer pool retention limits; returns pages trimmed.
proc setPageBufferPoolPolicy*(
  app: ExpressApp,
  maxRetainedPages: int = DefaultPagePoolLimit,
  maxRetainedBytes: int64 = 0'i64,
  trimNow: bool = false,
  trimTargetPages: int = -1,
  trimTargetBytes: int64 = -1'i64
): int =
  ## Configure thread-local paged-buffer pool retention limits.
  ## Defaults preserve existing behavior (1024 retained pages, no byte cap).
  discard app
  setPagePoolEvictionPolicy(
    maxRetainedPages = maxRetainedPages,
    maxRetainedBytes = maxRetainedBytes,
    trimNow = trimNow,
    trimTargetPages = trimTargetPages,
    trimTargetBytes = trimTargetBytes
  )

## Trim the thread-local paged-buffer pool now; returns pages released.
proc trimPageBufferPool*(app: ExpressApp, retainPages: int = -1, retainBytes: int64 = -1'i64): int =
  ## Trim thread-local paged-buffer pool immediately.
  discard app
  trimPagePool(retainPages = retainPages, retainBytes = retainBytes)

## Current thread-local paged-buffer pool hit, miss, and retention metrics.
proc pageBufferPoolMetrics*(app: ExpressApp): PagePoolMetrics {.inline.} =
  discard app
  pagePoolMetrics()

## Enable a fixed overload controller that rejects work above limits.
proc setOverloadController*(
  app: ExpressApp,
  maxBacklogBytes: int = 0,
  maxPendingResponses: int = 0,
  closeOnReject: bool = false
) =
  app.server.setOverloadController(maxBacklogBytes, maxPendingResponses, closeOnReject)

## Enable the adaptive overload controller that tightens limits under load.
proc setAdaptiveOverloadController*(
  app: ExpressApp,
  enabled: bool = true,
  minBacklogBytes: int = 256 * 1024,
  maxBacklogBytes: int = 0,
  minPendingResponses: int = 64,
  maxPendingResponses: int = 0,
  tightenStepPercent: int = 20,
  relaxStepPercent: int = 10,
  cooldownRequests: int = 64
) =
  app.server.setAdaptiveOverloadController(
    enabled,
    minBacklogBytes,
    maxBacklogBytes,
    minPendingResponses,
    maxPendingResponses,
    tightenStepPercent,
    relaxStepPercent,
    cooldownRequests
  )

## Set low-level listen socket options (nodelay, keepalive, buffers, CPU, epoll).
proc setSocketTunables*(
  app: ExpressApp,
  noDelay: bool = true,
  keepAlive: bool = true,
  keepAliveSeconds: int = 60,
  fastOpen: bool = false,
  sendBufferBytes: int = 0,
  recvBufferBytes: int = 0,
  notSentLowWaterBytes: int = 0,
  deferAcceptSeconds: int = 0,
  incomingCpu: int = -1,
  exclusivePort: bool = false,
  epollExclusive: bool = false,
  epollEdgeTrigger: bool = false
) =
  app.server.setSocketTunables(
    noDelay,
    keepAlive,
    keepAliveSeconds,
    fastOpen,
    sendBufferBytes,
    recvBufferBytes,
    notSentLowWaterBytes,
    deferAcceptSeconds,
    incomingCpu,
    exclusivePort,
    epollExclusive,
    epollEdgeTrigger
  )

## Apply the throughput-oriented Linux production socket and coalescing profile.
proc applyLinuxThroughputProfile*(app: ExpressApp) =
  ## Throughput-oriented runtime knobs intended for Linux production.
  app.setSocketTunables(
    noDelay = true,
    keepAlive = true,
    keepAliveSeconds = 60,
    fastOpen = true,
    sendBufferBytes = 1024 * 1024,
    recvBufferBytes = 1024 * 1024,
    notSentLowWaterBytes = 128 * 1024,
    deferAcceptSeconds = 1,
    exclusivePort = false,
    epollExclusive = true
  )
  app.setWriteCoalesceLimits(maxBytes = 128 * 1024, maxResponses = 32)
  app.setWriteCoalesceThroughputLimits(maxBytes = 256 * 1024, maxResponses = 48)
  app.setWriteCoalesceMode(wcmThroughput)
  app.setParseFairnessBudget(requestsPerRead = 64, bytesPerRead = 1024 * 1024)
  app.setLoopDispatchFairnessBudget(requestsPerLoop = 512, bytesPerLoop = 8 * 1024 * 1024)
  app.setWriteFairnessBudget(iterationsPerFlush = 64, bytesPerFlush = 1024 * 1024)
  app.setLoopWriteFairnessBudget(bytesPerLoop = 8 * 1024 * 1024)
  app.setAdaptiveReadBuffer(minCapacity = 4 * 1024, maxCapacity = 1024 * 1024, shrinkPercent = 20)
  app.setMaxPendingBytesPerSocket(1024 * 1024)
  app.setOverloadController(maxBacklogBytes = 8 * 1024 * 1024, maxPendingResponses = 4096, closeOnReject = false)

proc parseEnvBool(name: string, defaultValue: bool): bool =
  let raw = getEnv(name, "")
  if raw.len == 0:
    return defaultValue
  case raw.toLowerAscii()
  of "1", "true", "yes", "on":
    true
  of "0", "false", "no", "off":
    false
  else:
    defaultValue

proc parseEnvInt(name: string, defaultValue: int): int =
  let raw = getEnv(name, "")
  if raw.len == 0:
    return defaultValue
  try:
    parseInt(raw)
  except ValueError:
    defaultValue

proc parseWriteCoalesceMode(raw: string, defaultValue: WriteCoalesceMode): WriteCoalesceMode =
  case raw.toLowerAscii()
  of "adaptive":
    wcmAdaptive
  of "latency":
    wcmLatency
  of "balanced":
    wcmBalanced
  of "throughput":
    wcmThroughput
  else:
    defaultValue

proc parseWsBackpressureAction(raw: string, defaultValue: BackpressureHighWaterAction): BackpressureHighWaterAction =
  case raw.toLowerAscii().strip()
  of "drop-oldest", "drop_oldest", "oldest":
    bhwDropOldest
  of "close":
    bhwClose
  of "drop-newest", "drop_newest", "newest":
    bhwDropNewest
  else:
    defaultValue

## Apply runtime tunables from ``NIM_EXPRESS_*`` environment variables.
proc applyRuntimeTunablesFromEnv*(app: ExpressApp) {.gcsafe.} =
  ## Runtime override layer used by benchmark and Linux deployment harnesses.
  let profile = getEnv("NIM_EXPRESS_PROFILE", "").toLowerAscii()
  if profile == "linux-throughput":
    app.applyLinuxThroughputProfile()
  let poolingEnabled = parseEnvBool(
    "NIM_EXPRESS_REQUEST_RESPONSE_POOLING",
    getRequestResponsePoolingEnabled()
  )
  setRequestResponsePoolingEnabled(poolingEnabled)

  let noDelay = parseEnvBool("NIM_EXPRESS_SOCKET_NODELAY", app.server.options.socketNoDelay)
  let keepAlive = parseEnvBool("NIM_EXPRESS_SOCKET_KEEPALIVE", app.server.options.socketKeepAlive)
  let keepAliveSec = parseEnvInt("NIM_EXPRESS_SOCKET_KEEPALIVE_SEC", app.server.options.socketKeepAliveSeconds)
  let fastOpen = parseEnvBool("NIM_EXPRESS_SOCKET_FASTOPEN", app.server.options.socketFastOpen)
  let sndBuf = parseEnvInt("NIM_EXPRESS_SOCKET_SNDBUF", app.server.options.socketSendBufferBytes)
  let rcvBuf = parseEnvInt("NIM_EXPRESS_SOCKET_RCVBUF", app.server.options.socketRecvBufferBytes)
  let notSentLowat = parseEnvInt("NIM_EXPRESS_SOCKET_NOTSENT_LOWAT", app.server.options.socketNotSentLowWaterBytes)
  let deferAcceptSec = parseEnvInt("NIM_EXPRESS_SOCKET_DEFER_ACCEPT_SEC", app.server.options.socketDeferAcceptSeconds)
  let incomingCpu = parseEnvInt("NIM_EXPRESS_SOCKET_INCOMING_CPU", app.server.options.socketIncomingCpu)
  let exclusivePort = parseEnvBool("NIM_EXPRESS_LISTEN_EXCLUSIVE_PORT", app.server.options.listenExclusivePort)
  let epollExclusive = parseEnvBool("NIM_EXPRESS_LISTEN_EPOLL_EXCLUSIVE", app.server.options.listenEpollExclusive)
  let epollEdgeTrigger = parseEnvBool("NIM_EXPRESS_LISTEN_EPOLL_EDGE_TRIGGER", app.server.options.listenEpollEdgeTrigger)
  app.setSocketTunables(
    noDelay = noDelay,
    keepAlive = keepAlive,
    keepAliveSeconds = keepAliveSec,
    fastOpen = fastOpen,
    sendBufferBytes = sndBuf,
    recvBufferBytes = rcvBuf,
    notSentLowWaterBytes = notSentLowat,
    deferAcceptSeconds = deferAcceptSec,
    incomingCpu = incomingCpu,
    exclusivePort = exclusivePort,
    epollExclusive = epollExclusive,
    epollEdgeTrigger = epollEdgeTrigger
  )

  let loopBatchEnv = getEnv("NIM_EXPRESS_LOOP_WRITE_BATCHING", "")
  if loopBatchEnv.len > 0:
    app.setLoopWriteBatching(parseEnvBool("NIM_EXPRESS_LOOP_WRITE_BATCHING", app.server.options.loopWriteBatching))

  let modeRaw = getEnv("NIM_EXPRESS_WRITE_COALESCE_MODE", "")
  if modeRaw.len > 0:
    app.setWriteCoalesceMode(parseWriteCoalesceMode(modeRaw, app.server.options.writeCoalesceMode))
  let coalesceMaxBytes = parseEnvInt("NIM_EXPRESS_WRITE_COALESCE_MAX_BYTES", app.server.options.writeCoalesceMaxBytes)
  let coalesceMaxResponses = parseEnvInt("NIM_EXPRESS_WRITE_COALESCE_MAX_RESPONSES", app.server.options.writeCoalesceMaxResponses)
  app.setWriteCoalesceLimits(coalesceMaxBytes, coalesceMaxResponses)
  let coalesceTpMaxBytes = parseEnvInt("NIM_EXPRESS_WRITE_COALESCE_TP_MAX_BYTES", app.server.options.writeCoalesceThroughputMaxBytes)
  let coalesceTpMaxResponses = parseEnvInt("NIM_EXPRESS_WRITE_COALESCE_TP_MAX_RESPONSES", app.server.options.writeCoalesceThroughputMaxResponses)
  app.setWriteCoalesceThroughputLimits(coalesceTpMaxBytes, coalesceTpMaxResponses)

  let parseReqBudget = parseEnvInt("NIM_EXPRESS_PARSE_BUDGET_REQUESTS", app.server.options.parseBudgetRequestsPerRead)
  let parseByteBudget = parseEnvInt("NIM_EXPRESS_PARSE_BUDGET_BYTES", app.server.options.parseBudgetBytesPerRead)
  app.setParseFairnessBudget(parseReqBudget, parseByteBudget)
  let loopReqBudget = parseEnvInt("NIM_EXPRESS_LOOP_DISPATCH_REQUESTS", app.server.options.loopDispatchBudgetRequests)
  let loopByteBudget = parseEnvInt("NIM_EXPRESS_LOOP_DISPATCH_BYTES", app.server.options.loopDispatchBudgetBytes)
  app.setLoopDispatchFairnessBudget(loopReqBudget, loopByteBudget)
  let writeIterBudget = parseEnvInt("NIM_EXPRESS_WRITE_BUDGET_ITERATIONS", app.server.options.writeBudgetIterationsPerFlush)
  let writeByteBudget = parseEnvInt("NIM_EXPRESS_WRITE_BUDGET_BYTES", app.server.options.writeBudgetBytesPerFlush)
  app.setWriteFairnessBudget(writeIterBudget, writeByteBudget)
  let loopWriteBudget = parseEnvInt("NIM_EXPRESS_LOOP_WRITE_BUDGET_BYTES", app.server.options.loopWriteBudgetBytes)
  app.setLoopWriteFairnessBudget(loopWriteBudget)

  let overloadBacklog = parseEnvInt("NIM_EXPRESS_OVERLOAD_MAX_BACKLOG_BYTES", app.server.options.overloadMaxLoopBacklogBytes)
  let overloadPending = parseEnvInt("NIM_EXPRESS_OVERLOAD_MAX_PENDING_RESPONSES", app.server.options.overloadMaxPendingResponses)
  let overloadClose = parseEnvBool("NIM_EXPRESS_OVERLOAD_CLOSE_ON_REJECT", app.server.options.overloadCloseOnReject)
  app.setOverloadController(overloadBacklog, overloadPending, overloadClose)
  let overloadAdaptiveEnabled = parseEnvBool("NIM_EXPRESS_OVERLOAD_ADAPTIVE", app.server.options.overloadAdaptiveEnabled)
  let overloadAdaptiveMinBacklog = parseEnvInt("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MIN_BACKLOG_BYTES", app.server.options.overloadAdaptiveMinBacklogBytes)
  let overloadAdaptiveMaxBacklog = parseEnvInt("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MAX_BACKLOG_BYTES", app.server.options.overloadAdaptiveMaxBacklogBytes)
  let overloadAdaptiveMinPending = parseEnvInt("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MIN_PENDING_RESPONSES", app.server.options.overloadAdaptiveMinPendingResponses)
  let overloadAdaptiveMaxPending = parseEnvInt("NIM_EXPRESS_OVERLOAD_ADAPTIVE_MAX_PENDING_RESPONSES", app.server.options.overloadAdaptiveMaxPendingResponses)
  let overloadAdaptiveTighten = parseEnvInt("NIM_EXPRESS_OVERLOAD_ADAPTIVE_TIGHTEN_PERCENT", app.server.options.overloadAdaptiveTightenStepPercent)
  let overloadAdaptiveRelax = parseEnvInt("NIM_EXPRESS_OVERLOAD_ADAPTIVE_RELAX_PERCENT", app.server.options.overloadAdaptiveRelaxStepPercent)
  let overloadAdaptiveCooldown = parseEnvInt("NIM_EXPRESS_OVERLOAD_ADAPTIVE_COOLDOWN_REQUESTS", app.server.options.overloadAdaptiveCooldownRequests)
  app.setAdaptiveOverloadController(
    enabled = overloadAdaptiveEnabled,
    minBacklogBytes = overloadAdaptiveMinBacklog,
    maxBacklogBytes = overloadAdaptiveMaxBacklog,
    minPendingResponses = overloadAdaptiveMinPending,
    maxPendingResponses = overloadAdaptiveMaxPending,
    tightenStepPercent = overloadAdaptiveTighten,
    relaxStepPercent = overloadAdaptiveRelax,
    cooldownRequests = overloadAdaptiveCooldown
  )

  let wsRecvBuf = parseEnvInt("NIM_EXPRESS_WS_RECV_BUFFER", app.server.options.wsSocketRecvBufferBytes)
  let wsSndBuf = parseEnvInt("NIM_EXPRESS_WS_SEND_BUFFER", app.server.options.wsSocketSendBufferBytes)
  let wsNotsentLowat = parseEnvInt("NIM_EXPRESS_WS_NOTSENT_LOWWATER", app.server.options.wsSocketNotSentLowWaterBytes)
  app.setWsSocketTunables(wsRecvBuf, wsSndBuf, wsNotsentLowat)
  app.setWsKeepaliveInterval(parseEnvInt("NIM_EXPRESS_WS_KEEPALIVE_INTERVAL_MS", app.server.options.wsKeepaliveInterval))
  app.setWsIdleTimeout(parseEnvInt("NIM_EXPRESS_WS_IDLE_TIMEOUT_SEC", app.server.options.wsIdleTimeoutSeconds))
  app.setWsMaxBackpressure(parseEnvInt("NIM_EXPRESS_WS_MAX_BACKPRESSURE_BYTES", app.server.options.wsMaxBackpressure))
  app.setWsBackpressureHighWater(parseEnvInt(
    "NIM_EXPRESS_WS_BACKPRESSURE_HIGH_WATER_BYTES",
    app.server.options.wsBackpressureHighWaterBytes
  ))
  let wsHighWaterAction = parseWsBackpressureAction(
    getEnv("NIM_EXPRESS_WS_BACKPRESSURE_HIGH_WATER_ACTION", ""),
    app.server.options.wsBackpressureHighWaterAction
  )
  app.setWsBackpressureHighWaterAction(wsHighWaterAction)
  let dynamicWs = parseEnvBool("NIM_EXPRESS_WS_DYNAMIC_BACKPRESSURE", app.server.options.wsDynamicBackpressureEnabled)
  let wsExpected = parseEnvInt("NIM_EXPRESS_WS_EXPECTED_CONNECTIONS", app.server.options.wsExpectedConnections)
  let wsMessageBytes = parseEnvInt("NIM_EXPRESS_WS_MESSAGE_BYTES", app.server.options.wsMessageBytes)
  var wsQueueBudget = parseEnvInt("NIM_EXPRESS_WS_QUEUE_BUDGET_BYTES", app.server.options.wsQueueBudgetBytes)
  let wsQueueBudgetMbRaw = getEnv("NIM_EXPRESS_WS_QUEUE_BUDGET_MB", "")
  if wsQueueBudgetMbRaw.len > 0:
    let mb = parseEnvInt("NIM_EXPRESS_WS_QUEUE_BUDGET_MB", -1)
    if mb >= 0 and mb <= int.high div (1024 * 1024):
      wsQueueBudget = mb * 1024 * 1024
  let wsCloseOnBackpressure = parseEnvBool(
    "NIM_EXPRESS_WS_CLOSE_ON_BACKPRESSURE_LIMIT",
    app.server.options.wsCloseOnBackpressureLimit
  )
  if dynamicWs:
    let effectiveExpected =
      if wsExpected > 0: wsExpected
      else: app.server.options.maxConnections
    app.setWsDynamicBackpressure(
      dynamicWs,
      effectiveExpected,
      wsMessageBytes,
      wsQueueBudget,
      wsHighWaterAction,
      wsCloseOnBackpressure
    )
  else:
    app.setWsCloseOnBackpressureLimit(wsCloseOnBackpressure)

## Apply a parsed ``AppEnvConfig`` to the app's server and WebSocket settings.
proc applyAppEnvConfig*(app: ExpressApp, cfg: AppEnvConfig) =
  if app == nil:
    return

  if cfg.profile.toLowerAscii() == "linux-throughput":
    app.applyLinuxThroughputProfile()

  app.setTrustProxy(cfg.trustProxy)
  app.setTrustedProxyHops(cfg.trustedProxyHops)
  app.setTrustedProxyAllowlist(cfg.trustedProxyAllowlist)
  app.setAsyncPumpIntervalMs(cfg.asyncPumpIntervalMs)
  app.setMaxInflightAsyncRequests(cfg.maxInflightAsyncRequests)
  app.setContextPoolPrewarm(cfg.contextPoolPrewarm)
  setRequestResponsePoolingEnabled(cfg.requestResponsePoolingEnabled)
  app.setMaxPendingBytesPerSocket(cfg.maxPendingBytesPerSocket)
  app.setMaxBodySize(cfg.maxBodySize)
  app.setConnectionTimeout(cfg.connectionTimeoutSeconds)
  app.setMaxConnections(cfg.maxConnections)
  app.setMinimalHeaderParsing(cfg.minimalHeaderParsing)
  app.setGracefulShutdown(cfg.gracefulShutdown)
  app.setMacosHighQos(cfg.macosHighQos)
  app.setTlsFlattenThreshold(cfg.tlsFlattenThreshold)
  app.setSocketTunables(
    noDelay = cfg.socketNoDelay,
    keepAlive = cfg.socketKeepAlive,
    keepAliveSeconds = cfg.socketKeepAliveSeconds,
    fastOpen = cfg.socketFastOpen,
    sendBufferBytes = cfg.socketSendBufferBytes,
    recvBufferBytes = cfg.socketRecvBufferBytes,
    notSentLowWaterBytes = cfg.socketNotSentLowWaterBytes,
    deferAcceptSeconds = cfg.socketDeferAcceptSeconds,
    incomingCpu = cfg.socketIncomingCpu,
    exclusivePort = cfg.listenExclusivePort,
    epollExclusive = cfg.listenEpollExclusive,
    epollEdgeTrigger = cfg.listenEpollEdgeTrigger
  )
  app.setWriteCoalesceMode(cfg.writeCoalesceMode)
  app.setWriteCoalesceLimits(cfg.writeCoalesceMaxBytes, cfg.writeCoalesceMaxResponses)
  app.setWriteCoalesceThroughputLimits(
    cfg.writeCoalesceThroughputMaxBytes,
    cfg.writeCoalesceThroughputMaxResponses
  )
  app.setParseFairnessBudget(cfg.parseBudgetRequestsPerRead, cfg.parseBudgetBytesPerRead)
  app.setLoopDispatchFairnessBudget(cfg.loopDispatchBudgetRequests, cfg.loopDispatchBudgetBytes)
  app.setWriteFairnessBudget(cfg.writeBudgetIterationsPerFlush, cfg.writeBudgetBytesPerFlush)
  app.setLoopWriteFairnessBudget(cfg.loopWriteBudgetBytes)
  app.setOverloadController(
    cfg.overloadMaxLoopBacklogBytes,
    cfg.overloadMaxPendingResponses,
    cfg.overloadCloseOnReject
  )
  app.setAdaptiveOverloadController(
    enabled = cfg.overloadAdaptiveEnabled,
    minBacklogBytes = cfg.overloadAdaptiveMinBacklogBytes,
    maxBacklogBytes = cfg.overloadAdaptiveMaxBacklogBytes,
    minPendingResponses = cfg.overloadAdaptiveMinPendingResponses,
    maxPendingResponses = cfg.overloadAdaptiveMaxPendingResponses,
    tightenStepPercent = cfg.overloadAdaptiveTightenStepPercent,
    relaxStepPercent = cfg.overloadAdaptiveRelaxStepPercent,
    cooldownRequests = cfg.overloadAdaptiveCooldownRequests
  )
  app.setWsKeepaliveInterval(cfg.wsKeepaliveIntervalMs)
  app.setWsIdleTimeout(cfg.wsIdleTimeoutSeconds)
  app.setWsMaxBackpressure(cfg.wsMaxBackpressureBytes)
  app.setWsBackpressureHighWater(cfg.wsBackpressureHighWaterBytes)
  app.setWsBackpressureHighWaterAction(cfg.wsBackpressureHighWaterAction)
  if cfg.wsDynamicBackpressureEnabled:
    let effectiveWsExpected =
      if cfg.wsExpectedConnections > 0: cfg.wsExpectedConnections
      else: cfg.maxConnections
    app.setWsDynamicBackpressure(
      cfg.wsDynamicBackpressureEnabled,
      effectiveWsExpected,
      cfg.wsMessageBytes,
      cfg.wsQueueBudgetBytes,
      cfg.wsBackpressureHighWaterAction,
      cfg.wsCloseOnBackpressureLimit
    )
  else:
    app.setWsCloseOnBackpressureLimit(cfg.wsCloseOnBackpressureLimit)
  app.setWsResetIdleTimeoutOnSend(cfg.wsResetIdleTimeoutOnSend)
  app.setWsCompressionEnabled(cfg.wsCompressionEnabled)
  app.setWsCompressionThreshold(cfg.wsCompressionThresholdBytes)
  app.setWsCompressionMinSavings(cfg.wsCompressionMinSavingsBytes)
  app.setWsCompressionBypass(
    disableForBinary = cfg.wsCompressionDisableForBinary,
    disableForText = cfg.wsCompressionDisableForText
  )
  app.setWsCompressionBackpressureBypass(cfg.wsCompressionBackpressureBypassBytes)
  app.setWsWriteCoalesceLimits(cfg.wsWriteCoalesceMaxBytes, cfg.wsWriteCoalesceMaxFrames)
  app.setWsSocketTunables(
    cfg.wsSocketRecvBufferBytes,
    cfg.wsSocketSendBufferBytes,
    cfg.wsSocketNotSentLowWaterBytes
  )
  app.setBodySpillToDisk(cfg.bodySpillThresholdBytes, cfg.bodySpillDir)

## Render the ``optimizationMetrics`` counters as a JSON object string.
proc optimizationMetricsJson*(app: ExpressApp): string =
  let m = app.optimizationMetrics()
  result = "{"
  result.add("\"parser_errors\":")
  result.add($(m.getOrDefault("parser_errors", 0)))
  result.add(",\"overload_rejects\":")
  result.add($(m.getOrDefault("overload_rejects", 0)))
  result.add(",\"overload_reject_backlog\":")
  result.add($(m.getOrDefault("overload_reject_backlog", 0)))
  result.add(",\"overload_reject_pending\":")
  result.add($(m.getOrDefault("overload_reject_pending", 0)))
  result.add(",\"write_retries\":")
  result.add($(m.getOrDefault("write_retries", 0)))
  result.add(",\"backpressure_drops\":")
  result.add($(m.getOrDefault("backpressure_drops", 0)))
  result.add(",\"backpressure_high_water_events\":")
  result.add($(m.getOrDefault("backpressure_high_water_events", 0)))
  result.add(",\"shutdown_drained_connections\":")
  result.add($(m.getOrDefault("shutdown_drained_connections", 0)))
  result.add(",\"shutdown_forced_connections\":")
  result.add($(m.getOrDefault("shutdown_forced_connections", 0)))
  result.add(",\"page_pool_hits\":")
  result.add($(m.getOrDefault("page_pool_hits", 0)))
  result.add(",\"page_pool_misses\":")
  result.add($(m.getOrDefault("page_pool_misses", 0)))
  result.add(",\"page_pool_bytes\":")
  result.add($(m.getOrDefault("page_pool_bytes", 0)))
  result.add(",\"page_pool_retained\":")
  result.add($(m.getOrDefault("page_pool_retained", 0)))
  result.add(",\"connections\":")
  result.add($(m.getOrDefault("connections", 0)))
  result.add(",\"websockets\":")
  result.add($(m.getOrDefault("websockets", 0)))
  result.add(",\"inflight_async\":")
  result.add($(m.getOrDefault("inflight_async", 0)))
  result.add(",\"async_pump_poll_failures\":")
  result.add($(m.getOrDefault("async_pump_poll_failures", 0)))
  result.add("}")

## Total HTTP parse errors observed by the server.
proc parserErrorCount*(app: ExpressApp): int64 {.inline.} =
  app.server.getParserErrorCount()

## Total requests rejected by the overload controller.
proc overloadRejectCount*(app: ExpressApp): int64 {.inline.} =
  app.server.getOverloadRejectCount()

## Total overload rejections caused by the loop backlog limit.
proc overloadRejectBacklogCount*(app: ExpressApp): int64 {.inline.} =
  app.server.getOverloadRejectBacklogCount()

## Total overload rejections caused by the pending response limit.
proc overloadRejectPendingCount*(app: ExpressApp): int64 {.inline.} =
  app.server.getOverloadRejectPendingCount()

## Total socket write retries after partial writes.
proc writeRetryCount*(app: ExpressApp): int64 {.inline.} =
  app.server.getWriteRetryCount()

## Total WebSocket messages dropped under send backpressure.
proc backpressureDropCount*(app: ExpressApp): int64 {.inline.} =
  app.server.getBackpressureDropCount()

## Total WebSocket high-water-mark backpressure events.
proc backpressureHighWaterCount*(app: ExpressApp): int64 {.inline.} =
  app.server.getBackpressureHighWaterEventCount()

## Total connections drained cleanly during shutdown.
proc shutdownDrainedConnectionCount*(app: ExpressApp): int64 {.inline.} =
  app.server.getShutdownDrainedConnectionCount()

## Total connections force-closed during shutdown.
proc shutdownForcedConnectionCount*(app: ExpressApp): int64 {.inline.} =
  app.server.getShutdownForcedConnectionCount()

## Snapshot core server and pool counters for observability automation.
proc optimizationMetrics*(app: ExpressApp): FastMap[int64] =
  ## Snapshot core counters used by perf/observability automation.
  result = newFastMap[int64]()
  discard result.reserve(16)
  let poolMetrics = pagePoolMetrics()
  discard result.put("parser_errors", app.parserErrorCount())
  discard result.put("overload_rejects", app.overloadRejectCount())
  discard result.put("overload_reject_backlog", app.overloadRejectBacklogCount())
  discard result.put("overload_reject_pending", app.overloadRejectPendingCount())
  discard result.put("write_retries", app.writeRetryCount())
  discard result.put("backpressure_drops", app.backpressureDropCount())
  discard result.put("backpressure_high_water_events", app.backpressureHighWaterCount())
  discard result.put("shutdown_drained_connections", app.shutdownDrainedConnectionCount())
  discard result.put("shutdown_forced_connections", app.shutdownForcedConnectionCount())
  discard result.put("page_pool_hits", poolMetrics.hitCount)
  discard result.put("page_pool_misses", poolMetrics.missCount)
  discard result.put("page_pool_bytes", poolMetrics.retainedBytes)
  discard result.put("page_pool_retained", poolMetrics.retainedPages.int64)
  discard result.put("connections", app.server.getConnectionCount().int64)
  discard result.put("websockets", app.server.getWebSocketCount().int64)
  discard result.put("inflight_async", app.getInflightAsyncRequests().int64)
  discard result.put("async_pump_poll_failures", asyncPumpPollFailureCount())

proc ensureAppRouterMutable(app: ExpressApp) {.inline.} =
  if app == nil:
    return
  if app.listenStarted:
    raise newException(ValueError, "router mutation denied: listen_started")
  app.router.ensureRouterMutable()

## Add middleware to the application pipeline.
## Middleware executes in registration order for every request.
proc use*(app: ExpressApp, middleware: AsyncMiddleware) =
  app.ensureAppRouterMutable()
  app.middlewares.add(middleware)
  app.orderedMiddlewares.add(middleware)

## Wrap a synchronous next-based middleware as an ``AsyncMiddleware``.
proc asAsyncMiddleware*(middleware: SyncNextMiddleware): AsyncMiddleware

## Add a synchronous next-based middleware to the application pipeline.
proc useSync*(app: ExpressApp, middleware: SyncNextMiddleware) =
  app.ensureAppRouterMutable()
  app.syncMiddlewares.add(middleware)
  app.orderedMiddlewares.add(asAsyncMiddleware(middleware))

## Wrap a ``SyncHandler`` so it can be used where an ``AsyncHandler`` is expected.
proc asAsyncHandler*(handler: SyncHandler): AsyncHandler =
  if handler == nil:
    return nil
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    handler(req, res)

when defined(singleThread):
  var syncNextFlag: bool
  var asyncNextFlag: bool
else:
  var syncNextFlag {.threadvar.}: bool
  var asyncNextFlag {.threadvar.}: bool

proc sharedSyncNext() {.nimcall.} =
  syncNextFlag = true

## Shared async ``next`` callable that marks continuation from sync middleware.
let sharedAsyncNext*: NextProc = proc(): Future[void] {.async.} =
  asyncNextFlag = true

## Wrap a synchronous next-based middleware as an ``AsyncMiddleware``.
proc asAsyncMiddleware*(middleware: SyncNextMiddleware): AsyncMiddleware =
  if middleware == nil:
    return nil
  result = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
    syncNextFlag = false
    middleware(req, res, sharedSyncNext)
    if syncNextFlag:
      await next()

## Add a synchronous next-based middleware to the application pipeline.
proc use*(app: ExpressApp, middleware: SyncNextMiddleware) =
  app.useSync(middleware)

proc pathPrefixMatches(path, prefix: string): bool {.inline.} =
  if prefix.len == 0 or prefix == "/":
    return true
  if path == prefix:
    return true
  if path.len > prefix.len and path.startsWith(prefix):
    if prefix[^1] == '/':
      return true
    return path[prefix.len] == '/'
  false

## Add ``middleware`` that runs only for requests whose path matches ``path``.
proc use*(app: ExpressApp, path: string, middleware: AsyncMiddleware) =
  app.ensureAppRouterMutable()
  let pathMiddleware: AsyncMiddleware = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
    if pathPrefixMatches(req.path, path):
      await middleware(req, res, next)
    else:
      await next()
  app.middlewares.add(pathMiddleware)
  app.orderedMiddlewares.add(pathMiddleware)

## Add sync ``middleware`` that runs only for requests whose path matches ``path``.
proc use*(app: ExpressApp, path: string, middleware: SyncNextMiddleware) =
  app.use(path, asAsyncMiddleware(middleware))

proc normalizeGroupPrefix(prefix: string): string {.inline.} =
  var normalized = prefix.strip()
  if normalized.len == 0:
    return "/"
  if normalized[0] != '/':
    normalized = "/" & normalized
  if normalized.len > 1 and normalized.endsWith("/"):
    normalized.setLen(normalized.len - 1)
  normalized

proc joinGroupPattern(prefix, pattern: string): string {.inline.} =
  let normalizedPattern =
    if pattern.len == 0: "/"
    elif pattern[0] == '/': pattern
    else: "/" & pattern
  if prefix == "/":
    return normalizedPattern
  if normalizedPattern == "/":
    return prefix
  prefix & normalizedPattern

## Create a ``RouteGroup`` under ``prefix`` and attach the given middlewares.
proc group*(app: ExpressApp, prefix: string, middlewares: varargs[AsyncMiddleware]): RouteGroup =
  app.ensureAppRouterMutable()
  let groupPrefix = normalizeGroupPrefix(prefix)
  for middleware in middlewares:
    app.use(groupPrefix, middleware)
  new(result)
  result.app = app
  result.prefix = groupPrefix

## Create a nested ``RouteGroup`` by extending the parent group's prefix.
proc group*(group: RouteGroup, prefix: string, middlewares: varargs[AsyncMiddleware]): RouteGroup =
  if group == nil or group.app == nil:
    return nil
  let combinedPrefix = normalizeGroupPrefix(joinGroupPattern(group.prefix, prefix))
  result = group.app.group(combinedPrefix)
  for middleware in middlewares:
    result.app.use(result.prefix, middleware)

## Add async middleware that applies to every route registered in the group.
proc use*(group: RouteGroup, middleware: AsyncMiddleware) =
  if group == nil or group.app == nil:
    return
  group.app.use(group.prefix, middleware)

## Add sync middleware that applies to every route registered in the group.
proc use*(group: RouteGroup, middleware: SyncNextMiddleware) =
  if group == nil or group.app == nil:
    return
  group.app.use(group.prefix, middleware)

# Add route to the appropriate method group
proc addRouteToGroup(router: Router, methodKind: nim_usockets.HttpMethod, route: Route) =
  router.ensureRouterMutable()
  template addRouteWithIndex(routesField, exactField, firstDynamicField: untyped) =
    let idx = router.routesField.len
    router.routesField.add(route)
    if route.isDynamic:
      if router.firstDynamicField < 0:
        router.firstDynamicField = idx
    elif not router.exactField.contains(route.pattern):
      # Keep first registration to preserve route-order semantics.
      discard router.exactField.put(route.pattern, idx.int64)

  case methodKind
  of hmGet: addRouteWithIndex(getRoutes, getExactRoutes, firstDynamicGet)
  of hmPost: addRouteWithIndex(postRoutes, postExactRoutes, firstDynamicPost)
  of hmPut: addRouteWithIndex(putRoutes, putExactRoutes, firstDynamicPut)
  of hmDelete: addRouteWithIndex(deleteRoutes, deleteExactRoutes, firstDynamicDelete)
  of hmPatch: addRouteWithIndex(patchRoutes, patchExactRoutes, firstDynamicPatch)
  of hmHead: addRouteWithIndex(headRoutes, headExactRoutes, firstDynamicHead)
  of hmOptions: addRouteWithIndex(optionsRoutes, optionsExactRoutes, firstDynamicOptions)
  else: discard
  router.artifactsCompiled = false
  for i in 0..<128:
    router.routeCacheValid[i] = false

# ASYNC handlers (for I/O operations)
proc addAsyncRoute(app: ExpressApp, methodKind: nim_usockets.HttpMethod, pattern: string, handler: AsyncHandler) =
  let paramNames = parsePattern(pattern)
  let meta = compileRouteMeta(pattern)
  let route = Route(
    kind: rkAsync,
    pattern: pattern,
    paramNames: paramNames,
    isDynamic: paramNames.len > 0 or ('*' in pattern),
    staticPrefix: meta.staticPrefix,
    prefixBucketKey: routePrefixBucketKey(meta.staticPrefix),
    firstLiteralSegment: meta.firstLiteralSegment,
    minSegmentCount: meta.minSegmentCount,
    maxSegmentCount: meta.maxSegmentCount,
    asyncHandler: handler,
    middlewares: @[],
    compiledMiddlewares: @[]
  )
  app.router.addRouteToGroup(methodKind, route)

## Register an async ``GET`` route; ``handler`` is an ``AsyncHandler`` ({.async.} proc).
proc getAsync*(app: ExpressApp, pattern: string, handler: AsyncHandler) =
  app.addAsyncRoute(hmGet, pattern, handler)

## Register an async ``GET`` route; a sync ``SyncHandler`` is wrapped as async.
proc getAsync*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addAsyncRoute(hmGet, pattern, asAsyncHandler(handler))

## Register an async ``POST`` route; ``handler`` is an ``AsyncHandler`` ({.async.} proc).
proc postAsync*(app: ExpressApp, pattern: string, handler: AsyncHandler) =
  app.addAsyncRoute(hmPost, pattern, handler)

## Register an async ``POST`` route; a sync ``SyncHandler`` is wrapped as async.
proc postAsync*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addAsyncRoute(hmPost, pattern, asAsyncHandler(handler))

## Register an async ``PUT`` route; ``handler`` is an ``AsyncHandler`` ({.async.} proc).
proc putAsync*(app: ExpressApp, pattern: string, handler: AsyncHandler) =
  app.addAsyncRoute(hmPut, pattern, handler)

## Register an async ``PUT`` route; a sync ``SyncHandler`` is wrapped as async.
proc putAsync*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addAsyncRoute(hmPut, pattern, asAsyncHandler(handler))

## Register an async ``DELETE`` route; ``handler`` is an ``AsyncHandler`` ({.async.} proc).
proc deleteAsync*(app: ExpressApp, pattern: string, handler: AsyncHandler) =
  app.addAsyncRoute(hmDelete, pattern, handler)

## Register an async ``DELETE`` route; a sync ``SyncHandler`` is wrapped as async.
proc deleteAsync*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addAsyncRoute(hmDelete, pattern, asAsyncHandler(handler))

## Register an async ``PATCH`` route; ``handler`` is an ``AsyncHandler`` ({.async.} proc).
proc patchAsync*(app: ExpressApp, pattern: string, handler: AsyncHandler) =
  app.addAsyncRoute(hmPatch, pattern, handler)

## Register an async ``PATCH`` route; a sync ``SyncHandler`` is wrapped as async.
proc patchAsync*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addAsyncRoute(hmPatch, pattern, asAsyncHandler(handler))

## Register an async ``HEAD`` route; ``handler`` is an ``AsyncHandler`` ({.async.} proc).
proc headAsync*(app: ExpressApp, pattern: string, handler: AsyncHandler) =
  app.addAsyncRoute(hmHead, pattern, handler)

## Register an async ``HEAD`` route; a sync ``SyncHandler`` is wrapped as async.
proc headAsync*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addAsyncRoute(hmHead, pattern, asAsyncHandler(handler))

## Register an async ``OPTIONS`` route; ``handler`` is an ``AsyncHandler`` ({.async.} proc).
proc optionsAsync*(app: ExpressApp, pattern: string, handler: AsyncHandler) =
  app.addAsyncRoute(hmOptions, pattern, handler)

## Register an async ``OPTIONS`` route; a sync ``SyncHandler`` is wrapped as async.
proc optionsAsync*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addAsyncRoute(hmOptions, pattern, asAsyncHandler(handler))

# SYNC handlers (default request path)
proc addSyncRoute(app: ExpressApp, methodKind: nim_usockets.HttpMethod, pattern: string, handler: SyncHandler) =
  let paramNames = parsePattern(pattern)
  let meta = compileRouteMeta(pattern)
  let route = Route(
    kind: rkSync,
    pattern: pattern,
    paramNames: paramNames,
    isDynamic: paramNames.len > 0 or ('*' in pattern),
    staticPrefix: meta.staticPrefix,
    prefixBucketKey: routePrefixBucketKey(meta.staticPrefix),
    firstLiteralSegment: meta.firstLiteralSegment,
    minSegmentCount: meta.minSegmentCount,
    maxSegmentCount: meta.maxSegmentCount,
    syncHandler: handler,
    middlewares: @[],
    compiledMiddlewares: @[]
  )
  app.router.addRouteToGroup(methodKind, route)

## Register a handler for GET requests matching ``path``.
## Path supports ``:param`` placeholders (e.g., ``"/users/:id"``).
proc get*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addSyncRoute(hmGet, pattern, handler)

## Register a handler for POST requests matching ``path``.
proc post*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addSyncRoute(hmPost, pattern, handler)

## Register a handler for PUT requests matching ``path``.
proc put*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addSyncRoute(hmPut, pattern, handler)

## Register a handler for DELETE requests matching ``path``.
proc delete*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addSyncRoute(hmDelete, pattern, handler)

## Register a handler for PATCH requests matching ``path``.
proc patch*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addSyncRoute(hmPatch, pattern, handler)

## Register a handler for HEAD requests matching the pattern.
proc head*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addSyncRoute(hmHead, pattern, handler)

## Register a handler for OPTIONS requests matching the pattern.
proc options*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  app.addSyncRoute(hmOptions, pattern, handler)

## Register an ``AsyncHandler`` for every HTTP method on the pattern.
proc allAsync*(app: ExpressApp, pattern: string, handler: AsyncHandler)
## Register a sync handler for every HTTP method on the pattern.
proc all*(app: ExpressApp, pattern: string, handler: SyncHandler)

## Register an async ``GET`` route on this group, prefixed with the group prefix.
proc getAsync*(group: RouteGroup, pattern: string, handler: AsyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.getAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``GET`` route on this group from a sync ``SyncHandler``.
proc getAsync*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.getAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``POST`` route on this group, prefixed with the group prefix.
proc postAsync*(group: RouteGroup, pattern: string, handler: AsyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.postAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``POST`` route on this group from a sync ``SyncHandler``.
proc postAsync*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.postAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``PUT`` route on this group, prefixed with the group prefix.
proc putAsync*(group: RouteGroup, pattern: string, handler: AsyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.putAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``PUT`` route on this group from a sync ``SyncHandler``.
proc putAsync*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.putAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``DELETE`` route on this group, prefixed with the group prefix.
proc deleteAsync*(group: RouteGroup, pattern: string, handler: AsyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.deleteAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``DELETE`` route on this group from a sync ``SyncHandler``.
proc deleteAsync*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.deleteAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``PATCH`` route on this group, prefixed with the group prefix.
proc patchAsync*(group: RouteGroup, pattern: string, handler: AsyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.patchAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``PATCH`` route on this group from a sync ``SyncHandler``.
proc patchAsync*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.patchAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``HEAD`` route on this group, prefixed with the group prefix.
proc headAsync*(group: RouteGroup, pattern: string, handler: AsyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.headAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``HEAD`` route on this group from a sync ``SyncHandler``.
proc headAsync*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.headAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``OPTIONS`` route on this group, prefixed with the group prefix.
proc optionsAsync*(group: RouteGroup, pattern: string, handler: AsyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.optionsAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register an async ``OPTIONS`` route on this group from a sync ``SyncHandler``.
proc optionsAsync*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.optionsAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register a sync ``GET`` route on this group, prefixed with the group prefix.
proc get*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.get(joinGroupPattern(group.prefix, pattern), handler)

## Register a sync ``POST`` route on this group, prefixed with the group prefix.
proc post*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.post(joinGroupPattern(group.prefix, pattern), handler)

## Register a sync ``PUT`` route on this group, prefixed with the group prefix.
proc put*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.put(joinGroupPattern(group.prefix, pattern), handler)

## Register a sync ``DELETE`` route on this group, prefixed with the group prefix.
proc delete*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.delete(joinGroupPattern(group.prefix, pattern), handler)

## Register a sync ``PATCH`` route on this group, prefixed with the group prefix.
proc patch*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.patch(joinGroupPattern(group.prefix, pattern), handler)

## Register a sync ``HEAD`` route on this group, prefixed with the group prefix.
proc head*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.head(joinGroupPattern(group.prefix, pattern), handler)

## Register a sync ``OPTIONS`` route on this group, prefixed with the group prefix.
proc options*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.options(joinGroupPattern(group.prefix, pattern), handler)

## Register an ``AsyncHandler`` for every HTTP method on this group.
proc allAsync*(group: RouteGroup, pattern: string, handler: AsyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.allAsync(joinGroupPattern(group.prefix, pattern), handler)

## Register a sync handler for every HTTP method on this group (wrapped as async).
proc allAsync*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.allAsync(joinGroupPattern(group.prefix, pattern), asAsyncHandler(handler))

## Register a sync handler for every HTTP method on this group.
proc all*(group: RouteGroup, pattern: string, handler: SyncHandler) =
  if group == nil or group.app == nil:
    return
  group.app.all(joinGroupPattern(group.prefix, pattern), handler)

## Register an ``AsyncHandler`` for every HTTP method on the pattern.
proc allAsync*(app: ExpressApp, pattern: string, handler: AsyncHandler) =
  for m in [hmGet, hmPost, hmPut, hmDelete, hmPatch, hmHead, hmOptions]:
    app.addAsyncRoute(m, pattern, handler)

## Register a sync handler for every HTTP method on the pattern (wrapped as async).
proc allAsync*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  for m in [hmGet, hmPost, hmPut, hmDelete, hmPatch, hmHead, hmOptions]:
    app.addAsyncRoute(m, pattern, asAsyncHandler(handler))

## Register a sync handler for every HTTP method on the pattern.
proc all*(app: ExpressApp, pattern: string, handler: SyncHandler) =
  for m in [hmGet, hmPost, hmPut, hmDelete, hmPatch, hmHead, hmOptions]:
    app.addSyncRoute(m, pattern, handler)

## Set the async error handler invoked when a handler or middleware raises.
proc onError*(app: ExpressApp, handler: AsyncErrorHandler) =
  app.errorHandler = handler

proc notifyAsyncDisconnect(remoteIp: string, requestSeq: uint64, socketKey: uint64)

## Register a hook invoked when a new client connection opens.
proc onConnectionOpen*(app: ExpressApp, hook: ConnectionOpenHook) =
  app.connectionOpenHook = hook
  app.server.onConnectionOpen(proc(remoteIp: string) =
    if app.connectionOpenHook != nil:
      try:
        app.connectionOpenHook(remoteIp)
      except CatchableError as err:
        app.reportHookFailure("connectionOpenHook", err)
  )

## Register a hook invoked when a client connection closes.
proc onConnectionClose*(app: ExpressApp, hook: ConnectionCloseHook) =
  app.connectionCloseHook = hook
  app.hasConnectionCloseHook = hook != nil
  nim_usockets.onConnectionClose(app.server, proc(
    remoteIp: string,
    wasWebSocket: bool,
    requestSeq: uint64,
    socketKey: uint64
  ) =
    notifyAsyncDisconnect(remoteIp, requestSeq, socketKey)
    if app.hasConnectionCloseHook:
      try:
        app.connectionCloseHook(remoteIp, wasWebSocket)
      except CatchableError as err:
        app.reportHookFailure("connectionCloseHook", err)
  )

## Register a hook invoked when request processing starts.
proc onRequestStartHook*(app: ExpressApp, hook: RequestStartHook) =
  app.requestStartHook = hook
  app.hasRequestStartHook = hook != nil

## Register a hook invoked when a request finishes, with its duration in micros.
proc onRequestEndHook*(app: ExpressApp, hook: RequestEndHook) =
  app.requestEndHook = hook
  app.hasRequestEndHook = hook != nil

## Register a hook invoked with the matched route pattern per request.
proc onRouteMatched*(app: ExpressApp, hook: RouteMatchedHook) =
  app.routeMatchedHook = hook
  app.hasRouteMatchedHook = hook != nil

## Register a hook invoked when a socket or request times out.
proc onTimeoutHook*(app: ExpressApp, hook: TimeoutHook) =
  app.timeoutHook = hook
  app.server.onTimeout(proc(kind: string, remoteIp: string) =
    app.emitInspectorEvent(InspectorEvent(
      kind: iekTimeout,
      phase: kind,
      path: "",
      message: "timeout",
      statusCode: 504,
      correlationId: "",
      remoteIp: remoteIp
    ))
    if app.timeoutHook != nil:
      try:
        app.timeoutHook(kind, remoteIp)
      except CatchableError as err:
        app.reportHookFailure("timeoutHook", err)
  )

## Register a hook invoked with full metadata for timeout events.
proc onTimeoutMetadataHook*(app: ExpressApp, hook: TimeoutMetadataHook) =
  app.timeoutMetadataHook = hook
  app.server.onTimeoutMetadata(proc(
    kind: string,
    phase: string,
    remoteIp: string,
    requestSeq: uint64,
    isWebSocket: bool
  ) =
    app.emitInspectorEvent(InspectorEvent(
      kind: iekTimeout,
      phase: phase,
      path: "",
      message: kind,
      statusCode: if isWebSocket: 101 else: 504,
      correlationId: $requestSeq,
      remoteIp: remoteIp
    ))
    if app.timeoutMetadataHook != nil:
      try:
        app.timeoutMetadataHook(kind, phase, remoteIp, requestSeq, isWebSocket)
      except CatchableError as err:
        app.reportHookFailure("timeoutMetadataHook", err)
  )

## Register a hook that can transform HTTP protocol-error responses.
proc onProtocolErrorHook*(app: ExpressApp, hook: ProtocolErrorHook) =
  app.protocolErrorHook = hook

## Register a hook that receives server error messages as strings.
proc onErrorHook*(app: ExpressApp, hook: ErrorHook) =
  app.errorHook = hook
  app.server.onError(proc(message: string) =
    if app.errorHook != nil:
      try:
        app.errorHook(message)
      except CatchableError:
        discard
  )

## Register a hook that receives fatal (Defect) messages as strings.
proc onPanicHook*(app: ExpressApp, hook: PanicHook) =
  app.panicHook = hook
  app.server.onPanic(proc(message: string) =
    if app.panicHook != nil:
      try:
        app.panicHook(message)
      except CatchableError as err:
        app.reportHookFailure("panicHook", err)
  )

proc bindRequestResponse(req: Request, res: Response) {.inline.}

## Register a hook that runs before response headers are flushed.
proc onBeforeHeaders*(app: ExpressApp, hook: BeforeHeadersHook) =
  app.beforeHeadersHook = hook
  let viewsDir = app.settings.get("views", absolutePath("views"))
  let viewExt = app.settings.get("view_ext", "")
  app.server.onBeforeHeaders(proc(nativeReq: HttpRequest, nativeRes: HttpResponse) =
    if app.beforeHeadersHook == nil:
      return
    let req = acquireBorrowedRequest(nativeReq)
    req.trustProxyEnabled = app.trustProxy
    let res = acquireResponse(nativeRes, app, viewsDir, viewExt)
    bindRequestResponse(req, res)
    try:
      app.beforeHeadersHook(req, res)
      if res.headersInited and res.headers.len > 0:
        for key, value in res.headers:
          nativeRes.setHeader(key, value)
      if res.setCookies.len > 0:
        for cookie in res.setCookies:
          nativeRes.setHeader("set-cookie", cookie)
    finally:
      releaseResponse(res)
      releaseRequest(req)
  )

## Register a hook invoked before bytes are written to a socket.
proc onBeforeWrite*(app: ExpressApp, hook: BeforeWriteHook) =
  app.beforeWriteHook = hook
  if hook != nil:
    app.server.onBeforeWrite(proc(bytes: int, isWebSocket: bool) =
      try:
        app.beforeWriteHook(bytes, isWebSocket)
      except CatchableError as err:
        app.reportHookFailure("beforeWriteHook", err)
    )
  else:
    app.server.onBeforeWrite(nil)

## Register a hook invoked after a socket write completes.
proc onAfterWrite*(app: ExpressApp, hook: AfterWriteHook) =
  app.afterWriteHook = hook
  if hook != nil:
    app.server.onAfterWrite(proc(bytes: int, ok: bool, isWebSocket: bool) =
      try:
        app.afterWriteHook(bytes, ok, isWebSocket)
      except CatchableError as err:
        app.reportHookFailure("afterWriteHook", err)
    )
  else:
    app.server.onAfterWrite(nil)

## Register a hook invoked when socket write backpressure accumulates.
proc onBackpressure*(app: ExpressApp, hook: BackpressureHook) =
  app.backpressureHook = hook
  if hook != nil:
    app.server.onBackpressure(proc(bufferedBytes: int64, isWebSocket: bool) =
      try:
        app.backpressureHook(bufferedBytes, isWebSocket)
      except CatchableError as err:
        app.reportHookFailure("backpressureHook", err)
    )
  else:
    app.server.onBackpressure(nil)

## Enable or disable response compression.
proc setCompressionEnabled*(app: ExpressApp, enabled: bool) =
  app.compressionPolicy.enabled = enabled

## Min response bytes before compression is applied.
proc setCompressionMinBytes*(app: ExpressApp, bytes: int) =
  app.compressionPolicy.minBytes = max(0, bytes)

## Min fraction of bytes saved (0.0-1.0) for compression to be used.
proc setCompressionMinSavingsRatio*(app: ExpressApp, ratio: float) =
  app.compressionPolicy.minSavingsRatio = max(0.0, min(1.0, ratio))

## Set the compression level from 1 (fast) to 9 (best).
proc setCompressionLevel*(app: ExpressApp, level: int) =
  app.compressionPolicy.level = max(1, min(9, level))

## Disable compression while socket backpressure exceeds the given bytes.
proc setCompressionBackpressureThreshold*(app: ExpressApp, bytes: int) =
  app.compressionPolicy.disableWhenBackpressureAboveBytes = max(0, bytes)

## Offload compression to a worker for responses larger than the given bytes.
proc setCompressionOffloadThreshold*(app: ExpressApp, bytes: int) =
  app.compressionPolicy.offloadThresholdBytes = max(0, bytes)

## Enable or disable trust-proxy handling of client remote addresses.
proc setTrustProxy*(app: ExpressApp, enabled: bool) =
  app.trustProxy = enabled

## Whether trust-proxy handling is enabled.
proc getTrustProxy*(app: ExpressApp): bool {.inline.} =
  app.trustProxy

## Set how many trusted proxy hops are counted from the connection.
proc setTrustedProxyHops*(app: ExpressApp, hops: int) =
  discard app.settings.put("trust_proxy_hops", $max(0, hops))

## Number of trusted proxy hops counted from the connection.
proc getTrustedProxyHops*(app: ExpressApp): int =
  let raw = app.settings.get("trust_proxy_hops", "0")
  try:
    max(0, parseInt(raw))
  except ValueError:
    0

## Set a CSV allowlist of trusted proxy addresses.
proc setTrustedProxyAllowlist*(app: ExpressApp, allowlistCsv: string) =
  discard app.settings.put("trust_proxy_allowlist", allowlistCsv.strip())

## CSV allowlist of trusted proxy addresses.
proc getTrustedProxyAllowlist*(app: ExpressApp): string =
  app.settings.get("trust_proxy_allowlist", "")

proc normalizeAllowedHostToken(hostHeader: string): string =
  if hostHeader.len == 0:
    return ""
  let comma = hostHeader.find(',')
  let token =
    if comma >= 0:
      hostHeader[0..<comma].strip().toLowerAscii()
    else:
      hostHeader.strip().toLowerAscii()
  if token.len == 0 or token.len > 255:
    return ""
  for c in token:
    case c
    of 'a'..'z', '0'..'9', '.', '-', ':', '[', ']':
      discard
    else:
      return ""

  if token[0] == '[':
    let closeBracket = token.find(']')
    if closeBracket <= 1:
      return ""
    if closeBracket + 1 < token.len:
      if token[closeBracket + 1] != ':' or closeBracket + 2 >= token.len:
        return ""
      for i in (closeBracket + 2)..<token.len:
        if token[i] notin {'0'..'9'}:
          return ""
    return token[1..<closeBracket]

  var colonCount = 0
  for c in token:
    if c == ':':
      inc colonCount
  if colonCount == 0:
    return token
  if colonCount == 1:
    let sep = token.find(':')
    if sep <= 0 or sep + 1 >= token.len:
      return ""
    for i in (sep + 1)..<token.len:
      if token[i] notin {'0'..'9'}:
        return ""
    return token[0..<sep]

  # Unbracketed IPv6 literal without a port.
  token

## Restrict accepted ``Host`` headers to the list; mismatches get 421.
proc setAllowedHosts*(app: ExpressApp, hosts: seq[string]) =
  app.allowedHosts = @[]
  for host in hosts:
    let normalized = normalizeAllowedHostToken(host)
    if normalized.len > 0:
      app.allowedHosts.add(normalized)
  if hosts.len > 0:
    app.onBeforeRouteMatchAdvice(proc(req: Request, res: Response): bool =
      if app.allowedHosts.len == 0:
        return true
      let hostRaw = req.get("host")
      if hostRaw.len == 0:
        res.status(421)
        res.set("Content-Type", "text/plain")
        res.send("Misdirected Request")
        return false
      let host = normalizeAllowedHostToken(hostRaw)
      if host.len == 0:
        res.status(421)
        res.set("Content-Type", "text/plain")
        res.send("Misdirected Request")
        return false
      for allowed in app.allowedHosts:
        if host == allowed:
          return true
      res.status(421)
      res.set("Content-Type", "text/plain")
      res.send("Misdirected Request")
      return false
    )

## Override the default compression decision with a per-response hook.
proc shouldCompressWith*(app: ExpressApp, hook: ShouldCompressHook) =
  app.shouldCompressHook = hook

## Select the compression profile per response with a custom hook.
proc selectCompressionProfileWith*(app: ExpressApp, hook: SelectCompressionProfileHook) =
  app.selectCompressionProfileHook = hook

## Register a hook invoked with per-response compression results and CPU cost.
proc onCompressionResult*(app: ExpressApp, hook: CompressionResultHook) =
  app.compressionResultHook = hook

## Register a hook invoked when a response skips compression, with the reason.
proc onCompressionBypass*(app: ExpressApp, hook: CompressionBypassHook) =
  app.compressionBypassHook = hook

## Report a failed offload outcome through the app's error hook.
proc emitOffloadOutcome*[T](app: ExpressApp, outcome: OffloadOutcome[T]) =
  if app == nil or outcome.kind == ookOk:
    return
  app.emitSafeErrorHook(formatOffloadOutcomeEvent(outcome))

## Run ``handler`` once the server has started listening.
proc onStart*(app: ExpressApp, handler: proc()) =
  ## Called once the underlying server has started listening.
  app.server.onStart(handler)

## Run ``handler`` when shutdown starts, before sockets are closed.
proc onShutdown*(app: ExpressApp, handler: proc()) =
  ## Called when shutdown starts (before sockets are closed).
  app.server.onShutdown(handler)

## Run ``handler`` after the event loop exits and resources are cleaned up.
proc onStop*(app: ExpressApp, handler: proc()) =
  ## Called after the event loop exits and server resources are cleaned up.
  app.server.onStop(handler)

## Queue a warmup hook that runs once per app instance before traffic.
proc onStartupWarmup*(app: ExpressApp, hook: StartupWarmupHook) =
  if app == nil or hook == nil:
    return
  app.startupWarmupHooks.add(hook)

## Queue a startup hook that receives the app once before traffic.
proc onStartup*(app: ExpressApp, hook: proc(app: ExpressApp) {.closure.}) =
  app.onStartupWarmup(hook)

## Execute queued startup warmup hooks once per app instance.
proc runStartupWarmups*(app: ExpressApp) =
  ## Execute startup warmup hooks exactly once per app/worker instance.
  if app == nil:
    return
  let startIdx = max(0, app.startupWarmupCursor)
  if startIdx >= app.startupWarmupHooks.len:
    app.startupWarmupDone = app.startupWarmupHooks.len > 0
    return
  for i in startIdx ..< app.startupWarmupHooks.len:
    let hook = app.startupWarmupHooks[i]
    if hook == nil:
      continue
    try:
      hook(app)
    except Exception as err:
      if app.errorHook == nil:
        raise
      app.emitSafeErrorHook("startup warmup hook failed: " & err.msg)
  app.startupWarmupCursor = app.startupWarmupHooks.len
  app.startupWarmupDone = true

## Schedule ``callback`` at the next event-loop pre-hook.
proc deferPre*(app: ExpressApp, callback: proc()) =
  ## Schedule callback at next event-loop pre-hook.
  app.server.deferPre(callback)

## Schedule ``callback`` at the next event-loop post-hook.
proc `defer`*(app: ExpressApp, callback: proc()) =
  ## Schedule callback at next event-loop post-hook.
  app.server.`defer`(callback)

## Store a string setting on the app under ``key``.
proc set*(app: ExpressApp, key: string, value: string) =
  discard app.settings.put(key, value)

## Read a string setting from the app, or the empty string if unset.
proc getSetting*(app: ExpressApp, key: string): string =
  app.settings.get(key, "")

## Set the view template directory (stored as an absolute path).
proc setViewsDir*(app: ExpressApp, dir: string) =
  discard app.settings.put("views", absolutePath(dir))

## View template directory.
proc getViewsDir*(app: ExpressApp): string =
  app.settings.get("views", absolutePath("views"))

## Set the view template file extension, normalized to start with a dot.
proc setViewExtension*(app: ExpressApp, ext: string) =
  if ext.len == 0:
    discard app.settings.put("view_ext", "")
  elif ext[0] == '.':
    discard app.settings.put("view_ext", ext)
  else:
    discard app.settings.put("view_ext", "." & ext)

## View template file extension.
proc getViewExtension*(app: ExpressApp): string =
  app.settings.get("view_ext", "")

## Enable or disable compiled view template caching.
proc setViewCache*(app: ExpressApp, enabled: bool) =
  discard app.settings.put("view_cache", if enabled: "true" else: "false")

## Register a named view template from a string and compile it.
proc embedView*(app: ExpressApp, name: string, content: string) =
  if app.embeddedViews == nil:
    app.embeddedViews = newFastMap[string]()
    app.embeddedViewPlans = newFastMap[pointer]()
  discard app.embeddedViews.put(name, content)
  var oldPlan: pointer
  if app.embeddedViewPlans.tryGet(name, oldPlan) and oldPlan != nil:
    GC_unref(cast[CompiledTemplate](oldPlan))
  let compiled = compileTemplate(content)
  GC_ref(compiled)
  discard app.embeddedViewPlans.put(name, cast[pointer](compiled))

## Register a named view template and pre-render it with the given variable pairs.
proc embedView*(app: ExpressApp, name: string, content: string, pairs: openArray[(string, string)]) =
  if app.embeddedViews == nil:
    app.embeddedViews = newFastMap[string]()
    app.embeddedViewPlans = newFastMap[pointer]()
  discard app.embeddedViews.put(name, content)
  var oldPlan: pointer
  if app.embeddedViewPlans.tryGet(name, oldPlan) and oldPlan != nil:
    GC_unref(cast[CompiledTemplate](oldPlan))
  let compiled = compileTemplate(content)
  compiled.cachedRender = renderTemplateWithPairs(compiled, pairs)
  GC_ref(compiled)
  discard app.embeddedViewPlans.put(name, cast[pointer](compiled))

## Load every template file under ``dir`` as an embedded view.
proc embedViewDir*(app: ExpressApp, dir: string) =
  for file in walkDirRec(dir):
    let rel = file.relativePath(dir)
    let name = rel.changeFileExt("")
    try:
      app.embedView(name, readFile(file))
    except CatchableError:
      discard

## Compile-time macro that embeds every template file under ``dir`` as a view.
macro staticEmbedViewDir*(app: ExpressApp, dir: static[string]): untyped =
  result = newStmtList()
  let absDir = if dir.isAbsolute: dir else: getProjectPath() / dir
  for file in walkDirRec(absDir):
    let rel = file.relativePath(absDir)
    let name = rel.changeFileExt("")
    let content = slurp(file)
    let nameLit = newStrLitNode(name)
    let contentLit = newStrLitNode(content)
    result.add quote do:
      `app`.embedView(`nameLit`, `contentLit`)

## Compile-time macro that embeds the single file ``file`` as the view ``name``.
##
## Relative paths resolve against the project path first, then the current
## working directory (compile-time `PWD` environment variable, POSIX).
macro staticEmbedView*(app: ExpressApp, name: static[string], file: static[string]): untyped =
  result = newStmtList()
  let envCwd = getEnv("PWD")
  let absFile = if file.isAbsolute:
    file
  elif (getProjectPath() / file).fileExists():
    getProjectPath() / file
  elif envCwd.len > 0 and (envCwd / file).fileExists():
    envCwd / file
  else:
    file
  let content = slurp(absFile)
  let nameLit = newStrLitNode(name)
  let contentLit = newStrLitNode(content)
  result.add quote do:
    `app`.embedView(`nameLit`, `contentLit`)

## Whether compiled view template caching is enabled.
proc getViewCache*(app: ExpressApp): bool =
  let raw = app.settings.get("view_cache", "true")
  not (raw == "false" or raw == "0" or raw == "off")

## Set the runtime environment name; disables the view cache in development.
proc setEnvironment*(app: ExpressApp, env: string) =
  discard app.settings.put("env", env)
  let isDev = env == "development" or env == "dev"
  app.setViewCache(not isDev)

## Current runtime environment name (default ``production``).
proc getEnvironment*(app: ExpressApp): string =
  app.settings.get("env", "production")

## True when the environment is ``development`` or ``dev``.
proc isDevelopment*(app: ExpressApp): bool =
  let env = app.getEnvironment()
  env == "development" or env == "dev"

## True when the environment is not a development environment.
proc isProduction*(app: ExpressApp): bool =
  not app.isDevelopment()

## Queue a startup prewarm pass for the request/response context pools.
proc prewarmContextPoolsOnStartup*(
  app: ExpressApp,
  requestCount: int = -1,
  responseCount: int = -1
) =
  ## Queue an explicit startup prewarm pass for request/response context pools.
  if app == nil:
    return
  let reqTarget = if requestCount >= 0: requestCount else: app.contextPoolPrewarm
  let resTarget = if responseCount >= 0: responseCount else: app.contextPoolPrewarm
  app.onStartupWarmup(proc(ctx: ExpressApp) =
    prewarmContextPools(max(0, reqTarget), max(0, resTarget))
  )

## Queue startup precompile hooks for the given views; returns count queued.
proc precompileViewsOnStartup*(app: ExpressApp, viewNames: openArray[string]): int =
  ## Queue startup template precompile hooks for a set of views.
  if app == nil:
    return 0
  for viewName in viewNames:
    let target = viewName.strip()
    if target.len == 0:
      continue
    app.onStartupWarmup(proc(ctx: ExpressApp) =
      if not precompileViewTemplate(ctx.getViewsDir(), ctx.getViewExtension(), target) and ctx.errorHook != nil:
        ctx.errorHook("startup template precompile failed: " & target)
    )
    inc result

# WebSocket handlers
## Register the default WebSocket message handler for upgraded connections.
proc ws*(app: ExpressApp, handler: WsHandler) =
  app.wsHandler = handler

## Register a zero-copy WebSocket handler for complete uncompressed frames.
proc wsRaw*(app: ExpressApp, handler: WsRawHandler) =
  ## Register an opt-in zero-copy WebSocket message handler for complete,
  ## uncompressed, unfragmented frames. The payload pointer is callback-scoped.
  app.wsRawHandler = handler

## Register a hook invoked when a WebSocket connection opens.
proc onWsOpen*(app: ExpressApp, handler: WsOpenHandler) =
  app.wsOpenHandler = handler

## Register a hook invoked when a WebSocket connection closes.
proc onWsClose*(app: ExpressApp, handler: WsCloseHandler) =
  app.wsCloseHandler = handler

## Register a hook invoked when a WebSocket send buffer drains.
proc onWsDrain*(app: ExpressApp, handler: WsDrainHandler) =
  app.wsDrainHandler = handler

## Register a hook invoked when a queued WebSocket message is dropped.
proc onWsDropped*(app: ExpressApp, handler: WsDroppedHandler) =
  app.wsDroppedHandler = handler

## Register a hook invoked when a WebSocket send buffer hits the high-water mark.
proc onWsHighWater*(app: ExpressApp, handler: WsHighWaterHandler) =
  app.wsHighWaterHandler = handler

## Set a custom validator for WebSocket upgrade requests.
proc setWsUpgradeValidator*(app: ExpressApp, validator: WsUpgradeValidator) =
  app.wsUpgradeValidator = validator

## Allow WebSocket upgrades from the given ``Origin``; use ``*`` for any origin.
proc allowWsOrigin*(app: ExpressApp, origin: string) =
  if app == nil:
    return
  let normalized = origin.strip()
  if normalized.len == 0:
    return
  app.wsAllowedOrigins.add(normalized)

## Allow WebSocket upgrades on the given path.
proc allowWsPath*(app: ExpressApp, path: string) =
  if app == nil:
    return
  var normalized = path.strip()
  if normalized.len == 0:
    return
  if normalized[0] != '/':
    normalized = "/" & normalized
  app.wsAllowedPaths.add(normalized)

## Clear the allowed WebSocket origin list.
proc clearWsOriginAllowlist*(app: ExpressApp) =
  if app != nil:
    app.wsAllowedOrigins.setLen(0)

## Clear the allowed WebSocket path list.
proc clearWsPathAllowlist*(app: ExpressApp) =
  if app != nil:
    app.wsAllowedPaths.setLen(0)

proc hasUnsafeOriginBytes(value: string): bool {.inline.} =
  for ch in value:
    if ch == '\r' or ch == '\n' or ch == '\0':
      return true
  false

proc normalizedWsAuthority(value: string): string =
  var authority = value.strip().toLowerAscii()
  if authority.len == 0 or authority.find('@') >= 0:
    return ""
  if authority[0] == '[':
    let closeIdx = authority.find(']')
    if closeIdx < 0:
      return ""
    if closeIdx + 1 < authority.len and authority[closeIdx + 1] != ':':
      return ""
    return authority
  let colon = authority.rfind(':')
  if colon > 0:
    let portPart = authority[colon + 1 .. ^1]
    if portPart.len == 0:
      return ""
    for ch in portPart:
      if ch < '0' or ch > '9':
        return ""
  authority

proc originMatchesHost(origin, host: string): bool =
  let trimmed = origin.strip()
  if trimmed.len == 0 or hasUnsafeOriginBytes(trimmed):
    return false
  let schemeSep = trimmed.find("://")
  if schemeSep <= 0:
    return false
  let scheme = trimmed[0 ..< schemeSep].toLowerAscii()
  if scheme != "http" and scheme != "https":
    return false
  var authorityEnd = trimmed.len
  var i = schemeSep + 3
  while i < trimmed.len:
    if trimmed[i] == '/' or trimmed[i] == '?' or trimmed[i] == '#':
      authorityEnd = i
      break
    inc i
  if authorityEnd <= schemeSep + 3:
    return false
  let originAuthority = normalizedWsAuthority(trimmed[schemeSep + 3 ..< authorityEnd])
  let requestAuthority = normalizedWsAuthority(host)
  originAuthority.len > 0 and originAuthority == requestAuthority

proc wsOriginAllowedByPolicy(app: ExpressApp, nativeReq: HttpRequest): bool =
  if nativeReq == nil:
    return false
  nativeReq.ensureHeadersPopulated()
  let origin =
    if nativeReq.headers != nil:
      nativeReq.headers.getOrDefault("origin", "").strip()
    else:
      ""
  if app.wsAllowedOrigins.len > 0:
    for candidate in app.wsAllowedOrigins:
      if candidate == "*":
        return true
      if cmpIgnoreCase(origin, candidate) == 0:
        return true
    return false
  if origin.len == 0:
    return true
  let host =
    if nativeReq.headers != nil:
      nativeReq.headers.getOrDefault("host", "")
    else:
      ""
  originMatchesHost(origin, host)

## Publish a message to all WebSocket subscribers of ``topic``; returns sockets sent.
proc publish*(app: ExpressApp, topic: string, message: string, binary: bool = false): int {.inline.} =
  app.server.publish(topic, message, binary)

## Publish a prepared message to all WebSocket subscribers of ``topic``.
proc publishPrepared*(app: ExpressApp, topic: string, msg: PreparedWsMessage): int {.inline.} =
  app.server.publishPrepared(topic, msg)

## Schedule ``callback`` on the server event loop every ``intervalMs``.
proc setInterval*(app: ExpressApp, callback: proc(), intervalMs: int) =
  app.server.setInterval(callback, intervalMs)

# Router methods
proc addAsyncRoute(router: Router, methodKind: nim_usockets.HttpMethod, pattern: string, handler: AsyncHandler) =
  router.ensureRouterMutable()
  let paramNames = parsePattern(pattern)
  let fullPattern = router.basePath & pattern
  let meta = compileRouteMeta(fullPattern)
  let route = Route(
    kind: rkAsync,
    pattern: fullPattern,
    paramNames: paramNames,
    isDynamic: paramNames.len > 0 or ('*' in pattern),
    staticPrefix: meta.staticPrefix,
    prefixBucketKey: routePrefixBucketKey(meta.staticPrefix),
    firstLiteralSegment: meta.firstLiteralSegment,
    minSegmentCount: meta.minSegmentCount,
    maxSegmentCount: meta.maxSegmentCount,
    asyncHandler: handler,
    middlewares: @[],
    compiledMiddlewares: @[]
  )
  router.addRouteToGroup(methodKind, route)

proc addSyncRoute(router: Router, methodKind: nim_usockets.HttpMethod, pattern: string, handler: SyncHandler) =
  router.ensureRouterMutable()
  let paramNames = parsePattern(pattern)
  let fullPattern = router.basePath & pattern
  let meta = compileRouteMeta(fullPattern)
  let route = Route(
    kind: rkSync,
    pattern: fullPattern,
    paramNames: paramNames,
    isDynamic: paramNames.len > 0 or ('*' in pattern),
    staticPrefix: meta.staticPrefix,
    prefixBucketKey: routePrefixBucketKey(meta.staticPrefix),
    firstLiteralSegment: meta.firstLiteralSegment,
    minSegmentCount: meta.minSegmentCount,
    maxSegmentCount: meta.maxSegmentCount,
    syncHandler: handler,
    middlewares: @[],
    compiledMiddlewares: @[]
  )
  router.addRouteToGroup(methodKind, route)

## Register an async ``GET`` route on the router, joined with its base path.
proc getAsync*(router: Router, pattern: string, handler: AsyncHandler) =
  router.addAsyncRoute(hmGet, pattern, handler)

## Register an async ``POST`` route on the router, joined with its base path.
proc postAsync*(router: Router, pattern: string, handler: AsyncHandler) =
  router.addAsyncRoute(hmPost, pattern, handler)

## Register an async ``PUT`` route on the router, joined with its base path.
proc putAsync*(router: Router, pattern: string, handler: AsyncHandler) =
  router.addAsyncRoute(hmPut, pattern, handler)

## Register an async ``DELETE`` route on the router, joined with its base path.
proc deleteAsync*(router: Router, pattern: string, handler: AsyncHandler) =
  router.addAsyncRoute(hmDelete, pattern, handler)

## Register a sync ``GET`` route on the router, joined with its base path.
proc get*(router: Router, pattern: string, handler: SyncHandler) =
  router.addSyncRoute(hmGet, pattern, handler)

## Register a sync ``POST`` route on the router, joined with its base path.
proc post*(router: Router, pattern: string, handler: SyncHandler) =
  router.addSyncRoute(hmPost, pattern, handler)

## Register a sync ``PUT`` route on the router, joined with its base path.
proc put*(router: Router, pattern: string, handler: SyncHandler) =
  router.addSyncRoute(hmPut, pattern, handler)

## Register a sync ``DELETE`` route on the router, joined with its base path.
proc delete*(router: Router, pattern: string, handler: SyncHandler) =
  router.addSyncRoute(hmDelete, pattern, handler)

## Add middleware that applies to every route on the router.
proc use*(router: Router, middleware: AsyncMiddleware) =
  router.ensureRouterMutable()
  router.middlewares.add(middleware)

proc clearDynamicBuckets(buckets: var DynamicRouteBuckets) {.inline.} =
  buckets.anyPrefix.setLen(0)
  buckets.fallbackOrder.setLen(0)
  for i in 0..<RoutePrefixBucketCount:
    buckets.byPrefix[i].setLen(0)

proc compileMethodArtifacts(
  routes: var seq[Route],
  exactRoutes: FastMap[int64],
  firstDynamic: var int,
  buckets: var DynamicRouteBuckets
) =
  exactRoutes.clear()
  discard exactRoutes.reserve(max(8, routes.len))
  firstDynamic = -1
  buckets.clearDynamicBuckets()
  if routes.len == 0:
    return
  buckets.fallbackOrder = newSeqOfCap[int32](routes.len)
  buckets.anyPrefix = newSeqOfCap[int32](max(8, routes.len div 4))
  for i in 0..<routes.len:
    routes[i].routeListIdx = int32(i)
    if routes[i].isDynamic:
      if firstDynamic < 0:
        firstDynamic = i
      let idx = int32(i)
      buckets.fallbackOrder.add(idx)
      if routes[i].prefixBucketKey < 0:
        buckets.anyPrefix.add(idx)
      else:
        buckets.byPrefix[routes[i].prefixBucketKey.int].add(idx)
    elif not exactRoutes.contains(routes[i].pattern):
      # Keep first registration to preserve route-order semantics.
      discard exactRoutes.put(routes[i].pattern, i.int64)

## Rebuild exact-match and dynamic-route lookup artifacts for all methods.
proc compileRouterArtifacts*(router: Router) =
  compileMethodArtifacts(router.getRoutes, router.getExactRoutes, router.firstDynamicGet, router.getDynamicBuckets)
  compileMethodArtifacts(router.postRoutes, router.postExactRoutes, router.firstDynamicPost, router.postDynamicBuckets)
  compileMethodArtifacts(router.putRoutes, router.putExactRoutes, router.firstDynamicPut, router.putDynamicBuckets)
  compileMethodArtifacts(router.deleteRoutes, router.deleteExactRoutes, router.firstDynamicDelete, router.deleteDynamicBuckets)
  compileMethodArtifacts(router.patchRoutes, router.patchExactRoutes, router.firstDynamicPatch, router.patchDynamicBuckets)
  compileMethodArtifacts(router.headRoutes, router.headExactRoutes, router.firstDynamicHead, router.headDynamicBuckets)
  compileMethodArtifacts(router.optionsRoutes, router.optionsExactRoutes, router.firstDynamicOptions, router.optionsDynamicBuckets)
  router.artifactsCompiled = true

proc routeCacheHash(path: string, methodOrd: int): uint64 {.inline.} =
  var h = 0xcbf29ce484222325'u64 xor uint64(methodOrd)
  var i = 0
  let pLen = path.len
  while i + 7 < pLen:
    var chunk: uint64
    copyMem(addr chunk, unsafeAddr path[i], 8)
    h = (h xor chunk) * 0x100000001b3'u64
    i += 8
  while i < pLen:
    h = (h xor uint64(path[i])) * 0x100000001b3'u64
    inc i
  h

proc findRoute(
  router: Router,
  methodKind: nim_usockets.HttpMethod,
  path: string,
  params: var FastMap[string]
): ptr Route =
  if not router.artifactsCompiled:
    router.compileRouterArtifacts()

  let cacheKey = routeCacheHash(path, ord(methodKind))
  let cacheSlot = int(cacheKey and 127)
  if router.routeCacheValid[cacheSlot] and
     router.routeCacheKeys[cacheSlot] == cacheKey and
     router.routeCacheMethodKinds[cacheSlot] == uint8(ord(methodKind)):
    let idx = router.routeCacheRouteIdxs[cacheSlot]
    let methodRoutes = routesForMethod(router, methodKind)
    if methodRoutes != nil and idx >= 0 and idx < int32(methodRoutes[].len):
      let routePtr = addr methodRoutes[][idx]
      if routePtr.isDynamic:
        if matchRoutePattern(routePtr.pattern, path):
          materializeParams(routePtr.pattern, routePtr.paramNames, path, params)
          return routePtr
      else:
        if routePtr.pattern == path:
          return routePtr

  var pathSegCount = -1
  var firstSegStart = -1
  var firstSegLen = 0
  let pathPrefixKey = int(routePrefixBucketKey(path))

  template ensurePathMeta() =
    if pathSegCount < 0:
      analyzePathSegments(path, pathSegCount, firstSegStart, firstSegLen)

  template scanDynamicCandidates(
    routesRef: ptr seq[Route],
    bucketsRef: ptr DynamicRouteBuckets,
    endBefore: int = -1
  ): ptr Route =
    block:
      var found: ptr Route = nil
      let anyRef = addr bucketsRef[].anyPrefix
      let keyRef =
        if pathPrefixKey >= 0:
          addr bucketsRef[].byPrefix[pathPrefixKey]
        else:
          nil
      var anyIdx = 0
      var keyIdx = 0
      while true:
        var routeIdx = -1
        if keyRef == nil:
          if anyIdx >= anyRef[].len:
            break
          routeIdx = int(anyRef[][anyIdx])
          inc anyIdx
        else:
          let hasAny = anyIdx < anyRef[].len
          let hasKey = keyIdx < keyRef[].len
          if not hasAny and not hasKey:
            break
          if hasAny and (not hasKey or anyRef[][anyIdx] < keyRef[][keyIdx]):
            routeIdx = int(anyRef[][anyIdx])
            inc anyIdx
          else:
            routeIdx = int(keyRef[][keyIdx])
            inc keyIdx

        if endBefore >= 0 and routeIdx >= endBefore:
          break

        ensurePathMeta()
        if routeFastReject(routesRef[][routeIdx], path, pathSegCount, firstSegStart, firstSegLen):
          continue
        if matchRoutePattern(routesRef[][routeIdx].pattern, path):
          found = addr routesRef[][routeIdx]
          break
      if found != nil:
        materializeParams(found.pattern, found.paramNames, path, params)
      found

  template findInGroup(routesExpr, exactExpr, firstDynamicExpr, bucketsExpr: untyped): ptr Route =
    block:
      let routesRef = routesExpr
      let exactRef = exactExpr
      let firstDyn = firstDynamicExpr
      let bucketsRef = bucketsExpr
      let idx = int(exactRef[].get(path, -1'i64))
      # Safe fast path: no earlier dynamic route can preempt this exact match.
      if idx >= 0 and (firstDyn < 0 or idx < firstDyn):
        return addr routesRef[][idx]
      if firstDyn < 0:
        nil
      elif idx >= 0:
        let dynamicMatch = scanDynamicCandidates(routesRef, bucketsRef, idx)
        if dynamicMatch != nil:
          dynamicMatch
        else:
          addr routesRef[][idx]
      else:
        scanDynamicCandidates(routesRef, bucketsRef)

  var routes: ptr seq[Route] = nil
  var exactRoutes: ptr FastMap[int64] = nil
  var dynamicBuckets: ptr DynamicRouteBuckets = nil
  var firstDynamic = -1
  var fallbackToGet = false
  case methodKind
  of hmGet:
    routes = addr router.getRoutes
    exactRoutes = addr router.getExactRoutes
    dynamicBuckets = addr router.getDynamicBuckets
    firstDynamic = router.firstDynamicGet
  of hmPost:
    routes = addr router.postRoutes
    exactRoutes = addr router.postExactRoutes
    dynamicBuckets = addr router.postDynamicBuckets
    firstDynamic = router.firstDynamicPost
  of hmPut:
    routes = addr router.putRoutes
    exactRoutes = addr router.putExactRoutes
    dynamicBuckets = addr router.putDynamicBuckets
    firstDynamic = router.firstDynamicPut
  of hmDelete:
    routes = addr router.deleteRoutes
    exactRoutes = addr router.deleteExactRoutes
    dynamicBuckets = addr router.deleteDynamicBuckets
    firstDynamic = router.firstDynamicDelete
  of hmPatch:
    routes = addr router.patchRoutes
    exactRoutes = addr router.patchExactRoutes
    dynamicBuckets = addr router.patchDynamicBuckets
    firstDynamic = router.firstDynamicPatch
  of hmHead:
    routes = addr router.headRoutes
    exactRoutes = addr router.headExactRoutes
    dynamicBuckets = addr router.headDynamicBuckets
    firstDynamic = router.firstDynamicHead
    # RFC 9110 §9.3.2: HEAD semantics mirror GET metadata; fallback permitted.
    fallbackToGet = true
  of hmOptions:
    routes = addr router.optionsRoutes
    exactRoutes = addr router.optionsExactRoutes
    dynamicBuckets = addr router.optionsDynamicBuckets
    firstDynamic = router.firstDynamicOptions
  else:
    return nil

  let direct = findInGroup(routes, exactRoutes, firstDynamic, dynamicBuckets)
  if direct != nil:
    router.routeCacheKeys[cacheSlot] = cacheKey
    router.routeCacheMethodKinds[cacheSlot] = uint8(ord(methodKind))
    router.routeCacheRouteIdxs[cacheSlot] = direct.routeListIdx
    router.routeCacheValid[cacheSlot] = true
    return direct

  if fallbackToGet:
    let fallbackResult = findInGroup(
      addr router.getRoutes,
      addr router.getExactRoutes,
      router.firstDynamicGet,
      addr router.getDynamicBuckets
    )
    if fallbackResult != nil:
      router.routeCacheKeys[cacheSlot] = cacheKey
      router.routeCacheMethodKinds[cacheSlot] = uint8(ord(hmGet))
      router.routeCacheRouteIdxs[cacheSlot] = fallbackResult.routeListIdx
      router.routeCacheValid[cacheSlot] = true
      return fallbackResult
  nil

## Find the route matching ``methodKind`` and ``path``; fills ``params`` on match.
proc findRouteForMethod*(
  router: Router,
  methodKind: nim_usockets.HttpMethod,
  path: string,
  params: var FastMap[string]
): ptr Route {.inline.} =
  findRoute(router, methodKind, path, params)

when defined(singleThread):
  var
    methodProbeParams: FastMap[string]
else:
  var
    methodProbeParams {.threadvar.}: FastMap[string]

proc hasRouteForMethod(router: Router, methodKind: nim_usockets.HttpMethod, path: string): bool {.inline.} =
  if methodProbeParams == nil:
    methodProbeParams = newFastMap[string]()
    discard methodProbeParams.reserve(8)
  findRoute(router, methodKind, path, methodProbeParams) != nil

proc httpMethodToken(methodKind: nim_usockets.HttpMethod): string {.inline.} =
  case methodKind
  of hmGet: "GET"
  of hmPost: "POST"
  of hmPut: "PUT"
  of hmDelete: "DELETE"
  of hmPatch: "PATCH"
  of hmHead: "HEAD"
  of hmOptions: "OPTIONS"
  of hmConnect: "CONNECT"
  of hmTrace: "TRACE"

proc buildAllowHeader(router: Router, path: string): string =
  var first = true
  var hasGet = false
  var hasHead = false

  for methodKind in [hmGet, hmHead, hmPost, hmPut, hmDelete, hmPatch, hmOptions]:
    if hasRouteForMethod(router, methodKind, path):
      if methodKind == hmGet:
        hasGet = true
      elif methodKind == hmHead:
        hasHead = true
      if not first:
        result.add(", ")
      result.add(httpMethodToken(methodKind))
      first = false

  # RFC 9110: GET implies HEAD when HEAD is not explicitly defined.
  if hasGet and not hasHead:
    if not first:
      result.add(", ")
    result.add("HEAD")

proc buildServerAllowHeader(router: Router): string =
  var first = true
  template addMethodIf(cond: bool, token: string) =
    if cond:
      if not first:
        result.add(", ")
      result.add(token)
      first = false

  addMethodIf(router.getRoutes.len > 0, "GET")
  addMethodIf(router.getRoutes.len > 0 or router.headRoutes.len > 0, "HEAD")
  addMethodIf(router.postRoutes.len > 0, "POST")
  addMethodIf(router.putRoutes.len > 0, "PUT")
  addMethodIf(router.deleteRoutes.len > 0, "DELETE")
  addMethodIf(router.patchRoutes.len > 0, "PATCH")
  addMethodIf(router.optionsRoutes.len > 0 or result.len > 0, "OPTIONS")

proc routeHandlerKindToken(route: Route): string {.inline.} =
  if route.kind == rkAsync:
    "async"
  else:
    "sync"

proc appendRouteManifestEntries(
  entries: var seq[RouteManifestEntry],
  methodToken: string,
  routes: seq[Route],
  baseMiddlewareCount: int
) =
  var firstIndexByPattern = initTable[string, int]()
  for idx, route in routes:
    var entry = RouteManifestEntry(
      httpMethod: methodToken,
      pattern: route.pattern,
      handlerKind: route.routeHandlerKindToken(),
      dynamic: route.isDynamic,
      middlewareCount: if route.compiledMiddlewares.len > 0:
        route.compiledMiddlewares.len
      else:
        baseMiddlewareCount + route.middlewares.len,
      shadowed: false,
      warning: ""
    )
    if firstIndexByPattern.hasKey(route.pattern):
      entry.shadowed = true
      entry.warning = "shadowed by earlier route index " & $firstIndexByPattern[route.pattern]
    else:
      firstIndexByPattern[route.pattern] = idx
    entries.add(entry)

## List every registered route with method, handler kind, and middleware count.
proc routeManifestEntries*(app: ExpressApp): seq[RouteManifestEntry] =
  if app == nil or app.router == nil:
    return @[]
  result = @[]
  let baseCount =
    if app.compiledBaseMiddlewares.len > 0:
      app.compiledBaseMiddlewares.len
    else:
      app.middlewares.len + app.router.middlewares.len
  appendRouteManifestEntries(result, "GET", app.router.getRoutes, baseCount)
  appendRouteManifestEntries(result, "POST", app.router.postRoutes, baseCount)
  appendRouteManifestEntries(result, "PUT", app.router.putRoutes, baseCount)
  appendRouteManifestEntries(result, "DELETE", app.router.deleteRoutes, baseCount)
  appendRouteManifestEntries(result, "PATCH", app.router.patchRoutes, baseCount)
  appendRouteManifestEntries(result, "HEAD", app.router.headRoutes, baseCount)
  appendRouteManifestEntries(result, "OPTIONS", app.router.optionsRoutes, baseCount)

## Render the route manifest as a JSON array string.
proc routeManifestJson*(app: ExpressApp): string =
  let entries = app.routeManifestEntries()
  var payload = newJArray()
  for entry in entries:
    let node = %*{
      "method": entry.httpMethod,
      "pattern": entry.pattern,
      "handler": entry.handlerKind,
      "dynamic": entry.dynamic,
      "middleware_count": entry.middlewareCount,
      "shadowed": entry.shadowed
    }
    if entry.warning.len > 0:
      node["warning"] = %entry.warning
    payload.add(node)
  $payload

## Print route manifest diagnostics when the server starts listening.
proc setRouteManifestOnStartup*(app: ExpressApp, enabled: bool = true) =
  if app == nil:
    return
  app.routeManifestOnStartup = enabled

## Whether the route manifest is printed at startup.
proc getRouteManifestOnStartup*(app: ExpressApp): bool {.inline.} =
  if app == nil:
    return false
  app.routeManifestOnStartup

proc emitRouteManifestDiagnostics(app: ExpressApp) =
  if app == nil:
    return
  let entries = app.routeManifestEntries()
  for entry in entries:
    var line = "[route] " & entry.httpMethod & " " & entry.pattern &
      " handler=" & entry.handlerKind &
      " middleware=" & $entry.middlewareCount &
      " dynamic=" & $(if entry.dynamic: 1 else: 0)
    if entry.shadowed:
      line.add(" shadowed=1")
      if entry.warning.len > 0:
        line.add(" warning=" & entry.warning)
    echo line

proc sendRouteMiss(app: ExpressApp, req: Request, res: Response) {.inline.} =
  if req.methodKind == hmConnect or req.methodKind == hmTrace:
    # RFC 9110 §15.6.2: unsupported functionality/method handling -> 501.
    res.status(501).send("Not Implemented")
    return

  if req.methodKind == hmOptions and req.path == "*":
    let allowAll = buildServerAllowHeader(app.router)
    if allowAll.len > 0:
      res.status(204).set("allow", allowAll).send("")
    else:
      res.status(204).send("")
    return

  let allow = buildAllowHeader(app.router, req.path)
  if allow.len > 0:
    if req.methodKind == hmOptions:
      res.status(204).set("allow", allow).send("")
    else:
      res.status(405).set("allow", allow).send("Method Not Allowed")
  else:
    res.notFound()

proc hasAsyncRoutes(routes: seq[Route]): bool =
  for route in routes:
    if route.kind == rkAsync:
      return true
  false

proc routerHasAsyncRoutes(router: Router): bool =
  hasAsyncRoutes(router.getRoutes) or
  hasAsyncRoutes(router.postRoutes) or
  hasAsyncRoutes(router.putRoutes) or
  hasAsyncRoutes(router.deleteRoutes) or
  hasAsyncRoutes(router.patchRoutes) or
  hasAsyncRoutes(router.headRoutes) or
  hasAsyncRoutes(router.optionsRoutes)

proc combineMiddlewares(a, b: seq[AsyncMiddleware]): seq[AsyncMiddleware] =
  if a.len == 0:
    return b
  if b.len == 0:
    return a
  result = newSeqOfCap[AsyncMiddleware](a.len + b.len)
  result.add(a)
  result.add(b)

proc compileRoutePipelines(routes: var seq[Route], base: seq[AsyncMiddleware]) =
  for i in 0..<routes.len:
    if routes[i].middlewares.len == 0:
      routes[i].compiledMiddlewares = base
    else:
      routes[i].compiledMiddlewares = combineMiddlewares(base, routes[i].middlewares)

proc routeGroupHasCustomMiddlewares(routes: seq[Route]): bool =
  for route in routes:
    if route.middlewares.len > 0:
      return true
  false

proc routerHasCustomMiddlewares(router: Router): bool =
  routeGroupHasCustomMiddlewares(router.getRoutes) or
  routeGroupHasCustomMiddlewares(router.postRoutes) or
  routeGroupHasCustomMiddlewares(router.putRoutes) or
  routeGroupHasCustomMiddlewares(router.deleteRoutes) or
  routeGroupHasCustomMiddlewares(router.patchRoutes) or
  routeGroupHasCustomMiddlewares(router.headRoutes) or
  routeGroupHasCustomMiddlewares(router.optionsRoutes)

proc compileSyncPipelines(routes: var seq[Route], baseSyncMiddlewares: seq[SyncNextMiddleware], allBaseSync: bool) =
  for i in 0..<routes.len:
    if allBaseSync and routes[i].middlewares.len == 0 and routes[i].syncMiddlewares.len >= 0:
      routes[i].compiledSyncMiddlewares = baseSyncMiddlewares & routes[i].syncMiddlewares
      routes[i].allMiddlewaresSync = routes[i].compiledMiddlewares.len == 0 or
        (allBaseSync and routes[i].middlewares.len == 0)
    else:
      routes[i].allMiddlewaresSync = false

proc compileMiddlewarePipelines(app: ExpressApp) =
  app.allBaseSyncMiddlewares = app.middlewares.len == 0 and app.router.middlewares.len == 0 and
    app.syncMiddlewares.len + app.router.middlewares.len >= 0
  if app.allBaseSyncMiddlewares:
    app.compiledBaseMiddlewares = @[]
    app.compiledBaseSyncMiddlewares = app.syncMiddlewares
  else:
    app.compiledBaseMiddlewares = combineMiddlewares(app.orderedMiddlewares, app.router.middlewares)
    app.compiledBaseSyncMiddlewares = @[]
  compileRoutePipelines(app.router.getRoutes, app.compiledBaseMiddlewares)
  compileRoutePipelines(app.router.postRoutes, app.compiledBaseMiddlewares)
  compileRoutePipelines(app.router.putRoutes, app.compiledBaseMiddlewares)
  compileRoutePipelines(app.router.deleteRoutes, app.compiledBaseMiddlewares)
  compileRoutePipelines(app.router.patchRoutes, app.compiledBaseMiddlewares)
  compileRoutePipelines(app.router.headRoutes, app.compiledBaseMiddlewares)
  compileRoutePipelines(app.router.optionsRoutes, app.compiledBaseMiddlewares)
  compileSyncPipelines(app.router.getRoutes, app.compiledBaseSyncMiddlewares, app.allBaseSyncMiddlewares)
  compileSyncPipelines(app.router.postRoutes, app.compiledBaseSyncMiddlewares, app.allBaseSyncMiddlewares)
  compileSyncPipelines(app.router.putRoutes, app.compiledBaseSyncMiddlewares, app.allBaseSyncMiddlewares)
  compileSyncPipelines(app.router.deleteRoutes, app.compiledBaseSyncMiddlewares, app.allBaseSyncMiddlewares)
  compileSyncPipelines(app.router.patchRoutes, app.compiledBaseSyncMiddlewares, app.allBaseSyncMiddlewares)
  compileSyncPipelines(app.router.headRoutes, app.compiledBaseSyncMiddlewares, app.allBaseSyncMiddlewares)
  compileSyncPipelines(app.router.optionsRoutes, app.compiledBaseSyncMiddlewares, app.allBaseSyncMiddlewares)

proc markRequestTimedOut(app: ExpressApp, req: Request, res: Response) =
  if req == nil:
    return
  if app != nil:
    app.emitInspectorEvent(InspectorEvent(
      kind: iekTimeout,
      phase: "request_timeout",
      path: req.path,
      message: "request exceeded timeout budget",
      statusCode: 504,
      correlationId: req.correlationId,
      remoteIp: ""
    ))
  if res != nil and not res.finished:
    res.status(504).send("Gateway Timeout")
  discard req.notifyRequestTimeout()
  req.clearRequestTimeoutBudget()
  req.locals["_timed_out"] = "1"

proc requestSocketKey(res: Response): uint64 {.inline.} =
  if res == nil or res.native == nil or res.native.socket == nil:
    return 0'u64
  cast[uint64](cast[uint](res.native.socket))

proc bindRequestResponse(req: Request, res: Response) {.inline.} =
  if req == nil or res == nil:
    return
  res.request = req
  req.requestSeq =
    if res.native != nil:
      res.native.requestSeq
    else:
      0'u64

proc effectiveRequestSeq(req: Request): uint64 {.inline.} =
  if req == nil:
    return 0'u64
  req.requestSeq

proc registerActiveAsyncRequest(req: Request, res: Response) =
  if req == nil:
    return
  activeAsyncRequests.add(ActiveAsyncRequest(
    req: req,
    requestSeq: req.effectiveRequestSeq(),
    socketKey: requestSocketKey(res)
  ))

proc unregisterActiveAsyncRequest(req: Request) =
  if req == nil or activeAsyncRequests.len == 0:
    return
  var i = activeAsyncRequests.len - 1
  while i >= 0:
    if activeAsyncRequests[i].req == req:
      activeAsyncRequests[i] = activeAsyncRequests[^1]
      activeAsyncRequests.setLen(activeAsyncRequests.len - 1)
      break
    dec i

proc notifyAsyncDisconnect(remoteIp: string, requestSeq: uint64, socketKey: uint64) =
  if activeAsyncRequests.len == 0:
    return
  var matched = false
  for item in activeAsyncRequests:
    if item.req == nil:
      continue
    if socketKey != 0'u64 and item.socketKey == socketKey:
      discard item.req.notifyRequestDisconnect()
      matched = true
      continue
    if requestSeq != 0'u64 and item.requestSeq == requestSeq:
      discard item.req.notifyRequestDisconnect()
      matched = true
  if matched:
    return
  if remoteIp.len == 0:
    return
  for item in activeAsyncRequests:
    if item.req != nil and item.req.native != nil and item.req.native.remoteIp == remoteIp:
      discard item.req.notifyRequestDisconnect()

## Test access: register a request in the active async request tracking.
proc registerActiveAsyncRequestForTest*(req: Request, res: Response = nil) =
  registerActiveAsyncRequest(req, res)

## Test access: unregister a request from active async request tracking.
proc unregisterActiveAsyncRequestForTest*(req: Request) =
  unregisterActiveAsyncRequest(req)

## Test access: notify in-flight async requests of a client disconnect by remote IP.
proc notifyAsyncDisconnectByRemoteIpForTest*(remoteIp: string) =
  notifyAsyncDisconnect(remoteIp, 0'u64, 0'u64)

## Test access: notify in-flight async requests of a client disconnect.
proc notifyAsyncDisconnectForTest*(remoteIp: string, requestSeq: uint64, socketKey: uint64) =
  notifyAsyncDisconnect(remoteIp, requestSeq, socketKey)

proc cancelTimedOutFuture(fut: Future[void]) {.inline.} =
  if fut == nil or fut.finished:
    return
  when compiles(cancel(fut)):
    try:
      cancel(fut)
    except CatchableError:
      discard

proc runSyncMiddlewares(app: ExpressApp, req: Request, res: Response, middlewares: seq[SyncNextMiddleware]): bool =
  var idx = 0
  while idx < middlewares.len and not res.finished:
    syncNextFlag = false
    try:
      middlewares[idx](req, res, sharedSyncNext)
    except CatchableError as err:
      app.emitSafeErrorHook("class=sync_middleware_error path=" & req.path & " error=" & err.msg)
      app.runErrorAdvices(req, res, "middleware", err.msg)
      if not res.finished:
        res.serverError()
      return false
    except Defect as defect:
      let msg = "class=sync_middleware_defect path=" & req.path & " error=" & defect.msg
      app.emitSafeErrorHook(msg)
      if app.panicHook != nil:
        try:
          app.panicHook(msg)
        except CatchableError as hookErr:
          app.reportHookFailure("panicHook", hookErr)
      app.runErrorAdvices(req, res, "middleware_defect", defect.msg)
      if not res.finished:
        res.serverError()
      return false
    if not syncNextFlag:
      return false
    inc idx
  true

type
  AsyncPipelineState = ref object
    shouldContinue: bool
    enteredHandlerPhase: bool

  AsyncNextState = ref object
    called: bool
    future: Future[void]

proc completedVoidFuture(): Future[void] {.inline.} =
  result = newFuture[void]("completedNext")
  result.complete()

proc executeRouteHandler(
  app: ExpressApp,
  req: Request,
  res: Response,
  matchedRoute: ptr Route,
  state: AsyncPipelineState
) {.async.} =
  if not state.shouldContinue or res.finished:
    return
  let remainingBeforeHandler = requestTimeoutRemainingMs(req)
  if remainingBeforeHandler == 0:
    markRequestTimedOut(app, req, res)
    state.shouldContinue = false
    return
  if matchedRoute != nil and app.hasBeforeHandlerAdvice and
     not app.runBeforeHandlerAdvices(req, res, matchedRoute.pattern):
    state.shouldContinue = false
    return

  state.enteredHandlerPhase = true
  try:
    if matchedRoute != nil:
      case matchedRoute.kind
      of rkSync:
        matchedRoute.syncHandler(req, res)
      of rkAsync:
        let remainingMs = requestTimeoutRemainingMs(req)
        let handlerFuture = matchedRoute.asyncHandler(req, res)
        if remainingMs >= 0:
          if remainingMs == 0 or not await handlerFuture.withTimeout(max(1, remainingMs)):
            cancelTimedOutFuture(handlerFuture)
            markRequestTimedOut(app, req, res)
        else:
          await handlerFuture
    else:
      app.sendRouteMiss(req, res)
  except Exception as e:
    app.emitSafeErrorHook(e.msg)
    app.runErrorAdvices(req, res, "handler", e.msg)
    if not res.finished:
      if app.errorHandler != nil:
        try:
          await app.errorHandler(e, req, res)
        except CatchableError as err:
          app.emitSafeErrorHook("async error handler failed: " & err.msg)
          res.serverError()
      else:
        res.serverError()

proc runMiddlewaresAndHandler(
  app: ExpressApp,
  req: Request,
  res: Response,
  middlewares: seq[AsyncMiddleware],
  matchedRoute: ptr Route,
  state: AsyncPipelineState
) {.async.} =
  proc runAt(idx: int): Future[void] {.async.} =
    if not state.shouldContinue or res.finished:
      return
    if idx >= middlewares.len:
      await app.executeRouteHandler(req, res, matchedRoute, state)
      return

    let remainingBefore = requestTimeoutRemainingMs(req)
    if remainingBefore == 0:
      markRequestTimedOut(app, req, res)
      state.shouldContinue = false
      return

    let nextState = AsyncNextState(called: false)
    let nextProc: NextProc = proc(): Future[void] =
      if nextState.called:
        if nextState.future != nil:
          return nextState.future
        return completedVoidFuture()
      nextState.called = true
      nextState.future = runAt(idx + 1)
      nextState.future

    try:
      let middlewareFuture = middlewares[idx](req, res, nextProc)
      let remaining = requestTimeoutRemainingMs(req)
      if remaining >= 0:
        if remaining == 0 or not await middlewareFuture.withTimeout(max(1, remaining)):
          cancelTimedOutFuture(middlewareFuture)
          markRequestTimedOut(app, req, res)
          state.shouldContinue = false
          return
      else:
        await middlewareFuture
      if nextState.called and nextState.future != nil and not nextState.future.finished:
        let remainingAfterMiddleware = requestTimeoutRemainingMs(req)
        if remainingAfterMiddleware >= 0:
          if remainingAfterMiddleware == 0 or
             not await nextState.future.withTimeout(max(1, remainingAfterMiddleware)):
            cancelTimedOutFuture(nextState.future)
            markRequestTimedOut(app, req, res)
            state.shouldContinue = false
            return
        else:
          await nextState.future
    except CatchableError as err:
      state.shouldContinue = false
      app.emitSafeErrorHook("class=middleware_error path=" & req.path & " error=" & err.msg)
      app.runErrorAdvices(req, res, "middleware", err.msg)
      if not res.finished:
        res.serverError()
      return
    except Defect as defect:
      state.shouldContinue = false
      let msg = "class=middleware_defect path=" & req.path & " error=" & defect.msg
      app.emitSafeErrorHook(msg)
      if app.panicHook != nil:
        try:
          app.panicHook(msg)
        except CatchableError as hookErr:
          app.reportHookFailure("panicHook", hookErr)
      app.runErrorAdvices(req, res, "middleware_defect", defect.msg)
      if not res.finished:
        res.serverError()
      return

    if not nextState.called:
      state.shouldContinue = false

  await runAt(0)

proc tryAcquireAsyncSlot(app: ExpressApp): bool {.inline.} =
  let maxInflight = app.maxInflightAsyncRequests
  if maxInflight <= 0:
    return true
  let now = app.inflightAsyncRequests.fetchAdd(1'i64, moAcquireRelease) + 1
  if now <= int64(maxInflight):
    return true
  discard app.inflightAsyncRequests.fetchSub(1'i64, moAcquireRelease)
  false

proc releaseAsyncSlot(app: ExpressApp) {.inline.} =
  if app.maxInflightAsyncRequests > 0:
    discard app.inflightAsyncRequests.fetchSub(1'i64, moAcquireRelease)

## Invoke the registered request-start hook, if any, with error trapping.
proc invokeRequestStartHook*(app: ExpressApp, req: Request) {.inline.} =
  if app == nil or not app.hasRequestStartHook:
    return
  try:
    app.requestStartHook(req)
  except CatchableError as err:
    app.reportHookFailure("requestStartHook", err)

## Invoke the registered route-matched hook, if any, with error trapping.
proc invokeRouteMatchedHook*(app: ExpressApp, pattern: string, req: Request) {.inline.} =
  if app == nil or not app.hasRouteMatchedHook:
    return
  try:
    app.routeMatchedHook(pattern, req)
  except CatchableError as err:
    app.reportHookFailure("routeMatchedHook", err)

## Invoke the registered request-end hook, if any, with the duration.
proc invokeRequestEndHook*(app: ExpressApp, req: Request, res: Response, durationMicros: int64) {.inline.} =
  if app == nil or not app.hasRequestEndHook:
    return
  try:
    app.requestEndHook(req, res, durationMicros)
  except CatchableError as err:
    app.reportHookFailure("requestEndHook", err)

## Run the protocol-error transform hook; returns adjusted status, body, and close flag.
proc invokeProtocolErrorTransform*(
  app: ExpressApp,
  statusCode: int,
  remoteIp: string
): tuple[statusCode: int, body: string, closeConnection: bool] =
  app.emitInspectorEvent(InspectorEvent(
    kind:
      if statusCode == 400:
        iekParseError
      else:
        iekProtocolError,
    phase: "http_parse",
    path: "",
    message: "protocol error",
    statusCode: statusCode,
    correlationId: "",
    remoteIp: remoteIp
  ))
  app.emitSafeErrorHook(
    "class=protocol_error operation=http_parse remote_ip=" &
    remoteIp & " status=" & $statusCode
  )
  if app != nil and app.protocolErrorHook != nil:
    try:
      return app.protocolErrorHook(statusCode, remoteIp)
    except CatchableError as err:
      app.reportHookFailure("protocolErrorHook", err)
  (statusCode: statusCode, body: "", closeConnection: true)

# Async request handler with middleware chain
proc handleRequestAsync(app: ExpressApp, req: Request, res: Response): Future[void] {.async.} =
  let wantsRequestTiming = app.hasRequestEndHook
  let startedMicros =
    if wantsRequestTiming:
      getCachedEpochMicros()
    else:
      0'i64

  if app.hasBeforeRouteMatchAdvice and not app.runBeforeRouteMatchAdvices(req, res):
    if not res.finished:
      app.emitSafeErrorHook("class=before_route_advice_reject path=" & req.path)
      res.serverError()
    if wantsRequestTiming:
      app.invokeRequestEndHook(req, res, max(0'i64, getCachedEpochMicros() - startedMicros))
    return

  # Find matching route - O(1) method lookup
  let matchedRoute = findRoute(app.router, req.methodKind, req.path, req.params)
  if matchedRoute != nil:
    app.invokeRouteMatchedHook(matchedRoute.pattern, req)

  let middlewareChain =
    if matchedRoute != nil: matchedRoute.compiledMiddlewares
    else: app.compiledBaseMiddlewares
  var shouldContinue = true
  var enteredHandlerPhase = false
  let canUseSyncPath = matchedRoute != nil and matchedRoute.allMiddlewaresSync and
    matchedRoute.compiledSyncMiddlewares.len > 0
  let pipelineState = AsyncPipelineState(
    shouldContinue: shouldContinue,
    enteredHandlerPhase: enteredHandlerPhase
  )
  try:
    if canUseSyncPath:
      shouldContinue = runSyncMiddlewares(app, req, res, matchedRoute.compiledSyncMiddlewares)
    elif middlewareChain.len > 0:
      await app.runMiddlewaresAndHandler(req, res, middlewareChain, matchedRoute, pipelineState)
      shouldContinue = pipelineState.shouldContinue
      enteredHandlerPhase = pipelineState.enteredHandlerPhase
  except Exception as e:
    shouldContinue = false
    app.emitSafeErrorHook(e.msg)
    app.runErrorAdvices(req, res, "middleware", e.msg)
    if not res.finished:
      res.serverError()
    if wantsRequestTiming:
      app.invokeRequestEndHook(req, res, max(0'i64, getCachedEpochMicros() - startedMicros))
    return

  if not shouldContinue and not res.finished:
    app.emitSafeErrorHook("class=middleware_stall path=" & req.path)
    res.status(500)
    res.jsonRaw("""{"error":"Internal Server Error"}""")

  if middlewareChain.len == 0 or canUseSyncPath:
    pipelineState.shouldContinue = shouldContinue
    pipelineState.enteredHandlerPhase = enteredHandlerPhase
    await app.executeRouteHandler(req, res, matchedRoute, pipelineState)
    shouldContinue = pipelineState.shouldContinue
    enteredHandlerPhase = pipelineState.enteredHandlerPhase
  if shouldContinue and matchedRoute != nil and not res.finished:
    app.emitSafeErrorHook("class=handler_stall path=" & req.path)
    app.emitInspectorEvent(InspectorEvent(
      kind: iekBackpressureStall,
      phase: "handler_stall",
      path: req.path,
      message: "handler did not finalize response",
      statusCode: 500,
      correlationId: req.correlationId,
      remoteIp: ""
    ))
    res.serverError()
  if enteredHandlerPhase and app.hasAfterHandlerAdvice:
    app.runAfterHandlerAdvices(req, res)
  if wantsRequestTiming:
    app.invokeRequestEndHook(req, res, max(0'i64, getCachedEpochMicros() - startedMicros))

proc handleRequestAsyncTracked(app: ExpressApp, req: Request, res: Response): Future[void] {.async.} =
  try:
    await app.handleRequestAsync(req, res)
  finally:
    unregisterActiveAsyncRequest(req)
    req.markRequestReleased()
    if res != nil:
      releaseHttpResponse(res.native)
    releaseResponse(res)
    releaseRequest(req)
    app.releaseAsyncSlot()

## Test helper that compiles router artifacts and runs one async request path.
proc handleRequestForTest*(app: ExpressApp, req: Request, res: Response): Future[void] {.async.} =
  ## Test helper: compile current router artifacts and execute one async request path.
  if app == nil or req == nil or res == nil:
    return
  req.trustProxyEnabled = app.trustProxy
  req.trustedProxyHopCount = int16(min(high(int16).int, app.getTrustedProxyHops()))
  req.trustedProxyAllowlist = app.getTrustedProxyAllowlist()
  compileRouterArtifacts(app.router)
  compileMiddlewarePipelines(app)
  await app.handleRequestAsync(req, res)

proc scheduleAsyncRequest(app: ExpressApp, req: Request, res: Response): bool =
  if not app.tryAcquireAsyncSlot():
    if not res.finished:
      res.status(503).set("connection", "close")
      res.send("server busy")
    if req != nil:
      discard req.notifyRequestTimeout()
    return false
  res.native.setAutoEndEnabled(false)
  retainHttpResponse(res.native)
  registerActiveAsyncRequest(req, res)
  asyncCheck app.handleRequestAsyncTracked(req, res)
  runAsyncPumpPollNow()
  true

proc scheduleExistingAsyncFuture(app: ExpressApp, req: Request, res: Response, fut: Future[void]): bool =
  if not app.tryAcquireAsyncSlot():
    if not res.finished:
      res.status(503).set("connection", "close")
      res.send("server busy")
    cancelTimedOutFuture(fut)
    if req != nil:
      discard req.notifyRequestTimeout()
    return false
  res.native.setAutoEndEnabled(false)
  retainHttpResponse(res.native)
  registerActiveAsyncRequest(req, res)
  let wantsRequestTiming = app.hasRequestEndHook
  let startedMicros =
    if wantsRequestTiming:
      getCachedEpochMicros()
    else:
      0'i64
  proc trackExistingFuture(app: ExpressApp, req: Request, res: Response, fut: Future[void]) {.async.} =
    try:
      await fut
    except CatchableError as e:
      app.emitSafeErrorHook(e.msg)
      app.runErrorAdvices(req, res, "handler", e.msg)
      if not res.finished:
        res.serverError()
    except Defect as defect:
      let msg = "class=tracked_future_defect error=" & defect.msg
      app.emitSafeErrorHook(msg)
      if app.panicHook != nil:
        try:
          app.panicHook(msg)
        except CatchableError as hookErr:
          app.reportHookFailure("panicHook", hookErr)
      app.runErrorAdvices(req, res, "handler_defect", defect.msg)
      if not res.finished:
        res.serverError()
    finally:
      if wantsRequestTiming:
        app.invokeRequestEndHook(req, res, max(0'i64, getCachedEpochMicros() - startedMicros))
      unregisterActiveAsyncRequest(req)
      req.markRequestReleased()
      if res != nil:
        releaseHttpResponse(res.native)
      releaseResponse(res)
      releaseRequest(req)
      app.releaseAsyncSlot()
  asyncCheck trackExistingFuture(app, req, res, fut)
  runAsyncPumpPollNow()
  true

## Test access: attach app async tracking to an already started handler future.
proc scheduleExistingAsyncFutureForTest*(
  app: ExpressApp,
  req: Request,
  res: Response,
  fut: Future[void]
): bool =
  scheduleExistingAsyncFuture(app, req, res, fut)

proc handleRequestSyncMatched(
  app: ExpressApp,
  req: Request,
  res: Response,
  matchedRoute: ptr Route
): bool =
  if matchedRoute != nil:
    if app.hasBeforeHandlerAdvice and not app.runBeforeHandlerAdvices(req, res, matchedRoute.pattern):
      if not res.finished:
        app.emitSafeErrorHook("class=before_handler_stall path=" & req.path)
        res.serverError()
      return false
    if matchedRoute.kind == rkSync:
      var enteredHandlerPhase = false
      try:
        enteredHandlerPhase = true
        matchedRoute.syncHandler(req, res)
      except Exception as e:
        app.emitSafeErrorHook(e.msg)
        app.runErrorAdvices(req, res, "handler", e.msg)
        if not res.finished:
          res.serverError()
      if enteredHandlerPhase and app.hasAfterHandlerAdvice:
        app.runAfterHandlerAdvices(req, res)
      return false
    else:
      return app.scheduleAsyncRequest(req, res)
  else:
    app.sendRouteMiss(req, res)
  false

# Set up server handlers
proc setupHandlers(app: ExpressApp) =
  prewarmContextPools(app.contextPoolPrewarm, app.contextPoolPrewarm)
  app.runStartupWarmups()
  if not app.initializePlugins():
    raise newException(ValueError, "plugin initialization failed: " & app.pluginInitFailedReason)
  app.router.lockRouterMutations("listen_started")
  app.listenStarted = true
  compileRouterArtifacts(app.router)
  compileMiddlewarePipelines(app)
  if app.routeManifestOnStartup:
    app.emitRouteManifestDiagnostics()
  # Choose fast path if no middlewares
  let hasMiddlewares = app.compiledBaseMiddlewares.len > 0 or routerHasCustomMiddlewares(app.router)
  let needsAsyncPump = hasMiddlewares or routerHasAsyncRoutes(app.router)
  app.asyncPumpInstalled = needsAsyncPump
  let viewsDir = app.getViewsDir()
  let viewExt = app.getViewExtension()
  let trustedProxyHops = int16(min(high(int16).int, app.getTrustedProxyHops()))
  let trustedProxyAllowlist = app.getTrustedProxyAllowlist()
  let generateCorrIds = app.generateCorrelationIds
  let trustProxyFlag = app.trustProxy
  let hasStartHook = app.hasRequestStartHook
  let hasEndHook = app.hasRequestEndHook
  let hasBeforeRouteAdvice = app.hasBeforeRouteMatchAdvice
  let hasBeforeHandlerAdv = app.hasBeforeHandlerAdvice
  let hasAfterHandlerAdv = app.hasAfterHandlerAdvice
  let hasRouteMatchHook = app.hasRouteMatchedHook
  let router = app.router
  var syncReqCache: Request = nil
  var syncResCache: Response = nil

  app.server.handle proc(nativeReq: HttpRequest, nativeRes: HttpResponse) =
    if hasMiddlewares:
      let req = acquireRequest(nativeReq)
      if generateCorrIds:
        req.correlationSeq = correlationFallbackCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
        req.correlationIdGenerated = false
        req.correlationIdCached.setLen(0)
      req.trustProxyEnabled = trustProxyFlag
      req.trustedProxyHopCount = trustedProxyHops
      req.trustedProxyAllowlist = trustedProxyAllowlist
      let res = acquireResponse(nativeRes, app, viewsDir, viewExt)
      bindRequestResponse(req, res)
      if hasStartHook:
        app.invokeRequestStartHook(req)
      if not app.scheduleAsyncRequest(req, res):
        discard req.notifyRequestTimeout()
        if hasEndHook:
          app.invokeRequestEndHook(req, res, 0)
        releaseResponse(res)
        releaseRequest(req)
    else:
      var req: Request
      if syncReqCache != nil:
        req = syncReqCache
        syncReqCache = nil
        req.rebindRequest(nativeReq)
      else:
        req = acquireRequest(nativeReq)
      if generateCorrIds:
        req.correlationSeq = correlationFallbackCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
        req.correlationIdGenerated = false
        req.correlationIdCached.setLen(0)
      req.trustProxyEnabled = trustProxyFlag
      req.trustedProxyHopCount = trustedProxyHops
      req.trustedProxyAllowlist = trustedProxyAllowlist
      var res: Response
      if syncResCache != nil:
        res = syncResCache
        syncResCache = nil
        res.rebindResponse(nativeRes, app, viewsDir, viewExt)
      else:
        res = acquireResponse(nativeRes, app, viewsDir, viewExt)
      bindRequestResponse(req, res)
      let startedMicros =
        if hasEndHook:
          getCachedEpochMicros()
        else:
          0'i64
      if hasStartHook:
        app.invokeRequestStartHook(req)
      var matchedRoute: ptr Route = nil
      let continueAfterAdvice =
        if hasBeforeRouteAdvice:
          app.runBeforeRouteMatchAdvices(req, res)
        else:
          true
      if continueAfterAdvice and not res.finished:
        matchedRoute = findRoute(router, nativeReq.methodKind, nativeReq.path, req.params)
      if matchedRoute != nil and hasRouteMatchHook:
        app.invokeRouteMatchedHook(matchedRoute.pattern, req)
      if not continueAfterAdvice and not res.finished:
        app.emitSafeErrorHook("class=before_route_match_stall path=" & req.path)
        res.serverError()
      var syncMiddlewareOk = true
      if continueAfterAdvice and not res.finished and app.allBaseSyncMiddlewares:
        if matchedRoute != nil and matchedRoute.allMiddlewaresSync and
           matchedRoute.compiledSyncMiddlewares.len > 0:
          syncMiddlewareOk = runSyncMiddlewares(app, req, res, matchedRoute.compiledSyncMiddlewares)
        elif matchedRoute == nil and app.compiledBaseSyncMiddlewares.len > 0:
          syncMiddlewareOk = runSyncMiddlewares(app, req, res, app.compiledBaseSyncMiddlewares)
        if not syncMiddlewareOk and not res.finished:
          app.emitSafeErrorHook("class=middleware_stall path=" & req.path)
          res.serverError()
      let handedOffAsync =
        if continueAfterAdvice and syncMiddlewareOk and not res.finished:
          if matchedRoute != nil and not hasBeforeHandlerAdv and not hasAfterHandlerAdv:
            if matchedRoute.kind == rkSync:
              try:
                matchedRoute.syncHandler(req, res)
              except CatchableError as err:
                if not res.finished:
                  app.emitSafeErrorHook("class=sync_inline_handler path=" & req.path & " " & err.msg)
                  res.serverError()
              except Defect as defect:
                let msg = "class=sync_inline_handler_defect path=" & req.path & " " & defect.msg
                app.emitSafeErrorHook(msg)
                if app.panicHook != nil:
                  try:
                    app.panicHook(msg)
                  except CatchableError as hookErr:
                    app.reportHookFailure("panicHook", hookErr)
                if not res.finished:
                  res.serverError()
              false
            else:
              var inlinedOk = false
              var pendingFut: Future[void] = nil
              try:
                let fut = matchedRoute.asyncHandler(req, res)
                if fut.finished:
                  inlinedOk = true
                  if fut.failed:
                    let e = fut.readError()
                    app.emitSafeErrorHook("class=async_inline_handler path=" & req.path & " " & e.msg)
                    app.runErrorAdvices(req, res, "handler", e.msg)
                    if not res.finished:
                      res.serverError()
                else:
                  pendingFut = fut
              except CatchableError as err:
                inlinedOk = true
                if not res.finished:
                  app.emitSafeErrorHook("class=async_inline_handler path=" & req.path & " " & err.msg)
                  res.serverError()
              except Defect as defect:
                inlinedOk = true
                let msg = "class=async_inline_handler_defect path=" & req.path & " " & defect.msg
                app.emitSafeErrorHook(msg)
                if app.panicHook != nil:
                  try:
                    app.panicHook(msg)
                  except CatchableError as hookErr:
                    app.reportHookFailure("panicHook", hookErr)
                if not res.finished:
                  res.serverError()
              if inlinedOk:
                false
              elif pendingFut != nil:
                app.scheduleExistingAsyncFuture(req, res, pendingFut)
              else:
                app.scheduleAsyncRequest(req, res)
          else:
            app.handleRequestSyncMatched(req, res, matchedRoute)
        else:
          false
      if not handedOffAsync and continueAfterAdvice and syncMiddlewareOk and
         matchedRoute != nil and not res.finished:
        app.emitSafeErrorHook("class=handler_stall path=" & req.path)
        res.serverError()
      if not handedOffAsync:
        if hasEndHook:
          app.invokeRequestEndHook(req, res, max(0'i64, getCachedEpochMicros() - startedMicros))
        let canCacheWrappers = req.cancelReason == rcrNone and not req.requestCancelled()
        req.markRequestReleased()
        if canCacheWrappers and syncResCache == nil:
          syncResCache = res
        else:
          releaseResponse(res)
        if canCacheWrappers and syncReqCache == nil:
          syncReqCache = req
        else:
          releaseRequest(req)

  app.server.onConnectionClose(proc(
    remoteIp: string,
    wasWebSocket: bool,
    requestSeq: uint64,
    socketKey: uint64
  ) =
    notifyAsyncDisconnect(remoteIp, requestSeq, socketKey)
    if app.hasConnectionCloseHook:
      try:
        app.connectionCloseHook(remoteIp, wasWebSocket)
      except CatchableError as err:
        app.reportHookFailure("connectionCloseHook", err)
  )

  app.server.onProtocolErrorTransform(proc(
    statusCode: int,
    remoteIp: string
  ): tuple[statusCode: int, body: string, closeConnection: bool] =
    app.invokeProtocolErrorTransform(statusCode, remoteIp)
  )

  app.server.onWebSocketUpgradeValidate(proc(nativeReq: HttpRequest): bool =
    if nativeReq == nil:
      return false
    if app.wsAllowedPaths.len > 0:
      var allowedPath = false
      for candidate in app.wsAllowedPaths:
        if candidate.len > 0 and nativeReq.path == candidate:
          allowedPath = true
          break
      if not allowedPath:
        return false
    if not app.wsOriginAllowedByPolicy(nativeReq):
      return false
    if app.wsUpgradeValidator != nil:
      return app.wsUpgradeValidator(nativeReq)
    true
  )

  if app.wsHandler != nil:
    app.server.onWebSocket(app.wsHandler)
  if app.wsRawHandler != nil:
    app.server.onWebSocketRaw(app.wsRawHandler)
  if app.wsOpenHandler != nil:
    app.server.onWebSocketOpen(app.wsOpenHandler)
  if app.wsCloseHandler != nil:
    app.server.onWebSocketClose(app.wsCloseHandler)
  if app.wsDrainHandler != nil:
    app.server.onWebSocketDrain(app.wsDrainHandler)
  if app.wsDroppedHandler != nil:
    app.server.onWebSocketDropped(app.wsDroppedHandler)
  if app.wsHighWaterHandler != nil:
    app.server.onWebSocketHighWater(app.wsHighWaterHandler)

  # uWebSockets drives its own loop; asyncdispatch futures need periodic polling.
  if needsAsyncPump:
    asyncPumpOwnerApp = app
    setOffloadDispatchServer(app.server)
    app.server.setLoopCallbacks(preCallback = runAsyncPumpTick)
    when not defined(macosx):
      app.server.setInternalInterval(runAsyncPumpTick, app.asyncPumpIntervalMs)
  else:
    setOffloadDispatchServer(nil)

## Test helper that installs the production server handler without the event loop.
proc setupHandlersForTest*(app: ExpressApp) =
  ## Compile router artifacts and install the native server handler without
  ## entering the uSockets event loop. Intended for tests that need the real
  ## production dispatch path instead of handleRequestForTest's async path.
  if app == nil or app.listenStarted:
    return
  app.setupHandlers()

# Start server
proc normalizedListenHost(host: string): string {.inline.} =
  let trimmed = host.strip()
  if trimmed.len == 0:
    return "0.0.0.0"
  trimmed

## Resolve the listen host for scaling entry points from the NIM_EXPRESS_HOST
## or HOST environment variable, matching the env source of AppEnvConfig.host.
## Returns 0.0.0.0 when neither is set.
proc scalingEntryListenHost(): string {.used.} =
  let raw = getEnv("NIM_EXPRESS_HOST", "").strip()
  if raw.len > 0:
    return raw
  normalizedListenHost(getEnv("HOST", ""))

proc runServerLoop(app: ExpressApp) =
  if app == nil:
    return
  assertMacosGcdMainThread("runServerLoop")
  when defined(macosx) and compileOption("threads"):
    let previousStopCallback = app.server.stopCallback
    app.server.onStop(proc() =
      stopMacosAsyncPumpWakeThread(app)
      if previousStopCallback != nil:
        previousStopCallback()
    )
  try:
    app.server.run()
  finally:
    setOffloadDispatchServer(nil)
    when defined(macosx) and compileOption("threads"):
      stopMacosAsyncPumpWakeThread(app)
    app.shutdownPlugins()

## The uSockets event loop pointer for the app, or ``nil`` before ``listen``.
proc getEventLoop*(app: ExpressApp): UsLoopPtr {.inline.} =
  if app != nil and app.server != nil:
    return app.server.loop
  nil

## Request server shutdown and close all app-owned HTTP clients.
proc close*(app: ExpressApp) =
  ## Request shutdown of the app server and close app-owned HTTP clients.
  if app == nil:
    return
  if app.httpClientRegistryPtr != nil:
    let registry = cast[ptr HttpClientRegistry](app.httpClientRegistryPtr)
    if registry != nil:
      closeAll(registry[])
      dealloc(registry)
    app.httpClientRegistryPtr = nil
  if app.server != nil:
    app.server.close()

proc ensureRegistry(app: ExpressApp): ptr HttpClientRegistry =
  if app.httpClientRegistryPtr == nil:
    let regPtr = cast[ptr HttpClientRegistry](alloc0(sizeof(HttpClientRegistry)))
    regPtr[] = initRegistry()
    app.httpClientRegistryPtr = regPtr
  cast[ptr HttpClientRegistry](app.httpClientRegistryPtr)

## Create or fetch a named HTTP client registered on the app.
proc createHttpClient*(app: ExpressApp, name: string = "default",
                        maxConnsPerHost: int = 16,
                        requestTimeoutMs: int = 30000,
                        connectTimeoutMs: int = 5000,
                        keepAliveTimeoutMs: int = 60000,
                        maxRetries: int = 0,
                        preferH2: bool = false): ptr http_clients.HttpClient =
  if app == nil:
    return nil
  let reg = app.ensureRegistry()
  let existing = getClient(reg[], name)
  if existing != nil:
    return existing
  var config = defaultHttpClientConfig()
  config.maxConnsPerHost = maxConnsPerHost
  config.requestTimeoutMs = requestTimeoutMs
  config.connectTimeoutMs = connectTimeoutMs
  config.keepAliveTimeoutMs = keepAliveTimeoutMs
  config.maxRetries = maxRetries
  config.preferH2 = preferH2
  let clientPtr = cast[ptr http_clients.HttpClient](alloc0(sizeof(http_clients.HttpClient)))
  clientPtr[] = newHttpClientFromConfig(config)
  reg[].clients[name] = clientPtr
  reg[].configs[name] = config
  app.onStartup(proc(ctx: ExpressApp) =
    let loop = ctx.getEventLoop()
    if loop != nil and not clientPtr[].initialized:
      initClientWithLoop(clientPtr[], loop)
  )
  clientPtr

## Look up a named HTTP client, or ``nil`` if not created.
proc httpClient*(app: ExpressApp, name: string = "default"): ptr http_clients.HttpClient =
  if app == nil or app.httpClientRegistryPtr == nil:
    return nil
  let registry = cast[ptr HttpClientRegistry](app.httpClientRegistryPtr)
  getClient(registry[], name)

## Look up a named HTTP client, or ``nil`` if not created.
proc getHttpClient*(app: ExpressApp, name: string): ptr http_clients.HttpClient =
  app.httpClient(name)

## Load named HTTP clients from a JSON config file and init them at startup.
proc initHttpClients*(app: ExpressApp, configPath: string = "config.json") =
  if app == nil:
    return
  var registry = loadHttpClients(configPath)
  let reg = app.ensureRegistry()
  for name in registry.clients.keys:
    reg[].clients[name] = registry.clients[name]
  for name in registry.configs.keys:
    reg[].configs[name] = registry.configs[name]
  app.onStartup(proc(ctx: ExpressApp) =
    let loop = ctx.getEventLoop()
    if loop != nil:
      let r = cast[ptr HttpClientRegistry](ctx.httpClientRegistryPtr)
      if r != nil:
        initRegistryClients(r[], loop)
  )

## Start listening for HTTP connections on the given ``port``.
## Calls ``callback`` once the server is ready to accept connections.
proc listen*(app: ExpressApp, host: string, port: int, callback: proc(success: bool)) =
  when defined(posix):
    installSignalHandlers()
  app.setupHandlers()
  app.server.listen(normalizedListenHost(host), port) do (success: bool):
    when defined(macosx) and compileOption("threads"):
      if success:
        startMacosAsyncPumpWakeThread(app)
    callback(success)
  app.runServerLoop()

## Listen on ``0.0.0.0:port``; calls ``callback`` once the server is ready.
proc listen*(app: ExpressApp, port: int, callback: proc(success: bool)) =
  app.listen("0.0.0.0", port, callback)

## Apply ``cfg`` then listen on its host and port.
proc listen*(app: ExpressApp, cfg: AppEnvConfig, callback: proc(success: bool)) =
  app.applyAppEnvConfig(cfg)
  app.listen(cfg.host, cfg.port, callback)

## Start the application on ``port`` and block until shutdown.
## Convenience wrapper around ``listen`` + event loop.
proc run*(app: ExpressApp, host: string, port: int) =
  let normalizedHost = normalizedListenHost(host)
  app.listen(normalizedHost, port) do (success: bool):
    if success:
      echo "Server running at http://", normalizedHost, ":", port
    else:
      echo "Failed to start server on port ", port
      quit(1)

## Run on ``0.0.0.0:port`` and block until shutdown.
proc run*(app: ExpressApp, port: int) =
  app.run("0.0.0.0", port)

## Apply ``cfg`` then run on its host and port.
proc run*(app: ExpressApp, cfg: AppEnvConfig) =
  app.applyAppEnvConfig(cfg)
  app.run(cfg.host, cfg.port)

# ============================================
# MULTI-THREADED SUPPORT
# ============================================

type
  # Factory function that creates an app in each worker thread
  ## Factory that builds a fresh ``ExpressApp`` per worker thread or process.
  AppFactory* = proc(): ExpressApp {.gcsafe.}

  WorkerArgs = object
    port: int
    workerId: int
    host: string
    factory: AppFactory

# Thread worker proc - each thread runs its own event loop
proc workerThread(args: WorkerArgs) {.thread.} =
  {.cast(gcsafe).}:
    # Create app using the factory (creates fresh handlers in this thread)
    let app = args.factory()
    app.server.options.listenExclusivePort = false

    # Set up the HTTP handler
    app.setupHandlers()

    # Listen on the same port (SO_REUSEPORT allows this)
    app.server.listen(args.host, args.port) do (success: bool):
      if success:
        echo "Worker ", args.workerId, " started on ", args.host, ":", args.port
      else:
        echo "Worker ", args.workerId, " failed to start"
        quit(1)

    # Run the event loop (blocking)
    app.runServerLoop()

## Start multiple threads sharing the same port.
## Each thread gets its own event loop. Linux epoll recommended.
## Threads listen on the host from NIM_EXPRESS_HOST or HOST, defaulting to
## 0.0.0.0. SIGINT and SIGTERM terminate the process with the default action
## unless the factory registers the graceful_shutdown middleware, which drains
## in-flight requests in every worker thread first.
proc runThreaded*(factory: AppFactory, port: int, numThreads: int = 0) =
  var threadCount = if numThreads > 0: numThreads else: defaultThreadCount()
  let host = scalingEntryListenHost()
  when defined(posix):
    installSignalHandlers()

  when defined(macosx) and defined(LIBUS_USE_GCD):
    if threadCount > 1:
      echo "Warning: Multi-threading not supported with GCD backend. Using 1 thread."
      threadCount = 1

    if threadCount == 1:
      let app = factory()
      app.setupHandlers()
      app.server.listen(host, port) do (success: bool):
        if success:
          when defined(macosx) and compileOption("threads"):
            startMacosAsyncPumpWakeThread(app)
          echo "Server running at http://", host, ":", port
        else:
          echo "Failed to start server on port ", port
          quit(1)
      app.runServerLoop()
      return

  echo "Starting ", threadCount, " worker threads on ", host, ":", port

  # Create worker threads
  var threads = newSeq[Thread[WorkerArgs]](threadCount)

  for i in 0..<threadCount:
    let args = WorkerArgs(
      port: port,
      workerId: i,
      host: host,
      factory: factory
    )
    createThread(threads[i], workerThread, args)

  echo "All workers started. Press Ctrl+C to stop."

  # Wait for all threads (they run forever until interrupted)
  for i in 0..<threadCount:
    joinThread(threads[i])

# ============================================
# MULTI-PROCESS (CLUSTER) SUPPORT
# ============================================

when not defined(windows):
  const
    ClusterParentPollMs = 50
    ## Grace period in milliseconds workers get to exit before SIGKILL.
    DefaultClusterWorkerShutdownGraceMs* = 30_000
    ## Max worker pids tracked for the repeat-signal force-kill path.
    MaxTrackedClusterWorkers = 256

  var clusterParentShutdownFlag: Atomic[bool]
  var clusterParentForceExitFlag: Atomic[bool]
  ## Worker pids for the repeat-signal force-kill path. Plain Pid array with
  ## only single-word stores so the signal handler path needs no locks, GC, or
  ## heap access. A zero entry is a free slot.
  var clusterWorkerPidTable: array[MaxTrackedClusterWorkers, Pid]

  type
    ## Worker respawn supervision policy for cluster mode.
    ClusterSupervisionPolicy* = object
      ## Base respawn backoff delay in milliseconds.
      baseBackoffMs*: int
      ## Maximum respawn backoff delay in milliseconds.
      maxBackoffMs*: int
      ## Random jitter cap added to the respawn backoff, in milliseconds.
      jitterMs*: int
      ## Max restarts allowed per worker within ``restartStormWindowMs``.
      restartStormCap*: int
      ## Rolling window in milliseconds for the restart storm cap.
      restartStormWindowMs*: int
      ## Total respawns allowed within ``hardRespawnWindowMs`` before fatal state.
      hardRespawnCap*: int
      ## Rolling window in milliseconds for the hard respawn cap.
      hardRespawnWindowMs*: int

  ## Clear the cluster parent shutdown and force-exit signal flags.
  proc resetClusterParentSignalFlags*() =
    clusterParentShutdownFlag.store(false, moRelease)
    clusterParentForceExitFlag.store(false, moRelease)

  ## True after the cluster parent received SIGINT or SIGTERM.
  proc clusterParentShutdownRequested*(): bool {.inline.} =
    clusterParentShutdownFlag.load(moAcquire)

  ## Test access: mark the cluster parent as shutdown requested.
  proc markClusterParentShutdownForTest*() =
    clusterParentShutdownFlag.store(true, moRelease)
    clusterParentForceExitFlag.store(true, moRelease)

  ## Track a spawned worker pid so the repeat-signal path can force-kill it.
  ## No-op for non-positive pids or when the tracking table is full.
  proc registerClusterWorkerPid*(pid: Pid) =
    if pid <= 0:
      return
    for i in 0 ..< MaxTrackedClusterWorkers:
      if clusterWorkerPidTable[i] == 0:
        clusterWorkerPidTable[i] = pid
        return

  ## Stop tracking a reaped worker pid. No-op when the pid is not tracked.
  proc unregisterClusterWorkerPid*(pid: Pid) =
    if pid <= 0:
      return
    for i in 0 ..< MaxTrackedClusterWorkers:
      if clusterWorkerPidTable[i] == pid:
        clusterWorkerPidTable[i] = 0
        return

  ## Force-kill all tracked worker pids with SIGKILL. Called from the
  ## repeat-signal handler, so it uses only async-signal-safe calls; the parent
  ## exits right after and init reaps the killed children.
  proc forceKillTrackedClusterWorkers*() {.used.} =
    for pid in clusterWorkerPidTable:
      if pid > 0:
        discard kill(pid, SIGKILL)

  proc handleClusterParentSignal(sig: cint) {.noconv.} =
    if clusterParentForceExitFlag.load(moAcquire):
      # Second signal: the graceful pass is over. Force-kill the tracked
      # workers so the parent exit cannot orphan them on the shared port.
      forceKillTrackedClusterWorkers()
      if sig == SIGTERM:
        exitnow(143)
      else:
        exitnow(130)
    clusterParentShutdownFlag.store(true, moRelease)
    clusterParentForceExitFlag.store(true, moRelease)

  proc installClusterParentSignalHandlers() {.used.} =
    resetClusterParentSignalFlags()
    discard signal(SIGINT, handleClusterParentSignal)
    discard signal(SIGTERM, handleClusterParentSignal)

  # Workers must not inherit the parent's cluster signal handler: after fork
  # the parent flag state is per-process and nothing inside a worker observes
  # it, so a forwarded SIGTERM would be ignored until the 30s SIGKILL
  # escalation. Default action keeps workers exitable; apps that want in-flight
  # request draining register the graceful_shutdown middleware in the factory,
  # which installs its own handlers after this reset.
  proc resetWorkerSignalHandlersBeforeListen() {.used.} =
    discard signal(SIGINT, SIG_DFL)
    discard signal(SIGTERM, SIG_DFL)

  proc nowMillis(): int64 {.inline, used.} =
    int64(epochTime() * 1000.0)

  proc sleepInterruptibly(ms: int): bool {.used.} =
    var remaining = max(0, ms)
    while remaining > 0:
      if clusterParentShutdownRequested():
        return false
      let step = min(remaining, ClusterParentPollMs)
      sleep(step)
      remaining -= step
    not clusterParentShutdownRequested()

  proc signalClusterWorkers(slotForPid: Table[Pid, int], sig: cint) {.used.} =
    for pid in slotForPid.keys:
      if pid > Pid(0):
        discard kill(pid, sig)

  proc reapClusterWorkers(slotForPid: var Table[Pid, int], graceMs: int) {.used.} =
    let deadline = nowMillis() + int64(max(0, graceMs))
    var status: cint
    while slotForPid.len > 0 and nowMillis() < deadline:
      let exitedPid = waitpid(Pid(-1), status, WNOHANG)
      if exitedPid > 0 and slotForPid.hasKey(exitedPid):
        slotForPid.del(exitedPid)
        unregisterClusterWorkerPid(exitedPid)
      else:
        sleep(ClusterParentPollMs)
    if slotForPid.len > 0:
      signalClusterWorkers(slotForPid, SIGKILL)
      while slotForPid.len > 0:
        let exitedPid = waitpid(Pid(-1), status, WNOHANG)
        if exitedPid > 0 and slotForPid.hasKey(exitedPid):
          slotForPid.del(exitedPid)
          unregisterClusterWorkerPid(exitedPid)
        else:
          sleep(ClusterParentPollMs)

  ## Default cluster supervision policy with exponential backoff and storm caps.
  proc defaultClusterSupervisionPolicy*(): ClusterSupervisionPolicy =
    ClusterSupervisionPolicy(
      baseBackoffMs: 100,
      maxBackoffMs: 2000,
      jitterMs: 100,
      restartStormCap: 8,
      restartStormWindowMs: DefaultRestartStormWindowMs,
      hardRespawnCap: 64,
      hardRespawnWindowMs: 5 * 60_000
    )

  proc splitMix64(value: uint64): uint64 {.inline.} =
    var mixed = value + 0x9E3779B97F4A7C15'u64
    mixed = (mixed xor (mixed shr 30)) * 0xBF58476D1CE4E5B9'u64
    mixed = (mixed xor (mixed shr 27)) * 0x94D049BB133111EB'u64
    mixed xor (mixed shr 31)

  ## Random jitter of 0 to ``jitterCap`` milliseconds, for spreading worker respawns.
  proc respawnJitterMs*(jitterCap: int): int =
    let cap = max(0, jitterCap)
    if cap <= 0:
      return 0
    var bytes: array[8, byte]
    if urandom(bytes):
      var sample = 0'u64
      for i, b in bytes:
        sample = sample or (uint64(b) shl (i * 8))
      return int(sample mod uint64(cap + 1))
    let tick = clusterJitterFallbackCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
    int(splitMix64(tick) mod uint64(cap + 1))

  ## Drop restart timestamps older than ``windowMs`` before ``nowMs``.
  proc pruneRestartStormTimestamps*(
    restartTimestampsMs: var seq[int64],
    nowMs: int64,
    windowMs: int
  ) =
    if restartTimestampsMs.len == 0:
      return
    let effectiveWindowMs = max(1, windowMs)
    let cutoffMs = nowMs - int64(effectiveWindowMs)
    var firstLive = 0
    while firstLive < restartTimestampsMs.len and restartTimestampsMs[firstLive] <= cutoffMs:
      inc firstLive
    if firstLive == 0:
      return
    var writeIdx = 0
    for readIdx in firstLive ..< restartTimestampsMs.len:
      restartTimestampsMs[writeIdx] = restartTimestampsMs[readIdx]
      inc writeIdx
    restartTimestampsMs.setLen(writeIdx)

  ## Count restarts within the policy's rolling storm window.
  proc rollingRestartCount*(
    policy: ClusterSupervisionPolicy,
    restartTimestampsMs: var seq[int64],
    nowMs: int64
  ): int =
    pruneRestartStormTimestamps(restartTimestampsMs, nowMs, policy.restartStormWindowMs)
    restartTimestampsMs.len

  ## Record a restart and report whether the slot is under the storm cap.
  proc canRespawnWorker*(
    policy: ClusterSupervisionPolicy,
    restartTimestampsMs: var seq[int64],
    nowMs: int64
  ): bool =
    discard rollingRestartCount(policy, restartTimestampsMs, nowMs)
    restartTimestampsMs.add(nowMs)
    restartTimestampsMs.len <= max(1, policy.restartStormCap)

  ## Record a respawn and report whether the hard respawn budget allows it.
  proc withinHardRespawnBudget*(
    policy: ClusterSupervisionPolicy,
    respawnTimestampsMs: var seq[int64],
    nowMs: int64
  ): bool =
    pruneRestartStormTimestamps(respawnTimestampsMs, nowMs, max(1, policy.hardRespawnWindowMs))
    respawnTimestampsMs.add(nowMs)
    respawnTimestampsMs.len <= max(1, policy.hardRespawnCap)

  ## Exponential respawn delay in milliseconds, capped and jittered.
  proc boundedRespawnDelayMs*(policy: ClusterSupervisionPolicy, restartCount: int): int =
    let base = max(0, policy.baseBackoffMs)
    let maxDelay = max(base, policy.maxBackoffMs)
    var delay = base
    if restartCount > 1:
      let shifts = min(10, restartCount - 1)
      delay = base shl shifts
    delay = min(maxDelay, delay)
    let jitterCap = max(0, policy.jitterMs)
    if jitterCap > 0:
      let jitter = respawnJitterMs(jitterCap)
      delay += jitter
    delay

  ## True while the worker's restart count is within the storm cap.
  proc canRespawnWorker*(policy: ClusterSupervisionPolicy, restartCount: int): bool =
    restartCount <= max(1, policy.restartStormCap)

  proc decodeWorkerExitStatus(status: cint): tuple[exited: bool, exitCode: int, signalCode: int] {.inline.} =
    let signalCode = int(status and 0x7f)
    let exited = signalCode == 0
    let exitCode =
      if exited:
        int((status shr 8) and 0xff)
      else:
        -1
    (exited: exited, exitCode: exitCode, signalCode: signalCode)

  ## Format a worker exit as a JSON ``cluster_worker_exit`` event string.
  proc formatWorkerFailureEvent*(
    workerSlot: int,
    pid: Pid,
    status: cint,
    restartCount: int
  ): string =
    let decoded = decodeWorkerExitStatus(status)
    result = "{"
    result.add("\"event\":\"cluster_worker_exit\"")
    result.add(",\"worker_slot\":")
    result.add($workerSlot)
    result.add(",\"pid\":")
    result.add($pid)
    result.add(",\"restart_count\":")
    result.add($restartCount)
    result.add(",\"exited\":")
    result.add(if decoded.exited: "true" else: "false")
    result.add(",\"exit_code\":")
    result.add($decoded.exitCode)
    result.add(",\"signal\":")
    result.add($decoded.signalCode)
    result.add("}")

  ## Start multiple worker processes sharing the same port via SO_REUSEPORT.
  ## Each worker runs an independent event loop. Linux recommended.
  ## Workers listen on the host from NIM_EXPRESS_HOST or HOST, defaulting to
  ## 0.0.0.0. Workers reset SIGINT and SIGTERM to the default action before the
  ## factory runs, so in-flight requests only drain when the factory registers
  ## the graceful_shutdown middleware. A second SIGINT or SIGTERM to the parent
  ## force-kills the workers before the parent exits.
  proc runCluster*(factory: AppFactory, port: int, numWorkers: int = 0) =
    var workerCount = if numWorkers > 0: numWorkers else: defaultWorkerCount()

    when defined(macosx):
      # macOS limitations:
      # 1. SO_REUSEPORT doesn't load-balance (all connections go to one process)
      # 2. GCD event loop doesn't survive fork()
      # Solution: Run single process on macOS
      if workerCount > 1:
        echo "Note: Multi-process cluster mode limited on macOS."
        echo "      SO_REUSEPORT doesn't load-balance on macOS."
        echo "      Running single process. Use nginx/haproxy for scaling."
        workerCount = 1

      # Single process mode on macOS
      let host = scalingEntryListenHost()
      let app = factory()
      app.setupHandlers()
      when defined(posix):
        installSignalHandlers()
      app.server.listen(host, port) do (success: bool):
        if success:
          when defined(macosx) and compileOption("threads"):
            startMacosAsyncPumpWakeThread(app)
          echo "Server running at http://", host, ":", port
        else:
          echo "Failed to start server on port ", port
          quit(1)
      app.runServerLoop()
    else:
      # Linux: SO_REUSEPORT works correctly, kernel load-balances
      let host = scalingEntryListenHost()
      echo "Starting ", workerCount, " worker processes on ", host, ":", port
      let supervisionPolicy = defaultClusterSupervisionPolicy()

      proc spawnWorker(slot: int): Pid =
        let pid = fork()
        if pid == 0:
          resetWorkerSignalHandlersBeforeListen()
          when defined(linux):
            let cpuListEnv = getEnv("NIM_EXPRESS_CPU_LIST", "").strip()
            if cpuListEnv.len > 0:
              if not applyLinuxWorkerAffinity(slot):
                echo "Worker ", slot, " affinity request ignored (invalid or unsupported NIM_EXPRESS_CPU_LIST)."
              else:
                echo "Worker ", slot, " affinity pinned from NIM_EXPRESS_CPU_LIST."
            let numaNodeEnv = getEnv("NIM_EXPRESS_NUMA_NODE", "").strip()
            if numaNodeEnv.len > 0:
              echo "Worker ", slot, " NUMA hint set to node ", numaNodeEnv, " (external numactl launcher recommended)."
          let app = factory()
          app.server.options.listenExclusivePort = false
          app.setupHandlers()
          app.server.listen(host, port) do (success: bool):
            if success:
              echo "Worker ", slot, " (pid ", getpid(), ") started on ", host, ":", port
            else:
              echo "Worker ", slot, " failed to start"
              quit(1)
          app.runServerLoop()
          # A returned run loop is unexpected outside explicit shutdown.
          quit(70)
        # Parent-only: track the new worker pid for the repeat-signal path.
        registerClusterWorkerPid(pid)
        pid

      var slotForPid = initTable[Pid, int]()
      var restarts = newSeq[int](workerCount)
      var restartTimestampsBySlot = newSeq[seq[int64]](workerCount)
      var hardRespawnTimestamps: seq[int64] = @[]
      var supervisionFatal = false
      var parentShuttingDown = false
      var shutdownStartedAtMs = 0'i64
      var shutdownEscalated = false
      installClusterParentSignalHandlers()
      for i in 0..<workerCount:
        let pid = spawnWorker(i)
        if pid > 0:
          slotForPid[pid] = i
        else:
          echo "Fork failed for worker ", i
          signalClusterWorkers(slotForPid, SIGTERM)
          quit(1)

      echo "All ", workerCount, " workers started. Press Ctrl+C to stop."

      # Parent-side supervision loop with bounded respawn policy.
      var status: cint
      while slotForPid.len > 0:
        if clusterParentShutdownRequested():
          if not parentShuttingDown:
            parentShuttingDown = true
            shutdownStartedAtMs = nowMillis()
            echo "Cluster parent received shutdown signal; stopping respawn and forwarding SIGTERM to workers."
            signalClusterWorkers(slotForPid, SIGTERM)
          elif not shutdownEscalated and nowMillis() - shutdownStartedAtMs >= int64(DefaultClusterWorkerShutdownGraceMs):
            shutdownEscalated = true
            echo "Cluster workers did not exit within ", DefaultClusterWorkerShutdownGraceMs, "ms; forwarding SIGKILL."
            signalClusterWorkers(slotForPid, SIGKILL)

        let exitedPid = waitpid(Pid(-1), status, WNOHANG)
        if exitedPid == 0:
          sleep(ClusterParentPollMs)
          continue
        if exitedPid <= 0:
          sleep(ClusterParentPollMs)
          continue
        if not slotForPid.hasKey(exitedPid):
          continue
        let slot = slotForPid[exitedPid]
        slotForPid.del(exitedPid)
        unregisterClusterWorkerPid(exitedPid)
        if parentShuttingDown:
          echo "Worker ", slot, " (pid ", exitedPid, ") stopped during cluster shutdown."
          continue
        inc restarts[slot]
        echo formatWorkerFailureEvent(slot, exitedPid, status, restarts[slot])

        let decoded = decodeWorkerExitStatus(status)
        if decoded.exited and decoded.exitCode == 0:
          echo "Worker ", slot, " exited cleanly unexpectedly; respawning."
        let nowMs = nowMillis()
        if not withinHardRespawnBudget(supervisionPolicy, hardRespawnTimestamps, nowMs):
          echo "Hard respawn cap reached; entering fatal supervision state and stopping automatic worker respawn."
          supervisionFatal = true
          break
        if not canRespawnWorker(supervisionPolicy, restartTimestampsBySlot[slot], nowMs):
          let cooldownMs = max(1_000, supervisionPolicy.restartStormWindowMs)
          echo "Respawn storm cap reached for worker slot ", slot, "; cooling down for ", cooldownMs, "ms."
          if not sleepInterruptibly(cooldownMs):
            continue
          restartTimestampsBySlot[slot].setLen(0)

        let backoffMs = boundedRespawnDelayMs(supervisionPolicy, restarts[slot])
        if backoffMs > 0 and not sleepInterruptibly(backoffMs):
          continue
        if clusterParentShutdownRequested():
          continue
        let replacementPid = spawnWorker(slot)
        if replacementPid > 0:
          slotForPid[replacementPid] = slot
        else:
          echo "Fork failed while respawning worker ", slot
      if supervisionFatal:
        echo "Fatal cluster supervision state; terminating remaining workers before parent exit."
        signalClusterWorkers(slotForPid, SIGTERM)
        reapClusterWorkers(slotForPid, DefaultClusterWorkerShutdownGraceMs)
        quit(1)

  ## Auto-select the best scaling strategy for the current platform.
  ## Linux: runCluster or runThreaded. macOS/Windows: single process.
  ## The listen host comes from NIM_EXPRESS_HOST or HOST, defaulting to 0.0.0.0.
  proc runAuto*(factory: AppFactory, port: int, numWorkers: int = 0) =
    when defined(windows):
      echo "Windows: Running single process"
      let app = factory()
      app.run(scalingEntryListenHost(), port)
    elif defined(macosx):
      echo "macOS: Running single process (use nginx for scaling)"
      let host = scalingEntryListenHost()
      let app = factory()
      app.setupHandlers()
      when defined(posix):
        installSignalHandlers()
      app.server.listen(host, port) do (success: bool):
        if success:
          when defined(macosx) and compileOption("threads"):
            startMacosAsyncPumpWakeThread(app)
          echo "Server running at http://", host, ":", port
        else:
          echo "Failed to start server on port ", port
          quit(1)
      app.runServerLoop()
    else:
      echo "Linux: Using multi-process cluster mode"
      runCluster(factory, port, numWorkers)
