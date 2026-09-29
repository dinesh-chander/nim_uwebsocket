# DevX APIs

This page documents developer-focused APIs added in `nim_express`.

## Route Groups

Use `group` to apply prefix-scoped middleware and routes:

```nim
let api = app.group("/api", authMiddleware)
api.get("/health", proc(req: Request, res: Response) =
  res.send("ok")
)
```

Groups can be nested:

```nim
let v1 = api.group("/v1", auditMiddleware)
v1.get("/users", usersHandler)
```

This produces route pattern `/api/v1/users`. Middleware from parent groups is inherited by nested group paths.

## Typed Locals

Request-local helpers avoid repetitive string parsing:

```nim
req.setLocal("user_id", 42)
let userId = req.localInt("user_id")
if not userId.ok:
  res.badRequest(userId.error)
```

Available helpers:
- `local(name, default = "")`
- `localRequired(name)`
- `localInt(name, required = true, defaultValue = 0, minValue = low(int), maxValue = high(int))`
- `localBool(name, required = true, defaultValue = false)`
- `setLocal(name, value: string|int|bool)`

## Request Abort Surface

Register request cancellation hooks:

```nim
req.onAbort(proc(reason: RequestCancelReason) =
  # timeout/disconnect/shutdown
  discard
)
```

Helpers:
- `aborted()`
- `abortReason()`

## Env Config Loader

Load and apply core runtime config from environment:

```nim
let cfg = loadAppEnvConfig()
app.applyAppEnvConfig(cfg)

# or one call:
discard app.loadAndApplyAppEnvConfig()
```

Supported keys:
- `NIM_EXPRESS_HOST` (fallback `HOST`)
- `NIM_EXPRESS_PORT` (fallback `PORT`)
- `NIM_EXPRESS_TRUST_PROXY`
- `NIM_EXPRESS_ASYNC_PUMP_INTERVAL_MS`
- `NIM_EXPRESS_MAX_INFLIGHT_ASYNC_REQUESTS`
- `NIM_EXPRESS_CONTEXT_POOL_PREWARM`
- `NIM_EXPRESS_MAX_PENDING_BYTES_PER_SOCKET`

## RFC7807 Problem Details

Legacy helper:

```nim
discard res.problem(400, "invalid_input", "email is required")
```

RFC7807-focused helper:

```nim
discard res.problemDetails(
  statusCode = 422,
  detail = "validation failed",
  typeUri = "https://example.com/problems/validation",
  title = "Validation Error",
  instance = "/todos/42",
  extensions = @[(key: "request_id", value: "req-123")]
)
```

## Plugin Lifecycle

Use plugin definitions to control startup/shutdown ordering with dependencies:

```nim
let dbPlugin = pluginDef(
  id = "db",
  initHook = proc(): bool = true,
  shutdownHook = proc() = discard
)
let cachePlugin = pluginDef(
  id = "cache",
  dependsOn = @["db"],
  initHook = proc(): bool = true
)
discard app.registerPlugin(dbPlugin)
discard app.registerPlugin(cachePlugin)
```

Plugins initialize during `setupHandlers`/`listen` and shutdown after the server loop exits.

## Advice Phases

Advice hooks are separate from middleware:

- `onBeforeRouteMatchAdvice`
- `onBeforeHandlerAdvice`
- `onAfterHandlerAdvice`
- `onErrorAdvice`

## Handler Adapters

You can lift sync handlers/middleware into async surfaces:

```nim
app.use(proc(req: Request, res: Response, next: proc() {.closure.}) =
  next()
)

app.getAsync("/users", proc(req: Request, res: Response) =
  res.send("ok")
)
```

## Typed Extractors

Generic extractor API supports `string`, `int`, and `bool`:

```nim
let userId = req.queryAs[int]("user_id")
let enabled = req.headerAs[bool]("x-enabled", required = false, defaultValue = false)
let name = req.localAs[string]("name")
```

## Detach/Snapshot APIs

Owned request data can be detached for background/offloaded work:

```nim
let snap = req.snapshot(includeBody = true)
# safe to use after request lifecycle ends
echo snap.path
echo snap.body
```

## Route Manifest Diagnostics

Route manifest helpers:

- `setRouteManifestOnStartup(enabled = true)`
- `getRouteManifestOnStartup()`
- `routeManifestEntries()`
- `routeManifestJson()`

When enabled, startup prints normalized route entries and shadow warnings.

## Inspector Events

Structured diagnostics can be consumed via:

```nim
app.onInspector(proc(event: InspectorEvent) =
  echo event.kind, " ", event.phase, " ", event.path
)
```

Event kinds include parse/protocol errors, timeout transitions, handler errors, and backpressure stalls.
