# nim_utils/AGENTS.md

Shared utilities used by the whole stack. See the root `AGENTS.md`.

Layout:
- `src/nim_utils/` — `fast_map`, `fast_set`, `async_logger`, and other helpers.
- `src/nim_utils/nim_fastjson/` — fast JSON (de)serialization, pure Nim.
  - `benchmark/`, `tests/` — benchmarks and tests (run via top-level `make test`).
  - `README.md`, `plan.md`, `fastmap.md`, `performance_optimizations.md` — package design docs.

Rules:
- These modules are on the hot path for every request — keep allocations out of lookup/serialize loops.
- `nim_fastjson` deserialize contract: every `deserialize` path must reject invalid JSON with `JsonError` (the direct engine validates structurally while parsing: UTF-8, escapes, surrogates, control bytes, depth, item limits). See `nim_fastjson/performance_optimizations.md` section 8.
- `nim_fastjson` is pure Nim: no C/C++ sources may be added back. SIMD string scanning is emitted inline (SSE2/NEON) guarded by `-d:noSimd`; borrowed views (`BorrowedString`) share one `BorrowedDocRef` per document — never let a view outlive its holder's bytes.
- Do not commit test binaries (git-ignored by filename rule).
- Every public declaration needs a doc comment (see Documentation rules in the root AGENTS.md).

## Agentic harness (unit guardrails)
Before changing this package: read `harness/nim_utils/AGENTS.md` (ownership + hash-seed/invariant hard rules) and finish only when `bash harness/nim_utils/run.sh` exits 0.
