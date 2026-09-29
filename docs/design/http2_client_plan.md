# nim_fasthttpclient — High-Performance HTTP Client

## Overview

A new standalone Nim package providing HTTP/1.1, HTTP/2, SSE, and WebSocket client capabilities built on the same uSockets foundation as the server. Designed for maximum throughput and minimum latency.

## Architecture

### uSockets Integration

uSockets provides the perfect foundation for a client via:
- `us_socket_context_connect(ssl, ctx, host, port, sourceHost, options, extSize)` — outbound TCP connections
- `us_socket_context_on_data` — receive data callbacks
- `us_socket_context_on_writable` — backpressure-aware writes
- `us_socket_context_on_close` — connection cleanup
- `us_socket_context_on_open` — connection established
- `us_socket_context_on_connect_error` — connection failure
- SSL support via `UsSocketContextOptions` (cert, key, CA)
- Timer API for timeouts and keepalive

The client will share the same `uSockets.a` static library and event loop as the server, enabling in-process client calls with zero serialization overhead.

### Module Layout

```
nim_fasthttpclient/
├── src/
│   └── nim_fasthttpclient/
│       ├── client.nim          # Main client API, connection pooling
│       ├── http1.nim           # HTTP/1.1 request/response framing
│       ├── http2.nim           # HTTP/2 framing, stream multiplexing
│       ├── hpack.nim           # HPACK header compression (RFC 7541)
│       ├── h2_frames.nim       # HTTP/2 frame types and parsing (RFC 7540)
│       ├── ws_client.nim       # WebSocket client (RFC 6455)
│       ├── sse_client.nim      # Server-Sent Events client
│       ├── connection_pool.nim # Connection pool with keepalive
│       ├── dns_cache.nim       # DNS resolution cache
│       └── types.nim           # Shared types
├── tests/
│   ├── test_http1.nim
│   ├── test_http2.nim
│   ├── test_hpack.nim
│   ├── test_ws_client.nim
│   └── test_sse_client.nim
└── nim_fasthttpclient.nimble
```

## Protocol Support

### HTTP/1.1
- Persistent connections (keepalive)
- Chunked transfer encoding
- Pipelining (optional)
- Automatic redirect following
- Cookie jar
- Proxy support (HTTP CONNECT)

### HTTP/2
- ALPN negotiation via TLS (h2) and cleartext upgrade (h2c)
- Stream multiplexing — multiple concurrent requests over one TCP connection
- HPACK header compression with dynamic table
- Flow control (connection and stream level, WINDOW_UPDATE)
- Server push handling (PUSH_PROMISE)
- Priority/dependency (optional, deprecated in RFC 9113)
- PING for keepalive
- GOAWAY for graceful shutdown
- Frame types: DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE, PING, GOAWAY, WINDOW_UPDATE, CONTINUATION

### WebSocket Client
- RFC 6455 handshake (HTTP/1.1 Upgrade)
- Text and binary frames
- Ping/pong keepalive
- Close handshake
- Per-message compression (permessage-deflate, optional)
- Auto-reconnect with exponential backoff

### SSE Client
- `text/event-stream` parsing
- Auto-reconnect with Last-Event-ID
- Event type routing
- Timeout handling

## Performance Targets

- HTTP/1.1: 200k+ req/sec to localhost (single connection, pipelining)
- HTTP/2: 300k+ req/sec to localhost (multiplexed streams)
- WebSocket: 500k+ msg/sec (echo benchmark)
- Memory: < 1KB per idle connection, < 4KB per active stream
- Latency: < 50μs for in-process calls

## Key Design Decisions

1. **Zero-copy parsing** — Response headers parsed in-place from the receive buffer
2. **Pre-allocated buffers** — Per-connection send/recv buffers sized at connection creation
3. **No GC pressure** — ARC memory management, pre-allocated HPACK tables
4. **Callback-based API** — Matches uSockets event-driven model
5. **Connection pooling** — Per-host pool with configurable max connections
6. **DNS caching** — TTL-based DNS cache to avoid repeated lookups

## HPACK Implementation (RFC 7541)

The HPACK codec is the most complex component:
- Static table: 61 pre-defined header entries
- Dynamic table: Bounded FIFO, default 4096 bytes
- Encoding: Indexed, literal with/without indexing, literal never indexed
- Integer encoding: Prefix-coded variable-length integers
- Huffman coding: RFC 7541 Appendix B table (256 entries)

## HTTP/2 Connection Lifecycle

```
Client                              Server
  |--- TCP Connect (+ TLS) ---------->|
  |--- Connection Preface ------------>|  "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + SETTINGS
  |<-- SETTINGS ----------------------|
  |--- SETTINGS ACK ----------------->|
  |<-- SETTINGS ACK ------------------|
  |--- HEADERS (stream 1) ----------->|  :method, :path, :scheme, :authority
  |<-- HEADERS (stream 1) ------------|  :status, content-type
  |<-- DATA (stream 1) ---------------|  response body
  |--- HEADERS (stream 3) ----------->|  concurrent request
  |<-- HEADERS (stream 3) ------------|
  |<-- DATA (stream 3) ---------------|
  |--- GOAWAY ----------------------->|  graceful close
```

## Dependencies

- `uSockets.a` — shared with nim_usockets (event loop, TLS, TCP)
- `zippy` or `libdeflate` — for HTTP compression (gzip/deflate/brotli)
- No other external dependencies
