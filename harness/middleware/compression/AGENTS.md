# AGENTS.md — middleware: `compression`

Compression middleware Supports Brotli, Zstandard, and gzip (via libdeflate). Negotiates encoding from Accept-Encoding with quality values. Preference order (server tie-breaker): Zstandard > Brotli > gzip.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Codec choice follows the client's Accept-Encoding (and the configured priority); never emit a codec the client didn't advertise.
2. Exactly one of Content-Length / Transfer-Encoding on the response — never both, never neither on body responses.

## Context map
- Imports (unit-internal): common
- Imported by: test_compression_codecs.nim
- Tests: test_compression_codecs.nim, test_compression_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/compression.nim` + `nim_express/tests/test_compression*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/compression/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
