# nim_fastjson

High-performance JSON parser and serializer for Nim. RFC 8259 compliant with SIMD-accelerated string escaping, zero-copy key matching, and compile-time object layout planning.

Part of the [nim_uwebsocket](../../../../../../README.md) framework.

## Features

- **SIMD-accelerated string processing** — SSE2 on x86_64, NEON on ARM64, SWAR fallback on all platforms
- **Zero-copy key matching** — object field names compared as `uint32`/`uint64` word loads against compile-time constants
- **Compile-time layout planning** — field serialization order, buffer size estimates, and dispatch tables generated at compile time via macros
- **Direct typed serde** — deserialize JSON straight into Nim types without intermediate tree representation
- **Pre-allocated cursor-based serialization** — single buffer allocation with position cursor, no per-field `setLen` calls
- **RFC 8259 strict compliance** — leading zeros rejected, NaN/Infinity rejected, surrogate pairs validated, control characters in strings rejected
- **Fused field prefix writes** — field name + separator + opening quote written as a single `uint64` store
- **Batch numeric formatting** — float and integer fields in `seq[object]` are pre-formatted in tight loops for better icache utilization
- **Zero-copy borrowed views** — `BorrowedString` / `JsonStringView` fields decode as views into the document with no string copies
- **Pure Nim** — no C/C++ dependencies; SIMD string scanning is emitted inline for SSE2 (x86_64) and NEON (ARM64)

## Platform Support

| Platform | Architecture | SIMD Tier | Throughput | Notes |
|----------|-------------|-----------|------------|-------|
| Linux | x86_64 | SSE2 | 16 bytes/iter | Auto-detected via `defined(amd64)` |
| Linux | ARM64 | NEON | 16 bytes/iter | Auto-detected via `defined(arm64)` |
| macOS | x86_64 | SSE2 | 16 bytes/iter | Intel Macs |
| macOS | ARM64 (Apple Silicon) | NEON | 16 bytes/iter | M1/M2/M3/M4 |
| Windows | x86_64 | SSE2 | 16 bytes/iter | Requires MSVC or MinGW with SSE2 support |
| FreeBSD | x86_64 / ARM64 | SSE2 / NEON | 16 bytes/iter | Same auto-detection as Linux |
| Any | Any | SWAR scalar | 8 bytes/iter | Portable fallback, always available |

### SIMD tier details

- **SSE2 (x86_64)** — uses `_mm_loadu_si128`, `_mm_cmpeq_epi8`, `_mm_movemask_epi8`, and `__builtin_ctz` for branchless first-unsafe-byte detection. Included via `<emmintrin.h>`.
- **NEON (ARM64)** — uses `vld1q_u8`, `vceqq_u8`, `vcltq_u8`, `vorrq_u8`, and `vmaxvq_u8` for 16-byte vector scanning. Included via `<arm_neon.h>`.
- **SWAR (scalar)** — processes 8 bytes at a time using `uint64` arithmetic with bitmask tricks (`hasZeroByte`, XOR against broadcast constants). No platform-specific headers required.

SIMD is enabled by default. Pass `-d:noSimd` to force the SWAR fallback on all platforms.

### Auto-selection logic

At compile time, the following cascade determines which scan path is used:

1. If `defined(arm64) and not defined(noSimd)` → NEON path, emits `#include <arm_neon.h>`
2. Else if `defined(amd64) and not defined(noSimd)` → SSE2 path, emits `#include <emmintrin.h>`
3. Else → SWAR scalar path (no includes needed)

The same cascade applies to both `scanSafeJsonBytes` (scan-only) and `copySafeJsonBytesFused` (fused scan+copy), and the inline C block in `cPutJsonBodySlow` which uses `#if defined(__aarch64__)` / `#else` for runtime-correct codegen on the target.

## Prerequisites

- **Nim** >= 2.0.0
- **C compiler** — gcc, clang, or any C99-compatible compiler

## Installation

```bash
nimble install nim_fastjson
```

Or add to your `.nimble` file:

```nim
requires "nim_fastjson >= 0.1.0"
```

## Quick Start

### Serialize

```nim
import nim_fastjson/direct_engine

type User = object
  name: string
  age: int
  active: bool

let user = User(name: "Alice", age: 30, active: true)
let json = serializeDirect(user)
echo json
# {"name":"Alice","age":30,"active":true}
```

### Deserialize

```nim
import nim_fastjson/direct_engine

type User = object
  name: string
  age: int
  active: bool

let json = """{"name":"Bob","age":25,"active":false}"""
let user = deserializeDirect(json, User)
echo user.name  # Bob
echo user.age   # 25
```

### Reuse Buffer (Zero-Alloc Hot Path)

```nim
import nim_fastjson/direct_engine

type Event = object
  kind: string
  ts: int64

var buf = newStringOfCap(4096)
let event = Event(kind: "click", ts: 1700000000)

serializeDirectInto(buf, event)
echo buf
# {"kind":"click","ts":1700000000}
```

## API Reference

### Deserialization

#### `deserializeDirect[T](json: string, _: typedesc[T]): T`

Parse a JSON string directly into a typed Nim value. Rejects trailing data after the root value.

```nim
let n = deserializeDirect("42", int)
let s = deserializeDirect("\"hello\"", string)
let v = deserializeDirect("[1,2,3]", seq[int])
```

#### Borrowed string views (`BorrowedString` / `JsonStringView`)

Declare string fields as `JsonStringView` to decode without copying string
bytes. Fast-path (escape-free) views point directly into the input document;
views for strings containing JSON escapes point into a decoded buffer. Both
share one ref-counted holder per document (`BorrowedDocRef`), so views stay
valid even after the caller drops its own copy of the document.

```nim
type Todo = object
  id: int
  title: JsonStringView

let t = deserializeDirect("""{"id":1,"title":"ship it"}""" + , Todo)
assert t.title.toString() == "ship it"   # toString copies when you need ownership
```

`BorrowedString` exposes `len`, `isNil` (JSON null), `dataPtr`, `toString`,
`stripAscii`, `equalsAscii`, `equalsIgnoreCaseAscii`, and
`parseBoolLikeAscii`. Views borrow the document's bytes; mutate or resize the
document only through its owner. The `nim_fastjson` wrapper routes borrowed
shapes through the same direct engine as every other type.

#### `parseValue[T](s: string, i: var int, value: var T)`

Low-level incremental parser. Reads one JSON value starting at index `i`, advances `i` past the consumed bytes, and writes the result into `value`.

Supported types:

| Type | JSON |
|------|------|
| `bool` | `true` / `false` |
| `SomeSignedInt` (`int`, `int8`..`int64`) | Number (integer) |
| `SomeUnsignedInt` (`uint`, `uint8`..`uint64`) | Number (unsigned) |
| `SomeFloat` (`float32`, `float64`) | Number (decimal/exponent) |
| `string` | String (with escape processing) |
| `enum` | String → `parseEnum` |
| `seq[T]` | Array |
| `Option[T]` | Value or `null` → `none` |
| `Table[A, B]` | Object (key must be `string` or `enum`) |
| `OrderedTable[A, B]` | Object (preserves key order) |
| `ref object` | Object or `null` → `nil` |
| `object` | Object (macro-generated field dispatch) |

```nim
var i = 0
var nums: seq[int]
parseValue("[10,20,30]", i, nums)
assert nums == @[10, 20, 30]
```

#### `skipJsonValue(s: string, i: var int)`

Skip over a JSON value without allocating or storing it. Validates structure and rejects malformed input. Useful for ignoring unknown fields.

### Serialization

#### `serializeDirect[T](value: T): string`

Serialize any supported Nim value to a JSON string. Pre-allocates the output buffer based on compile-time size estimates.

```nim
let json = serializeDirect(@[1, 2, 3])
assert json == "[1,2,3]"
```

#### `serializeDirectInto[T](buf: var string, value: T)`

Serialize into an existing buffer, reusing its allocation. The buffer is resized to fit. Pass a pre-allocated string for zero-alloc serialization on a hot path.

```nim
var buf = newStringOfCap(1024)
serializeDirectInto(buf, myObj)
```

#### `appendJsonEscaped(buf: var string, value: string)`

Append a JSON-escaped string (with surrounding quotes) to `buf`. Uses SIMD/SWAR to scan for unsafe bytes and only enters the escape slow path when necessary.

### String Safety Annotations

#### `JsonSafeString`

A `distinct string` for values known to never contain characters requiring JSON escaping (`"`, `\`, control chars). Skips the SIMD/SWAR escape scan during serialization — approximately 5ns savings per string.

```nim
type ApiResponse = object
  status {.jsonSafe.}: string
  id: JsonSafeString
```

#### `JsonAsciiSafeString`

Same as `JsonSafeString` but additionally guarantees ASCII-only content.

#### `{.jsonSafe.}` pragma

Annotate individual `string` fields to skip escape scanning without changing the field type:

```nim
type LogEntry = object
  level {.jsonSafe.}: string
  message: string
```

### Validation

#### Leading zeros

Numbers like `007`, `01.5`, `00` are rejected per RFC 8259 §6. `0`, `0.5`, and `-0` are accepted.

#### NaN and Infinity

Serializing `NaN`, `Inf`, or `NegInf` raises `JsonError`. These values have no JSON representation.

#### Control characters

Unescaped control characters (0x00–0x1F) inside strings are rejected during parsing. Escaped forms (`\n`, `\t`, `\uXXXX`) are accepted.

#### Unicode escapes

Full surrogate pair handling: `\uD83D\uDD12` → 🔒. Orphan surrogates (high without low, low without high) are rejected.

#### Object keys

Object keys must be strings. `{null: "value"}` is rejected.

#### Nesting depth

Maximum nesting depth is 512 levels (defined as `MaxJsonParseDepth`). Exceeding this raises `JsonError`.

### Error Handling

All parse errors raise `JsonError` (a subtype of `ValueError`) with an error message and byte offset:

```nim
try:
  let v = deserializeDirect("007", int)
except JsonError as e:
  echo e.msg  # "leading zeros not allowed in JSON numbers at offset 1"
```

## Performance

### Design Principles

1. **SIMD string scanning** — 16 bytes per iteration on x86_64 (SSE2) and ARM64 (NEON). The scan detects `"`, `\`, and control chars in a single vector comparison. Falls back to SWAR (8 bytes/iter) on other architectures.

2. **Fused scan+copy** — `copySafeJsonBytesFused` combines scanning for unsafe bytes with copying safe bytes into the output buffer in a single SIMD pass. On NEON, safe 16-byte chunks are written with `vst1q_u8`; on SSE2, with `_mm_storeu_si128`. This avoids a separate scan-then-copy sequence.

3. **Zero-copy field matching** — object field names are compared as `uint32`/`uint64` word loads against compile-time constants. A two-level dispatch (key length → first character → word compare) avoids hash table lookups entirely. The `spanEquals` proc handles keys up to 16 bytes with at most 2 word loads, and falls back to `equalMem` for longer keys.

4. **Compile-time buffer estimation** — `estimateJsonSize` uses `typeStaticJsonOverhead` (a compile-time constant per type) plus sampled dynamic field sizes (first + last element of sequences) to pre-allocate close to the final output size. The `initialCapacityForSerialize` then applies a 3× safety margin to eliminate per-field bounds checks.

5. **Cursor-based writes** — the serializer pre-allocates a single buffer and writes through a `pos` cursor. Field name prefixes (e.g., `,"name":"`) are fused into single `uint64` stores via `cPutLit`. String field writes fuse the prefix + opening quote into one literal, and `cPutJsonBody` writes the body + closing quote.

6. **Batch numeric formatting** — for `seq[object]` types, all float fields are pre-formatted via `preformatFloats` and all integer fields via `preformatInts` in tight loops before structural serialization begins. This improves icache utilization by separating the dragonbox/digit-pair formatting from the structural JSON emission.

7. **Root shape specialization** — the `selectedSerializeRootShape` macro detects top-level `seq[object]`, `Table[string, object]`, and deeply-nested numeric trees (`seq[seq[seq[float64]]]`) at compile time and routes to specialized writers that skip per-element dispatch overhead.

### vs stdlib `json`

nim_fastjson avoids the `JsonNode` tree representation entirely. Parsing goes directly from bytes to typed Nim values. Serialization goes directly from typed values to bytes. This eliminates:

- Tree allocation and GC pressure
- String copies for field name lookup
- Dynamic dispatch on node kind

## Performance Tuning

This section covers every lever available for optimizing nim_fastjson throughput.

### Compile-Time Defines

| Flag | Effect | Default |
|------|--------|---------|
| `-d:release` | Enables `{.push checks: off.}` for bounds-check-free hot paths | Off |
| `-d:noSimd` | Force SWAR fallback — disables SSE2 (x86_64) and NEON (ARM64) | Off (SIMD enabled) |

#### `-d:noSimd`

Disables all SIMD intrinsic paths. The guard is `defined(arm64) and not defined(noSimd)` / `defined(amd64) and not defined(noSimd)`. When set, all string scanning falls back to the SWAR scalar path (8 bytes/iter using `uint64` arithmetic). Use this when:

- Cross-compiling to an architecture where you cannot verify SIMD support
- Debugging SIMD-related build errors
- Targeting 32-bit x86 (no SSE2 baseline)

```bash
nim c -d:release -d:noSimd myapp.nim
```

### Buffer Pre-Allocation Strategies

#### `serializeDirectInto` with pre-sized buffer

The zero-allocation hot path. Allocate a buffer once, reuse it across serialization calls:

```nim
var buf = newStringOfCap(4096)

proc handleRequest(event: Event) =
  serializeDirectInto(buf, event)
  sendResponse(buf)
```

The buffer is resized only if the estimated output exceeds current capacity. For consistent payloads this means zero allocations after warmup.

#### How capacity estimation works

1. `typeStaticJsonOverhead` computes field name lengths + fixed-type estimates (8 bytes per int, 16 per float, 5 per bool) at **compile time** as a CacheTable constant
2. `estimateDynamicFields` adds runtime string lengths and nested seq sizes
3. `initialCapacityForSerialize` applies a safety margin:
   - ≤ 128 bytes estimated → `max(256, estimated * 3 + 64)`
   - ≤ 4096 bytes estimated → `estimated * 3 + 128`
   - Otherwise → `estimated * 3 + 256`

For `seq[object]` with > 4 elements, only the first and last elements are sampled to avoid O(n) traversal during estimation.

### Zero-Copy Key Matching

During deserialization, object field names are matched without allocating a key string. The parser extracts the key span (`keyStart`, `keyLen`) via `parseObjectKeySpan` and compares directly against compile-time constants using `spanEquals`:

| Key length | Comparison strategy |
|-----------|-------------------|
| 0 | Always true |
| 1 | Single byte compare |
| 2–3 | `uint32` load + compare |
| 4 | `uint32` load + compare |
| 5–7 | Overlap trick: first 4 + last 4 bytes as `uint32` |
| 8 | `uint64` load + compare |
| 9–15 | Overlap trick: first 8 + last 8 bytes as `uint64` |
| 16 | Two `uint64` loads |
| 17+ | `equalMem` fallback |

This is fastest when field names are ≤ 8 bytes (single word load). Design your field names accordingly.

### Compile-Time Capacity Estimation

The macro system generates per-type constants at compile time:

- **`typeStaticJsonOverhead`** — sum of all field name bytes, separators, and fixed-type size estimates. Cached in `StaticOverheadCache` (CacheTable) so each type is computed exactly once.
- **`countFloatFieldsInType`** / **`countIntFieldsInType`** / **`countStringFieldsInType`** — field counts used to size batch buffers.
- **`typeStringOnlyFieldOverhead`** / **`typeSafeStringOnlyFieldOverhead`** — specialized overhead for objects with only string fields, enabling the staged-write fast path.

You get these benefits automatically. The key takeaway: nim_fastjson knows the structural overhead of your types at compile time and only measures variable-length data (strings, seqs) at runtime.

### JsonSafeString and JsonAsciiSafeString

Every string field in serialization goes through the SIMD/SWAR escape scanner. If you **know** a string will never contain `"`, `\`, or control characters (0x00–0x1F), you can skip this scan entirely.

**`JsonSafeString`** — distinct string type. Serialization writes `"` + raw bytes + `"` without scanning. Saves ~5ns per string on typical hardware.

**`JsonAsciiSafeString`** — same as `JsonSafeString`, additionally guarantees ASCII-only content.

**`{.jsonSafe.}` pragma** — annotate `string` fields without changing the type. The macro system detects the pragma and emits the unescaped write path:

```nim
type Config = object
  region {.jsonSafe.}: string
  env {.jsonSafe.}: string
  userInput: string
```

**When to use:**

- UUIDs, hex strings, numeric-only strings, enum-like status codes
- Field values sourced from a controlled vocabulary
- **Never** use for user-provided input or data from external systems

**Safe-string-only object optimization:** when *all* fields of an object are `{.jsonSafe.}` or safe-string types, the serializer activates a one-pass writer (`writeSafeStringOnlySeqObjectsC`) that skips escape scanning entirely for the whole sequence. This is detected at compile time via `typeSafeStringOnlyFieldOverhead`.

### Avoiding Allocations: Typed Parsing vs Generic JsonNode

nim_fastjson has **no** `JsonNode` type. All parsing is typed. This is a deliberate design choice:

```nim
# Zero intermediate allocations — bytes go directly into your type
let user = deserializeDirect(json, User)

# Compare with stdlib json:
# let node = parseJson(json)       ← allocates JsonNode tree
# let user = node.to(User)         ← walks tree, copies strings
```

If you need to skip unknown fields, `skipJsonValue` validates and advances the cursor without allocating.

### Batch Serialization Patterns

For `seq[object]` at the root level, nim_fastjson applies several batch optimizations automatically:

**1. Batch float formatting** — all float fields across all elements are pre-formatted via dragonbox in a tight loop (`preformatFloats`), then the formatted digits are `copyMem`'d during structural emission. This keeps dragonbox code hot in icache.

**2. Batch int formatting** — same pattern for integer fields via `preformatInts` using the digit-pair table.

**3. Staged string bodies** — for objects with only string fields (`typeStringOnlyFieldOverhead >= 0`), strings are pre-scanned for escape safety and pre-escaped into a staging buffer. Final emission pulls from the staging buffer without re-reading source bytes.

**4. Root shape specialization** — the `selectedSerializeRootShape` macro detects:
- `seq[object]` → `jsrsSeqObject` → `writeSeqObjectRootC`
- `Table[string, object]` → `jsrsTableObject` → `writeTableObjectRootC`
- `seq[seq[seq[float64]]]` (3+ depth) → `jsrsNumericTree` → `writeNumericTreeRootC`

These kick in automatically for top-level calls to `serializeDirect` / `serializeDirectInto`.

### Memory Layout Considerations

- **seq elements are contiguous** — nim_fastjson casts `seq[T]` to `ptr UncheckedArray[T]` for cache-friendly sequential access without bounds checks.
- **Compile-time field ordering** — fields are serialized in declaration order via the `objectFieldPlanNode` macro. Declaring hot fields first improves cache line utilization during serialization.
- **Pre-allocated escape table** — `EscapeSeq` is a 256-entry compile-time lookup table (8 bytes per entry) providing escape sequences and their lengths. This avoids branching on individual escape characters.
- **SWAR constants are compile-time** — `ByteHighBits`, `ByteLowMask`, `QuoteMask`, `SlashMask`, and `ControlFloor` are `const uint64` values, so they live in the immediate operand stream rather than memory.

### Nesting Depth Limit

The parser enforces `MaxJsonParseDepth = 512` using a thread-local counter (`jsonParseDepth`). Each `[` or `{` increments the counter; each `]` or `}` decrements it. Exceeding 512 raises `JsonError`.

**Performance impact:** the depth check is a single integer comparison and increment per nesting level — negligible for realistic documents. The limit exists to prevent stack overflow from adversarial input (e.g., `[[[[...` × 10,000).

If your application processes deeply nested structures by design, you would need to modify `MaxJsonParseDepth` in `direct_engine.nim` and recompile.

### Large Document Strategies

nim_fastjson is a **full-parse** library — the entire JSON document must be in memory as a `string`. There is no streaming parser.

**Strategies for large documents:**

- **Pre-allocate the input buffer** with `newStringOfCap(expectedSize)` before reading from I/O to avoid reallocation during read
- **Use typed parsing** to skip irrelevant subtrees — `skipJsonValue` validates and advances without allocating
- **Reuse the output buffer** with `serializeDirectInto` if round-tripping large documents
- For documents exceeding available memory, split them at the application level before passing to nim_fastjson

### Fused Prefix Writes

The `cPutLit` proc writes compile-time string literals using embedded `uint64` constants:

- Strings ≤ 8 bytes → single `uint64` + `copyMem` (1 store)
- Strings 9–16 bytes → two overlapping `uint64` stores
- Strings 17+ bytes → local array copy (rare for field prefixes)

For string fields, the prefix and opening quote are fused: `,"name":"` becomes a single `cPutLit` call, and `cPutJsonBody` writes the body + closing quote. This eliminates one byte write per string field.

## Building

### Standard build

```bash
nim c -d:release --path:nim_utils/src myapp.nim
```

### With SIMD (default)

SIMD is auto-detected based on the target architecture. No flags needed:

```bash
# x86_64 → SSE2
# ARM64  → NEON
nim c -d:release myapp.nim
```

### Disable SIMD

```bash
nim c -d:release -d:noSimd myapp.nim
```

### Maximum performance build

Combine release mode with danger (disables all runtime checks including overflow):

```bash
nim c -d:release -d:danger --opt:speed myapp.nim
```

### Cross-compilation

When cross-compiling (e.g., ARM64 on an x86_64 host), ensure the C compiler targets the correct architecture. SIMD selection is based on Nim's `defined(arm64)` / `defined(amd64)` which follows the `--cpu` flag:

```bash
# ARM64 target from x86_64 host
nim c -d:release --cpu:arm64 --cc:aarch64-linux-gnu-gcc myapp.nim

# x86_64 target from ARM64 host
nim c -d:release --cpu:amd64 --cc:x86_64-linux-gnu-gcc myapp.nim
```

When cross-compiling with `-d:noSimd`, no architecture-specific headers are needed:

```bash
nim c -d:release -d:noSimd --cpu:arm64 --cc:aarch64-linux-gnu-gcc myapp.nim
```

### Platform-specific notes

**macOS (Apple Silicon):**

```bash
nim c -d:release myapp.nim
# NEON auto-detected, no extra flags needed
```

**macOS (Intel):**

```bash
nim c -d:release myapp.nim
# SSE2 auto-detected, baseline for all x86_64
```

**Linux (x86_64):**

```bash
nim c -d:release myapp.nim
# SSE2 auto-detected
```

**Linux (ARM64, e.g., Graviton, Raspberry Pi 4+):**

```bash
nim c -d:release myapp.nim
# NEON auto-detected
```

## Benchmarks

### Running benchmarks

```bash
# Build and run the comprehensive test suite (includes timing)
nim c -d:release -d:danger --opt:speed \
  --path:nim_utils/src \
  nim_utils/src/nim_utils/nim_fastjson/tests/test_fastjson_comprehensive.nim

./nim_utils/src/nim_utils/nim_fastjson/tests/test_fastjson_comprehensive
```

### What to expect vs stdlib json

| Operation | nim_fastjson | stdlib `json` | Reason |
|-----------|-------------|---------------|--------|
| Serialize `object` | Fast — cursor writes, no tree | Slow — build JsonNode, then stringify | No intermediate representation |
| Serialize `seq[object]` | Faster — batch float/int formatting | Slow — per-element JsonNode creation | Batch icache optimization |
| Deserialize `object` | Fast — zero-copy key matching | Slow — hash table key lookup | Word-load comparison |
| Deserialize `string` | Fast — SIMD scan for end-of-string | Moderate — byte-at-a-time | 16 bytes/iter vs 1 byte/iter |
| String escaping | Fast — SIMD scan + fused copy | Moderate — per-byte check | `copySafeJsonBytesFused` |
| Memory usage | Minimal — no tree, typed target only | High — full JsonNode tree in memory | Direct serde |

### Compile-time overhead

The macro system generates dispatch tables, field plans, and overhead constants at compile time. First compilation of a new type takes slightly longer; subsequent compilations use the `CacheTable` and are fast.

## RFC 8259 Compliance

| Section | Requirement | Status |
|---------|-------------|--------|
| §6 | No leading zeros in numbers | Enforced |
| §6 | No leading `+` on numbers | Enforced |
| §6 | Digit required after decimal point | Enforced |
| §6 | Digit required after exponent marker | Enforced |
| §6 | No NaN/Infinity | Enforced (parse and serialize) |
| §7 | Control chars (0x00–0x1F) must be escaped | Enforced |
| §7 | Valid `\uXXXX` hex digits | Enforced |
| §7 | Surrogate pair validation | Enforced |
| §7 | All standard escapes (`\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`) | Supported |
| §4 | Object keys must be strings | Enforced |
| §2 | UTF-8 encoding | Assumed (no BOM handling) |

## Troubleshooting

### "undefined reference to `_mm_*`" or SSE2 errors

Your C compiler does not support SSE2 intrinsics. Either:
- Use a compiler that targets x86_64 (SSE2 is baseline for x86_64)
- Pass `-d:noSimd` to use the SWAR fallback

### "undefined reference to `vld1q_u8`" or NEON errors

Your C compiler does not support NEON intrinsics. Either:
- Use a compiler that targets ARM64 (NEON is baseline for AArch64)
- Pass `-d:noSimd` to use the SWAR fallback

### "__builtin_ctz not found" (Windows / MSVC)

The SSE2 path uses `__builtin_ctz` (GCC/Clang built-in) for trailing-zero count. MSVC uses `_BitScanForward` instead. If using MSVC:
- Switch to MinGW-w64: `nim c --cc:gcc myapp.nim`
- Or pass `-d:noSimd` to bypass the intrinsic entirely


### "JSON nesting depth exceeds 512"

The parser enforces a maximum nesting depth of 512 to prevent stack overflow from deeply nested or adversarial input. This limit is defined as `MaxJsonParseDepth` in `direct_engine.nim`. To change it, modify the constant and recompile.

### NaN/Infinity serialization errors

JSON has no representation for `NaN` or `Infinity` (RFC 8259 §6). Sanitize float values before serialization:

```nim
import std/math

proc safeFloat(v: float64): float64 =
  if v != v or v == Inf or v == NegInf: 0.0
  else: v
```

### Cross-compilation picks wrong SIMD path

Nim's `defined(arm64)` / `defined(amd64)` follows the `--cpu` flag, not the host architecture. Verify you are passing `--cpu:arm64` or `--cpu:amd64` correctly. If in doubt, add `-d:noSimd` to use the portable SWAR path and confirm the build succeeds before re-enabling SIMD.

### Buffer overflows in serialization

The serializer pre-allocates with a 3× safety margin and uses `ensureRoom` for dynamic growth. If you observe corruption:
- Ensure you are not mutating the buffer concurrently with serialization
- Check that `{.jsonSafe.}` annotations are correct — if a "safe" string actually contains `"` or `\`, the output will be malformed

## License

MIT
