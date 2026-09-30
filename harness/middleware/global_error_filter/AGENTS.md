# AGENTS.md — middleware: `global_error_filter`

Global exception filter middleware. Registers filters that transform exceptions into HTTP responses, similar to ASP.NET's IExceptionFilter pattern.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
None beyond the shared rules.

## Context map
- Imports (unit-internal): common
- Imported by: none (leaf unit)
- Tests: test_global_error_filter_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/global_error_filter.nim` + `nim_express/tests/test_global_error_filter*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/global_error_filter/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
