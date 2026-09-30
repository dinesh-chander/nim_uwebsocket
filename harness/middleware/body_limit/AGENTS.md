# AGENTS.md — middleware: `body_limit`

Request body size limit middleware. Rejects requests exceeding a configurable body size with 413 Payload Too Large.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Limits are dual-layer (this middleware + framework body limits). Do not remove either; enforce BEFORE buffering the full body (streaming reject).

## Context map
- Imports (unit-internal): common
- Imported by: test_middleware_resilience.nim
- Tests: test_body_limit_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/body_limit.nim` + `nim_express/tests/test_body_limit*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/body_limit/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
