# GoFiber Deep Implementation Analysis

## Scope and snapshot

- Repository: `https://github.com/gofiber/fiber`
- Clone mode: `git clone --depth 1`
- Analyzed commit: `7595d364eac1a1c2ba51289bc2ace9a8c598498c`
- Focus: server/runtime internals only (routing, context lifecycle, request/response path, scaling)

## Architecture and execution model

Fiber is a thin framework layer over `fasthttp.Server`, with a precomputed route structure and pooled request context objects.

- App core state is centralized in `App` with:
  - `sync.Pool` for contexts
  - per-method route stacks
  - per-method, prefix-bucketed tree stacks
  - mutable startup flags (`routesRefreshed`)  
  Code: `app.go:68`, `app.go:74`, `app.go:101`, `app.go:102`, `app.go:109`.
- `New()` sets defaults, allocates route stacks, and creates the context pool.  
  Code: `app.go:543`, `app.go:556`, `app.go:652`.
- `init()` constructs/configures `fasthttp.Server` and wires Fiber config directly into fast HTTP runtime knobs (`Concurrency`, `BodyLimit`, stream request body, buffer sizes, timeouts).  
  Code: `app.go:1286`, `app.go:1302`, `app.go:1311`, `app.go:1325`.
- Startup path is explicit:
  - auto-HEAD route synthesis
  - mounted sub-app route expansion
  - route tree build  
  Code: `app.go:1435`, `app.go:1439`, `app.go:1446`, `app.go:1449`, `mount.go:113`, `router.go:627`, `router.go:703`.
- Request entrypoint:
  - `fasthttp` calls `requestHandler`
  - Fiber acquires pooled ctx, executes route pipeline, then releases ctx  
  Code: `router.go:313`, `ctx_interface.go:66`, `ctx_interface.go:89`.

## Request parse/routing pipeline and optimizations

### Pipeline

1. `AcquireCtx` gets pooled context and `Reset`s request state.
2. `Reset` captures method/path and computes config-dependent routing path variants.
3. `next()` selects a pre-bucketed route slice by method + 3-byte path hash.
4. Route matching executes sequentially in registration order.
5. Handler chain runs via `Next()`, then falls through back to `next()`.
6. If no match, Fiber checks other methods to emit `405 + Allow` vs `404`.

Code: `ctx_interface.go:66`, `ctx.go:662`, `ctx.go:632`, `router.go:113`, `ctx.go:243`, `router.go:172`.

### Routing optimizations

- Pre-normalization at registration (lowercase/trim/escape removal) done once, not per request.  
  Code: `router.go:511`.
- Route parser precomputes segment metadata (`ComparePart`, greediness, optional slash behavior, constraint info).  
  Code: `path.go:221`, `path.go:258`, `path.go:507`.
- Regex constraints are compiled at route registration time.  
  Code: `path.go:419`.
- Route tree bucketing by first 3 bytes of first constant segment minimizes linear scan set per request.  
  Code: `router.go:703`, `router.go:734`, `ctx.go:653`.
- Route bucket slices are capacity-reused when tree rebuilds happen.  
  Code: `router.go:760`.
- Auto `HEAD` generation from `GET` is done once and uses copied route handler chain; explicit `HEAD` can replace generated route.  
  Code: `router.go:627`, `router.go:658`, `router.go:490`.

### Request parse hot-path micro-optimizations

- Manual header list tokenization for IP extraction avoids allocations from `strings.Split`.
- Stack-buffer strategy for subdomain parsing avoids heap allocation in common cases.
- Content-encoding body decode order handled in-place with temporary body rewrites only when needed.

Code: `req.go:526`, `req.go:588`, `req.go:1009`, `req.go:100`, `req.go:149`.

## Response write/backpressure strategy

Fiber mostly delegates response I/O and backpressure semantics to `fasthttp`, with thin convenience APIs.

- Fast body set path uses raw setter (`SetBodyRaw`) in `Send`, `JSON`, `XML`, etc. (caller/library must respect no-mutate semantics after set).  
  Code: `res.go:762`, `res.go:764`, `res.go:502`, `res.go:509`, `res.go:597`.
- Streaming APIs:
  - `SendStream` -> `SetBodyStream(reader,size|-1)`
  - `SendStreamWriter` -> `SetBodyStreamWriter`  
  Code: `res.go:1004`, `res.go:1006`, `res.go:1015`.
- Server-level write/read deadlines are configured via `fasthttp.Server` to bound blocked I/O time.  
  Code: `app.go:1319`, `app.go:1320`.
- `SendFile` builds and caches `fasthttp.FS` handlers per unique `SendFile` config, reducing repeated handler construction overhead.  
  Code: `res.go:66`, `res.go:76`, `res.go:792`, `res.go:811`, `res.go:842`.
- `End()` does manual flush+close but explicitly does not operate in async streaming cases (nil conn).  
  Code: `res.go:1132`.
- Docs explicitly describe streaming flush behavior and disconnect handling in stream writer mode.  
  Doc: `docs/api/ctx.md:2766`.

## Memory/allocation optimizations

- Context pooling:
  - per-app `sync.Pool`
  - `Reset` + `release` lifecycle  
  Code: `app.go:74`, `app.go:556`, `ctx_interface.go:66`, `ctx_interface.go:89`, `ctx.go:662`, `ctx.go:686`.
- Zero-allocation-oriented value lifetime model (ctx-derived strings/bytes valid only during handler unless detached/copy/immutable mode).  
  Code: `docs/intro.md:27`.
- Optional immutable mode changes conversions to allocate safe copies.  
  Code: `app.go:609`, `helpers.go:915`, `helpers.go:919`.
- Selective detach API (`GetString`, `GetBytes`) with runtime read-only memory detection avoids unnecessary copies for rodata-backed values.  
  Code: `app.go:675`, `app.go:687`, `readonly.go:15`.
- Byte buffer pooling in several response/request formatting paths (`bytebufferpool`).  
  Code: `req.go:215`, `res.go:570`, `ctx.go:599`.
- Route tree bucket reuse to reduce churn during rebuild.  
  Code: `router.go:760`.

## Concurrency and scaling model

- In-process concurrency is inherited from `fasthttp` and bounded by `Config.Concurrency`.  
  Code: `app.go:1311`.
- Multi-process scaling option is prefork:
  - parent process spawns N children (`N = GOMAXPROCS`)
  - child binds with `reuseport`
  - each child sets `GOMAXPROCS(1)`  
  Code: `prefork.go:37`, `prefork.go:47`, `prefork.go:50`, `prefork.go:87`, `prefork.go:101`.
- Prefork enabled via `ListenConfig.EnablePrefork`.  
  Code: `listen.go:127`, `listen.go:236`.
- Route registration/mutation is mutex-protected, but runtime rebuild is explicitly documented as not thread-safe for production request path and has measured per-request cost impact when made safer.  
  Code: `router.go:695`, `router.go:703`.
- Timeout middleware prioritizes race-freedom by abandoning contexts on timeout; timed-out contexts are intentionally not returned to pool yet (documented TODO memory leak tradeoff).  
  Code: `ctx.go:718`, `timeout/timeout.go:95`, `timeout/timeout.go:111`, `timeout/timeout.go:145`.

## Notable implementation techniques with code pointers

- Method-to-int fast path switch when using default methods (avoids map lookup/string maps).  
  `helpers.go:923`.
- Request path dual representation:
  - user-visible path
  - detection path (normalized for routing)
  - plus cached hash for tree bucket selection  
  `ctx.go:632`.
- Middleware route matching with boundary-aware prefix checks (`hasPartialMatchBoundary`) to prevent false positives.  
  `router.go:89`, `path.go:486`.
- 405 generation by scanning other method buckets and accumulating `Allow` header in a single miss path.
  `router.go:172`.
- Auto-generated `HEAD` routes cloned from `GET` chains to preserve behavior with body suppression handled by fasthttp transport layer.
  `router.go:627`.
- Sendfile handler cache keyed by config equality, avoiding repeated FS handler setup for repeated usage patterns.
  `res.go:76`, `res.go:811`.
- Proxy-trust model with CIDR/IP allowlist and optional validation, defaulting to remote socket IP when untrusted.
  `req.go:1080`, `app.go:697`.
- Error path middleware traversal support in `serverErrorHandler` (`skipNonUseRoutes`) before final error handler invocation.
  `app.go:1382`.

## Transferable learnings for nim_express/nim_usockets

## P0 (high impact, low-medium risk)

- Build a startup-time route index with cheap prefix bucketing (like 3-byte hash) plus per-method buckets to shrink match scan set in hot path.  
  Analog: `router.go:703`, `ctx.go:653`.
- Preparse route patterns into immutable segment programs with precomputed metadata (compare parts, greedy counts, optional slash rules).  
  Analog: `path.go:221`, `path.go:258`, `path.go:507`.
- Keep pooled request context lifecycle explicit (`reset`/`release`) and make borrowed-value lifetime a hard contract in docs + API naming.  
  Analog: `ctx.go:662`, `ctx.go:686`, `docs/intro.md:27`.
- For IP/header-heavy paths, prefer allocation-free token scanning over `split` helpers.  
  Analog: `req.go:526`, `req.go:588`.

## P1 (strong value, moderate integration cost)

- Add optional auto-HEAD registration from GET with explicit override precedence.
  Analog: `router.go:627`.
- Introduce sendfile handler caching keyed by config tuple (compression, range, cache duration, FS backend).
  Analog: `res.go:66`, `res.go:76`, `res.go:792`.
- Add explicit immutable-detach helper APIs rather than global copy-on-read for all accessors.
  Analog: `app.go:675`, `app.go:687`.
- Keep error middleware traversal distinct from route handlers (ability to run `use` chain on parser/protocol errors).
  Analog: `app.go:1382`.

## P2 (situational/advanced)

- Abandon/force-release semantics for timeout-driven async safety where handler may continue after response timeout.  
  Analog: `ctx.go:718`, `timeout/timeout.go:95`.
- Handler-shape adaptation layer (if Nim APIs need interop with multiple callback signatures).
  Analog: `adapter.go:12`.
- Mounted-app startup flattening into a single compiled route stack for request-time simplicity.
  Analog: `mount.go:113`, `mount.go:181`.

## Risks/tradeoffs if adopted

- Complexity risk: route parser + bucket compiler + mount flattening adds startup complexity and harder correctness testing.
- Dynamic-route mutation risk: lock-free read path + mutable route trees requires strict lifecycle controls; runtime rebuild can be expensive and unsafe without additional synchronization.
- Memory safety risk: pooled context + borrowed slices/strings is fast but easy to misuse by app/middleware authors.
- Timeout strategy risk: race-free abandonment can leak pooled objects unless a safe reclamation mechanism is engineered.
- Prefork operational risk: process supervision, logs, graceful shutdown, and socket behavior differ across OS/network setups.
- API flexibility tradeoff: avoiding regex routes in matcher improves speed but reduces expressiveness.

## Brief completion summary

GoFiber's core performance comes from: startup-time route compilation, method/prefix bucketed dispatch, pooled context reuse with strict value lifetimes, and heavy delegation to `fasthttp` for transport/write-path behavior. The most transferable ideas for `nim_express`/`nim_usockets` are P0 route bucketing + parsed segment programs + strict pooled-context contracts.
