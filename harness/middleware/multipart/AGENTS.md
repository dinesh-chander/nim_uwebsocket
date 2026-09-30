# AGENTS.md — middleware: `multipart`

Multipart form-data parser middleware (bounded, opt-in).

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Temporary files are cleaned up on ALL paths (success, parse error, limit hit, client abort).
2. Uploaded filenames are untrusted: sanitize (strip path components) before any disk write; size caps apply per-part and total.

## Context map
- Imports (unit-internal): common
- Imported by: none (leaf unit)
- Tests: test_multipart_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/multipart.nim` + `nim_express/tests/test_multipart*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/multipart/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
