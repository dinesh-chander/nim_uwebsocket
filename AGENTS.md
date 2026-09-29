# AGENTS.md

## Project context
This repository contains a high-performance Nim web stack inspired by Node.js Express, with two main components:
- `nim_usockets/`: low-level uSockets FFI bindings and HTTP/WebSocket server internals.
- `nim_express/`: Express-like web framework built on top of `nim_uwebsockets`.

Performance envelope (JSON endpoint with dynamic construction):
- **Single process**: ~95k req/s.
- **Multi-process (4 workers)**: ~130k req/s.
- **vs Node.js ultimate-express**: 43% faster throughput, 48% lower p99 latency.

## Repository layout
- `nim_uwebsockets/src/nim_uwebsockets/types.nim`: core low-level types (SslMode, socket pointers, callbacks).
- `nim_usockets/src/nim_usockets/usockets.nim`: C FFI bindings to the uSockets library.
- `nim_uwebsockets/src/nim_uwebsockets/http.nim`: HTTP server with WebSocket support (thread-local state).
- `nim_usockets/usockets/`: vendored uSockets C sources (a locally patched fork of uNetworking/uSockets — see `docs/design/usockets-fork.md`) and the git-ignored compiled `uSockets.a`.
- `nim_express/src/nim_express/app.nim`: app lifecycle and scaling (`runCluster`, `runThreaded`, `runAuto`).
- `nim_express/src/nim_express/router.nim`: route matching with `:param` support.
- `nim_express/src/nim_express/request.nim` / `response.nim`: request helpers and optimized single-syscall writes.
- `nim_express/src/nim_express/fastrand.nim`: fast xorshift64 RNG for hot paths.
- `nim_express/src/nim_express/middlewares/`: built-in middlewares.
- `examples/htmx_app.nim`: full demo with HTMX + WebSocket.
- `examples/showcase_app.nim`: API-feature tour (typed JSON, JsonBuilder, `runOffload`, ETag/gzip, WS broadcast, `/metrics`).
- `nim_utils/`: shared helpers (`fast_map`, `fast_set`, `async_logger`, `nim_fastjson` incl. simdjson backend).
- `nim_fasthttpclient/`: async HTTP/1.1 + HTTP/2 + WebSocket client with connection pooling.
- `vendor/`: vendored deps (zippy, brotli, nim_zstd, nim_libdeflate_gzip, malebolgia, jsony, checksums) — read-only.
- `benchmark/`: benchmark binaries/config and Node comparison (see `benchmark/AGENTS.md`).
- `docs/`: curated docs — framework analysis, benchmark results, design docs (index: `docs/README.md`).
- `doc/api/`: generated API reference (regenerate with `make docs`).

Every major package has its own `AGENTS.md` (`nim_express/`, `nim_usockets/`, `nim_utils/`, `nim_fasthttpclient/`, `examples/`, `benchmark/`, `docs/`, `vendor/`) with folder-specific rules; read the relevant one before working in that folder, and keep it current when its layout or conventions change.

Key external dependencies: **uSockets** (C networking, statically linked), **zippy** (gzip/deflate), **pcre2** (regex for route matching).

## Build and run
Use the top-level Makefile which handles platform detection automatically:
```bash
make usockets   # build uSockets.a (auto-selects GCD on macOS, epoll on Linux)
make bench      # build benchmark binary
make examples   # build all examples
make test       # run all tests
make docs       # regenerate API docs from code into doc/api/ (see Documentation)
```

Manual build from `nim_express/` (macOS):
```bash
nim c -d:release --opt:speed \
  --passL:"/path/to/uSockets.a -framework CoreFoundation" \
  -o:bin/htmx_app examples/htmx_app.nim
```

Manual build from `nim_express/` (Linux):
```bash
nim c -d:release --opt:speed \
  --passL:"/path/to/uSockets.a -lpthread -ldl" \
  -o:bin/htmx_app examples/htmx_app.nim
```

Rebuild uSockets when needed:
```bash
cd nim_uwebsockets/usockets
make clean
make                 # Linux (epoll, no GCD)
WITH_IO_URING=1 make # Linux (io_uring backend)
WITH_GCD=1 make      # macOS (required GCD backend)
```

## Documentation
Every **public** declaration (`proc`, `func`, `method`, `iterator`, `type`, `const`, `let` with `*`) in the library packages (`nim_utils`, `nim_usockets`, `nim_express`, `nim_fasthttpclient`) **must** have a doc comment. When adding or changing a public API, document it in the same change.

Doc comment format:
- `## ` prefix, placed **immediately above** the declaration (no blank line between doc and declaration).
- Indentation must **exactly match** the declaration line's indentation.
- 1–3 lines: concise, accurate description of what the declaration does (not how the implementation works).
- Reference other symbols with double backticks, e.g. `` `runCluster` ``.
- Do **not** use square brackets `[...]` in doc text — Nim's doc parser treats them as links and it breaks the generated docs.
- Keep doc text as prose; avoid parentheses wrapping identifier-like tokens.

Regenerate HTML docs from code (run after any public API or doc change):
```bash
make docs          # all packages -> doc/api/{express,fastjson,async-logger,fast-map,fast-set,usockets,fasthttpclient}/
```

## Platform constraints
- macOS:
  - Build/link with `-framework CoreFoundation`.
  - `WITH_GCD=1` is required for uSockets.
  - `runThreaded` falls back to single-thread due to GCD limitations.
  - `SO_REUSEPORT` does not load-balance effectively; use nginx/haproxy across ports.
- Linux:
  - Default backend is epoll; use `USOCKETS_BACKEND=io_uring`/`WITH_IO_URING=1` only when liburing and runtime seccomp allow io_uring syscalls.
  - `runCluster`/`runThreaded` are valid scaling options.
- Windows:
  - single-process mode expected.

## Architecture notes
### HTTP/WebSocket flow
1. `us_create_loop` creates the event loop (GCD on macOS, epoll/io_uring on Linux).
2. `us_socket_context_listen` starts the TCP listener.
3. `onSocketData` callback receives raw bytes.
4. The HTTP parser extracts method, path, headers, body.
5. WebSocket upgrade is detected via the `Upgrade: websocket` header.
6. Timer callbacks (`setInterval`) drive periodic work (keepalives, broadcasts).

### Scaling
```nim
# Factory function pattern (required for multi-process/thread)
proc createApp(): ExpressApp {.gcsafe.} =
  let app = newExpressApp()
  app.getSync("/json") do (req: Request, res: Response):
    res.jsonify(myData)
  return app

let app = createApp()
app.run(3000)                                # Option 1: single process
runCluster(createApp, 3000, numWorkers = 4)  # Option 2: multi-process (SO_REUSEPORT on Linux)
runThreaded(createApp, 3000, numThreads = 4) # Option 3: multi-thread (Linux only; macOS falls back)
runAuto(createApp, 3000)                     # Option 4: auto-select best for the platform
```

| Platform | Multi-threading | Multi-process | Recommended |
|----------|----------------|---------------|-------------|
| **Linux** | Works (epoll) | Works (SO_REUSEPORT) | `runCluster` or `runThreaded` |
| **macOS** | No (GCD limitation) | No (SO_REUSEPORT doesn't load-balance) | Single process + nginx |
| **Windows** | No (no fork) | No (no fork) | Single process |

macOS scaling with nginx: run multiple instances on different ports (`./bench_multiport 3010 4`) and load balance with nginx (see `benchmark/nginx_loadbalancer.conf`).

### Middleware pattern
```nim
proc myMiddleware(): Middleware =
  proc(req: Request, res: Response, next: NextProc) =
    # Before handler
    next()
    # After handler (response built)
```

### Performance optimizations
- `{.inline.}` pragmas on hot path functions.
- Pre-computed status strings array (`StatusLines`).
- Pre-sized Tables and strings (`newStringOfCap`, `initTable(size)`).
- Fast method parsing without string allocation; single-pass HTTP header parsing.
- Single socket write (headers + body combined); fast integer-to-string (`fastIntToStr`).
- Fast xorshift64 RNG (`fastrand.nim`) instead of stdlib random; jsony/simdjson for fast JSON.

## Runtime/testing checks
- Run app: `./bin/htmx_app`
- HTTP test: `curl http://localhost:3000/api/todos`
- WebSocket upgrade smoke test:
```bash
curl -sI -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  http://localhost:3000/ws
```

## Benchmarking
```bash
cd benchmark
wrk -t4 -c100 -d30s --latency http://localhost:3002/json
# Expected (M1/M2 Mac): ~95k req/s single process, p50 ~1ms, p99 ~1.2ms
```
Use `benchmark/` for performance regressions only after functional correctness is confirmed.

## Common pitfalls
- Startup SIGSEGV on macOS: rebuild uSockets with `WITH_GCD=1` and verify the CoreFoundation link flag.
- Linux link errors: ensure `-lpthread -ldl` are passed instead of `-framework CoreFoundation`.
- Multi-threading on macOS: GCD builds require event-loop startup on the process main thread and fail fast otherwise; `runThreaded` falls back to single thread.
- WebSocket closes immediately: verify accept key generation uses raw SHA1 bytes (not hex) and ensure handler registration before `listen()`.
- Ambiguous proc calls: use explicit type qualification where needed.

## Agent guidance
- Prefer changes that preserve existing performance characteristics and allocation behavior.
- For scaling-related work, validate behavior per platform rather than assuming Linux semantics on macOS.
- For `nim_express` API changes, verify routing, middleware flow, JSON responses, and WebSocket upgrade behavior.
- Always document new/changed public APIs per the Documentation section, and regenerate with `make docs`.
- Keep context small by default: inspect only files on the critical path and prefer targeted reads (`rg`, scoped `sed`, narrow diffs) over loading full files or broad directory scans.
- Summarize findings instead of pasting large outputs; include only the minimal code, logs, or benchmark slices needed to support the next decision.
- Reuse gathered context and avoid rereading unchanged files unless verifying a fix, resolving uncertainty, or reviewing a new conflicting change.
- Prefer narrow tests and focused benchmarks for touched paths before running wider suites; expand scope only when the smaller check is insufficient.
- Defer speculative explorations and side refactors unless they are clearly needed to achieve the current goal or unblock correctness/performance work.
