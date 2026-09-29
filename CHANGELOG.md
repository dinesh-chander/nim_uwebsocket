# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-04-10

### Added
- Express-style web framework (`nim_express`) with routing, middleware pipeline, and scaling
- Low-level uSockets FFI bindings (`nim_usockets`) with HTTP/1.1, HTTP/2, and WebSocket support
- HTTP/2 server with HPACK header compression, flow control, and stream management
- HTTP/1.1 and HTTP/2 client library (`nim_fasthttpclient`) with connection pooling
- Shared utilities (`nim_utils`) including fast_map, nim_fastjson, and simdjson bindings
- 36 built-in middlewares: CORS, compression, rate limiting, helmet, CSRF, session, Prometheus, OpenTelemetry, circuit breaker, graceful shutdown, health checks, proxy, and more
- WebSocket support with RFC 6455 compliance, per-message compression, pub/sub topics, and backpressure
- Server-Sent Events (SSE) streaming
- SIMD-accelerated HTTP parsing (NEON on ARM64, SSE2 on x86_64)
- Adaptive write coalescing with 4 modes (latency, balanced, throughput, adaptive)
- Adaptive overload protection with AIMD controller and fairness budgets
- Body spill-to-disk for large payloads
- Object pools for zero-GC-pressure request handling
- Configuration via JSON files, environment variables, and named profiles
- Docker and Docker Compose support
- TLS support via OpenSSL or BoringSSL
- Multi-process (`runCluster`) and multi-threaded (`runThreaded`) scaling
- 71 test files with ~485+ test cases including fuzz testing
- GitHub Actions CI for Linux and macOS
- 15+ example applications

### Security
- Defect recovery middleware with `--panics:off` support
- Slowloris protection via header/body read timeouts (30s defaults)
- SSRF protection in proxy middleware (private IP blocklist)
- CONNECT/TRACE method blocking in proxy
- Log injection prevention via sanitizeLogField
- RFC 7807 Problem Details error responses (no stack traces in production)
- Per-connection memory budgets (32MB default)
- Request size limits (headers 16KB, body 10MB, URI 8KB)
