# AGENTS.md — middleware: `session`

Session middleware with pluggable store callbacks; session id carried in an HttpOnly cookie.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Session identifiers come from `sysrand` — never predictable or derived from user input.
2. Session cookie keeps HttpOnly (+Secure/SameSite per config); the cookie value is secret material — never log it.
3. Store callbacks are user code: their errors must fail the request without leaking the session id or stack.

## Context map
- Imports (unit-internal): common
- Imported by: test_security_and_pending_api_extensions.nim
- Tests: test_session_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/session.nim` + `nim_express/tests/test_session*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/session/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
