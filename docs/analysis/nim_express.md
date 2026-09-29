# nim_express Deep Code Analysis

Scope reviewed: `/nim_express`

## 1) Executive summary

`nim_express` has a strong high-performance core: route artifacts are precompiled, request/response objects are pooled, and HTTP method semantics (notably `HEAD` fallback and `405/501` handling) are considered carefully.  
The main risks are in security hardening and behavioral consistency, not core routing throughput:

- Header/cookie output paths are not sanitized against CRLF injection.
- Template rendering inserts unescaped values directly into HTML.
- Trust-boundary handling is weak in proxy-related helpers (`x-forwarded-proto`, optional proxy IP trust).
- Error responses can leak internal exception messages.
- Some middleware APIs are semantically incomplete (`timeout`) or easy to misconfigure (`cors` with credentials).

Overall: performant architecture with good HTTP framing discipline, but requires a security hardening pass before production exposure.

## 2) Findings (severity-tagged)

### Critical

1. **[Critical] Response splitting risk via unsanitized header/cookie values**
   - Evidence:
     - `response.set/append` stores raw header name/value without CR/LF validation: `src/nim_express/response.nim:191`, `src/nim_express/response.nim:217`, `src/nim_express/response.nim:205`, `src/nim_express/response.nim:232`
     - Header emission writes raw keys/values into response head: `src/nim_express/response.nim:384`, `src/nim_express/response.nim:386`, `src/nim_express/response.nim:579`, `src/nim_express/response.nim:581`, `src/nim_express/response.nim:854`, `src/nim_express/response.nim:856`
     - Cookie strings are concatenated from raw parts: `src/nim_express/response.nim:247`
     - File helper header builder writes raw header map values: `src/nim_express/middlewares/file_helpers.nim:18`, `src/nim_express/middlewares/file_helpers.nim:20`
   - Impact:
     - If application code passes untrusted header/cookie input, attackers can inject extra headers or split responses.
   - Recommendation:
     - Enforce RFC token validation for header names and reject/control-strip `\r`/`\n` in all header values (including `Location`, `Set-Cookie`, `Content-Disposition`).

### High

2. **[High] Template injection/XSS surface in view rendering**
   - Evidence:
     - Template renderer inserts local values directly (`result.add(value)`) with no escaping: `src/nim_express/response.nim:732`, `src/nim_express/response.nim:742`
     - `render` uses this path directly for HTML output: `src/nim_express/response.nim:760`, `src/nim_express/response.nim:768`
   - Impact:
     - Any user-controlled value in template locals can produce reflected/stored XSS.
   - Recommendation:
     - Default to HTML-escaped interpolation; add explicit raw markers (`{{{raw}}}` or filter) only when required.

3. **[High] Internal error-message disclosure to clients**
   - Evidence:
     - Exception message returned to client in multiple failure paths: `src/nim_express/app.nim:1251`, `src/nim_express/app.nim:1275`, `src/nim_express/app.nim:1277`, `src/nim_express/app.nim:1311`
   - Impact:
     - Stack/procedure details and sensitive operational strings may be exposed.
   - Recommendation:
     - Return generic 500 body by default; gate detailed error output behind explicit debug mode.

4. **[High] Proxy trust boundary bypass in `protocol()/secure()`**
   - Evidence:
     - `protocol` trusts `x-forwarded-proto` unconditionally: `src/nim_express/request.nim:68`, `src/nim_express/request.nim:70`
     - `secure` derives from that value: `src/nim_express/request.nim:75`
   - Impact:
     - Clients can spoof HTTPS context unless deployment always strips/controls forwarded headers.
   - Recommendation:
     - Add app-level `trustProxy` policy; only use forwarded headers when source proxy is trusted.

### Medium

5. **[Medium] CORS misconfiguration hazard: `*` origin + credentials**
   - Evidence:
     - Default origin is `*`: `src/nim_express/middlewares/cors.nim:14`
     - Credentials can be enabled simultaneously: `src/nim_express/middlewares/cors.nim:23`, `src/nim_express/middlewares/cors.nim:24`
   - Impact:
     - Invalid/non-portable behavior across browsers; can create confusing security posture.
   - Recommendation:
     - When `credentials=true`, require explicit origin reflection/allowlist and emit `Vary: Origin`.

6. **[Medium] `timeout` middleware does not enforce timeout**
   - Evidence:
     - Middleware only stores deadline in locals and awaits next: `src/nim_express/middlewares/timeout.nim:6`, `src/nim_express/middlewares/timeout.nim:8`, `src/nim_express/middlewares/timeout.nim:10`
   - Impact:
     - False sense of protection; long handlers still run indefinitely.
   - Recommendation:
     - Implement cancellation/abort semantics using server timers and definitive timeout response path.

7. **[Medium] Rate limiting is per-thread/per-process, not global**
   - Evidence:
     - Stores are thread-local (`threadvar`): `src/nim_express/middlewares/rate_limit.nim:9`, `src/nim_express/middlewares/rate_limit.nim:10`, `src/nim_express/middlewares/rate_limit.nim:11`, `src/nim_express/middlewares/rate_limit.nim:12`
   - Impact:
     - Effective limit scales with worker count; attackers can bypass strict global expectations.
   - Recommendation:
     - Document as local limiter or offer pluggable shared backend (Redis/memcached/in-process shmem).

8. **[Medium] `bodyParser` can throw on malformed form-encoding**
   - Evidence:
     - `decodeUrl` called without error guard: `src/nim_express/middlewares/body_parser.nim:13`
   - Impact:
     - Malformed `%` sequences can trigger exceptions and 500s.
   - Recommendation:
     - Catch decode errors and return `400 Bad Request` (do not crash middleware chain).

9. **[Medium] Header-level behavior inconsistent between async and sync error paths**
   - Evidence:
     - Async path invokes `app.errorHandler` when set: `src/nim_express/app.nim:1271`, `src/nim_express/app.nim:1273`
     - Fast sync path bypasses `app.errorHandler` and returns direct serverError: `src/nim_express/app.nim:1299`, `src/nim_express/app.nim:1309`, `src/nim_express/app.nim:1311`
   - Impact:
     - Different behavior for equivalent failures depending on middleware presence/route type.
   - Recommendation:
     - Normalize error handling so sync and async routes go through a single policy.

### Low

10. **[Low] Naive content negotiation and cache freshness helpers**
    - Evidence:
      - `accepts` uses substring matching: `src/nim_express/request.nim:53`, `src/nim_express/request.nim:58`
      - `fresh` checks `etag in if-none-match` directly: `src/nim_express/request.nim:87`, `src/nim_express/request.nim:93`
    - Impact:
      - Edge-case RFC mismatches (`q` values, weak/strong validators, token boundaries).
    - Recommendation:
      - Add token-aware parsers compliant with RFC 9110 matching semantics.

11. **[Low] File serving often buffers whole file in memory**
    - Evidence:
      - Non-fast-path reads full file before send: `src/nim_express/middlewares/file_helpers.nim:103`, `src/nim_express/middlewares/file_helpers.nim:106`
    - Impact:
      - Higher memory pressure and latency for large static assets.
    - Recommendation:
      - Prefer zero-copy/sendfile-style streaming on all platforms where possible.

12. **[Low] Duplicate compression logic can drift**
    - Evidence:
      - Main policy path in `maybeCompressBody`: `src/nim_express/response.nim:282`
      - Separate text-specific compression path: `src/nim_express/response.nim:825`, `src/nim_express/response.nim:829`
    - Impact:
      - Behavior differences (hooks, savings thresholds, profiles) across `send/json/text`.
    - Recommendation:
      - Route all compression decisions through a single policy function.

## 3) Optimization opportunities (prioritized)

1. **Unify compression decision path**
   - Consolidate `text()` and `send/json/jsonify` into `maybeCompressBody` policy once (`response.nim:282`, `response.nim:825`).
   - Benefit: less branch divergence, fewer bugs, simpler tuning.

2. **Reduce async middleware overhead for sync-only stacks**
   - Middleware currently forces async request scheduling when present (`app.nim:1326`, `app.nim:1334`, `app.nim:1289`).
   - Add a “sync middleware” pipeline option for hot sync routes.

3. **Stream file responses broadly**
   - Replace full `readFileAsync` fallback with chunked/sendfile pipeline (`file_helpers.nim:103`, `file_helpers.nim:106`).
   - Benefit: memory stability under static-asset load.

4. **Avoid per-middleware closure churn in `runMiddlewares`**
   - `nextFn` closure recreated per middleware invocation (`app.nim:1197`, `app.nim:1201`).
   - Consider index-driven iterative state machine.

5. **Hook wrapper overhead in `onBeforeHeaders`**
   - Wrapper request/response objects acquired/released for each callback (`app.nim:662`, `app.nim:665`, `app.nim:668`).
   - If hook is high-frequency, consider lightweight metadata struct instead.

6. **Improve request helper parsing accuracy**
   - `accepts`/`fresh` tokenization improvements (`request.nim:53`, `request.nim:87`) reduce app-level workaround code and branch retries.

## 4) Security issues and mitigations

1. **Header injection / response splitting**
   - Affected: header setters/emission + cookie construction (`response.nim:191`, `response.nim:247`, `file_helpers.nim:18`)
   - Mitigation:
     - Reject header names outside RFC token charset.
     - Reject `\r`/`\n` in all header values.
     - Add safe builders for `Location`, `Content-Disposition`, and cookies.

2. **Template XSS**
   - Affected: raw local interpolation (`response.nim:742`)
   - Mitigation:
     - Escape by default.
     - Introduce explicit raw opt-in token.
     - Add tests for `<script>`, event handlers, attribute context.

3. **Proxy header spoofing**
   - Affected: `protocol()/secure()` (`request.nim:68`, `request.nim:75`)
   - Mitigation:
     - `app.setTrustProxy(...)` with CIDR/known proxy list.
     - Ignore forwarded headers when untrusted.

4. **Sensitive error leakage**
   - Affected: error bodies use `e.msg` (`app.nim:1251`, `app.nim:1311`)
   - Mitigation:
     - Replace with generic error body.
     - Send details only to logs/observability.

5. **CORS credential handling**
   - Affected: wildcard origin with credentials (`cors.nim:14`, `cors.nim:23`)
   - Mitigation:
     - Disallow `*` when credentials enabled.
     - Emit `Vary: Origin`; reflect only validated origins.

6. **Rate-limit trust model**
   - Affected: optional forwarded-header trust and per-thread stores (`rate_limit.nim:9`, `rate_limit.nim:56`)
   - Mitigation:
     - Restrict proxy trust to trusted ingress.
     - Offer shared limiter backend for clustered deployments.

## 5) Quick-win action list (top 10)

1. Add centralized `sanitizeHeaderName/Value` and enforce it in `set`, `append`, `cookie`, `redirect`, and file helper header construction.
2. Change template rendering to HTML-escape locals by default; add explicit raw interpolation syntax.
3. Replace `res.serverError(e.msg)` with generic body and internal logging in all catch blocks.
4. Introduce `trustProxy` app setting and gate `x-forwarded-proto` / forwarded IP usage.
5. Fix CORS middleware: when `credentials=true`, require concrete origin and set `Vary: Origin`.
6. Implement real timeout behavior (timer + abort response), or rename middleware to avoid false expectations.
7. Add `decodeUrl` error handling in `bodyParser` and return `400` on malformed form data.
8. Unify compression logic so `text()` follows policy hooks/thresholds used by `send/json/jsonify`.
9. Improve `accepts` and `fresh` to token-aware parsers for RFC-safe negotiation/validators.
10. Expand static file path to streaming/sendfile on non-macOS fast path to avoid full-file memory loads.

