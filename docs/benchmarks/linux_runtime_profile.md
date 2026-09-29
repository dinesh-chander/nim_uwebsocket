# Linux Runtime Profile (Throughput-Oriented)

This profile is the recommended production baseline for high-throughput deployments.
macOS remains primarily a development/validation target.

## Process model

- Prefer multi-process on Linux with `runAuto` / `runCluster`.
- Start workers close to physical core count (or `~40%` default if not tuned yet).
- Keep one event loop per worker process.

## Socket and loop tuning

- `setSocketTunables(noDelay=true, keepAlive=true, keepAliveSeconds=60, fastOpen=true)`
- `setWriteCoalesceLimits(maxBytes=131072, maxResponses=32)`
- `setParseFairnessBudget(requestsPerRead=64, bytesPerRead=1048576)`
- `setAdaptiveReadBuffer(minCapacity=4096, maxCapacity=1048576, shrinkPercent=20)`
- `setMaxPendingBytesPerSocket(1048576)`

## Overload guardrails

- Enable overload controller in production:
  - `setOverloadController(maxBacklogBytes=8 * 1024 * 1024, maxPendingResponses=4096, closeOnReject=false)`
- Track counters:
  - parser errors
  - overload rejects
  - write retries
  - backpressure drops

## Build guidance

- Linux perf builds should use `release + danger + ARC + LTO + jemalloc`.
- Keep benchmark flags and production flags aligned when comparing revisions.

## Notes

- macOS can run the same code paths but does not represent Linux throughput ceilings.
- For peak throughput validation, always benchmark on Linux with the same worker model and connection profile.
