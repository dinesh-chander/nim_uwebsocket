# Bun HTTP Core Analysis

Analyzed against Bun `main` at commit `923690e923b2f13e0815e8cf342748082058bede` (pulled locally into `analysis/tmp/bun` on 2026-03-20).

## Executive summary

Bun is fast because it does not spend much time in the usual slow places:

1. It does not implement the hot socket/HTTP path in JavaScript.
2. It does not allocate much on the common request path.
3. It does not rebuild dynamic JS object shapes every request.
4. It does not eagerly copy request state unless the request truly goes async.
5. It treats backpressure, corking, and `sendfile` as first-class transport concerns.

The biggest architectural point is this:

- Bun HTTP is not "fast because Zig" in isolation.
- Bun’s server path is a composition of `uWebSockets` / `uSockets` for the actual transport + parser, Zig for orchestration/runtime glue, and JavaScriptCore-aware data structures to keep the JS boundary cheap.

So the speed story is really:

- native evented networking,
- specialized request lifecycle management,
- JIT-friendly JS object behavior,
- minimized copies and allocations,
- disciplined write-path/backpressure handling.

## What the code shows

### 1. `Bun.serve()` chooses specialized server types up front

Entry point:

- `src/bun.js/api/BunObject.zig:998`

At startup Bun parses config once, then selects one of four compile-time server variants:

- HTTP vs HTTPS
- development vs production

That avoids pushing many mode checks into the hot path. The server implementation itself is generated through `NewServer(...)`:

- `src/bun.js/api/server.zig`

This is a recurring Bun pattern: move branching to setup time, keep steady-state request handling monomorphic.

### 2. The real HTTP engine is already native and event-driven

The server is built on `uWS.NewApp(...)` and uWS response/request types rather than a JS-level socket stack:

- `src/bun.js/api/server/RequestContext.zig:23`
- `src/bun.js/api/server.zig`

That matters more than the language choice. Bun inherits a very efficient parser/event-loop/write model from uWebSockets/uSockets, then tries hard not to ruin it in the JS bridge.

### 3. Request contexts are pooled aggressively

Request context pooling:

- `src/bun.js/api/server/RequestContext.zig:26`
- `src/bun.js/api/server/RequestContext.zig:31`
- `src/bun.js/api/server.zig:1675`

Bun uses a thread-local `HiveArray` pool of up to 2048 `RequestContext` objects. This removes allocator churn for one of the hottest structures in the server.

Why this matters:

- request structs are reused instead of malloc/free on every request
- allocator lookups are minimized
- hot state stays in a predictable layout

This is one of the clearest "framework speed" optimizations in the codebase.

### 4. Route dispatch is optimized for JSCore, not just for lookup

User route setup:

- `src/bun.js/api/server.zig:2478`

Route callback storage and params-object generation:

- `src/bun.js/bindings/ServerRouteList.cpp:19`
- `src/bun.js/bindings/ServerRouteList.cpp:175`
- `src/bun.js/bindings/ServerRouteList.cpp:201`
- `src/bun.js/bindings/ServerRouteList.cpp:215`

Important details:

- callbacks are stored in `FixedVector<WriteBarrier<JSCell>>`, not generic JS arrays or lots of `Strong` handles
- route param names are parsed once during route-list creation
- params object `Structure` is cached per route
- param decoding uses `decodeURIComponentSIMD`

Why this is fast:

- less GC bookkeeping overhead
- stable JS object shapes help JSC optimize property access
- route params become predictable objects instead of ad hoc dictionaries
- parameter decoding is optimized in native code

This is a very Bun-specific optimization style: it is not just "fast hash map lookup", it is "make the JS engine see the same shapes repeatedly".

### 5. Bun avoids copying request data until async transition is necessary

Sync path to async transition:

- `src/bun.js/api/server.zig:2046`
- `src/bun.js/api/server.zig:2088`
- `src/bun.js/api/server/RequestContext.zig:1312`
- `src/bun.js/api/server/RequestContext.zig:1335`

The uWS request object is short-lived and reused. Bun handles this by keeping the synchronous path lean, then only cloning URL/headers into durable JS-side state when the request becomes async via `toAsync(...)`.

This is a major optimization because many frameworks eagerly materialize:

- full header maps
- full URL objects
- full request wrappers

for every request, even when the handler finishes immediately.

Bun defers that cost.

### 6. Early rejection and deferred buffering keep the body path cheap

Body-size guard and request-body setup:

- `src/bun.js/api/server.zig:2193`
- `src/bun.js/api/server.zig:2218`
- `src/bun.js/api/server.zig:2241`

What Bun does:

- reads `content-length` early
- rejects oversized bodies before further work
- sets timeouts immediately
- does not preallocate the body buffer until chunks actually arrive

This is exactly the kind of optimization that matters at scale:

- less wasted memory on aborted or dishonest clients
- less heap pressure under high concurrency
- fewer slow-path cleanups

### 7. Fulfilled promise fast-path skips an extra event-loop turn

Promise handling:

- `src/bun.js/api/server/RequestContext.zig:1595`

If the handler returns a promise that is already fulfilled, Bun unwraps it immediately and renders the response without paying for the normal async callback scheduling path.

This is subtle but important. A lot of "async" overhead in web runtimes is really bookkeeping overhead. Bun explicitly shaves that off when possible.

### 8. The response path is built around `tryEnd` + `onWritable`

Backpressure and retry path:

- `src/bun.js/api/server/RequestContext.zig:440`
- `src/bun.js/api/server/RequestContext.zig:468`
- `src/bun.js/api/server/RequestContext.zig:871`
- `src/bun.js/api/server/RequestContext.zig:888`

Bun treats backpressure as part of the core response protocol:

- attempt `tryEnd(...)`
- if not complete, mark pending
- resume from `onWritable(...)` with the write offset

Why this is fast:

- avoids buffering everything blindly
- avoids blocking semantics
- preserves progress without re-sending bytes
- fits the evented transport model directly

This is one of the most transferable lessons for any high-performance server stack.

### 9. Static/file paths use transport-level optimizations, not app-level loops

Small-body corking:

- `src/bun.js/api/server/StaticRoute.zig:281`

File and sendfile path:

- `src/bun.js/api/server/RequestContext.zig:908`
- `src/bun.js/api/server/RequestContext.zig:801`
- `src/bun/src/http/SendFile.zig:28`

Bun uses two important write optimizations:

- cork small responses so headers + body are flushed together
- use `sendfile` for eligible file responses

That reduces:

- syscall count
- userspace copying
- socket write fragmentation

This is not glamorous, but it is exactly where high-throughput servers win.

### 10. Expensive housekeeping is amortized

Date header timer:

- `src/bun.js/api/Timer/DateHeaderTimer.zig:58`

The code explicitly notes that `updateDate()` is expensive, so Bun updates it on a timer instead of rebuilding that state unnecessarily on every response path.

This is a classic optimization category:

- move repeated work out of the request loop
- refresh shared state periodically

### 11. Routing fallback registration is optimized at setup time

Route registration and method coverage:

- `src/bun.js/api/server.zig:2478`
- `src/bun.js/api/server.zig:2677`

Bun tracks which methods are already covered for `/*` and only installs fallback handlers for the missing ones.

This is not as large as pooling or backpressure, but it shows the same design bias:

- do the work once during route setup
- simplify dispatch tables before traffic starts

### 12. Scaling is explicit: event-loop efficiency first, multi-listener via `reusePort`

Config and cluster-related reuse:

- `src/bun.js/api/server/ServerConfig.zig:52`
- `src/bun.js/api/server/ServerConfig.zig:406`
- `src/bun.js/api/server/ServerConfig.zig:835`

Bun’s default speed story is not "spawn many internal worker threads for one server object". It keeps the per-loop execution model efficient and exposes process-level scaling through `reusePort`, especially for Node cluster-style usage.

That is usually the right trade:

- keep each event loop simple
- scale out by listener/process when needed

## Optimization taxonomy

These are the main categories of optimization Bun is using.

### A. Architecture-level optimizations

- native evented HTTP stack via uWebSockets/uSockets
- compile-time specialization of server variants
- process/listener scaling through `reusePort`

### B. Allocation and memory optimizations

- thread-local pooled `RequestContext`
- deferred body allocation
- minimized GC-root overhead for route callbacks
- avoiding eager copies on sync requests

### C. JIT and language-boundary optimizations

- stable params object shapes
- per-route cached JS `Structure`
- native route-param decoding
- avoiding generic JS containers on hot paths

### D. Async lifecycle optimizations

- promise fulfilled fast-path
- only transition to async when required
- keep sync completion as short as possible

### E. Transport/write-path optimizations

- `tryEnd`/`onWritable` backpressure loops
- corked writes for small bodies
- `sendfile` for file responses
- efficient partial-write continuation

### F. Setup-time optimizations

- precomputed route metadata
- selective fallback route registration
- expensive repeated work moved out of the request path

## Why Bun is fast in practice

If you compress all of the above into one sentence:

Bun is fast because the hot path stays inside native networking machinery for as long as possible, and when it must cross into JS it does so with stable shapes, pooled state, and minimal copying.

More concretely, Bun avoids the common framework taxes:

- no per-request parser objects in JS
- no always-on body materialization
- no unnecessary async turn when the result is already available
- no naive response buffering strategy
- no shape-churn-heavy route params objects

## What is most transferable to `nim_uwebsocket`

Highest-value ideas to borrow:

1. Pool request contexts aggressively.
2. Keep sync handlers on a zero-copy / zero-materialization path as long as possible.
3. Treat async transition as a separate expensive mode, not the default representation.
4. Standardize on offset-based backpressure continuation.
5. Cork small static responses.
6. Use `sendfile` or equivalent kernel-assisted transfer for file bodies.
7. Move repeated route/setup work out of the live request path.
8. Cache any dynamic object shape or route-param metadata once per route.

## Bottom line

Bun’s performance is not one trick and not merely "written in Zig".

The real formula is:

- uWebSockets/uSockets for the transport core
- Zig for tight orchestration and lifecycle control
- JSCore-aware object/layout decisions
- ruthless removal of allocations, copies, and avoidable async work

That combination is why it is fast.
