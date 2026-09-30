# AGENTS.md — package: `nim_fasthttpclient`

Complements `nim_fasthttpclient/AGENTS.md` (layout + base rules — read that first); this file adds the unit contract. Where they overlap, the stricter rule applies.

Guardrails for AI agents working in `nim_fasthttpclient/` (async HTTP/1.1 +
HTTP/2 + WebSocket client with connection pooling).

## Ownership
- You own: `nim_fasthttpclient/src/` and `nim_fasthttpclient/tests/`.
- Do NOT modify other packages. The client shares the uSockets FFI from `nim_usockets` (read-only dependency).
- Do not run `git add/commit` unless asked.

## Hard rules
1. **Never issue a request from inside a response callback.** The client does not support re-entrant `request()` from its own dispatch — it can hang silently (observed in test_redirect_auth_strip). Defer follow-up requests (timer/main thread/new phase).
2. **Pool discipline**: connection cap checks happen in `ConnectionPool.addConnection` BEFORE any socket is created — keep that ordering; a cap hit must dispose the conn without opening a socket. Every failed open path must `us_socket_close` + remove from pool + dispose both conn and ClientConnData (no leaks, no dangling ext).
3. **Redirect security (do not regress)**: cross-origin redirects strip `Authorization`/`Cookie`/`Proxy-Authorization` (`stripSensitiveRedirectHeaders` + `sameRedirectOrigin`); same-origin keeps them. Location values with CRLF are rejected.
4. **Ext lifetime**: `ClientConnData` is raw-`alloc0`'d and its pointer stored in the socket ext; mirror the server-side contract — release before unrooting, nil the ext slot on close.
5. **Timeouts**: every public request path must honor `defaultTimeoutMs`/config timeouts; tests must set timeouts so a stuck request fails instead of hanging the suite.
6. TLS verification is ON by default — never flip the default.
7. Public API needs a `## ` doc comment (directly above, same indentation, no square brackets).
8. Regression tests go in `nim_fasthttpclient/tests/`; `test_client.nim` additionally requires `-d:nimFastHttpClientTest` (the gate handles it).

## Gate
```
bash harness/nim_fasthttpclient/run.sh
```
Runs all client tests (incl. the gated `test_client.nim`). Exits 0 only when green.