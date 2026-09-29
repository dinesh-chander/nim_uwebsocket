# Examples

Categorized, runnable apps for `nim_express` live here.
This top-level `examples/` tree is the canonical example location for the repo.

## Structure

```
examples/
  apps/
    performance/
    operations/
    observability/
    edge/
    rest/
    fullstack/
    security/
    realtime/
    rendering/
    transport/
    devx/
  views/
    fullstack_todo_upload/
    htmx_ssr/
    security/
    websocket_pubsub/
    sse/
```

Top-level `*.nim` files are thin entrypoints so existing build scripts still work.

## Build helper

From repo root:

```bash
mkdir -p examples/bin
make usockets
LINK_FLAGS="nim_usockets/usockets/uSockets.a -lpthread -ldl"  # Linux
# LINK_FLAGS="nim_usockets/usockets/uSockets.a -framework CoreFoundation"  # macOS
nim c -d:release --opt:speed \
  --passL:"$LINK_FLAGS" \
  -o:examples/bin/<example_name> examples/<example_name>.nim
```

Context pooling is disabled by default.

- Default build: request/response context pooling is off.
- Opt in to pooling: add `-d:nimexpress_context_pool`.

## Category index

| Category | Entrypoint | Purpose | Cancellation semantics |
|---|---|---|---|
| Performance-oriented | `performance_app.nim` | Fast JSON paths, typed JSON, optimization metrics | `/async-window` checks `req.aborted()` and timeout budget |
| Platform controls | `platform_controls_app.nim` | body_limit, concurrency_guard, normalize_path, backpressure, graceful_shutdown, panic_recovery, global_error_filter, error_handler | `/work/slow` shows guard metrics and `/ops/shutdown` simulates drain mode |
| Observability | `observability_app.nim` | server_timing, response_time, json_logger, openTelemetry | `/trace` exposes propagated trace context |
| Edge caching + IP filter | `edge_cache_app.nim` | output_cache tag invalidation and ip_filter allowlist | `/cache/catalog` demonstrates cached GETs and `/protected/ping` shows IP filtering |
| REST + OpenAPI generation | `rest_openapi_app.nim` | CRUD todo API + live OpenAPI middleware + Swagger UI | `/api/todos/search` uses abort hook + cooperative checks |
| Full-stack todo + file upload | `fullstack_todo_upload_app.nim` | HTMX SSR todo app with multipart file upload | `/api/todos/export` cooperative cancellation |
| Security-oriented | `security_hardening_app.nim` | Helmet, rate limit, session, CSRF | `/api/audit` abort-aware async path |
| WebSocket compression + pub/sub | `websocket_pubsub_compression_app.nim` | WS topic subscribe/unsubscribe/publish with permessage-deflate | `/api/replay/:topic` abort-aware async publisher |
| HTMX + SSR templates/views | `htmx_ssr_app.nim` | Template-driven SSR with HTMX fragments | `/fragments/slow-status` abort-aware async fragment |
| Server-sent events | `sse_stream_app.nim` | Event stream using chunked response | `/events` registers `onAbort` + stream loop checks |
| Compression showcase | `compression_showcase_app.nim` | Demonstrates gzip/br/zstd negotiation and policy tuning | `/payload/slow` cooperative cancellation |
| Proxy + CORS gateway | `proxy_cors_app.nim` | Reverse proxy middleware mounted under `/proxy/upstream/*` with CORS enabled | Upstream proxy work is delegated to middleware |
| DevX timeout/cancellation | `cancellation_timeout_app.nim` | Timeout middleware + offload behavior | `/work` + `/offload` abort-aware response logic |

## Quick run commands

```bash
make usockets
LINK_FLAGS="nim_usockets/usockets/uSockets.a -lpthread -ldl"  # Linux
# LINK_FLAGS="nim_usockets/usockets/uSockets.a -framework CoreFoundation"  # macOS

# performance
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/performance_app examples/performance_app.nim
./examples/bin/performance_app

# platform controls
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/platform_controls_app examples/platform_controls_app.nim
./examples/bin/platform_controls_app

# observability
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/observability_app examples/observability_app.nim
./examples/bin/observability_app

# edge cache + ip filter
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/edge_cache_app examples/edge_cache_app.nim
./examples/bin/edge_cache_app

# REST + OpenAPI
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/rest_openapi_app examples/rest_openapi_app.nim
./examples/bin/rest_openapi_app

# full-stack todo + upload
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/fullstack_todo_upload_app examples/fullstack_todo_upload_app.nim
./examples/bin/fullstack_todo_upload_app

# security
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/security_hardening_app examples/security_hardening_app.nim
./examples/bin/security_hardening_app

# websocket
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/websocket_pubsub_compression_app examples/websocket_pubsub_compression_app.nim
./examples/bin/websocket_pubsub_compression_app

# htmx + ssr
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/htmx_ssr_app examples/htmx_ssr_app.nim
./examples/bin/htmx_ssr_app

# sse
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/sse_stream_app examples/sse_stream_app.nim
./examples/bin/sse_stream_app

# compression showcase
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/compression_showcase_app examples/compression_showcase_app.nim
./examples/bin/compression_showcase_app

# proxy + cors
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/proxy_cors_app examples/proxy_cors_app.nim
PROXY_TARGET=http://127.0.0.1:4001 ./examples/bin/proxy_cors_app

# timeout/cancellation devx
nim c -d:release --opt:speed --passL:"$LINK_FLAGS" -o:examples/bin/cancellation_timeout_app examples/cancellation_timeout_app.nim
./examples/bin/cancellation_timeout_app
```

## Smoke tests

```bash
curl -s http://localhost:3000/health
curl -s http://localhost:3000/openapi.json
curl -s http://localhost:3000/docs >/dev/null
curl -s -H 'Accept-Encoding: zstd' http://localhost:3000/payload/text -o /dev/null -D -
curl -sN http://localhost:3000/events
```

## Legacy examples

Older examples are still present for backwards compatibility:

- `basic_app.nim`
- `async_app.nim`
- `benchmark_app.nim`
- `htmx_app.nim`
- `todo_sqlite_mvc_app.nim`
- `middleware_showcase_app.nim`
- `sse_example/sse_server.nim`
