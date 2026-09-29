import std/[unittest, os, strutils]

suite "uSockets hardening":
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  let bsdSource = readFile(repoRoot / "nim_usockets/usockets/src/bsd.c")
  let udpSource = readFile(repoRoot / "nim_usockets/usockets/src/udp.c")
  let loopSource = readFile(repoRoot / "nim_usockets/usockets/src/loop.c")
  let internalHeader = readFile(repoRoot / "nim_usockets/usockets/src/internal/internal.h")
  let opensslSource = readFile(repoRoot / "nim_usockets/usockets/src/crypto/openssl.c")
  let epollSource = readFile(repoRoot / "nim_usockets/usockets/src/eventing/epoll_kqueue.c")
  let libuvSource = readFile(repoRoot / "nim_usockets/usockets/src/eventing/libuv.c")
  let gcdSource = readFile(repoRoot / "nim_usockets/usockets/src/eventing/gcd.c")
  let asioSource = readFile(repoRoot / "nim_usockets/usockets/src/eventing/asio.cpp")
  let httpSource = readFile(repoRoot / "nim_usockets/src/nim_usockets/http.nim")
  let usocketsMakefile = readFile(repoRoot / "nim_usockets/usockets/Makefile")
  let rootMakefile = readFile(repoRoot / "Makefile")
  let ioUringInternalHeader = readFile(repoRoot / "nim_usockets/usockets/src/io_uring/internal.h")
  let ioUringLoopSource = readFile(repoRoot / "nim_usockets/usockets/src/io_uring/io_loop.c")
  let ioUringContextSource = readFile(repoRoot / "nim_usockets/usockets/src/io_uring/io_context.c")
  let ioUringSocketSource = readFile(repoRoot / "nim_usockets/usockets/src/io_uring/io_socket.c")

  test "AF_UNIX path copy is bounded":
    check "static int bsd_copy_unix_path(" in bsdSource
    check "path_len == 0 || path_len >= sizeof(addr->sun_path)" in bsdSource
    check "strcpy(server_address.sun_path, path);" notin bsdSource
    check "strcpy(server_address.sun_path, server_path);" notin bsdSource

  test "TLS passphrase callback clamps and terminates":
    check "if (!buf" in opensslSource
    check "size <= 0" in opensslSource
    check "!u)" in opensslSource
    check "size_t max_copy = (size_t) (size - 1);" in opensslSource
    check "buf[passphrase_length] = '\\0';" in opensslSource

  test "SNI lookup path has no unconditional printf":
    check "printf(\"finding %s\\n\", hostname_pattern);" notin opensslSource

  test "poll resize/create paths guard allocation failures":
    check "if (!new_p) {" in epollSource
    check "if (!new_p) {" in libuvSource
    check "if (!new_p) {" in gcdSource
    check "if (!new_p) {" in asioSource
    check "if (!p) {" in epollSource
    check "if (!p) {" in libuvSource
    check "if (!poll) {" in gcdSource
    check "if (!p) {" in asioSource
    check "if (!p->uv_p) {" in libuvSource
    check "if (!p->boost_block) {" in asioSource

  test "connect paths handle immediate connect errors":
    check "static int bsd_connect_in_progress(void)" in bsdSource
    check "if (connect(fd, result->ai_addr, (socklen_t) result->ai_addrlen) == LIBUS_SOCKET_ERROR && !bsd_connect_in_progress()) {" in bsdSource
    check "if (connect(fd, (struct sockaddr *)&server_address, size) == LIBUS_SOCKET_ERROR && !bsd_connect_in_progress()) {" in bsdSource

  test "loop allocation and bootstrap paths are fail-closed":
    check "int us_internal_loop_data_init(struct us_loop_t *loop" in internalHeader
    check "if (!loop) {" in epollSource
    check "if (loop->fd == -1) {" in epollSource
    check "if (!us_internal_loop_data_init(loop, wakeup_cb, pre_cb, post_cb)) {" in epollSource
    check "if (!loop) {" in libuvSource
    check "if (!loop->uv_loop) {" in libuvSource
    check "if (!us_internal_loop_data_init(loop, wakeup_cb, pre_cb, post_cb)) {" in libuvSource
    check "if (!loop) {" in gcdSource
    check "if (!us_internal_loop_data_init(loop, wakeup_cb, pre_cb, post_cb)) {" in gcdSource
    check "if (!loop) {" in asioSource
    check "if (!loop->io) {" in asioSource
    check "if (!us_internal_loop_data_init(loop, wakeup_cb, pre_cb, post_cb)) {" in asioSource
    check "if (!loop->data.sweep_timer) {" in loopSource
    check "if (!loop->data.recv_buf) {" in loopSource
    check "if (!loop->data.wakeup_async) {" in loopSource
    check "if (loop->data.sweep_timer) {" in loopSource

  test "openssl loop and context setup guards fail closed":
    check "if (!loop || loop->data.ssl_data) {" in opensslSource
    check "if (!loop_ssl_data->shared_biom) {" in opensslSource
    check "if (!loop_ssl_data->shared_rbio || !loop_ssl_data->shared_wbio) {" in opensslSource
    check "if (!ssl_context) {" in opensslSource
    check "char *passphrase_copy = strdup(options.passphrase);" in opensslSource
    check "if (!passphrase_copy) {" in opensslSource
    check "const char *value = getenv(\"LIBUS_TLS_INSECURE_NO_VERIFY\");" in opensslSource
    check "SSL_set_verify(s->ssl, SSL_VERIFY_PEER, NULL);" in opensslSource
    check "SSL_set1_host(s->ssl, s->connect_hostname)" in opensslSource
    check "SSL_set_tlsext_host_name(s->ssl, s->connect_hostname)" in opensslSource
    check "s->connect_hostname = strdup(host);" in opensslSource

  test "udp packet-buffer allocations are guarded":
    check "if (LIBUS_UDP_MAX_NUM != 0 && ((size_t) LIBUS_UDP_MAX_SIZE) > (SIZE_MAX / (size_t) LIBUS_UDP_MAX_NUM)) {" in bsdSource
    check "if (sizeof(struct us_internal_udp_packet_buffer) > (SIZE_MAX - payload_bytes)) {" in bsdSource
    check "if (!b) {" in bsdSource
    check "if (!buf) {" in udpSource
    check "if (!p) {" in udpSource
    check "bsd_close_socket(fd);" in udpSource

  test "library logging is gated and raw prints are removed from udp paths":
    check "#define LIBUS_ENABLE_LOGGING 0" in bsdSource
    check "#define LIBUS_LOG_RATE_LIMIT 64u" in bsdSource
    check "LIBUS_LOG_WARN(\"Error setting IPv4 pktinfo!\\n\");" in bsdSource
    check "LIBUS_LOG_WARN(\"The port of UDP is: %d\\n\", cb->port);" in udpSource
    check "printf(\"The port of UDP is: %d\\n\", cb->port);" notin udpSource
    check "printf(\"Error setting IPv4 pktinfo!\\n\");" notin bsdSource

  test "io_uring direct slot allocation is bounded and recycled":
    check "#define LIBUS_IO_URING_MAX_CONNECTIONS 4096" in ioUringInternalHeader
    check "#define REGISTERED_FILES_COUNT MAX_CONNECTIONS" in ioUringInternalHeader
    check "unsigned char registered_fd_slot_used[REGISTERED_FILES_COUNT];" in ioUringInternalHeader
    check "int us_internal_allocate_registered_fd_slot(struct us_loop_t *loop)" in ioUringLoopSource
    check "void us_internal_mark_registered_fd_slot(struct us_loop_t *loop, int slot)" in ioUringLoopSource
    check "void us_internal_release_registered_fd_slot(struct us_loop_t *loop, int slot)" in ioUringLoopSource
    check "SOCKET_CLOSE" in ioUringInternalHeader
    check "unsigned char registered_fd_slot_closing[REGISTERED_FILES_COUNT];" in ioUringInternalHeader
    check "unsigned char registered_fd_slot_pending_close[REGISTERED_FILES_COUNT];" in ioUringInternalHeader
    check "int direct_slot = us_internal_allocate_registered_fd_slot(context->loop);" in ioUringContextSource
    check "us_internal_release_registered_fd_slot(context->loop, direct_slot);" in ioUringContextSource
    check "us_internal_queue_close_direct(s->context->loop, direct_slot);" in ioUringSocketSource
    check "us_internal_complete_close_direct(loop, slot);" in ioUringLoopSource

  test "io_uring connect waits for completion before open callback":
    check "us_internal_socket_queue_connect" in ioUringContextSource
    check "io_uring_prep_poll_add(sqe, fd, POLLOUT | POLLERR | POLLHUP);" in ioUringContextSource
    check "getsockopt(s->fd, SOL_SOCKET, SO_ERROR" in ioUringLoopSource
    check "s->context->on_open(s, 1, 0, 0);" in ioUringLoopSource
    check "context->on_open(s, 1, 0, 0);" notin ioUringContextSource

  test "io_uring write path preserves payloads larger than scratch buffer":
    check "char *write_data;" in ioUringInternalHeader
    check "char *write_buf;" in ioUringInternalHeader
    check "size_t write_buf_capacity;" in ioUringInternalHeader
    check "us_internal_socket_write_buffer" in ioUringSocketSource
    check "realloc(s->write_buf, (size_t) length)" in ioUringSocketSource
    check "us_internal_socket_try_direct_send" in ioUringSocketSource
    check "us_internal_socket_try_direct_writev" in ioUringSocketSource
    check "us_internal_socket_can_queue_fallback" in ioUringSocketSource
    check "io_uring_sq_space_left(&s->context->loop->ring)" in ioUringSocketSource
    check "us_internal_copy_iov_remaining" in ioUringSocketSource
    check "io_uring_prep_send(sqe, s->dd, buffer, (unsigned) length" in ioUringSocketSource
    check "io_uring_prep_send(sqe, s->dd, s->write_data + s->write_offset" in ioUringLoopSource
    check "us_internal_queue_closed_socket(context->loop, s);" in ioUringSocketSource
    check "if (s->closed || s->prev == (struct us_socket_t *) s->context)" in ioUringLoopSource
    check "if (s->read_pending || s->write_pending || s->connect_pending)" in ioUringLoopSource
    check "length = (int) sizeof(s->sendBuf)" notin ioUringSocketSource
    check "buf_len = (int) sizeof(s->sendBuf)" notin ioUringSocketSource
    check "us_internal_socket_free_write_buffer(s);" in ioUringLoopSource

  test "io_uring close waits for queued write completion":
    check "if (s->write_pending) {\n        s->close_pending = 1;\n        return s;\n    }" in ioUringSocketSource
    check "unsigned char write_drained_inline;" in ioUringInternalHeader
    check "s->write_drained_inline = 1;" in ioUringSocketSource
    check "if (s->write_drained_inline) {" in ioUringSocketSource
    check "if (s->close_pending) {\n                        bsd_shutdown_socket(s->fd);\n                    }" in ioUringLoopSource

  test "low-priority handshake budget is runtime configurable":
    check "#define LIBUS_LOW_PRIO_BUDGET_DEFAULT 5" in loopSource
    check "getenv(\"LIBUS_LOW_PRIO_BUDGET\")" in loopSource
    check "loop_data->low_prio_budget = us_internal_low_prio_budget_per_iteration();" in loopSource

  test "gcd backend lifecycle paths guard allocation and source creation":
    check "if (!loop) {" in gcdSource
    check "if (!us_internal_loop_data_init(loop, wakeup_cb, pre_cb, post_cb)) {" in gcdSource
    check "if (!cb) {" in gcdSource
    check "if (!(*gcd_timer)) {" in gcdSource
    check "dispatch_source_set_cancel_handler_f(*gcd_timer, gcd_timer_cancel_handler);" in gcdSource
    check "internal_cb->closed = 1;" in gcdSource
    check "if (!new_p) {\n        return 0;" in gcdSource

  test "loop-thread affinity and cross-thread marshaling are enforced":
    check "proc assertMacosGcdServerMainThread*(operation: string)" in httpSource
    check "pthread_main_np() == 0.cint" in httpSource
    check "assertMacosGcdServerMainThread(\"HttpServer.listen\")" in httpSource
    check "assertMacosGcdServerMainThread(\"HttpServer.run\")" in httpSource
    check "proc assertLoopAffinity(server: HttpServer, operation: string)" in httpSource
    check "proc assertResponseLoopAffinity(res: HttpResponse, operation: string)" in httpSource
    check "proc assertWebSocketLoopAffinity(ws: WebSocket, operation: string)" in httpSource
    check "proc deferFromAnyThread*(server: HttpServer, callback: TimerCallback)" in httpSource
    check "proc enqueueCrossThreadDeferred(server: HttpServer, callback: TimerCallback)" in httpSource
    check "proc tryQueueDeferredPreFromAnyThread*(server: HttpServer, callback: TimerCallback): bool" in httpSource
    check "crossThreadDeferWakeRefs: int" in httpSource
    check "proc wakeCrossThreadLoop(server: HttpServer, loop: UsLoopPtr)" in httpSource
    check "server.waitForCrossThreadWakeRefs()" in httpSource
    check "proc scheduleShutdownOnOwnerLoop(server: HttpServer): bool" in httpSource
    check "return server.tryQueueDeferredPreFromAnyThread(proc() =" in httpSource
    check "sockData.ws.socket = nil" in httpSource

  test "quic remains explicit opt-in in bundled usockets build":
    check "ifeq ($(WITH_QUIC),1)" in usocketsMakefile
    check "-DLIBUS_USE_QUIC" in usocketsMakefile
    check "WITH_QUIC=1" notin rootMakefile
