# HTTP Fuzz/Compliance Report (Nim Stack)

Date: 2026-03-10

## Scope
- Added/expanded tests only (no runtime refactors) in:
  - `nim_usockets/tests/test_http_parser_framing_compliance.nim`
  - `nim_usockets/tests/test_http_ws_safety_regressions.nim`
  - `nim_express/tests/test_http_surface_compliance.nim`

## Local fuzz/compliance inspiration used
- `analysis/tmp/uWebSockets/fuzzing/Http.cpp`
  - chunk-wise feed model (`makeChunked(... consumePostPadded ...)`)
- `analysis/tmp/uWebSockets/fuzzing/helpers.h`
  - post-padding and chunked input slicing patterns
- `analysis/tmp/uWebSockets/fuzzing/EpollHelloWorld.dict`
  - HTTP/WebSocket token seeds (`get`, `post`, `http/1.1`, `upgrade: websocket`, websocket key/version headers)

Direct corpus copy was not used because the seed corpus is mostly hashed binary artifacts; equivalent deterministic vectors were implemented in Nim tests.

## Coverage added

### 1) Request line parsing edge cases
- malformed spacing (`GET/ HTTP/1.1`, `GET  HTTP/1.1`)
- invalid version token (`HTTP/9.9` => 505)
- LF-only separators treated as incomplete framing (not false hard-error)

### 2) Method token strictness
- case-sensitive unrecognized token (`get` => 501)
- extension token still unknown (`PRI*` => 501)
- invalid token bytes/control separators (`B@D`, `GE\tT` => 400)

### 3) Invalid/overflow Content-Length
- mismatched duplicate `Content-Length` rejected
- invalid numeric forms (`+10`, empty) rejected
- overflow-length rejected
- matching duplicate `Content-Length` accepted

### 4) Header folding / duplicate headers expectations
- obs-fold style continuation line rejected
- duplicate `Host` rejected for HTTP/1.1
- duplicate `Host` tolerated for HTTP/1.0 behavior path

### 5) Chunked framing correctness
- valid chunked body with extension + trailer parsed and decoded (`Wikipedia`)
- malformed chunk size rejected
- truncated chunked body remains incomplete (non-crashing, no false hard-error)
- transfer-coding order/finality enforcement:
  - `chunked, gzip` => 400
  - `gzip, chunked` => 501

### 6) Connection-close semantics with pending writes
- overload close policy matrix expanded (`shouldCloseAfterOverloadWrite`)
- pending stream close intent validated:
  - close-after-write is not latched mid-stream
  - close-after-write latches only on finishing chunk append

### 7) Pipelining / framing boundary safety
- declared `Content-Length` body excludes pipelined next request bytes
- chunked request consumes exact framed bytes and allows parsing next pipelined request via offset

### 8) WebSocket handshake edge cases in HTTP layer
- valid handshake path accepted (`101`)
- unsupported WS version returns `426` and `Sec-WebSocket-Version: 13`
- invalid websocket key rejected (`400`)
- missing `Connection: upgrade` token prevents `isWebSocketUpgrade`

### 9) nim_express surface compliance guards
- RFC token-based header-name sanitizer assertions
- response-splitting byte rejection in header values (`CR`, `LF`, `NUL`)
- `Response.set` ignores unsafe header names/values and preserves safe values

## Test commands and outcomes

1. `nim c -r -d:nimUwebsocketsTest --path:src --passL:"../nim_usockets/usockets/uSockets.a -framework CoreFoundation -L/opt/homebrew/lib -ljemalloc" tests/test_http_parser_framing_compliance.nim`
- Result: PASS (14/14 tests in suite)

2. `nim c -r -d:nimUwebsocketsTest --path:src --passL:"../nim_usockets/usockets/uSockets.a -framework CoreFoundation -L/opt/homebrew/lib -ljemalloc" tests/test_http_ws_safety_regressions.nim`
- Result: PASS (21/21 tests in suite)

3. `nim c -r --path:nim_express/src --path:nim_usockets/src --passL:"/nim_usockets/usockets/uSockets.a -framework CoreFoundation -L/opt/homebrew/lib -ljemalloc" nim_express/tests/test_http_surface_compliance.nim`
- Result: PASS (3/3 tests in suite)

## Residual gaps
- Tracked in `analysis/http_fuzz_todo_items.json`.
