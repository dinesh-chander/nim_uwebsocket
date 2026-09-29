import std/unittest
import ../src/nim_usockets/http

suite "Adaptive cork/coalesce policy":
  test "adaptive mode picks latency profile for small payloads":
    let server = newHttpServer()
    let limits = resolveWriteCoalesceLimits(
      server,
      pendingBytes = 0,
      pendingResponses = 1,
      payloadBytes = 1024,
      inWriteBatch = false
    )
    check limits.maxBytes == 16 * 1024
    check limits.maxResponses == 4

  test "adaptive mode picks balanced profile for medium payloads":
    let server = newHttpServer()
    let limits = resolveWriteCoalesceLimits(
      server,
      pendingBytes = 256 * 1024,
      pendingResponses = 16,
      payloadBytes = 8 * 1024,
      inWriteBatch = false
    )
    check limits.maxBytes == 64 * 1024
    check limits.maxResponses == 16

  test "adaptive mode picks throughput profile for large payloads":
    let server = newHttpServer()
    let limits = resolveWriteCoalesceLimits(
      server,
      pendingBytes = 256 * 1024,
      pendingResponses = 24,
      payloadBytes = 64 * 1024,
      inWriteBatch = false
    )
    check limits.maxBytes == 128 * 1024
    check limits.maxResponses == 32

  test "p99 guard clamps aggressive mode under low backlog":
    let server = newHttpServer()
    server.setWriteCoalesceMode(wcmThroughput)
    let limits = resolveWriteCoalesceLimits(
      server,
      pendingBytes = 8 * 1024,
      pendingResponses = 2,
      payloadBytes = 64 * 1024,
      inWriteBatch = false
    )
    check limits.maxBytes == 16 * 1024
    check limits.maxResponses == 4

  test "p99 guard does not clamp while write batch is active":
    let server = newHttpServer()
    server.setWriteCoalesceMode(wcmThroughput)
    let limits = resolveWriteCoalesceLimits(
      server,
      pendingBytes = 8 * 1024,
      pendingResponses = 2,
      payloadBytes = 64 * 1024,
      inWriteBatch = true
    )
    check limits.maxBytes == 128 * 1024
    check limits.maxResponses == 32

  test "config knobs clamp invalid values and preserve profile ordering":
    let server = newHttpServer()
    server.setWriteCoalesceLatencyLimits(512, 0)
    server.setWriteCoalesceLimits(0, 0)
    server.setWriteCoalesceThroughputLimits(2048, 2)
    server.setWriteCoalescePayloadThresholds(8 * 1024, 4 * 1024)
    server.setWriteCoalesceP99Guard(512, 0)
    check server.options.writeCoalesceLatencyMaxBytes == 1024
    check server.options.writeCoalesceLatencyMaxResponses == 1
    check server.options.writeCoalesceMaxBytes == 1024
    check server.options.writeCoalesceMaxResponses == 1
    check server.options.writeCoalesceThroughputMaxBytes == 2048
    check server.options.writeCoalesceThroughputMaxResponses == 2
    check server.options.writeCoalesceSmallPayloadBytes == 8 * 1024
    check server.options.writeCoalesceLargePayloadBytes == 8 * 1024
    check server.options.writeCoalesceP99GuardPendingBytes == 1024
    check server.options.writeCoalesceP99GuardPendingResponses == 1
