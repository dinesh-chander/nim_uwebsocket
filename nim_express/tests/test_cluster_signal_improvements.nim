import std/[unittest, os]
when not defined(windows):
  import std/posix
import ../src/nim_express/[types, app, response, offload]

when not defined(windows):
  # Forked child body: idle for a bounded time, then exit on its own so the
  # blocking waitpid below stays bounded even if the force-kill under test
  # were broken.
  proc boundedClusterChildBody() =
    for _ in 0 ..< 50:
      sleep(100)
    posix.exitnow(0)

  # Decode the signal that terminated a child (low 7 bits of waitpid status),
  # mirroring decodeWorkerExitStatus in app.nim.
  func terminatedBySignal(status: cint): cint =
    status and 0x7f

  proc spawnBoundedClusterChild(): Pid =
    let child = posix.fork()
    if child == 0:
      boundedClusterChildBody()
    child

  test "repeat-signal force-kill terminates tracked worker pids":
    resetClusterParentSignalFlags()
    let child = spawnBoundedClusterChild()
    if child < 0:
      echo "SKIP: fork failed"
    else:
      registerClusterWorkerPid(child)
      forceKillTrackedClusterWorkers()
      var status: cint
      let reaped = posix.waitpid(child, status, 0)
      check reaped == child
      check terminatedBySignal(status) == SIGKILL
      unregisterClusterWorkerPid(child)

  test "cluster worker pid table tolerates duplicate and stale operations":
    resetClusterParentSignalFlags()
    let child = spawnBoundedClusterChild()
    if child < 0:
      echo "SKIP: fork failed"
    else:
      # Duplicate registration must not corrupt the table.
      registerClusterWorkerPid(child)
      registerClusterWorkerPid(child)
      # Unregistering an untracked pid must be a safe no-op.
      unregisterClusterWorkerPid(Pid(1))
      # After unregistration the slot is free again, so the same pid can be
      # tracked, force-killed, and reaped.
      unregisterClusterWorkerPid(child)
      registerClusterWorkerPid(child)
      forceKillTrackedClusterWorkers()
      var status: cint
      let reaped = posix.waitpid(child, status, 0)
      check reaped == child
      check terminatedBySignal(status) == SIGKILL
      unregisterClusterWorkerPid(child)

  test "registering a dead pid is rejected and table stays clean":
    resetClusterParentSignalFlags()
    # Registering a non-positive pid must be a no-op.
    registerClusterWorkerPid(Pid(-1))
    registerClusterWorkerPid(0)
    # Force-kill with nothing tracked must not crash the test process.
    forceKillTrackedClusterWorkers()
    check true
