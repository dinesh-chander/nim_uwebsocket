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

### GEN-050: leaf/nested shapes re-routed to the direct engine (supersedes the simd leaf route)

Changed:

- `deserialize` sends only borrowed-string shapes to the simd backend; leaf
  and nested shapes all go to `direct_engine.deserializeDirect`
- the simdjson ondemand max-depth/max-array-items FFI calls moved inside the
  simd branch so direct-path calls no longer pay them
- `selectedDeserializePath`/`selectedDeserializeEngine` now report what is
  actually used (`fjdpDirect`/`fjeDirect` for leaf and nested shapes); the
  `fjdpSimdLeaf`/`fjdpSimdNested` enum values are kept for API compatibility

Why it helped:

- on AVX2+AVX512 Linux hardware the simd leaf route cost a full ondemand
  token-walk validation pre-pass plus a second decode walk, while the direct
  engine does one pure-Nim pass with precomputed field plans
- measured 3.7x to 12.9x loss of the simd leaf route on small shapes
  (A/B report: docs/benchmarks/fastjson_leaf_reroute_ab_20261022.md)
- small-object deserialize flipped from 2.8x slower than jsony to 1.6x faster

Observed effect:

- SmallTodo 40B: 181ns to 39.2ns (jsony 64ns); wide 107B: 400.6ns to 124.6ns
  (jsony 231.7ns); scalar int root 63.7ns to 8.5ns
- borrowed-string shapes unchanged (still simd, zero-copy)
- both harness gates green (nim_utils 14/14, nim_express 73/73)

### GEN-051: `scanStringEnd` reuses the SIMD `scanSafeJsonBytes` kernel

Changed:

- the deserializer's per-string `scanStringEnd` used a scalar SWAR 8-byte
  loop that duplicated the exact predicate of `scanSafeJsonBytes` (quote /
  backslash / control byte)
- it now delegates to `scanSafeJsonBytes`, which scans 16 bytes per
  iteration with SSE2 on x86-64 and NEON on ARM64

Why it helped:

- half the iterations and vector comparison instead of scalar byte tests
  for every deserialized string value

Observed effect:

- small 40B document: 39.2ns to 36.5ns; medium100: 5534ns to 4804ns (-13%);
  nested50: 8110ns to 6931ns (-15%)

### GEN-052: ASCII fast path skips UTF-8 validation

Changed:

- added `containsHighByte`, an 8-byte-per-iteration shift-and-test scan that
  reports whether a span contains any byte 0x80 or higher
- `parseJsonString` (both the no-escape fast path and the escaped slow path)
  and `ensureValidJsonUtf8Span` now run the full `validateUtf8` pass only
  when high bytes are actually present; pure-ASCII strings are valid UTF-8 by
  definition and skip validation entirely

Why it helped:

- `validateUtf8` measured 0.126ns per byte (a full re-read of every string),
  which dominated deserialized string cost (0.168ns per byte marginal before)
- the high-byte pre-check costs roughly one op per 8 bytes, so ASCII strings
  now pay about 0.006ns per byte instead of 0.126ns

Observed effect:

- single-string deserialize marginal cost at 4KB: 0.168ns/B to 0.081ns/B
  (687ns to 333ns total for a 4096-byte string)
- small 40B document: 36.5ns to 35.3ns; medium100: 4804ns to 4748ns;
  nested50: 6931ns to 6894ns
- first cut forgot the end boundary in the key-span pre-check and scanned to
  the end of the document per key (6.5x slower on medium shapes); fixed by
  passing the span end into `containsHighByte`

### GEN-053: AVX2 32-byte scan kernels — measured, rejected

Tried runtime cpuid AVX2 detection plus `target("avx2")` 32-byte scan and
fused scan+copy kernels for `scanSafeJsonBytes` and
`copySafeJsonBytesFused`. Result: no gain on serialize (0.031ns/B unchanged)
and slightly worse deserialize (extra call plus branch overhead per scan).
The scan is uop-bound, not iteration-bound: 32 bytes per iteration doubles
the compare/movemask uops, so the per-byte cost stays the same. Reverted.

### GEN-054: 3-digit chunk integer formatting (DigitTriples)

Changed `appendIntFast` from 2-digit (div/mod 100) to 3-digit (div/mod 1000)
chunking with a 1000-entry `DigitTriples` table, cutting the number of
64-bit integer divisions per value.

Measured (standalone microbench, 5-digit values, min-of-7):

- pairs div-100 kernel: 5.14 ns/int
- triples div-1000 kernel: 4.80 ns/int

A 4-digit (div 10000, 2048-entry) variant measured worse (7.3 ns/int), and
an unchecked per-char literal append for field keys was slower than the
standard `buf.add(static)` path (3.74 vs 1.22 ns/field), so both were
rejected.

Full-bench note: the int-heavy serialize scenario in
`bench_varied_types.nim` still reads 0.82-0.90x vs jsony in the full
benchmark binary, but an isolated replica of the same shape (same harness,
only the int-heavy block) shows fastjson winning 1.18x (1.31us vs 1.55us).
The jsony number is identical in both binaries (1.6us); only fastjson
degrades when the other benchmark code is compiled in, which points to
instruction-cache pressure from the larger binary rather than an
algorithmic loss.

### GEN-055: cached strict-defaults option validation

`FastJson` now computes `strictDefaults` and `strictSerializeDefaults`
once in `initFastJson`. When every option that
`validateDeserializeOptions` / `validateSerializeOptions` would reject is
at its default value, the per-call option checks are skipped (the
maxInputBytes length check stays on every path).

Measured (min-of-7):

- int root deserialize: 8.5 → 6.3 ns/op (jsony 3.2)
- small 40B object deserialize: 35.3 → 34.2 ns/op (jsony 64)
- medium/nested unchanged within noise

## 4. Public API wins





### GEN-056: deferred object-key UTF-8 validation

`parseObjectKeySpan` used to run `ensureValidJsonUtf8Span` on every
object key before field dispatch. A span that equals a known ASCII field
literal is valid UTF-8 by construction, so that scan was pure overhead on
every matched field. Validation is now deferred to the unknown-key branch:
the span dispatch macro routes unmatched keys through `skipUnknownJsonKey`,
which validates the span and then skips the value. Invalid UTF-8 keys can
never equal an ASCII literal, so they always reach the validating branch
and are rejected with the same message and offset as before (covered by a
manual conformance check: `{\xff...}` and `{\xc3\x28...}` keys still raise
`invalid UTF-8 in string`).

Measured (min-of-7):

- small 40B object deserialize: 34.2 → 33.1 ns/op
- medium100 deserialize: 4784 → 4384 ns/op (-8.4%, jsony 9609)
- nested50 deserialize: 6969 → 6602 ns/op (-5.3%, jsony 12238)

### GEN-057: fused high-byte tracking in the string end scan

After GEN-052, `parseJsonString`'s fast path ran two passes over every
escape-free string: `scanStringEnd` (quote/backslash/control predicate) and
`containsHighByte` (high-byte predicate). `scanStringEndWithHigh` merges
them into one pass: the same SIMD/SWAR/scalar kernels as `scanSafeJsonBytes`
plus a "saw a high byte" flag — the SSE2/NEON kernels take the movemask
once per chunk and OR its non-zero-ness into the flag, the SWAR kernel reuses
its existing shift-and-test word, and the scalar tail checks each byte.
The fast path then calls `ensureValidJsonUtf8` only when the flag is set,
and the result is byte-identical to the two-pass version (ASCII strings
skip validation exactly as before; high-byte strings validate exactly as
before).

Measured (min-of-7):

- small 40B object deserialize: 33.1 → 32.6 ns/op
- medium100 deserialize: 4384 → 4223 ns/op (-3.7%, jsony 9582)
- nested50 deserialize: 6602 → 6340 ns/op (-4.0%, jsony 12401)
- 4KB string value deserialize: 333 → 197 ns/op (marginal 0.081 → 0.048 ns/B)
- official matrix deserialize vs jsony: nested 1.29x → 1.39x, large_nested 2.10x → 2.21x

### GEN-058: SIMD scan resume in the escaped-string slow path

The `parseJsonString` slow path (strings containing escapes) copied the
safe prefix with the SIMD scan but then walked the remainder byte by byte
in a scalar loop. It now resumes `scanStringEnd` after every decoded
escape, so long safe spans between escapes are scanned and copied in bulk.
Error messages and offsets are unchanged (control-byte, invalid-escape,
expected-escaped-character, unterminated-string all verified).

Measured (min-of-7, 4KB string with one `\n` escape):

- escape at byte 0: 1185 → 302 ns/op (3.9x)
- escape-free 4KB: 389 ns unchanged
- official escaped-string deserialize: 126.5k → 136k ops/s (1.10x → 1.20x vs jsony)
- non-escaped workloads unchanged (small 32.0 ns, medium100 4266 ns, nested50 6260 ns)

### GEN-059: two-digits-per-iteration number parsing

The unsigned-int kernel and the float fast path (integer part and fraction
part accumulators) walked numbers one digit per loop iteration. They now
consume two digits per iteration (`raw * 100 + pair` with a matching
div-by-100 overflow check) plus a one-digit tail, so a 5-digit number takes
3 iterations instead of 5. Overflow, leading-zero, and range behavior are
unchanged (conformance/numeric suites green).

Measured (min-of-7):

- seq[int] 5-digit values: 6.38 → 5.61 ns/int (12%)
- official numeric deserialize: 68.1k → 75.0k ops/s (1.89x → 2.15x vs jsony)
- gprof flat profile of a 6-field numeric object after this change: 60% object
  dispatch body, 20% key-span scan, number parsing a small share — the
  remaining time is structural dispatch work
- gprof on a 2×512B string object: 100% `newStringUninit` (GC allocation)
  — owned string copies are allocation-bound, a structural floor

### GEN-060: pure-Nim borrowed lane + single-allocation escape decode

Two related changes shipped together when the simdjson C++ backend was
removed (see A/B report Part 10):

1. **Pure-Nim borrowed decoding.** `BorrowedString` / `JsonStringView` fields
   now decode on the direct engine. Escape-free strings borrow the document
   bytes through one shared `BorrowedDocRef` per document (a threadvar holder
   keyed on the buffer address; views copy only the small ref). Strings with
   escapes decode once into a buffer the view owns outright
   (`borrowOwned`). Pitfall discovered: an `owner: string` field makes Nim's
   sink analysis move the document string into every view write and duplicate
   the whole buffer at the call site (measured 2.5-3.6x on borrowed seq
   shapes; `eqdup` of the full doc per view in generated C). A `ref`-typed
   shared owner removes the string from the per-view write entirely.
2. **Single-allocation escape decode (also owned strings).**
   `parseJsonStringEscaped` first locates the closing quote, allocates the
   raw length once (`newStringUninit` — every escape shrinks, so raw length
   is an upper bound), writes safe spans and decoded bytes straight into the
   buffer, and truncates once at the end. This replaced per-span `setLen`
   growth plus per-escape `add()` calls, which gprof showed as 26% of
   escaped-deserialize time (`prepareAdd` + `setLengthStrV2`).

Measured (min-of-7, official string-heavy bench, before = C++ simdjson lane):

- owned escaped deserialize: 150.7k → 156–160k ops/s (1.39x → 1.42x vs jsony)
- borrowed escaped deserialize: 144.9–147.1k (C++) → 143.2k (pure Nim, parity within noise)
- synthetic escape-free borrowed seq shapes still cost ~2.5x the owned path:
  a GC-managed view record (ref + string owners) pays per-element copy hooks
  through `seq.add`; a POD view would remove them but cannot keep the
  document alive after the caller drops it (the old C++ lane never decoded
  this shape either, so there is no regression against the baseline)

Contract preserved: invalid UTF-8 rejected, lone surrogates encode
byte-identically to `std/unicode` `add(Rune)`, control bytes / bad escapes /
unterminated strings report the same offsets, views stay valid after the
caller drops the document string (holder / owned buffer keep the bytes —
covered by the "borrowed views stay valid after the document is dropped"
regression test, raw UTF-8 and escape-decoded views, `GC_fullCollect` in
between).

### GEN-061: pure Nim end to end - emitted SSE2/NEON kernels removed

- The last C in the package was five `{.emit.}` kernel regions
  (`scanSafeJsonBytes`, `scanStringEndWithHigh`, `copySafeJsonBytesFused`,
  `cPutJsonBodySlow`, plus the intrinsic `#include` block). All replaced by
  the portable SWAR scanners (8 bytes/`uint64`, unique-byte-OR trick reused
  from fast_map).
- Kernel microbench (1 MB safe string): SSE2 30.5 ns vs SWAR 102 ns per MB;
  auto-vectorization is blocked by the data-dependent break and byte-wise
  borrow semantics, so the gap is the price of pure Nim.
- End-to-end cost is limited to long escaped-string serialization
  (`bench_string_heavy` serialize 428k -> 291k ops/s, still 1.5x jsony).
  Every other official benchmark is at parity or better: string deserialize
  159.5k -> 170.9k, borrowed 143k -> 151.5k, numeric serialize 91k -> 106k,
  numeric deserialize 75k -> 83.5k, matrix unchanged (not scan-bound).
- `scanStringEndWithHigh` now detects high bytes byte-exactly: an OR-accumulator
  that persisted across chunks leaked `sawHigh` from an earlier string into the
  next one and skipped required UTF-8 validation (caught by
  `test_rfc8259_compliance_fixes` - truncated multibyte in the raw fast path).
  ASCII-only chunks still advance 8 bytes at a time; the first chunk holding a
  high byte or terminator switches to the scalar tail.
- Decision record: a 1 MB scan microbench earlier suggested keeping the emit
  kernels (35% string-heavy serialize loss). Re-measured end to end on every
  official benchmark, the loss is confined to one scenario that still beats
  jsony by 1.5x, while several scenarios improved - so full C removal is the
  adopted trade. See `docs/benchmarks/fastjson_leaf_reroute_ab_20261022.md`
  Part 11.

### GEN-062: perfect-hash object key dispatch

- Same-length field groups with four or more entries now dispatch through a
  compile-time perfect hash (unique byte pair `(s[keyStart+p1], s[keyStart+p2])`
  searched in `findPerfectSig`, dispatched as a `case` switch) instead of the
  first-character chain plus linear `spanEquals` walk.
- Each hash branch still verifies the full name with `spanEquals` before
  parsing, so an unknown key whose bytes collide with a signature is skipped
  via `skipUnknownJsonKey` (UTF-8 validation included), never mis-parsed.
- Measured (wide-object bench, 8/18 same-length fields): deserialize
  112.1 -> 72.4 ns (-35%) and 344.0 -> 198.1 ns (-42%). Objects with three or
  fewer fields per length group keep the old chain; all official benchmarks
  unchanged (they never hit four same-length keys).

### GEN-063: exact fast path for JSON float exponents

- `parseValue[SomeFloat]` previously bounced every `1.5e10`-style token to
  `parseFloat`. It now folds the decimal point into an integer mantissa
  (`intPart * 10^fracDigits + fracPart`, capped at 15 digits) and computes
  the net decimal exponent `eNet = exp - fracDigits`:
  - `eNet == 0`: `float64(m)` directly;
  - `0 < eNet <= 19` and `m <= U64Pow10Limit[eNet]`: `float64(m *
    U64Pow10Table[eNet])` - the product is an exact uint64, so the single
    int-to-float conversion is correctly rounded;
  - `-15 <= eNet < 0`: `float64(m) / 10^-eNet` - both operands are exactly
    representable (`10^15 < 2^53`), so the IEEE division is correctly rounded.
  Everything else falls back to `parseFloat` as before.
- A naive `value * pow10` fast path was measured first and REJECTED: 6158 of
  30000 random exponent documents differed from strtod by one ULP. The exact
  integer variants above cannot drift: a 30000-case randomized sweep against
  `parseutils.parseFloat` shows zero mismatches.
- Exponent-heavy four-float document deserialize 66.7 -> 62.6 ns/op (jsony
  79-81 ns); no-exponent and official numeric paths untouched.

### GEN-064: fused UTF-8 high-byte detection in the skip path

- `skipJsonString` and `skipJsonObjectKey` (used for unknown fields, array
  elements of skipped objects, and `isValidJsonDirect`) scanned each string
  segment twice: once for the quote/backslash terminator, once inside
  `ensureValidJsonUtf8Span` for the high-byte pre-check. Both now use
  `scanStringEndWithHigh` and validate only when the fused scan saw a high
  byte - the GEN-057 trick applied to the skip path.
- Unknown-field-heavy document (40 skipped string fields) deserialize
  522 -> 501 ns (-3.4%). Invalid UTF-8 inside skipped keys and skipped values
  is still rejected (verified with raw `0xFF` probes); `isValidJsonDirect`
  stays 10x faster than std `parseJson` (2.27 us on a 3 KB nested doc).

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

### GEN-065: round-two measured-and-rejected candidates (documented floors)

Six further candidates were implemented, measured, and rejected on this box
(Intel Core Ultra 7 265K, min-of-7, `taskset -c 4`); none changed the tree:

- pretty-printed deserialize: already 1.77x jsony - nothing to change.
- byte-loop copy until unsafe byte in `copySafeJsonBytesFused` for short
  escaped segments: within noise of the SWAR + `copyMem` form.
- seq[T] decode capacity pre-estimation (four variants: remaining-bytes
  floor, static-overhead floor, first-item width probe, min-cap gate): the
  probe variant won -5.6% on flat 100k-item docs but lost 8-17% on nested
  trees (`buildNested(64,8,6)`) because remaining bytes include all
  descendants; every variant net-negative overall.
- negative-int serialize via the unsigned chunk path: 14.55 vs 14.3 ns/int;
  Nim `$` on int64 is already fast C, the temp string is not the bottleneck.
- custom UTF-8 validator (SWAR 8B word skip + scalar rune walk, validated
  byte-exact strict-UTF-8 against a reference decoder with exhaustive
  1-4 byte sequences plus 300k random inputs): 0.38 ns/B on CJK-dense text
  vs std 0.30 (std `validateUtf8` already runs near one cycle per rune) and
  only +2% on mixed script. Rejected; std kernel retained.
- object-serializer literal batching: the cursor path already fuses the
  field prefix and opening quote into one 8-byte store (`cPutLit`,
  `writeObjectFieldsC`); nothing left to merge.

Residual documented here: raw-multibyte string deserialize measures 237 vs
jsony 158 ns on a 900-byte CJK payload because fastjson validates UTF-8
(RFC 8259 requirement) and jsony does not. That gap is a conformance
feature, not a kernel gap; `\u`-escaped unicode input (the shape jsony
handles at parity) runs 1.8x faster in fastjson.

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

## 8. Deserialize path rework

Before this change, `deserialize` paid for up to three full passes over the
input:

1. a Nim byte scan for depth validation (`validateJsonDepth`),
2. a full simdjson **DOM** parse as an up-front validity pre-check
   (`isValidJson`),
3. the actual simdjson **ondemand** decode.

ondemand parse validation is lazy: token errors only surface when the token is
consumed, so targeted field access never sees malformed bytes in unvisited
regions. The full-document check was therefore mandatory — but it did not have
to be a DOM parse.

### DESER-001: ondemand token-walk validation instead of DOM pre-parse

Changed:

- added `nim_simdjson_ondemand_validate` to the C shim: one recursive
  ondemand walk that forces consumption of every token (keys, values,
  scalars), returning the first simdjson error if any
- the wrapper now calls that walk as its sole pre-pass before
  `deserializeViaSimd`
- removed `validateJsonDepth` (the Nim byte scan) and the `isValidJson` DOM
  pre-check from the wrapper; the direct engine's own depth counter is now
  bounded per call via `setJsonParseDepthLimit` (a threadvar, restored via
  defer)

Why it helped:

- ondemand walking builds the tape but does not materialize DOM elements, so
  the validation pass is cheaper than the DOM parse it replaced
- the Nim-side depth scan is gone entirely (depth is enforced natively by the
  parser on both backends)

Observed effect (506KB string-heavy nested payload, release build, 5-round
interleaved A/B):

- simd-path deserialize: 548.9us -> 397.3us (1.38x, -28%)
- direct-path deserialize (76KB): 121.8us -> 98.8us (1.23x, -19%)
- serialize: unchanged (122.6us -> 125.2us, within noise)

### DESER-002: thread-local ondemand scratch parser reuse

Changed:

- the shim reuses one `simdjson::ondemand::parser` per thread
  (`g_ondemand_scratch_parser`) across the capture, projection, validate, and
  typed-decode entry points instead of constructing a fresh parser for every
  call

Why it helped:

- parser construction allocates a JSON implementation and its tape buffers on
  the heap every time; reuse keeps them warm and avoids the per-call
  allocation traffic

### DESER-003: native ondemand depth limit

Changed:

- patched the vendored `simdjson.h` to expose `set_max_depth` on the ondemand
  parser (7 declaration sites + 7 definition sites; upstream only ships it on
  the DOM parser)
- the shim applies the wrapper's `maxDepth` option to the ondemand parser
  before each parse; `maxDepth=0` restores the simdjson default

Effect:

- depth bombs are rejected natively by the ondemand backend (previously the
  DOM pre-parse did that work)
- `nim_fastjson` depth semantics now hold on both backends

Security note: the no-pre-parse behavior is NOT "parse without validation".
Every simd-backed `deserialize` still validates the full document (the
ondemand walk) before decoding; only the validation mechanism changed.

## Option A (single-pass zero-copy capture) — investigated, NOT merged

The per-level parser pool + borrowed tape views below were built and validated
on `perf/nim-json-singlepass`; measured parity with the baseline at realistic
sizes, so the complexity was not merged. Findings kept here for the record.

Design: the simdjson shim keeps one thread-local ondemand parser per decode
depth (level 0 = root, levels 1..3 = nested sub-slices). The root tape stays
alive while nested decodes run, so captured strings and sub-slice views
**borrow pointers into the owning parser's tape** instead of malloc+memcpy.
A `flags` field on every captured value/entry records ownership
(`NIM_SIMDJSON_DATA_OWNED`); release functions skip `free` for borrowed
views. `level` is threaded through all 6 C entry points, the FFI, 18 decode
overloads, and the 3 projection macros (root = 0, nested fields = level + 1).

### Measured effect (A/B, 5 alternating passes, best-of-30 per size)

Payload: 1000-item tweet envelope ≈ 294 KB, 4000 items ≈ 1.2 MB.

| items | bytes | baseline 85747c7 | singlepass | verdict |
|-------|-------|------------------|------------|---------|
| 10    | 2.8 KB   | 2.75–8.75 µs | 2.75 µs | within noise, trend positive |
| 100   | 29 KB    | 28.2–48.2 µs | 28.0–28.5 µs | ~1.7x on cold runs, parity warm |
| 1000  | 294 KB   | 278–284 µs | 280–284 µs | **parity** |
| 2000  | 595 KB   | 433–564 µs | 435–564 µs | **parity** (system bimodality in both) |
| 4000  | 1.2 MB   | 872–889 µs | 873–890 µs | **parity** |

Honest conclusion: eliminating the C-side string/sub-slice copies does not
move end-to-end time at realistic sizes, because the Nim side still copies
every string once (`copyCString`) and the C pipeline was already ~50% of the
total (C: ~226 µs, Nim materialization: ~210 µs at 595 KB). The complexity
(level threading, ownership flags, parser pool) is a prerequisite for
Option B (schema-recursive single-pass C decode with no Nim-side copy),
which is the only design that can close the remaining gap.

### Correctness

- all 5 fastjson suites green (core, comprehensive, conformance, standard,
  simdjson security) plus 4 new escaped-string regression tests for nested
  seq-of-object fields (unicode, mention-level, control/quote, surrogate
  pair)
- no debug instrumentation left in the tree (direct_engine.nim has zero diff)

Test-authoring pitfall discovered while validating: Nim **triple-quoted
strings treat backslashes as literal** (`"""\u0041"""` is a real backslash
at runtime, i.e. a genuine JSON escape; `"""\\u0041"""` is a JSON-escaped
backslash + literal `u0041`). Regular strings do the opposite (`"\\u0041"`
is a real backslash). When writing escape tests, build or self-check the
runtime document (e.g. `check doc[pos] == '\\'`) instead of trusting the
literal.

## Option B investigation (schema-recursive C decode routing) — `perf/nim-json-optb`

Hypothesis: routing arbitrary nested object/seq-of-object shapes to the
simdjson single-pass native plan (C tree extraction, ~226 µs C-side at 595 KB)
would beat the pure-Nim direct engine.

Measured A/B (best-of-30, 5 alternating passes), same payload shape:

| items | bytes | direct engine (main) | native plan routing | verdict |
|-------|-------|----------------------|---------------------|---------|
| 10    | 2.8 KB   | 3.5 µs   | 6.0 µs    | 1.7x slower |
| 100   | 29 KB    | 28.3 µs  | 62.8 µs   | 2.2x slower |
| 500   | 147 KB   | 139 µs   | 401 µs    | 2.9x slower |
| 1000  | 294 KB   | 280 µs   | 721 µs    | 2.6x slower |
| 2000  | 595 KB   | 563 µs   | 1523 µs   | 2.7x slower |
| 4000  | 1.2 MB   | 907 µs   | 3143 µs   | 3.5x slower |

The C-side 226 µs extraction ceiling was real, but Nim-side materialization
of the C value tree (~70 ns/node of macro dispatch per item field) dominates:
4000 items × ~10 fields ≈ 40k nodes ≈ 2.8 s/1000 decodes. Beating the direct
engine would require the C side to write directly into Nim object memory
(zero materialization), which is a far larger architecture change with no
evidence it wins on this hardware.

Decision: **routing reverted** — the pure-Nim direct engine stays the champion
for general shapes; the simd macro path stays pre-pass-validated for
leaf/borrowed shapes; the special envelope shapes keep their dedicated paths.

What this branch **keeps** (security, previously unenforced on the simd side):

- `maxDepth` is enforced on every simd decode entry. Vendored simdjson's
  ondemand `set_max_depth` is a no-op for enforcement (dev-checks only), so
  the shim now tracks plan depth in the native-plan extraction recursion and
  per-level depth in both special envelope paths, returning `DEPTH_ERROR`.
  Semantics: `maxDepth` must be ≥ the type's nesting depth (root object = 1).
- `maxArrayItems` is enforced on the native-plan + special paths via a new
  `NIM_SIMDJSON_ERR_ARRAY_TOO_LARGE` error code
  (`nim_simdjson_set_ondemand_max_array_items`); the wrapper sets it from
  `fj.options.maxArrayItems` for every deserialize.
- The native plan's parser now applies `set_max_depth` per parse
  (`typed_decode_parser()`), matching the other ondemand entries.
- New regression tests: native-plan depth + array-limit enforcement.

Known remaining gap (pre-existing, out of scope): the simd **macro** path
(leaf shapes) has no per-array item-count cap of its own; it relies on the
token-walk pre-pass for syntax and on the direct engine's limit when
`useSimdWhenAvailable=false`.
