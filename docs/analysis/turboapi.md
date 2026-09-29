# turboAPI Analysis

Analyzed against `justrach/turboAPI` `main` at commit `cc093455cdac018a0dc999cb6cf7b0c398db20f6` (pulled locally into `analysis/tmp/turboAPI` on 2026-03-20).

## Executive summary

`turboAPI` is fast for a straightforward reason: it bypasses most of the usual FastAPI/ASGI/Python request overhead and replaces it with a narrow Zig-to-CPython fast path.

The real speed comes from:

1. startup-time handler classification,
2. a direct Zig HTTP server with a fixed worker pool,
3. specialized Python call paths (`PyObject_CallNoArgs`, `PyObject_Vectorcall`, tuple ABI),
4. Zig-side route matching and body validation,
5. pre-rendered static/CORS/cached responses,
6. small-response single-write assembly.

The important caveat is that some repo claims are stronger than the current code:

- the checked hot path does not show real SIMD JSON usage
- async does not have a dedicated native fast path in the current Zig `HandlerType`
- “zero-copy” is partially true, not end-to-end true
- the server architecture is thread-pool + blocking sockets, not a uWebSockets-style event loop

So the right conclusion is:

`turboAPI` is optimized and fast, but its speed mostly comes from removing Python framework overhead, not from an unusually advanced HTTP runtime.

## What the code is actually doing

### 1. Requests are classified once at startup

Handler classification:

- `python/turboapi/zig_integration.py:24`

Route registration:

- `python/turboapi/zig_integration.py:537`
- `zig/src/server.zig:352`
- `zig/src/server.zig:437`

Handlers are sorted into categories like:

- `simple_sync_noargs`
- `simple_sync`
- `model_sync`
- `body_sync`
- `enhanced`

This matters because the request path avoids per-request introspection. The expensive questions:

- does it need body parsing?
- does it need a model?
- can it use positional args?
- does it need the full wrapper?

are answered once during route registration instead of on every request.

That is one of the highest-value optimizations in the repo.

### 2. The core server is a fixed-size thread pool, not an event loop

Worker pool and accept loop:

- `zig/src/server.zig:685`
- `zig/src/server.zig:727`
- `zig/src/server.zig:758`
- `zig/src/server.zig:776`

The architecture is:

- one accept loop
- a queue of accepted `std.net.Stream`s
- 24 worker threads
- each worker owns a persistent CPython thread state

Each worker then services keep-alive connections in a loop:

- `zig/src/server.zig:812`

This is a practical optimization:

- no thread creation per request
- no `PyGILState_Ensure` lookup cost per call
- good fit for free-threaded Python 3.14t

But it is not the same class of architecture as Bun/uWebSockets. It is blocking socket IO with a worker pool and per-connection handling.

### 3. Per-worker CPython state reuse is one of the strongest optimizations

CPython bridge:

- `zig/src/py.zig:99`
- `zig/src/py.zig:106`
- `zig/src/py.zig:108`

Worker setup:

- `zig/src/server.zig:736`
- `zig/src/server.zig:738`

Accept loop GIL release:

- `zig/src/server.zig:776`

Instead of using the more expensive generic GIL APIs for every request, each worker creates one `PyThreadState` and reuses it. That cuts recurring interpreter bookkeeping from the hot path.

This is a very real performance win.

## The hot-path optimizations

### 4. Route matching is cheap and mostly allocation-free

Router implementation:

- `zig/src/router.zig:19`
- `zig/src/router.zig:64`
- `zig/src/router.zig:91`

Key details:

- radix-trie style route tree
- fixed-size stack buffer for path segments
- fixed-size `RouteParams` buffer instead of a dynamic map
- static > param > wildcard priority

This avoids a lot of framework-style routing overhead:

- no regex per request
- no Python route matching
- no dynamic param container for the common case

The only notable allocation in matching is wildcard path joining when needed.

### 5. It matches routes before parsing headers/body

Request pipeline:

- `zig/src/server.zig:865`
- `zig/src/server.zig:882`
- `zig/src/server.zig:957`

`turboAPI` parses the request line first, performs route lookup early, and only then decides whether it even needs:

- headers
- body
- Python

This is a good design choice because the fastest request is the one that exits early:

- static routes skip Python entirely
- FFI routes skip Python entirely
- simple GET-style handlers skip full header/body work

### 6. Fast handler dispatch is the biggest user-visible win

No-arg fast path:

- `zig/src/server.zig:1182`

Positional/vectorcall fast path:

- `zig/src/server.zig:1239`
- `zig/src/server.zig:1315`
- `python/turboapi/request_handler.py:853`
- `python/turboapi/zig_integration.py:605`

Tuple response ABI:

- `zig/src/server.zig:1143`

This is where `turboAPI` wins most clearly over ordinary Python frameworks.

For fast handlers it avoids:

- building `kwargs`
- parsing query strings in Python
- repeated dict lookups on response objects
- generic wrapper logic

Instead the optimized path is:

- Zig extracts/decodes args
- Zig calls Python directly via `PyObject_CallNoArgs` or `PyObject_Vectorcall`
- Python wrapper returns a fixed `(status, content_type, body)` tuple
- Zig unpacks and writes it

That is a strong, concrete optimization stack.

### 7. Model validation is moved into Zig

Validation support:

- `zig/src/dhi_validator.zig:83`
- `zig/src/server.zig:1025`
- `zig/src/server.zig:1532`
- `zig/src/server.zig:1593`
- `python/turboapi/request_handler.py:1003`

For `model_sync` routes, `turboAPI` can:

- validate JSON in Zig before Python
- retain the parsed JSON tree
- convert it directly into Python objects
- call the minimal model wrapper without `json.loads`

This is one of the more meaningful optimizations in the repo because it removes both:

- Python-side JSON parse cost
- late validation overhead

It also improves rejection efficiency: invalid requests can fail before touching the normal Python handler stack.

### 8. The response path is optimized for the common case

Response writer:

- `zig/src/server.zig:1858`

Small responses are assembled into a stack buffer and sent with one `writeAll` when total size is `<= 4096`:

- `zig/src/server.zig:1901`

Larger responses fall back to multiple writes:

- `zig/src/server.zig:1903`

This is a classic throughput optimization:

- reduce syscalls for common API payloads
- avoid heap allocation for common responses
- keep hot response assembly in flat memory

### 9. Static routes, CORS, and cacheable no-arg responses are pre-rendered

Static routes:

- `zig/src/server.zig:559`
- `python/turboapi/zig_integration.py:334`

CORS block:

- `zig/src/server.zig:602`

Response cache:

- `zig/src/server.zig:651`
- `zig/src/server.zig:924`
- `zig/src/server.zig:943`

These are effective because they remove whole subsystems from the hot path:

- no Python call
- no GIL
- no per-request header formatting
- no per-request CORS logic

This is especially strong for health/version endpoints and other predictable responses.

### 10. Several security/robustness checks also help performance stability

Relevant checks:

- `zig/src/server.zig:818`
- `zig/src/server.zig:846`
- `zig/src/server.zig:963`
- `zig/src/server.zig:985`

The server currently:

- applies socket read timeout for slowloris protection
- rejects oversized headers
- rejects `Transfer-Encoding` paths it does not implement
- rejects TE+CL smuggling combinations
- caps request body size at 16 MB

These are not “speed” optimizations directly, but they prevent bad traffic from pushing the server into expensive or ambiguous states.

## Where the repo’s claims overreach

### 11. “SIMD JSON” does not appear in the checked hot path

What the docs say:

- `docs/PERFORMANCE_TUNING.md`
- `docs/BENCHMARKS.md`
- `python/turboapi/zig_integration.py:97`

What the code shows:

- JSON parsing uses `std.json.parseFromSlice(...)`
  - `zig/src/dhi_validator.zig:83`
  - `zig/src/server.zig:1535`
- enhanced response serialization falls back to Python `json.dumps()`
  - `zig/src/server.zig:1774`

I did not find actual `simd-json` usage in the inspected Zig request/response path. So “SIMD JSON” currently looks more like roadmap/docs language than an implemented hot-path fact.

### 12. “Zero-copy” is only partially true

Direct Python string/bytes read:

- `zig/src/server.zig:1163`
- `zig/src/server.zig:1215`
- `zig/src/server.zig:1399`

Owned-copy paths:

- `zig/src/server.zig:1233`
- `zig/src/server.zig:1416`
- `zig/src/server.zig:1797`

`turboAPI` does use zero-copy reads from Python objects in places:

- `PyUnicode_AsUTF8`
- `PyBytes_AsStringAndSize`

But it is not zero-copy end-to-end:

- cached responses duplicate body bytes into owned storage
- enhanced responses duplicate content type and body into owned buffers
- `sendResponse` copies small responses into a stack buffer before writing

So the honest description is:

- reduced-copy on fast paths
- not fully zero-copy transport end-to-end

### 13. Async fast paths are not really native fast paths yet

Zig handler enum:

- `zig/src/server.zig:109`
- `zig/src/server.zig:117`

Async registration:

- `zig/src/server.zig:476`

Coroutine execution:

- `zig/src/server.zig:1723`

Python-side classification does recognize `simple_async` and `body_async`, but the Zig `HandlerType` enum does not. Unrecognized types fall back to `.enhanced`.

In the enhanced path, if the handler returns a coroutine, the code imports `asyncio` and runs it via `asyncio.run()` per request.

That means the current repo does not have a dedicated async-native hot path comparable to the sync tuple/vectorcall path.

This is the biggest mismatch between the docs and the current implementation.

## Why it is still fast

Despite those caveats, `turboAPI` can still be fast because it removes expensive framework layers:

- no ASGI adapter in the hot path
- no Starlette/FastAPI dependency resolution for simple routes
- no Python routing for matched requests
- no generic request/response object construction for fast paths
- no Python query/body parsing for `model_sync`
- reduced interpreter overhead via thread-state reuse

In practice, the repo’s fast path is best understood as:

Zig socket server + Zig router + direct CPython ABI + specialized wrappers

That is a credible way to beat general-purpose Python web stacks.

## Why it is not Bun/uWebSockets-class fast

Compared with Bun or uWebSockets, the current architecture still pays for:

- blocking socket reads per active connection
- worker-thread occupancy for keep-alive connections
- more copying around Python values
- Python serialization on many paths
- generic enhanced path for async and complex routes

So the repo is strongest when requests stay in these buckets:

- static routes
- FFI/native routes
- no-arg sync routes
- simple positional sync routes
- validated `model_sync` routes

That is where the design is genuinely sharp.

## Most transferable ideas for `nim_uwebsocket`

Highest-value ideas to borrow:

1. Classify handlers once at startup and register the lightest possible dispatch path.
2. Use a narrow tuple ABI for fast responses instead of generic response objects.
3. Add a positional call path that avoids kwargs/dicts for simple handlers.
4. Match routes before parsing headers/body when possible.
5. Keep route params in a fixed stack buffer on the common path.
6. Pre-render static and CORS responses.
7. Cache truly immutable no-arg responses.
8. Move validation ahead of the dynamic language boundary.
9. Reuse per-worker language runtime state if you bridge into a VM.

## Bottom line

`turboAPI` is fast because it strips away Python framework overhead with a focused Zig front-end and a very cheap CPython calling convention.

Its real strengths are:

- startup-time specialization,
- fast CPython dispatch,
- Zig-side route matching,
- Zig-side validation,
- pre-rendered/common-case response shortcuts.

Its current limits are:

- no true async-native fast path,
- no evidence of actual SIMD JSON in the checked hot path,
- only partial zero-copy behavior,
- thread-pool/blocking-IO architecture rather than a higher-end evented transport core.

That still makes it a useful design to study, especially for how much performance you can recover just by narrowing the language boundary and specializing the request path aggressively.
