# AGENTS.md — middleware: `etag`

ETag middleware and validator helpers. Uses FNV-1a 64-bit hash for deterministic ETags. Shared hash/match primitives live in etag_core.nim (single source of truth). Relies on response layer to compute and set the ETag header after body is ready.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
None beyond the shared rules.

## Context map
- Imports (unit-internal): common, etag_core
- Imported by: test_uncovered_module_coverage.nim
- Tests: test_etag_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/etag.nim` + `nim_express/tests/test_etag*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/etag/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
