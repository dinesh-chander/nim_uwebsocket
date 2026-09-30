# AGENTS.md — middleware: `circuit_breaker`

Circuit breaker middleware: opens after repeated failures to fail fast instead of piling load onto a sick dependency; state machine per instance (see unit rules).

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. State machine is CLOSED → OPEN → HALF_OPEN with exactly one in-flight probe in HALF_OPEN; recovery is timer-driven, never polling.
2. A tripped breaker must reject fast (no connection attempt) and release its slot on every path, including handler exceptions.

## Context map
- Imports (unit-internal): common
- Imported by: none (leaf unit)
- Tests: test_circuit_breaker_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/circuit_breaker.nim` + `nim_express/tests/test_circuit_breaker*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/circuit_breaker/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
