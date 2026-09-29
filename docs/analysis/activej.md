# ActiveJ Deep Analysis (implementation-focused)

Analyzed repository: `https://github.com/activej/activej`  
Local snapshot: `analysis/tmp/activej` at commit `6a7746d` (depth-1 clone)

## 1) Architecture and execution model

- Core server path is `HttpServer` on top of `AbstractReactiveServer` and `NioReactor` (`core-http/src/main/java/io/activej/http/HttpServer.java:68`, `core-net/src/main/java/io/activej/net/AbstractReactiveServer.java:64`).
- Active connection lifecycle is explicitly modeled as four intrusive lists: `poolNew`, `poolReadWrite`, `poolServing`, `poolKeepAlive` (`HttpServer.java:68-71`).
- Expiration is a recurring reactor task (1s cadence) that closes timed-out connections by pool (`HttpServer.java:318-342`).
- Accept path:
  - `listen()` binds server sockets (`AbstractReactiveServer.java:229`, `:250-254`).
  - `doAccept` applies accept filter, chooses worker, and dispatches to worker reactor when needed (`AbstractReactiveServer.java:311-341`).
- Reactor loop model is explicit single-thread event loop with select + task phases (`core-eventloop/src/main/java/io/activej/eventloop/Eventloop.java:442-505`).
- Cross-thread handoff into a reactor uses `execute()` (MPSC queue + `selector.wakeup()`) (`Eventloop.java:986-990`).

## 2) Request parse/routing pipeline and optimizations

- Parse entry is `HttpServerConnection.readMessage()`; supports pipelined continue-read when body in/out completed and keep-alive active (`core-http/src/main/java/io/activej/http/HttpServerConnection.java:144-163`).
- Start-line parsing is byte-scan to LF without regex/tokenizers (`AbstractHttpConnection.java:256-276`).
- Header parsing is a manual state machine:
  - fast path scans LF and parses header directly (`AbstractHttpConnection.java:278-331`);
  - multiline header handling via `scanHeader` (`AbstractHttpConnection.java:333-373`);
  - header name hashing is case-folded byte loop before token lookup (`AbstractHttpConnection.java:375-409`).
- HTTP method parsing is optimized:
  - hardcoded fast checks for `GET` and `POST`;
  - fallback to static open-addressed `METHODS` hash table with startup collision assert (`HttpServerConnection.java:64-78`, `:271-305`).
- URL parsing is byte-level:
  - parser avoids regex and stores query key bounds in packed `int` positions (`UrlParser.java:372-406`);
  - router consumption uses incremental `pollUrlPart()` (`UrlParser.java:469`);
  - percent decode uses thread-local scratch buffer (`UrlParser.java:65`, `:551-556`).
- Routing is trie-like recursive traversal:
  - static segment map `routes`, param branches, fallback table by method/protocol ordinal (`RoutingServlet.java:55-63`, `:167-207`).

## 3) Response write/backpressure strategy

- Response selection:
  - try render headers+body into one buffer (`renderHttpResponse`) (`HttpServerConnection.java:347-381`);
  - otherwise stream via `writeHttpMessageAsStream` (`HttpServerConnection.java:343`, `AbstractHttpConnection.java:549-574`).
- Stream path applies transforms only as needed:
  - gzip transform for body stream;
  - chunked encoder when content length absent (`AbstractHttpConnection.java:555-567`).
- Write completion semantics:
  - `writeBuf()` writes then calls `onBodySent` on success (`AbstractHttpConnection.java:576-586`);
  - stream writes push each chunk through async consumer backed by socket writes (`AbstractHttpConnection.java:588-594`).
- Socket-level backpressure:
  - `ITcpSocket.write` contract: multiple write promises may co-complete when a later write succeeds (`core-net/src/main/java/io/activej/net/socket/tcp/ITcpSocket.java:51-58`).
  - `TcpSocket.doWrite` handles partial kernel writes; if unread bytes remain, it returns and relies on OP_WRITE readiness (`core-net/src/main/java/io/activej/net/socket/tcp/TcpSocket.java:518-541`).
- Keep-alive reuse:
  - after request/response complete, connection returns to keep-alive pool and immediately re-reads if socket already has data (`HttpServerConnection.java:505-521`).

## 4) Memory/allocation optimizations

- `ByteBufPool` is slab-based (power-of-two) with optional min/max bypass for out-of-policy sizes (`core-bytebuf/src/main/java/io/activej/bytebuf/ByteBufPool.java:38-48`, `:214-223`).
- Buffer growth avoids unnecessary allocations via `ensureWriteRemaining`, copying only when required (`ByteBufPool.java:341-351`).
- Append fast-path recycles empty destination and reuses source (`ByteBufPool.java:367-377`).
- Pool watchdog can evict retained entries to cap overgrowth (`ByteBufPool.java:90-92`, `:631-653`).
- `ByteBuf` supports refcounted slices, reducing copy pressure (`core-bytebuf/src/main/java/io/activej/bytebuf/ByteBuf.java:229-249`).
- Header storage is compact open-addressed `Object[] kvPairs` (`core-http/src/main/java/io/activej/http/HttpHeadersMultimap.java:32`, `:49-63`, `:79-88`).
- Header writing is direct array emission with pre-estimated size (`core-http/src/main/java/io/activej/http/HttpMessage.java:482-519`).
- Known headers/tokens are pre-registered in case-insensitive token maps (avoids repeated string allocations/parsing) (`core-http/src/main/java/io/activej/http/HttpHeaders.java:30-34`, `CaseInsensitiveTokenMap.java:63-69`, `:112-139`).

## 5) Concurrency and scaling model

- Base model: one reactor thread owns each connection/socket state.
- Horizontal scale in-process uses primary/worker split:
  - `PrimaryServer` accepts and round-robins workers (`core-net/src/main/java/io/activej/net/PrimaryServer.java:34`, `:72-75`).
  - cross-reactor dispatch done with `workerServerReactor.execute(...)` (`AbstractReactiveServer.java:340`).
- Worker creation is DI-scoped:
  - worker pools create per-worker scoped injectors;
  - worker id injected via `@WorkerId` cache (`boot-workers/src/main/java/io/activej/worker/WorkerPool.java:72-84`, `WorkerPoolModule.java:49-59`).
- Canonical wiring is shown in `MultithreadedHttpServerLauncher` (`launchers/http/src/main/java/io/activej/launchers/http/MultithreadedHttpServerLauncher.java:72-98`).

## 6) Notable implementation techniques with code pointers

- Intrusive connection lists + ordered timeout close:
  - `closeExpiredConnections` stops scanning when timestamp is newer than expiration (ordered-by-activity assumption) (`core-http/src/main/java/io/activej/http/ConnectionsLinkedList.java:66-80`).
- Mixed inline/stream body strategy in request parser:
  - in-memory body fast path when full body already in read buffer and not gzipped;
  - otherwise switch to streaming decode pipeline (`AbstractHttpConnection.java:424-439`, `:449-505`).
- Body-stream sanitization to propagate close exceptions consistently (`AbstractHttpConnection.java:669-692`).
- WebSocket upgrade path binds frame encoder/decoder around raw channel streams and emits protocol headers only on `101` (`core-http/src/main/java/io/activej/http/WebSocketServlet.java:68-107`).
- RFC handshake key is computed as SHA-1 over key+magic and base64-encoded (`core-http/src/main/java/io/activej/http/HttpUtils.java:391-396`).
- Malformed pipelined behavior is regression-tested (normal response may precede `400` + close when second request is malformed) (`core-http/src/test/java/io/activej/http/HttpServerTest.java:748-786`).

## 7) Transferable learnings for nim_express/nim_usockets

### P0 (highest impact)

1. Adopt explicit connection-state pools (`new/readwrite/serving/keepalive`) with timestamped intrusive lists for O(expired-prefix) timeout cleanup.
2. Keep request parser strictly byte-oriented with fast-path branches for common methods and start-line/header scans (no regex, no split/tokenize).
3. Preserve dual write path:
   - single-buffer render for known-length responses;
   - stream path with late chunked/gzip insertion only when required.

### P1

1. Pre-register common headers/methods into compact token tables keyed by case-insensitive hash.
2. Add thread-local decode scratch buffers for URL decode/query parse to reduce transient allocations.
3. Build strong malformed-pipeline tests (first malformed, second malformed, split writes/random chunking) as protocol safety guardrails.

### P2

1. Consider worker DI-style composition pattern (or equivalent factory scoping) for clean multi-reactor bootstrapping.
2. Add allocator watchdog/telemetry for buffer-pool slabs to detect retention drift under real traffic.
3. Expose fine-grained inspector hooks (parse errors, servlet exceptions, write stalls) for production diagnosis.

## 8) Risks/tradeoffs if adopted

- More manual parser/state-machine code increases complexity and maintenance burden; correctness requires strong fuzz/regression coverage.
- Intrusive list lifecycle is fast but error-prone if pool transitions are missed; can cause leaks/timeouts not firing.
- Slab pooling improves throughput but can raise memory footprint under bursty traffic if eviction policy is weak.
- Event-loop ownership model reduces lock contention but pushes strict non-blocking discipline into all app/middleware code.
- Multi-reactor handoff improves scaling but introduces cross-reactor queueing latency and additional operational tuning (worker count, affinity, overload control).

## Brief completion summary

Completed a deep implementation analysis of ActiveJ HTTP/net/eventloop/bytebuf/worker modules and wrote this report with concrete file/line pointers, prioritized transfer items (P0/P1/P2), and adoption risks targeted to `nim_express`/`nim_usockets`.
