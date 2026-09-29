# WebSocket Connection Scaling Guide

This guide covers how to test and scale the nim_uwebsocket framework from 1K
to 500K+ concurrent WebSocket connections. It documents the benchmark tooling
in `benchmark/`, OS-level tuning, server configuration, and step-by-step test
scenarios.

For **empirical load-testing lessons** (`websocketload` per-thread caps, multi-process fan-out, ramp vs. thundering herd, script pointers), see **[`WEBSOCKET_LOAD_SCALABILITY_LEARNINGS.md`](./WEBSOCKET_LOAD_SCALABILITY_LEARNINGS.md)**.

---

## Overview

nim_uwebsocket is a single-thread, event-loop-based WebSocket server built on
top of uSockets (epoll on Linux, kqueue on macOS). Key scaling properties:

- **Default limit:** 100,000 concurrent connections (`DefaultMaxConnections` in
  `http.nim`). Configurable at runtime via `maxConnections` or
  `NIM_EXPRESS_MAX_CONNECTIONS`.
- **Proven ceiling:** 131,072 connections in the `websocket_broadcast` example;
  the scale sweep driver (`run_ws_connection_scale.sh`) steps up to 500K on
  Linux.
- **Architecture:** Single event loop per process. For multi-core scaling, use
  `runCluster` (multi-process with SO_REUSEPORT on Linux) or front multiple
  single-process instances with nginx/haproxy.
- **Backpressure:** Per-socket backpressure with configurable high-water mark,
  drop policy, and close-on-limit. Server-side metrics expose
  `backpressure_drops` and `backpressure_high_water_events`.
- **Connection pool:** Pre-warmed context pools (`prewarmContextPools`) reduce
  allocation overhead during connection bursts.

---

## Prerequisites

### Build toolchain

| Dependency | Purpose |
|---|---|
| Nim >= 2.2 | Compiler for server binaries |
| Make | Build system (`make bench`, `make ws-random-object-bench`) |
| uSockets.a | Statically linked C networking library (built in `nim_usockets/usockets/`) |
| jemalloc (optional) | Allocation-optimized builds (`-ljemalloc`) |
| CoreFoundation (macOS) | Required link framework on macOS |

### Client tooling

| Tool | Purpose | Install |
|---|---|---|
| Node.js >= 18 | Runs JS-based connection clients | `brew install node` / distro package |
| `ws` npm module | WebSocket client library for Node.js | `cd benchmark && npm install ws` |
| tcpkali | Raw TCP/WebSocket load generator | `brew install tcpkali` / build from source |
| wrk | HTTP throughput benchmark | `brew install wrk` |
| curl | Health checks and `/stats` endpoint | Pre-installed |

### OS-level tuning

#### Linux

Run `benchmark/linux_ws_tuning.sh --apply` as root, or apply manually:

```bash
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.core.netdev_max_backlog=250000
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sudo sysctl -w net.ipv4.ip_local_port_range="10240 65535"
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
sudo sysctl -w net.ipv4.tcp_fin_timeout=15
sudo sysctl -w net.ipv4.tcp_mtu_probing=1
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432"
sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432"

ulimit -n 1048576
```

Persist these by writing them into `/etc/sysctl.d/99-websocket.conf` and
setting `nofile` in `/etc/security/limits.conf`:

```
*  soft  nofile  1048576
*  hard  nofile  1048576
```

#### macOS

macOS has tighter per-process FD limits and no effective SO_REUSEPORT
load-balancing. Apply these before testing:

```bash
sudo sysctl -w kern.ipc.somaxconn=8192
sudo sysctl -w kern.ipc.maxsockbuf=8388608
sudo sysctl -w kern.maxfiles=1048576
sudo sysctl -w kern.maxfilesperproc=524288

ulimit -n 524288
```

Set up loopback aliases for multi-IP source testing (needed to exceed ~16K
ephemeral ports per source IP):

```bash
for i in $(seq 2 32); do
  sudo ifconfig lo0 alias "127.0.0.$i" up
done
```

---

## Server Configuration

### maxConnections

The server-side connection limit is set in code or via environment variable:

```nim
app.server.options.maxConnections = 120000
```

```bash
NIM_EXPRESS_MAX_CONNECTIONS=200000 ./benchmark/ws_conntest_server
```

The default is 100,000. The `websocket_broadcast` example uses 131,072.

### WebSocket keepalive and idle timeout

| Option | Default | Env Var | Description |
|---|---|---|---|
| `wsKeepaliveInterval` | 30,000 ms | `NIM_EXPRESS_WS_KEEPALIVE_INTERVAL` | Server-to-client ping interval |
| `wsIdleTimeoutSeconds` | 60 s | `NIM_EXPRESS_WS_IDLE_TIMEOUT` | Close idle connections after this period |
| `wsResetIdleTimeoutOnSend` | false | — | Reset idle timer on every outbound frame |
| `connectionTimeout` | 120 s | `NIM_EXPRESS_CONNECTION_TIMEOUT` | Overall connection lifetime limit (0 = disabled) |

For connection scaling tests, disable timeouts to prevent the server from
closing idle test connections:

```bash
NIM_EXPRESS_WS_IDLE_TIMEOUT=0 \
NIM_EXPRESS_CONNECTION_TIMEOUT=0 \
./benchmark/ws_conntest_server
```

### Socket buffer tuning

```nim
app.server.options.socketSendBufferBytes = 256 * 1024
app.server.options.socketRecvBufferBytes = 64 * 1024
app.server.options.socketNoDelay = true
app.server.options.socketKeepAlive = true
app.server.options.socketKeepAliveSeconds = 60
```

For high connection counts with low per-connection throughput, smaller buffers
reduce total memory:

```nim
app.server.options.socketSendBufferBytes = 16 * 1024
app.server.options.socketRecvBufferBytes = 8 * 1024
```

### Backpressure configuration

```nim
app.server.options.wsMaxBackpressure = 32 * 1024 * 1024
app.server.options.wsBackpressureHighWaterBytes = 16 * 1024 * 1024
app.server.options.wsBackpressureHighWaterAction = bhwDropNewest
app.server.options.wsCloseOnBackpressureLimit = true
```

The server exposes `backpressure_drops` and `backpressure_high_water_events` via
the `/metrics` endpoint. Monitor these during scale tests to detect when the
server is shedding load.

### Multi-process scaling (Linux)

```nim
runCluster(createApp, port, numWorkers = 4)
```

With `SO_REUSEPORT` on Linux, the kernel distributes incoming connections across
workers. Pin workers to cores for best performance:

```bash
taskset -c 0 ./bin/ws_server --port=3000 &
taskset -c 1 ./bin/ws_server --port=3000 &
taskset -c 2 ./bin/ws_server --port=3000 &
taskset -c 3 ./bin/ws_server --port=3000 &
```

On macOS, SO_REUSEPORT does not load-balance. Use multiple ports with
nginx/haproxy instead.

---

## Test Scenarios

### Scenario 1: Quick 1K Connection Smoke Test

Validates basic connectivity with minimal OS tuning.

**Server:**

```bash
make ws-random-object-bench
NIM_EXPRESS_WS_IDLE_TIMEOUT=0 \
NIM_EXPRESS_CONNECTION_TIMEOUT=0 \
PORT=3100 ./benchmark/ws_random_object_bench
```

Or use the simple connection test server:

```bash
nim c -d:release --mm:arc \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src \
  --path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
  --path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
  --path:vendor/jsony/src --path:vendor/checksums \
  --passL:"nim_usockets/usockets/uSockets.a -lpthread -ldl" \
  -o:benchmark/ws_conntest_server benchmark/ws_conntest_server.nim

NIM_EXPRESS_WS_IDLE_TIMEOUT=0 \
NIM_EXPRESS_CONNECTION_TIMEOUT=0 \
./benchmark/ws_conntest_server
```

**Client:**

```bash
cd benchmark && npm install ws

node ws_100k_client.js 127.0.0.1 3100 1000 500
```

Arguments: `<dest_ip> <port> <target_conns> <connect_rate_per_sec> [src_ip]`

**Verify:**

```bash
curl http://127.0.0.1:3100/stats
```

Expected: `current=1000 peak=1000 totalOpen=1000 totalClose=0`

### Scenario 2: 10K Connection Test

Requires `ulimit -n` >= 10500.

**Server (same as above).**

**Client (single process):**

```bash
node benchmark/ws_100k_client.js 127.0.0.1 3100 10000 2000
```

**Client (tcpkali — connect only, no message exchange):**

```bash
tcpkali --websocket -c 10000 --connect-rate 2000 -T 30s 127.0.0.1:3100
```

**Monitor during test:**

```bash
watch -n 2 'curl -s http://127.0.0.1:3100/stats'
```

### Scenario 3: 100K Connection Test

Each source IP can use ~55K ephemeral ports (range 10240–65535). For 100K
connections, use multiple loopback addresses.

**Step 1: Set up loopback aliases (macOS)**

```bash
for i in 2 3 4 5; do
  sudo ifconfig lo0 alias "127.0.0.$i" up
done
```

Linux already supports all 127.x.x.x addresses without aliases.

**Step 2: Start server**

Build and run `ws_conntest_server` or `ws_broadcast_server` with
`maxConnections >= 120000`.

```bash
NIM_EXPRESS_MAX_CONNECTIONS=120000 \
NIM_EXPRESS_WS_IDLE_TIMEOUT=0 \
NIM_EXPRESS_CONNECTION_TIMEOUT=0 \
PORT=3100 ./benchmark/ws_conntest_server
```

**Step 3: Run the orchestrated test**

`ws_100k_test.sh` launches 4 client processes, each opening 25K connections
from different source IPs to different destination IPs:

```bash
bash benchmark/ws_100k_test.sh 3100
```

This script:
1. Starts 4 Node.js clients (src 127.0.0.1-4 → dst 127.0.0.1-4)
2. Waits for each to ramp (25K conns at 3000/sec ≈ 8s per client)
3. Polls `/stats` every 10s for 60s
4. Reports per-client and aggregate connection counts, errors, and memory

**Alternative: Cross-wired multi-IP test**

`run_100k_test.sh` uses a cross-wired topology (client src and dst on
different IPs) to maximize ephemeral port utilization:

```bash
bash benchmark/run_100k_test.sh 3200 100000 60
```

Arguments: `<port> <total_connections> <hold_seconds>`

**Step 4: Monitor**

```bash
curl -s http://127.0.0.1:3100/stats

lsof -p <server_pid> | wc -l

ps -o pid,rss,%cpu,%mem -p <server_pid>
```

### Scenario 4: Connection Scale Sweep (10K → 500K)

`run_ws_connection_scale.sh` is the most comprehensive test. It:
1. Cold-builds the server binary (`ws_random_object_bench`)
2. Launches 8 server instances on ports 3412–3419
3. Steps from `START_CONNECTIONS` to `MAX_CONNECTIONS` in increments
4. At each step, connects N clients, waits for all to open (or timeout), runs
   a steady-state measurement window, then tears down
5. Collects per-step metrics into a CSV and generates a markdown summary
6. Stops at the first step where a bottleneck is detected

**Linux (full range):**

```bash
cd /path/to/nim_uwebsocket
bash benchmark/run_ws_connection_scale.sh
```

Default on Linux: 10K → 500K in 10K steps.

**macOS (auto-capped):**

```bash
SETUP_LOOPBACK=1 bash benchmark/run_ws_connection_scale.sh
```

macOS auto-detects `kern.maxfilesperproc` and caps `MAX_CONNECTIONS`
accordingly. With `SETUP_LOOPBACK=1`, it creates loopback aliases 127.0.0.2-32
for additional source addresses.

**Custom parameters:**

```bash
START_CONNECTIONS=5000 \
STEP_CONNECTIONS=5000 \
MAX_CONNECTIONS=100000 \
DURATION_SEC=30 \
OPEN_TIMEOUT_SEC=120 \
CLIENT_WORKERS=4 \
SERVER_PORTS=3412,3413,3414,3415 \
bash benchmark/run_ws_connection_scale.sh
```

**Reading results:**

Results are written to `benchmark/reports/ws_connection_scale_<timestamp>/`:

| File | Contents |
|---|---|
| `results.csv` | Per-step data: clients, opened, open_ratio, msg/s total, msg/s per conn, errors, backpressure drops, high-water events, bottleneck |
| `summary.md` | Rendered markdown table with config and outcome |
| `run_<N>_bench.json` | Raw JSON output from each step's client run |
| `server_<port>.log` | Per-server stdout/stderr |

The CSV columns:

```
clients,opened,open_ratio,messages_per_sec_total,messages_per_sec_per_open_conn,errors,backpressure_drops,backpressure_high_water_events,bottleneck
```

Bottleneck reasons:

| Value | Meaning |
|---|---|
| `open_shortfall` | Not all requested connections were opened before timeout |
| `client_errors` | Client-side errors during the run |
| `server_backpressure_drops` | Server dropped messages due to backpressure |
| `server_backpressure_high_water` | Server triggered high-water backpressure events |
| `message_rate_drop` | Per-connection message rate fell below 0.10 msg/s |

### Scenario 5: Message Throughput Under Load

These tests measure how fast the server can process messages, not just hold
connections.

**tcpkali (raw ingest rate — no echo expected):**

```bash
NIM_EXPRESS_WS_IDLE_TIMEOUT=0 \
NIM_EXPRESS_CONNECTION_TIMEOUT=0 \
PORT=3400 ./benchmark/ws_echo_bench &
sleep 2

tcpkali --websocket -c 200 --connect-rate 5000 \
  -m 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
  -T 15s 127.0.0.1:3400
```

Reference results (Apple M1 Pro, single thread):

| Connections | Msg/sec ↑ | Bandwidth ↑ |
|---|---|---|
| 50 | 500K | 5.7 Gbps |
| 100 | 798K | 9.1 Gbps |
| 200 | 1.08M | 12.3 Gbps |

**ws_bench.js (round-trip latency + throughput):**

```bash
cd benchmark && npm install ws

node ws_bench.js ws://127.0.0.1:3400 200 15 64 16
```

Arguments: `<url> <clients> <duration_sec> <payload_bytes> <max_inflight>`

Output is JSON with `rttMsgPerSec`, `avgLatencyMs`, `p50LatencyMs`,
`p95LatencyMs`, `p99LatencyMs`, and `maxLatencyMs`.

Reference: 100 clients × 16 inflight → 224K round-trip msg/sec.

---

## Monitoring During Tests

### HTTP endpoints

| Endpoint | Server | Response |
|---|---|---|
| `/stats` | `ws_conntest_server` | `current=N peak=N totalOpen=N totalClose=N` |
| `/metrics` | `websocket_broadcast`, `ws_random_object_bench` | JSON with pid, uptime, active websockets/connections, total opened/closed, messages received/sent/dropped, overload rejects, backpressure drops/high-water events, messages/sec |
| `/health` | All benchmark servers | `{"status":"ok"}` or `ok` |
| `/` | `websocket_broadcast` | JSON with service name, websocket count, connection count |

Example polling loop:

```bash
while true; do
  echo "$(date +%T) $(curl -s http://127.0.0.1:3100/stats)"
  sleep 5
done
```

### OS-level monitoring

**Open file descriptors (server process):**

```bash
lsof -p <pid> | wc -l

ls /proc/<pid>/fd | wc -l      # Linux only
```

**Socket state distribution:**

```bash
ss -s                           # Linux: summary
ss -tn state established | wc -l

netstat -an | grep ESTABLISHED | wc -l   # macOS
```

**Memory and CPU:**

```bash
ps -o pid,rss,%cpu,%mem -p <pid>

top -pid <pid>                  # macOS live
```

**Ephemeral port usage:**

```bash
ss -tn | awk '{print $4}' | cut -d: -f2 | sort -un | wc -l   # Linux

netstat -an -p tcp | grep ESTABLISHED | wc -l                 # macOS
```

---

## Troubleshooting

### EMFILE — Too many open files

The process has hit its file descriptor limit.

```bash
ulimit -n 1048576               # raise for current shell

# Permanent (Linux): /etc/security/limits.conf
*  soft  nofile  1048576
*  hard  nofile  1048576

# macOS: also need
sudo sysctl -w kern.maxfilesperproc=524288
sudo sysctl -w kern.maxfiles=1048576
```

### ECONNRESET / ECONNREFUSED during ramp

- **Listen backlog too small:** Raise `somaxconn`:
  - Linux: `sudo sysctl -w net.core.somaxconn=65535`
  - macOS: `sudo sysctl -w kern.ipc.somaxconn=8192`
- **Server maxConnections reached:** Increase `maxConnections` in server config.
- **Client connecting too fast:** Lower `CONNECT_RATE` or `CONNECT_BATCH`.

### ENOMEM — Out of memory

Each WebSocket connection uses memory for:
- Socket buffers (send + recv): 16–320 KB per socket depending on config
- WebSocket state: ~200 bytes
- Application-level state

At 100K connections with 256KB send + 64KB recv buffers, memory usage is ~30 GB.
For high connection counts, reduce buffer sizes:

```nim
app.server.options.socketSendBufferBytes = 16 * 1024
app.server.options.socketRecvBufferBytes = 8 * 1024
```

### macOS-specific issues

**Loopback aliases not persisting:**
macOS clears aliases on reboot. Re-run:
```bash
for i in $(seq 2 32); do
  sudo ifconfig lo0 alias "127.0.0.$i" up
done
```

**kern.maxfiles / kern.maxfilesperproc too low:**
Default `kern.maxfilesperproc` is 10240. The scale benchmark auto-detects this
and caps `MAX_CONNECTIONS` accordingly. Raise it before testing:
```bash
sudo sysctl -w kern.maxfilesperproc=524288
```

**SO_REUSEPORT not load-balancing:**
macOS allows SO_REUSEPORT binding but does not distribute connections evenly.
Use multiple ports + nginx/haproxy for multi-process scaling on macOS.

### Linux-specific issues

**Port exhaustion:**
Each (src_ip, src_port, dst_ip, dst_port) tuple must be unique. With a single
source IP, the usable ephemeral port range (~55K ports) limits you to ~55K
connections per destination IP+port.

Solutions:
- Use multiple loopback addresses (127.0.0.1–32 × 55K = ~1.7M tuples)
- Widen port range: `echo "2000 65000" | sudo tee /proc/sys/net/ipv4/ip_local_port_range`
- Use multiple server ports (`run_ws_connection_scale.sh` uses 8 ports)

**nf_conntrack table full:**
If conntrack is enabled, it can fill at high connection counts:
```bash
sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
```
Or disable conntrack for loopback traffic:
```bash
sudo iptables -t raw -A PREROUTING -i lo -j NOTRACK
sudo iptables -t raw -A OUTPUT -o lo -j NOTRACK
```

**TCP TIME_WAIT accumulation:**
After tearing down many connections, TIME_WAIT sockets consume port space:
```bash
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
sudo sysctl -w net.ipv4.tcp_fin_timeout=15
```

---

## Expected Results

Reference numbers from `BENCHMARK_RESULTS.md` (Apple M1 Pro, single-thread,
kqueue, jemalloc):

### HTTP baseline

| Endpoint | Connections | Req/sec |
|---|---|---|
| `/plaintext` (13 B) | 256 | 90,744 |
| `/json` (~75 B) | 64 | 90,465 |
| pipelined (16/batch) | 64 | 622,020 |

### WebSocket throughput

| Metric | Result |
|---|---|
| tcpkali ingest (200 conns, 64 B) | **1.08M msg/sec** |
| Round-trip echo (100 clients, 64 B) | **224K msg/sec** |
| WS frame build | 62.8M ops/sec |
| WS unmask | 25–26 GB/sec |

### Connection count expectations

| Target | Platform | Notes |
|---|---|---|
| 1K | Any | Works with default OS settings |
| 10K | Any | Raise `ulimit -n` to 10500+ |
| 100K | macOS/Linux | Requires loopback aliases, raised FD limits, somaxconn tuning |
| 200K+ | Linux | Multiple server ports, raised sysctl limits, `runCluster` |
| 500K+ | Linux | 8+ server ports, 32 loopback addrs, sysctl fully tuned, small socket buffers |

Memory estimate at scale (with 16KB send + 8KB recv buffers):

| Connections | Approx server RSS |
|---|---|
| 10K | ~300 MB |
| 100K | ~3 GB |
| 500K | ~15 GB |

These are rough estimates. Actual memory depends on message traffic, backpressure
state, and application-level per-connection data.

---

## Benchmark Tool Reference

| Tool | File | Purpose |
|---|---|---|
| `ws_conntest_server` | `benchmark/ws_conntest_server.nim` | Minimal WS server with `/stats`, maxConnections=120K |
| `ws_echo_bench` | `benchmark/ws_echo_bench.nim` | Pure echo WS server for throughput testing |
| `websocket_broadcast` | `examples/websocket_broadcast.nim` | Full-featured broadcast server with `/metrics`, pub/sub, compression |
| `ws_100k_client.js` | `benchmark/ws_100k_client.js` | Raw TCP WS client, configurable target/rate/source IP |
| `ws_100k_test.sh` | `benchmark/ws_100k_test.sh` | 4-process orchestrator for 100K test |
| `run_100k_test.sh` | `benchmark/run_100k_test.sh` | Cross-wired multi-IP 100K test |
| `ws_connection_scale_bench.js` | `benchmark/ws_connection_scale_bench.js` | Multi-URL scale client with message rate measurement, cluster mode |
| `run_ws_connection_scale.sh` | `benchmark/run_ws_connection_scale.sh` | Full driver: cold build, multi-port, stepped sweep with CSV/summary output |
| `ws_bench.js` | `benchmark/ws_bench.js` | RTT echo benchmark with latency percentiles |
| `linux_ws_tuning.sh` | `benchmark/linux_ws_tuning.sh` | Linux sysctl tuning (dry-run by default) |
| `linux_ws_scaling.md` | `benchmark/linux_ws_scaling.md` | Production scaling strategy doc |

---

## Quick-Start Cheat Sheet

```bash
cd /path/to/nim_uwebsocket

# 1. Build
make usockets-kqueue   # macOS
make usockets          # Linux (auto-detect)
make ws-random-object-bench

# 2. Raise limits
ulimit -n 524288

# 3. Quick smoke test (1K connections)
NIM_EXPRESS_WS_IDLE_TIMEOUT=0 PORT=3100 ./benchmark/ws_random_object_bench &
sleep 2
cd benchmark && npm install ws
node ws_100k_client.js 127.0.0.1 3100 1000 500
curl -s http://127.0.0.1:3100/stats
kill %1

# 4. Full 100K test (needs loopback aliases on macOS)
for i in 2 3 4 5; do sudo ifconfig lo0 alias "127.0.0.$i" up; done
bash benchmark/ws_100k_test.sh 3100

# 5. Connection scale sweep
SETUP_LOOPBACK=1 bash benchmark/run_ws_connection_scale.sh
# Results in benchmark/reports/ws_connection_scale_<timestamp>/
```
