# HTTP Framework Performance Analysis (Recreated)

This folder recreates the cross-framework analysis and extracts practical lessons for `nim_express` and `nim_usockets`.

Additional internal design notes:

- [design/nim_fastjson_design.md](../design/nim_fastjson_design.md)

Framework reports:

- [khttp.md](/analysis/khttp.md)
- [ohkami_tokio.md](/analysis/ohkami_tokio.md)
- [hyper.md](/analysis/hyper.md)
- [uwebsockets.md](/analysis/uwebsockets.md)
- [bun_http.md](/analysis/bun_http.md)
- [activej.md](/analysis/activej.md)
- [drogon.md](/analysis/drogon.md)
- [gofiber.md](/analysis/gofiber.md)

## Cross-framework themes

1. Keep hot paths zero-copy and segmented as long as possible.
2. Single-thread event loops are fastest when handlers are non-blocking.
3. If work blocks (DB/files), isolate with worker/eventloop partitioning.
4. Reuse memory aggressively (buffers/context objects) and avoid per-request allocations.
5. Backpressure and write lifecycle must be first-class (writable callbacks, tryEnd/progress).
6. Routing and parsing should avoid string materialization on common paths.

## Highest-impact actions for Nim stack

1. Finish zero-copy response streaming for large rendered bodies (avoid final flatten copy).
2. Improve SQLite read path for `/todos/fragment` (read-only handle, query/index tuning).
3. Reduce write-path syscall/copy overhead with adaptive batching policy.
4. Remove repeated thread-local lookups from page buffer hot functions.
5. Add payload shaping options (fragment windows/pagination) for large list responses.

## Source links

- https://github.com/karlivory/khttp
- https://github.com/ohkami-rs/ohkami
- https://github.com/hyperium/hyper
- https://hyper.rs/
- https://github.com/uNetworking/uWebSockets
- https://unetworking.github.io/uWebSockets.js/generated/interfaces/HttpResponse.html
- https://github.com/oven-sh/bun
- https://bun.com/docs/runtime/http/server
- https://github.com/activej/activej
- https://activej.io/async-io/eventloop
- https://activej.io/boot/workers
- https://github.com/drogonframework/drogon
- https://github.com/drogonframework/drogon/wiki/ENG-08-1-Database-DbClient
- https://github.com/gofiber/fiber
- https://docs.gofiber.io/
