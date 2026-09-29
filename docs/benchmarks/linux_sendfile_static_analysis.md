# Linux sendfile static validation (no runtime execution)

Date: 2026-03-08

## Scope

Static validation of Linux file-send path wiring in `nim_usockets` and framework call sites.

## Trace

1. Framework/API entrypoint:
   - `nim_usockets/src/nim_usockets/http.nim:2391` `sendFilePreparedResponse`
2. Platform gate:
   - Now enabled for `linux` and `macosx` (`when not (defined(macosx) or defined(linux))` short-circuit only for unsupported OSes).
3. Queued write file-body branch:
   - `nim_usockets/src/nim_usockets/http.nim:1733` file branch
   - `nim_usockets/src/nim_usockets/http.nim:1754` Linux branch
   - `nim_usockets/src/nim_usockets/http.nim:1759` `linuxSendfile(...)`
4. Native handle dependency:
   - `us_socket_get_native_handle(...)` validated before `sendfile` call.
5. Fallback behavior:
   - Non-SSL + valid fd path attempts sendfile.
   - SSL, invalid fd, or unsupported platform returns to normal queued write handling (no undefined path).

## Correctness checks

- Partial writes:
  - `sent > 0` updates `fileOffset`, `fileRemaining`, and `tryEnd` progress.
- Backpressure / would-block:
  - `EAGAIN` / `EWOULDBLOCK` returns `false` to keep response queued for writable callback.
- EOF handling:
  - `sent == 0` treats completion based on `fileRemaining`.
- Error handling:
  - Non-retriable sendfile errors return `true` from file branch to avoid tight retry loops; queued lifecycle remains responsible for socket state progression.

## Risks

- Linux-only behavior still depends on event-loop/write lifecycle tests for large file + slow client scenarios.
- No TLS sendfile path (expected); TLS remains buffered path.

## Recommendation

- Keep this static validation as gate before Linux runtime benchmark.
- Run Linux integration checks for:
  - 1MB static file transfer checksum
  - slow-client partial-write behavior
  - `Connection: close` completion semantics
