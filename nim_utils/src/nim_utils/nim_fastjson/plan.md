# nim_fastjson Generic High-Performance Plan

## Goal
Build a generic high-performance serializer and deserializer that keeps the public API simple:

- `serialize(value)`
- `deserialize(json, T)`

The fast path should be selected automatically from `T` at compile time for normal typed code.

## Current Bottlenecks

### Serialize
Fresh serialize samples show that the hot path is still dominated by string-body work.

#### historical_events serialize
- `cPutJsonBody`: about 38.5%
- `json_write_string`: about 31.1%
- `_platform_memmove`: about 10.8%
- Combined string-body + copy traffic: about 80%

#### twitter serialize
- `json_write_string`: about 19.9%
- `cPutJsonBody`: about 19.7%
- `writeValueC...`: about 17.0%
- `_platform_memmove`: about 14.4%
- `_tlv_get_addr`: about 5.2%
- `cPutInt`: about 2.0%
- Combined string-body + copy traffic: about 54%

### Deserialize
The long-term deserializer bottleneck remains:
- repeated per-field lookup
- owned string materialization
- intermediate decode work for nested objects and arrays

## Recommended Architecture

### 1. Two-layer design
- Typed fast path generated at compile time
- Dynamic fallback path for unsupported or runtime-shaped JSON

Do not try to make one reflective runtime path be both the most generic and the fastest.

### 2. Keep the public API simple
- `serialize(value)` is the main entry point
- `deserialize(json, T)` is the main typed entry point

Nim already knows `T` at compile time for normal generic code, so extra user hints are usually unnecessary.

### 3. Use Nim macros for control flow, native code for hot kernels
Generate per-type code for:
- field order
- field names
- nested object/seq recursion
- nullable/optional behavior
- borrowed vs owned string policy

Use native code only for the kernels that benefit:
- string scan/escape/copy
- integer and float formatting
- one-pass ondemand extraction
- batched walkers for arrays/objects

## Serializer Strategy

### Typed serializer fast path
- direct write into preallocated output
- generated per-type object writers
- specialized `seq[T]` path for homogeneous object arrays
- reuse per-batch scratch buffers

### String-heavy `seq[T]` path
The next real path to 5x on string-heavy roots is:
- pre-scan string fields once per batch
- cache useful metadata per string, not just a boolean
  - string length
  - first unsafe byte offset, or sentinel for fully safe
- emit rows using that cached metadata
- use native `json_write_string` only when needed

The failed boolean column prepass should not be retried. It rescanned the same bytes without preserving enough information to pay for itself.

### Dataset-specific serializer paths
- `twitter`, `historical_events`: string-field batching
- `citm_catalog`: `Table` specialization
- `canada`: float-array / coordinate specialization

## Deserializer Strategy

### Typed deserializer fast path
- native ondemand one-pass traversal
- generated per-type direct-destination decode
- no DOM tree for typed hot paths
- no subtree reparsing
- no generic intermediate value tree for Tier-1 types

### String ownership
Use two categories:
- `string`: allocate once at the final assignment boundary
- `JsonStringView` / borrowed string: zero-copy all the way

This is required for a truly high-performance generic typed decoder.

## What To Avoid
- more runtime reflection in hot loops
- more boolean-only prepasses
- one-off handwritten fast paths per business schema
- pushing all control flow into C/C++ instead of only the kernels

## Execution Order

### Phase 1: Serializer
1. Generated per-type serializer metadata and support matrix
2. Generated direct object serializer
3. `seq[T]` string scan metadata cache
4. Native string-body writer that consumes cached metadata
5. Reusable scratch buffers for batched `seq[T]`
6. Table-heavy and float-heavy specializations

### Phase 2: Deserializer
1. Generated decode plan metadata
2. Native ondemand direct-destination decoder for leaf objects
3. Nested object/array direct decode
4. Borrowed-string typed decode
5. Fallback routing for unsupported shapes

## Success Criteria

### Serializer
- 5x on string-heavy `seq[object]` datasets is plausible only with generated batching plus cached string scan metadata
- float-heavy and table-heavy datasets will need their own specialized fast paths

### Deserializer
- remove repeated field lookup
- avoid intermediate trees
- delay or eliminate owned string creation where possible

