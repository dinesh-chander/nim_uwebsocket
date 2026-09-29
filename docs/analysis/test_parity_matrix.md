# Test Parity Matrix (vs analyzed high-performance frameworks)

Date: 2026-03-11  
Scope: `nim_usockets` + `nim_express` compared against practices observed in `uWebSockets`, `hyper`, `drogon`, `bun`, `activej`, `fiber`, `khttp`, `ohkami`.

## Summary
- We have strong HTTP/1.1 parser/framing/property coverage and middleware resilience coverage.
- We do **not** yet have full external conformance parity with top ecosystems (notably Autobahn-at-scale gating and HTTP/2 conformance harnesses).

## Matrix
| Area | Typical in top frameworks | Current in this repo | Parity |
|---|---|---|---|
| HTTP/1.1 request-line/header/framing conformance | RFC edge suites, malformed vectors, parser fuzz | `test_http_parser_framing_compliance`, `test_http_parser_rfc_extended`, `test_http_parser_property_fuzz_compliance` | High |
| HTTP request smuggling / TE+CL ambiguity guards | Explicit regression vectors | Covered in parser compliance suites | High |
| WebSocket handshake/frame protocol safety | RFC6455 edge tests + fuzz | `test_websocket_codec_and_handshake`, `test_http_ws_safety_regressions` | Medium-High |
| External WS conformance (Autobahn) | CI/automation in many mature stacks | Added harness script (`benchmark/run_ws_autobahn_conformance.sh`), not yet baseline-gated in CI | Medium |
| HTTP surface hardening (header sanitation, response-splitting) | Dedicated API-level compliance tests | `nim_express` surface compliance suites | High |
| Fault injection (write shortfall, close failures, alloc-failure fallback) | Chaos/fault harnesses | Added deterministic fault-injection suite (`test_fault_injection_failure_paths`) | Medium-High |
| Stateful multi-read fuzzing under arbitrary split boundaries | Chunked/read-loop mutational stress | Partial via property tests; broader long-run stateful harness still valuable | Medium |
| Long-soak chaos (slowloris, stalled writer, churn, shutdown interleavings) | Common in production-grade servers | Some targeted stability tests exist; full standardized soak matrix still evolving | Medium |
| HTTP/2 server conformance (`h2spec`-class) | Present for h2-capable frameworks | Stack is HTTP/1.1-focused; no h2 server conformance suite | Not applicable / Gap if h2 introduced |
| Differential testing against reference servers | Compare outcomes vs known-good servers | Not systematically automated | Low-Medium |

## Immediate additions implemented
1. HTTP conformance pack runner: `benchmark/run_http_conformance_pack.sh`
2. WS Autobahn runner: `benchmark/run_ws_autobahn_conformance.sh`
3. Make targets:
   - `make conformance-http`
   - `make conformance-ws`
   - `make conformance-all`

## Recommended next parity steps
1. Add nightly Autobahn run with pass/fail artifact upload.
2. Add stateful split-boundary fuzz runner that feeds parser via simulated read loop.
3. Add a single long-soak matrix script (slow-reader, keepalive churn, shutdown races).
4. If HTTP/2 is adopted, add `h2spec` suite before feature is considered production-ready.
