# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the **benchmark/** subdirectory of the nim_uwebsocket project. See the parent `../AGENTS.md` for framework architecture, scaling patterns, and common issues.

## Agent Policy

**All tasks in this project must be executed in a subagent.** When the user gives you a task, dispatch it to a subagent using the Agent tool. Parse the user's input as the task prompt, choose the appropriate subagent type (general-purpose for implementation, Explore for research, Plan for architecture), and run it. Only respond directly for clarifying questions or reporting subagent results.

## Build Commands

All builds run from the **project root** (`../`), not from `benchmark/`.

```bash
# Build the main benchmark binary (single-process)
make bench

# Build with GCD event loop (macOS default)
make bench-gcd

# kqueue is exposed as a compatibility alias and maps to GCD on macOS.
make bench-kqueue

# Build a specific benchmark variant
make bench BENCH_SRC=benchmark/bench_nim_express_cluster.nim BENCH_BIN=benchmark/bench_nim_express_cluster

# PGO (profile-guided optimization) build
bash benchmark/build_nim_express_pgo.sh

# Run tests
make test

# Rebuild uSockets (if C layer changed)
make usockets        # auto-detects macOS backend
make usockets-gcd    # force GCD
make usockets-kqueue # compatibility alias; maps to GCD on macOS
```

### Direct nim compile (from benchmark/)
```bash
nim c -d:release -d:danger --opt:speed --mm:arc \
  --passL:"../nim_usockets/usockets/uSockets.a -lpthread -ldl" \
  -o:bench_nim_express bench_nim_express.nim
```

Use `-framework CoreFoundation` on macOS. Add `-L/opt/homebrew/lib -ljemalloc` for Homebrew jemalloc.

## Running Benchmarks

```bash
# Standard wrk benchmark
wrk -t8 -c256 -d5s --latency http://localhost:3002/json
wrk -t8 -c256 -d5s --latency http://localhost:3002/plaintext

# Quick benchmark (warmup + wrk)
bash run_wrk_quick.sh

# Full multi-framework comparison (asynchttp, nim_express, ultimate-express)
bash run_benchmark.sh

# Post-merge regression test
make post-merge-bench

# Flamegraph profiling
make profile-flamegraph

# WebSocket conformance (requires Docker)
make conformance-ws

# HTTP conformance
make conformance-http
```

### Benchmark ports
| Binary | Port |
|--------|------|
| bench_asynchttp (stdlib baseline) | 3001 |
| bench_nim_express (main) | 3002 |
| bench_ultimate_express.js (Node.js) | 3003 |
| ws_echo_server | 3100 |

## Compiler Flags

The Makefile applies these automatically:
- `--mm:arc` — ARC memory management (no GC pauses)
- `-d:release -d:danger --opt:speed` — full optimization
- `-flto=thin -march=native -mtune=native` — LTO + CPU-specific codegen
- PGO auto-detected: if `.pgo-data/` has profiles, `-fprofile-use` is added

## Key Benchmark Files

- `bench_nim_express.nim` — Single-process baseline (port 3002, `/json` + `/plaintext`)
- `bench_nim_express_cluster.nim` — Multi-process with `runCluster()` + SO_REUSEPORT
- `bench_nim_express_threaded.nim` — Multi-threaded with `runThreaded()` (Linux only)
- `bench_nim_express_bigjson.nim` — Large nested JSON payload stress test
- `bench_nim_express_multiport.nim` — Multiple ports for nginx LB on macOS
- `bench_ultimate_express.js` — Node.js comparison (`npm install` first)

## Performance-Critical Code Paths

When profiling or optimizing, these are the hot paths (in order of CPU time):

1. **`http.nim:onSocketData`** — Entry point for all socket I/O. Contains macOS maintenance, overload checks, HTTP parsing, and request dispatch.
2. **`http.nim:flushPendingResponses`** — Response write path. Contains write budget, hook callbacks, writev coalescing.
3. **`app.nim:setupHandlers` closure** — Request dispatch. Routes to sync fast path or middleware chain.
4. **`http.nim:setSocketTimeoutPhase`** — Called up to 5x per request for timeout tracking.
5. **`app.nim:buildFallbackCorrelationId`** — Per-request correlation ID (1 syscall + string allocs).

### Performance tuning flags on ExpressApp
```nim
app.server.options.minimalHeaderParsing = true  # Skip non-essential header parsing
app.generateCorrelationIds = false              # Skip correlation ID generation
app.server.fairnessEnabled = false              # Skip dispatch budget checks
# overloadControlEnabled auto-detected from options
```

## Profiling

```bash
# macOS sample profiler + flamegraph
make profile-flamegraph

# Manual profiling
./bench_nim_express &
PID=$!
sample $PID 8 -f /tmp/profile.txt
# Convert to flamegraph with stackcollapse-sample.awk + flamegraph.pl
```

## Node.js Comparison Setup

```bash
cd benchmark
npm install          # Installs ultimate-express
node bench_ultimate_express.js  # Port 3003
```
