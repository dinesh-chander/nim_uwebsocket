# Performance Optimization Task List

Date: 2026-05-12

Scope: `nim_utils`, `nim_usockets`, `nim_fasthttpclient`, `nim_express`, benchmarks, and Linux/macOS transport backends.

## Baseline Evidence

Short Docker run on Linux with `USOCKETS_BACKEND` matrix, 4 workers, `wrk -t4 -c100 -d3s --latency`, `NATIVE_OPT=1`, seccomp unconfined for io_uring:

| Backend | Scale Mode | Requests/sec | Avg Latency | p50 | p90 | p99 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| epoll | threaded | 1,005,733.84 | 81.44us | 72us | 129us | 223us |
| epoll | cluster | 992,671.30 | 81.94us | 74us | 131us | 224us |
| io_uring | threaded | 566,016.12 | 177.45us | 132us | 257us | 0.96ms |
| io_uring | cluster | 676,478.85 | 136.53us | 124us | 190us | 325us |

The current io_uring gap is not explained only by `threaded` versus `cluster`; io_uring remains slower under matched 4-worker cluster scaling.

## Post-Change Validation

Docker run on Linux with `USOCKETS_BACKEND` matrix, 4 workers, `wrk -t8 -c1000 -d60s --latency`, `NATIVE_OPT=1`, seccomp unconfined for io_uring:

| Backend | Scale Mode | Requests/sec | Avg Latency | p50 | p90 | p99 | Requests | Socket Errors |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| epoll | threaded | 1,202,070.49 | 828.30us | 577us | 1.61ms | 3.75ms | 72,191,484 | 0 |
| epoll | cluster | 1,230,438.61 | 812.22us | 555us | 1.61ms | 3.76ms | 73,896,154 | 0 |
| io_uring | threaded | 986,714.90 | 1.03ms | 849us | 1.71ms | 3.67ms | 59,300,856 | 0 |
| io_uring | cluster | 1,017,845.11 | 0.99ms | 816us | 1.64ms | 3.56ms | 61,164,548 | 0 |

The direct-send/writev fast path closes most of the previous io_uring throughput gap under the required 1000-client, 60-second load. Epoll remains the production default because it is still about 17-21% faster in this Docker run, while io_uring now has comparable p99 latency and no observed socket errors.

## Decision States

- `[todo]` Needs review or implementation.
- `[debate]` Candidate for review-agent debate.
- `[doing]` Implementation in progress.
- `[done]` Implemented and verified.
- `[defer]` Valid opportunity, but not a first implementation target.

## P0: Transport Hot Path

- [done] `PERF-IOU-001` Add a direct nonblocking send/writev fast path before io_uring fallback.
  - Evidence: `nim_usockets/usockets/src/io_uring/io_socket.c` currently copies every `us_socket_write`, `us_socket_write2`, and `us_socket_writev_n` payload into a per-socket buffer and completes the send via SQE/CQE. Tiny HTTP responses pay an extra copy plus ring completion latency even when `send` or `sendmsg` would complete immediately on a nonblocking socket.
  - Expected impact: High for plaintext and small JSON/template responses.
  - Risk: Medium. Must preserve partial-write/backpressure semantics and close-on-error behavior.

- [debate] `PERF-IOU-002` Rework the io_uring loop wait policy.
  - Evidence: `io_loop.c` calls `io_uring_submit_and_wait(&loop->ring, 1)` every loop iteration. Under sustained traffic this can force a wait-oriented loop even when work can be submitted and drained in larger batches.
  - Expected impact: Medium to high for high concurrency and pipelined loads.
  - Risk: Medium/high. Event-loop fairness, timers, async wakeups, and close cleanup need regression coverage.

- [done] `PERF-IOU-003` Make io_uring ring entries and receive buffer size explicit benchmark variables.
  - Evidence: ring entries are hardcoded at `2048`; receive buffer size is `MAX_MESSAGE_LEN` from backend headers, while Makefile only exposes max connections and receive buffer count.
  - Expected impact: Low for tiny plaintext; possibly medium for larger headers, bodies, WebSocket frames, and H2.
  - Risk: Low if guarded by compile-time defaults.
  - Status: compile-time knobs added as `IOURING_ENTRIES` and `IOURING_RECV_BUFFER_SIZE`, alongside existing max-connections and receive-buffer-count knobs.

- [defer] `PERF-IOU-004` Lazy remote-address lookup on accept.
  - Evidence: `io_loop.c` calls `bsd_remote_addr` for each accepted socket before adoption. This is a syscall on accept, even for apps that never read `remoteAddress`.
  - Expected impact: Low for keepalive throughput, medium for high connection churn.
  - Risk: Medium because on-open callbacks currently receive the address.

- [defer] `PERF-IOU-005` Evaluate `IORING_SETUP_SQPOLL`, `IORING_SETUP_DEFER_TASKRUN`, and kernel-version-specific flags.
  - Evidence: queue init currently uses `IORING_SETUP_COOP_TASKRUN | IORING_SETUP_SINGLE_ISSUER`.
  - Expected impact: Workload and kernel dependent.
  - Risk: Medium/high. SQPOLL needs privileges and careful CPU accounting.

## P1: HTTP Server and Framework Hot Path

- [debate] `PERF-HTTP-001` Remove avoidable response double-copy for small fixed responses.
  - Evidence: `nim_express/response.nim` and `nim_usockets/http.nim` already build compact response strings or header/body pairs, but io_uring currently copies them again before submission.
  - Expected impact: Covered mostly by `PERF-IOU-001`; framework changes may help epoll too if copies remain.
  - Risk: Medium. Response lifetimes must remain valid until write completion.

- [todo] `PERF-HTTP-002` Add a zero-allocation benchmark target for the true `/plaintext` framework fast path.
  - Evidence: Existing benchmarks mix several endpoints and modes; regressions are harder to attribute without a stable micro benchmark that records response bytes, allocation count, and backend.
  - Expected impact: Medium for future optimization safety.
  - Risk: Low.

- [todo] `PERF-HTTP-003` Profile and reduce hot-path route/middleware bookkeeping for exact routes.
  - Evidence: Router and middleware layers have been hardened heavily; exact-route benchmarks should verify whether per-request locals, hooks, and middleware arrays are bypassed when unused.
  - Expected impact: Medium for minimal APIs.
  - Risk: Medium. Must not bypass user hooks, error flow, or middleware semantics.

- [defer] `PERF-HTTP-004` Precompute more status/header fragments for common response shapes.
  - Evidence: Common 200 text/json/html templates exist, but custom status codes and some headers still allocate.
  - Expected impact: Low/medium.
  - Risk: Low.

## P1: Data Structures and Serialization

- [todo] `PERF-UTIL-001` Benchmark and tune FastMap tombstone compaction under churn.
  - Evidence: fast-map correctness was recently fixed around Swiss-table probing. High-delete workloads can accumulate tombstones and degrade probe length.
  - Expected impact: Medium for header maps, routing params, and locals-heavy workloads.
  - Risk: Medium. Must preserve pointer-key and string-view semantics.

- [todo] `PERF-UTIL-002` Add fast_map and fast_set microbenchmarks to `bench/`.
  - Evidence: Existing tests cover correctness more than stable throughput envelopes.
  - Expected impact: Medium for preventing regressions.
  - Risk: Low.

- [todo] `PERF-JSON-001` Audit JSON response serialization for unnecessary string copies.
  - Evidence: `nim_fastjson` and response helpers use low-level copies. Need benchmark-backed confirmation that JSON endpoint throughput is not copy-bound.
  - Expected impact: Medium for JSON-heavy APIs.
  - Risk: Medium.

## P2: Client Stack

- [done] `PERF-WSLOAD-001` Avoid per-tick full connection scans when outbound message rate is below timer frequency.
  - Evidence: `nim_websocketcli/websocketload.nim` scanned every slot on every `--tick-ms` timer even when `--out-mps 1 --tick-ms 10` cannot send until 100 ticks have accumulated. At 40k clients this burns about 4 million slot checks/sec before writing a single application message.
  - Expected impact: Medium/high for high-connection low-message-rate soak tests.
  - Risk: Low/medium. The client sends in coarser batches for fractional/low rates, so validate message totals and connection accounting under Docker.
  - Status: Implemented worker-level rate credit. Docker epoll validation passed at 1k/10s and 40k/60s with exact sent/recv counts and zero errors.

- [done] `PERF-WSLOAD-001B` Iterate only open slots during outbound rate sends.
  - Evidence: Even after timer-credit batching, rate sends still scanned unopened/closed slots during long ramps, reconnect storms, and teardown.
  - Expected impact: Medium for high-connection ramp/close phases and partial-open failure cases.
  - Risk: Low. Maintain an O(1) open-slot index with swap-delete on close.

- [done] `PERF-FHC-003` Remove O(n^2) active WebSocket tracking during connect fanout.
  - Evidence: `trackActiveWs` scanned `client.activeWs` before every add. A 40k connection load test can spend millions of comparisons before the server path is measured.
  - Expected impact: Medium for high-connection WebSocket bootstrap and reconnect storms.
  - Risk: Low. Use an `activeWsIndex` for O(1) add/remove and keep a stale-index fallback scan.
  - Status: Implemented O(1) active WebSocket add/remove. Docker epoll validation passed at 1k/10s and 40k/60s; focused WS client tests passed.

- [done] `PERF-WSLOAD-002A` Add a binary opcode option to `websocketload`.
  - Evidence: Text-frame-only load tests include receive-side UTF-8 validation cost even when measuring raw frame transport.
  - Expected impact: Medium for raw WebSocket throughput/load validation.
  - Risk: Low.
  - Status: `--opcode text|binary` added and covered by Docker epoll binary smoke plus matrix smoke.

- [todo] `PERF-WSLOAD-002B` Add a static-frame load-test send path.
  - Evidence: `websocketload` currently sends text frames, receives echoed text validation cost, and builds/masks a fresh client frame for every static payload send.
  - Expected impact: Medium/high for client-limited throughput tests.
  - Risk: Medium. Keep normal API behavior and make the fast path opt-in for load tests.

- [done] `PERF-WSLOAD-003` Add repeated WebSocket Docker benchmark matrix and report metadata.
  - Evidence: Current 20k/40k reports are useful but mostly single-run and do not always capture backend, scale mode, seccomp, cgroup limits, bind-source count, CPU, kernel, dirty git state, and server env.
  - Expected impact: High for deciding whether a bottleneck is server code, Docker/runtime limits, source-port exhaustion, or the client harness.
  - Risk: Low.
  - Status: Added `benchmark/run_ws_docker_scale_matrix.sh`; Docker epoll smoke passed for text and binary opcode modes.

- [done] `PERF-WS-001` Benchmark no-copy receive/send-view WebSocket echo path.
  - Evidence: The server validates from the socket buffer, copies payload into a string for `WsHandler`, then echo benchmarks immediately send that string back.
  - Expected impact: Medium/high for echo throughput and large frames.
  - Risk: Medium/high because it touches handler API/lifetime semantics. Prefer internal benchmark-only path or compatible handler variant first.
  - Status: Added `WebSocketRawHandler`/`wsRaw` as an opt-in callback-scoped payload pointer API, kept the normal string handler compatible, and moved the realistic WebSocket benchmark to raw parsing. Docker epoll 4-thread 1000-client 4KB realtime runs completed cleanly at 29.15M sent/recv over a 60s send window plus drain.

- [done] `PERF-WS-008` Make benchmark default echo path use zero-copy receive and pointer send.
  - Evidence: The default WS echo benchmark previously copied inbound payloads into `string` before echoing. This made the default benchmark path measure framework allocation overhead rather than the lower-level server ceiling.
  - Expected impact: High for large echo frames and useful for identifying the next transport bottleneck.
  - Risk: Medium. Pointer payloads must be callback-scoped and copied before queueing on partial writes.
  - Status: `wbsEcho` now uses `wsRaw` plus `sendPtr`; `sendPtr` writes header + payload directly on successful sends and allocates a queued frame only when backpressure/partial write requires retention.

- [todo] `PERF-WS-002` Add profile controls for high-connection keepalive and queued-write coalescing.
  - Evidence: default WS keepalive pings all sockets in one timer burst, and queued write coalescing defaults to one frame.
  - Expected impact: Medium for 100k+ connection stability and backpressure throughput.
  - Risk: Low/medium. Benchmark with keepalive disabled/staggered and coalescing values `8|16|32` before changing defaults.

- [done] `PERF-WS-003` Remove keepalive snapshot allocation from high-connection WebSocket timers.
  - Evidence: `onWsKeepaliveFire` copied `server.websockets` before every keepalive pass. At 100k+ connections this creates a periodic O(N) allocation spike before any ping work.
  - Expected impact: Medium for high-connection soak tests and production idle-WS fleets.
  - Risk: Low/medium. Cursor iteration must remain safe with swap-delete close handling.
  - Status: Implemented cursor-based mutation-safe iteration without snapshot allocation; validate with Docker WS scale runs.

- [done] `PERF-WS-004` Make `wsKeepaliveInterval = 0` actually disable keepalive.
  - Evidence: benchmark server calls `setWsKeepaliveInterval(0)`, but lower-level listen setup and macOS fallback converted non-positive values back to `DefaultWsKeepaliveInterval`.
  - Expected impact: Medium/high for many-idle-WS benchmarks and deployments that explicitly disable keepalive.
  - Risk: Medium API semantics change for callers relying on `0` as default. Current public setter clamps to `0`, so disable semantics are the more predictable behavior.

- [done] `PERF-WS-005` Add explicit WS benchmark controls and startup metadata.
  - Evidence: `benchmark/ws_echo_bench.nim` currently reads only `PORT` and `THREADS`, making keepalive, backpressure, coalescing, and socket-buffer runs hard to compare.
  - Expected impact: High for decision quality.
  - Risk: Low.
  - Status: `ws_echo_bench` now reads and prints keepalive, idle timeout, backpressure, coalescing, and socket-buffer knobs.

- [done] `PERF-WS-006` Avoid frame allocation when an already-backpressured WebSocket send will be dropped.
  - Evidence: queued send paths built a full frame before checking high-water policy or queue capacity.
  - Expected impact: High for slow-client/fanout backpressure cases; near-zero for healthy echo.
  - Risk: Low/medium. Preserve control-frame policy and existing drop behavior.

- [done] `PERF-WS-007` Add production dynamic WebSocket backpressure budgeting.
  - Evidence: 20k-client realistic 4KB tests could OOM-kill the server when write queues grew under overload; static per-socket limits are easy to mis-size.
  - Expected impact: High for production stability under slow clients and bursty fanout.
  - Risk: Low/medium. Opt-in via config/env; existing static high-water behavior remains available.
  - Status: Added budget-derived high-water sizing from expected connections, typical message bytes, and total queue budget; wired through `nim_express` config/env and regression tests.

- [done] `PERF-HTTP-004` Make explicitly disabled HTTP timeouts cheap and semantically disabled.
  - Evidence: `connectionTimeout = 0` was documented as disabled but fell back to `DefaultConnectionTimeout`, and zero-timeout phase changes still called into `us_socket_timeout`.
  - Expected impact: Medium for explicit throughput profiles that disable timeout tracking.
  - Risk: Low/medium. Defaults still use secure non-zero timeouts; only explicit zero disables.

- [todo] `PERF-FHC-001` Benchmark HTTP/1 receive-buffer compaction and parse scans.
  - Evidence: `nim_fasthttpclient/client.nim` uses `moveMem` when partial data remains. Under many small responses, compaction can become visible.
  - Expected impact: Medium for client load tests.
  - Risk: Medium.

- [todo] `PERF-FHC-002` Benchmark HTTP/2 frame and HPACK decode hot paths with dynamic-table churn.
  - Evidence: H2/HPACK fuzz and correctness work changed several parser paths. Need dedicated throughput counters.
  - Expected impact: Medium.
  - Risk: Low for benchmark-only work.

## P2: Benchmark and Build Controls

- [done] `PERF-BENCH-001` Record backend, scale mode, compiler flags, kernel, CPU, Docker runtime, and seccomp mode in every benchmark report.
  - Evidence: Previous comparisons mixed scale modes and did not always capture runtime constraints.
  - Expected impact: High for reliable performance decisions.
  - Risk: Low.

- [done] `PERF-BENCH-002` Add a benchmark matrix target for epoll/io_uring x single/threaded/cluster.
  - Evidence: Manual matrix runs found an important io_uring regression shape.
  - Expected impact: Medium.
  - Risk: Low.
  - Status: `benchmark/run_linux_transport_scale_matrix.sh` runs the canonical backend x scale matrix with repetitions and links per-run reports.

- [todo] `PERF-BUILD-001` Separate Apple-Silicon Docker results from native Linux host targets.
  - Evidence: Docker Desktop can make CPU, syscall, and io_uring results differ from bare-metal Linux.
  - Expected impact: Medium for interpreting absolute ceilings.
  - Risk: Low.

## Initial Implementation Recommendation

Start with `PERF-IOU-001`. It is the clearest direct explanation for io_uring losing to epoll on tiny keepalive HTTP responses: epoll can complete a small `send` synchronously, while this io_uring backend copies the response into an owned buffer and waits for a CQE for every write. Implement it with strict fallback to the existing async path on partial write or `EAGAIN`, and benchmark before considering loop-policy changes.
