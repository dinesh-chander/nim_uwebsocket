# Performance Optimization Opportunities (nim_express + nim_usockets)

Date: 2026-03-10
Scope: Throughput + p95/p99 improvements while preserving HTTP/WebSocket compliance.

## Evidence snapshot

- Current full-fragment benchmark baseline is strong on throughput but still tail-sensitive under load:
  - `benchmark/reports/todo_vs_dotnet_20260310_194041/summary.md:14-16`
  - `benchmark/reports/todo_vs_dotnet_20260310_194041/nim_1.txt:4-13`
- At higher concurrency (1000 conns), p99 inflates notably with read socket errors:
  - `benchmark/reports/todo_stability_20260308_141604/wrk.txt:4-13`
  - `benchmark/reports/todo_stability_20260308_141807/wrk.txt:4-13`
- Latest flat profiles show dominant buckets in transport syscalls, memmove/copy, and SQLite VM execution:
  - `benchmark/profiles/todo_frag_20260310_194124/top_flat.txt:2-5`
  - `benchmark/profiles/todo_frag_20260310_194232/top_flat.txt:2-5`
- Existing controls already available but need tuning/operationalization:
  - Linux throughput profile knobs: `nim_express/src/nim_express/app.nim:882-905`
  - Overload/queue/timeouts defaults and setters: `nim_usockets/src/nim_usockets/http.nim:7504-7593`, `7896-8098`
  - Adaptive overload algorithm: `nim_usockets/src/nim_usockets/http.nim:1657-1717`
- Platform constraints are explicit:
  - macOS single-process constraints: `nim_express/src/nim_express/app.nim:3097-3114`, `3213-3237`
  - Linux scaling guidance and transport matrix harness:
    - `benchmark/linux_runtime_profile.md:8-23`
    - `benchmark/run_linux_transport_ceiling.sh:22-30`, `144-153`, `155-167`
    - `benchmark/run_linux_transport_knob_matrix.sh:12-40`
- Compliance baseline must remain intact:
  - `benchmark/http_compliance_iterations_20260305.md:1-23`
  - `http_compliance.md:41-58`, `64-75`

## Immediate top 3 execution order

1. **P1: Linux transport/backend + worker-topology matrix** (PERF-001)
2. **P2: Overload + fairness + timeout calibration under pressure** (PERF-002)
3. **P3: Windowed fragment delivery as default high-cardinality path** (PERF-006)

Rationale: this order gives fastest measurable wins with minimal protocol-risk, and creates a stable baseline before deeper code-path optimizations.

---

## Top 10 prioritized opportunities

### P1. Linux transport/backend & worker-topology matrix (PERF-001)
- Expected impact: **High** throughput gain on Linux (+15% to +40%), p95/p99 improvement from reduced queueing.
- Complexity: **Medium**
- Risk: **Low-Medium**
- Platform split:
  - Linux: primary target.
  - macOS: not primary (single-process constraints).
- Evidence:
  - `benchmark/linux_runtime_profile.md:8-18`
  - `benchmark/run_linux_transport_ceiling.sh:22-30`, `116-119`, `144-153`
  - `nim_express/src/nim_express/app.nim:3097-3130`, `3213-3237`
- Affected files/modules:
  - `benchmark/run_linux_transport_ceiling.sh`
  - `benchmark/run_linux_transport_knob_matrix.sh`
  - `nim_express/src/nim_express/app.nim`
  - `nim_usockets/src/nim_usockets/http.nim`
- Measurement plan:
  - Run 5x repeats for each policy/backend combo (`baseline`, `exclusive`, `edge`, `exclusive_edge`; `epoll`, opt-in `io_uring`).
  - Capture `rps`, `p50/p95/p99`, and `perf_top.txt` for each run.
  - Keep same `NIM_EXPRESS_PROFILE` and seed data for comparability.

### P2. Overload, fairness budgets, and timeout calibration under pressure (PERF-002)
- Expected impact: **High p99** improvement under saturation (-20% to -45% tail) with stable throughput.
- Complexity: **Medium**
- Risk: **Medium** (mis-tuning can raise reject/drop rates)
- Platform split:
  - Linux: broader envelope.
  - macOS: especially important since vertical scaling is constrained.
- Evidence:
  - Tail drift at high concurrency: `benchmark/reports/todo_stability_20260308_141807/wrk.txt:4-13`
  - Overload defaults off by default: `nim_usockets/src/nim_usockets/http.nim:7563-7567`
  - Overload adaptive logic exists: `nim_usockets/src/nim_usockets/http.nim:1657-1717`
  - Exposed tuning/env knobs: `nim_express/src/nim_express/app.nim:986-1017`
- Affected files/modules:
  - `nim_express/src/nim_express/app.nim`
  - `nim_usockets/src/nim_usockets/http.nim`
  - `nim_express/examples/todo_sqlite_mvc_app.nim`
- Measurement plan:
  - Step-load tests at `c=200/500/1000/2000` with fixed threads.
  - Track `overload_rejects`, backlog/pending reject counters (`/metrics`) and socket errors.
  - Select profile where p99 improves without material (>5%) throughput regression.

### P3. Windowed fragment delivery as default for high-cardinality lists (PERF-006)
- Expected impact: **High tail** improvement (p95/p99 -40% to -70% on large lists), often throughput-positive due to smaller response bodies.
- Complexity: **Medium**
- Risk: **Medium** (client behavior/API expectations)
- Platform split: both Linux and macOS benefit.
- Evidence:
  - Full-mode payload is heavy (`~1.28-1.36GB/s transfer`): `benchmark/profiles/todo_frag_20260310_194124/wrk.txt:11-13`, `benchmark/reports/todo_vs_dotnet_20260310_194041/nim_1.txt:11-13`
  - Windowing path already implemented with Range semantics: `nim_express/examples/todo_sqlite_mvc/todo_controller.nim:108-161`, `179-183`
  - Compliance alignment for range-window responses: `http_compliance.md:55`
- Affected files/modules:
  - `nim_express/examples/todo_sqlite_mvc/todo_controller.nim`
  - `nim_express/src/nim_express/request.nim`
  - `nim_express/src/nim_express/response.nim`
  - `benchmark/run_todo_fragment_windowing.sh`
- Measurement plan:
  - Compare `mode=full` vs `mode=window` at same load (200/500/1000 conns).
  - Record transfer/sec, p95/p99, and verify `206/416` correctness.

### P4. SQLite read-path optimization for fragment endpoints (PERF-005)
- Expected impact: **Medium-High** throughput gain (+10% to +25%) on DB-bound routes.
- Complexity: **Medium-High**
- Risk: **Medium** (durability/consistency tradeoffs if pragmas changed)
- Platform split: both OSes.
- Evidence:
  - SQLite VM consistently hot: `benchmark/profiles/todo_frag_20260310_194124/top_flat.txt:4`, `benchmark/profiles/todo_frag_20260310_194232/top_flat.txt:4`
  - Streaming path per-row step/column access: `nim_express/examples/todo_sqlite_mvc/todo_model.nim:271-299`
  - Prepared statement setup and busy timeout present: `nim_express/examples/todo_sqlite_mvc/todo_model.nim:441-452`
- Affected files/modules:
  - `nim_express/examples/todo_sqlite_mvc/todo_model.nim`
  - SQLite schema/bootstrap in same module
- Measurement plan:
  - Benchmark candidate pragmas/indexes one-by-one (WAL/synchronous/cache/mmap).
  - Validate correctness/durability assumptions in write-heavy smoke tests.
  - Use `tmp_todo_fragment_profile.sh` to confirm `sqlite3VdbeExec` share reduction.

### P5. Reduce memcopy/memmove pressure in fragment render path (PERF-004)
- Expected impact: **Medium** (+8% to +18% throughput, better p95).
- Complexity: **Medium-High**
- Risk: **Low-Medium**
- Platform split:
  - macOS: likely more visible due single-process cap.
  - Linux: still useful per worker.
- Evidence:
  - `platform_memmove` and `memcpy` are major buckets: `benchmark/profiles/todo_frag_20260310_194124/top_flat.txt:3,6`, `benchmark/profiles/todo_frag_20260310_194232/top_flat.txt:3,6`
  - Hot render path uses planned fast append and raw copies: `nim_express/examples/todo_sqlite_mvc/todo_view.nim:303-368`
  - Paged buffer copy-heavy paths: `nim_express/src/nim_express/paged_buffer.nim:243-253`, `301-339`
- Affected files/modules:
  - `nim_express/examples/todo_sqlite_mvc/todo_view.nim`
  - `nim_express/src/nim_express/paged_buffer.nim`
  - `nim_express/src/nim_express/response.nim`
- Measurement plan:
  - Before/after `sample` + `top_flat` on `/todos/fragment?mode=full`.
  - Validate no HTML escaping regressions and stable response correctness.

### P6. Re-tune write coalescing mode and p99 guard by workload (PERF-003)
- Expected impact: **Medium** (+5% to +15% throughput or -10% to -25% p99 depending on profile).
- Complexity: **Medium**
- Risk: **Medium** (HOL blocking if too aggressive)
- Platform split:
  - Linux: combine with epoll tuning.
  - macOS: focus on tail control.
- Evidence:
  - Coalescing policy and p99 guard logic already exists: `nim_usockets/src/nim_usockets/http.nim:1180-1256`
  - Throughput profile currently forces throughput mode: `nim_express/src/nim_express/app.nim:896-899`
- Affected files/modules:
  - `nim_usockets/src/nim_usockets/http.nim`
  - `nim_express/src/nim_express/app.nim`
- Measurement plan:
  - A/B test `wcmThroughput` vs `wcmAdaptive` + guard thresholds.
  - Evaluate at low/medium/high concurrency to avoid overfitting.

### P7. Linux affinity/NUMA policy hardening for clusters (PERF-007)
- Expected impact: **Medium** (+10% to +35% throughput on multi-core Linux deployments).
- Complexity: **Low-Medium**
- Risk: **Low**
- Platform split:
  - Linux only.
  - macOS not applicable.
- Evidence:
  - Worker affinity support exists: `nim_express/src/nim_express/app.nim:375-393`
  - Worker default policy and Linux profile behavior: `nim_express/src/nim_express/app.nim:394-405`
  - Linux WS/process scaling guidance: `benchmark/linux_ws_scaling.md:8-22`
- Affected files/modules:
  - `nim_express/src/nim_express/app.nim`
  - `benchmark/linux_affinity_numa.sh`
- Measurement plan:
  - Sweep worker counts and pinned CPU sets.
  - Compare cache-miss-sensitive perf counters and p99.

### P8. WebSocket backpressure/coalescing tuning for transport-dominated path (PERF-008)
- Expected impact: **Medium** in WS workloads (+5% to +15% msg/s, p99 send-latency improvements).
- Complexity: **Medium**
- Risk: **Medium** (drop/close behavior must remain deterministic)
- Platform split:
  - macOS: kqueue dominated.
  - Linux: validate with multi-process scaling.
- Evidence:
  - WS bottleneck is kernel transport now: `benchmark/ws_taskB_report.md:38-42`, `benchmark/ws_taskB_iter10_report.md:34-39`
  - WS backpressure controls in server options: `nim_usockets/src/nim_usockets/http.nim:364-368`, `1719-1735`
- Affected files/modules:
  - `nim_usockets/src/nim_usockets/http.nim`
  - `benchmark/ws_bench.js`
  - `benchmark/run_ws_bench_once.sh`
- Measurement plan:
  - Repeat iter-style WS benches with fixed open sockets and payload.
  - Track drops/high-water events and latency distribution.

### P9. Slow-client timeout profile for long-run stability (PERF-009)
- Expected impact: **Medium tail-stability** (-15% to -35% p99 drift in soak tests).
- Complexity: **Low-Medium**
- Risk: **Medium** (false timeout risk)
- Platform split: both OSes.
- Evidence:
  - High-concurrency soak had read socket errors and larger tails: `benchmark/reports/todo_stability_20260308_141807/wrk.txt:10-13`
  - Timeout knobs exist but default to disabled (0) except connection timeout: `nim_usockets/src/nim_usockets/http.nim:7588-7593`
  - Timeout handling path: `nim_usockets/src/nim_usockets/http.nim:7483-7499`
- Affected files/modules:
  - `nim_usockets/src/nim_usockets/http.nim`
  - `nim_express/src/nim_express/app.nim`
- Measurement plan:
  - Add slow-reader and slow-header synthetic clients.
  - Tune thresholds to reduce queue bloat without affecting normal traffic.

### P10. Perf+compliance gating harness unification (PERF-010)
- Expected impact: **Indirect but high confidence gain** (faster safe iteration, fewer regressions).
- Complexity: **Low**
- Risk: **Low**
- Platform split: both OSes, Linux primary for ceiling checks.
- Evidence:
  - Existing perf scripts are rich but fragmented:
    - `benchmark/run_todo_vs_dotnet.sh:80-96`, `174-201`
    - `benchmark/tmp_todo_fragment_profile.sh:50-77`
    - `benchmark/run_linux_transport_ceiling.sh:144-167`
  - Compliance checks already exist: `benchmark/http_compliance_iterations_20260305.md:1-23`
- Affected files/modules:
  - `benchmark/*.sh`
  - `benchmark/http_compliance_iterations_20260305.md`
- Measurement plan:
  - Define one standard benchmark suite per PR/branch:
    - short smoke, pressure profile, long soak, compliance checks.
  - Require median-of-N and p99 guardrails for acceptance.

---

## Compliance constraints to keep fixed while optimizing

- Preserve strict request framing and TE/CL handling semantics:
  - `http_compliance.md:49-55`
- Preserve websocket handshake and framing correctness:
  - `http_compliance.md:64-74`
- Keep compliance validation in perf loops:
  - `benchmark/http_compliance_iterations_20260305.md:7-23`
