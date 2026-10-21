# AGENTS.md — package: `nim_utils`

Complements `nim_utils/AGENTS.md` (layout + base rules — read that first); this file adds the unit contract. Where they overlap, the stricter rule applies.

Guardrails for AI agents working in `nim_utils/` (fast_map, fast_set, async_logger,
nim_fastjson incl. the simdjson C shim, helpers).

## Ownership
- You own: `nim_utils/src/` and `nim_utils/tests/`. The nested `nim_utils/src/nim_utils/nim_fastjson/tests/` is also yours.
- Do NOT modify other packages. `nim_utils` is the substrate: every other package compiles against it, so API breaks cascade.
- `simdjson_shim.cpp` is C++ code: keep it dependency-free (no external libs). The former verstable C backend was removed; `fast_map`/`fast_set` are pure Nim Swiss-table implementations (portable SWAR via `helpers/swar_group.nim`).
- Do not run `git add/commit` unless the operator asked.

## Guardrails
1. **Hash seed contract**: the pure-Nim backends hash with the process-wide `FastMapHashSeed` via `hashKey`. Never reintroduce a fixed public seed, and keep `nimWyHash` byte-compatible with the historical wyhash layout so persisted hashes stay meaningful.
2. **Swiss-table invariants** (fast_map/fast_set): growth at 7/8 (map) / 3/4 (set), rebuild at 15/16 / 7/8; deletes never raise `used`, so >=1 empty ctrl slot always exists and probes always terminate. If you change layout, hash, or thresholds, run the full `nim_utils` gate AND `nim_express` (route hot path).
3. **Checked arithmetic in C**: use `checked_size_mul` for any size computation before allocation; return the established error code (e.g. `simdjson::MEMALLOC`) on overflow.
4. **Error paths must release**: in the shim, every error return that follows a `reserve_temp`/pre-allocated buffer must `release_temp()` and null out caller-visible pointers (children/children_len) after free.
5. **async_logger**: the flush thread must never abort the process — keep `drainRing` calls wrapped in `try/except CatchableError`; producer waits must stay bounded (drop + count after the 100ms window).
6. **Performance**: this package is on the per-request hot path (~95k req/s). Prefer zero-allocation APIs, `newSeqOfCap`/`newStringOfCap`, and `{.inline.}` on hot functions. Known residual: `insertFastMapStringRaw` foreign-key fallback is O(cap) per insert (bulk insert is O(n²)) — do not "fix" it without an approved API decision; report it instead.
7. Public API needs a `## ` doc comment (directly above, same indentation, no square brackets).
8. Bugfix/behavior change ships with a regression test in `nim_utils/tests/` (or the fastjson tests dir for shim changes).

## Gate
```
bash harness/nim_utils/run.sh
```
Runs all `nim_utils/tests/*.nim` and `nim_utils/src/nim_utils/nim_fastjson/tests/*.nim`. Exits 0 only when green.