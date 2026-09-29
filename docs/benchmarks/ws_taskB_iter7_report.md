# WebSocket Optimization Iterations (7 rounds)

## Scope
- Target: `benchmark/ws_echo_bench` on macOS
- Client load: `node benchmark/ws_bench.js ws://127.0.0.1:3400 220 8 64 16`
- Focus: keep RFC-correctness and improve WS hot path without introducing brittle app-specific behavior.

## Iteration Results

| Iter | Change | Msg/s | Avg Latency (ms) | Notes |
|---|---|---:|---:|---|
| 1 | Baseline + profile capture | 115490.91 | 25.972 | Low/noisy run under profiling overhead |
| 2 | Decode refactor: out-params instead of tuple return | 134116.83 | 22.519 | Reduced per-frame decode churn |
| 3 | Short-frame fast path (`payloadLen < 126`) + shared unmask helper | 135561.51 | 22.283 | Best early gain for 64B frame workload |
| 4 | Profile-only validation pass | 132077.95 | 22.841 | Kernel still dominant |
| 5 | WS-specific pre-append compaction threshold in `onSocketData` | 134741.74 | 22.406 | Reduced unnecessary memmove pressure |
| 6 | Attempted FIN data-frame fast dispatch branch | 132763.72 | 22.725 | Regression observed |
| 7 | Reverted iter-6 regression + profile validation | 136131.22 | 22.176 | Best run in this 7-iter set |

## Kept Code Changes
- `decodeWebSocketFrame` now uses out-params and status code instead of tuple construction.
- Added `unmaskWebSocketPayload` helper and short-frame fast path for masked client frames.
- `onSocketData` now uses `WsInputCompactThreshold` for upgraded WebSocket sockets before append compaction.
- Reverted iter-6 branch optimization due measurable regression.

## Current Bottlenecks (post-iter7)
From profile samples, top hotspots remain kernel transport path:
1. `kevent`
2. `writev`
3. `__recvfrom`

User-space WS parser/dispatcher no longer dominates runtime in this workload.

## Artifacts
- JSON runs: `benchmark/profiles/ws_iter7/iter{1..7}.json`
- Profiles: `benchmark/profiles/ws_iter7/iter1.sample.txt`, `iter4.sample.txt`, `iter7.sample.txt`
- This report: `benchmark/ws_taskB_iter7_report.md`
