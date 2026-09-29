# nim_usockets Deep Analysis

## 1) Executive summary

`nim_usockets` is architected as a high-performance, single-loop, callback-driven HTTP/WebSocket engine with per-socket state kept in `SocketData` (uSockets ext memory), explicit fairness budgets, and write coalescing for both HTTP and WebSocket paths.

The parser and framing core has several strong correctness protections (Host validation, TE/CL ambiguity rejection, chunk framing checks, WebSocket masking and close-code validation), and the queue/backpressure system is thoughtfully instrumented.

The most important issues found:

- **Critical memory safety risk** in buffer compaction/shift code from using overlapping `copyMem` operations.
- **High-risk operational DoS path** from synchronous body spill-to-disk writes on the event loop thread.
- **High-risk response splitting vector** because response headers are emitted without CR/LF sanitization.
- Additional medium risks in API correctness (`sendFilePreparedResponse` success path), protocol behavior (`Expect: 100-continue` always rejected), and resilience under header/control-frame abuse.

Overall: the core is strong, but the above issues should be addressed before relying on this in hostile traffic environments.

## 2) Findings (severity-tagged)

### [Critical] Overlapping `copyMem` in in-place buffer compaction/shift causes undefined behavior

- **Where**:
  - `src/nim_usockets/http.nim:5159`
  - `src/nim_usockets/http.nim:5174`
  - `src/nim_usockets/http.nim:5461`
- **Why it is critical**:
  - Nim’s `copyMem` requires **non-overlapping** memory regions.
  - These call sites copy from `buffer[bufferStart..]` into `buffer[0..]` (same backing memory, overlapping ranges), which is UB and can corrupt data/crash under realistic traffic patterns (compaction, upgrade residual shifts, pipelined input).
- **Recommendation**:
  - Replace overlapping `copyMem` with `moveMem` at all in-place shifts.
  - Add tests that force compaction/shift under partial-parse and upgrade transitions.

### [High] Response splitting / header injection due to unsanitized header key/value emission

- **Where**:
  - Header setter entry: `src/nim_usockets/http.nim:3257`
  - Emission points:
    - `src/nim_usockets/http.nim:3313`
    - `src/nim_usockets/http.nim:3452`
    - `src/nim_usockets/http.nim:3598`
    - `set-cookie` emission: `src/nim_usockets/http.nim:3327`, `3465`, `3611`
- **Impact**:
  - If application code passes untrusted header/cookie values, embedded `\r`/`\n` can inject extra headers/body (response splitting, cache poisoning).
- **Recommendation**:
  - Enforce RFC-safe header validation in `setHeader`:
    - key must be token chars only,
    - reject any `\r`/`\n` in key or value.
  - Apply same checks for `set-cookie` values before write.

### [High] Synchronous body spill-to-disk on event loop enables head-of-line blocking DoS

- **Where**:
  - Blocking write loop: `src/nim_usockets/http.nim:2497`
  - Spill calls: `src/nim_usockets/http.nim:2526`, `2543`
  - Invoked during parse path: `src/nim_usockets/http.nim:3041-3043`, `3066-3068`
  - Called from socket data callback path: `src/nim_usockets/http.nim:5395-5396`
- **Impact**:
  - Large/spill-triggered uploads do disk IO in the hot loop callback thread.
  - Slow disk or contention blocks unrelated connections, creating easy throughput collapse.
- **Recommendation**:
  - Move spill writes off loop thread (worker queue/thread pool) or use asynchronous file IO strategy.
  - Add per-socket spill budget and reject/429 policy under disk pressure.

### [Medium] `sendFilePreparedResponse` returns false on successful immediate completion

- **Where**:
  - `src/nim_usockets/http.nim:1966` (function start)
  - Success path with bare `return`: `src/nim_usockets/http.nim:2034-2039`
- **Impact**:
  - In the `done == true` fast path, function exits without explicit `true`, returning default `false` for a `bool` proc.
  - Callers may mis-handle success as failure.
- **Recommendation**:
  - Change that path to `return true`.
  - Add a regression test for the fully-drained fast path.

### [Medium] `Expect: 100-continue` is always rejected with 417

- **Where**:
  - Parse/validation: `src/nim_usockets/http.nim:2290`, `2337-2345`
  - 417 response mapping: `src/nim_usockets/http.nim:88`, `5210`
- **Impact**:
  - Legit clients using `Expect: 100-continue` never get interoperability-compliant behavior.
  - Can increase client retry/body resend inefficiency.
- **Recommendation**:
  - Keep unsupported expectations -> `417`.
  - Implement optional `100 Continue` path for `100-continue` when body acceptance policy allows.

### [Medium] No dedicated header-size/header-count limits (headers can consume full body budget)

- **Where**:
  - Header terminator scan across full parse window: `src/nim_usockets/http.nim:2736-2739`
  - Input cap is broad `maxBodySize` gate in socket callback: `src/nim_usockets/http.nim:5322-5328`
- **Impact**:
  - Attackers can send very large header blocks (up to body cap) to burn CPU/memory per connection.
  - This is a classic low-cost DoS vector even with valid HTTP syntax.
- **Recommendation**:
  - Add `maxHeaderBytes`, `maxHeaderCount`, and `maxHeaderLineBytes`.
  - Return `431 Request Header Fields Too Large` for header-limit violations.

### [Medium] Control-frame responses (PONG/CLOSE) can be dropped by general backpressure policy

- **Where**:
  - PING -> PONG path: `src/nim_usockets/http.nim:5140-5143`
  - Backpressure drop/high-water policy: `src/nim_usockets/http.nim:4238-4277`, `4281-4342`, `4342-4421`
- **Impact**:
  - Under backpressure, control responses can be dropped, causing peer disconnect churn and unstable sessions.
- **Recommendation**:
  - Reserve a small control-frame queue budget that bypasses normal drop policy.
  - Never drop CLOSE/PONG once parsed; close socket only if even control budget cannot be honored.

### [Low] `panicHandler` exists but is not used around user callback execution

- **Where**:
  - Field and setter: `src/nim_usockets/http.nim:353`, `5733`
  - User handler call site: `src/nim_usockets/http.nim:5489`
- **Impact**:
  - Exceptions in app handlers are not routed through configured panic callback.
  - Operational diagnostics and controlled failure behavior are weaker than API implies.
- **Recommendation**:
  - Wrap user handler invocation in `try/except` and dispatch to `panicHandler` plus safe close/fail policy.

### [Low] Standalone `websocket.nim` has non-strict masking behavior and fixed mask key for masked encode

- **Where**:
  - Fixed mask key (`# Should be random`): `src/nim_usockets/websocket.nim:168`
  - Decode does not enforce mask-required mode: `src/nim_usockets/websocket.nim:221`, `237`, `257`
- **Impact**:
  - If this module is used directly, client-frame masking semantics may be non-RFC-strict.
- **Recommendation**:
  - Use cryptographically random mask for masked client frames.
  - Add strict decode mode that requires masked client->server frames.

## 3) Optimization opportunities (prioritized)

1. **Fix overlap copies (`moveMem`) and reduce compaction frequency**: removes UB and avoids repeated memory shifts in hot path.
2. **Make body spill asynchronous**: largest single latency/throughput protection under large-upload traffic.
3. **Add header hard-limits with early abort**: protects parser CPU/memory and reduces pathological scans.
4. **Control-frame fast lane for WebSocket**: keeps protocol liveness stable under backpressure.
5. **Object/buffer pooling for `HttpRequest`/`HttpResponse` and header strings**: reduce allocation churn on high RPS.
6. **Optional no-copy request views for path/query/selected headers**: lower allocation pressure in parse path.
7. **Use monotonic integer clocks for request timing hooks**: avoid `epochTime()*1_000_000` float conversions in hot callback.
8. **Eliminate global callback server singleton dependency (`globalServer`)**: fetch server from context/socket ext for cleaner multi-instance behavior.
9. **Expose fine-grained overload policies (429 vs 503, per-IP/backlog gating)**: smoother degradation under bursts.
10. **Add focused fuzzing around parser + WS frame decoder**: catch rare edge-cases early without regressing RFC behavior.

## 4) Security issues and mitigations

### A. Memory corruption risk from overlapping copies
- **Issue**: in-place compaction uses `copyMem` with overlapping regions.
- **Mitigation**: replace with `moveMem`; add regression tests with partial frame/request boundaries and upgrade leftovers.

### B. Response splitting via unsanitized headers
- **Issue**: raw header values are interpolated into response stream.
- **Mitigation**: reject CR/LF and invalid token chars in header names; sanitize/validate `set-cookie` paths.

### C. Event-loop blocking spill IO DoS
- **Issue**: large request spill writes are synchronous in parse callback.
- **Mitigation**: async spill pipeline + backpressure thresholds + disk-pressure fail-fast policy.

### D. Header abuse DoS (no dedicated header limits)
- **Issue**: header memory/CPU bounded only by broad body-size cap.
- **Mitigation**: add explicit header caps and 431 handling.

### E. WebSocket control-plane reliability under pressure
- **Issue**: pong/close can be dropped by generic backpressure policy.
- **Mitigation**: reserve control-frame budget and bypass drop policy for mandatory control replies.

### F. Parser/request-smuggling posture status
- **Strong points already present**:
  - TE+CL rejected, duplicate CL mismatch rejected.
  - malformed TE/chunk framing rejected.
  - HTTP/1.1 Host requirement enforced.
  - strict WebSocket upgrade key/version checks.
- **Keep as non-regression requirements** for future optimizations.

## 5) Quick-win action list (top 10)

1. Replace overlapping `copyMem` with `moveMem` at `http.nim:5159`, `5174`, `5461`.
2. Fix `sendFilePreparedResponse` fast-path `return` to `return true` at `http.nim:2039`.
3. Add header validation in `setHeader` (block CR/LF and invalid token chars).
4. Add same validation for `set-cookie` emission paths.
5. Introduce `maxHeaderBytes` / `maxHeaderCount` / `maxHeaderLineBytes` + return 431.
6. Add control-frame reserved queue path for WebSocket ping/pong/close handling.
7. Add optional RFC-compliant `Expect: 100-continue` handling mode.
8. Offload spill-to-disk writes from event loop thread.
9. Wire `panicHandler` into guarded user-callback execution.
10. Add tests for:
   - overlap-safe compaction behavior,
   - sendfile fast-path return correctness,
   - header injection rejection,
   - control-frame behavior under forced backpressure.
