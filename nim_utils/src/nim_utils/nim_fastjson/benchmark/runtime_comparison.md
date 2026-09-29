# Cross-runtime benchmark: fastjson vs Node.js vs System.Text.Json

This report compares:

- `fastjson` (`nim_fastjson`)
- Node.js built-in JSON (`JSON.parse` / `JSON.stringify`)
- .NET `System.Text.Json` (`JsonSerializer.Deserialize<JsonElement>` / `JsonSerializer.Serialize`)

Datasets:

- `twitter`
- `citm`
- `canada`
- `historical`

## Method

To make the payloads comparable, the benchmark first normalizes each dataset
through the same typed `fastjson` model and then benchmarks all three runtimes
against that normalized JSON payload.

That avoids comparing Node/.NET against the raw original file while `fastjson`
is operating on a reduced typed shape.

Iteration policy matches the existing API benchmark:

- `< 64 KB`: `300`
- `< 512 KB`: `120`
- `< 2 MB`: `40`
- otherwise: `12`

Warmup policy:

- each runtime performs `10` untimed warmup passes
- only the final timed pass is recorded
- this reduces JIT/tier-up distortion for Node.js and .NET

Runners:

- [cross_runtime_fastjson.nim](/nim_utils/src/nim_utils/nim_fastjson/benchmark/cross_runtime_fastjson.nim)
- [cross_runtime_node.mjs](/nim_utils/src/nim_utils/nim_fastjson/benchmark/cross_runtime_node.mjs)
- [cross_runtime_dotnet/Program.cs](/nim_utils/src/nim_utils/nim_fastjson/benchmark/cross_runtime_dotnet/Program.cs)
- [normalize_cross_runtime_payloads.nim](/nim_utils/src/nim_utils/nim_fastjson/benchmark/normalize_cross_runtime_payloads.nim)

Build/runtime settings:

- `fastjson` was built without `-d:danger`
- `fastjson` build flags:
  - `-d:release`
  - `--passC:-O3`
  - `--passC:-mcpu=native`
  - `--passC:-flto`
  - `--passL:-flto`
  - Homebrew Clang `22.1.1`
  - Clang instrumentation PGO via `-fprofile-instr-generate` / `-fprofile-instr-use`
- true sample-based AutoFDO was not enabled yet
  - `llvm-profgen` is available through Homebrew LLVM
  - but the current macOS environment still does not provide a `perf`-compatible
    sampling pipeline that `llvm-profgen` can consume directly
- .NET was run with:
  - `DOTNET_TieredCompilation=1`
  - `DOTNET_TieredPGO=1`
  - `DOTNET_ReadyToRun=0`
  - `DOTNET_TC_QuickJit=1`
  - `DOTNET_TC_QuickJitForLoops=1`
  - `DOTNET_TC_CallCountingDelayMs=0`

## Results

### Deserialize

Ops/s:

| Dataset | Payload | Node.js | System.Text.Json | fastjson |
|---|---:|---:|---:|---:|
| twitter | 231 KB | 2,112 | 1,850 | 5,906 |
| citm | 474 KB | 582 | 365 | 2,590 |
| canada | 2.09 MB | 77.0 | 90.9 | 380.9 |
| historical | 8.33 MB | 53.2 | 55.1 | 159.8 |

ns/op:

| Dataset | Node.js | System.Text.Json | fastjson |
|---|---:|---:|---:|
| twitter | 473,517 | 540,647 | 169,326 |
| citm | 1,719,140 | 2,741,210 | 386,066 |
| canada | 12,991,844 | 10,996,225 | 2,625,471 |
| historical | 18,797,830 | 18,164,458 | 6,256,132 |

### Serialize

Ops/s:

| Dataset | Payload | Node.js | System.Text.Json | fastjson |
|---|---:|---:|---:|---:|
| twitter | 231 KB | 2,976 | 2,427 | 20,601 |
| citm | 474 KB | 667 | 1,231 | 4,953 |
| canada | 2.09 MB | 77.8 | 381.2 | 374.3 |
| historical | 8.33 MB | 53.5 | 82.6 | 467.0 |

ns/op:

| Dataset | Node.js | System.Text.Json | fastjson |
|---|---:|---:|---:|
| twitter | 335,971 | 412,013 | 48,541 |
| citm | 1,499,031 | 812,459 | 201,895 |
| canada | 12,859,715 | 2,623,168 | 2,671,645 |
| historical | 18,691,430 | 12,103,850 | 2,141,493 |

## Ratios vs fastjson

### Deserialize speedup

| Dataset | vs Node.js | vs System.Text.Json |
|---|---:|---:|
| twitter | 2.80x | 3.19x |
| citm | 4.45x | 7.10x |
| canada | 4.95x | 4.19x |
| historical | 3.00x | 2.90x |

### Serialize speedup

| Dataset | vs Node.js | vs System.Text.Json |
|---|---:|---:|
| twitter | 6.92x | 8.49x |
| citm | 7.42x | 4.02x |
| canada | 4.81x | 0.98x |
| historical | 8.73x | 5.65x |

## Takeaways

- `fastjson` leads deserialize on all four normalized datasets.
- `fastjson` leads serialize on `twitter`, `citm`, and `historical`.
- `canada` serialize is now very close, but `System.Text.Json` still edges it
  out.
- The stronger Nim build settings matter materially: release + `O3` + native
  CPU + LTO + Clang PGO with Homebrew Clang improved the `fastjson` side well
  beyond the earlier warmed-only run.
- The 10-pass warmup and more aggressive .NET tiered JIT settings produce a
  more defensible runtime comparison than the earlier single-warmup run.

## Caveats

- Node.js and .NET are using their standard dynamic JSON APIs here.
- `fastjson` is using typed models because that is the package's primary API.
- This is a practical comparison of default runtime behavior on the same
  normalized payloads, not a strict apples-to-apples typed-vs-typed benchmark.
