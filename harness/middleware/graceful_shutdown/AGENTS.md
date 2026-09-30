# AGENTS.md — middleware: `graceful_shutdown`

Graceful shutdown middleware. Handles SIGTERM/SIGINT, drains in-flight requests, and runs cleanup hooks.  Signal delivery is async-signal-safe: the handler only sets a volatile flag.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Signal handlers stay async-signal-safe: set a volatile flag only. All drain logic runs on the dedicated drain thread (10ms flag poll), never on the event loop.
2. Worker signal ordering (cluster children reset to SIG_DFL before the factory runs; this middleware reinstalls after) is load-bearing — see `harness/nim_express/AGENTS.md`.
3. After changing close/drain paths, run the graceful-shutdown stress test 10× (see nim_usockets harness gate notes).

## Context map
- Imports (unit-internal): common
- Imported by: none (leaf unit)
- Tests: test_graceful_shutdown_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/graceful_shutdown.nim` + `nim_express/tests/test_graceful_shutdown*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/graceful_shutdown/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
