# Correctness and Security Hardening Task List

Status legend: `[ ]` not started, `[~]` in progress, `[x]` fixed and covered by tests.

## Critical and High

- [x] `EXP-FP-001` Fix `fastProxy` timeout lifecycle so delayed upstream callbacks cannot write through a pooled `Response` into a later request. Add a regression test that times out one proxied request, reuses the response wrapper, then verifies the late upstream callback is ignored.
- [x] `USO-IOU-001` Fix Linux io_uring queued-write close ordering. Add an io_uring integration test proving HTTP close responses and WebSocket close frames are fully delivered before FIN.
- [x] `USO-XTD-001` Fix cross-thread deferred wake shutdown race. Add a stress test racing `deferFromAnyThread`/offload completion with server cleanup under Linux.
- [x] `USO-SHUT-001` Route `shutdown()`/`close()` cleanup through the owner event loop once a loop exists; do not free or mutate libuSockets loop resources from non-owner threads.
- [x] `EXP-OFF-001` Fix offload completion scheduling drops so `runOffload` futures cannot hang forever when cross-thread defer queues overflow or shutdown begins.
- [x] `EXP-OFF-002` Replace/block-avoid the request-path blocking Malebolgia `spawn` behavior with explicit backpressure or non-blocking admission.
- [x] `EXP-FIN-001` Route optimized terminal response paths (`text`, cached/fragment/page-buffer HTML, and similar fast paths) through finalization hooks before headers are built so middleware such as response-time and session cannot be bypassed.
- [x] `UTL-LOG-001` Fix async logger shutdown deadlock when producers block on a full ring and `close()` needs `producerLock`.
- [x] `UTL-LOG-003` Bound or document async logger shutdown behavior when stdout/stderr/FIFO writes block during flush thread shutdown.
- [x] `UTL-FJ-001` Add configurable JSON input/array allocation limits so large streams or arrays fail with controlled errors instead of container OOM.
- [x] `UTL-FM-004` Add keyed/randomized FastMap/FastSet string hash seeding or another hash-flooding mitigation for untrusted HTTP keys.
- [x] `UTL-FJ-BLD-001` Move simdjson compile/archive side effects out of source-tree compile-time static blocks or add locking/read-only-safe build behavior.
- [x] `FHC-OWN-001` Make `HttpClient` ownership non-copyable or ref-backed so raw loop/context/timer/socket ownership cannot be duplicated and double-closed.
- [x] `FHC-H1-PIPE-001` Fix HTTP/1 pipelined timeout scanning so later requests with shorter deadlines cannot hang behind the first pending response.
- [x] `FHC-H1-002` Enforce small HTTP/1 status/header line and aggregate header caps before `recvBuf` can grow toward the 64 MiB connection buffer cap.
- [x] `FHC-CB-001` Fix `HttpClient` HTTP/1 and HTTP/2 callback reentrancy so callbacks can close the client without use-after-free or double-close.
- [x] `FHC-SSE-001` Fix SSE callback reentrancy so callbacks can close the client without writing parser metadata back into freed connection data.
- [x] `FHC-SSE-002` Route early SSE setup failures (invalid URL, unsupported scheme, init/connect failure) through caller `onError` instead of silent return.
- [x] `EXP-TPL-001` Fix embedded pre-rendered template caching so per-request status, headers, and cookies are never replayed to another request.
- [x] `EXP-BRA-001` Fix async before-route advice rejection so requests are finalized with an error when advice rejects without sending.

## Medium

- [x] `EXP-SES-001` Fix session cookie emission for the common mutate-session-then-send flow.
- [x] `EXP-PRX-001` Fix standard proxy oversized-response errors so upstream headers/cookies are not forwarded on generated 502 responses.
- [x] `EXP-HTML-001` Fix HTML response finalization for `1xx`, `204`, and `304` so forbidden body/entity headers are not emitted.
- [x] `EXP-NOBODY-001` Omit entity metadata consistently for generic no-body responses (`send`, `jsonRaw`, `text`) just as HTML no-body responses do.
- [x] `USO-XTD-002` Fix `deferFromAnyThread` so user error callbacks never run on non-owner worker threads.
- [x] `USO-H2-001` Map HTTP/2 HPACK/header block limits to configured server HTTP header limits instead of hardcoded 1 MiB / 4096-header ceilings.
- [x] `USO-BLD-001` Add backend stamp/symbol validation or backend-specific archives so stale `uSockets.a` cannot silently mismatch epoll/io_uring/kqueue/GCD compile flags.
- [x] `USO-GCD-001` Guard or document macOS GCD backend main-thread requirements; fail fast or route consistently through the GCD loop queue.
- [x] `USO-WS-003` Truncate WebSocket close reasons on UTF-8 boundaries in server close-frame generation.
- [x] `USO-WS-001` Make the exported WebSocket decoder enforce server-side masking policy through an explicit peer-mode or `requireMasked` option.
- [x] `USO-WS-002` Reject invalid WebSocket opcodes before payload allocation, copy, unmask, or decompression work.
- [x] `FHC-WS-001` Stop WebSocket buffered-frame delivery after `onMessage` closes or starts closing the socket.
- [x] `FHC-WS-003` Tighten or remove the keyless exported WebSocket upgrade-response validator so forged non-upgrade responses cannot be accepted.
- [x] `FHC-H2-001` Fragment outgoing HTTP/2 HEADERS into CONTINUATION frames according to `remoteSettings.maxFrameSize`.
- [x] `FHC-H2-002` Emit the required HPACK dynamic table size update after peer `SETTINGS_HEADER_TABLE_SIZE` changes.
- [x] `FHC-H2-003` Account errored HTTP/2 DATA frames against local flow-control windows or close the connection consistently.
- [x] `FHC-H2-004` Treat unknown extension frames during an open HEADERS/CONTINUATION block as protocol errors.
- [x] `UTL-FM-001` Fix long-lived string `FastMap`/`FastSet` arena retention under insert/delete churn, including growing overwrites.
- [x] `UTL-FM-002` Fix or harden `putHashed` so identical keys with different caller-supplied hashes cannot become duplicate logical entries.
- [x] `UTL-FM-003` Add explicit arena allocation rollback or capacity reservation for failed insert paths.
- [x] `BLD-SH-001` Quote or reject unsafe repository filenames in Nimble/Make build and test glue.
- [x] `BLD-TEST-001` Fix top-level `make test` so documented verification does not target missing `nim_express/tests/test_express.nim`.

## Low and Correctness

- [x] `EXP-RT-001` Fix `responseTime` middleware so the header is emitted from a before-headers/finalization hook.
- [x] `FHC-H1-001` Reject malformed HTTP/1 status lines such as `HTTP/1.1 200OK`.
- [x] `FHC-WS-002` Truncate WebSocket close reasons on UTF-8 code point boundaries or reject invalid close reasons.
- [x] `UTL-LOG-002` Fix threaded default logger replacement leak and unsynchronized mutable global publication.
- [x] `EXM-TODO-001` Bound the Todo SQLite full-fragment render path and move blocking SQLite work off the async event loop, or mark the path non-production-only.

## Verification Policy

- Add or update a targeted failing test before each fix unless the issue is strictly build-system quoting or lifecycle code that needs a smoke/stress harness first.
- Run targeted tests in Docker after each fix.
- Run package-level Docker verification after each group of related fixes.
- Run Linux epoll and io_uring Docker builds before marking transport items complete.
