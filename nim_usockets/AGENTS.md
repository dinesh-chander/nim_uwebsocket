# nim_usockets/AGENTS.md

Low-level uSockets FFI bindings and the HTTP/WebSocket server core. See the root `AGENTS.md` for full architecture.

Layout:
- `src/nim_usockets/usockets.nim` — C FFI to the uSockets library.
- `src/nim_usockets/http.nim` — HTTP/WebSocket server, raw socket callbacks, hot paths (`onSocketData`, `flushPendingResponses`).
- `src/nim_usockets/types.nim` — core types (SslMode, socket pointers, callbacks).
- `usockets/` — vendored uSockets C sources.

Rules:
- `usockets/` is a **locally patched fork** of uNetworking/uSockets (base: upstream `master` at `7a7c820`, i.e. v0.8.8 + 19 commits). Local patches add hardened NULL checks, a DNS cache, TCP FastOpen queue, rate-limited logging, and io_uring backend work — do NOT replace it with a vanilla upstream tarball. To upgrade, 3-way merge upstream `master` against the v0.8.8 base and keep the local patches (see `docs/` for the fork history). Rebuild the archive with `make usockets` (see root AGENTS.md for backend flags: GCD on macOS, epoll/io_uring on Linux).
- `uSockets.a` is a build artifact and is git-ignored; a fresh clone requires `make usockets` before linking.
- Keep allocations off the hot socket path; preserve the single-syscall write behavior in `http.nim`.
- Every public declaration needs a doc comment (see Documentation rules in the root AGENTS.md).
