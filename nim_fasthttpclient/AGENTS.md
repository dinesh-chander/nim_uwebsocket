# nim_fasthttpclient/AGENTS.md

Async HTTP/1.1 + HTTP/2 + WebSocket + SSE client with connection pooling, built on `nim_usockets`. See the root `AGENTS.md`.

Rules:
- Client code runs on the same event loop as the server — no blocking calls, no cross-thread socket sharing.
- Keep the pooling behavior (keep-alive reuse, H2 stream multiplexing) intact when touching transport code.
- Every public declaration needs a doc comment (see Documentation rules in the root AGENTS.md).

## Agentic harness (unit guardrails)
Before changing this package: read `harness/nim_fasthttpclient/AGENTS.md` (ownership + pool/redirect hard rules) and finish only when `bash harness/nim_fasthttpclient/run.sh` exits 0.
