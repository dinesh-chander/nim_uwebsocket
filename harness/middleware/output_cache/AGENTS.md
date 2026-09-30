# AGENTS.md — middleware: `output_cache`

Output cache middleware with tag invalidation

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Cache poisoning: the cache key must include every request element that influences the response (method, path, relevant query params, and any header the handler reads). If in doubt, do not cache.
2. Only cache safe method/status combinations; vary by the same elements downstream `Cache-Control` would.

## Context map
- Imports (unit-internal): common
- Imported by: test_static_output_cache_security.nim
- Tests: test_output_cache_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/output_cache.nim` + `nim_express/tests/test_output_cache*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/output_cache/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
