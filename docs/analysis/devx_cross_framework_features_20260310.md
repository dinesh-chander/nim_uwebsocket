# Cross-Framework DevX/Runtime Feature Gaps for `nim_express` (2026-03-10)

Scope: compared current `nim_express` APIs to modern framework features in Fastify/NestJS/Express ecosystem, ASP.NET Core, Go Fiber, Actix/Axum/Hyper (Tower), and uWebSockets.js docs.

## Recommended features (concrete gaps)

| # | Feature | Why useful | Minimal implementation sketch for `nim_express` |
|---|---|---|---|
| 1 | Schema-first route contracts (request + response) with compiled validation/serialization | Fastify-style schema compilation reduces runtime parsing bugs and gives predictable perf for hot paths. Also unlocks better typed handler contracts. | Add optional `RouteSchema` in route registration: `{params, query, headers, body, response[status]}`. Compile validators at startup and store in route metadata. Validate before middleware/handler; serialize responses through precompiled encoders when schema exists. |
| 2 | Built-in OpenAPI generation (runtime + build artifact) | Nest/ASP.NET expose API docs with near-zero friction. This improves onboarding, client SDK generation, and contract testing. | Extend existing route manifest to include schemas/tags/security metadata. Add `app.openApiDocument()` and `app.writeOpenApi(path)`; optional `app.useSwaggerUi("/docs")`. Generate from route table + schemas only (no reflection dependency). |
| 3 | Streaming `multipart/form-data` with limits and disk/memory modes | Express/Fastify/Fiber treat file upload as first-class. Current `bodyParser` only handles `application/x-www-form-urlencoded`, leaving a major API gap. | Add `multipartParser()` middleware using streaming parser (busboy-style architecture in Nim). Support `req.file()`, `req.files()`, and per-route limits (`fileSize`, `parts`, `fields`). Include secure temp-file storage + explicit cleanup hooks. |
| 4 | First-class in-process HTTP test client (`app.inject`) | Fastify/Fiber/Actix have fast, no-socket testing that improves CI speed and deterministic API testing. | Add public `app.inject(reqSpec): InjectResponse` calling internal parser/dispatcher path. Support method/url/query/headers/body/cookies and return status/headers/body/json helper. Reuse existing `handleRequestForTest` internals but expose stable API. |
| 5 | Typed extractor/binder system for structs (beyond `string|int|bool`) | Actix/Axum extractors make handlers concise and safe (`Json<T>`, `Path<T>`, `Query<T>`). `nim_express` currently hard-limits generic extraction types. | Add `req.bind[T](sources=...)` where `T` is object/record; map from query/params/headers/body with coercion + field-level errors. Keep hot path fast by generating binders at compile time (macros/templates) and caching field maps. |
| 6 | Route-level filter/policy pipeline (timeouts, rate, concurrency, auth) | ASP.NET endpoint filters and Tower layers provide declarative, composable per-endpoint behavior with clear ordering and short-circuit semantics. | Introduce `Policy` objects and `route.withPolicies(...)`. Implement built-ins: `timeout`, `rateLimit`, `concurrencyLimit`, `auth`. Compile policy chain into route metadata once; execute before handler with deterministic FIFO/FILO semantics. |
| 7 | Output caching middleware with per-route policy + invalidation tags | ASP.NET output cache improves repeated GET latency and reduces backend pressure without custom middleware per app. | Add `outputCache()` with named policies (`varyByQuery`, `varyByHeader`, TTL). Add route helper `cacheOutput("policy")`. Maintain lock-free sharded cache store; expose tag invalidation API (`cache.evictTag("todos")`). |
| 8 | OpenTelemetry integration (traces/metrics/log correlation) | Modern stacks expose OTEL as default observability interface. Enables vendor-neutral tracing and production diagnostics. | Add `nim_express/opentelemetry` module: request span lifecycle hooks, HTTP semantic attrs, traceparent propagation, error/status mapping, metrics counters/histograms. Export via OTLP + Prometheus adapter. Hook into existing inspector/error hooks. |
| 9 | Managed background services (`IHostedService`-style) | ASP.NET hosted services provide supervised long-running tasks with cooperative shutdown and lifecycle ordering. | Add `app.addHostedService(service)` where service has `start(ctx)` and `stop(deadline)`; include cancellation token, health state, restart/backoff policy. Integrate with existing startup/shutdown/plugin lifecycle. |
| 10 | Explicit `cork` write-batching API on HTTP/WS response objects | uWebSockets wrappers expose `cork` to batch writes into fewer syscalls/TLS blocks for lower overhead during multi-write responses. | Expose `res.cork(proc() = ...)` and `ws.cork(proc() = ...)` in high-level API, mapped to underlying socket batching/coalescing. Use as opt-in for complex handlers (headers + chunks + trailers) while preserving existing single-write fast path. |

## High-confidence local gap evidence in repository

- `bodyParser` currently parses URL-encoded forms only (`nim_express/src/nim_express/middlewares/body_parser.nim`).
- Generic extractor enforces only `string|int|bool` (`nim_express/src/nim_express/request.nim`, static assert around line 822).
- No OpenAPI/Swagger/Otel/multipart APIs found in `nim_express/src` and docs by repository search.
- Existing strengths already present (so excluded from gaps): plugin lifecycle, graceful shutdown hooks, WS publish, compression hooks, route groups, diagnostics hooks.

## Primary references used

- Fastify validation/serialization: https://fastify.dev/docs/latest/Reference/Validation-and-Serialization/
- Fastify testing/inject: https://fastify.dev/docs/latest/Guides/Testing/
- Nest OpenAPI: https://docs.nestjs.com/openapi/introduction
- Nest injection scopes: https://docs.nestjs.com/fundamentals/injection-scopes
- Nest pipes / ValidationPipe: https://docs.nestjs.com/pipes
- Nest file upload: https://docs.nestjs.com/techniques/file-upload
- ASP.NET Core minimal API filters: https://learn.microsoft.com/en-us/aspnet/core/fundamentals/minimal-apis/min-api-filters?view=aspnetcore-9.0
- ASP.NET Core rate limiting: https://learn.microsoft.com/en-us/aspnet/core/performance/rate-limit?view=aspnetcore-9.0
- ASP.NET Core OpenAPI overview: https://learn.microsoft.com/en-us/aspnet/core/fundamentals/openapi/overview?view=aspnetcore-9.0
- ASP.NET Core output caching: https://learn.microsoft.com/en-us/aspnet/core/performance/caching/output?view=aspnetcore-10.0
- ASP.NET Core hosted services: https://learn.microsoft.com/en-us/aspnet/core/fundamentals/host/hosted-services?view=aspnetcore-9.0
- Fiber app testing + `app.Test`: https://docs.gofiber.io/api/app/
- Fiber multipart APIs (`FormFile`, `MultipartForm`): https://docs.gofiber.io/api/ctx/
- Fiber limiter middleware: https://docs.gofiber.io/api/middleware/limiter/
- Actix extractors (`FromRequest`): https://docs.rs/actix-web/latest/actix_web/trait.FromRequest.html
- Actix test helpers: https://docs.rs/actix-web/latest/actix_web/test/index.html
- Axum extractors: https://docs.rs/axum/latest/axum/extract/index.html
- Axum route layering: https://docs.rs/axum/latest/axum/routing/struct.Router.html
- Tower `ServiceBuilder` and limit layers: https://docs.rs/tower/latest/tower/builder/struct.ServiceBuilder.html and https://docs.rs/tower/latest/tower/limit/index.html
- Hyper graceful shutdown guide: https://hyper.rs/guides/1/server/graceful-shutdown/
- uWebSockets.js WebSocket/HttpResponse/TemplatedApp APIs (`cork`, pub/sub):
  - https://unetworking.github.io/uWebSockets.js/generated/interfaces/WebSocket.html
  - https://unetworking.github.io/uWebSockets.js/generated/interfaces/HttpResponse.html
  - https://unetworking.github.io/uWebSockets.js/generated/interfaces/TemplatedApp.html
- Express ecosystem multipart baseline (Multer): https://github.com/expressjs/multer
