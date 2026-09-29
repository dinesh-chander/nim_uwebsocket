# FastMap Redesign Plan

## Goal
Build a `FastMap` that keeps a Nim-`TableRef`-like public surface while allowing specialized internal backends for performance.

Primary goals:
- keep the public API simple and familiar
- support the current hot string-key workloads well
- make room for true typed storage and mutable-value APIs where the backend can support them
- avoid exposing backend complexity to callers

## Current State

The current `FastMap` in `nim_utils/src/nim_utils/helpers/fast_map.nim` is only partially generic:
- key type is fixed to `string`
- value type is limited to `string` and `int64`
- storage is split across native C-backed implementations
- borrowed view APIs work well for string-heavy hot paths

This design is good for:
- string-key lookups
- borrowed string reads
- arena-backed short-lived maps

This design is weak for:
- exact Nim `TableRef` API parity
- mutable-reference APIs like `mgetOrPut`, `mpairs`, `mvalues`
- extending to more `K, V` combinations cleanly

## Target Public API

Keep `FastMap` as the public type and expose Nim-like methods where supported:
- `newFastMap[V]()`
- `newFastMap[V](pairs)`
- `[]`
- `[]=`
- `hasKey`
- `contains`
- `getOrDefault`
- `hasKeyOrPut`
- `pop`
- `take`
- `pairs`
- `keys`
- `values`
- `clear`
- `len`

Compatibility target:
- match Nim `TableRef` naming and general ergonomics
- do not promise exact `TableRef` semantics unless the selected backend can support them

## Core Design

### 1. One public `FastMap`, multiple internal backends
`FastMap` remains the public facade.

Internally, select a backend by `K, V` and storage mode:
- string-key borrowed backend for current hot string paths
- typed primitive backend for mutable primitive values
- arena variants for short-lived maps

This backend split should remain an internal detail.

### 2. Move map structure into Nim
Implement the table structure, entry layout, iteration, and typed dispatch in Nim.

Reasons:
- allows true typed storage for `V`
- enables `var`-return APIs where the backend supports them
- lets the compiler specialize by `K, V`
- reduces wrapper impedance from a full C-owned table core

### 3. Keep only tiny kernels in C
Use native code only where it clearly helps:
- byte hashing for string keys
- optional `memcmp`/copy helpers
- platform-specific SIMD later, only if profiling proves it

Do not keep the whole table core in C.

## Backend Strategy

### Backend A: String-Key Borrowed Backend
Use for:
- `FastMap[string]`
- hot HTTP/header/query use cases

Properties:
- key type remains string/byte-slice based
- support `getView`, `tryGetView`, `pairsView`
- preserve cheap borrowed reads
- keep arena mode

Expected limitation:
- exact mutable `var string` APIs are still awkward unless values move to Nim-managed storage

### Backend B: Typed Primitive Backend
Use first for:
- `FastMap[int64]`
- later other primitive `V` types

Properties:
- entries store Nim values directly
- enable `[]: var V`, `mgetOrPut`, `mpairs`, `mvalues`
- direct hash/compare for primitive values
- no string-value allocation path

This is the easiest path to exact Nim-like mutable APIs.

### Backend C: Future Generic Primitive `K, V`
Only after the first two backends are stable.

Possible key types:
- `int`
- `int64`
- `uint64`
- `char`
- `bool`
- enums

Possible value types:
- primitive value types
- possibly small POD objects

Do not attempt broad ref-type support early.

## API Semantics Policy

### Exact Match
Support exact Nim-like semantics only when the backend can actually provide them.

Examples:
- `hasKeyOrPut`: yes
- `pop`: yes
- `take`: yes
- `mgetOrPut`: only on typed mutable backends
- `mpairs` / `mvalues`: only on typed mutable backends

### Partial Match
For borrowed string backends:
- keep view APIs as first-class operations
- allow read APIs to remain cheaper than exact `TableRef`

Do not fake `var V` semantics with copied values.

## Rollout Plan

### Phase 1: Stabilize public shape
1. Align naming with Nim `TableRef`
2. Add constructor-from-pairs
3. Add `hasKeyOrPut`, `pop`, `take`, `keys`, `values`, `pairs`
4. Keep unsupported mutable-reference APIs out for now

### Phase 2: Typed primitive backend in Nim
1. Build pure-Nim core table for `string -> int64`
2. Add true mutable slot access internally
3. Implement exact `mgetOrPut`
4. Add `mpairs` and `mvalues`
5. Benchmark against current C-backed `string -> int64`

### Phase 3: String backend decision
1. Decide whether `string -> string` stays borrowed/C-assisted
2. Or move values to Nim-managed storage for exact mutable semantics
3. Measure cost of losing some borrowed-path advantages

### Phase 4: Expand supported types
1. Add more primitive `V`
2. Add primitive `K`
3. Keep each new pair gated by benchmarks and tests

## What To Avoid
- one fully generic fallback pretending to be fast for all `K, V`
- exact API promises that the backend cannot honor
- keeping the whole hash table core in C
- broad ref-type support early
- SIMD-first optimization before storage/layout issues are solved

## Performance Priorities

Based on current profiling, the next wins are more likely to come from:
- typed storage
- less allocation/free traffic
- direct primitive hash/compare
- less wrapper branching

Not from:
- more short-string micro-tuning in the current backend
- more API-layer tricks without storage changes

## Success Criteria

### API
- `FastMap` feels close to Nim `TableRef` for supported types
- unsupported semantics fail clearly at compile time

### Performance
- `string -> int64` matches or beats the current backend
- string-heavy borrowed read paths remain competitive
- short-lived maps benefit from arena/reuse

### Maintainability
- backend choice stays internal
- new `K, V` support is added by specialization, not by weakening the design

---

# Performance Learnings & Optimization Results

*Recorded after systematic benchmarking across value types and access patterns.*

## Benchmark suite

| File | What it measures |
|------|-----------------|
| `nim_express/benchmark/bench_bigstruct_lookup_opts.nim` | FastMap[BigStruct] lookup variants vs Table |
| `nim_express/benchmark/bench_int64_lookup_opts.nim` | FastMap[int64] lookup variants vs Table |
| `nim_express/benchmark/bench_nested_map.nim` | Nested map: outer[string]→inner[string,string], 4 variant combinations |
| `nim_express/benchmark/bench_fast_map_int64_modes.nim` | Full int64 op profile: insert / lookup / overwrite / iterate / erase |
| `nim_express/benchmark/bench_fast_map_hot.nim` | FastMap[string] hot-loop: all ops + prehashed lookup |
| `nim_express/benchmark/bench_compare_tableref.nim` | SmallStruct + BigStruct side-by-side vs Table |

Build from `nim_express/benchmark/`:
```
nim c -d:release -d:danger --opt:speed \
  --path:"../src" \
  --passL:"../../nim_usockets/usockets/uSockets.a -framework CoreFoundation" \
  -o:bin/<name> <name>.nim
```

---

## Why FastMap beats Table for large value types

FastMap uses a Swiss-table layout with **ctrl-byte separation**: the 1-byte control array is stored apart from the entry array. During a probe sequence only the ctrl bytes are touched — for 200k entries that is a 200 KB working set that fits in L2. A `Table[string, BigStruct]` stores 88-byte entries contiguously; probing touches 88 bytes per slot, blowing L2 at the same N.

Result at N=200k, 20 repeats:

| | FastMap tryGet | FastMap getPtrHashed | Table |
|---|---|---|---|
| BigStruct (80-byte, string+seq) | 365ms (baseline) | **146ms** | 1259ms |
| int64 (8-byte primitive) | 140ms (baseline) | **107ms** | 167ms |

FastMap is **3.4× faster** than Table for BigStruct. For int64 the advantage is modest (Table within 20%) because the entry size is small enough not to blow the cache.

---

## ORC copy cost: heap-alloc vs primitive values

BigStruct has `string` and `seq[string]` fields. Every copy triggers ORC `=copy` (malloc + memcpy + refcount bump) and a matching `=destroy` on the old value. `Table.getOrDefault` returns by value, forcing a full deep-copy per lookup. `FastMap.tryGet` avoids this for `FastMap[ref BigStruct]` but not for value-type BigStruct.

The zero-copy `getPtrHashed` API returns a `ptr V` directly into map storage. No copy means no ORC traffic.

For int64 the copy is a single 8-byte register move — negligible. The gain from `getPtrHashed` there comes entirely from skipping the `wyhash` call (~30ns at 200k), not from avoiding a copy.

---

## API rationalization: why only `getPtrHashed`

Three internal hot-path APIs were prototyped: `getPtr`, `tryGetHashed`, `getPtrHashed`.

### `tryGetHashed` was removed

For heap-alloc types it is **actively harmful**: when a pre-computed hash is accepted and the function is inlined, the ORC `eqcopy(BigStruct)` (~60 instructions of malloc+memcpy+refcount) lands inline in the hot loop body. This evicts the probe code from the I-cache and causes register spills, making the loop **2× slower** than plain `tryGet`.

Diagnostic: `bench4b` (getPtr + explicit `v = p[]` copy at the call site) showed the identical slowdown — confirming the issue is the copy being at the call site, not anything in the function itself.

For primitive types `tryGetHashed` is modestly helpful but strictly dominated by `getPtrHashed`.

### `getPtr` was removed

`getPtr(key)` is identical to `getPtrHashed(key, hashKey(key))` — one hash call inlined. Since these are internal APIs used only in hot loops where hashes can be precomputed and reused, the convenience wrapper adds no value and the extra API surface creates confusion.

**Kept: only `getPtrHashed`** — eliminates both hash recomputation and ORC copy in one call.

---

## getPtrHashed usage

```nim
# Precompute hashes once (amortise cost over many lookups of the same key set)
var hashes = newSeq[uint64](keys.len)
for i in 0..<keys.len: hashes[i] = hashKey(keys[i])

# Hot loop — zero copy, no hash cost
for i in 0..<keys.len:
  let p = map.getPtrHashed(keys[i], hashes[i])
  if p != nil:
    # use p.field directly — DO NOT mutate map while holding p
    process(p[])
```

`hashKey` is exported from `nim_express/fast_hash`. The pointer is invalidated by any mutating call (`put`, `del`, `clear`, `reserve`).

---

## Nested maps: the Table[Table] copy trap

Benchmarked: outer key 50 chars, inner key 25 chars, inner value 50 chars, 75 inner entries, 10k outer entries, 1M lookups.

| Variant | Lookup | ops/s | vs Table[Table] |
|---|---|---|---|
| `Table[Table[string,string]]` | 4235ms | 2.3M/s | 1× (baseline) |
| `Table[FastMap[string]]` | 193ms | 52M/s | **22×** |
| `FastMap[FastMap[string]]` tryGet | 221ms | 45M/s | **19×** |
| `FastMap[FastMap[string]]` getPtrHashed outer | 125ms | 80M/s | **34×** |
| `FastMap[FastMap[string]]` getPtrHashed both | **56ms** | **176M/s** | **75×** |

**Root cause of `Table[Table]` slowdown**: `Table.getOrDefault` returns by value. For `Table[string, Table[string,string]]` every outer lookup deep-copies the entire 75-entry inner Table (75 string alloc/copy pairs) before the inner lookup even begins. 1M lookups × 75-entry deep-copy = complete ORC heap thrash.

`FastMap[FastMap[string]]` avoids this because `FastMap[string]` is a `ref object` (8-byte pointer). The outer lookup copies only the ref — one 8-byte move regardless of inner map size.

**Rule**: never use `Table` (or `FastMap.tryGet`) as the outer container when the value type is itself a heap-allocated collection. Use `FastMap` with `getPtrHashed` outer to get a `ptr` into storage and avoid any copy.

---

## Allocator impact

Tested with system allocator, mimalloc, and tcmalloc_minimal against the BigStruct benchmark. Results showed **3–8% variation** — allocator choice does not close the structural gap. The performance difference between FastMap and Table is dominated by ctrl-byte separation and ORC copy avoidance, not malloc throughput.

---

## Recommended API per use case

| Value type | Access pattern | Recommended API |
|---|---|---|
| Any | General use, occasional lookup | `tryGet` / `get` |
| Heap-alloc (string/seq fields) | Hot loop, read fields only | `getPtrHashed` — skips ORC copy |
| Heap-alloc (string/seq fields) | Nested outer map | `getPtrHashed` outer → avoid inner copy |
| Primitive (int64, enum, etc.) | Hot loop with fixed key set | `getPtrHashed` — saves hash cost (~10-28%) |
| Primitive | Single / ad-hoc lookup | `get` — simpler, no prehash needed |
| **Never** | Outer container holding a collection value | `Table[Table]` / `tryGet` on collection V — copies whole inner collection per lookup |
