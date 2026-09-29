# Final Non-Redundant Learnings Across Frameworks

This document consolidates unique, non-redundant performance and design learnings from:

- `khttp`
- `ohkami_tokio`
- `hyper`
- `uwebsockets`
- `bun_http`
- `activej`
- `drogon`
- `gofiber`

Only distinct techniques are kept; repeated ideas are merged.

## 1) Core Architecture Learnings

1. Strict engine/framework split
- Keep protocol + socket state machine isolated from framework concerns (routing/middleware/rendering).
- Seen strongly in `hyper`, `uWebSockets`.
- Why it matters: lets transport hot path stay minimal and easier to tune independently.

2. Single-owner event-loop state
- Connection/socket state should be owned by one loop/thread; cross-thread work must be explicit queue+defer.
- Seen in `uWebSockets`, `ActiveJ`, `Drogon/trantor`.
- Why it matters: removes lock contention and race complexity in hot I/O path.

3. Startup compilation of runtime structures
- Build route trees/matcher artifacts at startup (method partitions, segment programs, static-chain compression).
- Seen in `GoFiber`, `Ohkami`, `uWebSockets`, `khttp`.
- Why it matters: request path avoids dynamic parsing/normalization/mutation.

## 2) Parsing and Routing Learnings

4. Byte-oriented parser with bounded state machine
- Parse via manual state transitions and bounded buffers; avoid split/tokenizer-heavy logic.
- Seen in `uWebSockets`, `Drogon`, `ActiveJ`, `Ohkami`.

5. Centralized RFC framing enforcement
- TE/CL precedence and malformed/duplicate header handling must be centralized and strict.
- Seen in `hyper` (strongly), `uWebSockets` (duplicate Host handling), `ActiveJ`.

6. Route lookup should be tiered
- Method bucket -> prefix bucket/hash -> exact literal fast path -> param/wildcard fallback.
- Seen in `GoFiber` (prefix hash buckets), `khttp` (sorted literals), `uWebSockets` (segment trie), `Drogon`.

7. Param parsing should be precompiled
- Parse route pattern once; runtime only executes compiled segment program.
- Seen in `GoFiber`, `Ohkami`.

## 3) Response and Backpressure Learnings

8. Dual write strategy
- Small/known payload: single assembled write.
- Larger payload: segmented/vectored writes with continuation.
- Seen in `khttp`, `hyper`, `Ohkami`, `Drogon`.

9. Explicit progress-based write lifecycle
- Use `tryEnd/onWritable` with offset tracking; never treat partial write as terminal.
- Seen in `uWebSockets`, `Bun`.

10. Cork/batch writes with limits
- Coalesce writes, but keep bounded thresholds to avoid latency spikes and excess copy.
- Seen in `uWebSockets`, `Bun`, `Drogon`.

11. Backpressure as first-class policy
- High-water callbacks + overload policy + close-after-flush semantics.
- Seen in `Drogon/trantor`, `uWebSockets`, `hyper`.

12. Sendfile path with resumable continuation
- For large files/streams, prefer sendfile when transport/platform allows; continue on writable.
- Seen in `Bun`, `Drogon`, `GoFiber`.

## 4) Memory and Allocation Learnings

13. Reuse request context objects aggressively
- Per-connection or pooled request context reuse with explicit reset/release lifecycle.
- Seen in `Ohkami`, `GoFiber`, `Bun`, `Drogon`, `ActiveJ`.

14. Avoid forced copies in common path
- Keep borrowed/slice views where lifetimes are safe; copy only when transitioning to async/extended lifetime.
- Seen in `Ohkami`, `Bun`, `uWebSockets`, `hyper`.

15. Specialized small maps beat generic hash maps in hot metadata paths
- Standard header fast map + tiny custom map, token tables for known headers/methods.
- Seen in `Ohkami`, `ActiveJ`, `uWebSockets`.

16. Buffer pool policy needs observability/eviction
- Slab/pool gives throughput gains, but watchdog/limits are needed to avoid memory growth.
- Seen in `ActiveJ`.

17. Cache cheap-but-frequent generated values
- Cache Date header at second granularity per loop/thread.
- Seen in `khttp`, `hyper`, `uWebSockets`.

## 5) WebSocket-Specific Learnings

18. Fanout should be index-based, not message-copy-per-subscriber
- Store payload once and queue small indices/tickets per subscriber.
- Seen in `uWebSockets` TopicTree.

19. Compression must be policy-driven
- Shared vs dedicated compression streams; tune for CPU/memory/backpressure safety.
- Seen in `uWebSockets`.

20. Idle handling should be staged
- Ping-before-close timeout flow to reduce false disconnects.
- Seen in `uWebSockets`.

## 6) Concurrency and Scaling Learnings

21. In-process scaling is loop/worker architecture, not arbitrary thread sharing
- Accept/dispatch and worker reactor patterns should be explicit.
- Seen in `ActiveJ`, `Drogon`.

22. Platform-specific accept strategy matters
- Linux reuse-port multi-listener strategy differs from non-Linux behavior.
- Seen in `Drogon` and aligns with your macOS/Linux observations.

23. Fairness budgets prevent starvation
- Limit per-loop/per-connection work chunks and yield.
- Seen in `hyper`.

## 7) Direct Priority for nim_express / nim_usockets

## P0 (highest value now)

1. Finish zero-copy large response streaming (remove final flatten copy in hot fragment path).
2. Enforce unified `tryEnd/onWritable` offset lifecycle across all response modes.
3. Upgrade routing to method+prefix bucket + exact-first + compiled dynamic fallback.
4. Tighten RFC framing checks centrally (duplicate Host, TE/CL, malformed combinations).
5. Strengthen backpressure policy with high-water instrumentation and deterministic close-after-flush.

## P1

1. Remove hot TLS/threadvar lookups from PageBuffer path (bind state once per request/loop).
2. Move hot request metadata toward slice-first access where lifetime allows.
3. Add allocator/pool telemetry and retention guardrails (pool ceilings, age/pressure eviction).
4. Add fairness budgets in event-loop dispatch for anti-starvation under pipelining.

## P2

1. WS TopicTree-style fanout queueing (index-based).
2. More advanced parser micro-optimizations (post-padding style scans) if profiling still parser-bound.
3. Extended deployment model docs/scripts for Linux multi-loop/multi-process topologies.

## 8) Tradeoffs to Keep Explicit

1. More manual state-machine code increases correctness risk without strong tests/fuzzing.
2. More zero-copy exposure increases lifetime-footgun risk for framework users.
3. Aggressive batching can improve throughput but worsen p99 if thresholds are not adaptive.
4. Platform-optimized accept paths can diverge behavior across macOS/Linux.
5. Complex pooling can reduce CPU but hide memory regressions without observability.

## 9) Practical Rule of Thumb

When optimizing, prefer this order:

1. Eliminate obvious copy/allocation work in current hot profile.
2. Stabilize backpressure + write lifecycle correctness.
3. Improve route/parse dispatch structure.
4. Add micro-optimizations only after macro bottlenecks move.

