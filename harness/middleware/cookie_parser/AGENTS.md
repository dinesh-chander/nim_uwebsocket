# AGENTS.md — middleware: `cookie_parser`

Cookie parser middleware  Eagerly parses the Cookie header into req.cookies on every request that carries one, so downstream middleware/handlers can read req.cookies without

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
None beyond the shared rules.

## Context map
- Imports (unit-internal): common
- Imported by: test_middleware_resilience.nim
- Tests: test_cookie_parser_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/cookie_parser.nim` + `nim_express/tests/test_cookie_parser*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/cookie_parser/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
