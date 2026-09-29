# HTTP / WebSocket Compliance Report

Last updated: 2026-03-05

## Scope
This report maps implemented protocol rules to concrete code paths in:
- `nim_usockets/src/nim_usockets/http.nim`
- `nim_usockets/src/nim_usockets/websocket.nim`
- `nim_express/src/nim_express/app.nim`
- `nim_express/src/nim_express/response.nim`

Primary specs:
- RFC 9112 (HTTP/1.1 Messaging): https://www.rfc-editor.org/rfc/rfc9112
- RFC 9110 (HTTP Semantics): https://www.rfc-editor.org/rfc/rfc9110
- RFC 6455 (WebSocket): https://www.rfc-editor.org/rfc/rfc6455

Frequently referenced exact sections:
- RFC 9112 §3.1 (method token): https://www.rfc-editor.org/rfc/rfc9112#section-3.1
- RFC 9112 §3.2 (Host in HTTP/1.1): https://www.rfc-editor.org/rfc/rfc9112#section-3.2
- RFC 9112 §6.1 (Transfer-Encoding): https://www.rfc-editor.org/rfc/rfc9112#section-6.1
- RFC 9112 §6.2 (Content-Length): https://www.rfc-editor.org/rfc/rfc9112#section-6.2
- RFC 9112 §6.3 (message body length precedence): https://www.rfc-editor.org/rfc/rfc9112#section-6.3
- RFC 9112 §7.1 (chunked coding): https://www.rfc-editor.org/rfc/rfc9112#section-7.1
- RFC 9112 §9.3 (persistence): https://www.rfc-editor.org/rfc/rfc9112#section-9.3
- RFC 9110 §10.1.1 (Expect): https://www.rfc-editor.org/rfc/rfc9110#section-10.1.1
- RFC 9110 §15.5.18 (417): https://www.rfc-editor.org/rfc/rfc9110#section-15.5.18
- RFC 9110 §15.6.2 (501): https://www.rfc-editor.org/rfc/rfc9110#section-15.6.2
- RFC 9110 §15.6.6 (505): https://www.rfc-editor.org/rfc/rfc9110#section-15.6.6
- RFC 6455 §4.2.1 (client handshake requirements): https://www.rfc-editor.org/rfc/rfc6455#section-4.2.1
- RFC 6455 §4.2.2 (server handshake requirements): https://www.rfc-editor.org/rfc/rfc6455#section-4.2.2
- RFC 6455 §5.3 (client-to-server masking): https://www.rfc-editor.org/rfc/rfc6455#section-5.3
- RFC 6455 §5.4 (fragmentation): https://www.rfc-editor.org/rfc/rfc6455#section-5.4
- RFC 6455 §5.5.1 (close frame): https://www.rfc-editor.org/rfc/rfc6455#section-5.5.1
- RFC 6455 §5.5.2 (ping): https://www.rfc-editor.org/rfc/rfc6455#section-5.5.2
- RFC 6455 §5.5.3 (pong): https://www.rfc-editor.org/rfc/rfc6455#section-5.5.3
- RFC 6455 §7.4.1 (close status codes): https://www.rfc-editor.org/rfc/rfc6455#section-7.4.1
- RFC 6455 §8.1 (UTF-8 errors): https://www.rfc-editor.org/rfc/rfc6455#section-8.1

## HTTP/1.1 Mapping

| Requirement | RFC section(s) | Code path(s) | Current behavior |
|---|---|---|---|
| Parse request-line and method as token | RFC 9112 §3, §3.1 | `parseMethodToken` | Enforces exact known method tokens; rejects malformed method token characters. |
| Unknown/unimplemented method status | RFC 9110 §15.6.2 | `parseHttpRequest` (`parseStatusCode = 501`) | Unknown methods return 501. |
| Unsupported HTTP version status | RFC 9110 §15.6.6 | `parseHttpRequest` (`parseStatusCode = 505`) | Non-HTTP/1.0 and non-HTTP/1.1 request lines return 505. |
| Host required for HTTP/1.1 and single Host field | RFC 9112 §3.2 | `parseHttpRequest` host validation | Missing, duplicated, or empty Host in HTTP/1.1 is rejected (400). |
| Expect header handling and 417 | RFC 9110 §10.1.1, §15.5.18 | `parseExpectHeaderBytes`, `parseHttpRequest` | Unsupported expectations and `100-continue` are currently rejected with 417. |
| Content-Length decimal framing parse | RFC 9112 §6.2, §6.3(5)(6) | `parseContentLengthBytes` | Non-decimal/overflow CL is rejected as invalid framing. |
| Transfer-Encoding parse and validity | RFC 9112 §6.1, §6.3(4) | `parseTransferEncodingBytes`, `parseHttpRequest` TE checks | Rejects malformed TE, duplicate chunked, unsupported codings, and non-final chunked in requests. |
| TE vs CL ambiguity rejection | RFC 9112 §6.3(3) | `parseHttpRequest` (`hasContentLength` + `hasTransferEncoding`) | Rejects requests containing both TE and CL (400). |
| Chunked decoding and trailer field-line parsing | RFC 9112 §7.1 | `parseChunkSizeLine`, `decodeChunkedBody` | Decodes chunked bodies and validates trailer field-line shape. |
| Response body forbidden for HEAD/1xx/204/205/304/2xx CONNECT | RFC 9112 §6.3, RFC 9110 §6.4.1, §9.3.2, §9.3.6 | `responseDisallowsBody` (low-level + express) | Body suppressed for forbidden combinations. |
| Connection persistence defaults | RFC 9112 §9.3 | `parseHttpRequest` (`connectionClose` logic) | HTTP/1.1 default keep-alive; HTTP/1.0 keep-alive requires explicit token. |
| Guard normal response paths from user TE framing | RFC 9112 §6.1/§6.2 framing correctness | `HttpResponse.setHeader`, `Response.set`, `Response.append` | Ignores user-set `Transfer-Encoding` in non-streaming APIs; normal paths use Content-Length framing. |
| Optional todo fragment windowing via Range | RFC 9110 §14 (Range), §15.3.7 (206), §15.5.17 (416) | `parseItemsRangeHeader`, `TodoController.respondTodoListFragmentWindow`, `Response.contentRange*` | In `mode=window`, validates `Range: items=start-end`, returns `206` with `Accept-Ranges`/`Content-Range`, and `416` with unsatisfied `Content-Range` for out-of-range windows. |
| HEAD route fallback to GET semantics | RFC 9110 §9.3.2 | `findRoute` (`fallbackToGet`) | HEAD uses explicit HEAD handler when present, otherwise GET route metadata path. |
| Unsupported CONNECT/TRACE app route handling | RFC 9110 §15.6.2 | `sendRouteMiss` | Returns 501 for CONNECT/TRACE when not implemented. |
| Multiple Set-Cookie handling as special-case field lines | RFC 9110 §5.3 note (Set-Cookie exception) | `Response.set` / `append` with `setCookies` | Preserves distinct Set-Cookie lines instead of comma-folding. |

## WebSocket Mapping

| Requirement | RFC section(s) | Code path(s) | Current behavior |
|---|---|---|---|
| Opening handshake validation (GET, Upgrade/Connection, key, version) | RFC 6455 §4.2.1 | `isWebSocketUpgrade`, `validateWebSocketUpgrade` | Enforces handshake preconditions; rejects invalid requests. |
| Version negotiation with 426 and Sec-WebSocket-Version | RFC 6455 §4.2.2 | `validateWebSocketUpgrade` | Non-`13` version returns 426 with `Sec-WebSocket-Version: 13`. |
| Sec-WebSocket-Accept generation | RFC 6455 §4.2.2 (step 5.4) | `generateAcceptKey` in both `http.nim` and `websocket.nim` | Uses `base64(raw SHA-1(key + GUID))` computation. |
| Frame shape constraints for control frames | RFC 6455 §5.2, §5.5 | `decodeWebSocketFrame` | Rejects fragmented control frames and control payload >125 bytes. |
| Client-to-server masking required | RFC 6455 §5.3 | `handleWebSocketData` (`not masked` -> close 1002) | Unmasked client frames trigger protocol error close (1002). |
| Fragmentation/continuation sequencing | RFC 6455 §5.4 | `handleWebSocketData` with `wsFragmentOpcode/wsFragmentPayload` | Enforces valid continuation flow and full message reassembly. |
| Ping/Pong behavior | RFC 6455 §5.5.2, §5.5.3 | `handleWebSocketData` opcode 0x9/0xA | Ping receives pong promptly; pong accepted/ignored. |
| Close frame payload validity | RFC 6455 §5.5.1, §7.4.1 | `handleWebSocketData` close branch, `isValidWsCloseCode` | Validates close payload length/code; protocol errors use 1002. |
| UTF-8 validity for text messages and close reason | RFC 6455 §8.1, §7.4.1 (1007) | `deliverWebSocketMessage`, close reason validation | Invalid UTF-8 triggers close 1007. |
| Oversized message handling | RFC 6455 §7.4.1 (1009) | `handleWebSocketData`, `onSocketData` oversize guard | Too-large messages are closed with 1009. |
| Close then transport shutdown | RFC 6455 §5.5.1, §7.1.7 | `sendWsCloseAndTerminate`, `WebSocketConnection.close` | Sends close frame and then shuts down socket path. |

## Intentional strictness / current limitations

1. `Expect: 100-continue` is currently not supported as an interim-response flow; parser maps it to 417.
2. For `Content-Length`, parser accepts strict decimal field values and repeated equal field-lines, but does not implement comma-list normalization from RFC 9112 §6.3(5).
3. This report covers implemented behavior in current code paths; it is not a complete formal proof of full RFC conformance.

## Quick references to core methods

- `parseHttpRequest`
- `parseTransferEncodingBytes`
- `parseExpectHeaderBytes`
- `responseDisallowsBody` (low-level + express)
- `validateWebSocketUpgrade`
- `decodeWebSocketFrame`
- `handleWebSocketData`
