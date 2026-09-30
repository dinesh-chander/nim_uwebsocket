# AGENTS.md — middleware: `helmet`

Security headers middleware with production-oriented defaults.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
None beyond the shared rules.

## Context map
- Imports (unit-internal): common
- Imported by: test_security_and_pending_api_extensions.nim, test_uncovered_module_coverage.nim
- Tests: test_helmet_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/helmet.nim` + `nim_express/tests/test_helmet*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/helmet/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
