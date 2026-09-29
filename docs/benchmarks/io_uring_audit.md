# io_uring support audit

Date: 2026-03-08

## Current support status

`io_uring` support is present in vendored uSockets build and source tree, but should be treated as opt-in in benchmark paths.

## Evidence

- Build flag in vendored Makefile:
  - `nim_uwebsockets/usockets/Makefile`:
    - `WITH_IO_URING=1` section
    - defines `-DLIBUS_USE_IO_URING`
    - compiles `src/io_uring/*.c`
- Backend source tree exists:
  - `nim_uwebsockets/usockets/src/io_uring/io_loop.c`
  - `nim_uwebsockets/usockets/src/io_uring/io_context.c`
  - `nim_uwebsockets/usockets/src/io_uring/io_socket.c`
- Benchmark harness wiring:
  - `benchmark/run_linux_transport_ceiling.sh` supports backend switch and now defaults to epoll with explicit io_uring opt-in.

## Practical enablement path

1. Rebuild uSockets with io_uring backend:
   - `WITH_IO_URING=1 make -j$(nproc)` in `nim_uwebsockets/usockets`.
2. Rebuild benchmark app.
3. Run Linux transport ceiling with explicit opt-in:
   - `RUN_IO_URING=1 benchmark/run_linux_transport_ceiling.sh`
   - or `BACKENDS="epoll io_uring" benchmark/run_linux_transport_ceiling.sh`.

## Known caveats

- io_uring path stability/perf may vary by kernel and liburing version.
- Keep epoll as baseline reference in every run.
- Treat backend as experimental until Linux correctness + tail-latency gates pass across repeated runs.

## Recommendation

- Keep default backend `epoll` for predictable CI/perf baselines.
- Use io_uring only in explicit comparison runs with per-backend status + reason reporting.
