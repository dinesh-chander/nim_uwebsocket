# Agentic harness

Per-unit guardrails + executable gates for AI coding agents (and humans).

Each unit (5 packages + 36 middlewares) has:

- **`AGENTS.md`** — the unit's guardrails: unit-specific hard rules (lifetime
  contracts, security invariants), a context map (imports/dependents/tests),
  ownership, and the gate. Middleware units share their common rules in
  `middleware/COMMON.md`; the unit file adds only the deltas.
- **`run.sh`** — the acceptance gate: compile-checks the unit and runs its
  tests. **Exit 0 only when green.** An agent must not report work on a unit
  as done until its gate passes.

Shared machinery: `common.sh` (compile paths, `harness_run_tests`,
`harness_nim_check`, log capture under `/tmp/nim_harness_tests/`).

## Layout
```
harness/
  common.sh                  # shared build/test machinery (source, don't run)
  nim_utils/                 # substrate: fast_map/fast_set/async_logger/nim_fastjson
  nim_usockets/              # FFI + HTTP/WS server core (+ patched uSockets fork)
  nim_fasthttpclient/        # async HTTP/1.1 + HTTP/2 + WS client, pooling
  nim_express/               # framework core (app/router/request/response)
  nim_websocketcli/          # websocketload tooling
  middleware/COMMON.md       # shared guardrails for all middleware units
  middleware/<name>/         # one unit per nim_express middleware (36)
```

## Usage
```bash
# package gate (slow: full test group)
bash harness/nim_express/run.sh

# narrow middleware gate (fast: module check + that middleware's tests)
bash harness/middleware/rate_limit/run.sh
```

Middleware test discovery: `nim_express/tests/test_<name>*.nim`; when a
middleware has no dedicated tests the gate falls back to
`test_integration_middlewares.nim` + `test_middleware_resilience.nim`.

## Agent protocol
1. Identify the unit for the task (package, or single middleware if scoped).
2. Read that unit's `AGENTS.md` and obey its ownership + hard rules.
3. Make the change; add regression tests for bugfixes/behavior changes.
4. Run the unit's `run.sh`. Iterate until exit 0.
5. Report: changed files, test results, residual risks.

Cross-unit changes (e.g. a middleware that needs a core change): stop, report
the need instead of editing outside your ownership.
