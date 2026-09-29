# uWebSockets deep analysis (uNetworking/uWebSockets)

Analyzed repository: `https://github.com/uNetworking/uWebSockets`  
Clone path: `/analysis/tmp/uWebSockets`  
Analyzed commit (shallow clone HEAD): `9824ecc9497fefd144b551e55f4e39dc99e8c2fb`

## Architecture and execution model

- `TemplatedApp` is a builder facade over one `HttpContext` plus on-demand `WebSocketContext`s; routing, WS behavior, and listen/run wiring are configured here (`src/App.h:83`, `src/App.h:232`, `src/App.h:285`, `src/App.h:545`, `src/App.h:649`).
- Core execution is callback-driven from uSockets context hooks:
  - HTTP: `on_data`, `on_writable`, `on_close`, `on_timeout` in `HttpContext` (`src/HttpContext.h:89`, `src/HttpContext.h:111`, `src/HttpContext.h:330`, `src/HttpContext.h:386`).
  - WebSocket: analogous hooks in `WebSocketContext` (`src/WebSocketContext.h:286`, `src/WebSocketContext.h:326`, `src/WebSocketContext.h:254`, `src/WebSocketContext.h:390`).
- Loop model is strict per-thread ownership:
  - lazily created thread-local loop (`src/Loop.h:113`, `src/Loop.h:145`);
  - explicit cross-thread transfer only via `Loop::defer` queue + wakeup (`src/Loop.h:39`, `src/Loop.h:203`, `src/Loop.h:208`, `src/Loop.h:211`).
- Loop lifecycle also runs pre/post handlers for shared structures (notably pub/sub drain/maintenance) (`src/Loop.h:58`, `src/Loop.h:66`, `src/App.h:355`, `src/App.h:360`).
- Manual states are kept close to hot paths (bitfields/flags and explicit transitions) instead of heavy abstractions (`src/HttpResponseData.h:67`, `src/HttpContextData.h:50`, `src/WebSocketData.h:39`).

## Request parse/routing pipeline and optimizations

- Parser entrypoint is `consumePostPadded`, with deep parse in `fenceAndConsumePostPadded`; it uses post-padding sentinels to allow bounded scanning and reduce boundary checks (`src/HttpParser.h:618`, `src/HttpParser.h:477`, `src/HttpParser.h:485`).
- Header parsing is tuned for low branch cost:
  - word-level byte-class tests (`hasLess/hasMore/hasBetween`) (`src/HttpParser.h:220`, `src/HttpParser.h:224`, `src/HttpParser.h:228`);
  - fast in-place lowercase and token validation (`src/HttpParser.h:249`, `src/HttpParser.h:264`, `src/HttpParser.h:286`).
- Duplicate/required header logic:
  - Bloom filter pre-check for fast membership (`src/HttpParser.h:67`, `src/HttpParser.h:504`, `src/BloomFilter.h:25`);
  - duplicate `host` rejection + mandatory `host` enforcement (`src/HttpParser.h:506`, `src/HttpParser.h:514`).
- Framing safety:
  - explicit `transfer-encoding` vs `content-length` handling (`src/HttpParser.h:523`, `src/HttpParser.h:546`);
  - bounded fallback accumulation (`MAX_FALLBACK_SIZE`) with error on overflow (`src/HttpParser.h:51`, `src/HttpParser.h:716`).
- URL/query extraction is computed once per request (`src/HttpParser.h:533`, `src/HttpParser.h:534`).
- Router structure is a method-rooted segment tree with handler priority embedding:
  - priorities (`HIGH/MEDIUM/LOW`) and wildcard/param/static ordering (`src/HttpRouter.h:39`, `src/HttpRouter.h:67`, `src/HttpRouter.h:93`);
  - normalized parameter node `:` and sorted insertion (`src/HttpRouter.h:297`, `src/HttpRouter.h:303`);
  - method ordering (`GET` first, `*` last) (`src/HttpRouter.h:308`, `src/HttpRouter.h:312`).
- Runtime request path in `HttpContext`:
  - socket cork before parse (`src/HttpContext.h:129`);
  - one pending response rule to avoid async pipelining mixups (`src/HttpContext.h:153`, `src/HttpContext.h:155`);
  - dispatch by selected router and hard fail on missing route (`src/HttpContext.h:177`, `src/HttpContext.h:181`).
- Documentation explicitly states specificity-based route matching (static > param > wildcard), matching the priority design (`misc/READMORE.md:70`, `misc/READMORE.md:72`, `misc/READMORE.md:73`, `misc/READMORE.md:74`).

## Response write/backpressure strategy

- Response state machine is centralized in `HttpResponse::internalEnd` (`src/HttpResponse.h:92`):
  - chooses fixed length or chunked based on prior `write()` usage (`src/HttpResponse.h:118`, `src/HttpResponse.h:157`, `src/HttpResponse.h:458`);
  - tracks write offset and completion (`src/HttpResponse.h:183`, `src/HttpResponse.h:480`);
  - exposes `tryEnd()` with `{ok, hasResponded}` semantics (`src/HttpResponse.h:441`).
- Async hooks for progressive writes and abort safety are explicit (`src/HttpResponse.h:555`, `src/HttpResponse.h:563`, `src/HttpResponse.h:571`).
- `markDone()` clears response-pending and writable/aborted hooks to prevent stale events (`src/HttpResponseData.h:37`, `src/HttpResponseData.h:40`, `src/HttpResponseData.h:43`).
- Transport write path (`AsyncSocket::write`) is three-tier:
  1. drain existing user-space backpressure;
  2. opportunistic cork-buffer path;
  3. syscall path with fallback buffering (`src/AsyncSocket.h:236`, `src/AsyncSocket.h:248`, `src/AsyncSocket.h:292`, `src/AsyncSocket.h:296`, `src/AsyncSocket.h:327`).
- Backpressure buffer compaction is incremental via `pendingRemoval` to reduce memmove frequency (`src/AsyncSocketData.h:27`, `src/AsyncSocketData.h:36`, `src/AsyncSocketData.h:39`).
- Connection close semantics are delayed until response complete and buffered bytes are drained (`src/HttpContext.h:284`, `src/HttpContext.h:286`, `src/HttpResponse.h:137`, `src/HttpResponse.h:204`).

## Memory/allocation optimizations

- Fixed-size request header storage avoids per-header allocations on hot path (`UWS_HTTP_MAX_HEADERS_COUNT`) (`src/HttpParser.h:52`, `src/HttpParser.h:63`).
- Fallback parser buffer is bounded and reused (`src/HttpParser.h:198`, `src/HttpParser.h:658`, `src/HttpParser.h:664`).
- Per-loop shared cork buffer (`16 KB`) and date cache avoid repeated allocations/builds (`src/LoopData.h:97`, `src/LoopData.h:99`, `src/LoopData.h:89`, `src/HttpResponse.h:79`).
- Compression memory can be shared per loop or dedicated per socket, selected by options:
  - option encoding (`src/PerMessageDeflate.h:29`, `src/PerMessageDeflate.h:41`, `src/PerMessageDeflate.h:51`);
  - dedicated stream allocation in `WebSocketData` only when requested (`src/WebSocketData.h:48`, `src/WebSocketData.h:61`, `src/WebSocketData.h:64`).
- Topic fanout avoids copying one message per subscriber by storing message indices (`uint16_t`) per subscriber and draining later (`src/TopicTree.h:59`, `src/TopicTree.h:64`, `src/TopicTree.h:103`, `src/TopicTree.h:338`).

## Concurrency and scaling model

- Design intent is single-threaded per app/loop, not generally thread-safe (`misc/READMORE.md:29`, `misc/READMORE.md:179`, `misc/READMORE.md:227`).
- README usage guidance is "one app per thread" and share listen port where supported (`README.md:30`).
- Cross-thread coordination primitive is `Loop::defer` (queue + loop wakeup) (`src/Loop.h:203`, `src/Loop.h:211`).
- There is an experimental local cluster/adopt model using `preOpen` + round-robin `adoptSocket` on other loops (`src/LocalCluster.h:41`, `src/LocalCluster.h:45`; also `src/App.h:604`, `src/App.h:622`, `src/App.h:644`).
- Upstream docs note uSockets supports multiple event-loop backends (libuv/ASIO/GCD/epoll/kqueue) as compile-time composition (`README.md:74`, `README.md:78`, `README.md:79`).

## WebSocket-specific optimizations

- Handshake generation uses internal SHA-1 + Base64 routine to compute `Sec-WebSocket-Accept` (`src/WebSocketHandshake.h:91`, `src/WebSocketHandshake.h:101`, `src/WebSocketHandshake.h:116`, `src/HttpResponse.h:249`, `src/HttpResponse.h:254`).
- Frame parser is a state machine with spill/continuation handling:
  - `wantsHead`, `spillLength`, `remainingBytes` (`src/WebSocketProtocol.h:67`, `src/WebSocketProtocol.h:68`, `src/WebSocketProtocol.h:86`);
  - consume split between `consumeMessage`, `consumeContinuation`, `consume` (`src/WebSocketProtocol.h:359`, `src/WebSocketProtocol.h:424`, `src/WebSocketProtocol.h:477`).
- Unmask path is aggressively optimized (templated unrolled XOR + bulk 8-byte operations) (`src/WebSocketProtocol.h:296`, `src/WebSocketProtocol.h:304`, `src/WebSocketProtocol.h:418`).
- UTF-8 and close-payload validation are built into protocol layer (`src/WebSocketProtocol.h:122`, `src/WebSocketProtocol.h:183`, `src/WebSocketProtocol.h:190`).
- Backpressure-aware send behavior:
  - hard max backpressure limit with drop/close behavior (`src/WebSocket.h:118`, `src/WebSocket.h:121`, `src/WebSocket.h:130`);
  - special long-message fast path for non-SSL/non-compressed sends (`src/WebSocket.h:137`).
- Pub/sub integration is synchronized with socket send path (`topicTree->drain` before send for subscribers) (`src/WebSocket.h:133`, `src/WebSocket.h:160`).
- Idle timeout uses staged ping then close:
  - on timeout, send ping and shorten timeout;
  - if still timed out, force close (`src/WebSocketContext.h:390`, `src/WebSocketContext.h:395`, `src/WebSocketContext.h:397`, `src/WebSocketContext.h:405`).
- Compression negotiation and browser-specific safeguards:
  - permessage-deflate negotiation at upgrade (`src/HttpResponse.h:266`, `src/HttpResponse.h:303`);
  - Safari 15.0-15.3 compression workaround (`src/App.h:28`, `src/App.h:426`).

## Notable implementation techniques with code pointers

1. Parse fencing via post-padding sentinels to keep scanning tight and bounded (`src/HttpParser.h:485`).
2. Branch-minimized HTTP field-name parser with in-place lowercase (`src/HttpParser.h:249`, `src/HttpParser.h:264`).
3. Header duplicate detection accelerated by a small custom Bloom filter (`src/HttpParser.h:504`, `src/BloomFilter.h:25`).
4. Router specificity encoded as handler priority bits and child ordering (`src/HttpRouter.h:39`, `src/HttpRouter.h:93`, `src/HttpRouter.h:303`).
5. Explicit denial of async pipelining (single pending request per connection) to simplify correctness (`src/HttpContext.h:153`, `src/HttpContext.h:155`).
6. One-loop-one-cork-buffer invariant, with fatal check if cork leaks across loop iterations (`src/Loop.h:70`, `src/Loop.h:72`).
7. Backpressure buffer lazy-compaction (`pendingRemoval`) to amortize erase costs (`src/AsyncSocketData.h:36`, `src/AsyncSocketData.h:39`).
8. WebSocket parser split between head/continuation modes with spill alignment (`src/WebSocketProtocol.h:67`, `src/WebSocketProtocol.h:424`, `src/WebSocketProtocol.h:478`).
9. Topic fanout by index indirection (`messageIndices`) instead of N payload copies (`src/TopicTree.h:59`, `src/TopicTree.h:338`).
10. Per-loop shared compression streams with optional per-socket dedicated streams (`src/LoopData.h:104`, `src/WebSocketData.h:61`).

## Transferable learnings for nim_express / nim_usockets (P0/P1/P2)

### P0 (high value / likely immediate impact)

1. Replace O(n) dynamic route scan with trie-based method+segment dispatch (uWS `HttpRouter` model).
   - uWS reference: `src/HttpRouter.h:257`, `src/HttpRouter.h:282`, `src/HttpRouter.h:168`.
   - Current Nim state: dynamic paths still scan route arrays (`nim_express/src/nim_express/app.nim:771`, `nim_express/src/nim_express/app.nim:786`).
   - Why P0: route count growth will directly increase matching cost despite fast rejects.

2. Add cork-style per-loop write batching for mixed header/body + WS framing paths (not only queue coalescing).
   - uWS reference: `src/AsyncSocket.h:133`, `src/AsyncSocket.h:155`, `src/LoopData.h:99`, `misc/READMORE.md:91`.
   - Current Nim state: strong queue/coalescing exists (`nim_usockets/src/nim_usockets/http.nim:1125`, `nim_usockets/src/nim_usockets/http.nim:1156`) but no explicit cork primitive (`rg cork|uncork` found none).
   - Why P0: can reduce syscall count in hot synchronous response paths and WS fanout bursts.

### P1 (important, medium complexity)

1. Move HTTP request metadata closer to zero-copy views in hot path.
   - uWS reference: request headers/URL stay as `string_view` over parser buffer (`src/HttpParser.h:63`, `src/HttpParser.h:126`, `src/HttpParser.h:135`).
   - Current Nim state: many headers/parts are copied into strings during parse (`nim_usockets/src/nim_usockets/http.nim:2068`, `nim_usockets/src/nim_usockets/http.nim:2075`).
   - Why P1: lower allocation churn and GC pressure under high request rates.

2. Adopt stricter duplicate-header checks (especially `Host`) and cheap pre-filtering strategy.
   - uWS reference: Bloom pre-check + duplicate `host` rejection (`src/HttpParser.h:504`, `src/HttpParser.h:506`, `src/HttpParser.h:514`).
   - Current Nim state: hot-header classification and flags exist, but duplicate-host hard rejection is not obvious in current parser flow (`nim_usockets/src/nim_usockets/http.nim:1836` onward).
   - Why P1: improves RFC hardening and request-smuggling resistance margin.

3. Rework WS pub/sub fanout to index-and-drain model for bursty topics.
   - uWS reference: `TopicTree` deferred fanout with per-subscriber index queues (`src/TopicTree.h:100`, `src/TopicTree.h:338`, `src/TopicTree.h:270`).
   - Current Nim state: topic subscribers are `seq[WebSocket]` lists (`nim_usockets/src/nim_usockets/http.nim:290`, `nim_usockets/src/nim_usockets/http.nim:590`).
   - Why P1: better behavior under large fanout and uneven subscriber backpressure.

### P2 (nice to have / strategic)

1. Consider optional strict “single pending request per connection” mode for simpler async correctness.
   - uWS reference: explicit close when a new request arrives while previous response pending (`src/HttpContext.h:155`).
   - Current Nim state: supports pipelined pending response queues (`nim_usockets/src/nim_usockets/http.nim:330`, `nim_usockets/src/nim_usockets/http.nim:3954`).
   - Why P2: potential simplification mode for services prioritizing predictability over pipelining throughput.

2. Push WS frame handling further toward in-place processing where API permits.
   - uWS reference: parser consumes/mutates frame memory and only materializes when needed (`src/WebSocketProtocol.h:359`, `src/WebSocketContext.h:60`).
   - Current Nim state: masked payload is always decoded into new string (`nim_usockets/src/nim_usockets/http.nim:3280`).
   - Why P2: further reduces allocation rate for high-frequency small frames.

## Risks/tradeoffs if adopted

- Trie router migration may alter route precedence semantics. `nim_express` currently preserves registration order in mixed exact/dynamic cases; uWS favors specificity. This must be an explicit compatibility decision.
- Cork-style buffering improves throughput but increases complexity around lifetime/ownership and can create subtle flush-order bugs if not tightly guarded.
- More zero-copy request/message views can expose lifetime hazards (user callbacks holding references beyond parse buffer validity).
- Stricter RFC validation (duplicate header rejection, framing hard-fail) may break permissive legacy clients.
- TopicTree-like deferred fanout reduces copy cost but introduces scheduler coupling (drain phase ordering) and more complex backpressure interactions.
- Optional single-pending-request mode can reduce pipelining throughput on clients that legitimately pipeline.

## Brief completion summary

- Completed a shallow clone analysis of upstream uWebSockets at commit `9824ecc`.
- Read core architecture/docs and hot-path sources (`App`, `HttpContext`, `HttpParser`, `HttpRouter`, `HttpResponse`, `AsyncSocket`, `WebSocket*`, `TopicTree`, `Loop`).
- Produced an implementation-focused report with concrete code pointers, plus prioritized P0/P1/P2 transfer recommendations and adoption tradeoffs for `nim_express`/`nim_usockets`.
