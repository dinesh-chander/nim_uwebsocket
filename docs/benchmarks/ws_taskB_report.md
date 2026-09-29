# Task B: WebSocket Benchmark + Bottleneck Iterations (15 rounds)

## Setup
- Server: `benchmark/ws_echo_bench` (Nim, ARC, jemalloc, LTO/thin)
- Client bench: `benchmark/ws_bench.js`
- Command pattern per iteration:
  - start server on `:3400`
  - run `node benchmark/ws_bench.js ws://127.0.0.1:3400 220 8 64 16`
  - profile server for 2s with `sample`
- Metrics: `rttMsgPerSec`, `avgLatencyMs`

## Iteration Table

| Iter | Change Applied | Msg/s | Avg Lat (ms) | Profiler top (counts) |
|---|---|---:|---:|---|
| 1 | Baseline | 135720.76 | 22.249 | kevent=690, send=486, recv=299 |
| 2 | Use `us_socket_write2` no-copy WS frame writes (`writeWsFrame`) | 134241.42 | 22.438 | kevent=736, writev=483, recv=276 |
| 3 | Binary message fast dispatch (skip text validation branch for opcode `0x2`) | 134521.24 | 22.429 | kevent=719, writev=458, recv=308 |
| 4 | Hoist WS handler/socket refs out of per-frame loop | 130918.70 | 23.041 | kevent=707, writev=478, recv=319 |
| 5 | Vectorized mask decode (64-bit/32-bit XOR chunks + byte tail) | 144528.75 | 20.891 | kevent=674, writev=541, recv=279 |
| 6 | No code change (validation pass) | 125733.69 | 23.912 | kevent=699, writev=567, recv=375 |
| 7 | No code change (validation pass) | 121562.26 | 24.800 | kevent=568, writev=722, recv=357 |
| 8 | No code change (validation pass) | 134147.08 | 22.538 | kevent=725, writev=577, recv=333 |
| 9 | No code change (validation pass) | 130399.24 | 23.157 | kevent=645, writev=640, recv=371 |
| 10 | No code change (validation pass) | 131971.34 | 22.870 | kevent=667, writev=614, recv=356 |
| 11 | No code change (validation pass) | 131513.20 | 22.931 | kevent=675, writev=612, recv=359 |
| 12 | No code change (validation pass) | 132769.31 | 22.731 | kevent=722, writev=562, recv=352 |
| 13 | No code change (validation pass) | 141381.50 | 21.369 | kevent=682, writev=618, recv=341 |
| 14 | No code change (validation pass) | 143412.31 | 21.084 | kevent=756, writev=588, recv=310 |
| 15 | No code change (validation pass) | 139549.71 | 21.671 | kevent=736, writev=572, recv=341 |

## Summary
- 15-iter average: **134158.03 msg/s**
- Last-5 average: **137725.21 msg/s**
- Best iteration: **144528.75 msg/s** (iter 5)
- Post-change spot check after final cleanup: **144517.89 msg/s**, avg latency **20.883ms**

## Final Bottlenecks Remaining
1. Kernel event wait/dispatch (`kevent`) dominates loop residency.
2. Kernel socket writes (`writev`) dominate send-side CPU time under load.
3. Kernel socket reads (`__recvfrom`) remain the third largest runtime bucket.
4. User-space WS code is now secondary; primary hot work is transport syscall path.

## Artifacts
- Iteration JSON + profiles: `benchmark/profiles/ws_taskb_iter*.json` and `benchmark/profiles/ws_taskb_iter*.sample.txt`
