# AGENTS.md — middleware: `static_files`

Static file serving middleware with per-component path-traversal protection, size caps, and Range support.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. Path traversal defense is per-component: every path component is checked (symlink + `isRelativeTo`) BEFORE opening the file. Never 'simplify' to resolving only the final path — that re-opens traversal via symlinked directories.
2. Served file size must be stat'd and capped; Range requests go through the shared `file_helpers` logic.

## Context map
- Imports (unit-internal): common, file_helpers
- Imported by: test_static_output_cache_security.nim, test_uncovered_module_coverage.nim
- Tests: test_static_files_improvements.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/static_files.nim` + `nim_express/tests/test_static_files*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/static_files/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
