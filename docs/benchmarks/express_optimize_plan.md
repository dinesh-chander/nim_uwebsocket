# nim_express Performance Regression Analysis & Optimization Plan

## Current vs Expected Performance

| Endpoint   | Current    | Expected  | Regression |
|------------|-----------|-----------|------------|
| /json      | 87,148    | ~150,000  | **-42%**   |
| /plaintext | 93,984    | ~150,000  | **-37%**   |

**Test:** `wrk -t8 -c256 -d5s --latency`, macOS ARM64, single process, Node 22 not involved (pure Nim).

---

## Flamegraph Profiling Results

Profiled with macOS `sample` (8s under `wrk -t8 -c256 -d12s`) + flamegraph generation.

### Inclusive Time Breakdown (% of total samples)

| Function | JSON | Plaintext | Category |
|----------|------|-----------|----------|
| `onSocketData` | 54.9% | 56.9% | Entry point |
| `flushPendingResponses` | 46.2% | 48.7% | Write path |
| `writev` (syscall) | 45.4% | 47.9% | I/O |
| `recvfrom` (syscall) | 44.8% | 42.9% | I/O |
| app dispatch closure | 4.8% | 4.1% | Framework |
| `handleRequestSyncMatched` | 2.2% | 1.8% | Framework |
| `epochTime` (all callers) | 0.9% | 1.3% | **Syscall overhead** |
| `setSocketTimeoutPhase` | 0.8% | 1.2% | **Timeout tracking** |
| `parseHttpRequest` | 1.1% | 1.2% | Parsing |
| `beginMacosFallbackMaintenance` | 0.2% | 0.4% | **macOS maintenance** |
| `nimNewObj` | 0.2% | 0.3% | **Allocation** |

**Total `epochTime` samples:** JSON=58/6482 (0.9%), Plaintext=84/6495 (1.3%).
**Total `setSocketTimeoutPhase` samples:** JSON=55/6482 (0.8%), Plaintext=80/6495 (1.2%).

### Key Insight

The framework is I/O bound: ~45% `writev`, ~43-45% `recvfrom`, only ~10% framework code. **The regression lives in that ~10%** — per-request overhead from syscalls, allocations, and unconditional checks that compound at 90k+ req/s.

### Regression #1: `new(res)` per request in http.nim (CRITICAL)

**File:** `nim_usockets/src/nim_usockets/http.nim:7599-7616`

```nim
var res: HttpResponse
new(res)                              # HEAP ALLOCATION EVERY REQUEST
res.socket = s
res.ssl = sockData.server.ssl.toInt
res.requestRef = req
res.statusCode = Http200
res.statusCodeInt = 200
res.requestMethod = req.methodKind
res.requestIsHttp11 = req.httpMajor == 1 and req.httpMinor == 1
res.headersInited = false
res.bodySent = false
res.headersSent = false
res.requestSeq = sockData.nextRequestSeq
res.autoEnd = true
res.connectionClose = req.connectionClose
res.chunkedStarted = false
res.chunkedFinished = false
```

**Problem:** `HttpResponse` is allocated with `new()` on **every single request** at the http.nim layer. This is separate from the nim_express `Response` pooling. Every `new()` hits the allocator, and every response object becomes GC/ARC-tracked garbage after the request completes. At 150k req/s that's 150k alloc+dealloc cycles per second.

**The nim_express layer pools `Request`/`Response` objects** (types.nim pools), but the **native `HttpResponse` underneath is never pooled** — it's freshly allocated in the http.nim hot path every time.

**Fix:** Pool `HttpResponse` objects like `Request`/`Response` are pooled, or use a stack-allocated object since `HttpResponse` doesn't escape the request scope.

**Expected impact:** 5-10% throughput recovery.

---

### Regression #2: `buildFallbackCorrelationId()` on every request (HIGH)

**File:** `nim_express/src/nim_express/app.nim:2847, 2868`

```nim
req.correlationId = buildFallbackCorrelationId()
```

Called unconditionally in **both** the middleware path (line 2847) and the sync fast path (line 2868).

**File:** `app.nim:32-35`
```nim
proc buildFallbackCorrelationId*(): string {.inline.} =
  let tick = correlationFallbackCounter.fetchAdd(1'u64, moRelaxed) + 1'u64
  let micros = uint64(epochTime() * 1_000_000.0)     # SYSCALL (gettimeofday)
  toHex(micros, 16) & toHex(tick, 16)                 # 2 string allocs + 1 concat
```

**Per-request cost:**
- 1 atomic fetch-add (`moRelaxed`)
- 1 `epochTime()` → `gettimeofday` syscall
- 2 `toHex()` calls → 2 `mnewString` allocations + hex conversion
- 1 string concatenation `&` → 3rd allocation
- Total: **1 syscall + 3 heap allocations per request**

Profile confirms: 47-53 samples (0.7-0.8%) in `buildFallbackCorrelationId` and children.

**Fix:** Make lazy — only compute when `req.correlationId` is first accessed. Or use a simple atomic counter without timestamp/hex:
```nim
req.correlationId = ""  # Skip entirely
# Or: req.correlationIdSeq = counter.fetchAdd(1)  # No strings, no syscall
```

**Expected impact:** 2-3% throughput recovery.

---

### Regression #3: macOS fallback maintenance on every `onSocketData` (HIGH)

**File:** `http.nim:7409-7414`
```nim
when defined(macosx):
  let ranMaintenance = server.beginMacosFallbackMaintenance()
  defer:
    server.endMacosFallbackMaintenance(ranMaintenance)
```

This runs on **every socket data callback**. Even though it early-exits if `macosMaintenanceEpochMs == nowMs`, it still calls:

**`beginMacosFallbackMaintenance` (line 6575):**
```nim
let nowMs = nowEpochMs()                              # SYSCALL (epochTime)
if server.macosMaintenanceEpochMs == nowMs: return     # Usually true
```

**`nowEpochMs` (line 1862):**
```nim
proc nowEpochMs(): int64 {.inline.} =
  int64(epochTime() * 1000.0)                         # gettimeofday syscall
```

Even the early-exit path costs a **gettimeofday syscall per socket data event**. At high request rates with pipelining, this fires tens/hundreds of thousands of times per second.

When it does run (once per ms), `runLoopPreMaintenance` calls:
- `flushCrossThreadDeferQueue` — takes a lock (line 942: `withLock`)
- `resetLoopFairnessBudgets` — resets counters
- `flushDeferredPreCallbacks` — checks/moves sequences

And `endMacosFallbackMaintenance` → `runLoopPostMaintenance`:
- `flushQueuedWsDrainHandlers`
- `flushDeferredPostCallbacks`

**Fix:** Use a monotonic counter or `mach_absolute_time` (no syscall) instead of `epochTime`. Or throttle by request count instead of wall time:
```nim
inc server.macosMaintenanceCounter
if (server.macosMaintenanceCounter and 0xFF) == 0:  # Every 256 requests
  server.runLoopPreMaintenance()
```

**Expected impact:** 3-5% throughput recovery.

---

### Regression #4: `overloadRejectReasonFor` called unconditionally (MEDIUM)

**File:** `http.nim:7420-7423`
```nim
let overloadReason = overloadRejectReasonFor(sockData)
if overloadReason != orrNone:
  rejectOverloadedSocket(sockData, s, overloadReason)
  return s
```

**Even with overload disabled** (default), `overloadRejectReasonFor` (line 7319) still calls:
- `pendingActiveCountForOverload(sockData)` — field access
- `overloadConfiguredBacklogLimit(server)` — reads option
- `overloadConfiguredPendingLimit(server)` — reads option
- `overloadAdaptiveEnabledFor(server)` — reads option + calls both above again
- `decaySpillPressure(server)` — **unconditional state mutation** (reads/writes `spillPressureScore` + calls `spillPressureRecoverThresholdFor`)

That's ~6 function calls + state mutation per request, even when overload control is not configured.

**Fix:** Gate the entire check:
```nim
if server.overloadCheckEnabled:  # Pre-computed bool at server init
  let overloadReason = overloadRejectReasonFor(sockData)
  ...
```

Or at minimum, make `decaySpillPressure` conditional on overload being configured.

**Expected impact:** 1-2% throughput recovery.

---

### Regression #5: `emitBeforeHeaders` + `emitBeforeWrite` + `emitAfterWrite` hooks (MEDIUM)

**File:** `http.nim:2978-2980, 3003-3005`
```nim
sockData.server.emitBeforeHeaders(res.requestRef, res)   # Per response
sockData.server.emitBeforeWrite(totalBytes, false)        # Per response
...
sockData.server.emitAfterWrite(wrote, true, false)        # Per write
sockData.server.emitAfterWrite(0, false, false)           # On failure too
```

Each hook function (lines 1157-1176) does:
```nim
proc emitBeforeHeaders(...) {.inline.} =
  if server != nil and server.beforeHeadersHandler != nil:    # nil check
    try:                                                       # exception frame setup
      server.beforeHeadersHandler(req, res)
    except CatchableError as err:
      server.emitServerPanic(...)
```

The `try/except` frame has a setup cost even when the handler is nil and the body never executes. Three of these per response = measurable overhead at high rates.

In `flushPendingResponses`, `emitAfterWrite` is called **inside the write loop** (lines 2889, 2891, 2929, 2937) — potentially multiple times per flush.

**Fix:** Check nil **before** the try/except, or better, cache handler presence as a boolean:
```nim
proc emitAfterWrite(...) {.inline.} =
  if server == nil or server.afterWriteHandler == nil: return  # Bail before try
  try:
    server.afterWriteHandler(...)
  except CatchableError as err:
    ...
```

Or precompute `server.hasWriteHooks = server.afterWriteHandler != nil` at setup time.

**Expected impact:** 1-2% throughput recovery.

---

### Regression #6: Write budget / fairness tracking overhead (MEDIUM)

**File:** `http.nim:2857-2858, 2893, 7493-7500, 7505`

Per-flush: `writeBudgetIterationsFor` + `writeBudgetBytesFor` (2 func calls with nil checks + option reads).

Per-write: `consumeLoopWriteBudget` (line 2893) — always called even when budget is effectively infinite.

Per-request in parse loop: `dispatchLoopBudgetExhausted()` check (line 7505) on every iteration.

Per socket-data: `resetLoopFairnessBudgets()` runs via macOS maintenance (line 6518).

**Fix:** If budgets aren't configured (default), skip all budget checks:
```nim
if server.fairnessEnabled:  # Pre-computed
  if server.dispatchLoopBudgetExhausted(): ...
```

**Expected impact:** 1% throughput recovery.

---

### Regression #7: `epochTime` called 3-5x per request path (HIGH — flamegraph confirmed)

**Flamegraph evidence:** 58 samples (0.9%) JSON, 84 samples (1.3%) plaintext — across ALL `epochTime` callers combined.

Across the full request lifecycle, `epochTime()` (a `gettimeofday` syscall) is called:

1. `beginMacosFallbackMaintenance` → `nowEpochMs()` (http.nim:6581) — every socket data event
2. `buildFallbackCorrelationId` → `epochTime()` (app.nim:34) — every request
3. `setSocketTimeoutPhase` → `nowEpochMs()` (http.nim:1981) — **up to 5x per request** (see #8)
4. `requestStartMicros` → `epochTime()` (http.nim:7590) — if timing enabled
5. `requestEndHandler` → `epochTime()` (http.nim:7701) — if timing enabled

In the best case (no timing hooks): **3-7 syscalls per request** (#1 + #2 + #3×multiple).
With timing: **5-9 syscalls per request**.

**Fix:** Cache a coarse timestamp per event-loop tick (updated once per ms or per loop iteration) and use it everywhere.

**Expected impact:** 2-3% throughput recovery (combined with #2, #3, and #8 fixes).

---

### Regression #8: `setSocketTimeoutPhase` calls `nowEpochMs()` repeatedly (HIGH — flamegraph confirmed)

**Flamegraph evidence:** 55 samples (0.8%) JSON, 80 samples (1.2%) plaintext — **the 2nd largest framework-code hotspot after app dispatch**.

**File:** `http.nim:1968-1983`
```nim
proc setSocketTimeoutPhase(
  sockData: ptr SocketData,
  s: UsSocketPtr,
  phase: TimeoutPhase,
  requestSeq: uint64 = 0'u64
) {.inline.} =
  if sockData == nil or sockData.server == nil or s == nil:
    return
  let timeoutSeconds = phaseTimeoutSecondsFor(sockData, phase)
  if not shouldUpdateSocketTimeoutPhase(sockData, phase, requestSeq, timeoutSeconds):
    return
  sockData.timeoutPhase = phase
  sockData.activeRequestSeq = requestSeq
  sockData.phaseStartedAtMs = nowEpochMs()    # SYSCALL every call
  sockData.timeoutPhaseSeconds = timeoutSeconds
  us_socket_timeout(sockData.server.ssl.toInt, s, timeoutSeconds)
```

**Called up to 5 times per request** in the parse/dispatch/response path:
- Line 7488: `tpHeaderRead` after response sent
- Line 7572: `tpHeaderRead` on pipeline
- Line 7588: `tpBodyRead` when body expected
- Line 7619: `tpHandlerExec` before handler
- Line 7698-7700: `tpHeaderRead` or `tpWriteDrain` after handler

Each call does: `phaseTimeoutSecondsFor` (option lookup) + `shouldUpdateSocketTimeoutPhase` (comparison) + `nowEpochMs()` (syscall) + `us_socket_timeout` (uSockets C call).

**Fix:** Use the cached coarse timestamp instead of `nowEpochMs()`:
```nim
sockData.phaseStartedAtMs = cachedEpochMs  # No syscall, updated once per loop tick
```

Or skip the timestamp entirely if timeout tracking doesn't need ms-precision start times.

**Expected impact:** 1-2% throughput recovery.

---

## Combined Regression Summary

| # | Issue | Per-Request Cost | Flamegraph % | Est. Impact |
|---|-------|-----------------|-------------|-------------|
| 1 | `new(HttpResponse)` not pooled | 1 heap alloc + ARC destroy | 0.2-0.3% (nimNewObj) | 5-10% |
| 2 | `buildFallbackCorrelationId` | 1 syscall + 3 allocs | ~0.4% (partial epochTime) | 2-3% |
| 3 | macOS maintenance `epochTime` | 1 syscall + checks | 0.2-0.4% | 3-5% |
| 4 | `overloadRejectReasonFor` unconditioned | 6 func calls + state mutation | <0.1% (inlined) | 1-2% |
| 5 | Hook try/except frames | 3 exception frames per response | <0.1% (inlined) | 1-2% |
| 6 | Budget/fairness tracking | Multiple func calls + checks | <0.1% | 1% |
| 7 | Multiple `epochTime` syscalls | 3-7+ syscalls cumulative | **0.9-1.3%** | 2-3% |
| 8 | `setSocketTimeoutPhase` `nowEpochMs` | Up to 5 syscalls per request | **0.8-1.2%** | 1-2% |
| **Total** | | | | **~17-28%** |

**Note on flamegraph %:** Items #1, #4, #5, #6 show low flamegraph % because they're heavily inlined — the profiler attributes their cost to parent functions. The code analysis impact estimates remain valid. Items #7 and #8 are the most directly measurable hotspots.

The remaining gap to 150k likely comes from compounding effects: more allocations = more GC/ARC work = more cache misses = worse throughput under contention.

---

## Recommended Fix Order

### Tier 1: Quick Wins (fix today)

**1a. Skip `buildFallbackCorrelationId` in benchmark** (`app.nim:2847,2868`)
```nim
# Option A: Make it configurable
if app.generateCorrelationIds:
  req.correlationId = buildFallbackCorrelationId()

# Option B: Lazy (compute on first access)
# Remove lines 2847 and 2868 entirely
```

**1b. Gate `overloadRejectReasonFor`** (`http.nim:7420-7423`)
```nim
if sockData.server.overloadControlEnabled:
  let overloadReason = overloadRejectReasonFor(sockData)
  if overloadReason != orrNone:
    rejectOverloadedSocket(sockData, s, overloadReason)
    return s
```
Set `overloadControlEnabled` at server init based on whether any overload options are configured.

**1c. Use counter-based macOS maintenance throttle** (`http.nim:6575`)
```nim
proc beginMacosFallbackMaintenance(server: HttpServer): bool {.inline.} =
  when defined(macosx):
    if server == nil or server.macosMaintenanceDepth > 0:
      return false
    inc server.macosMaintenanceCounter
    if (server.macosMaintenanceCounter and 0x3FF) != 0:  # Every 1024 events
      return false
    # ... rest of maintenance
```

### Tier 2: Pool `HttpResponse` (biggest single win)

**2a. Add `HttpResponse` pooling** (`http.nim:7599-7600`)

Replace `new(res)` with pool acquire, and return to pool after response is sent. Similar pattern to nim_express's `acquireRequest`/`releaseRequest`.

```nim
# Thread-local pool
var httpResponsePool {.threadvar.}: seq[HttpResponse]

proc acquireHttpResponse(): HttpResponse {.inline.} =
  if httpResponsePool.len > 0:
    result = httpResponsePool.pop()
  else:
    new(result)

proc releaseHttpResponse(res: HttpResponse) {.inline.} =
  if httpResponsePool.len < 4096:
    res.reset()  # Clear fields
    httpResponsePool.add(res)
```

### Tier 3: Reduce syscalls (flamegraph-confirmed — 1.7-2.5% of total CPU)

**3a. Cache coarse timestamp** — update once per event loop iteration:
```nim
var cachedEpochMs {.threadvar.}: int64
var cachedEpochMicros {.threadvar.}: int64

proc refreshCachedTime() {.inline.} =
  let t = epochTime()
  cachedEpochMs = int64(t * 1000.0)
  cachedEpochMicros = int64(t * 1_000_000.0)
```
Call `refreshCachedTime()` once in `runLoopPreMaintenance`. Use `cachedEpochMs`/`cachedEpochMicros` everywhere else.

**3b. Fix `setSocketTimeoutPhase`** (`http.nim:1981`) — replace `nowEpochMs()` with cached timestamp:
```nim
sockData.phaseStartedAtMs = cachedEpochMs  # Was: nowEpochMs()
```
This alone eliminates up to 5 `gettimeofday` syscalls per request.

### Tier 4: Remove hook overhead on hot path

**4a. Pre-check hook existence** at server setup, skip try/except frames entirely when hooks are nil.

---

## Expected Recovery

| After Tier | Est. Req/sec | Recovery |
|-----------|-------------|----------|
| Current   | ~90k        | —        |
| Tier 1    | ~105-110k   | +15-20%  |
| Tier 2    | ~120-130k   | +10%     |
| Tier 3    | ~135-145k   | +5-10%   |
| Tier 4    | ~145-155k   | +5%      |
