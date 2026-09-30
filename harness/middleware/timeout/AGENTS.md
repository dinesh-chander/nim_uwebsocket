# AGENTS.md — middleware: `timeout`

Timeout middleware Wraps the downstream handler in a deadline. If the handler does not complete within the budget, a 504 Gateway Timeout is sent. 

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. The expiry path must not leak the socket: on timeout the connection is closed or marked dead; never cancel work that already dispatched to offload.
2. Timeout values are per-request caps, not global; a hung handler must not extend another request's budget.

## Context map
- Imports (unit-internal): common
- Imported by: test_exp_stability_iter_31_40.nim, test_exp_stability_iter_41_50.nim, test_middleware_resilience.nim
- Tests: test_timeout_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/timeout.nim` + `nim_express/tests/test_timeout*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/timeout/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
