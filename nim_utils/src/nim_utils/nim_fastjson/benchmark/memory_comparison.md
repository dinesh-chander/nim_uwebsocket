# fastjson vs jsony memory comparison

This report records peak resident set size (RSS) comparisons for `nim_fastjson`
vs `jsony` on the same shaped workloads used by
[bench_api_surface.nim](/nim_utils/src/nim_utils/nim_fastjson/benchmark/bench_api_surface.nim).

Method:

- one isolated process per library/op/scenario
- peak RSS from `/usr/bin/time -l`
- same payload shapes as the public API benchmark
- comparisons are most useful as `fastjson - jsony` deltas, not absolute RSS

## Core serialize / deserialize(string)

Peak RSS in MB:

| Dataset | Size | jsony serialize | fastjson serialize | Delta | jsony deserialize | fastjson deserialize | Delta |
|---|---:|---:|---:|---:|---:|---:|---:|
| twitter | 10 | 39.0 | 39.0 | 0.0 | 39.1 | 39.0 | -0.0 |
| citm | 10 | 39.4 | 39.3 | -0.1 | 39.4 | 39.4 | -0.0 |
| canada | 10 | 166.6 | 125.0 | -41.6 | 132.5 | 194.6 | +62.2 |
| historical | 10 | 38.8 | 38.8 | -0.0 | 38.8 | 38.8 | -0.0 |
| twitter | 1000 | 48.6 | 46.3 | -2.3 | 44.6 | 45.9 | +1.3 |
| citm | 1000 | 46.0 | 43.2 | -2.8 | 42.5 | 43.3 | +0.8 |
| historical | 1000 | 39.6 | 39.5 | -0.2 | 39.6 | 39.6 | -0.0 |

Notes:

- `twitter`, `citm`, and `historical` are very close in memory usage.
- `fastjson` is slightly lower on large serialize-heavy `twitter` and `citm`.
- `canada` is the strong outlier:
  - serialize: `fastjson` uses much less memory
  - deserialize: `fastjson` uses much more memory

## Public API methods

Representative peak RSS in MB:

| Method | Dataset | Size | jsony | fastjson | Delta |
|---|---|---:|---:|---:|---:|
| serializeToBytes | twitter | 100 | 39.6 | 39.6 | -0.0 |
| serializeToStream | twitter | 100 | 39.6 | 39.4 | -0.2 |
| deserialize(bytes) | twitter | 100 | 39.7 | 39.6 | -0.0 |
| deserialize(stream) | twitter | 100 | 39.7 | 39.6 | -0.0 |
| isValidJson(bytes) | twitter | 100 | 39.7 | 40.2 | +0.5 |
| isValidJson(stream) | twitter | 100 | 39.7 | 40.4 | +0.8 |
| serializeToBytes | citm | 100 | 39.5 | 39.4 | -0.0 |
| serializeToStream | citm | 100 | 39.5 | 39.4 | -0.0 |
| deserialize(bytes) | citm | 100 | 39.5 | 39.4 | -0.1 |
| deserialize(stream) | citm | 100 | 39.5 | 39.5 | -0.1 |
| isValidJson(bytes) | citm | 100 | 39.5 | 40.4 | +0.9 |
| isValidJson(stream) | citm | 100 | 39.5 | 40.5 | +1.0 |
| serializeToBytes | historical | 100 | 39.0 | 38.9 | -0.0 |
| serializeToStream | historical | 100 | 39.0 | 38.9 | -0.1 |
| deserialize(bytes) | historical | 100 | 38.9 | 38.9 | -0.0 |
| deserialize(stream) | historical | 100 | 39.0 | 38.9 | -0.1 |
| isValidJson(bytes) | historical | 100 | 38.9 | 39.1 | +0.2 |
| isValidJson(stream) | historical | 100 | 39.0 | 39.2 | +0.1 |
| serializeToBytes | canada | 10 | 186.5 | 145.0 | -41.6 |
| serializeToStream | canada | 10 | 186.5 | 125.0 | -61.5 |
| deserialize(bytes) | canada | 10 | 152.4 | 214.6 | +62.2 |
| deserialize(stream) | canada | 10 | 189.6 | 214.6 | +25.0 |
| isValidJson(bytes) | canada | 10 | 152.4 | 163.5 | +11.0 |
| isValidJson(stream) | canada | 10 | 189.7 | 183.4 | -6.2 |

## Practical conclusions

- For most workloads, memory usage is effectively a wash.
- `fastjson` tends to be slightly better on serialize-heavy `twitter` and `citm`.
- `historical` is essentially tied.
- `canada` still has the clearest memory split:
  - `fastjson` wins on serialize memory
  - `fastjson` loses on deserialize memory
- The fast validation APIs are primarily a CPU win. Their memory usage is
  usually close to `jsony`, with small overheads on smaller datasets and mixed
  results on `canada`.

## Caveats

- These are process-level RSS measurements, not per-allocation traces.
- The benchmark process includes Nim runtime startup and the cost of loading the
  shaped benchmark value before the specific measured API call.
- Very large scenarios can be noisy; the delta is more trustworthy than the raw
  peak.
