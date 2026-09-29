# khttp Deep Implementation Analysis

Analyzed repository: `https://github.com/karlivory/khttp`  
Analyzed revision: `7cf8eed` (shallow clone, `--depth 1`)

## Architecture and execution model

`khttp` is a synchronous HTTP/1.1 library with:
- server core (`src/server/*`)
- hand-rolled parser (`src/parser/*`)
- response/request printer (`src/printer.rs`)
- lightweight router (`src/router.rs`)
- body framing reader (`src/body_reader.rs`)
- optional client (`src/client.rs`, behind `client` feature)

Execution model is connection-oriented:
1. Accept TCP socket.
2. Read + parse request head into borrowed structures.
3. Route by method/path.
4. Expose body as a streaming `Read`/`BufRead`.
5. Handler writes response via `ResponseHandle`.
6. Keep connection alive unless client requested `connection: close` or server sent close.

Core loop is in `src/server/mod.rs`:
- `serve()` uses fixed thread pool; each job handles an entire connection (including keep-alive loop).
- `handle_connection()` repeatedly runs `handle_one_request()`.
- `handle_one_request()` reads/parses request, runs optional pre-routing hook, routes, builds `RequestContext`, invokes handler, decides keep-alive.

## Request parse/routing pipeline and optimizations

### Request head ingestion
- `read_request()` (`src/server/mod.rs`) uses a thread-local `Vec<MaybeUninit<u8>>` (`REQUEST_BUFFER`) and incremental reads.
- It repeatedly calls `Request::parse()` on the initialized prefix; `UnexpectedEof` means “need more bytes”.
- Hard cap via `max_request_head_size`; overflow returns 431.

### Parser details
- `Request::parse()` (`src/parser/request.rs`) parses method, URI, version, CRLF, headers, and returns `buf_offset` to body start.
- Method parse fast-paths `GET` and `POST` by prefix match, then falls back to scan (`parse_method`).
- URI parse supports:
  - origin-form (`/path`)
  - absolute-form (`http://host/path`)
  - authority-form (`host:port`)
  - asterisk-form (`*`)
  via `parse_uri`.
- URI/path scanning uses SWAR helpers (`src/parser/simd.rs`):
  - `match_path_vectored` scans until `?` or space.
  - `match_uri_vectored` bulk-validates URI byte class.
- Header parsing (`src/parser/mod.rs`) uses `memchr` for newline, a precomputed token-byte mask for header names, and borrowed slices for values.

### Routing pipeline
- `handle_one_request()` runs optional pre-routing hook before route dispatch (`src/server/mod.rs`).
- Router design (`src/router.rs`):
  - per-method buckets for standard methods (`[MethodBucket; 8]`), plus hashmap for custom methods.
  - exact literal routes are sorted at build time and binary-searched (`find_literal`).
  - non-literal patterns (`:param`, `*`, `**`) are linearly scanned.
  - winner selection is “longest matching literal prefix” first, then segment precedence (`literal > param > * > **` for tie-break via `last_prec`).
- Params are collected in `RouteParams` as borrowed `(key, value)` pairs.

## Response write/backpressure strategy

### Write strategy
- `ResponseHandle` delegates to `HttpPrinter` (`src/server/mod.rs`, `src/printer.rs`).
- `HttpPrinter::decide_body_strategy()` chooses:
  - `Fast(Vec<u8>, cl)` for small/known bodies
  - `Streaming(reader, cl)` for known large CL bodies
  - `Chunked { reader }` if TE chunked already requested
  - `AutoChunked { prefix, reader }` when CL unknown and probe not complete
- Probe threshold is `PROBE_MAX = 8 KiB`; if body ends within probe, it emits `content-length`, else auto-chunked.

### Write-path optimizations
- Small response optimization (`INLINE_COPY_MAX = 2 KiB`): copy body into header buffer then single `write_all`.
- Larger response path uses `write_vectored` with `[head, body]`, then fallbacks for partial writes.
- Chunked streaming uses large stack buffer (`[MaybeUninit<u8>; 128*1024]`) and writes `<hex>\r\nchunk\r\n`.
- Status code formatting uses custom integer-to-ascii helpers (`u16_to_ascii`, `u64_to_ascii_buf`) to avoid formatting overhead.

### Backpressure behavior
- No explicit asynchronous backpressure state machine.
- Uses blocking socket writes (`write_all`, `write_vectored` fallback loops); slow clients can stall worker threads.
- In epoll mode, request handling still occurs in worker threads with blocking request read/write behavior; epoll mostly multiplexes readiness/dispatch.

## Memory/allocation optimizations

- Thread-local uninitialized request buffer reused per thread (`src/server/mod.rs`).
- Parser and request model borrow from request buffer (`Request<'b>`, `RequestUri<'b>`, header values) to avoid copying.
- `Headers` caches parsed flags (`content_length`, `chunked`, `connection_close`) for O(1) checks during hot path (`src/http/headers.rs`).
- Static/lazy empty headers variants reduce repeated allocations for common cases (`Headers::empty`, `empty_nodate`, `close`).
- Date header generation uses thread-local second-granularity cache (`src/date.rs`), avoiding full recompute per response.
- Router literal table sorted once at build time; runtime exact-match uses binary search.
- Route param temporary vectors are reused inside route matching loop with `clear`/`mem::swap`.
- Body probing uses `spare_capacity_mut` + manual `set_len` to reduce repeated zeroing and intermediate copies (`src/printer.rs`).

## Concurrency and scaling model

### `serve()` (default)
- Listener thread accepts and enqueues to fixed `ThreadPool` (`src/threadpool.rs`).
- Worker job owns one TCP stream and processes keep-alive requests serially for that connection.
- Thread count default: `max(10, available_parallelism * 2)` (`src/server/builder.rs`).

### `serve_threaded()`
- Spawns one OS thread per accepted connection (`src/server/mod.rs`).
- Simple model, but unbounded thread growth risk under high connection counts.

### `serve_epoll()` (feature `epoll`, Linux 64-bit only)
- Single epoll loop (`src/server/epoll.rs`) plus worker thread pool.
- Listener is nonblocking, edge-triggered accept drain.
- Each connection has aligned `Handle` with:
  - `in_flight: AtomicBool` to ensure at most one worker active per connection
  - raw pointers to boxed stream/handle for epoll token use
  - `closed: AtomicBool` and deferred stale pointer cleanup
- Improves readiness multiplexing and reduces accept overhead vs pure accept+thread.

## Notable implementation techniques with code pointers

- Thread-local uninitialized request head buffer with incremental parse retries: `src/server/mod.rs` (`REQUEST_BUFFER`, `read_request`).
- Parsing-as-you-read using `UnexpectedEof` as continuation signal: `src/server/mod.rs`, `src/parser/request.rs`.
- SWAR URI/path scan adapted from `httparse`: `src/parser/simd.rs`.
- Header-name token validation via compile-time byte mask table: `src/parser/mod.rs` (`HEADER_FIELD_BYTE_MASK`).
- Exact route fast path via sorted literal vector + binary search: `src/router.rs` (`MethodBucket::finalize`, `find_literal`).
- Match quality score using LML + precedence, not insertion order alone: `src/router.rs` (`match_route`).
- Drain request body on `BodyReader` drop to preserve connection reuse semantics: `src/body_reader.rs` (`Drop for BodyReader`).
- Body strategy auto-selection (CL/stream/chunked/auto-chunked): `src/printer.rs` (`decide_body_strategy`).
- Small-body inline copy cutoff and vectored write fallback: `src/printer.rs` (`write_vectored_bytes`).
- Per-thread date header cache with coarse clock preference on Linux: `src/date.rs` (`get_date_now`, `now_unix_sec`).
- Epoll handle gating to avoid concurrent processing of same keep-alive socket: `src/server/epoll.rs` (`in_flight` CAS).

## Transferable learnings for `nim_express` / `nim_usockets`

### P0 (high-impact, low-to-medium risk)

1. Reusable per-thread request-head buffer + incremental parse loop  
   Relevance: reduce per-request allocations in parse hot path.  
   Reference: `src/server/mod.rs` (`read_request` + TLS `REQUEST_BUFFER`).

2. Small-body response fast path with single-buffer write; large-body vectored write  
   Relevance: lower syscall count and copies for common tiny JSON/text responses.  
   Reference: `src/printer.rs` (`INLINE_COPY_MAX`, `write_vectored_bytes`).

3. Drain-on-drop request body to keep keep-alive correctness simple  
   Relevance: prevents protocol desync when handlers stop reading body early.  
   Reference: `src/body_reader.rs` (`Drop` + `drain`).

4. Header metadata caching (`content-length`, `chunked`, `connection_close`)  
   Relevance: avoids repeated token scans throughout request/response lifecycle.  
   Reference: `src/http/headers.rs`.

### P1 (medium impact or integration effort)

1. Router split: exact literals in sorted table + dynamic patterns fallback  
   Relevance: very fast exact route dispatch while retaining params/wildcards.  
   Reference: `src/router.rs`.

2. Auto framing strategy (probe unknown body; emit CL if complete else chunked)  
   Relevance: ergonomic API without forcing caller-provided length.  
   Reference: `src/printer.rs` (`probe_body`, `AutoChunked`).

3. Thread-local date header cache  
   Relevance: cheap repeated Date header generation under high RPS.  
   Reference: `src/date.rs`.

### P2 (specialized / careful benchmarking needed)

1. SWAR scanners for URI/path delimiter finding and validity screening  
   Relevance: parser micro-optimization; benefit depends on existing Nim parser costs.  
   Reference: `src/parser/simd.rs`.

2. LML + precedence route scoring heuristic  
   Relevance: deterministic conflict resolution for wildcard/param overlaps.  
   Reference: `src/router.rs` (`match_route`).

3. Epoll token-to-handle model with in-flight CAS  
   Relevance: useful in custom poll loops; less relevant if uSockets already provides mature eventing semantics.  
   Reference: `src/server/epoll.rs`.

## Risks/tradeoffs if adopted

1. Blocking I/O semantics can stall worker capacity on slow clients  
   Locations: `src/server/mod.rs`, `src/printer.rs`.  
   Impact: throughput collapse under many slow readers/writers unless timeouts/load shedding are strict.

2. Epoll mode still performs blocking reads inside worker job  
   Location: `src/server/epoll.rs` + shared `handle_one_request` path.  
   Impact: readiness demux helps accept/dispatch, but per-request worker blocking remains.

3. Dynamic route matching is O(number_of_pattern_routes) per request  
   Location: `src/router.rs` pattern scan loop.  
   Impact: large wildcard/param route tables can degrade latency tails.

4. Parser permissiveness/quirks need careful RFC/security review  
   Example: non-CRLF header lines are skipped while scanning (`parse_headers` in `src/parser/mod.rs`).  
   Impact: potential ambiguity/proxy mismatch if strict RFC compliance is required.

5. Manual unsafe memory handling increases audit burden  
   Locations: request read buffer, probe/read uninit slices, chunk write buffers (`src/server/mod.rs`, `src/printer.rs`).  
   Impact: high performance, but harder maintenance and potential UB risk if modified incorrectly.

6. Body chunk parser uses `read_line`/`String` for size/trailer parsing  
   Location: `src/body_reader.rs`.  
   Impact: acceptable simplicity; not the lowest-allocation possible for pathological chunk-heavy traffic.

7. No built-in request rate limiting or backpressure queue management  
   Location: server core design (`src/server/mod.rs`, `src/threadpool.rs`).  
   Impact: application/hooks must enforce limits.
