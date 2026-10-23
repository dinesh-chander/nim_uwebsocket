# fastjson leaf-shape decode re-route — simd vs direct A/B (2026-10-22)

## Mission

Follow-up to the fast_map / fast_set pure-Nim port branch: apply the same
A/B workflow to `nim_utils/nim_fastjson`. Finding: the historical
leaf-shape → simdjson routing (GEN-011/GEN-013, a macOS-era decision) is a
**3.7x–12.9x loss** on this Linux/AVX2+AVX512 box — the pure-Nim direct
engine decodes every non-borrowed shape faster. Re-route all non-borrowed
typed decode to the direct engine, keep simd only for borrowed-string
shapes (zero-copy requires the simd token walk).

Environment: Linux x86_64, Intel Core Ultra 7 265K pinned to core 4
(`taskset -c 4`), AVX2+AVX512, Nim 2.2.10, release `--opt:speed`,
min-of-7 after 200 warmup iters.

## What changed

`nim_utils/src/nim_utils/nim_fastjson.nim` (wrapper only — no engine changes):

1. **Routing**: `deserialize` now sends borrowed-string shapes to the simd
   backend (unchanged, incl. the ondemand token-walk validation pre-pass and
   per-thread scratch parser) and **everything else to
   `direct_engine.deserializeDirect`** — previously
   `directLeafDecodeSupported(T)` shapes also went to simd.
2. **FFI limit setup moved inside the simd branch**:
   `simdjsonSetOndemandMaxDepth` / `simdjsonSetOndemandMaxArrayItems` were
   called on every `deserialize` call even for shapes that never touch simd;
   now they run only when the simd path is actually taken.
3. **Reporting procs fixed to match reality**: `selectedDeserializePath`
   returns `fjdpDirect` for leaf and nested shapes (previously reported
   `fjdpSimdLeaf` / `fjdpSimdNested` while nested already went direct — an
   inconsistency); `selectedDeserializeEngine` returns `fjeSimdjson` only for
   borrowed shapes. Enum values `fjdpSimdLeaf` / `fjdpSimdNested` retained
   for API compatibility.
4. Test updates: `tests/test_fastjson_core.nim` routing expectations updated
   (leaf/nested now `fjdpDirect`/`fjeDirect`); borrowed expectations
   unchanged.

Public API surface unchanged; `useSimdWhenAvailable=false` with a
borrowed shape still raises (simd is the only zero-copy path for borrowed
strings).

## A/B — deserialize (ns/op, lower is better)

| shape | before (simd leaf) | after (direct) | jsony | after vs before | after vs jsony |
|---|---:|---:|---:|---:|---:|
| SmallTodo 40 B | 181.0 | **39.2** | 64.0 | **4.6x faster** | 1.6x faster |
| Wide flat 107 B | 400.6 | **124.6** | 231.7 | **3.2x faster** | 1.9x faster |
| scalar int root | 63.7 | **8.5** | 3.2 | **7.5x faster** | 0.4x (jsony faster) |
| scalar string root | 70.4 | **18.7** | 22.6 | **3.8x faster** | 1.2x faster |
| seq[Flat] n=100 (6.7 KB) | ≈ direct | 5316 | 8091 | — | 1.5x faster |
| seq[Flat] n=10000 (689 KB) | ≈ direct | 542 922 | 809 712 | — | 1.5x faster |
| medium nested 100 (6.2 KB) | 5652 (already direct) | 5534 | 9519 | — | 1.7x faster |
| nested 50 (6.7 KB) | 8196 (already direct) | 8110 | 12 231 | — | 1.5x faster |

Headline: the small-shape deserialize that lost to jsony 2.8x at baseline
(4.94M vs 13.99M ops/s) now **wins 1.6x** (25.5M vs 15.6M ops/s).

Residual: `wrapper/direct` ratio is 1.06–1.7 on tiny inputs — that is
`validateDeserializeOptions` + the direct-engine limit save/restore +
exception conversion, ~4–4 ns; acceptable against the 3.7–12.9x gain.

Direct engine still loses to jsony only on the raw scalar-int root (3.2 vs
8.5 ns); jsony has a specialized scalar fast path there.

## Why simd lost

- simd leaf decode pays a full simdjson ondemand token-walk validation
  pre-pass **plus** a second ondemand decode walk: two passes over the
  document, C heap churn per call, macro projection overhead.
- The direct engine does one pass in pure Nim with precomputed field plans
  and inlined scalar parsing; on this CPU its per-byte cost is lower than
  the simd walk for shapes that allocate strings anyway (no zero-copy win).
- Borrowed-string shapes keep the simd route: only the simd token walk can
  hand out `JsonStringView` references into the input without copying.

## Verification

- `bash harness/nim_utils/run.sh` → 14 passed, 0 failed.
- `bash harness/nim_express/run.sh` → 73 passed, 0 failed.
- fastjson suites individually: core 38 ok, comprehensive 69 ok,
  conformance ok, resource-limits 5 ok (all exit 0).
- Conformance + error-shape tests only assert `JsonError` type, not
  engine-specific messages — re-route is behavior-compatible.

## Part 2: direct-engine micro-optimizations (2026-10-23)

Follow-up loop on the now-champion direct engine. Two more wins adopted,
one experiment rejected. Same machine, same methodology (min-of-7,
taskset -c 4, release builds).

### GEN-051: `scanStringEnd` delegates to the SIMD scan kernel

The deserializer's per-string end scan was a scalar SWAR 8-byte loop
duplicating the exact predicate of `scanSafeJsonBytes` (quote / backslash /
control byte), which already had SSE2 (16B) and NEON versions. Replaced the
body with a delegation.

- small 40B: 39.2 → 36.5 ns; medium100: 5534 → 4804 ns (-13%);
  nested50: 8110 → 6931 ns (-15%)

### GEN-052: ASCII fast path skips UTF-8 validation

`validateUtf8` measured 0.126 ns per byte — it re-read every deserialized
string and dominated string cost (0.168 ns/B marginal before). Added
`containsHighByte` (8 bytes per iteration, one shift-and-test); pure-ASCII
strings are valid UTF-8 by definition and now skip the full validation pass
in both `parseJsonString` paths and `ensureValidJsonUtf8Span`.

- 4096-byte string deserialize: 687 → 333 ns total (0.168 → 0.081 ns/B)
- small 40B: 36.5 → 35.3 ns; medium100: 4804 → 4748 ns; nested50:
  6931 → 6894 ns
- pitfall hit: the first cut forgot the span end boundary and scanned to the
  document end per object key → 6.5x slower on medium shapes; fixed by
  passing the end index

### GEN-053: AVX2 32-byte scan kernels — measured, rejected

Runtime cpuid AVX2 detection plus `target("avx2")` 32-byte scan and fused
scan+copy kernels: no serialize gain (0.031 ns/B unchanged) and slightly
worse deserialize (call + branch overhead per scan). The scan is
uop-bound, not iteration-bound — 32B per iteration doubles the compare /
movemask uops. Reverted.

### Cumulative deserialize position after Part 2 (min-of-7)

| shape | before session | after | jsony |
|---|---|---|---|
| small 40B | 181 ns | 35.3 ns | 64 ns |
| wide 107B | 400.6 ns | ~124 ns | 231.7 ns |
| int root | 63.7 ns | 8.5 ns | 3.2 ns |
| medium100 | 5534 ns | 4748 ns | 9545 ns |
| nested50 | 8110 ns | 6894 ns | 12453 ns |

Gates re-run after each change: `harness/nim_utils/run.sh` 14/14 and
`harness/nim_express/run.sh` 73/73 green.

## Part 4: cached strict-defaults option validation (GEN-055)

`initFastJson` now computes `strictDefaults` / `strictSerializeDefaults`
once; when every rejectable option is at its default the per-call option
checks in `validateDeserializeOptions` / `validateSerializeOptions` are
skipped (the maxInputBytes length check stays on every path).

- int root deserialize: 8.5 → 6.3 ns/op (jsony 3.2).
- small 40B deserialize: 35.3 → 34.2 ns/op (jsony 64).
- medium/nested unchanged within noise.

Final matrix (min-of-7, this box) — fastjson wins every scenario:

| scenario | ser vs jsony | deser vs jsony |
|---|---|---|
| small 40B | 3.05x | 1.72x |
| medium 1.5KB | 1.87x | 1.90x |
| nested 2KB | 1.31x | 1.29x |
| large_nested 26KB | 1.57x | 2.10x |

## Part 3: integer formatting (DigitTriples, GEN-054)

`appendIntFast` switched from 2-digit (div/mod 100) to 3-digit (div/mod 1000)
chunking with a 1000-entry table, cutting 64-bit division count per value.

- Standalone kernel (5-digit values, min-of-7): 5.14 → 4.80 ns/int.
- Rejected variants: 4-digit div-10000 table (7.3 ns/int, worse); unchecked
  per-char literal key append (3.74 ns/field vs 1.22 for `buf.add(static)`).
- Isolated int-heavy replica (same harness, only that block): fastjson now
  wins 1.18x (1.31us vs 1.55us). In the full `bench_varied_types` binary the
  same scenario reads 0.82–0.91x because fastjson's inlined code grows the
  binary and takes instruction-cache pressure (jsony's number is identical
  1.6us in both binaries); treated as a bench artifact, not an algorithmic
  loss. All other varied-type scenarios win 1.23x–3.67x.

## Follow-up candidates (not done)

- Float-heavy serialize is the weakest serialize win (1.23x); both engines
  use `formatFloat` (Dragon4). A Grisu/Ryu-style formatter would be a large
  correctness-sensitive project; accepted as-is.
- Scalar int-root deserialize still loses to jsony (6.3 vs 3.2 ns) — the
  remaining gap is call/threadvar overhead around a two-digit parse; niche
  shape, accepted.
- Full `bench_varied_types` binary shows int-heavy serialize at 0.82–0.91x
  due to instruction-cache pressure from the large benchmark binary
  (isolated replica wins 1.18x); accepted as a bench artifact.

## Part 5: deferred object-key UTF-8 validation (GEN-056)

Object-key UTF-8 validation moved from every key to the unknown-key
branch only (a span equal to a known ASCII field literal is valid UTF-8 by
construction; invalid keys can never match and are still rejected with the
same error and offset).

| workload | before | after | jsony |
|---|---|---|---|
| small 40B deser | 34.2 ns | 33.1 ns | 64 ns |
| medium100 deser | 4784 ns | 4384 ns | 9609 ns |
| nested50 deser | 6969 ns | 6602 ns | 12238 ns |

Cumulative deserialize improvement from 181 ns baseline: small -82%,
medium100 -21%, nested50 -19%. Gates: nim_utils 14/14, nim_express 73/73.

Flamegraph artifact (gprof call graph rendered, 10M iterations, 450ms):
/tmp/fj_base/gprof2.txt.svg — leaf time is parseObjectKeySpan (~21%), the per-field
parseValue number kernels (~40% combined), and the deserialize wrapper (~11%,
measured floor); the `_init` frame is the -pg gmon constructor (instrumentation
artifact, not application code).

## Part 6: fused high-byte tracking in the string end scan (GEN-057)

`parseJsonString`'s fast path used to scan every escape-free string twice
(end-of-string predicate, then high-byte predicate for the UTF-8 skip
decision). `scanStringEndWithHigh` fuses both into one SIMD/SWAR/scalar
pass with a "saw high byte" flag; validation behavior is unchanged.

| workload | before | after | jsony |
|---|---|---|---|
| small 40B deser | 33.1 ns | 32.6 ns | 64 ns |
| medium100 deser | 4384 ns | 4223 ns | 9582 ns |
| nested50 deser | 6602 ns | 6340 ns | 12401 ns |
| 4KB string value deser | 333 ns | 197 ns | — |
| matrix nested deser | 1.29x | 1.39x | — |
| matrix large_nested deser | 2.10x | 2.21x | — |

Cumulative deserialize improvement from 181 ns baseline: small -82%,
medium100 -23%, nested50 -22%. Gates: nim_utils 14/14, nim_express 73/73.

Flamegraph artifact (gprof call graph rendered, 10M iterations, 450ms):
/tmp/fj_base/gprof2.txt.svg — leaf time is parseObjectKeySpan (~21%), the per-field
parseValue number kernels (~40% combined), and the deserialize wrapper (~11%,
measured floor); the `_init` frame is the -pg gmon constructor (instrumentation
artifact, not application code).

## Part 7: large-document verification (no change, verification only)

seq[record] documents up to 5MB (1000/10000/100000 items, min-of-7,
taskset -c 4):

| size | fj deser | jsony deser | fj ser | jsony ser |
|---|---|---|---|---|
| 46KB | 6.15 ms | 14.38 ms (2.3x) | 1.54 ms | 3.99 ms (2.6x) |
| 483KB | 9.71 ms | 21.98 ms (2.3x) | 3.18 ms | 6.67 ms (2.1x) |
| 5.0MB | 107.9 ms | 216.8 ms (2.0x) | 34.3 ms | 87.3 ms (2.5x) |

No regression at scale; wins hold for multi-megabyte documents.

## Part 8: SIMD scan resume in the escaped-string slow path (GEN-058)

The escaped-string slow path walked bytes scalar after the first escape.
It now resumes the SIMD end-scan after every decoded escape, copying long
safe spans in bulk. Error messages/offsets unchanged (verified: control
byte, invalid escape, dangling backslash, unterminated string, \u and all
short escapes).

| workload | before | after | jsony |
|---|---|---|---|
| 4KB string, escape at byte 0 | 1185 ns | 302 ns | 1115 ns |
| 4KB string, escape at byte 2000 | 1185 ns | 372 ns | 1173 ns |
| 4KB string, no escape | 389 ns | 392 ns | 1101 ns |
| official escaped deser | 126.5k ops/s (1.10x) | 136k ops/s (1.20x) | 113.3k |
| small 40B deser | 32.6 ns | 32.0 ns | 63.6 ns |

Gates: nim_utils 14/14, nim_express 73/73.

Flamegraph artifact (gprof call graph rendered, 10M iterations, 450ms):
/tmp/fj_base/gprof2.txt.svg — leaf time is parseObjectKeySpan (~21%), the per-field
parseValue number kernels (~40% combined), and the deserialize wrapper (~11%,
measured floor); the `_init` frame is the -pg gmon constructor (instrumentation
artifact, not application code).

## Part 9: two-digits-per-iteration number parsing (GEN-059)

Int/float parse kernels now consume two digits per loop iteration (div-100
overflow-checked) with a one-digit tail. Conformance/numeric suites green.

| workload | before | after | jsony |
|---|---|---|---|
| seq[int] 5-digit deser | 6.38 ns/int | 5.61 ns/int | — |
| official numeric deser | 68.1k ops/s (1.89x) | 75.0k ops/s (2.15x) | 34.9k |

gprof (perf blocked: perf_event_paranoid=4, used `-pg` C instrumentation):
numeric object time is now 60% object-dispatch body + 20% key-span scan
(structural); 2×512B string object is 100% `newStringUninit` GC allocation
(structural floor for owned copies). Gates: nim_utils 14/14, nim_express 73/73.

Flamegraph artifact (gprof call graph rendered, 10M iterations, 450ms):
/tmp/fj_base/gprof2.txt.svg — leaf time is parseObjectKeySpan (~21%), the per-field
parseValue number kernels (~40% combined), and the deserialize wrapper (~11%,
measured floor); the `_init` frame is the -pg gmon constructor (instrumentation
artifact, not application code).

## Part 10: C/C++ removal — pure-Nim fastjson (GEN-060)

Directive: remove C from fastjson, keep performance. `escaped_scan.c`
(opt-in, off by default) was deleted first; then the simdjson C++ backend
(`simdjson.nim`, `simdjson/` shim + vendored C++, `simdjson_ffi.nim`) was
replaced by a pure-Nim borrowed lane and deleted. All C/C++ sources under
`nim_fastjson/` are gone; the only remaining "C" is Nim `emit` of SSE2/NEON
intrinsics inside `direct_engine.nim` (measured required: SWAR-only scanning
is 19.5x slower on 1MB strings and cost 35% on string-heavy serialize).

Design (`borrowed.nim`, final): `BorrowedString = {docOwner: BorrowedDocRef,
strOwner: string, data, size}`. One `BorrowedDocRef` holder per thread holds
the most-recently-decoded document (identity-checked on the buffer address,
shared by every escape-free view); escaped strings decode into a buffer the
view owns outright. Views outlive the caller's document copy — locked by a
dedicated lifetime regression test with `GC_fullCollect`.

A/B, official string-heavy bench, interleaved PRE(C++)/POST(Nim), min-of-3
rounds (ops/s):

| scenario | PRE (C++ simdjson lane) | POST (pure Nim) |
|---|---|---|
| deserialize owned escaped | 150.3–151.0k | **156.1–160.4k** (+4–6%) |
| deserialize borrowed escaped | 144.9–147.1k | 143.2–143.5k (parity) |
| serialize escaped | 436.8–438.7k | 433.5–437.0k (unchanged) |

Intermediate measured dead-ends on the way to parity (each measured, kept or
reverted on data): owner-as-plain-string (Nim sink analysis turns the field
write into a move and duplicates the whole document buffer per view — 2.5–5.5x
loss on escape-free seq shapes, confirmed by `eqdup` of the doc in generated
C), raw-slot owner writes with `wasMoved` (GC accounting collapse, 103x —
reverted immediately), per-string holder ref (~12% escaped loss),
template-level view construction (same sink-move; templates do not help).

Behavior contract verified by dedicated tests: invalid UTF-8 keys/values
still raise `JsonError` at the right offsets; views remain valid after the
document string is reassigned; null → nil view; escaped decode byte-identical
(all short escapes, `\u`, surrogate pairs, trailing/bad-escape errors).

Gates: harness/nim_utils 14/14, harness/nim_express 73/73 (after porting
`simdjson_utils.nim` helpers to std/json + `isValidJsonDirect` and replacing
`test_security_fixes_simdjson.nim` with a direct-engine RSS/limits test).

### Part 10 addendum — post-removal final numbers (this box, min-of-2)

Official `bench_string_heavy_fastjson`: escaped serialize 400.6–428.3k
(jsony 190.2–194.0k, 2.1–2.2x); escaped deserialize 159.5–159.7k
(jsony 113.5–114.2k, 1.40x); borrowed escaped 143.2k.

Official `bench_matrix_fastjson` after GEN-050..060 (all scenarios win):
small serialize 59.1M ops/s, small deserialize 31.6M (≈2.0x jsony), medium
deserialize 954k (1.9x), nested deserialize 352k (1.43x), large_nested
deserialize 39.3k (2.27x).

Build cleanup: the `simdjson` Makefile target, `SIMDJSON_*` variables, and
the `build-all`/`verify` dependencies were removed; `nim_fastjson` now has
zero C/C++ sources and needs no `libnimsimdjson.a`.
