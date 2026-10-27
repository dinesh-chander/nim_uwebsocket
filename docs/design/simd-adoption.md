# SIMD (nimsimd) adoption tracking

Tracks every place SIMD intrinsics (via the vendored [`nimsimd`](https://github.com/guzba/nimsimd)
binding) were **adopted** into the hot paths, and every place they were **evaluated and
deliberately not adopted** (with the measured reason). The goal is a durable, auditable
record of the SIMD surface so future work doesn't re-derive it.

- Dependency: `vendor/nimsimd` (v1.3.2), wired through `--path:vendor/nimsimd/src` in the
  Makefile, `harness/common.sh`, and `nim_uwebsocket.nimble`.
- Compiler: the project builds with **clang/LLVM** (`--cc:clang`). All SIMD paths are
  cross-compiler (gcc + clang) because they use nimsimd `_mm_*` intrinsics, not
  GCC-only `__builtin_ia32_*` emits.
- All gates green under clang: `nim_utils` 15/15, `nim_fasthttpclient` 9/9 (+1 gated),
  `nim_express` 74/74 (+gated).

## Key learnings
Cross-cutting lessons from this SIMD effort (the per-file evidence is in the tables below):

1. **Benchmark the dominant workload, not just the stress case.** The fastjson serialize scan was first *rejected* on an escape-dense-only workload, then *adopted* after testing length×density — the common no/sparse-escape case is 1.8–3.7× faster. A single adversarial workload hid a real win.
2. **SIMD wins on long, safe, regular spans — not short or dense data.** WS mask (2.4× @ 64 KB) and the fastjson no-escape scan (up to 3.7×) win on long runs; short line-bounded scans (HTTP `\r\n` ~6%), header-token find-first (−9%), and escape-dense strings regress or wash.
3. **The compiler changes SIMD outcomes.** gcc vs clang/LLVM flips results (long-key hash, WS mask 2.1×→2.4×). The project now builds with **clang/LLVM**; always benchmark under the real compiler.
4. **A faster scan only helps if it gates a bulk copy.** Serialize won because its scan gates a single `memcpy`; decode is copy/assignment-bound, so a faster decode scan is a wash.
5. **Zero-copy (borrow) is the real decode lever — and it was broken.** The `BorrowedString` path was a ~39× regression (O(n²) whole-doc `.cstring` identity + a fresh owner ref per field); fixed with O(1) source-pointer identity → now 1.1–1.2× faster than owned decode.
6. **Stay cross-compiler.** Use nimsimd `_mm_*` intrinsics, not GCC-only `__builtin_ia32_*` emits (the latter broke the clang build). Keep a portable fallback + a `-d:...Portable` toggle for A/B and non-x86.
7. **Build gotcha (LLVM switch):** uSockets is now compiled with clang+LTO (bitcode objects). It must be packed with `llvm-ar` and every link that consumes it must pass `-flto` — a `gcc-ar` archive or a no-`-flto` link fails with `uSockets.a: file format not recognized`.

## Adopted

| File | What | Intrinsic | Gate / toggle | Measured effect |
|------|------|-----------|---------------|-----------------|
| `nim_utils/src/nim_utils/helpers/simd_str.nim` | `simdStrEquals` — SSE2 16-byte compare with movemask early-exit; portable fallback. The shared primitive below builds on. | `mm_cmpeq_epi8`, `mm_movemask_epi8`, `mm_loadu_si128` | `simdStrUseSse2`; `-d:nimSimdStrPortable` | ~1.4–1.5× vs glibc `memcmp` for 16-byte keys; glibc wins on very long keys (rare). |
| `nim_utils/src/nim_utils/helpers/fast_map.nim` | Key comparison on the get/contains/put/del hot path uses `simdStrEquals` (was `equalMem`). | via `simd_str` | `simdStrUseSse2` | Short web-ish keys: win; long keys: neutral (glibc `memcmp` is itself SIMD). |
| `nim_utils/src/nim_utils/helpers/fast_set.nim` | Same key-compare change for set membership. | via `simd_str` | `simdStrUseSse2` | Same profile as `fast_map`. |
| `nim_utils/.../nim_fastjson/direct_engine.nim` | `scanSafeJsonBytes` — SSE2 (nimsimd) 16-byte "needs-escape" scan (control/quote/backslash) for string serialization; portable SWAR fallback. Re-introduces the kernel removed in `073cd40` (pure-Nim) as cross-compiler nimsimd intrinsics. | `mm_loadu_si128`, `mm_cmpeq_epi8`, `mm_min_epu8`, `mm_movemask_epi8` | `fastjsonScanUseSse2`; `-d:nimFastjsonPortable` | **Workload-dependent.** No-escape **1.8–3.7×**, sparse-escape **1.5–2.4×** faster across 32 B–64 KB (the dominant cases); escape-dense ≈1.0×; dense-64 KB −12% (rare). Net strongly positive. Full fastjson suite green (15/15). |
| `nim_utils/src/nim_utils/helpers/swar_group.nim` | Swiss-table group match (`swarMatch16` etc.) rewritten on nimsimd so it compiles under both gcc and clang (previously GCC-only emits). | `mm_loadu_si128`, `mm_cmpeq_epi8`, `mm_movemask_epi8` | `swarUseSimd` | Correctness/portability (enables the clang build); already-SIMD path preserved. |
| `nim_fasthttpclient/src/nim_fasthttpclient/http1.nim` | `findCrLf` — SSE2 `\r\n` finder (16 byte-pairs/vector) for the HTTP/1.1 response line scan; portable tail. | `mm_cmpeq_epi8`, `mm_and_si128`, `mm_movemask_epi8` | `http1CrlfUseSse2`; `-d:nimHttp1CrlfPortable` | End-to-end `feedData` parse ~6% faster (SSE2 64 ms vs 68 ms / 200k parses). Modest because parser scans are line-bounded (short). |
| `nim_fasthttpclient/src/nim_fasthttpclient/ws_frame.nim` (+ `ws_client.nim`) | `applyWsMask` — WebSocket payload mask/unmask (the receive path unmask is per masked frame) as in-place 16-byte XOR against the repeating 4-byte key; used by `encodeWsFrame`, `decodeWsFrame`, and the streaming client decode in `ws_client.nim`; portable tail. | `mm_loadu_si128`, `mm_xor_si128`, `mm_storeu_si128` | `wsFrameUseSse2`; `-d:nimWsFramePortable` | encode+decode round-trip: **2.4× at 64 KB** (14.4 vs 34.5 µs/op), 1.48× at 4 KB, 1.33× at 256 B. Correctness: round-trip doAssert + `test_fuzz` WS suites green. |
| `nim_express/src/nim_express/app.nim` | Route rejection: `sliceEquals` (first-segment compare) and the static-prefix `startsWith` in `routeFastReject` use `simdStrEquals`. | via `simd_str` | `simdStrUseSse2` | Route-reject compare workload **5.4× faster** (scalar 579 ms → simd 107 ms over a 200-route fan-out of near-miss ~15-byte prefix compares). |
| `nim_express/src/nim_express/middlewares/static_files.nim` | Static-mount prefix check (`path.startsWith(prefix)`) → guarded `simdStrEquals`. | via `simd_str` | `simdStrUseSse2` | Per static request; win scales with prefix length. Correctness: `test_static_files_improvements` green. |
| `nim_express/src/nim_express/middlewares/proxy.nim` | `stripPrefix` path check → guarded `simdStrEquals`. | via `simd_str` | `simdStrUseSse2` | Per proxied request; win scales with prefix length. Correctness: proxy tests green. |
| `nim_express/src/nim_express/middlewares/fast_proxy.nim` | Same `stripPrefix` check as `proxy`. | via `simd_str` | `simdStrUseSse2` | Per proxied request. Correctness: `test_fast_proxy_*` green. |

## Evaluated — not adopted (with reason)

These were profiled against the portable path and kept portable. Reasons are measured, not
speculative.

| File / area | What was tried | Why not adopted |
|-------------|----------------|-----------------|
| `nim_utils/.../nim_fastjson/direct_engine.nim` — `scanSafeJsonBytes` (initial pass) | SSE2 16-byte scan, first benchmarked on the escape-**dense** workload only. | Initially rejected (dense/short regressed −3.5%/−10%). **Superseded:** re-benchmarked across length×density shows the dense case was not representative — no/sparse-escape strings (the common case) are 1.8–3.7× faster, so it is now **adopted** (see Adopted table). Lesson: benchmark the dominant workload, not just the stress case. |
| `nim_utils/.../nim_fastjson/direct_engine.nim` — decode `scanStringEndWithHigh` + `containsHighByte` | SSE2 16-byte decode string scan (terminator + `sawHigh`, boundary-masked so it never leaks) and SIMD high-byte test. | **End-to-end deserialize is a wash:** SSE2 364 ms vs portable 363 ms over 30k deserializes of a 27 KB string-heavy doc (`bench_fastjson_decode.nim`). Deserialize is bound by copying the string content into the result + typed assignment + number parse, not by the scan — so a faster scan doesn't move it. (Serialize wins because its scan gates a single bulk memcpy; decode has no such asymmetry.) Reverted. |
| `nim_utils/.../nim_fastjson/direct_engine.nim` — simdjson-style SIMD structural pre-scan (phase-1 index of `{ } [ ] , :` + quotes) | The technique behind simdjson's 1.38× deserialize. | **Assessed, not pursued.** The decode engine is a recursive-descent cursor parser; capturing the phase-1 win means rewriting it into an index-walker (large, high-risk change to a ~4k-line engine). And because decode is copy/assignment-bound (the scan SIMD just measured a wash), the expected end-to-end gain is capped. Not a good incremental ROI. |
| `nim_utils/.../nim_fastjson/direct_engine.nim` — field-name matching (`matchField`) | SIMD key compare. | Already word-at-a-time with compile-time length dispatch; no measurable gain. |
| `nim_utils/.../helpers/fast_map.nim` — long-key `nimWyHash` | SSE 16-byte load/mix and wide XOR-accumulate hash. | Hash is 128-bit-multiply-latency-bound; SSE/AVX2 lack a 64×64→128 int multiply. The 3-interleaved scalar chain already beats any single SIMD chain (scalar ≤ simd across 256 B–64 KB under both gcc and clang). |
| `nim_express/src/nim_express/request.nim` — header-token scans (`firstHeaderToken`, `headerTokenFromRight`, `forwardedHeaderTokenCount`) | SSE2 find-first-of `{',' ' ' '\t'}` (3× `mm_cmpeq_epi8` + or + movemask) over header values. | **~9% slower** on a realistic header corpus (`bench_findfirst.nim`): values are short and the delimiter hits within the first few bytes, so the 3-compare vector prologue loses to the scalar early-exit. Kept portable. |
| `nim_express/src/nim_express/json_builder.nim` — escape scan | SSE2 needs-escape scan (same predicate as fastjson). | Cold path (manual/error JSON building; the typed hot path uses `nim_fastjson`). Same workload that regressed in fastjson, so not worth the second copy. Kept portable. |
| `nim_express/src/nim_express/app.nim` — `routeCacheHash` | SIMD hash. | FNV-1a is a sequential per-byte multiply chain (dependency-limited); not vectorizable (same class as the long-key wyhash result). |
| `nim_express/src/nim_express/app.nim` — `matchRoutePattern` | SIMD pattern match. | Irregular `:param` / `*` / wildcard char-by-char matching; no fixed-length compare structure to vectorize. |
Every `nim_express` middleware was reviewed individually (see the per-file coverage table below); the three with a genuine per-request prefix compare (`static_files`, `proxy`, `fast_proxy`) were adopted, the rest evaluated and kept portable for a file-specific reason.

### Decode: zero-copy `BorrowedString` fix (non-SIMD, adopted)
The real decode lever is not SIMD but avoiding the per-string copy. The zero-copy `BorrowedString` decode path existed but was a **~39× regression** vs owned-string decode (577 µs vs 15 µs for a `seq` of 1000 strings). Root cause: `borrowedDocHolderFor` identified the shared document owner with `s.cstring != holder.doc.cstring`, which materialized/compared the **whole document per borrowed field** (O(n²)) and allocated a fresh owner ref every field. Fixed by tracking the source buffer pointer in a threadvar (`tjBorrowDocSrc`) — O(1) identity, exactly one owner per document. Result: zero-copy borrow is now **1.12–1.19× faster** than owned decode (`bench_fastjson_borrow.nim`), as intended. Gate green.

## Middleware coverage (per file)

All 38 middleware sources reviewed. **Adopted** = `simdStrEquals` on a genuine per-request prefix/segment compare. **Not adopted** = specific reason (short literal below SIMD threshold, case-insensitive, security-sensitive, allocation/parsing/search-dominated, or no per-request string compare).

| Middleware | Decision | Reason |
|-----------|----------|--------|
| `proxy.nim` | **Adopted** | `stripPrefix` path prefix compare. |
| `fast_proxy.nim` | **Adopted** | `stripPrefix` path prefix compare. |
| `static_files.nim` | **Adopted** | static-mount path prefix compare. |
| `rate_limit.nim` | Not adopted | Bucket key already goes through `FastMap` (already `simdStrEquals`); key build is int/short. |
| `multipart.nim` | Not adopted | Boundary located via std `findSubstr` (substring **search**, not a compare) — a genuine SIMD-search candidate but a larger, riskier change; deferred. |
| `cors.nim` | Not adopted | Origin allowlist uses `cmpIgnoreCase` (case-insensitive, short origins); not a plain-memcmp fit. |
| `csrf.nim` | Not adopted | Token equality is security-sensitive (wants constant-time, not an early-exit SIMD compare); kept `==`. |
| `etag.nim` / `etag_core.nim` | Not adopted | `weakEqual` = `stripWeakPrefix(a)==stripWeakPrefix(b)`; allocation/split-dominated, short tags — compare is not the bottleneck. |
| `normalize_path.nim` | Not adopted | `./`/`../`/`..`/`.` checks are 1–3 char literals, below the SIMD threshold. |
| `session.nim` | Not adopted | Cookie `startsWith(SessionPrefix)` — short fixed prefix, below threshold. |
| `body_parser.nim` | Not adopted | content-type/charset parsing; short case-insensitive token checks, parsing-dominated. |
| `cookie_parser.nim` | Not adopted | Cookie split on `;`/`=`; short field compares, parsing-dominated. |
| `ip_filter.nim` | Not adopted | IP literal/CIDR parsing and range math; not a plain byte compare. |
| `compression.nim` | Not adopted | content-encoding negotiation — short fixed encoding-name compares. |
| `htmx.nim` | Not adopted | `HX-*` header presence/value checks — short fixed literals. |
| `method_override.nim` | Not adopted | Override param resolution — short fixed key/value checks. |
| `output_cache.nim` | Not adopted | Short `token=="*"`; cache key lookup already via `FastMap` (SIMD). |
| `opentelemetry.nim` | Not adopted | Trace-id zero-segment checks — short fixed literals. |
| `backpressure.nim` | Not adopted | Startup env check + request counters; no per-request string compare. |
| `body_limit.nim` | Not adopted | content-length is an integer parse/compare; no string compare. |
| `circuit_breaker.nim` | Not adopted | State machine/counters; no string compare. |
| `common.nim` | Not adopted | Shared option types/helpers; no hot string compare. |
| `concurrency_guard.nim` | Not adopted | Concurrency counters; no string compare. |
| `error_handler.nim` | Not adopted | Exception/status formatting; no per-request compare. |
| `file_helpers.nim` | Not adopted | Filesystem path helpers; no hot string compare. |
| `global_error_filter.nim` | Not adopted | Error classification; short status/keyword checks. |
| `graceful_shutdown.nim` | Not adopted | Lifecycle/signals; no per-request string work. |
| `health.nim` | Not adopted | Readiness status; no string compare. |
| `helmet.nim` | Not adopted | Emits fixed security headers; no compare. |
| `io_helpers.nim` | Not adopted | IO buffering helpers; no string compare. |
| `json_logger.nim` | Not adopted | Log line building; formatting-dominated. |
| `logger.nim` | Not adopted | Log line building; formatting-dominated. |
| `openapi.nim` | Not adopted | Spec generation at setup; not per-request. |
| `panic_recovery.nim` | Not adopted | Exception capture; no per-request string compare. |
| `prometheus.nim` | Not adopted | Metric name/format building; formatting-dominated. |
| `request_id.nim` | Not adopted | Generates a random/UUID id; no compare. |
| `response_time.nim` | Not adopted | Duration formatting; no compare. |
| `server_timing.nim` | Not adopted | Timing header formatting; no compare. |
| `timeout.nim` | Not adopted | Deadline/timing; no string compare. |

## Benchmarks

- `nim_utils/benchmark/bench_simd_str.nim` — `simdStrEquals` vs `equalMem` by length.
- `nim_utils/benchmark/bench_fastjson_scan.nim` — fastjson scan kernel SSE2 vs portable (dense-only, superseded).
- `nim_utils/benchmark/bench_fastjson_scan2.nim` — fastjson serialize scan SSE2 vs portable across length×density (the adopted result).
- `nim_utils/benchmark/bench_fastjson_decode.nim` — fastjson deserialize string-heavy SSE2 vs portable (the decode wash result).
- `nim_utils/benchmark/bench_string_heavy_fastjson.nim` — end-to-end fastjson serialize/deserialize.
- `nim_utils/benchmark/bench_crlf.nim` — `findCrLf` SSE2 vs portable by span length.
- `nim_utils/benchmark/bench_http1_parse.nim` — end-to-end HTTP/1.1 `feedData` parse.
- `nim_utils/benchmark/bench_route_match.nim` — route-reject compare scalar vs simd.
- `nim_utils/benchmark/bench_ws_mask.nim` — WebSocket encode+decode mask round-trip SSE2 vs portable by payload size.
- `nim_utils/benchmark/bench_findfirst.nim` — header find-first-delimiter SSE2 vs scalar on a realistic corpus (the not-adopted result).

## Toggle flags (force portable for A/B or debugging)

- `-d:nimSimdStrPortable` — `simd_str` (fastmap/fastset/routing) portable path.
- `-d:nimSwarPortable` — `swar_group` portable path.
- `-d:nimHttp1CrlfPortable` — `http1.findCrLf` portable path.
- `-d:nimWsFramePortable` — `ws_frame.applyWsMask` portable path.
- `-d:nimFastjsonPortable` — fastjson `scanSafeJsonBytes` portable (SWAR) path.
