# AGENTS.md — middleware: `backpressure`

Backpressure / load shedding middleware. Returns 503 when the server is under pressure based on configurable thresholds.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
None beyond the shared rules.

## Context map
- Imports (unit-internal): common
- Imported by: none (leaf unit)
- Tests: test_backpressure_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/backpressure.nim` + `nim_express/tests/test_backpressure*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/backpressure/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
