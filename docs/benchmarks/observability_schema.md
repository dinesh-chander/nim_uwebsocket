# Optimization Observability Schema

## Runtime counters
Expose and capture these counters each benchmark iteration:
- `parser_errors`
- `overload_rejects`
- `write_retries`
- `backpressure_drops`
- `backpressure_high_water_events`
- `page_pool_hits`
- `page_pool_misses`
- `page_pool_bytes`
- `page_pool_retained`
- `connections`
- `websockets`
- `inflight_async`

These are available from `nim_express.app.optimizationMetrics()`.

Paged-buffer pool guardrails are configurable via:
- `setPageBufferPoolPolicy(maxRetainedPages, maxRetainedBytes, trimNow, ...)`
- `trimPageBufferPool(...)`

## Artifact layout
Each optimization run should create:
- `benchmark/reports/<timestamp>/summary.md`
- `benchmark/reports/<timestamp>/*.txt` raw tool output
- `benchmark/profiles/iter_<timestamp>/report.md`
- `benchmark/profiles/iter_<timestamp>/*` profiling samples

## Iteration loop
1. Run matrix: `make bench-matrix`
2. Run profiling loop: `make profile-loop`
3. Compare with previous `benchmark/reports/latest/summary.md`
4. Prioritize fixes by highest CPU contributor + p95 impact.

## Priority model
- P0: protocol correctness, crashes, data loss.
- P1: high CPU hotspots in request parser/write path.
- P2: memory/allocator pressure under edge traffic.
- P3: maintainability and observability debt.
