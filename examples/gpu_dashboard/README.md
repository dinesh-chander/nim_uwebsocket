# GPU Dashboard example (server push over WebSocket)

Port of the Node sidecar `gpu-stats-server.js` + `gpu-dashboard.html`
(multi-model-cli repo) re-architected as a **nim_express** app — with one
deliberate change: the frontend does **not poll**. The backend collects
metrics on a timer and pushes every snapshot over a WebSocket; the page is
plain HTMX (ws extension) + a little client-side rendering. No REST APIs are
consumed by the frontend.

## Layout

```
gpu_dashboard/
  main.nim         # app wiring: setInterval tick, per-connection WS push,
                   #   rate control, /, /healthz
  collectors.nim   # amd-smi / nvidia-smi / llama.cpp collectors (blocking,
                   #   run on the offload pool via runOffload)
  dashboard.html   # HTMX + ws-extension frontend (served at /)
  vendor/          # htmx.min.js + ws.js, vendored (no CDN)
  README.md        # this file
examples/gpu_dashboard_app.nim   # thin entrypoint so `make examples` builds it
```

## Build

```bash
make usockets
make examples                      # -> examples/bin/gpu_dashboard_app
```

Single-target build (recommended flags; `--threads:on` makes `runOffload`
completions land on the event loop):

```bash
cd examples
nim c -d:release --opt:speed --mm:arc --threads:on \
  --passL:"../nim_usockets/usockets/uSockets.a -lpthread -ldl" \
  -o:bin/gpu_dashboard_app gpu_dashboard_app.nim
```

(macOS: link with `-framework CoreFoundation` instead of `-lpthread -ldl`.)

## Run

```bash
./examples/bin/gpu_dashboard_app                 # http://localhost:8083
PORT=9000 GPU_INTERVAL_MS=500 ./examples/bin/gpu_dashboard_app
```

| Env | Default | Meaning |
|-----|---------|---------|
| `PORT` | `8083` | listen port |
| `GPU_INTERVAL_MS` | `1000` | backend collection/push interval (min 250) |
| `ENGINE_BASE` | *(unset)* | llama.cpp server base URL; when set, `/metrics` + `/props` are polled backend-side and normalized into the snapshot (Prometheus text or JSON engines) |
| `FAKE_SMI_DIR` | *(unset)* | test hook: read `amd.metric.out` / `amd.static.out` / `nvidia.out` fixtures instead of running vendor CLIs |

## Endpoints (ops/debug only — the UI uses `/` and `/ws`)

- `GET /` — the dashboard page.
- `WS /ws` — snapshot stream. The server collects every tick but delivers to
  each page **at the rate that page asked for** (per-connection pacing, not a
  broadcast): new clients start at the server interval, then the page sends a
  control frame `"{\"t\":\"rate\",\"ms\":N}"` — `N` in `250..3600000`, `0` pauses.
  Each page's header has a **Push** selector (1 s / 2 s / 5 s / 10 s / 30 s /
  60 s / Paused) that sends exactly this frame; the same socket carries data
  (server→page snapshots) and control (page→server rate changes).
  New clients get the last snapshot immediately on open; the HTMX ws
  extension auto-reconnects.
- `GET /healthz` — interval, engine mode, live `wsClients` count.
- `GET /debug/tick` — in-flight / has-snapshot flags (also keeps the async pump installed).

## Single-file distribution

The page and both vendored JS files are embedded into the executable at
compile time via the nim_express `staticEmbedView` macro (added for this
example; see `nim_express/src/nim_express/app.nim`), so the binary runs with
**no asset files and no CDN**: `cp examples/bin/gpu_dashboard_app /anywhere/`
is a complete distribution. `dashboard.html` is still served disk-first when
the source tree is present, so frontend edits show on reload without a
rebuild; `/vendor/htmx.min.js` and `/vendor/ws.js` always come from the
embedded copies (long `Cache-Control` headers).

## Architecture notes

- Collection ticks fire independent blocking calls (amd-smi metric, nvidia-smi
  CSV, first-time amd-smi static, optional engine HTTP) concurrently on the
  malebolgia offload pool with `runOffload`, gathered with allSettled
  semantics — a failing collector becomes a string in `gpus.errors` instead
  of killing the tick.
- The llama.cpp parser mirrors the Node sidecar: metric-name alias table
  (`n_*` and `llamacpp:*` generations), Prometheus text parsing, decode/prefill
  rates from counter deltas, 60 s-cached `/props` model name, JSON engines
  passed through with `kind: "json"`.
- Per-page pacing: the tick loop keeps a `gConns: seq[Conn]` of open sockets,
  each with its own `rateMs` and `nextAtMs`; a tick sends to a connection only
  when its deadline is due (data is at most one collection interval stale, and
  every UI rate is a multiple of the interval). Paused connections receive
  nothing until resumed. Connection identity is the stable `WebSocket` ref the
  framework keeps on the socket, so rate frames and pushes always match.
- Memory: `gConns` is bounded by open tabs; per-tick payloads are rebuilt
  strings freed by ARC after the tick; measured RSS stays flat over hours of
  pushing to multiple clients (a few MB, ~8 threads incl. the offload pool).

## Smoke test without GPUs

```bash
mkdir -p /tmp/fakesmi
cat > /tmp/fakesmi/amd.metric.out <<'EOF'
{"gpu_data":[{"gpu":0,"temperature":{"edge":{"value":55.0},"hotspot":{"value":61.0}},"usage":{"gfx_activity":{"value":83.0}},"mem_usage":{"used_vram":{"value":24000.0},"total_vram":{"value":32768.0}},"power":{"socket_power":{"value":180.5}},"clock":{"gfx_0":{"clk":{"value":2400.0}},"mem_0":{"clk":{"value":1000.0}}}}]}
EOF
cat > /tmp/fakesmi/amd.static.out <<'EOF'
{"gpu_data":[{"gpu":0,"asic":{"market_name":"Radeon PRO 7900 XTX"},"limit":{"ppt0":{"socket_power_limit":{"value":315.0}}}}]}
EOF
: > /tmp/fakesmi/nvidia.out   # absent nvidia-smi -> recorded as a soft error
FAKE_SMI_DIR=/tmp/fakesmi ./examples/bin/gpu_dashboard_app &
curl -s http://localhost:8083/healthz
curl -sN --http1.1 -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  http://localhost:8083/ws   # 101 Switching Protocols
```
