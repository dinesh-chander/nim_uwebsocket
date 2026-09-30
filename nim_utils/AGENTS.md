# nim_utils/AGENTS.md

Shared utilities used by the whole stack. See the root `AGENTS.md`.

Layout:
- `src/nim_utils/` — `fast_map`, `fast_set`, `async_logger`, and other helpers.
- `src/nim_utils/nim_fastjson/` — fast JSON (de)serialization with an optional simdjson backend.
  - `simdjson/` — vendored simdjson (C++ header + single-header build artifacts). `vendor/simdjson.h` carries a surgical 14-site patch adding `set_max_depth` to the ondemand parser (upstream only ships it on the DOM parser) — preserve the patch when re-vendoring, or `simdjsonSetOndemandMaxDepth` stops working.
  - `benchmark/`, `tests/` — benchmarks and tests (run via top-level `make test`).
  - `README.md`, `plan.md`, `fastmap.md`, `performance_optimizations.md` — package design docs.

Rules:
- These modules are on the hot path for every request — keep allocations out of lookup/serialize loops.
- `nim_fastjson` deserialize contract: every simd-backed `deserialize` must reject invalid JSON with `JsonError`. Validation is the shim's full ondemand token walk (`nim_simdjson_ondemand_validate`) — ondemand parse errors are lazy, so targeted field access alone is NOT validation. Never "simplify away" the pre-pass; see `nim_fastjson/performance_optimizations.md` section 8.
- The vendored simdjson parser state is a per-thread scratch parser in the shim — do not introduce per-call parser construction on hot paths.
- Do not commit native build output under `simdjson/build/` (git-ignored); `make` handles it.
- Do not commit test binaries (git-ignored by filename rule).
- Every public declaration needs a doc comment (see Documentation rules in the root AGENTS.md).

## Agentic harness (unit guardrails)
Before changing this package: read `harness/nim_utils/AGENTS.md` (ownership + hash-seed/invariant hard rules) and finish only when `bash harness/nim_utils/run.sh` exits 0.
