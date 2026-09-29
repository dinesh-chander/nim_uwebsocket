# Linux Scaling Layout And Runtime Knobs

This guide documents a practical Linux deployment layout for `nim_express` and maps common runtime knobs to framework behavior.

This is documentation-only guidance. It does not change runtime behavior on macOS.

## Goal

- Keep one event loop per worker process.
- Pin workers to predictable CPU sets.
- Use the Linux throughput profile where appropriate.
- Keep macOS behavior unchanged (`runAuto` remains single-process there).

## Recommended Linux Layout

1. Start with `runCluster(createApp, port, numWorkers = N)` where `N` is close to physical core count.
2. Apply `app.applyLinuxThroughputProfile()` in app bootstrap when running throughput workloads.
3. Pin workers with `taskset`/`numactl` (or `benchmark/linux_affinity_numa.sh`) for stable tail latency.
4. Use one port per worker when fronted by nginx/haproxy, or a shared port with `SO_REUSEPORT` in cluster mode.

Example single-socket host (8 cores):

- `NIM_EXPRESS_WORKERS=8`
- `NIM_EXPRESS_CPU_LIST=0-7`
- `NIM_EXPRESS_NUMA_NODE=0`
- `NIM_EXPRESS_BASE_PORT=3002`
- `NIM_EXPRESS_PROFILE=linux-throughput`

Example dual-socket host (2 x 16 cores):

1. Group A: `NIM_EXPRESS_WORKERS=16`, `NIM_EXPRESS_CPU_LIST=0-15`, `NIM_EXPRESS_NUMA_NODE=0`, `NIM_EXPRESS_BASE_PORT=3002`
2. Group B: `NIM_EXPRESS_WORKERS=16`, `NIM_EXPRESS_CPU_LIST=16-31`, `NIM_EXPRESS_NUMA_NODE=1`, `NIM_EXPRESS_BASE_PORT=3102`

## Knob Mapping

| Knob | Values | Runtime Mapping |
|---|---|---|
| `NIM_EXPRESS_PROFILE` | `linux-throughput` or empty | `linux-throughput` maps to `app.applyLinuxThroughputProfile()` in app bootstrap. |
| `NIM_EXPRESS_SCALE_MODE` | `auto`, `cluster`, `threaded` | Maps to choosing `runAuto`, `runCluster`, or `runThreaded` in app entrypoint. |
| `NIM_EXPRESS_WORKERS` | `0..N` | For `cluster/auto`: maps to `numWorkers` argument. `0` means runtime default sizing. |
| `NIM_EXPRESS_THREADS` | `0..N` | For `threaded`: maps to `numThreads`. `0` means runtime default sizing. |
| `NIM_EXPRESS_BASE_PORT` | integer | Base port for multi-port process launchers (for example affinity scripts). |
| `NIM_EXPRESS_CPU_LIST` | `0-7`, `0,2,4-6` | CPU pin layout used by launch scripts. |
| `NIM_EXPRESS_NUMA_NODE` | integer | NUMA node used by launch scripts (`numactl --cpunodebind/--membind`). |

Notes:

- `NIM_EXPRESS_WORKERS` and `NIM_EXPRESS_THREADS` are deployment knobs for app boot logic; wire them in your app entrypoint.
- `NIM_EXPRESS_BASE_PORT`, `NIM_EXPRESS_CPU_LIST`, and `NIM_EXPRESS_NUMA_NODE` are launcher knobs, not framework-internal API.

## Layout Resolver Helper

Use the helper to resolve defaults and worker-to-CPU mapping:

```bash
NIM_EXPRESS_DOCS_ALLOW_NON_LINUX=1 \
NIM_EXPRESS_WORKERS=8 \
NIM_EXPRESS_CPU_LIST=0-7 \
bash nim_express/docs/scripts/linux_scaling_layout.sh
```

The output includes:

- Resolved worker count (including default sizing when `NIM_EXPRESS_WORKERS=0`)
- CPU expansion and round-robin worker mapping
- Port mapping from `NIM_EXPRESS_BASE_PORT`

## macOS

- Keep current behavior unchanged: no Linux affinity/NUMA assumptions.
- `runThreaded` remains constrained by platform limitations.
- Use the Linux layout only for Linux deployments.
