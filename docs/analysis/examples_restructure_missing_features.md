# Examples Restructure: Missing Features

Date: 2026-03-10

During the examples restructure, these framework-level gaps were identified:

1. Built-in OpenAPI generation from registered routes is not available.
2. Cooperative cancellation exists (`req.onAbort`, `req.aborted`, timeout budget), but there is no first-class cancellation token that propagates into offloaded/background work.
3. Multipart uploads are available, but files/fields are exposed via `req.locals` naming conventions instead of typed file abstractions.
4. SSE is implementable via chunked responses, but there is no dedicated SSE helper API (framing heartbeat/retry helpers, stream lifecycle callbacks).
5. WebSocket compression controls require direct `app.server` calls instead of full `ExpressApp` wrappers.

See `analysis/examples_todo_items.json` for structured TODO entries.
