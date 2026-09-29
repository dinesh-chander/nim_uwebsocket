# nim_utils

Shared utility library for the [nim_uwebsocket](../README.md) framework. Provides high-performance data structures, a lock-free async logger, and a SIMD-accelerated JSON engine.

## Modules

| Module | Description |
|--------|-------------|
| **fast_map** | Cache-friendly hash map optimized for small-to-medium key sets. Open addressing with linear probing and power-of-two sizing. |
| **fast_set** | Companion hash set built on the same open-addressing internals as `fast_map`. |
| **async_logger** | Lock-free, batched async logger that flushes via POSIX `writev` for minimal syscall overhead. |
| **nim_fastjson** | Zero-copy JSON serializer/deserializer with compile-time field planning, SIMD string scanning, and strict RFC 8259 compliance. See the [full nim_fastjson README](src/nim_utils/nim_fastjson/README.md). |

## Platform Support

| Module | Linux (x86_64) | Linux (ARM64) | macOS (Intel) | macOS (Apple Silicon) | Windows |
|--------|----------------|---------------|---------------|----------------------|---------|
| fast_map | Yes | Yes | Yes | Yes | Yes |
| fast_set | Yes | Yes | Yes | Yes | Yes |
| async_logger | Yes | Yes | Yes | Yes | **No** — `writev` is POSIX-only |
| nim_fastjson | Yes (SSE2) | Yes (NEON) | Yes (SSE2) | Yes (NEON) | Yes (scalar SWAR fallback) |

> **Windows note:** The umbrella `import nim_utils` pulls in `async_logger` and will not compile on Windows. Import modules individually instead:
>
> ```nim
> import nim_utils/helpers/fast_map
> import nim_utils/helpers/fast_set
> import nim_utils/nim_fastjson/direct_engine
> ```

## Installation

nim_utils is part of the nim_uwebsocket monorepo. Add the source path when compiling:

```bash
nim c --path:nim_utils/src your_app.nim
```

Or install via Nimble from within the monorepo:

```bash
cd nim_utils
nimble install
```

**Requirements:** Nim >= 2.0.0

## Quick Start

### fast_map / fast_set

```nim
import nim_utils

var m: FastMap[string, int]
m["users"] = 42
m["sessions"] = 7

if "users" in m:
  echo m["users"]

var s: FastSet[string]
s.incl("active")
if "active" in s:
  echo "found"
```

### async_logger

> **POSIX only** — uses `writev` for batched I/O. Will not compile on Windows.

```nim
import nim_utils/async_logger

let logger = newAsyncLogger(stdout)
logger.log(LogLevel.Info, "Server started on port 3000")
logger.flush()
```

### nim_fastjson

High-performance JSON serialization and deserialization with compile-time field planning.

```nim
import nim_utils/nim_fastjson/direct_engine

type User = object
  name: string
  age: int
  email: string

let json = """{"name":"Alice","age":30,"email":"alice@example.com"}"""
let user = deserializeDirect(json, User)
echo user.name

let output = serializeDirect(user)
echo output
```

## Performance Tuning

### fast_map / fast_set

**Hash function selection.** `fast_map` and `fast_set` use an open-addressing scheme with linear probing and power-of-two table sizes. The default hash function is suitable for most workloads. For custom key types, implement a `hash` proc that distributes bits well across the lower bits of the result — the table masks with `(capacity - 1)`, so entropy in the high bits is wasted.

**Load factor.** The table automatically resizes when occupancy crosses the internal load factor threshold (typically ~75%). If you know the final size at construction time, pre-size the table to avoid intermediate resizes:

```nim
var m = initFastMap[string, int](256)
```

**Initial capacity.** Always a power of two. If you pass a non-power-of-two, it rounds up. For best cache locality, keep the table small enough to fit in L1/L2 cache — 64–4096 entries is the sweet spot for linear probing.

**Key size.** Short keys (≤ 8 bytes) enable word-at-a-time comparison. For longer keys, consider interning strings or using integer identifiers.

### async_logger

> POSIX only (Linux, macOS). Not available on Windows.

**`writev` batch sizing.** The logger accumulates log entries in a lock-free ring buffer and flushes them as a single `writev` call. Larger batches amortize the syscall overhead but increase tail latency for individual log lines. Tune the flush interval to balance throughput and freshness.

**Buffer management.** Pre-allocate the ring buffer to match your expected peak log rate. Under-sized buffers cause the producer (your application) to block when the ring is full. Over-sized buffers waste memory.

**Flush strategies:**

| Strategy | When to use |
|----------|-------------|
| Explicit `logger.flush()` | Guaranteed delivery before process exit or checkpoint |
| Interval-based | Background thread drains the buffer every N milliseconds — good for steady log streams |
| Threshold-based | Flush when the buffer reaches N entries — adapts naturally to bursty workloads |

**File descriptor target.** Pass `stdout`, `stderr`, or a `File` opened for writing. For production, write to a file and use an external log rotator (logrotate, systemd journal) to avoid blocking on terminal I/O.

### nim_fastjson

See the [full nim_fastjson README](src/nim_utils/nim_fastjson/README.md) for API details, SIMD internals, and RFC 8259 compliance.

**Zero-alloc hot paths.** Use `serializeDirectInto` with a pre-allocated buffer to eliminate allocation on every request:

```nim
var buf = newStringOfCap(4096)

proc handleRequest(user: User): string =
  buf.setLen(0)
  serializeDirectInto(buf, user)
  buf
```

**String safety annotations.** Annotate fields that are known to never contain `"`, `\`, or control characters with `{.jsonSafe.}` or use `JsonSafeString`. This skips the SIMD/SWAR escape scan (~5ns per field):

```nim
type ApiResponse = object
  status {.jsonSafe.}: string
  id: JsonSafeString
  payload: string
```

**SIMD selection.** SIMD is auto-detected per architecture (SSE2 on x86_64, NEON on ARM64). Disable with `-d:noSimd` to force the 8-byte SWAR fallback — useful for debugging or on platforms where SIMD intrinsics are unavailable.

**Native C acceleration.** For maximum escape-scanning throughput, compile with `-d:nativeEscapeScan` to link the hand-tuned C implementation:

```bash
nim c -d:release -d:nativeEscapeScan app.nim
```

## API Reference

### nim_fastjson / direct_engine

#### Core Types

```nim
type
  JsonError* = object of ValueError
  JsonSafeString* = distinct string
  JsonAsciiSafeString* = distinct string
```

- **JsonError** — raised on parse failures (malformed JSON, depth exceeded, trailing data, RFC violations).
- **JsonSafeString** — a `distinct string` that skips escape scanning during serialization (~5ns savings per field). Use for values known to contain no `"`, `\`, or control characters.
- **JsonAsciiSafeString** — same guarantee plus ASCII-only (no multi-byte UTF-8).

#### Pragmas

```nim
template jsonSafe*() {.pragma.}
```

Annotate object string fields to skip the SWAR/SIMD safety scan at serialization time.

#### Serialization

```nim
proc serializeDirect*[T](value: T): string
```

Serialize any supported type to a JSON string. Uses compile-time field planning to pre-compute buffer sizes and field orderings. Supported types: primitives, `string`, `enum`, `seq`, `array`, `Option`, `Table`/`OrderedTable` (string or enum keys), `ref object`, and nested objects.

```nim
proc serializeDirectInto*[T](buf: var string, value: T)
```

Serialize into an existing buffer, reusing its allocation. Pass a pre-allocated string for zero-alloc serialization in hot paths.

#### Deserialization

```nim
proc deserializeDirect*[T](json: string, _: typedesc[T]): T
```

Deserialize a JSON string into type `T`. Rejects trailing data. Field matching uses compile-time-generated dispatch by key length and literal comparison (word-at-a-time on 64-bit).

#### Validation

```nim
proc skipJsonValue*(s: string, i: var int)
```

Advance the index past one complete JSON value without allocating. Useful for validation or selective parsing.

#### Compile-Time Planning

The engine uses Nim's `macrocache` to build field plans at compile time:

- **Serialize plan** — pre-computes static overhead (key bytes, delimiters), field kinds (generic, safe-string, ASCII-safe), and root shape (`seq[object]`, `Table`, numeric tree, or generic).
- **Decode plan** — maps field names to their kinds and key lengths for dispatch.

#### SIMD Acceleration

String escape scanning and copying use platform-specific SIMD when available:

| Platform | Instruction Set | Compile Flag |
|----------|----------------|--------------|
| ARM64 (Apple Silicon, etc.) | NEON (128-bit) | Automatic (disable with `-d:noSimd`) |
| x86_64 | SSE2 (128-bit) | Automatic (disable with `-d:noSimd`) |
| Other / fallback | 8-byte SWAR | Always available |

Optional native C acceleration for escape scanning:

| Flag | Effect |
|------|--------|
| `-d:nativeEscapeScan` | Links `escaped_scan.c` for C-level scan/copy/write |
| `-d:useSimdJson` | Delegates unsafe-byte scanning to C `jsonNextUnsafeC` via simdjson |

#### RFC 8259 Compliance

The parser enforces strict RFC 8259 rules:

- Rejects leading `+` on numbers
- Rejects leading zeros (`01`, `00.5`)
- Requires at least one digit after `.` and after `e`/`E`
- Rejects unescaped control characters (U+0000–U+001F) in strings
- Rejects `NaN` and `Infinity` in serialization output
- Rejects `null` as an object key
- Enforces max nesting depth of 512

#### Performance Notes

- **Depth limiting** — thread-local counter with a 512-level cap prevents stack overflow on malicious input.
- **Whitespace fast-path** — `eatSpace` optimizes for already-minified JSON (common in API payloads).
- **Float formatting** — uses dragonbox (`std/private/dragonbox`) for fast, correct float-to-string conversion.
- **Integer formatting** — digit-pairs lookup table for two-digits-at-a-time unsigned integer conversion.
- **Batched serialization** — `StringScanBatch` and `EscapedBodyBatch` types enable pre-staged string body computation for `seq[object]` payloads.

## Building

### Linux (x86_64 / ARM64)

```bash
nim c -d:release --opt:speed --path:nim_utils/src your_app.nim
```

With LTO for maximum performance:

```bash
nim c -d:release --opt:speed -d:lto --path:nim_utils/src your_app.nim
```

### macOS (Intel / Apple Silicon)

```bash
nim c -d:release --opt:speed --path:nim_utils/src your_app.nim
```

Apple Silicon automatically selects NEON SIMD paths. Intel Macs use SSE2.

### Windows

```bash
nim c -d:release --opt:speed --path:nim_utils/src your_app.nim
```

> `async_logger` is not available on Windows. Import specific modules instead of the umbrella `nim_utils` module if you need Windows compatibility.

### Cross-Compilation

When cross-compiling for a different architecture, the SIMD backend follows the `--cpu` flag:

```bash
nim c -d:release --cpu:arm64 --cc:aarch64-linux-gnu-gcc --path:nim_utils/src your_app.nim
```

### Build Flags

| Flag | Effect |
|------|--------|
| `-d:release` | Enables `{.push checks: off.}` in the JSON engine for maximum throughput |
| `-d:danger` | Like `-d:release` but also disables all runtime checks (bounds, overflow, nil). Use for benchmarks. |
| `-d:lto` | Link-time optimization — enables cross-module inlining for smaller, faster binaries |
| `--opt:speed` | Compiler optimization for speed (`-O3`) |
| `--gc:orc` | ORC garbage collector (default in Nim 2.x) — cycle-collecting, deterministic |
| `-d:noSimd` | Disables NEON/SSE2 SIMD paths, forces scalar SWAR fallback |
| `-d:nativeEscapeScan` | Uses compiled C helpers for string escape scanning |
| `-d:useSimdJson` | Routes unsafe-byte detection through simdjson C++ bindings |

### Running Tests

```bash
cd nim_utils

nim c -r tests/test_rfc8259_compliance_fixes.nim
```

Or from the monorepo root:

```bash
nimble test
```

## License

MIT
