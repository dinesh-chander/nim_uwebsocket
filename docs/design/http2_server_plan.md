# HTTP/2 Server Support in nim_usockets/http.nim

## Overview

Add HTTP/2 support to the existing HTTP server in `nim_usockets/http.nim`. The server will auto-detect HTTP/2 via ALPN (TLS) or the h2c upgrade mechanism (cleartext), and handle both HTTP/1.1 and HTTP/2 connections on the same port.

## Architecture

### uSockets Foundation

The existing uSockets integration already provides everything needed:
- `us_socket_context_listen` — accept incoming connections (unchanged)
- `onSocketData` callback — receives raw bytes; will branch to HTTP/1.1 or HTTP/2 parser
- `us_socket_write` / `us_socket_write2` — send frames (DATA, HEADERS, etc.)
- `onWritable` — backpressure handling for flow control
- SSL support — ALPN negotiation for `h2` protocol
- Socket ext data — per-connection state (H2Connection struct)
- Timer API — PING/PONG keepalive, idle connection timeout

### Integration with Existing Code

The HTTP/2 code will be added as a new layer in `http.nim` alongside the existing HTTP/1.1 parser:

```
onSocketData(socket, data)
  ├── if connection.isHttp2:
  │     parseH2Frames(data)  →  dispatchStream()  →  handler(req, res)
  └── else:
        parseHttp1(data)     →  handler(req, res)
```

The `Request` and `Response` types from `nim_express` remain unchanged — HTTP/2 streams are mapped to the same handler interface.

## Components to Add to http.nim

### 1. H2 Connection State (~300 lines)

```nim
type
  H2Stream = object
    id: uint32
    state: H2StreamState  # idle, open, halfClosedLocal, halfClosedRemote, closed
    recvWindowSize: int32
    sendWindowSize: int32
    headers: seq[(string, string)]
    bodyBuf: string
    contentLength: int64
    request: Request
    response: Response

  H2Connection = object
    streams: Table[uint32, H2Stream]
    hpackDecoder: HpackDecoder
    hpackEncoder: HpackEncoder
    nextStreamId: uint32
    settings: H2Settings
    peerSettings: H2Settings
    recvWindowSize: int32
    sendWindowSize: int32
    gotPreface: bool
    gotSettings: bool
    headerBuf: string  # for CONTINUATION frames

  H2Settings = object
    headerTableSize: uint32      # SETTINGS_HEADER_TABLE_SIZE (4096)
    enablePush: bool             # SETTINGS_ENABLE_PUSH (1)
    maxConcurrentStreams: uint32  # SETTINGS_MAX_CONCURRENT_STREAMS (100)
    initialWindowSize: uint32    # SETTINGS_INITIAL_WINDOW_SIZE (65535)
    maxFrameSize: uint32         # SETTINGS_MAX_FRAME_SIZE (16384)
    maxHeaderListSize: uint32    # SETTINGS_MAX_HEADER_LIST_SIZE (unlimited)
```

### 2. HPACK Codec (~500 lines)

Shared with the client — can be extracted to a separate module `hpack.nim`:
- Static table (61 entries from RFC 7541)
- Dynamic table with bounded size
- Integer decoding/encoding with prefix
- Huffman decoding/encoding (256-entry table)
- Header field representations: indexed, literal, never indexed

### 3. Frame Parser (~400 lines)

```nim
type
  H2FrameType = enum
    ftData = 0, ftHeaders = 1, ftPriority = 2, ftRstStream = 3,
    ftSettings = 4, ftPushPromise = 5, ftPing = 6, ftGoaway = 7,
    ftWindowUpdate = 8, ftContinuation = 9

  H2Frame = object
    length: uint32       # 24-bit payload length
    frameType: uint8
    flags: uint8
    streamId: uint32     # 31-bit stream identifier

# Frame header is 9 bytes: length(3) + type(1) + flags(1) + reserved(1bit) + streamId(31bits)
```

### 4. Stream Multiplexing (~300 lines)

- Stream lifecycle management (RFC 7540 §5.1 state machine)
- Concurrent stream limit enforcement
- Stream priority (optional, basic implementation)
- RST_STREAM for cancellation

### 5. Flow Control (~200 lines)

- Connection-level and stream-level windows
- WINDOW_UPDATE frame generation
- Backpressure integration with existing `onWritable` callback

### 6. H2 Detection and Negotiation (~100 lines)

Two paths:
1. **ALPN (TLS)**: uSockets SSL context negotiates `h2` protocol. After TLS handshake, check negotiated protocol.
2. **h2c (cleartext)**: Detect `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` connection preface (24 bytes) as the first bytes on the connection.

## HTTP/2 Connection Lifecycle (Server Side)

```
Client                              Server
  |--- Connection Preface ------------>|  Detect "PRI *" or ALPN h2
  |<-- SETTINGS ----------------------|  Send server settings
  |--- SETTINGS ---------------------->|  Receive client settings
  |--- SETTINGS ACK ----------------->|
  |<-- SETTINGS ACK ------------------|
  |--- HEADERS [stream 1, END_HEADERS, END_STREAM] -->|
  |                                    |  Decode HPACK headers
  |                                    |  Map to Request object
  |                                    |  Call handler(req, res)
  |<-- HEADERS [stream 1, END_HEADERS] |  Encode response headers
  |<-- DATA [stream 1, END_STREAM] ---|  Send response body
  |--- HEADERS [stream 3] ----------->|  Next request (odd stream IDs)
  |--- HEADERS [stream 5] ----------->|  Concurrent request
  |<-- HEADERS + DATA [stream 3] -----|
  |<-- HEADERS + DATA [stream 5] -----|
  |--- GOAWAY ----------------------->|  Client initiates close
  |<-- GOAWAY ------------------------|  Server acknowledges
```

## Mapping to Express API

HTTP/2 is transparent to Express handlers:

```nim
app.get("/api/data") do (req: Request, res: Response):
  # Same handler works for HTTP/1.1 and HTTP/2
  # req.httpVersion will be "2.0"
  # req.headers works the same (decoded from HPACK)
  # res.json(), res.text(), etc. work the same
  res.json(%*{"hello": "world"})
```

Differences visible to handlers:
- `req.httpVersion` = `"2.0"`
- `req.protocol` = `"h2"` or `"h2c"`
- Pseudo-headers (`:method`, `:path`, `:scheme`, `:authority`) mapped to standard fields
- No chunked encoding (HTTP/2 uses DATA frames with length)
- Server push via `res.push("/style.css")` (new API)

## Performance Targets

- HTTP/2 should match or exceed HTTP/1.1 throughput for single-stream requests
- Stream multiplexing: handle 100+ concurrent streams per connection
- HPACK encode/decode: < 1μs per header block (pre-warmed dynamic table)
- Frame overhead: 9 bytes per frame (minimal compared to HTTP/1.1 headers)
- Memory per H2 connection: < 32KB (HPACK tables + stream state)

## Implementation Phases

### Phase 1: Core Protocol
- H2 frame parser and serializer
- HPACK codec
- Connection preface handling
- SETTINGS exchange
- Single-stream request/response

### Phase 2: Multiplexing & Flow Control
- Multi-stream support
- Flow control (WINDOW_UPDATE)
- Stream state machine
- Concurrent stream limits

### Phase 3: Integration
- ALPN negotiation in TLS
- h2c cleartext upgrade
- Express handler mapping
- Server push API

### Phase 4: Optimization
- Zero-copy header access
- Pre-encoded common headers
- Huffman encode/decode tables as compile-time constants
- Frame coalescing (multiple frames in single write)

## Dependencies

- Same `uSockets.a` library (no additional C dependencies)
- OpenSSL for ALPN support (already linked for TLS)
- No external HTTP/2 libraries — pure Nim implementation
