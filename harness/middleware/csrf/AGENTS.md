# AGENTS.md — middleware: `csrf`

CSRF protection middleware (double-submit token model).

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Token comparison must not short-circuit on timing (constant-time compare where the primitive exists); tokens are per-session, never process-global.
2. Exempt exactly the configured safe methods/paths; default is enforce.

## Context map
- Imports (unit-internal): common
- Imported by: test_security_and_pending_api_extensions.nim
- Tests: test_csrf_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/csrf.nim` + `nim_express/tests/test_csrf*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/csrf/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
