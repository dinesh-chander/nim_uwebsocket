# AGENTS.md — package: `nim_websocketcli`

Complements `nim_websocketcli/AGENTS.md` (layout + base rules — read that first); this file adds the unit contract. Where they overlap, the stricter rule applies.

Guardrails for AI agents working in `nim_websocketcli/` (`websocketload` —
WebSocket load-testing tool; standalone CLI, depends on `nim_fasthttpclient`).

## Ownership
- You own: `nim_websocketcli/` (src/, tests/, websocketload.nim, nim.cfg, scripts/).
- Do NOT modify other packages. Do not run `git add/commit` unless asked.

## Hard rules
1. CLI tooling quality bar is lower than the library packages, but: no panics on bad user input (config/args validation with clear errors), clean shutdown on Ctrl-C (close sockets, release the client loop).
2. Load-generation must be non-allocating per message where practical (reuse buffers) — this tool hammers the server under test; its own overhead distorts results.
3. Keep config loading in one place (`websocketload` config module); tests assert against it (`tests/test_websocketload_config.nim`).
4. Public API needs a `## ` doc comment (directly above, same indentation, no square brackets).

## Gate
```
bash harness/nim_websocketcli/run.sh
```
Compile-checks the entry points and runs the config tests. Exits 0 only when green.