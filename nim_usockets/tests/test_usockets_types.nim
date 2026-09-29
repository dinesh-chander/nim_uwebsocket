import std/unittest
import ../src/nim_usockets/types

suite "SslMode enum":
  test "NoSsl ordinal is 0":
    check ord(NoSsl) == 0

  test "UseSsl ordinal is 1":
    check ord(UseSsl) == 1

  test "SslMode has exactly 2 values":
    static:
      var count = 0
      for _ in SslMode:
        inc count
      doAssert count == 2
    check true

  test "toInt converts NoSsl to cint 0":
    check NoSsl.toInt == cint(0)

  test "toInt converts UseSsl to cint 1":
    check UseSsl.toInt == cint(1)

  test "toInt return type is cint":
    let val = NoSsl.toInt
    check val is cint

suite "ListenOptions enum":
  test "loDefault ordinal is 0":
    check ord(loDefault) == 0

  test "loExclusivePort ordinal is 2":
    check ord(loExclusivePort) == 2

  test "loEpollExclusive ordinal is 4":
    check ord(loEpollExclusive) == 4

  test "loEpollEdgeTrigger ordinal is 8":
    check ord(loEpollEdgeTrigger) == 8

  test "ListenOptions has exactly 4 values":
    static:
      doAssert low(ListenOptions) == loDefault
      doAssert high(ListenOptions) == loEpollEdgeTrigger
    check true

  test "loExclusivePort OR loEpollExclusive produces 6":
    let combined = ord(loExclusivePort) or ord(loEpollExclusive)
    check combined == 6

  test "all flags OR'd together produces 14":
    let all = ord(loExclusivePort) or ord(loEpollExclusive) or ord(loEpollEdgeTrigger)
    check all == 14

  test "loDefault OR any flag equals that flag":
    check (ord(loDefault) or ord(loEpollEdgeTrigger)) == ord(loEpollEdgeTrigger)

  test "flags do not overlap (each is a distinct power of 2 or 0)":
    let vals = [ord(loExclusivePort), ord(loEpollExclusive), ord(loEpollEdgeTrigger)]
    for i in 0..<vals.len:
      for j in (i+1)..<vals.len:
        check (vals[i] and vals[j]) == 0

suite "SocketDescriptor type":
  test "SocketDescriptor is cint on non-Windows":
    when not defined(windows):
      static:
        doAssert SocketDescriptor is cint
      check true

  test "SocketDescriptor size matches cint":
    when not defined(windows):
      check sizeof(SocketDescriptor) == sizeof(cint)

  test "SocketDescriptor can hold typical fd values":
    when not defined(windows):
      var fd: SocketDescriptor = 0
      check fd == 0
      fd = 3
      check fd == 3
      fd = -1
      check fd == -1

suite "UsSocketContextOptions struct":
  test "default constructor zeroes all fields":
    var opts = UsSocketContextOptions()
    check opts.keyFileName == nil
    check opts.certFileName == nil
    check opts.passphrase == nil
    check opts.dhParamsFileName == nil
    check opts.caFileName == nil
    check opts.sslCiphers == nil
    check opts.sslPreferLowMemoryUsage == 0

  test "field count is exactly 7":
    static:
      var count = 0
      for _ in default(UsSocketContextOptions).fields:
        inc count
      doAssert count == 7
    check true

  test "cstring fields are assignable":
    var opts = UsSocketContextOptions()
    opts.keyFileName = "key.pem"
    opts.certFileName = "cert.pem"
    opts.passphrase = "secret"
    opts.dhParamsFileName = "dhparams.pem"
    opts.caFileName = "ca.pem"
    opts.sslCiphers = "ECDHE-RSA-AES256-GCM-SHA384"
    check opts.keyFileName == "key.pem"
    check opts.certFileName == "cert.pem"
    check opts.passphrase == "secret"
    check opts.dhParamsFileName == "dhparams.pem"
    check opts.caFileName == "ca.pem"
    check opts.sslCiphers == "ECDHE-RSA-AES256-GCM-SHA384"

  test "sslPreferLowMemoryUsage accepts 0 and 1":
    var opts = UsSocketContextOptions()
    opts.sslPreferLowMemoryUsage = 0
    check opts.sslPreferLowMemoryUsage == 0
    opts.sslPreferLowMemoryUsage = 1
    check opts.sslPreferLowMemoryUsage == 1

  test "struct is bycopy (value semantics)":
    var a = UsSocketContextOptions()
    a.keyFileName = "a.pem"
    a.sslPreferLowMemoryUsage = 1
    var b = a
    b.keyFileName = "b.pem"
    b.sslPreferLowMemoryUsage = 0
    check a.keyFileName == "a.pem"
    check a.sslPreferLowMemoryUsage == 1
    check b.keyFileName == "b.pem"
    check b.sslPreferLowMemoryUsage == 0

suite "defaultSocketContextOptions helper":
  test "returns struct with all nil cstrings":
    let opts = defaultSocketContextOptions()
    check opts.keyFileName == nil
    check opts.certFileName == nil
    check opts.passphrase == nil
    check opts.dhParamsFileName == nil
    check opts.caFileName == nil
    check opts.sslCiphers == nil

  test "returns struct with sslPreferLowMemoryUsage == 0":
    let opts = defaultSocketContextOptions()
    check opts.sslPreferLowMemoryUsage == 0

  test "multiple calls return independent copies":
    var a = defaultSocketContextOptions()
    var b = defaultSocketContextOptions()
    a.keyFileName = "modified.pem"
    check b.keyFileName == nil

suite "Opaque pointer types — size and nil":
  test "UsLoopPtr is pointer-sized":
    check sizeof(UsLoopPtr) == sizeof(pointer)

  test "UsTimerPtr is pointer-sized":
    check sizeof(UsTimerPtr) == sizeof(pointer)

  test "UsSocketContextPtr is pointer-sized":
    check sizeof(UsSocketContextPtr) == sizeof(pointer)

  test "UsSocketPtr is pointer-sized":
    check sizeof(UsSocketPtr) == sizeof(pointer)

  test "UsListenSocketPtr is pointer-sized":
    check sizeof(UsListenSocketPtr) == sizeof(pointer)

  test "UsPollPtr is pointer-sized":
    check sizeof(UsPollPtr) == sizeof(pointer)

  test "UsUdpSocketPtr is pointer-sized":
    check sizeof(UsUdpSocketPtr) == sizeof(pointer)

  test "UsUdpPacketBufferPtr is pointer-sized":
    check sizeof(UsUdpPacketBufferPtr) == sizeof(pointer)

  test "nil UsLoopPtr is valid":
    var p: UsLoopPtr = nil
    check p == nil

  test "nil UsSocketPtr is valid":
    var p: UsSocketPtr = nil
    check p == nil

  test "nil UsSocketContextPtr is valid":
    var p: UsSocketContextPtr = nil
    check p == nil

  test "nil UsListenSocketPtr is valid":
    var p: UsListenSocketPtr = nil
    check p == nil

  test "nil UsTimerPtr is valid":
    var p: UsTimerPtr = nil
    check p == nil

  test "nil UsUdpSocketPtr is valid":
    var p: UsUdpSocketPtr = nil
    check p == nil

  test "nil UsUdpPacketBufferPtr is valid":
    var p: UsUdpPacketBufferPtr = nil
    check p == nil

suite "Callback type signatures — compile-time verification":
  test "LoopWakeupCb accepts proc(UsLoopPtr){.cdecl.}":
    var cb: LoopWakeupCb = proc(loop: UsLoopPtr) {.cdecl.} = discard
    check cb != nil

  test "LoopPreCb accepts proc(UsLoopPtr){.cdecl.}":
    var cb: LoopPreCb = proc(loop: UsLoopPtr) {.cdecl.} = discard
    check cb != nil

  test "LoopPostCb accepts proc(UsLoopPtr){.cdecl.}":
    var cb: LoopPostCb = proc(loop: UsLoopPtr) {.cdecl.} = discard
    check cb != nil

  test "TimerCb accepts proc(UsTimerPtr){.cdecl.}":
    var cb: TimerCb = proc(timer: UsTimerPtr) {.cdecl.} = discard
    check cb != nil

  test "OnPreOpenCb has correct signature":
    var cb: OnPreOpenCb = proc(ctx: UsSocketContextPtr, fd: SocketDescriptor, ip: cstring, ipLength: cint): SocketDescriptor {.cdecl.} = fd
    check cb != nil

  test "OnOpenCb has correct signature":
    var cb: OnOpenCb = proc(s: UsSocketPtr, isClient: cint, ip: cstring, ipLen: cint): UsSocketPtr {.cdecl.} = s
    check cb != nil

  test "OnCloseCb has correct signature":
    var cb: OnCloseCb = proc(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.} = s
    check cb != nil

  test "OnDataCb has correct signature":
    var cb: OnDataCb = proc(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} = s
    check cb != nil

  test "OnWritableCb has correct signature":
    var cb: OnWritableCb = proc(s: UsSocketPtr): UsSocketPtr {.cdecl.} = s
    check cb != nil

  test "OnTimeoutCb has correct signature":
    var cb: OnTimeoutCb = proc(s: UsSocketPtr): UsSocketPtr {.cdecl.} = s
    check cb != nil

  test "OnConnectErrorCb has correct signature":
    var cb: OnConnectErrorCb = proc(s: UsSocketPtr, code: cint): UsSocketPtr {.cdecl.} = s
    check cb != nil

  test "OnEndCb has correct signature":
    var cb: OnEndCb = proc(s: UsSocketPtr): UsSocketPtr {.cdecl.} = s
    check cb != nil

  test "OnServerNameCb has correct signature":
    var cb: OnServerNameCb = proc(ctx: UsSocketContextPtr, hostname: cstring) {.cdecl.} = discard
    check cb != nil

  test "UdpDataCb has correct signature":
    var cb: UdpDataCb = proc(s: UsUdpSocketPtr, buf: UsUdpPacketBufferPtr, packets: cint) {.cdecl.} = discard
    check cb != nil

  test "UdpDrainCb has correct signature":
    var cb: UdpDrainCb = proc(s: UsUdpSocketPtr) {.cdecl.} = discard
    check cb != nil

  test "callback types are pointer-sized":
    check sizeof(LoopWakeupCb) == sizeof(pointer)
    check sizeof(TimerCb) == sizeof(pointer)
    check sizeof(OnOpenCb) == sizeof(pointer)
    check sizeof(OnCloseCb) == sizeof(pointer)
    check sizeof(OnDataCb) == sizeof(pointer)
    check sizeof(UdpDataCb) == sizeof(pointer)
    check sizeof(UdpDrainCb) == sizeof(pointer)

  test "nil callback assignments are valid":
    var cb1: LoopWakeupCb = nil
    var cb2: TimerCb = nil
    var cb3: OnOpenCb = nil
    var cb4: UdpDataCb = nil
    check cb1 == nil
    check cb2 == nil
    check cb3 == nil
    check cb4 == nil
