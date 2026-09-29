# Security Review: nim_express + nim_usockets

Date: 2026-03-10
Reviewer: Codex (iterative static review)

## Scope and method
- Reviewed parsing, headers, response lifecycle, middleware trust boundaries, websocket upgrade/auth, static files, sessions/cookies/csrf, compression, overload/error handling.
- Pass 1: broad surface mapping and hotspot review.
- Pass 2: targeted P0/P1 re-check on websocket/auth, traversal, parser framing, and stateful middleware.
- Result: no P0 findings. No additional P0/P1 found after pass 2.

## Severity summary
- P0: 0
- P1: 3
- P2: 4

## Findings (highest severity first)

### P1-1: WebSocket upgrades bypass HTTP middleware and route controls
- Impact: Authentication/authorization, CSRF, rate-limit, and route-bound security middleware can be bypassed for WebSocket connections. Any upgrade request can be accepted before app middleware executes.
- Evidence:
- `nim_usockets/src/nim_usockets/http.nim:7330` upgrades when `wsHandler != nil` and request is upgrade.
- `nim_usockets/src/nim_usockets/http.nim:7372` returns immediately after successful upgrade.
- `nim_usockets/src/nim_usockets/http.nim:7374` HTTP user handler is called only after that branch.
- `nim_express/src/nim_express/app.nim:1789` registers a global ws handler.
- `nim_express/src/nim_express/app.nim:2806` wires that global handler into server-level websocket callbacks.
- Why this matters: In `nim_express`, HTTP middlewares are run in app pipeline (`runMiddlewares`), but successful WS upgrades happen in `nim_usockets` before that pipeline.

### P1-2: WebSocket handshake has no origin/auth/path policy enforcement point
- Impact: Cross-origin and unauthenticated handshake risk for cookie-auth deployments; no request-scoped policy hook for rejecting based on path/origin/auth headers.
- Evidence:
- `nim_usockets/src/nim_usockets/http.nim:5278` `validateWebSocketUpgrade` checks only method/version/key semantics.
- `nim_usockets/src/nim_usockets/http.nim:5283`..`5293` no Origin/auth/path validation.
- `nim_express/src/nim_express/types.nim:228` WebSocket handlers only receive `(ws, message, isBinary)`.
- `nim_express/src/nim_express/types.nim:229` open/close handlers receive only `ws`.
- Why this matters: current callback signatures do not expose handshake request context for policy decisions.

### P1-3: Session middleware accepts client-supplied unsigned SID (session fixation risk)
- Impact: If an attacker can plant a `sid` cookie in a victim browser, subsequent authenticated session data may be persisted under attacker-chosen SID.
- Evidence:
- `nim_express/src/nim_express/middlewares/session.nim:159` reads SID directly from cookie.
- `nim_express/src/nim_express/middlewares/session.nim:161`..`163` does not rotate when cookie already exists.
- `nim_express/src/nim_express/middlewares/session.nim:166` loads store data by that SID.
- `nim_express/src/nim_express/middlewares/session.nim:196`..`197` saves data under same SID.
- Why this matters: no MAC/signature or server-side SID verification layer is present in middleware.

### P2-1: Insecure cookie defaults for session and CSRF (`Secure` off)
- Impact: In mixed/proxy-misconfigured deployments, sensitive cookies can traverse plaintext HTTP.
- Evidence:
- `nim_express/src/nim_express/middlewares/session.nim:91` `secureCookie: false` by default.
- `nim_express/src/nim_express/middlewares/csrf.nim:28` `secureCookie: false` by default.

### P2-2: Weak entropy fallback paths when CSPRNG is unavailable
- Impact: Predictable identifiers/tokens if `urandom` fails.
- Evidence:
- `nim_express/src/nim_express/middlewares/session.nim:108`..`109` SID fallback uses time/address.
- `nim_express/src/nim_express/middlewares/csrf.nim:44`..`45` CSRF token fallback uses time/address.
- `nim_express/src/nim_express/middlewares/multipart.nim:32`..`33` upload token fallback uses timestamp only.

### P2-3: CSRF middleware accepts token via query parameter
- Impact: Token leakage in logs, browser history, and referrer chains; weaker operational secrecy than header/form-only transport.
- Evidence:
- `nim_express/src/nim_express/middlewares/csrf.nim:87` falls back to `req.queryParam(...)`.

### P2-4: CORS `reflect` mode can enable broad credentialed cross-origin access if misconfigured
- Impact: If `origin="reflect"` and `credentials=true`, arbitrary Origin values may be trusted.
- Evidence:
- `nim_express/src/nim_express/middlewares/cors.nim:31`..`34` reflects request Origin.
- `nim_express/src/nim_express/middlewares/cors.nim:44` emits `Access-Control-Allow-Credentials: true`.

## Areas reviewed with no new high-severity findings
- HTTP parser/framing protections: Host requirement, TE/CL ambiguity checks, chunked decoding guards, header limits (`nim_usockets/src/nim_usockets/http.nim:3318`, `3348`, `3950`..`4183`).
- Header injection protections on response APIs (`nim_express/src/nim_express/response.nim:275`..`292`, `414`..`434`).
- Static/template path traversal guards (`nim_express/src/nim_express/middlewares/static_files.nim:72`..`89`, `nim_express/src/nim_express/response.nim:1018`..`1045`).
- WebSocket frame-level protocol checks (mask required, control-frame validation, payload bounds) (`nim_usockets/src/nim_usockets/http.nim:6036`..`6127`, `6729`..`6860`).

## Recommended priority order
1. Add explicit WS handshake policy hook with request context (path/origin/auth) and run it before upgrade.
2. Ensure WS upgrade path is route/middleware-aware (or provide dedicated WS route middleware chain).
3. Add signed session IDs and regeneration API (especially post-auth/login).
4. Flip secure-cookie defaults (or auto-enable when `req.secure()`/trusted proxy HTTPS is true).
