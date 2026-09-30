# AGENTS.md — middleware: `rate_limit`

Rate limit middleware  Fixed-window in-memory limiter. The store lives in the middleware instance, so under runThreaded/runCluster (one app factory per worker)

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. The limiter store is per middleware instance: under runThreaded/runCluster the effective limit multiplies by worker count (documented in the module header) — do not 'fix' this silently; a global limit needs an external store.
2. Window rollover must not double-count or reset buckets mid-window under concurrency.

## Context map
- Imports (unit-internal): common
- Imported by: test_exp_stability_iter_31_40.nim, test_middleware_resilience.nim
- Tests: test_rate_limit_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/rate_limit.nim` + `nim_express/tests/test_rate_limit*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/rate_limit/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
