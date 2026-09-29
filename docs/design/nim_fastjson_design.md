# nim_fastjson Design: Generic, High-Performance JSON for Nim

Date: 2026-03-13

## Summary

There is no existing `nim_fastjson` design doc in this repo. This document fills that gap using the concrete learnings from:

- [analysis/jsony/jsony.nim](/analysis/jsony/jsony.nim)
- [nim_simdjson.nim](/nim_utils/nim_simdjson/src/nim_simdjson.nim)
- current `todo.json` performance history for typed decode and borrowed-string work

The main conclusion is:

1. `jsony` is the right architectural model for fast generic full typed `serialize/deserialize`.
2. `nim_simdjson` is the right architectural model for selective parsing, borrowed-string decode, and large-document projection.
3. Trying to make one DOM-first or shim-heavy engine win both categories is the wrong optimization target.
4. The best path is a small public JSON package with multiple internal engines, while keeping the public API narrow.

If the goal is "superfast across different JSON sizes", the package should not be "just a nicer `nim_simdjson`". It should be a hybrid:

- direct typed engine for full materialization
- simdjson-backed engine for borrowed/selective/projection-heavy work

## Recommendation

Use a new package design, but reuse `nim_simdjson` internally.

Recommended structure:

- `nim_fastjson` as the public package and stable API
- `nim_simdjson` kept as a backend module for projection/selective/borrowed decoding
- a direct typed engine, optimized for full object materialization, as the default fast path for generic `serialize/deserialize`

This is better than making `nim_simdjson` itself the primary generic serde API because `nim_simdjson` still pays for:

- shim crossings
- parser/setup overhead on public typed paths
- owned string materialization at the API boundary
- generic native-plan tree materialization in some paths

Those are exactly the reasons it remains slower than `jsony` on full owned decode.

## What `jsony` Gets Right

`jsony` is fast because it uses the right base architecture for generic typed serde:

1. Single-pass typed parser and writer.
   - `parseHook` and `dumpHook` work directly on the source/output buffer.
   - There is no AST or DOM on the hot typed path.

2. Tight primitive loops.
   - booleans and integers are parsed by hand
   - floats use a focused primitive parser
   - integer serialization uses direct digit formatting instead of `$int`

3. Efficient string handling.
   - ASCII-fast scan
   - bulk `copyMem` of safe spans
   - branch into escape handling only when necessary

4. Direct materialization.
   - parse writes directly into the destination object
   - no intermediate tree is built for normal typed decode

5. Compile-time customization.
   - rename hooks
   - skip hooks
   - post hooks
   - low runtime overhead

6. Structural skipping.
   - unknown fields are skipped by structure, not reparsed into temporary values

The main weakness in `jsony` is not its core model. It is mostly in generic object field dispatch:

- object parsing still linearly scans `fieldPairs`
- that is flexible, but O(field-count) per key

That is the clearest place to beat `jsony` without abandoning its model.

## What `nim_simdjson` Gets Right

`nim_simdjson` already solved several hard problems that a generic fast package should reuse:

1. Borrowed-string lifetime management.
   - `BorrowedString` is not a toy view; it carries storage ownership.
   - this is the correct model for zero-copy fields

2. Projection-first parsing.
   - `project()` extracts a chosen field set efficiently
   - this is exactly the right model for large object arrays and partial reads

3. Compile-time decode tiering.
   - unsupported
   - DOM fallback
   - ondemand leaf
   - native-plan
   - this is a good control plane for internal engine selection

4. Backend abstraction.
   - the C/C++ shim surface already exposes a broad parsing backend
   - that work should be reused rather than thrown away

5. Typed decode history and benchmarks.
   - the repo already knows where `nim_simdjson` wins and where it loses
   - that is valuable design input

The main limitation is also clear:

- `nim_simdjson` is best when work stays borrowed, projected, or native-backed
- it is weakest when it must return a fully owned Nim object graph every time

That is not a failure. It means it should be a backend, not the only engine.

## Core Design Goal

The public API should stay small:

```nim
proc serialize*[T](value: T): string
proc deserialize*[T](json: string, _: typedesc[T]): T
proc deserialize*[T](json: openArray[byte], _: typedesc[T]): T
```

Optional advanced APIs can exist later, but the core surface should remain small:

```nim
proc extract*[T](json: string, _: typedesc[T]): T
proc projectArray*[T](json: string, _: typedesc[T]): T
```

The important point is that the engine choice happens underneath the same API.

## Engine Model

### Engine 1: Direct Typed Engine

Use this for:

- small JSON
- medium JSON
- nested typed payloads when the caller wants full owned objects
- serializer hot paths

This engine should follow the `jsony` architecture, but improve on it:

1. Single-pass cursor parser
2. Single-pass direct serializer
3. No DOM
4. No runtime reflection
5. Macro-generated field dispatch
6. Better object-key matching than linear `fieldPairs`

This engine is the default fast path for:

- `serialize[T]`
- `deserialize[T]`

### Engine 2: simdjson-Backed Engine

Use this for:

- borrowed-string targets
- selective field extraction
- projection from large objects/arrays
- large payloads where the caller does not need full materialization
- future path-based extractors

This engine should reuse `nim_simdjson` rather than duplicate it.

This is not the default for all `deserialize[T]`.
It is the best engine when:

- `T` contains borrowed string/view fields
- `T` is a projection type
- the schema is large and selective access matters more than object construction

## Why Not Build Only on `nim_simdjson`

Because full owned typed decode has a different winning architecture.

For generic owned serde, the fast path is:

1. scan bytes once
2. match keys directly
3. write fields directly into the destination object
4. allocate only what the destination truly owns

`nim_simdjson` still has residual costs that are hard to erase completely on that path:

- C shim transitions
- parser setup and native ownership management
- tree/value-plan materialization in generic paths
- later conversion to Nim-owned strings and seqs

That makes it a weaker default engine for plain `deserialize[T]`.

## Why Not Build Only on `jsony`

Because `jsony` does not naturally cover the workloads where simdjson is strongest:

- very large documents
- selective reads
- borrowed string views
- projection over homogeneous arrays
- high-performance field extraction without full materialization

If we only copy `jsony`, we will win one benchmark class and lose another.

## Required Low-Level Techniques

These are the concrete techniques that matter for a truly fast generic package.

### Parsing

1. Cursor-based single-pass parser
   - mutable index into the source buffer
   - no token array
   - no DOM on typed paths

2. Generated object key dispatch
   - do not linearly compare every field name
   - generate per-type dispatch by:
     - key length
     - first character
     - optionally first 4 or 8 bytes
   - fallback to full compare only when needed

3. Structural skip
   - unknown fields must be skipped without building values

4. Borrowed strings where possible
   - zero-copy for borrowed/view fields
   - copy only for owned `string`

5. Array specialization
   - `seq[object]` needs a dedicated decode loop
   - this is often where throughput is won or lost

6. Optional SoA scratch for array-of-object decode
   - useful internally, not as the public type
   - especially for large arrays with repeated fields

### Serialization

1. Direct field emission
   - no `JsonNode`
   - no generic runtime reflection

2. Fast string escaping
   - scan once
   - bulk-copy safe spans
   - only branch into escapes when required

3. Fast integer formatting
   - two-digit table or equivalent
   - avoid `$int`

4. Better buffer strategy
   - avoid repeated string growth churn
   - use capacity estimation aggressively
   - for extreme paths, use paged or arena-backed writers

5. Precomputed field literals
   - `"fieldName":` fragments should be emitted from compile-time literals

### Memory / Ownership

1. Explicit borrowed/owned distinction
2. Stable owner for borrowed views
3. Minimize copies at API boundaries
4. Reuse parser scratch/storage where safe

## Handling Different JSON Sizes

One engine is not optimal for every payload size. The package should choose well by workload.

### Small JSON

Characteristics:

- few fields
- low nesting
- overhead matters more than raw scan throughput

Best strategy:

- direct typed engine
- fully inlined primitive parsing
- generated object dispatch
- low setup overhead

Do not use simdjson here by default.

### Medium JSON

Characteristics:

- still typed object focused
- enough content for string/number loops to matter

Best strategy:

- still default to direct typed engine
- use stronger key dispatch and array specialization
- keep serializer/deserializer allocation behavior tight

Only switch to `nim_simdjson` when:

- the destination is borrowed/projection oriented
- the schema is selectively accessed

### Large JSON

Characteristics:

- scan cost matters
- allocation cost matters more
- selective access often becomes attractive

Best strategy:

- full owned decode: direct typed engine if caller needs the whole object
- selective/projection decode: simdjson-backed engine
- reuse parser state and scratch
- prefer borrowed fields when possible

### Nested JSON

Characteristics:

- recursion overhead
- many repeated object keys
- string-heavy subgraphs

Best strategy:

- direct typed engine with generated nested decode
- avoid reparsing nested raw fragments
- avoid intermediate generic trees
- use borrowed strings for internal and supported external fields

This is also where generic native-plan trees become expensive, so if `nim_simdjson` is used, it should stay on a direct-destination or projection path rather than a generic value tree.

## Data-Oriented Techniques

SoA is useful, but only in the right place.

Do not expose SoA as the public object model for ordinary serde.

Do use SoA internally for:

1. array-of-object decode scratch
2. per-column preprocessing
3. selective extraction
4. projection over large repeated structures

Example:

- decode `[{id,title,done}, ...]` internally as:
  - `ids`
  - `titles`
  - `doneFlags`
- then either:
  - return columns for projection APIs, or
  - assemble final `seq[Todo]` once

This can improve cache behavior and reduce branchy per-row repeated work, but only when used deliberately.

## Recommended Implementation Strategy

### Option A: New Package With Internal Backends

Recommended.

Structure:

- `nim_fastjson/`
- `src/nim_fastjson.nim`
- `src/nim_fastjson/direct_engine.nim`
- `src/nim_fastjson/simd_backend.nim`
- optional native backend sources if needed later

Benefits:

- clear public story
- no need to overload `nim_simdjson` with contradictory goals
- can evolve fast generic serde without weakening selective parsing APIs

### Option B: Evolve `nim_simdjson` Into the Whole Package

Possible, but not preferred.

This only makes sense if:

- the project explicitly wants one package
- the direct typed engine is added inside `nim_simdjson`
- `nim_simdjson` stops being conceptually “simdjson wrapper first”

If that happens, it becomes a multi-engine JSON package that happens to include simdjson, which is effectively Option A under a different name.

## Best Practical Choice

If the goal is maximum performance with minimal confusion:

- create `nim_fastjson`
- keep `nim_simdjson` as an internal or sibling backend

If the goal is fewer packages:

- keep the repo module count smaller
- but still implement a separate direct typed engine internally

In both cases, the engine design should be the same.

## Implementation Phases

### Phase 1: Direct Typed Engine in Nim

Build a clean `jsony`-style engine first:

1. cursor parser
2. dump path
3. primitive specializations
4. generated object dispatch
5. borrowed field support for parse targets

Why:

- fastest path to a working generic engine
- easiest benchmarking against `jsony`
- fewer moving parts than introducing native code immediately

### Phase 2: Replace the Weakest Generic Pieces

Primary targets:

1. object key dispatch
2. `seq` growth behavior
3. serializer buffer growth
4. nested object handling

This is where the first meaningful wins over `jsony` should come from.

### Phase 3: Integrate simdjson Backend

Add internal routing for:

- borrowed decode
- projection
- selective reads
- large document paths

Reuse `nim_simdjson` here instead of duplicating it.

### Phase 4: Native Hot Loops if Needed

Only do this after profiling shows the remaining bottlenecks are truly in:

- string escape/unescape loops
- key dispatch
- numeric parsing/formatting

If native code is used:

- expose a C ABI
- keep FFI coarse-grained
- do not cross the boundary per field

## Benchmark Matrix

Any serious implementation should be measured on all of these:

1. small flat object
2. medium object
3. large flat object
4. nested object
5. large nested object
6. string-heavy escaped payload
7. numeric-heavy payload
8. array-of-objects payload

For each:

- serialize
- deserialize
- borrowed deserialize where applicable
- projection/selective decode where applicable

Compare against:

- upstream `jsony`
- `nim_simdjson`
- the new engine

Iteration sets should include:

- 100
- 1000
- 10000
- 100000
- optionally 1000000 for stability

## Success Criteria

To justify this design, the package should aim for:

1. match or beat `jsony` on small and medium full typed serde
2. exceed `jsony` on nested and string-heavy cases by better dispatch and borrow/copy behavior
3. keep `nim_simdjson`-class strengths on borrowed/projection workloads
4. avoid large regressions across any one payload shape

## Non-Goals

Do not optimize for:

- dynamic `JsonNode` manipulation first
- DOM ergonomics first
- every obscure type shape in v1

Start with:

- scalars
- objects
- `seq`
- nested objects
- borrowed string views

Then extend carefully.

## Final Decision

If starting now, the best path is:

1. design a new generic package around a direct typed engine
2. reuse `nim_simdjson` as a specialized backend instead of forcing it to be the only engine
3. keep the public API very small
4. optimize by workload class rather than pretending one implementation is ideal for all JSON shapes

That gives the best chance of being:

- fast on small JSON
- fast on medium JSON
- competitive on nested JSON
- strong on large selective JSON

without repeating the mistake of chasing the wrong architecture for the wrong benchmark.
