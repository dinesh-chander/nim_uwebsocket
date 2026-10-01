# Performance Baseline — Linux (2026-10-01)

Hardware: Intel Core Ultra 7 265K (20 cores), kernel 7.0.0-34-generic, 91 GB RAM.
Build: `make bench` flags (`-d:release -d:danger --opt:speed --mm:arc`), uSockets epoll backend.
Protocol: `ab_run.sh` — 3 alternating passes per endpoint, best pass kept, wrk 8 threads / 256 conns / 5 s.

## Throughput baseline (best pass)

| workload | /json | /plaintext | /static (16 KB) |
|---|---|---|---|
| single process | **318,437** r/s (p99 1.49 ms) | **334,581** r/s (p99 1.45 ms) | **172,238** r/s (p99 2.82 ms) |
| cluster 4 workers (SO_REUSEPORT) | **1,165,716** r/s (p99 440 µs) | **1,249,188** r/s (p99 457 µs) | **1,090,286** r/s (p99 455 µs) |

Cluster scaling factor (JSON): 3.66× over single.

WebSocket echo roundtrip (node `ws` client, 200 conns, 32 B payload, 10 s):

| pass | msg/s |
|---|---|
| 1 | 278,321 |
| 2 | 280,839 |
| 3 (best) | **284,997** |

## Profiling (gprof, 15 s load each; perf blocked: paranoid=4 + seccomp, no sudo)

### /json single (4.39 M req sampled)

| % self | function | calls/req | note |
|---|---|---|---|
| 9.6 | `onSocketDataImpl` | 1 | C→Nim callback entry |
| 7.2 | `remoteIp` | 1 | **per-request remote-IP formatting** |
| 7.2 | `nimCopyMem` | 4 | string copies |
| 4.8 | `parseHttpRequest` | 2 | request-line + header parse |
| 2.4 | `setLengthStrV2` + `rawAlloc` | 7 alloc/req | allocation churn |
| 2.4 | `setSocketTimeoutPhase` | 4 | timeout phase bookkeeping |
| 2.4 | `maybeCompressBody` | 1 | per-request compression check |
| 1.6 | `us_socket_write2_unchecked` | 1 | final write |
| 1.6 | `setLen__times` (getTime) | 2 | per-request timestamp |

### /static 16 KB single (2.54 M req sampled)

| % self | function | note |
|---|---|---|
| 8.2 | `nimCopyMem` | body copies (~4/req) |
| 5.5 | `rawAlloc` | **16 KB buffer re-allocated per request** |
| 3.6 | `freeBigChunk` + 2.7 `getBigChunk` | big-chunk allocator churn |
| 2.7 | `insertFastMapStringRaw` | **per-request header map build** |
| 2.7 | `remoteIp` | same as JSON |
| 1.8 | `flushSendBuffer` | buffer flush |

### WS echo single (4.24 M msgs sampled)

| % self | function | note |
|---|---|---|
| 13.0 | `setLen__times` (getTime) | **2× per message — time formatting on hot path** |
| 13.0 | `handleWebSocketData` | frame handling |
| 6.5 | `onSocketDataImpl` | callback entry |
| 4.4 | `eqdestroy` (http) | per-message string destroy |
| 4.4 | `writeWsFrame` | frame serialization |
| 2.2 | `newStringUninit` + `rawAlloc` | per-message payload string alloc |
| 2.2 | `refreshWsIdleTimeout` | per-message timer refresh |
| 15.2 | `us_loop_run` | (C loop, flat) |

## Identified levers (candidate list for later tasks)

1. **static: zero-copy body** — no per-request 16 KB alloc/copy; prebuilt header block;
   sendfile or direct writev of a constant buffer (kernel-eventloop task).
2. **remoteIp on hot path** (7.2% JSON) — per-request IP string formatting; cache/lazy it.
3. **getTime() per request/message** — 2× in JSON path, 2× in WS path; drop or reuse.
4. **setSocketTimeoutPhase ×4/req** — timeout bookkeeping cost; batch or drop in fast path.
5. **WS per-message string alloc/destroy** — reuse payload buffer for small frames.
6. **per-request header fastmap insert (static)** — prebuild full header block once.
7. **cluster sweep** — 1/2/4/8 workers; TCP_NODELAY/accept-queue tuning.
8. **io_uring vs epoll** A/B.

Raw profiles: `gprof_json.txt`, `gprof_static.txt`, `gprof_ws.txt`.
