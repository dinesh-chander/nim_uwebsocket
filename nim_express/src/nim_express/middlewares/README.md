# Middleware Modules

This directory contains the built-in middleware surface for `nim_express`.

`nim_express/src/nim_express/middlewares.nim` re-exports the hub-backed modules below. The remaining modules in this folder are usable, but require direct imports such as `import nim_express/src/nim_express/middlewares/error_handler`.

## Exported Via Hub

| Module | Purpose | Main API | Status |
|---|---|---|---|
| [common.nim](./common.nim) | Shared middleware types and request/response helpers | `Req`, `Res`, `AsyncMiddleware`, `SyncNextMiddleware` | Exported by hub |
| [logger.nim](./logger.nim) | Access logging in plain, colored, or JSON-like formats | `logger`, `sanitizeLogField` | Exported by hub |
| [cors.nim](./cors.nim) | Cross-origin response headers and preflight handling | `cors`, `corsSync`, `CorsOptions` | Exported by hub |
| [body_parser.nim](./body_parser.nim) | JSON, text, raw, form, XML, and multipart body parsing | `json`, `text`, `raw`, `urlencoded`, `xml`, `bodyParser` | Exported by hub |
| [cookie_parser.nim](./cookie_parser.nim) | Parse incoming cookies into request locals | `cookieParser` | Exported by hub |
| [rate_limit.nim](./rate_limit.nim) | Fixed-window and preset request throttling | `rateLimit`, `rateLimitPreset` | Exported by hub |
| [helmet.nim](./helmet.nim) | Security headers and CSP controls | `helmet`, `defaultHelmetOptions` | Exported by hub |
| [request_id.nim](./request_id.nim) | Generate or propagate a request id | `requestId` | Exported by hub |
| [health.nim](./health.nim) | Health endpoint and request counting | `health`, `healthRequestCount`, `resetHealthRequestCount` | Exported by hub |
| [compression.nim](./compression.nim) | Response compression and policy tuning | `compression`, `installCompressionPolicy` | Exported by hub |
| [htmx.nim](./htmx.nim) | HTMX request metadata helpers | `htmx` | Exported by hub |
| [etag.nim](./etag.nim) | ETag generation and conditional response handling | `etag`, `generateETag`, `defaultETagOptions` | Exported by hub |
| [method_override.nim](./method_override.nim) | Override HTTP methods from headers, query, or form fields | `methodOverride`, `installMethodOverride` | Exported by hub |
| [multipart.nim](./multipart.nim) | Multipart form and file upload parsing | `multipart`, `MultipartOptions` | Exported by hub |
| [session.nim](./session.nim) | Signed cookie sessions with pluggable storage | `session`, `sessionGet`, `sessionSet`, `destroySession` | Exported by hub |
| [csrf.nim](./csrf.nim) | CSRF token generation and validation | `csrf`, `csrfToken`, `defaultCsrfOptions` | Exported by hub |
| [timeout.nim](./timeout.nim) | Request deadlines and timeout cancellation | `timeout`, `timeoutPreset` | Exported by hub |
| [concurrency_guard.nim](./concurrency_guard.nim) | Cap in-flight requests and reject overload early | `concurrencyGuard`, `newConcurrencyGuardState` | Exported by hub |
| [io_helpers.nim](./io_helpers.nim) | Async file and outbound HTTP helpers | `readFileAsync`, `writeFileAsync`, `fetchAsync`, `postAsync` | Exported by hub |
| [file_helpers.nim](./file_helpers.nim) | File send/download helpers for handlers | `sendFile`, `download`, `getMimeType` | Exported by hub |
| [static_files.nim](./static_files.nim) | Static file serving with cache controls | `serveStatic`, `defaultStaticCacheOptions` | Exported by hub |
| [body_limit.nim](./body_limit.nim) | Reject oversized request bodies | `bodyLimit`, `BodyLimitOptions` | Exported by hub |
| [openapi.nim](./openapi.nim) | Generate and serve OpenAPI docs and Swagger UI | `openapi`, `newOpenApiRegistry`, `documentGet`, `RouteDoc` | Exported by hub |
| [normalize_path.nim](./normalize_path.nim) | Normalize duplicate slashes and trailing slashes | `normalizePath`, `NormalizePathOptions` | Exported by hub |
| [panic_recovery.nim](./panic_recovery.nim) | Convert uncaught exceptions into 500 responses | `panicRecovery`, `PanicRecoveryOptions` | Exported by hub |
| [backpressure.nim](./backpressure.nim) | Shed load when pressure thresholds trip | `backpressure`, `BackpressureOptions`, `newBackpressureState` | Exported by hub |
| [graceful_shutdown.nim](./graceful_shutdown.nim) | Drain in-flight requests during shutdown | `gracefulShutdown`, `GracefulShutdownOptions`, `initiateShutdown` | Exported by hub |
| [server_timing.nim](./server_timing.nim) | Populate `Server-Timing` metadata | `serverTiming`, `ServerTimingOptions` | Exported by hub |
| [global_error_filter.nim](./global_error_filter.nim) | Map exception types to HTTP responses | `globalErrorFilter`, `globalErrorFilterWithBuiltins`, `newExceptionFilter` | Exported by hub |

## Direct Import Only

| Module | Purpose | Main API | Status |
|---|---|---|---|
| [error_handler.nim](./error_handler.nim) | RFC 7807 Problem Details error responses | `errorHandler`, `ErrorHandlerOptions` | Direct import only |
| [ip_filter.nim](./ip_filter.nim) | Allowlist/denylist IP filtering with CIDR support | `ipFilter`, `IpFilterOptions` | Direct import only |
| [json_logger.nim](./json_logger.nim) | NDJSON request logging | `jsonLogger`, `JsonLoggerOptions` | Direct import only |
| [opentelemetry.nim](./opentelemetry.nim) | W3C traceparent propagation and span hooks | `openTelemetry`, `OpenTelemetryOptions` | Direct import only |
| [output_cache.nim](./output_cache.nim) | Response caching with tag invalidation | `outputCache`, `initOutputCachePolicy`, `newOutputCacheStore` | Direct import only |
| [response_time.nim](./response_time.nim) | Add a response timing header | `responseTime`, `ResponseTimeOptions` | Direct import only |

## Notes

- If you import `nim_express/src/nim_express/middlewares`, you get the hub-exported modules only.
- For the direct-import-only modules, import the file explicitly from `middlewares/`.
- The example apps in `../../../../examples/` now cover the requested user-facing scenarios for the direct-import-only modules as well.
