# AGENTS.md — middleware: `panic_recovery`

Panic/crash recovery middleware. Catches unhandled exceptions and returns 500 instead of crashing.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Must not swallow `Defect`-class bugs silently: record + report per the established panic channel, then respond with a generic error (no internals leaked).

## Context map
- Imports (unit-internal): logger, common
- Imported by: none (leaf unit)
- Tests: test_panic_recovery_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/panic_recovery.nim` + `nim_express/tests/test_panic_recovery*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/panic_recovery/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
