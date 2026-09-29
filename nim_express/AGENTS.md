# nim_express/AGENTS.md

Express-style web framework (routing, middleware, scaling, JSON, compression). See the root `AGENTS.md` for architecture and performance notes.

Layout:
- `src/nim_express/app.nim` — app lifecycle and scaling (`runCluster`, `runThreaded`, `runAuto`, factory pattern).
- `src/nim_express/router.nim` — route matching with `:param` support.
- `src/nim_express/request.nim` / `response.nim` — request helpers, single-syscall response writes.
- `src/nim_express/config.nim` — config loading; precedence is defaults < `config.json` < env vars.
- `src/nim_express/middlewares/` — built-in middlewares (compression, CORS, body-limit, circuit-breaker, ...).
- `tests/` — unit and integration tests; `docs/` — package-level design notes.

Rules:
- `config.json` at the package root is a runtime sample config (loaded by the app); keep it valid JSON and in sync with `config.nim` defaults.
- Do not commit test binaries (e.g. `tests/ws_permessage_deflate_integration_server`) — they are git-ignored; build via `make test`.
- Preserve middleware flow semantics (before/after `next()`) and the sync fast-path dispatch when touching `app.nim`.
- Every public declaration needs a doc comment (see Documentation rules in the root AGENTS.md).
