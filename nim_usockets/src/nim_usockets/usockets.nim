## Low-level FFI bindings for uSockets
##
## uSockets is the networking foundation that uWebSockets builds upon.
## These bindings provide direct access to the C API.
##
## Link with: --passL:"path/to/uSockets.a" or --passL:"-lusockets"

import types
export types

# Use static linking - library is linked at compile time via --passL flag
{.push cdecl.}

# =============================================================================
# Event Loop Functions
# =============================================================================

## Create a new uSockets event loop with the given callbacks and extension size.
proc us_create_loop*(
  hint: pointer,
  wakeupCb: LoopWakeupCb,
  preCb: LoopPreCb,
  postCb: LoopPostCb,
  extSize: cuint
): UsLoopPtr {.importc.}

## Free an event loop and release its associated resources.
proc us_loop_free*(loop: UsLoopPtr) {.importc.}

## Return the user extension data attached to an event loop.
proc us_loop_ext*(loop: UsLoopPtr): pointer {.importc.}

## Run the event loop until it is stopped.
proc us_loop_run*(loop: UsLoopPtr) {.importc.}

## Stop a running event loop.
proc us_loop_stop*(loop: UsLoopPtr) {.importc.}

## Wake up the event loop so pending callbacks are processed.
proc us_wakeup_loop*(loop: UsLoopPtr) {.importc.}

type
  DnsResolveCallback* = proc(host: cstring, port: cint, success: cint, userData: pointer) {.cdecl.}

## Resolve a host asynchronously and invoke ``callback`` with the result.
proc us_dns_resolve_async*(loop: UsLoopPtr, host: cstring, port: cint,
  callback: DnsResolveCallback, userData: pointer) {.importc.}
## Clear the internal DNS resolution cache.
proc us_dns_cache_clear*() {.importc.}

## Integrate the loop with an external event loop for manual polling.
proc us_loop_integrate*(loop: UsLoopPtr) {.importc.}

## Return the current iteration number of the event loop.
proc us_loop_iteration_number*(loop: UsLoopPtr): clonglong {.importc.}

# =============================================================================
# Timer Functions
# =============================================================================

## Create a new timer attached to the given event loop.
proc us_create_timer*(
  loop: UsLoopPtr,
  fallthrough: cint,
  extSize: cuint
): UsTimerPtr {.importc.}

## Return the user extension data attached to a timer.
proc us_timer_ext*(timer: UsTimerPtr): pointer {.importc.}

## Close and free a timer.
proc us_timer_close*(timer: UsTimerPtr) {.importc.}

## Arm a timer to fire ``cb`` after ``ms`` with an optional ``repeatMs`` interval.
proc us_timer_set*(
  timer: UsTimerPtr,
  cb: TimerCb,
  ms: cint,
  repeatMs: cint
) {.importc.}

## Return the event loop a timer is attached to.
proc us_timer_loop*(timer: UsTimerPtr): UsLoopPtr {.importc.}

# =============================================================================
# Socket Context Functions
# =============================================================================

## Create a socket context for TCP or UDP sockets with the given options.
proc us_create_socket_context*(
  ssl: cint,
  loop: UsLoopPtr,
  extSize: cint,
  options: UsSocketContextOptions
): UsSocketContextPtr {.importc.}

## Free a socket context and release its resources.
proc us_socket_context_free*(
  ssl: cint,
  context: UsSocketContextPtr
) {.importc.}

## Register a callback invoked before a socket opens.
proc us_socket_context_on_pre_open*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnPreOpenCb
) {.importc.}

## Register a callback invoked when a socket opens.
proc us_socket_context_on_open*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnOpenCb
) {.importc.}

## Register a callback invoked when a socket closes.
proc us_socket_context_on_close*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnCloseCb
) {.importc.}

## Register a callback invoked when data arrives on a socket.
proc us_socket_context_on_data*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnDataCb
) {.importc.}

## Register a callback invoked when a socket becomes writable.
proc us_socket_context_on_writable*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnWritableCb
) {.importc.}

## Register a callback invoked when a socket hits its inactivity timeout.
proc us_socket_context_on_timeout*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnTimeoutCb
) {.importc.}

## Register a callback invoked when a socket hits its long inactivity timeout.
proc us_socket_context_on_long_timeout*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnTimeoutCb
) {.importc.}

## Register a callback invoked when a connection attempt fails.
proc us_socket_context_on_connect_error*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnConnectErrorCb
) {.importc.}

## Register a callback invoked when the peer ends the connection.
proc us_socket_context_on_end*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnEndCb
) {.importc.}

## Return the user extension data attached to a socket context.
proc us_socket_context_ext*(
  ssl: cint,
  context: UsSocketContextPtr
): pointer {.importc.}

## Close a socket context and all of its sockets.
proc us_socket_context_close*(
  ssl: cint,
  context: UsSocketContextPtr
) {.importc.}

## Make a socket context listen on the given host and port.
proc us_socket_context_listen*(
  ssl: cint,
  context: UsSocketContextPtr,
  host: cstring,
  port: cint,
  options: cint,
  socketExtSize: cint
): UsListenSocketPtr {.importc.}

## Make a socket context listen on a Unix domain socket path.
proc us_socket_context_listen_unix*(
  ssl: cint,
  context: UsSocketContextPtr,
  path: cstring,
  options: cint,
  socketExtSize: cint
): UsListenSocketPtr {.importc.}

## Return the event loop a socket context is attached to.
proc us_socket_context_loop*(
  ssl: cint,
  context: UsSocketContextPtr
): UsLoopPtr {.importc.}

## Create a child socket context that shares the parent event loop.
proc us_create_child_socket_context*(
  ssl: cint,
  context: UsSocketContextPtr,
  contextExtSize: cint
): UsSocketContextPtr {.importc.}

## Return the timestamp of the last packet received on the context.
proc us_socket_context_timestamp*(
  ssl: cint,
  context: UsSocketContextPtr
): cushort {.importc.}

## Register a server name pattern with per-name options and user data.
proc us_socket_context_add_server_name*(
  ssl: cint,
  context: UsSocketContextPtr,
  hostnamePattern: cstring,
  options: UsSocketContextOptions,
  user: pointer
) {.importc.}

## Remove a previously registered server name pattern.
proc us_socket_context_remove_server_name*(
  ssl: cint,
  context: UsSocketContextPtr,
  hostnamePattern: cstring
) {.importc.}

## Register a callback invoked when a connection matches a server name pattern.
proc us_socket_context_on_server_name*(
  ssl: cint,
  context: UsSocketContextPtr,
  cb: OnServerNameCb
) {.importc.}

## Return the native handle backing a socket context.
proc us_socket_context_get_native_handle*(
  ssl: cint,
  context: UsSocketContextPtr
): pointer {.importc.}

# =============================================================================
# Socket Functions
# =============================================================================

## Close a listen socket and stop accepting new connections.
proc us_listen_socket_close*(
  ssl: cint,
  ls: UsListenSocketPtr
) {.importc.}

## Initiate an outgoing TCP connection from a socket context.
proc us_socket_context_connect*(
  ssl: cint,
  context: UsSocketContextPtr,
  host: cstring,
  port: cint,
  sourceHost: cstring,
  options: cint,
  socketExtSize: cint
): UsSocketPtr {.importc.}

## Initiate an outgoing connection to a Unix domain socket.
proc us_socket_context_connect_unix*(
  ssl: cint,
  context: UsSocketContextPtr,
  serverPath: cstring,
  options: cint,
  socketExtSize: cint
): UsSocketPtr {.importc.}

## Check whether a socket has fully established its connection.
proc us_socket_is_established*(
  ssl: cint,
  s: UsSocketPtr
): cint {.importc.}

## Close a socket that is still in the connecting state.
proc us_socket_close_connecting*(
  ssl: cint,
  s: UsSocketPtr
): UsSocketPtr {.importc.}

## Adopt an externally created socket into a socket context.
proc us_socket_context_adopt_socket*(
  ssl: cint,
  context: UsSocketContextPtr,
  s: UsSocketPtr,
  extSize: cint
): UsSocketPtr {.importc.}

## Return the native file descriptor of a socket.
proc us_socket_get_native_handle*(
  ssl: cint,
  s: UsSocketPtr
): pointer {.importc.}

## Write data to a socket, optionally flagging that more data will follow.
proc us_socket_write*(
  ssl: cint,
  s: UsSocketPtr,
  data: cstring,
  length: cint,
  msgMore: cint
): cint {.importc.}

## Write a header and payload to a socket in a single system call.
proc us_socket_write2*(
  ssl: cint,
  s: UsSocketPtr,
  header: cstring,
  headerLength: cint,
  payload: cstring,
  payloadLength: cint
): cint {.importc.}

when not defined(windows):
  type Iovec* {.importc: "struct iovec", header: "<sys/uio.h>", bycopy.} = object
    iov_base*: pointer
    iov_len*: csize_t

  ## Write multiple buffers to a socket in one vectored write.
  proc us_socket_writev_n*(ssl: cint, s: UsSocketPtr, iov: ptr Iovec, iovcnt: cint, totalLength: cint): cint {.importc, cdecl.}

## Defer writes on a socket until uncorked to batch system calls.
proc us_socket_cork*(ssl: cint, s: UsSocketPtr) {.importc.}
## Flush all corked writes on a socket.
proc us_socket_uncork*(ssl: cint, s: UsSocketPtr) {.importc.}
## Write a header and payload without validating the lengths.
proc us_socket_write2_unchecked*(s: UsSocketPtr, header: cstring, headerLength: cint, payload: cstring, payloadLength: cint): cint {.importc.}

## Set the inactivity timeout of a socket in seconds.
proc us_socket_timeout*(
  ssl: cint,
  s: UsSocketPtr,
  seconds: cuint
) {.importc.}

## Set the long inactivity timeout of a socket in minutes.
proc us_socket_long_timeout*(
  ssl: cint,
  s: UsSocketPtr,
  minutes: cuint
) {.importc.}

## Return the user extension data attached to a socket.
proc us_socket_ext*(
  ssl: cint,
  s: UsSocketPtr
): pointer {.importc.}

## Return the socket context a socket belongs to.
proc us_socket_context*(
  ssl: cint,
  s: UsSocketPtr
): UsSocketContextPtr {.importc.}

## Configure the send and receive buffer sizes of a socket.
proc us_socket_set_buffer_sizes*(
  ssl: cint,
  s: UsSocketPtr,
  sendSize: cint,
  recvSize: cint
) {.importc.}

## Flush any corked or buffered data on a socket.
proc us_socket_flush*(
  ssl: cint,
  s: UsSocketPtr
) {.importc.}

## Shut down a socket in both directions.
proc us_socket_shutdown*(
  ssl: cint,
  s: UsSocketPtr
) {.importc.}

## Shut down the read side of a socket.
proc us_socket_shutdown_read*(
  ssl: cint,
  s: UsSocketPtr
) {.importc.}

## Check whether a socket has been shut down.
proc us_socket_is_shut_down*(
  ssl: cint,
  s: UsSocketPtr
): cint {.importc.}

## Check whether a socket has been fully closed.
proc us_socket_is_closed*(
  ssl: cint,
  s: UsSocketPtr
): cint {.importc.}

## Close a socket, returning the socket if data is still in flight.
proc us_socket_close*(
  ssl: cint,
  s: UsSocketPtr,
  code: cint,
  reason: pointer
): UsSocketPtr {.importc.}

## Return the local port bound to a socket.
proc us_socket_local_port*(
  ssl: cint,
  s: UsSocketPtr
): cint {.importc.}

## Return the remote port of a socket.
proc us_socket_remote_port*(
  ssl: cint,
  s: UsSocketPtr
): cint {.importc.}

## Fill the remote address of a socket into the provided buffer.
proc us_socket_remote_address*(
  ssl: cint,
  s: UsSocketPtr,
  buf: ptr char,
  length: ptr cint
) {.importc.}

## Return the current send buffer of a socket.
proc us_socket_send_buffer*(
  ssl: cint,
  s: UsSocketPtr
): ptr char {.importc.}

## Return the user data matched for the server name of a socket.
proc us_socket_server_name_userdata*(
  ssl: cint,
  s: UsSocketPtr
): pointer {.importc.}

## Return the user data registered for a server name pattern.
proc us_socket_context_find_server_name_userdata*(
  ssl: cint,
  context: UsSocketContextPtr,
  hostnamePattern: cstring
): pointer {.importc.}

## Adopt an accepted client file descriptor into a socket context.
proc us_adopt_accepted_socket*(
  ssl: cint,
  context: UsSocketContextPtr,
  clientFd: SocketDescriptor,
  socketExtSize: cuint,
  addrIp: cstring,
  addrIpLength: cint
): UsSocketPtr {.importc.}

## Return the ALPN protocol negotiated on a socket.
proc us_socket_get_alpn_protocol*(
  ssl: cint,
  s: UsSocketPtr,
  len: ptr cuint
): cstring {.importc.}

# =============================================================================
# Poll Functions
# =============================================================================

## Create a new poll object attached to an event loop.
proc us_create_poll*(
  loop: UsLoopPtr,
  fallthrough: cint,
  extSize: cuint
): UsPollPtr {.importc.}

## Free a poll object and its resources.
proc us_poll_free*(
  p: UsPollPtr,
  loop: UsLoopPtr
) {.importc.}

## Initialize a poll object to watch the given file descriptor.
proc us_poll_init*(
  p: UsPollPtr,
  fd: SocketDescriptor,
  pollType: cint
) {.importc.}

## Start polling a file descriptor for the given events.
proc us_poll_start*(
  p: UsPollPtr,
  loop: UsLoopPtr,
  events: cint
) {.importc.}

## Change the events a poll object is watching for.
proc us_poll_change*(
  p: UsPollPtr,
  loop: UsLoopPtr,
  events: cint
) {.importc.}

## Stop polling a poll object.
proc us_poll_stop*(
  p: UsPollPtr,
  loop: UsLoopPtr
) {.importc.}

## Return the events a poll object is currently watching for.
proc us_poll_events*(p: UsPollPtr): cint {.importc.}

## Return the user extension data attached to a poll object.
proc us_poll_ext*(p: UsPollPtr): pointer {.importc.}

## Return the file descriptor a poll object is watching.
proc us_poll_fd*(p: UsPollPtr): SocketDescriptor {.importc.}

## Resize the user extension area of a poll object.
proc us_poll_resize*(
  p: UsPollPtr,
  loop: UsLoopPtr,
  extSize: cuint
): UsPollPtr {.importc.}

# =============================================================================
# UDP Functions
# =============================================================================

## Create a packet buffer for UDP sockets.
proc us_create_udp_packet_buffer*(): UsUdpPacketBufferPtr {.importc.}

## Create a UDP socket attached to an event loop with data and drain callbacks.
proc us_create_udp_socket*(
  loop: UsLoopPtr,
  buf: UsUdpPacketBufferPtr,
  dataCb: UdpDataCb,
  drainCb: UdpDrainCb,
  host: cstring,
  port: cushort,
  user: pointer
): UsUdpSocketPtr {.importc.}

## Return the user data attached to a UDP socket.
proc us_udp_socket_user*(s: UsUdpSocketPtr): pointer {.importc.}

## Bind a UDP socket to the given host and port.
proc us_udp_socket_bind*(
  s: UsUdpSocketPtr,
  hostname: cstring,
  port: cuint
): cint {.importc.}

## Return the local port a UDP socket is bound to.
proc us_udp_socket_bound_port*(s: UsUdpSocketPtr): cint {.importc.}

## Receive a single UDP packet into the packet buffer.
proc us_udp_socket_receive*(
  s: UsUdpSocketPtr,
  buf: UsUdpPacketBufferPtr
): cint {.importc.}

## Send queued packets from the packet buffer.
proc us_udp_socket_send*(
  s: UsUdpSocketPtr,
  buf: UsUdpPacketBufferPtr,
  num: cint
): cint {.importc.}

## Return the payload pointer of a received packet.
proc us_udp_packet_buffer_payload*(
  buf: UsUdpPacketBufferPtr,
  index: cint
): ptr char {.importc.}

## Return the payload length of a received packet.
proc us_udp_packet_buffer_payload_length*(
  buf: UsUdpPacketBufferPtr,
  index: cint
): cint {.importc.}

## Fill the local IP address of a received packet.
proc us_udp_packet_buffer_local_ip*(
  buf: UsUdpPacketBufferPtr,
  index: cint,
  ip: ptr char
): cint {.importc.}

## Return the peer address structure of a received packet.
proc us_udp_packet_buffer_peer*(
  buf: UsUdpPacketBufferPtr,
  index: cint
): pointer {.importc.}

## Return the ECN congestion notification bits of a received packet.
proc us_udp_packet_buffer_ecn*(
  buf: UsUdpPacketBufferPtr,
  index: cint
): cint {.importc.}

## Stage a packet payload in a send buffer for transmission.
proc us_udp_buffer_set_packet_payload*(
  sendBuf: UsUdpPacketBufferPtr,
  index: cint,
  offset: cint,
  payload: pointer,
  length: cint,
  peerAddr: pointer
) {.importc.}

{.pop.}
