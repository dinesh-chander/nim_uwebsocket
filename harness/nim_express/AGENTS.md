# AGENTS.md — package: `nim_express`

Complements `nim_express/AGENTS.md` (layout + base rules — read that first); this file adds the unit contract. Where they overlap, the stricter rule applies.

Guardrails for AI agents working in `nim_express/` (Express-like framework:
app lifecycle, router, request/response, middlewares, scaling).

## Ownership
- You own: `nim_express/src/` and `nim_express/tests/`.
- Middleware units have their own guardrails + narrower gates: `harness/middleware/<name>/AGENTS.md` and `harness/middleware/<name>/run.sh`. When your change is scoped to one middleware, use that unit's gate; use the package gate when you touch core (`app.nim`, `router.nim`, `request.nim`, `response.nim`, `offload.nim`, `fastrand.nim`) or multiple middlewares.
- Do NOT modify other packages. Do not run `git add/commit` unless asked.

## Hard rules
1. **Routing**: `:param` matching and method dispatch live in `router.nim`; route matching is pcre2-backed. Keep the hot path allocation-light; changes here need the `nim_express` gate AND a quick benchmark sanity check (`benchmark/` — build with `make bench`).
2. **Response path**: single-syscall writes (headers+body combined), `StatusLines` pre-computed strings, `fastIntToStr` — don't introduce per-response allocations on the JSON hot path (~95k req/s target).
3. **Scaling/cluster** (`app.nim`):
   - Worker signal handling: workers reset SIGINT/SIGTERM to `SIG_DFL` before the factory runs; drain comes from the `graceful_shutdown` middleware installing handlers after the reset. Don't change the ordering without updating both sides.
   - Repeat-signal force-kill: `clusterWorkerPidTable` is lock-free (single-word stores, async-signal-safe). The signal handler path must not lock, allocate, or touch the GC.
   - Listen host: scaling entry points read `NIM_EXPRESS_HOST`/`HOST` (0.0.0.0 fallback) via `scalingEntryListenHost()`.
   - macOS: no SO_REUSEPORT load-balancing, `runThreaded` falls back to single-thread — keep the platform branches honest.
4. **Security (do not regress)**: header sanitization (incl. cookies/Content-Disposition), per-component symlink checks + `isRelativeTo` traversal guards in static files, body limit dual-layer (10MB + 8MiB), depth-capped JSON parsing, CORS/WS-origin policy, no user input echoed into errors or stack traces.
5. **Public API**: `## ` doc comment required on every public declaration (directly above, same indentation, no square brackets); regenerate docs with `make docs` after public API changes.
6. Regression tests go in `nim_express/tests/` (name them `test_<area>_*.nim` so middleware gates pick them up).

## Gate
```
bash harness/nim_express/run.sh        # all 71 tests (slowest gate — allow time)
bash harness/middleware/<name>/run.sh  # narrow gate for single-middleware work
```
Exits 0 only when green.