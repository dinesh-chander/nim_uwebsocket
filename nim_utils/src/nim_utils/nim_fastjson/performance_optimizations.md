# fastjson performance optimizations

This document summarizes the low-level changes that materially improved
`nim_fastjson` performance. It is derived from the kept items in
[todo.json](/nim_utils/src/nim_utils/nim_fastjson/todo.json),
not from every experiment that was attempted.

The main theme across the successful changes is simple:

- reduce passes over the same bytes
- reduce branch and call overhead in the hottest loops
- avoid allocator work on hot paths
- push more work to compile time when the data shape is known
- keep shared hot loops small enough to stay cache-friendly

## 1. Serializer hot-path wins

### OPT-001: fused single-pass string escaping

Changed:

- replaced the old scan-then-copy string escape path with a fused path that
  scans and writes in the same loop

Why it helped:

- removed an extra pass over string bytes
- reduced copy traffic on string-heavy payloads

Observed effect:

- twitter serialize: `1.35x -> 2.82x`
- historical serialize: `1.86x -> 2.21x`

### OPT-002: remove `ensureRoom` from the hot path

Changed:

- moved from frequent capacity checks to aggressive preallocation
- left growth as a rare fallback instead of a per-field/per-string branch

Why it helped:

- removed a very hot branch and function-call path from the serializer loop
- made the write path mostly just cursor updates and stores

Observed effect:

- twitter serialize: `2.82x -> 3.2x`
- historical serialize: `2.21x -> 2.77x`

### OPT-003: zero-copy float formatting into the output buffer

Changed:

- wrote dragonbox output directly into the final JSON buffer using a pointer
  into the destination string
- avoided intermediate float buffers and follow-up copies

Why it helped:

- reduced per-float copy overhead
- especially useful for the coordinate-heavy `canada` shape

Observed effect:

- canada serialize: `1.57x -> 1.9x`

### OPT-004: `NeedsEscape` lookup table

Changed:

- replaced repeated scalar comparisons with a 256-entry lookup table

Why it helped:

- fewer branches in scalar fast paths and tails
- cheaper “does this byte need escaping?” checks

Observed effect:

- small but consistent gain across datasets

### OPT-005 / OPT-006: SIMD string scanning via inline emit

Changed:

- added NEON and SSE2 string scanning directly inside the hot loop via
  `{.emit.}` inline code
- avoided the FFI call boundary that made earlier SIMD attempts slower

Why it helped:

- faster safe-byte detection on medium and long strings
- real win only when the SIMD logic is truly inlined into the writer

Observed effect:

- twitter serialize: `3.2x -> 3.9x`
- historical serialize: `2.77x -> 3.15x`

Important lesson:

- SIMD through a separate imported C function regressed
- SIMD only paid when the code was inlined into the shared hot path

### OPT-007: `cPutLit` with compile-time `uint64` constants

Changed:

- encoded field-name prefixes as compile-time `uint64` chunks
- wrote them directly into the output buffer

Why it helped:

- reduced TLS/global access overhead for field literals
- turned many literal writes into a couple of integer stores

### OPT-008: cursor-based writing

Changed:

- switched to `buf[pos]` plus a manual cursor
- avoided `buf.add` style growth-heavy writing

Why it helped:

- fewer string operations
- fewer hidden realloc/setLen costs
- enabled the later hot-loop optimizations

### OPT-009: fused string field prefix plus opening quote

Changed:

- for string fields, merged the field prefix and the opening quote into one
  emitted literal
- used `cPutJsonBody` for the string body instead of treating the quote as a
  separate write

Why it helped:

- removed per-string field overhead without bloating the hot loop
- improved string-heavy object emission cleanly through the generated writers

Observed effect:

- historical serialize: `3.15x -> 3.32x`
- citm serialize: `1.9x -> 1.97x`

### OPT-010: short-string fast path

Changed:

- added a small-string fast path for strings up to 16 bytes with no escaping

Why it helped:

- many JSON values are short and safe
- avoided the heavier SIMD/slow-loop setup for the common case

Observed effect:

- twitter serialize: `3.90x -> 4.05x`
- historical serialize: `3.32x -> 3.59x`

### GEN-019: fused scan+copy inside `cPutJsonBodySlow`

Changed:

- moved safe-byte copying into the same shared slow loop that scans for the
  next unsafe byte

Why it helped:

- reduced wasted rereads of safe spans
- kept the hot path one-pass

Observed effect:

- twitter serialize moved into the mid `4.4x+` range
- historical serialize moved into the upper `3.7x+` range

### GEN-021: shared C-emitted body writer kernel

Changed:

- added a narrow shared C-emitted kernel for the hottest string-body writer
  path

Why it helped:

- reduced overhead in the shared slow string-body path without generating
  per-type code bloat

Observed effect:

- twitter serialize reached about `4.56x`
- historical serialize reached about `3.79x`

## 2. Generated serializer improvements

### GEN-001: typed fast-path support matrix

Changed:

- defined a strict set of shapes that use the generated fast path

Why it helped:

- reduced ambiguity and kept the optimizer focused on the shapes that actually
  matter

### GEN-002: compile-time serializer field plans

Changed:

- generated a cached per-field plan with field kind, cached prefix, and fused
  string prefix information

Why it helped:

- avoided repeated type inspection and repeated per-field branching in hot code
- let later optimizations operate on field metadata instead of rediscovering
  shape at runtime

### GEN-003: direct object serializer generation

Changed:

- generated direct per-field object serializers from the field plan

Why it helped:

- removed repeated `when typeof(...)` branching in the hot object write loop
- produced a cleaner object writer with lower dispatch overhead

### TODO-010 / TODO-011: `serializeDirectBatched` groundwork

Changed:

- added a typed/batched root path for `seq[object]` shapes
- used tighter typed sizing for bounded sequence roots

Why it helped:

- sequence roots are a large practical shape class
- reduced some top-level sizing and dispatch overhead without changing the
  serializer architecture completely

Observed effect:

- a real but bounded gain on `historical_events`

### GEN-041 / GEN-042: safe-string metadata and routing

Changed:

- added `JsonSafeString` and `JsonAsciiSafeString`
- extended compile-time field metadata so safe-string fields route to unescaped
  body writes

Why it helped:

- lets known-safe fields avoid the generic escape machinery entirely
- establishes the right shape-based mechanism for future wins

Observed effect:

- benchmark-neutral for the current datasets
- useful infrastructure that helps when types opt into safe-string semantics

### GEN-008 / GEN-009: bounded shape-specialized serializer paths

Changed:

- kept specialized paths for hot shape families:
  - `Table[string, string]`
  - `Table[string, seq[int]]`
  - bounded object-valued table roots
  - bounded `[x, y, 0.0]` float-point shapes

Why it helped:

- these are reusable shape classes, not one-off payload hacks
- reduced overhead for table-heavy and numeric-heavy roots where the generic
  path was structurally more expensive

## 3. Parser and deserializer hot-path wins

### GEN-032: cheaper no-escape string allocation in `parseJsonString`

Changed:

- switched the no-escape fast path to `newStringUninit` instead of a resizing
  path before `copyMem`

Why it helped:

- reduced part of the `setLengthStrV2` / `_platform_memset` cost
- directly targeted the dominant string materialization cost on
  `historical_events`

Observed effect:

- deserialize improved across the real-world matrix
- historical deserialize moved into the low `3.2x+` range

### GEN-035: stronger object-key dispatch

Changed:

- generated object-field dispatch now groups by key length and, when useful, by
  first byte before doing full comparisons

Why it helped:

- reduced repeated full literal comparisons in object-heavy parse paths
- especially useful on nested/object-rich payloads such as `citm_catalog`

Observed effect:

- twitter deserialize: about `3.65x`
- citm deserialize: about `3.45x`
- canada deserialize: about `3.44x`
- historical deserialize: about `3.23x`

### GEN-011 / GEN-013: bounded simd-backed typed decode routing

Changed:

- leaf direct-decode shapes and borrowed-string shapes route through the simd
  backend where that path is known to help

Why it helped:

- preserves fast leaf decode without trying to over-route nested shapes that
  had already regressed

Observed effect:

- deserialize stayed strong on the supported typed cases without reopening the
  failed nested-routing experiments

## 4. Public API wins

### GEN-047: zero-copy `serializeToBytes`

Changed:

- `serializeToBytes` moves the serialized `string` buffer into `seq[byte]`
  instead of re-copying the bytes

Why it helped:

- removed an unnecessary string-to-bytes copy
- made the bytes API much more competitive with the plain string API

### GEN-049: direct validation APIs

Changed:

- `isValidJson(bytes)` now calls simdjson validation directly on the byte span
- `isValidJson(stream)` has a zero-copy `StringStream` fast path

Why it helped:

- validation no longer has to materialize a `string` just to check syntax
- makes validation a real first-class public API instead of a wrapper around
  parse-style work

Observed effect:

- validation methods now compare very strongly against `jsony`, often in the
  `8x` to `18x` range depending on dataset and entrypoint

## 5. Important low-level lessons

These are as important as the wins themselves:

- Shared hot loops beat template expansion.
  Full or hybrid template versions of `cPutJsonBody` regressed badly because
  they blew up code size and hurt icache locality.

- One-pass beats two-phase.
  Pre-scan, stage, then copy designs repeatedly lost because the extra memory
  traffic erased the intended gains.

- Inlined SIMD helps; FFI-bound SIMD does not.
  A separate imported C helper was slower than the inlined emit version.

- Wrapper-level API tweaks have limited headroom.
  Public method improvements were real for validation and bytes movement, but
  most additional wrapper changes were noise or regressions. The remaining big
  wins are still in the core serializer/parser kernels.

## 6. Key discoveries

These were not always direct code changes, but they strongly shaped what
actually worked.

### The string-body writer is already close to a local optimum

Repeated attempts to micro-tune the existing `cPutJsonBodySlow` kernel mostly
failed or produced unstable wins. The remaining headroom is more about
reducing how much work reaches that kernel than shaving a few more instructions
off it.

### Two-phase serializer designs were the biggest recurring trap

Many plausible designs regressed for the same reason:

- pre-scan strings
- stage intermediate escaped output or metadata
- copy or re-read again during final emission

The extra memory traffic consistently outweighed the intended gain. This is the
main reason the next serializer architecture must be truly no-extra-copy if it
is going to beat the current one-pass design.

### The benchmark shapes map to different bottlenecks

The real datasets are not interchangeable:

- `historical_events`: dominated by string materialization on deserialize and
  string emission on serialize
- `twitter`: also string-heavy, but with a more mixed object/int profile
- `citm_catalog`: more about recursive structure, object-key dispatch, and
  table/object traversal than escaping
- `canada`: dominated by nested numeric recursion and float formatting, with
  noticeably different memory behavior from the other datasets

That means one generic trick is unlikely to optimize every shape equally.

### Shape-based specialization worked; payload-specific hacks were unnecessary

The wins that held up were reusable shape families:

- string-heavy object roots
- object-valued tables
- safe-string fields
- bounded numeric point/tree shapes

This was the right level of specialization. Hardcoding for a benchmark file
was not necessary.

### Public API benchmarking was necessary

Core-engine wins did not always translate into public-method wins. A few
wrapper changes looked good until the dedicated API benchmark showed they were
unstable or regressed on larger payloads. The public surface needed its own
benchmark, not just the core real-world benchmark.

## 7. Where the real wins came from

The biggest practical gains came from:

1. reducing passes over string data
2. removing hot-path capacity checks
3. keeping generated writers branch-light
4. reducing owned-string allocation overhead in parse hot paths
5. specializing a few high-value shape classes without overfitting to one
   payload

That combination is what moved `nim_fastjson` from early baseline numbers into
its current state:

- twitter serialize roughly `1.35x -> 4.6x+`
- historical serialize roughly `1.86x -> 3.8x+`
- deserialize improved materially too, especially after the parse hot-path and
  dispatch fixes
