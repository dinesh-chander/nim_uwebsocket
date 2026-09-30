# AGENTS.md — middleware: `proxy`

Reverse-proxy middleware: forwards matching routes to a configured upstream with SSRF policy, timeouts, and credential stripping.

Shared rules: `harness/middleware/COMMON.md` (read first). Framework rules:
`nim_express/AGENTS.md`. This file adds only what is specific to this unit.

## Unit-specific rules
1. SSRF: the destination host is resolved and policy-checked before connecting. Redirects must not escape the policy (no following to internal/private addresses beyond the configured rule).
2. Upstream requests must carry timeouts; an upstream stall must not pin a worker socket forever.
3. Cross-origin upstream requests must not forward client credential headers (Authorization/Cookie/Proxy-Authorization).

## Context map
- Imports (unit-internal): common
- Imported by: none (leaf unit)
- Tests: test_proxy_improvements.nim, test_proxy_security.nim

## Ownership
- You own: `nim_express/src/nim_express/middlewares/proxy.nim` + `nim_express/tests/test_proxy*.nim`.
- Shared helpers (`common.nim`, `io_helpers.nim`, `file_helpers.nim`, `etag_core.nim`):
  edit only when strictly required, then re-run the gates of every unit importing them.
- No changes outside this package; no `git add/commit` unless asked.

## Gate
```
bash harness/middleware/proxy/run.sh
```
Module compile-check + this unit's tests (fallback: integration middlewares gates).
Exit 0 only when green.
