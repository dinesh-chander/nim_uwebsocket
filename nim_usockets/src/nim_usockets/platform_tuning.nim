when defined(linux):
  import std/syncio
import posix

when defined(linux):
  const
    TCP_NOTSENT_LOWAT* = 25.cint
    SO_INCOMING_CPU* = 49.cint
    IP_BIND_ADDRESS_NO_PORT* = 24.cint

## Configures small socket buffers and the Linux `TCP_NOTSENT_LOWAT` watermark for high-connection servers.
proc applyHighScaleSocketOpts*(fd: cint) {.inline.} =
  let s = SocketHandle(fd)
  when defined(linux):
    var val: cint
    val = 2048
    discard setsockopt(s, SOL_SOCKET, SO_RCVBUF, addr val, SockLen(sizeof(val)))
    val = 2048
    discard setsockopt(s, SOL_SOCKET, SO_SNDBUF, addr val, SockLen(sizeof(val)))
    val = 16384
    discard setsockopt(s, IPPROTO_TCP, TCP_NOTSENT_LOWAT, addr val, SockLen(sizeof(val)))
  elif defined(macosx):
    var val: cint
    val = 2048
    discard setsockopt(s, SOL_SOCKET, SO_RCVBUF, addr val, SockLen(sizeof(val)))
    val = 2048
    discard setsockopt(s, SOL_SOCKET, SO_SNDBUF, addr val, SockLen(sizeof(val)))
  else:
    discard

## Sets `IP_BIND_ADDRESS_NO_PORT` on Linux so outbound connections reuse local ports without reserving them.
proc applyOutboundSocketOpts*(fd: cint) {.inline.} =
  when defined(linux):
    let s = SocketHandle(fd)
    var val: cint = 1
    discard setsockopt(s, IPPROTO_IP, IP_BIND_ADDRESS_NO_PORT, addr val, SockLen(sizeof(val)))
  else:
    discard

## Pins the current process to a single CPU core on Linux, a no-op on other platforms.
proc setProcessAffinity*(cpuId: int) {.inline.} =
  when defined(linux):
    proc sched_setaffinity(pid: Pid, cpusetsize: csize_t, mask: pointer): cint {.importc, header: "<sched.h>".}
    const CPU_SETSIZE = 1024
    const NCPUBITS = 64
    if cpuId < 0 or cpuId >= CPU_SETSIZE:
      return
    var cpuSet: array[CPU_SETSIZE div NCPUBITS, uint64]
    cpuSet[cpuId div NCPUBITS] = 1'u64 shl (cpuId mod NCPUBITS)
    discard sched_setaffinity(Pid(0), csize_t(sizeof(cpuSet)), addr cpuSet[0])
  else:
    discard

## Advises the Linux kernel to back the given memory range with transparent huge pages.
proc enableHugePages*(p: pointer, size: int) {.inline.} =
  when defined(linux):
    const MADV_HUGEPAGE = 14.cint
    proc madvise(addrArg: pointer, len: csize_t, advice: cint): cint {.importc, header: "<sys/mman.h>".}
    discard madvise(p, csize_t(size), MADV_HUGEPAGE)
  else:
    discard

## Raises the process open file descriptor limit to the given target and reports success.
proc setMaxOpenFiles*(target: int): bool {.inline.} =
  var rl: RLimit
  if getrlimit(RLIMIT_NOFILE, rl) != 0:
    return false
  rl.rlim_cur = target
  if rl.rlim_cur > rl.rlim_max:
    rl.rlim_max = rl.rlim_cur
  setrlimit(RLIMIT_NOFILE, rl) == 0

## Returns the current soft limit on open files, or -1 when the limit cannot be read.
proc currentMaxOpenFiles*(): int {.inline.} =
  var rl: RLimit
  if getrlimit(RLIMIT_NOFILE, rl) == 0:
    return rl.rlim_cur
  -1

## Writes Linux sysctl network values tuned for high-scale connection workloads, a no-op elsewhere.
proc applyLinuxNetworkTuning*() =
  when defined(linux):
    proc writeProc(path: string, value: string) =
      try:
        writeFile(path, value)
      except CatchableError:
        discard
    writeProc("/proc/sys/net/core/somaxconn", "65535")
    writeProc("/proc/sys/net/core/rmem_default", "2048")
    writeProc("/proc/sys/net/core/wmem_default", "2048")
    writeProc("/proc/sys/net/ipv4/tcp_rmem", "512 1024 4194304")
    writeProc("/proc/sys/net/ipv4/tcp_wmem", "512 1024 4194304")
    writeProc("/proc/sys/net/ipv4/tcp_mem", "786432 1048576 1572864")
    writeProc("/proc/sys/net/core/netdev_max_backlog", "65535")
  else:
    discard
