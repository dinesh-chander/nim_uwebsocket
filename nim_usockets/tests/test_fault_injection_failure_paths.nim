import std/unittest

include ../src/nim_usockets/http

when not defined(nimUwebsocketsTest):
  {.error: "Compile this test with -d:nimUwebsocketsTest".}

suite "Fault injection failure paths":
  test "short write plus forced close failure records deterministic close metrics":
    resetSocketFaultInjectionForTest()
    let server = newHttpServer()
    setInjectedWriteResultsForTest([3])
    setCloseSocketFailureForTest(true)

    let payload = "abcdef"
    let fakeSocket = cast[UsSocketPtr](cast[pointer](0x1))
    let written = writeFallbackPayloadAndMaybeClose(
      server,
      server.ssl.toInt,
      fakeSocket,
      payload,
      "fault_inject_short_write"
    )

    check written == 3
    check server.getSocketCloseAttemptCount() == 1
    check server.getSocketCloseFailureCount() == 1
    let snapshot = server.socketCloseOutcomeSnapshot()
    check snapshot.getOrDefault("fail:fault_inject_short_write", 0'i64) == 1'i64
    resetSocketFaultInjectionForTest()

  test "forced socket reset style close failure on direct fallback is tracked":
    resetSocketFaultInjectionForTest()
    let server = newHttpServer()
    setInjectedWriteResultsForTest([-1])
    setCloseSocketFailureForTest(true)

    let fakeSocket = cast[UsSocketPtr](cast[pointer](0x2))
    let written = writeFallbackDirectAndMaybeClose(
      server,
      0,
      fakeSocket,
      "H",
      "B",
      "fault_inject_direct_write"
    )

    check written == -1
    check server.getSocketCloseAttemptCount() == 1
    check server.getSocketCloseFailureCount() == 1
    let snapshot = server.socketCloseOutcomeSnapshot()
    check snapshot.getOrDefault("fail:fault_inject_direct_write", 0'i64) == 1'i64
    resetSocketFaultInjectionForTest()

  test "simulated tls merge allocation failure falls back to split writes":
    resetSocketFaultInjectionForTest()
    let server = newHttpServer()
    setTlsMergeAllocFailureForTest(true)
    setInjectedWriteResultsForTest([4, 6])

    let fakeSocket = cast[UsSocketPtr](cast[pointer](0x3))
    let written = writeDirect(server, 1, fakeSocket, "HEAD", "123456")
    check written == 10
    check server.getSocketCloseAttemptCount() == 0
    resetSocketFaultInjectionForTest()
