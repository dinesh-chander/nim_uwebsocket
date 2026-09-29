# Linux WebSocket Scaling Path (Production)

This project is optimized first for single-process correctness and hot-path throughput.  
For higher sustained websocket throughput on Linux, scale out with multi-process workers and keep each worker single event-loop where possible.

## 1) Process topology

- Use one listener process per physical core group or NUMA node.
- Prefer `runCluster` / multi-process mode over heavy in-process threading for websocket fanout workloads.
- Keep worker count near physical cores (start with `nproc`, then tune down if CPU cache misses increase).

## 2) Port and balancing model

- Prefer one port with Linux `SO_REUSEPORT` workers when behavior is stable on your kernel.
- If reuseport distribution is uneven, front with nginx/haproxy and shard across worker ports.
- Keep websocket stickiness (hash by client tuple/cookie) when using pub/sub topics to reduce cross-worker rebroadcast work.

## 3) Worker launch pattern

- Start each worker with explicit CPU affinity (`taskset`) when possible.
- Pin workers to avoid core migration under sustained load.
- Keep GC/memory allocator settings identical across workers for repeatable behavior.

Example shape:

```bash
# Example only - adapt paths/binary/args
taskset -c 0 ./bin/ws_server --port=3000 &
taskset -c 1 ./bin/ws_server --port=3000 &
taskset -c 2 ./bin/ws_server --port=3000 &
taskset -c 3 ./bin/ws_server --port=3000 &
wait
```

## 4) Operational checks

- Validate steady-state messages/sec at 1m and 5m windows.
- Capture p50/p95/p99 send latency and queue depth under load.
- Track backpressure drops/high-water events per worker.
- Confirm graceful close behavior and no frame truncation during rolling restarts.

## 5) Compliance guardrails

- Do not bypass websocket framing/masking/close semantics for speed.
- Keep HTTP upgrade validation strict before switching protocols.
- Keep backpressure behavior deterministic (drop/close policy explicit).
