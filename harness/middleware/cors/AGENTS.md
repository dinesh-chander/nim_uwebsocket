# AGENTS.md — middleware: `cors`

CORS middleware  origin = "*" (default) allows any origin without credentials; combine with allowedOrigins to allow a specific set. origin = "reflect" echoes the

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Never reflect Origin `null`, and never reflect an origin together with credentials unless it is explicitly allowlisted (see module header).

## Context map
- Imports (unit-internal): common
- Imported by: test_compression_codecs.nim, test_security_and_pending_api_extensions.nim, test_uncovered_module_coverage.nim
- Tests: test_cors_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/cors.nim` + `nim_express/tests/test_cors*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/cors/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
