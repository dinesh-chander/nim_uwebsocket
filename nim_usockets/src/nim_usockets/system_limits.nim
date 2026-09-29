import std/strformat
import posix

when defined(linux):
  import std/strutils

when defined(macosx):
  proc sysctlbyname(
    name: cstring,
    oldp: pointer,
    oldlenp: ptr csize_t,
    newp: pointer,
    newlen: csize_t
  ): cint {.importc, header: "<sys/sysctl.h>".}

  proc getSysctlInt(name: string): int =
    var value: cint
    var size = csize_t(sizeof(cint))
    if sysctlbyname(name.cstring, addr value, addr size, nil, 0) == 0:
      return int(value)
    -1

when defined(linux):
  proc readProcInt(path: string): int =
    try:
      let content = readFile(path).strip()
      return parseInt(content)
    except CatchableError:
      return -1

  proc readProcIntTriple(path: string): tuple[low: int, pressure: int, high: int] =
    try:
      let content = readFile(path).strip()
      let parts = content.splitWhitespace()
      if parts.len >= 3:
        return (parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2]))
    except CatchableError:
      discard
    (-1, -1, -1)

proc getUlimitNoFile(): int =
  var rl: RLimit
  if getrlimit(RLIMIT_NOFILE, rl) == 0:
    return int(rl.rlim_cur)
  -1

proc getUlimitNoFileMax(): int =
  var rl: RLimit
  if getrlimit(RLIMIT_NOFILE, rl) == 0:
    return int(rl.rlim_max)
  -1

## Validates OS file descriptor and network limits against ``targetConnections`` and prints a warning for each value that is too low.
proc validateSystemLimits*(targetConnections: int) =
  let needed = targetConnections + targetConnections div 10 + 1024
  let neededFd = needed

  when defined(linux):
    let fileMax = readProcInt("/proc/sys/fs/file-max")
    if fileMax > 0 and fileMax < neededFd:
      stderr.writeLine &"WARNING: fs.file-max={fileMax} is below target {neededFd}. Run: sysctl -w fs.file-max={neededFd}"

    let nrOpen = readProcInt("/proc/sys/fs/nr_open")
    if nrOpen > 0 and nrOpen < neededFd:
      stderr.writeLine &"WARNING: fs.nr_open={nrOpen} is below target {neededFd}. Run: sysctl -w fs.nr_open={neededFd}"

    let ulimitCur = getUlimitNoFile()
    if ulimitCur > 0 and ulimitCur < neededFd:
      stderr.writeLine &"WARNING: ulimit -n={ulimitCur} is below target {neededFd}. Run: ulimit -n {neededFd}"
    let ulimitMax = getUlimitNoFileMax()
    if ulimitMax > 0 and ulimitMax < neededFd:
      stderr.writeLine &"WARNING: hard ulimit -Hn={ulimitMax} is below target {neededFd}. Raise LimitNOFILE or container nofile limit before setting ulimit -n."

    let somaxconn = readProcInt("/proc/sys/net/core/somaxconn")
    let neededBacklog = min(targetConnections, 65535)
    if somaxconn > 0 and somaxconn < neededBacklog:
      stderr.writeLine &"WARNING: net.core.somaxconn={somaxconn} is below target {neededBacklog}. Run: sysctl -w net.core.somaxconn={neededBacklog}"

    let tcpMem = readProcIntTriple("/proc/sys/net/ipv4/tcp_mem")
    let neededPages = targetConnections * 8
    if tcpMem.high > 0 and tcpMem.high < neededPages:
      let low = neededPages div 4
      let pressure = neededPages div 2
      stderr.writeLine &"WARNING: net.ipv4.tcp_mem high={tcpMem.high} pages is below target {neededPages}. Run: sysctl -w net.ipv4.tcp_mem=\"{low} {pressure} {neededPages}\""

    let tcpRmem = readProcIntTriple("/proc/sys/net/ipv4/tcp_rmem")
    if tcpRmem.high > 0 and tcpRmem.high < 4096:
      stderr.writeLine &"WARNING: net.ipv4.tcp_rmem max={tcpRmem.high} is below 4096. Run: sysctl -w net.ipv4.tcp_rmem=\"4096 4096 4096\""

    let tcpWmem = readProcIntTriple("/proc/sys/net/ipv4/tcp_wmem")
    if tcpWmem.high > 0 and tcpWmem.high < 4096:
      stderr.writeLine &"WARNING: net.ipv4.tcp_wmem max={tcpWmem.high} is below 4096. Run: sysctl -w net.ipv4.tcp_wmem=\"4096 4096 4096\""

    let rmemDefault = readProcInt("/proc/sys/net/core/rmem_default")
    if rmemDefault > 0 and rmemDefault > 8192:
      stderr.writeLine &"WARNING: net.core.rmem_default={rmemDefault} is higher than recommended 8192 for high connection counts. Run: sysctl -w net.core.rmem_default=8192"

    let wmemDefault = readProcInt("/proc/sys/net/core/wmem_default")
    if wmemDefault > 0 and wmemDefault > 8192:
      stderr.writeLine &"WARNING: net.core.wmem_default={wmemDefault} is higher than recommended 8192 for high connection counts. Run: sysctl -w net.core.wmem_default=8192"

  when defined(macosx):
    let maxFiles = getSysctlInt("kern.maxfiles")
    if maxFiles > 0 and maxFiles < neededFd:
      stderr.writeLine &"WARNING: kern.maxfiles={maxFiles} is below target {neededFd}. Run: sudo sysctl -w kern.maxfiles={neededFd}"

    let maxFilesPerProc = getSysctlInt("kern.maxfilesperproc")
    if maxFilesPerProc > 0 and maxFilesPerProc < neededFd:
      stderr.writeLine &"WARNING: kern.maxfilesperproc={maxFilesPerProc} is below target {neededFd}. Run: sudo sysctl -w kern.maxfilesperproc={neededFd}"

    let ulimitCur = getUlimitNoFile()
    if ulimitCur > 0 and ulimitCur < neededFd:
      stderr.writeLine &"WARNING: ulimit -n={ulimitCur} is below target {neededFd}. Run: ulimit -n {neededFd}"
    let ulimitMax = getUlimitNoFileMax()
    if ulimitMax > 0 and ulimitMax < neededFd:
      stderr.writeLine &"WARNING: hard ulimit -Hn={ulimitMax} is below target {neededFd}. Raise launchd/system limit before setting ulimit -n."

    let somaxconn = getSysctlInt("kern.ipc.somaxconn")
    let neededBacklog = min(targetConnections, 65535)
    if somaxconn > 0 and somaxconn < neededBacklog:
      stderr.writeLine &"WARNING: kern.ipc.somaxconn={somaxconn} is below target {neededBacklog}. Run: sudo sysctl -w kern.ipc.somaxconn={neededBacklog}"

## Returns a platform-specific sysctl settings block with recommended values for the given number of connections.
proc recommendedSysctlSettings*(targetConnections: int): string =
  let needed = targetConnections + targetConnections div 10 + 1024

  when defined(linux):
    let neededPages = targetConnections * 8
    let tcpMemLow = neededPages div 4
    let tcpMemPressure = neededPages div 2
    let neededBacklog = min(targetConnections, 65535)
    result = &"""# Recommended sysctl settings for {targetConnections} connections
fs.file-max = {needed}
fs.nr_open = {needed}
net.core.somaxconn = {neededBacklog}
net.ipv4.tcp_mem = {tcpMemLow} {tcpMemPressure} {neededPages}
net.ipv4.tcp_rmem = 4096 4096 4096
net.ipv4.tcp_wmem = 4096 4096 4096
net.core.rmem_default = 8192
net.core.wmem_default = 8192
"""

  when defined(macosx):
    let neededBacklog = min(targetConnections, 65535)
    result = &"""# Recommended sysctl settings for {targetConnections} connections
kern.maxfiles={needed}
kern.maxfilesperproc={needed}
kern.ipc.somaxconn={neededBacklog}
# Also run: ulimit -n {needed}
"""
