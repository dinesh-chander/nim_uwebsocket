# WebSocket load-testing scalability learnings

Operational notes from stress-testing **`websocketload`**, **`ws_echo_bench`**, and **`runThreaded`** stacks on Linux (io_uring builds, loopback aliases, high `ulimit`). For full OS/tuning recipes, see **[`WEBSOCKET_CONNECTION_SCALING.md`](./WEBSOCKET_CONNECTION_SCALING.md)**.

---

## 1. Client: one `websocketload` process is not infinite

`nim_websocketcli/websocketload` splits **`-c`** across **`-t`** worker threads (one uSockets/io_uring or epoll loop per thread).

- **`MaxConnectionsPerWorkerThread`** (default **15000**) caps how many sockets the **busiest** thread may own. Distribution is **`(n div t) + (n mod t)`** on thread 0 (remainder).
- **`MaxWorkerThreads`** (default **24**) caps **`-t`**.

**Implication:** a **single process** cannot honestly target **`c > 15000 × 24`** (~360k) without changing those constants—`websocketload` will **widen `-t`** only up to the cap, then **refuse** the config.

**Examples**

| Target | Single process? | Notes |
|--------|-----------------|--------|
| ~100k | Yes (e.g. `-t 14`…`24`) | Hottest thread must stay ≤ 15k. |
| ~200k | Yes with `-t 24` | `worstThread0Load(200000, 24) ≈ 8341`. |
| ~400k | **No** (2× 200k typical) | `worstThread0Load(400000, 24) > 15000` → use **multiple processes** or raise caps in source. |

---

## 2. “Too many connections too fast” → connect errors

**Observation:** Starting **several large `websocketload` processes close together** (e.g. two × 200k with only a short stagger) can produce **many `Connect Errors` / partial `Connected` counts**, even when the **same totals succeed** if the arrival rate is smoothed.

**Why (high level):** The path **TCP handshake → accept → HTTP/WebSocket upgrade** is finite. A **thundering herd** can briefly exceed:

- listen / SYN backlogs and related kernel queues,
- CPU time to accept and parse handshakes,
- transient fairness across **SO_REUSEPORT** listeners.

This is **not** “TCP forbids high concurrency”; it is **burst rate vs. sustained capacity**.

**Mitigations that worked in practice**

- **Ramp issuance:** **`--ramp-sec`** spreads bootstrap **`connect()`** calls per worker over wall time (default in `websocketload` is tuned for gentler ramps; **`0`** = fastest legacy pacing).
- **Stagger loaders:** start the **second** big process after a **gap** (e.g. **`LOADER_GAP_SEC`** in **`nim_websocketcli/scripts/run_400k_ws_load.sh`**) so the first wave is mostly established before the next ramp.
- **Parallel script fan-out:** **`ws_parallel_load.sh`**’s **`PARALLEL_FANOUT`** / **`STAGGER_SEC`** / **`BATCH_GAP_SEC`** trade wall-clock speed for stability.
- **Retries:** **`--connect-retries`** + **`--retry-delay-ms`** absorb **transient** refusals/timeouts (not a substitute for sane ramping on huge bursts).

---

## 3. Server: threads, port reuse, and io_uring

- **`runThreaded(createApp, port, n)`** (e.g. **`ws_echo_bench`** with **`THREADS`**) runs **one accept loop per Nim thread**, all on the **same TCP port**, using **SO_REUSEPORT-style** sharing on Linux.
- **io_uring vs epoll** is a **build-time** choice (`USOCKETS_BACKEND=io_uring`, **`-d:LIBUS_USE_IO_URING`**); it is **orthogonal** to “how many threads/processes” you use for accept scaling.
- Under very high connection rates, **more accept threads** (up to what the box can run) can help—empirically **`ws_echo_bench`** was run with **16–24** `THREADS` for large idle-fan-out tests.

---

## 4. OS and localhost client fan-out

For **hundreds of thousands of outbound connections to one `(127.0.0.1, port)`**, Linux needs:

- **`ulimit -n`** in the millions (e.g. **1 048 576**),
- a **wide** **`net.ipv4.ip_local_port_range`**,
- **many loopback source addresses** (`127.0.0.2` …) so ephemeral port space is multiplied,

See **`nim_websocketcli/scripts/ws_scale_linux.sh`** and **`nim_websocketcli/scripts/ws_preflight_500k.sh`** (quick checklist).

---

## 5. Reporting: “Connect Errors” line

Under async connects + retries, the raw internal counter does not always match “slots that never reached OPEN.” The **`websocketload`** summary therefore reconciles the printed **`Connect Errors`** line with **`concurrency − (connected − disconnected)`** so idle soak runs align with **missing successful opens**.

---

## 6. Handy scripts (repo)

| Script | Role |
|--------|------|
| **`nim_websocketcli/scripts/ws_preflight_500k.sh`** | Fail-fast checks before huge localhost fan-out. |
| **`nim_websocketcli/scripts/ws_parallel_load.sh`** | Many **`websocketload`** workers; optional **`WSLOAD_RAMP_SEC`**, **`WSLOAD_CONNECT_RETRIES`**, **`WSLOAD_RETRY_DELAY_MS`**. |
| **`nim_websocketcli/scripts/run_200k_ws_load.sh`** | Single-process ~200k smoke (adjust **`THREADS`** server side). |
| **`nim_websocketcli/scripts/run_400k_ws_load.sh`** | Two × 200k with **`LOADER_GAP_SEC`** / **`DURATION`** for overlap vs. burst trade-offs. |

**Build tip:** **`make websocketload ws-echo-bench USOCKETS_BACKEND=io_uring`** (Linux + liburing).

---

## 7. Mental model

| Layer | Knobs |
|--------|--------|
| **Kernel / localhost** | sysctl, **`ulimit -n`**, loopback aliases |
| **Server accept capacity** | **`runThreaded`** / **`runCluster`**, **`maxConnections`**, tuning |
| **Client aggregate `c`** | Multiple **`websocketload`** processes if per-process thread caps bite |
| **Burst shaping** | **`--ramp-sec`**, stagger / gap between loaders, **`PARALLEL_FANOUT`** tuning |
| **Transient failures** | **`--connect-retries`**, **`--retry-delay-ms`** |

Scaling **sustained concurrent idle WebSockets** is as much **about pacing and OS headroom** as about raw framework throughput.
