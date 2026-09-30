# AGENTS.md — middleware: `body_parser`

Body parser middlewares: json(), urlencoded(), text(), raw(), xml()  All parsers read the full request body into memory before processing. Streaming body parsing is not supported. For large file uploads, use the

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
None beyond the shared rules.

## Context map
- Imports (unit-internal): common
- Imported by: test_exp_stability_iter_31_40.nim, test_middleware_resilience.nim
- Tests: test_body_parser_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/body_parser.nim` + `nim_express/tests/test_body_parser*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/body_parser/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
