import std/unittest
import ../src/nim_usockets/usockets

suite "FFI — Event Loop function signatures":
  test "us_create_loop compiles with correct parameter types":
    when compiles((block:
      var p: UsLoopPtr
      p = us_create_loop(nil, nil, nil, nil, cuint(0))
    )):
      check true
    else:
      check false

  test "us_loop_free compiles with UsLoopPtr":
    static:
      doAssert compiles(us_loop_free(nil.UsLoopPtr))
    check true

  test "us_loop_ext returns pointer":
    static:
      doAssert compiles((block:
        let p: pointer = us_loop_ext(nil.UsLoopPtr)
      ))
    check true

  test "us_loop_run compiles with UsLoopPtr":
    static:
      doAssert compiles(us_loop_run(nil.UsLoopPtr))
    check true

  test "us_wakeup_loop compiles with UsLoopPtr":
    static:
      doAssert compiles(us_wakeup_loop(nil.UsLoopPtr))
    check true

  test "us_loop_integrate compiles with UsLoopPtr":
    static:
      doAssert compiles(us_loop_integrate(nil.UsLoopPtr))
    check true

  test "us_loop_iteration_number returns clonglong":
    static:
      doAssert compiles((block:
        let n: clonglong = us_loop_iteration_number(nil.UsLoopPtr)
      ))
    check true

suite "FFI — DNS function signatures":
  test "DnsResolveCallback type exists and has correct shape":
    var cb: DnsResolveCallback = proc(host: cstring, port: cint, success: cint, userData: pointer) {.cdecl.} = discard
    check cb != nil

  test "us_dns_resolve_async compiles with correct types":
    static:
      doAssert compiles(us_dns_resolve_async(nil.UsLoopPtr, "host", cint(80), nil, nil))
    check true

  test "us_dns_cache_clear compiles with no args":
    static:
      doAssert compiles(us_dns_cache_clear())
    check true

suite "FFI — Timer function signatures":
  test "us_create_timer compiles with loop, fallthrough, extSize":
    static:
      doAssert compiles((block:
        let t: UsTimerPtr = us_create_timer(nil.UsLoopPtr, cint(0), cuint(0))
      ))
    check true

  test "us_timer_ext returns pointer":
    static:
      doAssert compiles((block:
        let p: pointer = us_timer_ext(nil.UsTimerPtr)
      ))
    check true

  test "us_timer_close compiles with UsTimerPtr":
    static:
      doAssert compiles(us_timer_close(nil.UsTimerPtr))
    check true

  test "us_timer_set compiles with timer, callback, ms, repeatMs":
    static:
      doAssert compiles(us_timer_set(nil.UsTimerPtr, nil, cint(0), cint(0)))
    check true

  test "us_timer_loop returns UsLoopPtr":
    static:
      doAssert compiles((block:
        let lp: UsLoopPtr = us_timer_loop(nil.UsTimerPtr)
      ))
    check true

suite "FFI — Socket Context creation and destruction":
  test "us_create_socket_context compiles with correct types":
    static:
      doAssert compiles((block:
        let ctx: UsSocketContextPtr = us_create_socket_context(
          cint(0), nil.UsLoopPtr, cint(0), default(UsSocketContextOptions))
      ))
    check true

  test "us_socket_context_free compiles with ssl and context":
    static:
      doAssert compiles(us_socket_context_free(cint(0), nil.UsSocketContextPtr))
    check true

  test "us_socket_context_close compiles with ssl and context":
    static:
      doAssert compiles(us_socket_context_close(cint(0), nil.UsSocketContextPtr))
    check true

  test "us_socket_context_ext returns pointer":
    static:
      doAssert compiles((block:
        let p: pointer = us_socket_context_ext(cint(0), nil.UsSocketContextPtr)
      ))
    check true

  test "us_socket_context_loop returns UsLoopPtr":
    static:
      doAssert compiles((block:
        let lp: UsLoopPtr = us_socket_context_loop(cint(0), nil.UsSocketContextPtr)
      ))
    check true

  test "us_create_child_socket_context returns UsSocketContextPtr":
    static:
      doAssert compiles((block:
        let child: UsSocketContextPtr = us_create_child_socket_context(
          cint(0), nil.UsSocketContextPtr, cint(0))
      ))
    check true

  test "us_socket_context_timestamp returns cushort":
    static:
      doAssert compiles((block:
        let ts: cushort = us_socket_context_timestamp(cint(0), nil.UsSocketContextPtr)
      ))
    check true

  test "us_socket_context_get_native_handle returns pointer":
    static:
      doAssert compiles((block:
        let h: pointer = us_socket_context_get_native_handle(cint(0), nil.UsSocketContextPtr)
      ))
    check true

suite "FFI — Socket Context callback registration":
  test "us_socket_context_on_pre_open compiles":
    static:
      doAssert compiles(us_socket_context_on_pre_open(cint(0), nil.UsSocketContextPtr, nil))
    check true

  test "us_socket_context_on_open compiles":
    static:
      doAssert compiles(us_socket_context_on_open(cint(0), nil.UsSocketContextPtr, nil))
    check true

  test "us_socket_context_on_close compiles":
    static:
      doAssert compiles(us_socket_context_on_close(cint(0), nil.UsSocketContextPtr, nil))
    check true

  test "us_socket_context_on_data compiles":
    static:
      doAssert compiles(us_socket_context_on_data(cint(0), nil.UsSocketContextPtr, nil))
    check true

  test "us_socket_context_on_writable compiles":
    static:
      doAssert compiles(us_socket_context_on_writable(cint(0), nil.UsSocketContextPtr, nil))
    check true

  test "us_socket_context_on_timeout compiles":
    static:
      doAssert compiles(us_socket_context_on_timeout(cint(0), nil.UsSocketContextPtr, nil))
    check true

  test "us_socket_context_on_long_timeout compiles":
    static:
      doAssert compiles(us_socket_context_on_long_timeout(cint(0), nil.UsSocketContextPtr, nil))
    check true

  test "us_socket_context_on_connect_error compiles":
    static:
      doAssert compiles(us_socket_context_on_connect_error(cint(0), nil.UsSocketContextPtr, nil))
    check true

  test "us_socket_context_on_end compiles":
    static:
      doAssert compiles(us_socket_context_on_end(cint(0), nil.UsSocketContextPtr, nil))
    check true

  test "us_socket_context_on_server_name compiles":
    static:
      doAssert compiles(us_socket_context_on_server_name(cint(0), nil.UsSocketContextPtr, nil))
    check true

suite "FFI — Listen and Connect":
  test "us_socket_context_listen returns UsListenSocketPtr":
    static:
      doAssert compiles((block:
        let ls: UsListenSocketPtr = us_socket_context_listen(
          cint(0), nil.UsSocketContextPtr, "0.0.0.0", cint(3000), cint(0), cint(0))
      ))
    check true

  test "us_socket_context_listen_unix returns UsListenSocketPtr":
    static:
      doAssert compiles((block:
        let ls: UsListenSocketPtr = us_socket_context_listen_unix(
          cint(0), nil.UsSocketContextPtr, "/tmp/test.sock", cint(0), cint(0))
      ))
    check true

  test "us_listen_socket_close compiles with ssl and listen socket":
    static:
      doAssert compiles(us_listen_socket_close(cint(0), nil.UsListenSocketPtr))
    check true

  test "us_socket_context_connect returns UsSocketPtr":
    static:
      doAssert compiles((block:
        let s: UsSocketPtr = us_socket_context_connect(
          cint(0), nil.UsSocketContextPtr, "localhost", cint(80), nil, cint(0), cint(0))
      ))
    check true

  test "us_socket_context_connect_unix returns UsSocketPtr":
    static:
      doAssert compiles((block:
        let s: UsSocketPtr = us_socket_context_connect_unix(
          cint(0), nil.UsSocketContextPtr, "/tmp/test.sock", cint(0), cint(0))
      ))
    check true

  test "listen options can be passed as cint":
    static:
      doAssert compiles((block:
        let opts = cint(ord(loExclusivePort) or ord(loEpollExclusive))
        let ls: UsListenSocketPtr = us_socket_context_listen(
          cint(0), nil.UsSocketContextPtr, nil, cint(0), opts, cint(0))
      ))
    check true

suite "FFI — Socket operations":
  test "us_socket_is_established returns cint":
    static:
      doAssert compiles((block:
        let v: cint = us_socket_is_established(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_close_connecting returns UsSocketPtr":
    static:
      doAssert compiles((block:
        let s: UsSocketPtr = us_socket_close_connecting(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_context_adopt_socket returns UsSocketPtr":
    static:
      doAssert compiles((block:
        let s: UsSocketPtr = us_socket_context_adopt_socket(
          cint(0), nil.UsSocketContextPtr, nil.UsSocketPtr, cint(0))
      ))
    check true

  test "us_socket_get_native_handle returns pointer":
    static:
      doAssert compiles((block:
        let h: pointer = us_socket_get_native_handle(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_write returns cint":
    static:
      doAssert compiles((block:
        let n: cint = us_socket_write(cint(0), nil.UsSocketPtr, nil, cint(0), cint(0))
      ))
    check true

  test "us_socket_write2 returns cint":
    static:
      doAssert compiles((block:
        let n: cint = us_socket_write2(
          cint(0), nil.UsSocketPtr, nil, cint(0), nil, cint(0))
      ))
    check true

  test "us_socket_cork compiles":
    static:
      doAssert compiles(us_socket_cork(cint(0), nil.UsSocketPtr))
    check true

  test "us_socket_uncork compiles":
    static:
      doAssert compiles(us_socket_uncork(cint(0), nil.UsSocketPtr))
    check true

  test "us_socket_write2_unchecked returns cint":
    static:
      doAssert compiles((block:
        let n: cint = us_socket_write2_unchecked(nil.UsSocketPtr, nil, cint(0), nil, cint(0))
      ))
    check true

  test "us_socket_timeout compiles with ssl, socket, seconds":
    static:
      doAssert compiles(us_socket_timeout(cint(0), nil.UsSocketPtr, cuint(30)))
    check true

  test "us_socket_long_timeout compiles with ssl, socket, minutes":
    static:
      doAssert compiles(us_socket_long_timeout(cint(0), nil.UsSocketPtr, cuint(5)))
    check true

  test "us_socket_ext returns pointer":
    static:
      doAssert compiles((block:
        let p: pointer = us_socket_ext(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_context returns UsSocketContextPtr":
    static:
      doAssert compiles((block:
        let ctx: UsSocketContextPtr = us_socket_context(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_set_buffer_sizes compiles":
    static:
      doAssert compiles(us_socket_set_buffer_sizes(cint(0), nil.UsSocketPtr, cint(65536), cint(65536)))
    check true

  test "us_socket_flush compiles":
    static:
      doAssert compiles(us_socket_flush(cint(0), nil.UsSocketPtr))
    check true

  test "us_socket_shutdown compiles":
    static:
      doAssert compiles(us_socket_shutdown(cint(0), nil.UsSocketPtr))
    check true

  test "us_socket_shutdown_read compiles":
    static:
      doAssert compiles(us_socket_shutdown_read(cint(0), nil.UsSocketPtr))
    check true

  test "us_socket_is_shut_down returns cint":
    static:
      doAssert compiles((block:
        let v: cint = us_socket_is_shut_down(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_is_closed returns cint":
    static:
      doAssert compiles((block:
        let v: cint = us_socket_is_closed(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_close returns UsSocketPtr":
    static:
      doAssert compiles((block:
        let s: UsSocketPtr = us_socket_close(cint(0), nil.UsSocketPtr, cint(0), nil)
      ))
    check true

  test "us_socket_local_port returns cint":
    static:
      doAssert compiles((block:
        let p: cint = us_socket_local_port(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_remote_port returns cint":
    static:
      doAssert compiles((block:
        let p: cint = us_socket_remote_port(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_remote_address takes ptr char not cstring":
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

  test "us_socket_send_buffer returns cstring":
    static:
      doAssert compiles((block:
        let buf: cstring = us_socket_send_buffer(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_server_name_userdata returns pointer":
    static:
      doAssert compiles((block:
        let p: pointer = us_socket_server_name_userdata(cint(0), nil.UsSocketPtr)
      ))
    check true

  test "us_socket_context_find_server_name_userdata returns pointer":
    static:
      doAssert compiles((block:
        let p: pointer = us_socket_context_find_server_name_userdata(
          cint(0), nil.UsSocketContextPtr, "example.com")
      ))
    check true

  test "us_adopt_accepted_socket returns UsSocketPtr":
    static:
      doAssert compiles((block:
        let s: UsSocketPtr = us_adopt_accepted_socket(
          cint(0), nil.UsSocketContextPtr, SocketDescriptor(3), cuint(0), nil, cint(0))
      ))
    check true

  test "us_socket_get_alpn_protocol returns cstring with len out-param":
    static:
      doAssert compiles((block:
        var length: cuint
        let proto: cstring = us_socket_get_alpn_protocol(cint(0), nil.UsSocketPtr, addr length)
      ))
    check true

suite "FFI — SNI (Server Name Indication)":
  test "us_socket_context_add_server_name compiles":
    static:
      doAssert compiles(us_socket_context_add_server_name(
        cint(0), nil.UsSocketContextPtr, "*.example.com",
        default(UsSocketContextOptions), nil))
    check true

  test "us_socket_context_remove_server_name compiles":
    static:
      doAssert compiles(us_socket_context_remove_server_name(
        cint(0), nil.UsSocketContextPtr, "*.example.com"))
    check true

suite "FFI — Poll functions":
  test "us_create_poll returns UsPollPtr":
    static:
      doAssert compiles((block:
        let p: UsPollPtr = us_create_poll(nil.UsLoopPtr, cint(0), cuint(0))
      ))
    check true

  test "us_poll_free compiles":
    static:
      doAssert compiles(us_poll_free(nil.UsPollPtr, nil.UsLoopPtr))
    check true

  test "us_poll_init compiles with fd and pollType":
    static:
      doAssert compiles(us_poll_init(nil.UsPollPtr, SocketDescriptor(0), cint(0)))
    check true

  test "us_poll_start compiles":
    static:
      doAssert compiles(us_poll_start(nil.UsPollPtr, nil.UsLoopPtr, cint(0)))
    check true

  test "us_poll_change compiles":
    static:
      doAssert compiles(us_poll_change(nil.UsPollPtr, nil.UsLoopPtr, cint(0)))
    check true

  test "us_poll_stop compiles":
    static:
      doAssert compiles(us_poll_stop(nil.UsPollPtr, nil.UsLoopPtr))
    check true

  test "us_poll_events returns cint":
    static:
      doAssert compiles((block:
        let e: cint = us_poll_events(nil.UsPollPtr)
      ))
    check true

  test "us_poll_ext returns pointer":
    static:
      doAssert compiles((block:
        let p: pointer = us_poll_ext(nil.UsPollPtr)
      ))
    check true

  test "us_poll_fd returns SocketDescriptor":
    static:
      doAssert compiles((block:
        let fd: SocketDescriptor = us_poll_fd(nil.UsPollPtr)
      ))
    check true

  test "us_poll_resize returns UsPollPtr":
    static:
      doAssert compiles((block:
        let p: UsPollPtr = us_poll_resize(nil.UsPollPtr, nil.UsLoopPtr, cuint(64))
      ))
    check true

suite "FFI — UDP functions":
  test "us_create_udp_packet_buffer returns UsUdpPacketBufferPtr":
    static:
      doAssert compiles((block:
        let buf: UsUdpPacketBufferPtr = us_create_udp_packet_buffer()
      ))
    check true

  test "us_create_udp_socket compiles with all parameters":
    static:
      doAssert compiles((block:
        let s: UsUdpSocketPtr = us_create_udp_socket(
          nil.UsLoopPtr, nil.UsUdpPacketBufferPtr, nil, nil,
          "0.0.0.0", cushort(0), nil)
      ))
    check true

  test "us_udp_socket_user returns pointer":
    static:
      doAssert compiles((block:
        let p: pointer = us_udp_socket_user(nil.UsUdpSocketPtr)
      ))
    check true

  test "us_udp_socket_bind returns cint":
    static:
      doAssert compiles((block:
        let r: cint = us_udp_socket_bind(nil.UsUdpSocketPtr, "0.0.0.0", cuint(5000))
      ))
    check true

  test "us_udp_socket_bound_port returns cint":
    static:
      doAssert compiles((block:
        let p: cint = us_udp_socket_bound_port(nil.UsUdpSocketPtr)
      ))
    check true

  test "us_udp_socket_receive returns cint":
    static:
      doAssert compiles((block:
        let n: cint = us_udp_socket_receive(nil.UsUdpSocketPtr, nil.UsUdpPacketBufferPtr)
      ))
    check true

  test "us_udp_socket_send returns cint":
    static:
      doAssert compiles((block:
        let n: cint = us_udp_socket_send(nil.UsUdpSocketPtr, nil.UsUdpPacketBufferPtr, cint(0))
      ))
    check true

  test "us_udp_packet_buffer_payload returns cstring":
    static:
      doAssert compiles((block:
        let p: cstring = us_udp_packet_buffer_payload(nil.UsUdpPacketBufferPtr, cint(0))
      ))
    check true

  test "us_udp_packet_buffer_payload_length returns cint":
    static:
      doAssert compiles((block:
        let n: cint = us_udp_packet_buffer_payload_length(nil.UsUdpPacketBufferPtr, cint(0))
      ))
    check true

  test "us_udp_packet_buffer_local_ip takes ptr char (not cstring)":
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

  test "us_udp_packet_buffer_peer returns pointer":
    static:
      doAssert compiles((block:
        let p: pointer = us_udp_packet_buffer_peer(nil.UsUdpPacketBufferPtr, cint(0))
      ))
    check true

  test "us_udp_packet_buffer_ecn returns cint":
    static:
      doAssert compiles((block:
        let e: cint = us_udp_packet_buffer_ecn(nil.UsUdpPacketBufferPtr, cint(0))
      ))
    check true

  test "us_udp_buffer_set_packet_payload compiles":
    static:
      doAssert compiles(us_udp_buffer_set_packet_payload(
        nil.UsUdpPacketBufferPtr, cint(0), cint(0), nil, cint(0), nil))
    check true

suite "FFI — Iovec (non-Windows)":
  when not defined(windows):
    test "Iovec type exists with iov_base and iov_len":
      var iov: Iovec
      iov.iov_base = nil
      iov.iov_len = csize_t(0)
      check iov.iov_base == nil
      check iov.iov_len == csize_t(0)

    test "us_socket_writev_n compiles with correct types":
      static:
        doAssert compiles((block:
          var iov: Iovec
          let n: cint = us_socket_writev_n(cint(0), nil.UsSocketPtr, addr iov, cint(1), cint(0))
        ))
      check true

suite "FFI — SSL mode parameter consistency":
  test "NoSsl.toInt produces valid ssl parameter":
    let ssl = NoSsl.toInt
    static:
      doAssert compiles(us_create_socket_context(
        NoSsl.toInt, nil.UsLoopPtr, cint(0), default(UsSocketContextOptions)))
    check ssl == cint(0)

  test "UseSsl.toInt produces valid ssl parameter":
    let ssl = UseSsl.toInt
    static:
      doAssert compiles(us_create_socket_context(
        UseSsl.toInt, nil.UsLoopPtr, cint(0), default(UsSocketContextOptions)))
    check ssl == cint(1)

  test "ssl parameter accepted as cint(0) for all socket context operations":
    static:
      doAssert compiles(us_socket_context_free(cint(0), nil.UsSocketContextPtr))
      doAssert compiles(us_socket_context_close(cint(0), nil.UsSocketContextPtr))
      doAssert compiles(us_socket_context_ext(cint(0), nil.UsSocketContextPtr))
      doAssert compiles(us_socket_context_loop(cint(0), nil.UsSocketContextPtr))
    check true

suite "FFI — type re-exports from usockets module":
  test "usockets re-exports all types from types module":
    static:
      doAssert compiles(SslMode)
      doAssert compiles(NoSsl)
      doAssert compiles(UseSsl)
      doAssert compiles(ListenOptions)
      doAssert compiles(SocketDescriptor)
      doAssert compiles(UsSocketContextOptions)
      doAssert compiles(UsLoopPtr)
      doAssert compiles(UsTimerPtr)
      doAssert compiles(UsSocketContextPtr)
      doAssert compiles(UsSocketPtr)
      doAssert compiles(UsListenSocketPtr)
      doAssert compiles(UsPollPtr)
      doAssert compiles(UsUdpSocketPtr)
      doAssert compiles(UsUdpPacketBufferPtr)
      doAssert compiles(LoopWakeupCb)
      doAssert compiles(LoopPreCb)
      doAssert compiles(LoopPostCb)
      doAssert compiles(TimerCb)
      doAssert compiles(OnPreOpenCb)
      doAssert compiles(OnOpenCb)
      doAssert compiles(OnCloseCb)
      doAssert compiles(OnDataCb)
      doAssert compiles(OnWritableCb)
      doAssert compiles(OnTimeoutCb)
      doAssert compiles(OnConnectErrorCb)
      doAssert compiles(OnEndCb)
      doAssert compiles(OnServerNameCb)
      doAssert compiles(UdpDataCb)
      doAssert compiles(UdpDrainCb)
    check true
