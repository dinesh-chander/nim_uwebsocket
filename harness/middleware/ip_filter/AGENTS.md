# AGENTS.md — middleware: `ip_filter`

IP filter middleware (allowlist / denylist with CIDR support).

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. IP parsing goes through `parseutils` — never hand-rolled string arithmetic (overflow/misparse = filter bypass).
2. CIDR match must be exact (mask boundaries); default policy is fail-closed.

## Context map
- Imports (unit-internal): common
- Imported by: none (leaf unit)
- Tests: test_ip_filter_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/ip_filter.nim` + `nim_express/tests/test_ip_filter*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/ip_filter/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
