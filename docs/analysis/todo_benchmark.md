# Todo Benchmark Report

Date (UTC): 2026-03-05T21:45:17Z  
Repo: ``  
Scope: Todo app benchmark execution and reporting only.

## Environment Assumptions

- OS: `macOS 26.3` (`Darwin 25.3.0`, `arm64`)
- CPU: `Apple M1 Pro` (10 logical CPUs)
- RAM: `17179869184` bytes (16 GB)
- Nim: `2.2.8`
- Load tools: `wrk 4.2.0 [kqueue]`, `ab 2.3`
- Server mode: single process on localhost (`PORT=3300`)
- DB: `/todos.db`

## App Build and Run

```bash
sh -lc 'cd /nim_express/examples && \
  nim c -d:release --opt:speed --mm:arc -o:../bin/todo_sqlite_mvc_app todo_sqlite_mvc_app.nim'
```

```bash
sh -lc 'PORT=3300 \
  TODO_DB_PATH=/todos.db \
  /nim_express/bin/todo_sqlite_mvc_app'
```

Startup log:
- `Starting Todo MVC + SQLite + HTMX example...`
- `Server running at http://localhost:3300`

## Template/View Shape

Todo HTML uses dedicated templates under:
- `nim_express/examples/views/todo/`
  - `index.html`, `list.html`, `item.html`, `count.html`, `error.html`, `empty_item.html`

`GET /todos/fragment` is HTML fragment based (not JSON API).

## Endpoint Sanity Checks Before Load

```bash
curl -sS -D - http://127.0.0.1:3300/todos/fragment -o /tmp/todo_fragment_sample.html
```
- Result: `HTTP/1.1 200 OK`
- `content-length: 250206` bytes

```bash
curl -sS -D - -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  --data "title=benchmark-seed" http://127.0.0.1:3300/todos -o /tmp/todo_post_sample.html
```
- Result: `HTTP/1.1 200 OK`

## Benchmark Commands

Warmup:
```bash
wrk -t2 -c20 -d5s --latency http://127.0.0.1:3300/todos/fragment
```

Measured `/todos/fragment`:
```bash
wrk -t8 -c200 -d20s --latency http://127.0.0.1:3300/todos/fragment
```

Mutation script (`/tmp/wrk_post_todos.lua`):
```lua
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/x-www-form-urlencoded"
local c = 0
request = function()
  c = c + 1
  return wrk.format(nil, "/todos", nil, "title=bench-" .. c)
end
```

Warmup mutation:
```bash
wrk -t2 -c20 -d5s --latency -s /tmp/wrk_post_todos.lua http://127.0.0.1:3300
```

Measured mutation (`POST /todos`):
```bash
wrk -t4 -c80 -d20s --latency -s /tmp/wrk_post_todos.lua http://127.0.0.1:3300
```

## Measured Results

| Endpoint | Tool | Threads | Concurrency | Duration | Req/sec | Avg Lat | P50 | P99 | Notes |
|---|---|---:|---:|---|---:|---:|---:|---:|---|
| `GET /todos/fragment` | wrk | 8 | 200 | 20s | 2794.13 | 71.38ms | 71.33ms | 87.71ms | 56,132 requests, 668.77 MB/s transfer |
| `POST /todos` | wrk | 4 | 80 | 20s | 990.85 | 81.86ms | 74.17ms | 207.76ms | 19,888 requests, 802.91 KB/s transfer |

## Post-Run Blocker and Partial Results

After mutation load, DB row count reached `40200` (`select count(*) from todos;`).

`GET /todos/fragment` became unhealthy:
```bash
wrk -t2 -c20 -d5s --latency http://127.0.0.1:3300/todos/fragment
```
- `0 requests`
- `Socket errors: read 422`
- `curl` also reports: `Empty reply from server`

Other routes still worked (`/`, `/todos/count` returned `200`), so this is partial endpoint failure, not full process crash.

Windowed fragment still worked at this dataset size:
```bash
wrk -t4 -c100 -d10s --latency -H "Range: items=0-127" \
  "http://127.0.0.1:3300/todos/fragment?mode=window"
```
- `1274.52 req/sec`, avg `78.07ms`, p99 `126.32ms`

## Concise Bottleneck Hypotheses

1. `GET /todos/fragment` scales linearly with todo count (full-list HTML generation/transfer), and becomes unstable at large payload sizes.
2. Mutation path likely pays SQLite write + count-read cost per request (`createTodo` + `countRemaining`), increasing tail latency (`p99 207.76ms`).
3. Large template-rendered response copy/write path (HTML + socket output) appears to be the main throughput limiter on fragment endpoint.
4. Defaulting to full fragment (instead of windowing/pagination) is the main functional risk under sustained mutation traffic.
