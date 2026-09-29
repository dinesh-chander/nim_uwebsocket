import std/unittest

import ../src/nim_usockets/usockets

suite "FFI compliance — writable buffer parameters":
  test "us_udp_packet_buffer_local_ip ip param is ptr char":
    when compiles((block:
      proc check(buf: UsUdpPacketBufferPtr, index: cint, ip: ptr char): cint {.cdecl.} =
        us_udp_packet_buffer_local_ip(buf, index, ip)
    )):
      check true
    else:
      check false

    static:
      doAssert not compiles((block:
        proc check(buf: UsUdpPacketBufferPtr, index: cint, ip: cstring): cint {.cdecl.} =
          us_udp_packet_buffer_local_ip(buf, index, ip)
      ))

  test "us_socket_remote_address buf param is ptr char":
    when compiles((block:
      proc check(ssl: cint, s: UsSocketPtr, buf: ptr char, length: ptr cint) {.cdecl.} =
        us_socket_remote_address(ssl, s, buf, length)
    )):
      check true
    else:
      check false

    static:
      doAssert not compiles((block:
        proc check(ssl: cint, s: UsSocketPtr, buf: cstring, length: ptr cint) {.cdecl.} =
          us_socket_remote_address(ssl, s, buf, length)
      ))

suite "FFI compliance — ListenOptions enum":
  test "loDefault is 0":
    check ord(loDefault) == 0

  test "loExclusivePort is 2":
    check ord(loExclusivePort) == 2

  test "loExclusivePort is defined instead of loReuseAddr":
    static:
      doAssert not compiles(loReuseAddr)
    check true

  test "ListenOptions flags are bit-maskable":
    let combined = ord(loExclusivePort) or ord(loEpollExclusive)
    check combined == 6

suite "FFI compliance — SocketDescriptor platform type":
  test "SocketDescriptor is cint on Unix":
    when not defined(windows):
      static:
        doAssert SocketDescriptor is cint
      check true

  test "SocketDescriptor size matches cint":
    when not defined(windows):
      check sizeof(SocketDescriptor) == sizeof(cint)

suite "FFI compliance — UsSocketContextOptions layout":
  test "UsSocketContextOptions has all expected fields":
    var opts = UsSocketContextOptions()
    opts.keyFileName = nil
    opts.certFileName = nil
    opts.passphrase = nil
    opts.dhParamsFileName = nil
    opts.caFileName = nil
    opts.sslCiphers = nil
    opts.sslPreferLowMemoryUsage = 0
    check opts.sslPreferLowMemoryUsage == 0

  test "UsSocketContextOptions field count is 7":
    static:
      var count = 0
      for _ in default(UsSocketContextOptions).fields:
        inc count
      doAssert count == 7
    check true

  test "defaultSocketContextOptions returns zeroed struct":
    let opts = defaultSocketContextOptions()
    check opts.keyFileName == nil
    check opts.certFileName == nil
    check opts.passphrase == nil
    check opts.dhParamsFileName == nil
    check opts.caFileName == nil
    check opts.sslCiphers == nil
    check opts.sslPreferLowMemoryUsage == 0
