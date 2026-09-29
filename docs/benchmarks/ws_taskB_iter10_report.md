# WebSocket Optimization Iterations (10 more rounds)

## Setup
- Server: `benchmark/ws_echo_bench`
- Client: `node benchmark/ws_bench.js ws://127.0.0.1:3400 220 8 64 16`
- Platform: macOS (kqueue)

## Iteration Table

| Iter | Change | Msg/s | Avg Latency (ms) | Result |
|---|---|---:|---:|---|
| 1 | Baseline | 133554.69 | 22.594 | baseline |
| 2 | Disable WS pre-append compaction in `onSocketData` | 143330.54 | 21.050 | improved |
| 3 | No code change (validation) | 132767.57 | 22.714 | neutral |
| 4 | No code change + profile | 132751.19 | 22.766 | neutral |
| 5 | Short-header specialized `writeWsFrame`/`writeFrameNoCopy` | 126083.02 | 23.905 | regression |
| 6 | No code change (regression confirmation) | 121103.79 | 24.930 | regression confirmed |
| 7 | Revert iter-5 send specialization | 140637.70 | 21.457 | recovered |
| 8 | No code change | 110900.46 | 27.189 | noisy low run |
| 9 | No code change | 116693.54 | 25.879 | noisy low run |
| 10 | Restart server + profile | 131692.22 | 22.908 | stable-ish |

## Kept changes
- Keep: WS pre-append compaction disabled in `onSocketData` (WebSocket path already compacts in `handleWebSocketData`).
- Keep: Prior decode/unmask improvements from earlier batch.
- Revert: short-header send specialization (iter-5) due consistent regression.

## Aggregates
- Average over all 10: **128951.47 msg/s**
- Median over all 10: **132221.71 msg/s**
- Best run: **143330.54 msg/s** (iter 2)
- Average excluding obvious noisy lows (iter 8/9): **132740.09 msg/s**

## Current bottlenecks (iter10 sample)
Top stacks remain kernel transport:
1. `kevent`
2. `writev`
3. `__recvfrom`

Artifacts:
- Runs: `benchmark/profiles/ws_iter10/iter{1..10}.json`
- Samples: `benchmark/profiles/ws_iter10/iter{1,4,5,10}.sample.txt`
- This report: `benchmark/ws_taskB_iter10_report.md`
