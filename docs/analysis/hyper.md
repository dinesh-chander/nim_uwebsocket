# hyper (hyperium/hyper) deep implementation analysis

Analyzed repository: `https://github.com/hyperium/hyper`  
Clone: `analysis/tmp/hyper` (shallow, `--depth 1`)  
Commit analyzed: `8ba900853b0f619b165e8530fc8c310bc13e056b` (`2026-02-17`)

## Architecture and execution model

- hyper is a low-level HTTP protocol engine, not an end-to-end server runtime: accept loops are intentionally outside the crate (`src/server/mod.rs:6`, `src/server/mod.rs:9`).
- The server API is per-connection futures (`HTTP/1` and `HTTP/2` builders under `server::conn`) and each connection future must be actively polled (`src/server/conn/mod.rs:4`, `src/server/conn/http1.rs:36`, `src/server/conn/http2.rs:26`).
- Runtime abstraction is explicit and first-class:
  - generic async IO traits (`Read`/`Write`) (`src/rt/mod.rs:20`, `src/rt/io.rs:76`)
  - executor abstraction (`src/rt/mod.rs:45`)
  - trait-bounded executors for HTTP/2 stream and upgrade tasks (`src/rt/bounds.rs:109`, `src/rt/bounds.rs:113`, `src/rt/bounds.rs:19`).
- Feature gating is used to keep binaries slim and avoid unnecessary code paths (`Cargo.toml:71`, `Cargo.toml:74`, `Cargo.toml:82`, `Cargo.toml:83`, `Cargo.toml:86`, `Cargo.toml:87`).
- Service model is "connection-bound request handler" with no built-in router abstraction (`src/service/mod.rs:17`).

## Request parse/routing pipeline and optimizations

- There is no routing subsystem in hyper itself; dispatch to application logic is via `Service::call(req)` (`src/proto/h1/dispatch.rs:564`).
- HTTP/1 parse hot path:
  - uses `httparse` with uninitialized header buffers to avoid zeroing costs (`src/proto/h1/role.rs:149`, `src/proto/h1/role.rs:167`).
  - uses `SmallVec<[MaybeUninit<_>; DEFAULT_MAX_HEADERS]>` for stack-fast default header handling (`src/proto/h1/role.rs:153`, `src/proto/h1/role.rs:159`).
  - reuses header storage across messages via `cached_headers.take().unwrap_or_default()` + `reserve()` (`src/proto/h1/role.rs:247`, `src/proto/h1/role.rs:249`).
  - avoids URI copy via `Uri::from_maybe_shared(...)` on parsed buffer slices (`src/proto/h1/role.rs:214`).
  - header indexing is done once with pointer arithmetic, then mapped to real header values (`src/proto/h1/role.rs:1542`).
- HTTP/1 dispatcher parse-to-service flow:
  - parse head (`poll_read_head`) -> build `IncomingBody` channel if needed -> pass request to dispatch (`src/proto/h1/dispatch.rs:271`, `src/proto/h1/dispatch.rs:289`, `src/proto/h1/dispatch.rs:303`).
  - server-side `recv_msg` materializes an `http::Request` and immediately calls service future (`src/proto/h1/dispatch.rs:556`, `src/proto/h1/dispatch.rs:564`).
- HTTP/2 parse/accept flow:
  - handshake once, then `poll_accept` per stream (`src/proto/h2/server.rs:124`, `src/proto/h2/server.rs:259`).
  - each accepted stream constructs request body wrapper and executes service future in an executor task (`src/proto/h2/server.rs:276`, `src/proto/h2/server.rs:313`).

## Response write/backpressure strategy

- HTTP/1 write path is buffer-and-flush with explicit strategy modes:
  - `WriteStrategy::Queue` when vectored IO is available, else `Flatten` (`src/proto/h1/io.rs:61`, `src/proto/h1/io.rs:63`).
  - write buffering bounded by `max_buf_size` and queue count (`src/proto/h1/io.rs:577`, `src/proto/h1/io.rs:579`).
  - flush path uses `poll_write_vectored` in queue mode and a specialized flattened flush in flatten mode (`src/proto/h1/io.rs:282`, `src/proto/h1/io.rs:307`).
  - dispatcher applies backpressure by forcing flush when connection cannot buffer more (`src/proto/h1/dispatch.rs:356`).
- HTTP/1 pipelining behavior can switch to `pipeline_flush` aggregation mode (`src/server/conn/http1.rs:397`, `src/server/conn/http1.rs:483`, `src/proto/h1/io.rs:33`, `src/proto/h1/io.rs:267`).
- HTTP/1 body write progression is stateful (`write_head` -> `write_body`/`write_body_and_end`/trailers -> `end_body`) and transitions keepalive/close based on encoder state (`src/proto/h1/conn.rs:594`, `src/proto/h1/conn.rs:703`, `src/proto/h1/conn.rs:753`, `src/proto/h1/conn.rs:773`).
- HTTP/2 response body path uses h2 stream flow control:
  - reserves capacity before sending (`reserve_capacity(1)`), waits on `poll_capacity`, checks resets (`poll_reset`) (`src/proto/h2/mod.rs:122`, `src/proto/h2/mod.rs:126`, `src/proto/h2/mod.rs:142`).
  - sends DATA/TRAILERS and emits EOS frame if stream ends without explicit EOS (`src/proto/h2/mod.rs:162`, `src/proto/h2/mod.rs:172`, `src/proto/h2/mod.rs:185`, `src/proto/h2/mod.rs:212`).

## Memory/allocation optimizations

- Aggressive reuse and bounded growth in HTTP/1 buffering:
  - default read/write buffer bound ~400KB (`8192 + 4096*100`) (`src/proto/h1/io.rs:23`).
  - adaptive read sizing (power-of-two growth/shrink) to match traffic profile (`src/proto/h1/io.rs:357`, `src/proto/h1/io.rs:401`, `src/proto/h1/io.rs:427`).
  - too-large protection on partial header accumulation (`src/proto/h1/io.rs:205`).
- Header parsing/storage optimizations:
  - stack-based `SmallVec` default path, configurable max headers with known heap/perf tradeoff (~5% in docs/comments) (`src/server/conn/http1.rs:327`, `src/server/conn/http1.rs:330`).
  - explicit comment documents uninitialized parsing memory saving ~5% on pipeline benchmarks (`src/proto/h1/role.rs:149`, `src/proto/h1/role.rs:152`).
- Reusable date header cache (thread-local fixed-size bytes + periodic refresh) avoids per-response formatting (`src/common/date.rs:11`, `src/common/date.rs:14`, `src/common/date.rs:44`, `src/common/date.rs:70`).
- Zero-capacity bounded channel + watch signaling for inbound body channels limits over-buffering (`src/body/incoming.rs:114`, `src/body/incoming.rs:122`, `src/body/incoming.rs:353`).

## Concurrency and scaling model

- Concurrency shape differs by protocol:
  - HTTP/1 server dispatch is effectively single in-flight request per connection (`in_flight: Option<S::Future>`, `poll_ready` waits until none) (`src/proto/h1/dispatch.rs:49`, `src/proto/h1/dispatch.rs:569`, `src/proto/h1/dispatch.rs:570`).
  - HTTP/2 accepts many streams and spawns one task per stream via executor (`src/proto/h2/server.rs:259`, `src/proto/h2/server.rs:313`).
- HTTP/2 includes stream-level scaling controls:
  - default max concurrent streams = 200 (`src/proto/h2/server.rs:68`).
  - configurable flow-control windows and adaptive window mode (`src/server/conn/http2.rs:157`, `src/server/conn/http2.rs:170`, `src/server/conn/http2.rs:183`).
- Fairness: HTTP/1 dispatcher caps loop work (16 iterations) then yields to avoid starvation (`src/proto/h1/dispatch.rs:171`, `src/proto/h1/dispatch.rs:192`).
- Server-wide scaling (listener sharding, process/thread model) is explicitly outside hyper and left to user runtime architecture (`src/server/mod.rs:6`).

## Notable implementation techniques with code pointers

- H1/H2 protocol mismatch detection in H1 parser path (H2 preface check) for clear failure mode (`src/proto/h1/conn.rs:206`, `src/proto/h1/conn.rs:810`).
- Parser configurability wired through builder into per-connection parse context (`src/server/conn/http1.rs:453`, `src/proto/h1/conn.rs:244`).
- Expect/upgrade signaling encoded as compact bitflags (`Wants`) and propagated to dispatch/body channel setup (`src/proto/h1/mod.rs:110`, `src/proto/h1/dispatch.rs:289`, `src/proto/h1/dispatch.rs:294`).
- Strict transfer-encoding/content-length handling based on RFC semantics in parse and encode branches (`src/proto/h1/role.rs:260`, `src/proto/h1/role.rs:1290`, `src/proto/h1/role.rs:1340`).
- Automatic error response generation for parse errors on server side when possible (`src/proto/h1/conn.rs:808`, `src/proto/h1/role.rs:477`).
- Lightweight custom SPSC watch channel (`AtomicUsize` + `AtomicWaker`) for body readiness signaling (`src/common/watch.rs:7`, `src/common/watch.rs:52`, `src/common/watch.rs:66`).

## Transferable learnings for nim_express/nim_usockets (P0/P1/P2)

### P0 (high impact, low-moderate risk)

- Split protocol engine from framework:
  - keep transport/protocol state machine in `nim_usockets`; keep route/middleware policy in `nim_express`.
  - hyper's separation (`server::conn` + service boundary) is a strong template (`src/server/mod.rs:6`, `src/service/mod.rs:17`).
- Implement explicit backpressure at body send boundary:
  - do not keep accepting body chunks when socket/output buffers are saturated.
  - mirror hyper's "can_buffer -> flush -> continue" control points (`src/proto/h1/dispatch.rs:356`, `src/proto/h1/io.rs:577`).
- Add strict, centralized TE/CL semantics and malformed-header handling:
  - parse correctness here directly prevents request smuggling and protocol ambiguity (`src/proto/h1/role.rs:260`, `src/proto/h1/role.rs:1290`).

### P1 (important, moderate implementation effort)

- Reuse per-connection header maps/buffers instead of allocate-per-request (`src/proto/h1/role.rs:247`).
- Introduce adaptive read-buffer sizing with hard cap and explicit "too large" close behavior (`src/proto/h1/io.rs:357`, `src/proto/h1/io.rs:205`).
- Add fairness guard in per-connection loops (bounded work then yield) to avoid hot-connection starvation (`src/proto/h1/dispatch.rs:171`, `src/proto/h1/dispatch.rs:192`).
- Add cached Date header rendering with second-level refresh if you keep emitting Date (`src/common/date.rs:44`, `src/common/date.rs:70`).

### P2 (situational or higher complexity)

- Dual write strategies (flatten vs queue/writev) selected by transport capability (`src/proto/h1/io.rs:61`, `src/proto/h1/io.rs:282`).
- HTTP/2 adaptive window and ping-based tuning ideas if you expand h2 support deeply (`src/proto/h2/server.rs:150`, `src/proto/h2/server.rs:345`).
- Upgrade plumbing that cleanly hands off raw transport + buffered bytes (`src/server/conn/http1.rs:191`, `src/server/conn/http1.rs:538`).

## Risks/tradeoffs if adopted

- Complexity risk: these gains rely on tight state machines and subtle transition logic; introducing partial copies without full state model can regress correctness.
- Allocation/perf tradeoff risk: some knobs improve compatibility but reduce throughput (e.g., higher dynamic max header counts causing heap allocation, explicitly noted by hyper) (`src/server/conn/http1.rs:327`).
- Backpressure behavior changes can alter latency profiles:
  - aggressive flushing reduces memory but can lower pipelined throughput.
  - aggressive buffering raises throughput but increases tail latency/memory under slow clients.
- Runtime abstraction cost:
  - portability improves, but generic trait layers make debugging and profiling harder compared to a single concretely typed runtime stack.
- HTTP/2 model mismatch risk:
  - per-stream task spawn model scales well for multiplexing but can amplify scheduler overhead and memory footprint if not bounded carefully.
