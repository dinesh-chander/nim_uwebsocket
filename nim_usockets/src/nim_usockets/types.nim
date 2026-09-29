## Common types for nim_usockets
## These are used across uSockets and uWebSockets bindings

type
  # Socket descriptor type — cint is correct for Unix/macOS (int).
  # On Windows this would need to be UINT_PTR (not currently supported).
  SocketDescriptor* = cint

  # SSL mode flag
  SslMode* = enum
    NoSsl = 0
    UseSsl = 1

  # Socket context options for SSL configuration
  UsSocketContextOptions* {.bycopy.} = object
    keyFileName*: cstring
    certFileName*: cstring
    passphrase*: cstring
    dhParamsFileName*: cstring
    caFileName*: cstring
    sslCiphers*: cstring
    sslPreferLowMemoryUsage*: cint

  ListenOptions* = enum
    loDefault = 0
    loExclusivePort = 2
    loEpollExclusive = 4
    loEpollEdgeTrigger = 8

  # Opaque pointer types for uSockets structures
  UsLoop* = object
  UsLoopPtr* = ptr UsLoop

  UsPoll* = object
  UsPollPtr* = ptr UsPoll

  UsTimer* = object
  UsTimerPtr* = ptr UsTimer

  UsSocketContext* = object
  UsSocketContextPtr* = ptr UsSocketContext

  UsSocket* = object
  UsSocketPtr* = ptr UsSocket

  UsListenSocket* = object
  UsListenSocketPtr* = ptr UsListenSocket

  UsUdpSocket* = object
  UsUdpSocketPtr* = ptr UsUdpSocket

  UsUdpPacketBuffer* = object
  UsUdpPacketBufferPtr* = ptr UsUdpPacketBuffer

  # Callback types for loop
  LoopWakeupCb* = proc(loop: UsLoopPtr) {.cdecl.}
  LoopPreCb* = proc(loop: UsLoopPtr) {.cdecl.}
  LoopPostCb* = proc(loop: UsLoopPtr) {.cdecl.}

  # Callback types for timer
  TimerCb* = proc(timer: UsTimerPtr) {.cdecl.}

  # Callback types for socket context
  OnPreOpenCb* = proc(context: UsSocketContextPtr, fd: SocketDescriptor,
    ip: cstring, ipLength: cint): SocketDescriptor {.cdecl.}
  OnOpenCb* = proc(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr {.cdecl.}
  OnCloseCb* = proc(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.}
  OnDataCb* = proc(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.}
  OnWritableCb* = proc(s: UsSocketPtr): UsSocketPtr {.cdecl.}
  OnTimeoutCb* = proc(s: UsSocketPtr): UsSocketPtr {.cdecl.}
  OnConnectErrorCb* = proc(s: UsSocketPtr, code: cint): UsSocketPtr {.cdecl.}
  OnEndCb* = proc(s: UsSocketPtr): UsSocketPtr {.cdecl.}
  OnServerNameCb* = proc(context: UsSocketContextPtr, hostname: cstring) {.cdecl.}

  # UDP callbacks
  UdpDataCb* = proc(s: UsUdpSocketPtr, buf: UsUdpPacketBufferPtr, packets: cint) {.cdecl.}
  UdpDrainCb* = proc(s: UsUdpSocketPtr) {.cdecl.}

# Helper to convert SslMode to cint
## Converts a `SslMode` value to its `cint` ordinal.
proc toInt*(mode: SslMode): cint {.inline.} = cint(ord(mode))

# Default empty options
## Returns a `UsSocketContextOptions` value with all fields set to nil or zero.
proc defaultSocketContextOptions*(): UsSocketContextOptions {.inline.} =
  result = UsSocketContextOptions(
    keyFileName: nil,
    certFileName: nil,
    passphrase: nil,
    dhParamsFileName: nil,
    caFileName: nil,
    sslCiphers: nil,
    sslPreferLowMemoryUsage: 0
  )
