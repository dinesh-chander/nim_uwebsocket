# examples/AGENTS.md

Ready-to-run example applications (HTMX demo, showcase API, WebSocket broadcast, SSE, OpenAPI, proxy, ...). See the root `AGENTS.md` for build flags.

Build:
```bash
make examples          # all examples -> examples/bin/
make htmx_app          # single example
```

Rules:
- `bin/` is build output (git-ignored) — never commit binaries here.
- `generated/` holds checked-in generated fixtures (e.g. `rest_openapi/openapi.json`) that examples read at runtime — keep them in sync with the generator.
- `apps/` contains the modular example sources referenced by the top-level `.nim` wrappers.
- Examples must stay runnable as-is after a fresh clone + `make usockets`; if an example needs new deps, update the root `nim_uwebsocket.nimble` and README.
