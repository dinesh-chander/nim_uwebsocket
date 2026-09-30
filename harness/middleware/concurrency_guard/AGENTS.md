# AGENTS.md — middleware: `concurrency_guard`

Concurrency guard middleware. Caps concurrent in-flight requests and rejects excess load early.  The cap is PER WORKER: under runCluster/runThreaded each process/thread owns

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. The concurrency slot must be released on EVERY path (use defer); a handler exception must not deadlock the guard.

## Context map
- Imports (unit-internal): common
- Imported by: none (leaf unit)
- Tests: test_concurrency_guard.nim, test_concurrency_guard_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/concurrency_guard.nim` + `nim_express/tests/test_concurrency_guard*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/concurrency_guard/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
