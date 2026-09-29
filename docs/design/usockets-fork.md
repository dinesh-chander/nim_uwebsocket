# Vendored uSockets fork

`nim_usockets/usockets/` is a **locally patched fork** of
[uNetworking/uSockets](https://github.com/uNetworking/uSockets). It is not a
vanilla vendor drop and must not be replaced with a plain upstream tarball.

## Upstream base

| | |
|---|---|
| Base release | v0.8.8 (2024-02-07) — the last official tag |
| Rebased onto | upstream `master` @ `7a7c820` (2026-09-16), i.e. v0.8.8 + 19 commits |
| Last rebase | 2026-09-30 |

Upstream delta absorbed in the 2026-09-30 rebase:
- `on_pre_open` callback extended with peer IP: `(context, fd, char *ip, int ip_length)`
  (upstream `86097c4`). The Nim FFI type `OnPreOpenCb` in
  `nim_usockets/src/nim_usockets/types.nim` must match this 4-argument signature.
- asio backend: `deadline_timer` → `steady_timer` (`2353808`, deprecation fix).
- Configurable `LIBUS_RECV_BUFFER_LENGTH` (`a80584e`).
- UDP `msg_name` per-buffer fix (`ba0db0b`), lsquic/BoringSSL bumps (QUIC only).

## Local patches (must be preserved on any future rebase)

Approximately 3,800 lines across the eventing/networking backends:

- **Hardened NULL checks** after `us_poll_create` / `us_create_socket_context`
  across `bsd.c`, `context.c`, `udp.c`, `socket.c`, `crypto/openssl.c`,
  `eventing/*` (prevents NULL-deref crashes on allocation failure).
- **DNS cache** in `bsd.c` (`DNS_CACHE_SIZE=512`, 300 s TTL) to avoid repeated
  `getaddrinfo` calls on the hot path.
- **TCP FastOpen queue** (`LIBUS_TCP_FASTOPEN_QUEUE=4096`, set in `Makefile`
  CFLAGS).
- **Rate-limited warning logging** (`LIBUS_ENABLE_LOGGING`,
  `LIBUS_LOG_RATE_LIMIT=64`) in `bsd.c`.
- **io_uring backend work** in `src/io_uring/` (`io_loop.c`, `io_socket.c`,
  `io_context.c`, `internal.h`) — the largest patch set (~2,100 lines).
- **epoll eventfd error checking** in `eventing/epoll_kqueue.c`.

## How to upgrade again

1. `git clone https://github.com/uNetworking/uSockets` and check out the new
   `master` HEAD; note its SHA for the base table above.
2. 3-way merge: base = the currently recorded upstream base tree, ours =
   `nim_usockets/usockets/src`, theirs = new upstream `src`.
3. Conflict policy: keep local hardening (ours) where both sides touch the same
   call site; take upstream for API/behavior changes, then update the Nim FFI
   (`nim_usockets/src/nim_usockets/usockets.nim`, `types.nim`) to match and fix
   any test constructing affected callbacks.
4. `make usockets` (rebuild `uSockets.a`), run `bash scripts/test_all.sh`
   (expect 0 failures) plus the graceful-shutdown stress test, and benchmark
   before/after if the delta touches `loop.c`/`socket.c`/`bsd.c`.
5. Update the base table here and `nim_usockets/AGENTS.md`.
