# Ohkami Tokio Analysis

Scope:
- Target: `https://github.com/ohkami-rs/ohkami`
- Clone mode: shallow (`--depth 1`)
- Local path: `/analysis/tmp/ohkami`
- Analyzed revision: `809d9de`
- Focus: native runtime path, especially `rt_tokio`

## Architecture and execution model

Ohkami is runtime-flexible at compile-time and runtime-specific at build output. Runtime features (including `rt_tokio`) are selected in `ohkami/Cargo.toml:58-99`, and one runtime is enforced (`ohkami/src/lib.rs:100-109`).

For native runtimes, `__rt__` abstracts:
- socket types and `accept` (`ohkami/src/lib.rs:112-165`)
- binding conversion (`IntoTcpListener`) (`ohkami/src/lib.rs:167-184`)
- task spawning (`ohkami/src/lib.rs:201-227`)

Startup for native mode is `Ohkami::howl_core` (`ohkami/src/ohkami/mod.rs:510-565`):
1. Build and finalize router once (`into_router().finalize()`).
2. Wrap finalized router in `Arc`.
3. Accept loop.
4. Spawn one async session per accepted connection.
5. Graceful shutdown on Ctrl-C + wait for active sessions.

The request/response execution model is:
- one connection -> one `Session`
- one session loops through keep-alive requests
- each request invokes `router.handle(req).await`
- response is sent and loop continues unless close/upgrade/error (`ohkami/src/session/mod.rs:36-126`)

## Request parse/routing pipeline and optimizations

### Request read path

`Session::manage` reuses a single `Request` object per connection:
- allocate once: `Request::uninit(...)` (`ohkami/src/session/mod.rs:64`)
- clear/reuse each iteration: `req.clear()` (`ohkami/src/session/mod.rs:67`, `ohkami/src/request/mod.rs:239-253`)

Read timeout is applied per request read (resets on activity) using `with_timeout` (`ohkami/src/session/mod.rs:69-73`, `ohkami/src/util.rs:178-211`).

Parser characteristics in `Request::read` (`ohkami/src/request/mod.rs:256-347`):
- single `read` into fixed request buffer (`:263`)
- method parsed by byte matching (`Method::from_bytes`) (`ohkami/src/request/mod.rs:285-288`, `ohkami/src/request/method.rs:13-22`)
- path and query parsed in one pass from request-line (`ohkami/src/request/mod.rs:292-297`)
- strict `HTTP/1.1\r\n` check (`ohkami/src/request/mod.rs:300-301`)
- header loop until CRLF CRLF (`ohkami/src/request/mod.rs:303-340`)
- standard header fast path via enum mapping, custom headers separate (`ohkami/src/request/mod.rs:334-339`, `ohkami/src/request/headers.rs:1-7,147`)

Payload strategy:
- validates content-length and method semantics (`ohkami/src/request/mod.rs:177-207`)
- payload materialization has 3 cases (`ohkami/src/request/mod.rs:352-397`):
1. no remaining bytes in buffer -> read exact to owned buffer
2. payload fully in remaining buffer -> borrowed ref
3. payload split -> copy remaining + read rest to owned buffer

Path normalization and params:
- trailing slash stripped (including `/` -> empty internal) (`ohkami/src/request/path.rs:138-150`)
- param capture storage is fixed-size `Params::LIMIT = 2` (`ohkami/src/request/path.rs:9-15,103-121`)

### Router path

Router build/finalization:
- route trees per method in base router
- finalize validates handler path-param requirements (`ohkami/src/router/base.rs:214-240`)
- final router materializes optimized node structure (`ohkami/src/router/final.rs:264-339`)

Runtime route lookup:
- method dispatch is match-based (`ohkami/src/router/final.rs:35-44`)
- `HEAD` uses GET route and strips content (`ohkami/src/router/final.rs:45-52`)
- tree walk via `search_target` + `Pattern::take_through` on byte slices (`ohkami/src/router/final.rs:157-224,232-258`)

Router optimizations in finalize (`ohkami/src/router/final.rs:277-335`):
- compress chains of single static-child nodes (native only) (`:280-295`)
- sort children: static first (reverse lexical), param last (`:297-305`)
- leak finalized children and owned static segments to `'static` for lookup (`:317,334`)

## Response write/backpressure strategy

Response send path is in `Response::send` (`ohkami/src/response/mod.rs:333-423`):
- `Content::None` and `Content::Payload`:
  - precompute exact capacity
  - serialize status + headers (+ payload) into one buffer
  - one `write_all` then `flush` (`:338-363`)
- SSE `Content::Stream`:
  - send headers first
  - per event: format SSE lines, wrap as chunked encoding frame, `write_all` + `flush` (`:367-404`)
- WebSocket upgrade:
  - write handshake bytes, flush, return upgrade state (`:410-420`)

Backpressure behavior:
- relies on async writer await (`write_all(...).await`) to apply sink pressure naturally.
- no explicit watermarks, output queue limits, or batched coalescing beyond per-response buffer assembly.
- explicit `flush` is used after each response and each SSE chunk.

HTTP consistency fixups:
- `Response::complete` strips body/content-length for `204`, SSE, and WS cases (`ohkami/src/response/mod.rs:133-157`).

## Memory/allocation optimizations

Notable allocation behavior:
- request buffer is boxed and reused per connection (`ohkami/src/request/mod.rs:96,221-223,239-253`)
- parsing primarily uses borrowed slices (`Slice`, `CowSlice`) (`ohkami_lib/src/slice.rs:5-33,73-87`)
- headers separate standard/custom storage:
  - standard: byte-indexed map (`ByteArrayMap`) (`ohkami/src/header/map.rs:5-20`)
  - custom: tiny vector map (`TupleMap`) (`ohkami_lib/src/map.rs:1-6`)
- response headers track serialized size incrementally to avoid recounting (`ohkami/src/response/headers.rs:13,329-339,392-413`)
- header serialization uses unchecked append macro + direct copies (`ohkami/src/response/headers.rs:499-527`, `ohkami/src/util.rs:49-54`)
- default response headers initialized once with Date + Content-Length (`ohkami/src/response/headers.rs:451-463`)

Container/algorithm choices:
- `ByteArrayMap` uses `[u8; N]` indices + compact entries vec, swap-remove delete with index fixup (`ohkami/src/header/map.rs:5-11,49-68`)
- `TupleMap` intentionally favors small cardinality workloads over hash map overhead (`ohkami_lib/src/map.rs:1-6`)

## Concurrency and scaling model

Per-process concurrency model:
- one accept loop
- spawn one async task per connection (`ohkami/src/ohkami/mod.rs:530-558`)
- per connection keep-alive request loop (`ohkami/src/session/mod.rs:66-126`)

Tokio-specific behavior:
- `rt_tokio` enables threaded runtime traits and tokio IO (`ohkami/Cargo.toml:58-61`)
- task spawning delegates to `tokio::task::spawn` (`ohkami/src/lib.rs:212-215`)
- task type bounds differ by threaded vs non-threaded runtime (`ohkami/src/lib.rs:201-210`)

Shutdown model:
- custom `CtrlC` future gates accept/handshake loops (`ohkami/src/ohkami/mod.rs:524,530,538-541,1018+`)
- custom `WaitGroup` tracks active sessions and await completion on shutdown (`ohkami/src/ohkami/mod.rs:524,553-565,961-1015`)

Scaling observation:
- no built-in multi-process orchestration in this crate path; horizontal scaling is expected via runtime/process orchestration outside framework code.

## Notable implementation techniques with code pointers

1. Runtime abstraction without virtual dispatch hot-path:
- `__rt__` module aliases concrete types/functions by cfg (`ohkami/src/lib.rs:112-227`).

2. One-time router lowering + immutable runtime tree:
- `base::Router::finalize` to final tree with method partitioning (`ohkami/src/router/base.rs:214-240`, `ohkami/src/router/final.rs:264-274`).

3. Static-chain compression in route tree:
- merge intermediate static nodes during finalize (`ohkami/src/router/final.rs:280-295`).

4. Deterministic child ordering to simplify branch checks:
- static before param (`ohkami/src/router/final.rs:297-305`).

5. Low-level segment splitting:
- pointer-based `split_next_section` avoids iterator overhead (`ohkami/src/router/util.rs:3-17`).

6. Request object reuse + contextual clear:
- `req.clear` and no per-request object allocation under keep-alive (`ohkami/src/session/mod.rs:64-67`, `ohkami/src/request/mod.rs:239-253`).

7. Fast path header map representation:
- `ByteArrayMap` + `TupleMap` split (`ohkami/src/header/map.rs:5-11`, `ohkami_lib/src/map.rs:1-6`).

8. Pre-sized write buffer + unchecked push:
- `Response::send` capacity sizing (`ohkami/src/response/mod.rs:339-354`)
- `push_unchecked!` macro (`ohkami/src/util.rs:49-54`).

9. Controlled invariants via unsafe + debug asserts:
- param push bound assert only in debug (`ohkami/src/request/path.rs:113-121`)
- many unchecked indexing calls in parser/router/headers.

10. Compile-time request extractor arity expansion:
- generated `IntoHandler` impls for multiple argument counts (`ohkami/src/fang/handler/into_handler.rs:9+`).

## Transferable learnings for nim_express/nim_usockets (P0/P1/P2)

P0 (high impact / low-medium risk):
1. Single-write response assembly for non-streaming responses.
- Build status+headers+body in one pre-sized buffer and issue one socket write.
- Mirrors `Response::send` fast path (`ohkami/src/response/mod.rs:338-363`).

2. Reuse request parse buffers per connection.
- Keep one request object/buffer per live socket; reset fields per request.
- Mirrors `Session::manage` + `Request::clear` (`ohkami/src/session/mod.rs:64-67`, `ohkami/src/request/mod.rs:239-253`).

3. Finalize route tree once, then only immutable runtime lookups.
- Precompute router artifacts at startup and avoid mutation in hot path.
- Mirrors `finalize` pipeline (`ohkami/src/router/base.rs:214-240`).

P1 (moderate impact / moderate complexity):
1. Specialized map for known standard headers + tiny map for custom headers.
- Equivalent of `ByteArrayMap` + `TupleMap` split.
- Helps avoid hashmap overhead for common headers.

2. Route tree child ordering and static-chain compression.
- Reduces comparisons and branch ambiguity in path matching.
- Mirrors `router/final.rs:280-305`.

3. Header byte-size accounting during mutations.
- Maintain serialized size incrementally; avoid recomputing during write.
- Mirrors `response/headers.rs:329-339,392-413`.

P2 (selective / higher complexity or tighter constraints):
1. Aggressive unchecked writes/indexing in core paths.
- Potential gains, but requires strict invariant discipline and fuzz coverage.

2. Fixed small param storage in request path object.
- Useful only if your API shape strongly fits low param counts.
- Current Ohkami limit is 2 (`request/path.rs:14`), which is a hard behavioral constraint.

3. Intentional `'static` leaking of finalized router internals.
- acceptable for process-lifetime singleton servers; less suitable if frequent dynamic reconfiguration is needed.

## Risks/tradeoffs if adopted

1. Safety risk from unchecked indexing/memory ops.
- Many hot-path optimizations depend on unsafe invariants (`request/mod.rs`, `router/final.rs`, `response/headers.rs`, `util.rs`).
- Requires stronger invariant tests, parser fuzzing, and sanitizer runs.

2. Behavior constraints from performance shortcuts.
- fixed path param limit (2) can be incompatible with broader routing needs (`request/path.rs:14`).
- strict HTTP/1.1 request-line expectations may reject some proxy/client variants (`request/mod.rs:118,300-301`).

3. Backpressure and flush policy tradeoff.
- `write_all + flush` after each response/SSE chunk is simple and correct but can add syscall overhead at high rates (`response/mod.rs:345-346,360-361,400-404`).

4. Lifecycle memory tradeoff.
- leaked `'static` router segments/children simplify runtime references but are intentionally non-reclaimable until process exit (`router/final.rs:317,334`).

5. Concurrency model depends on external runtime/process strategy.
- task-per-connection works well, but process-level scaling and admission control are not managed here.

## Brief completion summary

Completed a deep implementation analysis of Ohkami’s Tokio-native server path from shallow clone `809d9de`, with concrete code-level findings for architecture, parser/router internals, response write path, memory behavior, concurrency/shutdown model, and prioritized transfer recommendations (P0/P1/P2) for `nim_express`/`nim_usockets`.
