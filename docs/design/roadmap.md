# Review Fix Execution Plan

Goal: resolve the latest four correctness findings with isolated steps and per-step verification.

Status: completed step-by-step (all items below are implemented and verified).

## [x] Step 1: Preserve non-enum HTTP status codes in `Response.send`
- File: `nim_express/src/nim_express/response.nim`
- Change:
  - Stop forcing unknown status codes through enum fallback to `200`.
  - Build/send status line from `res.statusCode` directly in `send`.
- Validation:
  - `res.status(429).send(...)` returns status line `HTTP/1.1 429 ...`.
  - `res.status(422).send(...)` returns status line `HTTP/1.1 422 ...`.

## [x] Step 2: Make `clearCookie` emit expiry directives
- File: `nim_express/src/nim_express/response.nim`
- Change:
  - Include `Max-Age` for non-zero values.
  - For non-positive values, also include `Expires=Thu, 01 Jan 1970 00:00:00 GMT`.
- Validation:
  - `clearCookie` response includes expiry attributes in `Set-Cookie`.

## [x] Step 3: Only propagate params for matched dynamic routes
- File: `nim_express/src/nim_express/app.nim`
- Change:
  - Use scratch params while probing dynamic routes.
  - Mark params initialized only when a dynamic route actually matches.
- Validation:
  - A static match after a failed dynamic probe does not receive stale `req.params`.

## [x] Step 4: Generate WebSocket accept key from raw SHA1 bytes
- File: `nim_usockets/src/nim_usockets/websocket.nim`
- Change:
  - Convert SHA1 hex digest to raw bytes and base64-encode bytes.
- Validation:
  - RFC sample key `dGhlIHNhbXBsZSBub25jZQ==` produces
    `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`.

## [x] Final verification
- Build benchmark binary.
- Run targeted correctness checks for status, cookies, params, and WebSocket accept key.
- Run quick perf sanity check (`wrk -t4 -c200 -d20s /plaintext`).
