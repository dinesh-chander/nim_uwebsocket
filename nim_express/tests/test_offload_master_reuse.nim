import std/unittest

when defined(nimExpressOffloadTest):
  import std/[asyncdispatch, os]
  import ../src/nim_express/[offload, types]

  proc blockingDouble(x: int): int =
    sleep(2)
    x * 2

  suite "offload master reuse":
    when defined(nimExpressOffloadTest):
      test "runOffload reuses one malebolgia master per thread (no use-after-free)":
        # Regression: the pool master used to be allocated per call and freed
        # as soon as the result was published, while a malebolgia worker still
        # touched the master lock (taskCompleted) afterwards. Destroying that
        # live mutex aborted inside glibc:
        #   pthread_mutex_lock ... assertion failed: mutex->__data.__owner == 0
        #   (robust variant: assertion failed: e != ESRCH || !robust)
        let a = waitFor runOffload(blockingDouble(1))
        check a == 2
        let first = offloadMasterPtrForTest()
        check first != nil

        let b = waitFor runOffload(blockingDouble(21))
        check b == 42
        check offloadMasterPtrForTest() == first

        # Enough round trips to exercise the worker -> master-lock path.
        for i in 0 ..< 2000:
          check waitFor(runOffload(blockingDouble(i))) == i * 2
        check offloadMasterPtrForTest() == first

        # Concurrent round trips sharing the same thread master.
        var futs: seq[Future[int]] = @[]
        for i in 0 ..< 10:
          futs.add runOffload(blockingDouble(i))
        for i, f in futs:
          check waitFor(f) == i * 2
        check offloadMasterPtrForTest() == first
    else:
      test "offload master reuse regression is enabled only with nimExpressOffloadTest":
        check true
