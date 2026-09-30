# AGENTS.md — middleware: `error_handler`

Centralized error handler middleware (RFC 7807 Problem Details).

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Production responses must never contain stack traces, file paths, or internal identifiers; the JSON error shape is stable and tested — extend fields additively only.

## Context map
- Imports (unit-internal): logger, common
- Imported by: none (leaf unit)
- Tests: test_error_handler_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/error_handler.nim` + `nim_express/tests/test_error_handler*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/error_handler/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
