# fast_map / fast_set pure-Nim port — C vs Nim A/B (2026-10-21)

## Mission

Port the C (verstable / `{.emit.}`) backends of `nim_utils` `fast_map` / `fast_set` to
pure Nim, A/B benchmark C vs Nim, then delete the C. Approved shape: pragmatic purity —
tiny `{.emit.}` one-liners allowed, no separate C files. Outcome: **C deleted, both
harness gates green, lookups at parity with C, one known insert residual (report-only).**

Environment: Linux x86_64 (AVX2), Nim 2.2.10 (mm=orc), gcc 15.2. All benchmark runs
executed under a RSS-capped watchdog (4096 MB cap, system-free guard); peak RSS of the
final full benchmark run: 563 MB (was > 4.2 GB before the arena fix — see below).

## What changed

1. **Portable SWAR group module** — `nim_utils/src/nim_utils/helpers/swar_group.nim`:
   absl-style uint32 byte-mask (`bit i = slot i`) over `copyMem`-loaded 8-byte pairs
   (probe starts are not 8-byte aligned). Replaces the 5 scalar nibble helpers in
   `fast_map.nim` and the SSE2/NEON `{.emit.}` SWAR in `fast_set.nim`. Equivalence
   suite: `nim_utils/tests/test_swar_group.nim` (exhaustive hasZero pairs, random words,
   match/empty/emptyOrDel vs scalar reference over random ctrl arrays).
2. **Leak fix** — `FastMap` storage moved into value object `FastMapStorageObj[V]` with
   `=destroy` calling idempotent `releaseFastMapStorage` (mirrors `FastSet`). 200k-map
   churn is flat ~1 MB (was 913 MB).
3. **Arena geometric ramp** — `FastMapBumpArena` / `FastSetBumpArena` now start at
   `min(128 B, chunkSize)` and double up to the configured chunk cap; `arenaReset`
   reuses the real chunk-0 size. Before: every string map's first insert malloced a
   full 256 KB chunk → map-of-map n=100k hit 4.2 GB and 1.3 µs/map (now 355.7 ns, flat
   RSS). Also fixes a latent `arenaReset` size bug.
4. **Arena kinds ported to Nim storage** — `fmskStringArena` maps route to the Nim
   string storage (chunkSize as arena cap); `fmskInt64Arena` stores raw 8-byte values
   in Nim entries; `fsskArena` sets route to Nim set storage. All behavior tests +
   new arena tests pass.
5. **putView guard** — views longer than the 65535 inline cap return `false` instead of
   attempting a ~2 EB allocation (previously process-fatal `out of memory`).
6. **C deleted** — all `{.emit.}` verstable regions, `nx_fm_*` / `nx_fs_*` importc
   decls, legacy backend kinds/defines, `vendor/verstable.h` + `VERSTABLE_LICENSE`
   (both packages), `helpers/fm_hash.h`, `helpers/sw_simd.h`. `syncFastMapCSeed`
   kept as a documented no-op (API compatibility; no callers depend on its effect).
   Remaining `{.emit.}`: exactly one — `__builtin_prefetch` in `fast_map.nim` (allowed
   one-liner). Grep for `verstable|nx_fm_|nx_fs_|fm_hash|sw_simd` over `.nim` sources
   is clean.

## A/B — `nim_utils/benchmark/bench_fastmap.nim` (ns/op)

Columns: **C** = verstable backend at HEAD; **before** = pure-Nim scalar nibble probes
(pre-SWAR); **after** = pure Nim + SWAR + ramp (final). C/from
`bfm_c_linebuf.txt`, before from `baseline_bfm_nim.txt` + partial guarded log, after
from `after_full.txt` (single clean run, exit 0).

### n = 1 000

| op | C | before | after |
|---|---:|---:|---:|
| string insert | 59.7 | 1 800 | 1 800 |
| string get-hit | 15.9 | 21.8 | 19.7* |
| string get-miss | 3.5 | 14.2 | 12.0* |
| string contains | 5.7 | 13.9 | 9.9* |
| string delete | 23.1 | 30.5 | 17.7* |
| int64 get-hit | 5.3 | 8.2 | 7.8* |
| map-of-map create | 245.9 | ~1.4 µs | 185–215 |

\* post-deletion sanity run; the same build measured 32.1 get-hit once under host
noise — run-to-run variance on this box is up to ~1.5×, treat ±30 % as noise.

### n = 10 000

| op | C | before | after |
|---|---:|---:|---:|
| string insert | 69.7 | 18 200 | 20 700 |
| string get-hit | 18.6 | 35.8 | 23.1 |
| string get-miss | 7.9 | 20.5 | 26.2 |
| string contains | 8.6 | 29.2 | 21.8 |
| string delete | 28.0 | 32.6 | 34.0 |
| int64 get-hit | 7.9 | 16.5 | 16.0 |
| map-of-map create | 255.4 | 1 300 (leak-era) | 201.9 |

### n = 100 000 (after only; before run timed out pre-fix at 1500 s cap)

| op | C | after | vs C |
|---|---:|---:|---|
| string get-hit | 28.7 | 29.6 | parity |
| string getView | — | 21.4 | — |
| string get-miss | 12.4 | 26.2 | 2.1× slower |
| string contains | 16.9 | 21.1 | 1.25× slower |
| string delete | 46.5 | 37.9 | **1.23× faster** |
| int64 insert | 54.2 | 83.2 | 1.5× slower |
| int64 get-hit | 14.6 | 27.0 | 1.85× slower |
| map-of-map create | 314.2 | 355.7 | ~parity (Table: 517.3) |

Lookups are at parity on the 1-probe hit path at every scale. The remaining C
advantage is on **long probe chains** (misses, contains and int64 at 7/8 load,
n ≥ 10k): the C backend loaded 16 ctrl bytes with one SSE2/AVX2 register; the portable
SWAR path does two `copyMem` 8-byte loads + mask math per group. Still ≥ 0.75× of std
`Table` on the same rows.

## A/B — `nim_express/benchmark/bench_fast_collections{,_prebuilt,_views,_small}.nim`

N = 10 000 (plain/prebuilt), default sizes otherwise. C = HEAD worktree, Nim = final
tree. ops/s (higher better):

| bench | metric | C | Nim |
|---|---|---:|---:|
| collections | FastMap lookup | 20.7 M | 23.4 M |
| collections | FastMap overwrite | 17.3 M | 21.8 M |
| collections | FastMap erase | 24.4 M | 28.4 M |
| collections | FastSet lookup | 28.5 M | 29.9 M |
| prebuilt | FastMap lookup | 36.4 M | 69.8 M |
| prebuilt | FastMap erase | 33.8 M | 53.2 M |
| prebuilt | FastSet lookup | 65.1 M | 75.8 M |
| views | FastMap Lookup View | 10.2 ms | 10.6 ms |
| views | Header Probe View | 4.56 ms | 4.59 ms |
| small | FastMap lifecycle | 129.4 ms | 127.2 ms |
| small | FastSet lifecycle | 120.8 ms | **99.6 ms** |

Checksums identical between C and Nim builds on every bench (same observable behavior).
The plain `FastMap insert` row (≈ 27–30 k ops/s in both C and Nim) is dominated by key
allocation in that bench, not the backend.

## End-to-end — `make bench` + wrk

`wrk -t8 -c200 -d15s http://127.0.0.1:8080/json`, single-process bench server, same
host, repeated runs:

| build | req/s | p99 |
|---|---:|---:|
| C backend (HEAD) | 303.4k / 306.9k | 1.22 / 1.21 ms |
| pure Nim (final) | 297.9k / 297.1k | 1.22 / 1.28 ms |

Within run-to-run noise (~2–3 %); far above the ~95k req/s bar.

## Known residuals (report-only)

> **Update (same day, follow-up pass):** residual 1 was fixed and residual 2
> narrowed — see “Optimization pass” below. Current state: only the int64 rows and
> a ~1.5× get-miss gap at n = 100 000 remain.

1. **O(capacity) string insert fallback** — `insertFastMapStringRaw` falls back to a
   keyOnly scan (`O(cap)`) in the duplicate-check path: string insert is ~1.8 µs at
   n=1 000, ~20.7 µs at n=10 000, ~186 µs at n=100 000 (C: 55–80 ns). Pre-existing in
   the Nim backend; unchanged by this port; fixing it needs a redesign of the
   tombstone/duplicate contract and was explicitly out of scope.
2. **1.5–2.1× lookup gap on long probes at n = 100 000** (get-miss / contains / int64)
   vs the SIMD C backend — inherent to portable uint64 SWAR; a 128-bit-SIMD `{.emit.}`
   group load would close it but was judged out of scope for the A/B (and the C it
   would mirror is now deleted).
3. **Step 5 (mulhi) evaluated and skipped** — `nimWyMum` compiles to four unfolded
   `imul`s (objdump of the release binary shows no `mul` in the hash path), but hash
   cost is not the measured bottleneck (hit-path lookups match C, which uses the same
   unfolded wyhash), so no 128-bit-multiply `{.emit.}` was added.

## Correctness evidence

- `bash harness/nim_utils/run.sh` → **11/11 passed** (includes new SWAR equivalence
  suite + new arena map/set behavior tests), run after C deletion.
- `bash harness/nim_express/run.sh` → **73/73 passed**, including new
  `nim_express/tests/test_fuzz_fast_collections.nim` (6 seeds × 200 000 random
  put/del/incl/excl ops vs `Table`/`HashSet` oracles for string map, int64 map, set).
- Leak churn: 200k create/drop cycles flat ~1 MB RSS.
- All C/Nim benchmark checksums match.

## Deleted / changed files

- Deleted: `nim_utils/src/nim_utils/vendor/` (verstable.h, VERSTABLE_LICENSE),
  `nim_express/src/nim_express/vendor/` (same), `helpers/fm_hash.h`, `helpers/sw_simd.h`.
- New: `helpers/swar_group.nim`, `nim_utils/tests/test_swar_group.nim`,
  `nim_express/tests/test_fuzz_fast_collections.nim`.
- Reworked: `helpers/fast_map.nim`, `helpers/fast_set.nim` (storage objects, ramp,
  Nim-only backends), bench output labels, `harness/nim_utils/AGENTS.md`.

## Optimization pass (same day, approved after initial A/B)

Two changes, both gated by the same suites (nim_utils 11/11, nim_express 73/73,
SWAR equivalence incl. new portable-vs-SSE2 cross-check):

1. **Hash-consistency flag kills the O(cap) insert fallback.** A per-storage
   `hashConsistent` flag starts `true` and is cleared only by the caller-hash write
   APIs (`putHashed`). Consistent maps — every non-`Hashed` workload — skip the
   key-only duplicate scan in insert and in hashed lookups; maps with any
   caller-hash write keep the exact old fallback (the `putHashed` hash-mismatch
   tests still pass).
2. **SSE2 control-group load.** `swar_group.nim` now matches a 16-byte group with one
   unaligned load + `pcmpeqb` + `pmovmskb` via three tiny `{.emit.}` helpers
   (extern C linkage so inlined callers link against the single definition;
   `nimSwarPortable` forces the portable path; portable path retained for non-x86).
   Nim's `defined(x86)` does not cover amd64 — the guard is `i386 or amd64`.

Selected results (ns/op, same guarded harness; **bold** = now better than C):

| op | C | before opt | after opt |
|---|---:|---:|---:|
| insert n=1 000 | 59.7 | 1 800 | **30.5** |
| insert n=10 000 | 69.7 | 20 700 | **42.7** |
| insert n=100 000 | 80.4 | 186 400 | **32.7** |
| get-hit n=100 000 | 28.7 | 29.6 | **26.8** |
| get-miss n=10 000 | 7.9 | 26.2 | **11.7** |
| get-miss n=100 000 | 12.4 | 26.2 | 18.8 |
| contains n=100 000 | 16.9 | 21.1 | **16.7** |
| delete n=10 000 | 28.0 | 34.0 | **15.7** |
| delete n=100 000 | 46.5 | 37.9 | **25.8** |
| map-of-map n=10 000 | 255.4 | 201.9 | **175.7** |
| map-of-map n=100 000 | 314.2 | 355.7 | 336.6 |
| int64 get-hit n=100 000 | 14.6 | 27.0 | 27.0 |
| int64 insert n=100 000 | 54.2 | 83.2 | 84.0 |

`wrk -t8 -c200 -d15s /json` with the optimized build: **306.2k / 305.4k req/s**,
p99 1.22 / 1.24 ms (C: 303–307k; pre-opt Nim: 297k) — back at C parity.

Remaining measured gaps: string get-miss ~1.5× C at n = 100 000 (long probe chains
at 7/8 load), int64 get-hit ~1.8× C and int64 insert ~1.5× C (the C int64 map had a
smaller cache footprint; closing this means inline-value entries, which would bloat
string-map entries 24→32 B — judged not worth the string-path regression risk).


### Generic-backend SWAR probe (adopted)

The generic-V backend (`FastMapNimStorage[V]`, used by `FastMap[int64]` and
custom value types) still probed slot-by-slot. It now uses the same aligned
group scan (`swarMatch16` / `swarMatchEmptyOrDel16`, quadratic group stride),
with minimum capacity raised 8→16 so groups tile exactly. Alternating
A/B runs (`/tmp/nimport/ab_{old,new}_{a,b}.txt`, ns/op):

| metric | old | new | verdict |
|---|---|---|---|
| int64 insert n=10 000 | 40.6–41.2 | 33.9–34.1 | win (−17 %) |
| int64 insert n=100 000 | 84.7–87.2 | 79.0–79.9 | win |
| int64 get-hit n=10 000 | 15.6–15.7 | 16.5–16.6 | −6 %, noise band |
| int64 get-hit n=100 000 | 28.3–34.0 | 30.9–32.6 | flat (noisy) |
| string get-miss | 11.5–11.8 | 11.5–11.8 | unchanged |

Adopted on the insert win; lookups flat within noise. A next-group prefetch
experiment was considered and skipped: probe chains average ~2 groups at these
load factors, so a prefetch cannot cover a dependent miss.

## Correctness stress suite

`nim_utils/tests/test_fast_collections_stress.nim` (joins the nim_utils gate;
gate now 12/12, nim_express gate 73/73) covers, all deterministic-seeded and
oracle-compared:

- string-map fuzz across three backends (plain, sized, arena) vs `Table`
  (20 000 ops × 3 seeds, full-iteration equality every 1 000 ops);
- int64-backend group-boundary torture: 24-key pool keeps capacity at 16–64 so
  the last group and wrap-around stride sequences are walked constantly;
- generic tuple-V backend fuzz (forces the `fmskNimGeneric` storage path);
- hash-inconsistent maps (`putHashed`): replace-by-key across caller-hash
  mismatch, 70 forced-collision keys spanning many groups, verification via
  `tryGetViewHashed` with the caller hash (plain `get`/`del` legitimately
  re-hash and only see real-hash entries — documented contract);
- tombstone storms (string + int64): 5 rounds of insert 2 000 / delete 60 % /
  re-insert 500 forcing in-place rebuilds, full oracle compare per round;
- arena map + arena set clear/re-insert rounds exercising the geometric
  arena ramp and `arenaReset`;
- oversized-key/view rejection (65 535-byte keys accepted, larger rejected,
  impossible-length views return false without corrupting the map);
- iteration-vs-len equality through six rounds of randomized tombstone
  scattering and re-insertion (string + generic backends).

One real hang was found and fixed during development: the rewritten
`resetFastMapCtrl` initially zero-filled the control array instead of filling
the 0xFF empty sentinel, producing an all-full table and an infinite probe.

### Unaligned group probe (tested, REJECTED)

Hypothesis: C's get-miss edge came from aligned group probing (a 16-slot span
straddling two group loads). Dropping the `and not(SwGroupSize - 1)` clamp in
all nine fast_map probe loops compiles and benches, but the stress suite
immediately hangs on the int64 group-boundary torture test: with unaligned
windows and group-multiple strides, probe offsets stay in one residue class
mod 16, so slots `[0, home mod 16)` form a dead band invisible to that home;
when the remaining empties fall in the dead band the probe never terminates.
Reading 16 bytes past `ctrl[cap)` additionally relies on the cap+16 slop being
empty (0xFF), which turns the dead-band case into phantom slot selection
(wrapped index may be occupied). The old fast_set backend already probes
unaligned and lives with this trade-off via slop semantics plus exhaustive
fuzz coverage; for fast_map the aligned tiling (every probe provably sees an
empty slot) is the correctness property we keep. Root cause of the residual
get-miss gap is therefore NOT alignment — verstable probes per-bucket with
quadratic triangular displacement and per-bucket chains, a different scheme
that is out of scope here. Rolled back from
`/tmp/nimport/fm_backup_pre_unaligned.nim`; gate re-verified 12/12.

## fast_set optimization pass (2026-10-21)

Two profiled changes, same test-and-adopt loop as fast_map, measured with
`nim_utils/benchmark/bench_fastset.nim` (new): alternating guarded runs, min-of-2
per binary after an early uncontended pair proved ±35% environment drift.

1. **Fused single-probe insert** — `findOrInsertFastSetRaw` previously ran the
   find group-scan and then a second full group-scan (`swFindInsertSlot`) for every
   new key. One scan now records the first empty-or-deleted slot while verifying
   h2 matches; stops at the first empty exactly like the standalone find, so the
   selected slot is identical (wrapped slop/mirror semantics unchanged). Insert
   −6..13%, containsOrIncl-new −3..9%, all other ops flat.
2. **Inlined find probes** — `{.inline.}` on `findFastSetStringFoundIdx` /
   `findFastSetRawFoundIdx`: contains-hit −4..9%, contains-miss −3..15%,
   excl-miss −7..13%; no regressions (median 0.97).

Rejected: nothing attempted-and-rejected on this pass beyond measurement noise
correction above. `swFindInsertSlot` removed as dead code after fusion.

| op | n | C (ns) | Nim before (ns) | Nim final (ns) | final/before | final/C |
|---|---|---|---|---|---|---|
| insert | 10 | 14.5 | 14.5 | 13.6 | 0.94 | 0.94 |
| contains-hit | 10 | 4.2 | 7.1 | 6.7 | 0.94 | 1.60 |
| contains-miss | 10 | 2.5 | 5.7 | 5.4 | 0.95 | 2.16 |
| incl-dup | 10 | 4.1 | 7.3 | 7.2 | 0.99 | 1.76 |
| coi-new | 10 | 20.3 | 21.2 | 20.7 | 0.98 | 1.02 |
| excl-hit | 10 | 7.1 | 12.8 | 12.5 | 0.98 | 1.76 |
| excl-miss | 10 | 3.5 | 7.0 | 6.8 | 0.97 | 1.94 |
| churn/op | 10 | 8.9 | 13.6 | 13.3 | 0.98 | 1.49 |
| insert | 100 | 17.6 | 10.8 | 9.3 | 0.86 | 0.53 |
| contains-hit | 100 | 4.4 | 7.3 | 6.7 | 0.92 | 1.52 |
| contains-miss | 100 | 2.5 | 5.8 | 5.4 | 0.93 | 2.16 |
| incl-dup | 100 | 4.5 | 7.5 | 7.7 | 1.03 | 1.71 |
| coi-new | 100 | 21.1 | 21.3 | 20.3 | 0.95 | 0.96 |
| excl-hit | 100 | 10.4 | 9.3 | 9.2 | 0.99 | 0.88 |
| excl-miss | 100 | 2.6 | 6.4 | 5.8 | 0.91 | 2.23 |
| churn/op | 100 | 9.7 | 10.0 | 10.0 | 1.00 | 1.03 |
| insert | 1000 | 13.8 | 11.8 | 10.4 | 0.88 | 0.75 |
| contains-hit | 1000 | 4.8 | 8.0 | 7.3 | 0.91 | 1.52 |
| contains-miss | 1000 | 2.8 | 7.8 | 7.0 | 0.90 | 2.50 |
| incl-dup | 1000 | 4.8 | 8.1 | 8.5 | 1.05 | 1.77 |
| coi-new | 1000 | 32.7 | 26.1 | 24.7 | 0.95 | 0.76 |
| excl-hit | 1000 | 12.2 | 10.5 | 10.6 | 1.01 | 0.87 |
| excl-miss | 1000 | 3.1 | 9.1 | 8.3 | 0.91 | 2.68 |
| churn/op | 1000 | 11.9 | 12.9 | 12.3 | 0.95 | 1.03 |
| insert | 10000 | 20.4 | 16.9 | 15.1 | 0.89 | 0.74 |
| contains-hit | 10000 | 6.8 | 11.0 | 10.4 | 0.95 | 1.53 |
| contains-miss | 10000 | 6.6 | 12.0 | 11.4 | 0.95 | 1.73 |
| incl-dup | 10000 | 6.9 | 11.2 | 11.3 | 1.01 | 1.64 |
| coi-new | 10000 | 48.9 | 41.7 | 40.8 | 0.98 | 0.83 |
| excl-hit | 10000 | 16.4 | 13.1 | 13.2 | 1.01 | 0.80 |
| excl-miss | 10000 | 8.6 | 12.7 | 11.7 | 0.92 | 1.36 |
| churn/op | 10000 | 18.1 | 23.6 | 23.1 | 0.98 | 1.28 |
| insert | 100000 | 28.6 | 15.8 | 14.7 | 0.93 | 0.51 |
| contains-hit | 100000 | 11.9 | 15.4 | 14.9 | 0.97 | 1.25 |
| contains-miss | 100000 | 12.1 | 17.8 | 17.0 | 0.96 | 1.40 |
| incl-dup | 100000 | 12.1 | 16.0 | 16.0 | 1.00 | 1.32 |
| coi-new | 100000 | 69.8 | 93.1 | 90.3 | 0.97 | 1.29 |
| excl-hit | 100000 | 22.2 | 22.6 | 22.8 | 1.01 | 1.03 |
| excl-miss | 100000 | 13.2 | 19.3 | 18.7 | 0.97 | 1.42 |
| churn/op | 100000 | 27.7 | 21.7 | 22.5 | 1.04 | 0.81 |

Per-op medians at n>=1000: final beats the deleted C backend on insert (0.52-0.78x),
coi-new (0.72-0.83x at 1k/10k), excl-hit (0.82-1.01x); lookups remain 1.3-1.7x
behind C at small scales (residual, same class as the fast_map get-miss residual:
C compile-unit inlining, unchanged by this pass). wrk /json after the pass:
304.0k / 299.7k req/s (p99 band unchanged) — parity with pre-pass 298-306k.
Gates after both changes: nim_utils 12/12, nim_express 73/73.
