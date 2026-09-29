# HTTP/2 Feasibility Plan for nim_usockets + nim_express

## Goals
- Add HTTP/2 without regressing HTTP/1.1 fast path.
- Keep protocol handling modular: stream scheduler, HPACK, flow-control, framing.
- Preserve existing request/response and middleware APIs for initial phase.

## Non-goals (Phase 1)
- No server push.
- No priority tree parity with browsers beyond weighted FIFO.
- No transparent HTTP/1<->HTTP/2 upgrade on cleartext (`h2c`) by default.

## Architecture split
1. Connection layer:
- Detect ALPN `h2` on TLS listeners.
- Route ALPN `h2` sockets into HTTP/2 state machine.

2. Stream layer:
- Stream table indexed by stream id.
- Per-stream read/write window accounting.
- Stream lifecycle states (idle/open/half-closed/closed).

3. Scheduler:
- Per-connection write queue with fairness budget.
- Small-control-frame priority over data frames.
- Weighted round-robin among active streams.

4. Header compression:
- HPACK dynamic table with max size guard.
- Size-limited header decode to prevent memory abuse.

## Phased milestones
### Milestone A (spike)
- Minimal frame parser/serializer.
- SETTINGS handshake + WINDOW_UPDATE + HEADERS + DATA.
- Hard cap concurrent streams.

### Milestone B (alpha)
- Request mapping from HEADERS/DATA to existing handler surface.
- Response mapping from handler output to HEADERS/DATA.
- Stream-level flow control and connection flow control.

### Milestone C (beta)
- HPACK dynamic table optimizations.
- Better stream scheduler fairness under mixed stream sizes.
- Load tests against h2load/nghttp2.

### Milestone D (ga candidate)
- Exhaustive RFC compliance tests for frame sequencing and error codes.
- HTTP/1.1 performance guardrail check in CI.

## Prototype spike checklist
- Implement `H2ConnState` + `H2StreamState` structs.
- Implement a frame decode loop with bounded frame size.
- Implement a scheduler prototype with:
  - per-stream queue
  - bytes/request budget per loop tick
  - control-frame fast lane

## HTTP/1 guardrails
- Keep current HTTP/1 parser and write path untouched.
- Compile-gate HTTP/2 with feature flag until alpha stable.
- Add benchmark threshold checks:
  - `/plaintext` req/s drop <= 2%
  - `/json` req/s drop <= 2%

## Validation matrix
- Functional: nghttp2 integration, malformed frame tests, flow-control tests.
- Performance: h2load mixed stream sizes, concurrent connections, tail latency.
- Regression: existing wrk suite for HTTP/1.
