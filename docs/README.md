# Documentation

Curated documentation for the nim_uwebsocket stack.

| Folder / file | Contents |
|---|---|
| [`../harness/`](../harness/) | Agentic harness: per-package and per-middleware AI-agent guardrails (`AGENTS.md`) + executable test gates (`run.sh`) |
| [`analysis/`](analysis/) | Cross-framework research (uWebSockets, Bun, GoFiber, Drogon, activej, tokio, and more) and the lessons extracted from them |
| [`benchmarks/`](benchmarks/) | Benchmark methodology, results, and per-iteration reports (HTTP + WebSocket, Linux scaling, io_uring) |
| [`design/`](design/) | Design documents and plans (HTTP/2 client/server, fastjson design, roadmap, vendored uSockets fork history) |
| [`design/simd-adoption.md`](design/simd-adoption.md) | SIMD (nimsimd) adoption + learnings: what was adopted, what was evaluated and why, with measured numbers and cross-cutting lessons |
| [`WEBSOCKET_CONNECTION_SCALING.md`](WEBSOCKET_CONNECTION_SCALING.md) | WebSocket connection-scaling design |
| [`WEBSOCKET_LOAD_SCALABILITY_LEARNINGS.md`](WEBSOCKET_LOAD_SCALABILITY_LEARNINGS.md) | Findings from WebSocket load-testing at scale |
| [`correctness_security_task_list.md`](correctness_security_task_list.md) | Correctness/security hardening status |
| [`performance_optimization_task_list.md`](performance_optimization_task_list.md) | Performance optimization status |

Generated API reference (regenerate with `make docs`): [`../doc/api/`](../doc/api/)
