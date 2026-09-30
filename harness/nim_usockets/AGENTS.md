# AGENTS.md — package: `nim_usockets`

Complements `nim_usockets/AGENTS.md` (layout + base rules — read that first); this file adds the unit contract. Where they overlap, the stricter rule applies.

Guardrails for AI agents working in `nim_usockets/` (C FFI bindings + the
HTTP/WebSocket server core in `http.nim`) and the vendored `usockets/` C fork.

## Ownership
- You own: `nim_usockets/src/` and `nim_usockets/tests/`.
- `nim_usockets/usockets/` is a **locally patched fork** of uSockets (see `docs/design/usockets-fork.md`). Edit C sources only to extend the patch set, then rebuild `uSockets.a` (`make usockets`) and record the patch in `docs/design/usockets-fork.md`.
- Do NOT modify other packages. Do not run `git add/commit` unless asked.

## Hard rules
1. **FFI callbacks**: every C callback entry point must be `proc(...) {.cdecl.}` and must catch `Defect`/`CatchableError` at the boundary (pattern: `reportEscapedDefect`/`reportEscapedError`) — an escaping Nim exception in a C callback is an abort.
2. **SocketData lifetime contract (do not regress)**: `SocketData` objects live on the Nim heap and are rooted in `HttpServer.socketDataRoots` keyed by socket key; the C-owned `ext` slot carries only a raw pointer (`sizeof(pointer)`). On close the refs are released, the root is removed, **and the ext pointer is set to nil** — all three, in that order. Never store GC-managed state directly in the C ext region: GC runs on the loop thread while handlers execute.
3. **Socket lifecycle**: never restructure open/close paths without running the graceful-shutdown stress test (see Gate). Address reuse must install a fresh pointer + fresh root and never dereference a stale ext (the `magic` guard in `socketDataFor` is defense, not design).
4. **Request limits stay enforced on the recv path**: header byte limit + `incompleteHeaderExceedsLimit` behavior must remain; smuggling/framing fixes are load-bearing.
5. **Thread model**: the event loop is not thread-safe; cross-thread work goes through the established dispatch structures, not direct socket calls. macOS GCD builds start the loop on the main thread — keep `runThreaded`'s fallback intact.
6. Public API needs a `## ` doc comment (directly above, same indentation, no square brackets).
7. Regression tests go in `nim_usockets/tests/`; use the `-d:nimUwebsocketsTest` flag (the gate passes it automatically).

## Gate
```
bash harness/nim_usockets/run.sh          # all 43 tests, -d:nimUwebsocketsTest
# After any socket-lifecycle or close-path change, also:
nim c --run ... -d:nimUwebsocketsTest nim_express/tests/test_graceful_shutdown_improvements.nim
# run it 10x in a loop; expect 0 failures (known flake-prone area)
```
Exits 0 only when green.