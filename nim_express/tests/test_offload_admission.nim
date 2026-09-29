import std/unittest

when defined(nimExpressOffloadTest):
  import std/[asyncdispatch, os, strutils]
  import ../src/nim_express/[offload, types]

  proc blockingSlow(): int =
    sleep(100)
    1

  proc blockingDouble(x: int): int =
    sleep(10)
    x * 2

suite "offload admission":
  when defined(nimExpressOffloadTest):
    test "offload admission rejects instead of blocking request path":
      check offloadAdmissionLimitForTest() == 1
      let first = runOffload(blockingSlow())
      let rejected = waitFor runOffloadOutcome("admission", "req-full", 100, blockingDouble(3))
      check rejected.kind == ookOffloadError
      check rejected.errorClass == "offload_error"
      check rejected.errorMessage.contains("offload queue full")
      discard waitFor first
      check offloadInFlightForTest() == 0
  else:
    test "offload admission regression is enabled only with nimExpressOffloadTest":
      check true
