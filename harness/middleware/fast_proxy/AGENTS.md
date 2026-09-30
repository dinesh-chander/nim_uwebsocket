# AGENTS.md — middleware: `fast_proxy`

Reverse-proxy middleware (fast-path variant of `proxy`); carries the same SSRF/timeout/credential invariants and has a dedicated security test.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Same SSRF + timeout + credential-strip invariants as `proxy` (see its AGENTS.md); this unit has a dedicated security test — always run `test_fast_proxy_security.nim` when touching it.

## Context map
- Imports (unit-internal): common
- Imported by: test_uncovered_module_coverage.nim
- Tests: test_fast_proxy_improvements.nim, test_fast_proxy_security.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/fast_proxy.nim` + `nim_express/tests/test_fast_proxy*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/fast_proxy/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
