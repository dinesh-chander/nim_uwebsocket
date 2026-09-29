import std/[strutils, deques, tables, times, json, atomics]
import types
import validation
import http1
import http2
import connection_pool
import ws_client
import sse_client
import ../../../nim_usockets/src/nim_usockets/usockets

when defined(macosx):
  proc CFRunLoopGetCurrent(): pointer {.importc, header: "<CoreFoundation/CoreFoundation.h>".}
  proc CFRunLoopStop(rl: pointer) {.importc, header: "<CoreFoundation/CoreFoundation.h>".}

const ConnDataMagic: uint32 = 0xC0DE_DA7A'u32

proc fireConnectStart(hooks: HttpClientHooks, host: string, port: uint16, isTls: bool) {.inline.} =
  if hooks.onConnectStart != nil:
    try: hooks.onConnectStart(host, port, isTls)
    except CatchableError: discard

proc fireConnectEnd(hooks: HttpClientHooks, host: string, port: uint16, durationMs: float, error: string) {.inline.} =
  if hooks.onConnectEnd != nil:
    try: hooks.onConnectEnd(host, port, durationMs, error)
    except CatchableError: discard

proc fireConnectionReuse(hooks: HttpClientHooks, host: string, port: uint16) {.inline.} =
  if hooks.onConnectionReuse != nil:
    try: hooks.onConnectionReuse(host, port)
    except CatchableError: discard

proc fireConnectionClose(hooks: HttpClientHooks, host: string, port: uint16, reason: string) {.inline.} =
  if hooks.onConnectionClose != nil:
    try: hooks.onConnectionClose(host, port, reason)
    except CatchableError: discard

proc fireRequestStart(hooks: HttpClientHooks, httpMethod: string, url: string, headers: seq[HttpHeader]) {.inline.} =
  if hooks.onRequestStart != nil:
    try: hooks.onRequestStart(httpMethod, url, headers)
    except CatchableError: discard

proc fireRequestHeadersSent(hooks: HttpClientHooks, httpMethod: string, url: string, headerBytes: int) {.inline.} =
  if hooks.onRequestHeadersSent != nil:
    try: hooks.onRequestHeadersSent(httpMethod, url, headerBytes)
    except CatchableError: discard

proc fireResponseHeaders(hooks: HttpClientHooks, statusCode: int, headers: seq[HttpHeader], durationMs: float) {.inline.} =
  if hooks.onResponseHeaders != nil:
    try: hooks.onResponseHeaders(statusCode, headers, durationMs)
    except CatchableError: discard

proc fireResponseBody(hooks: HttpClientHooks, bodyBytes: int, totalDurationMs: float) {.inline.} =
  if hooks.onResponseBody != nil:
    try: hooks.onResponseBody(bodyBytes, totalDurationMs)
    except CatchableError: discard

proc fireRequestError(hooks: HttpClientHooks, httpMethod: string, url: string, error: string, durationMs: float) {.inline.} =
  if hooks.onRequestError != nil:
    try: hooks.onRequestError(httpMethod, url, error, durationMs)
    except CatchableError: discard

proc fireRetry(hooks: HttpClientHooks, httpMethod: string, url: string, attempt: int, maxRetries: int, reason: string) {.inline.} =
  if hooks.onRetry != nil:
    try: hooks.onRetry(httpMethod, url, attempt, maxRetries, reason)
    except CatchableError: discard

proc scheduleRequestRetry(
  client: ptr HttpClient,
  httpMethod: HttpMethod,
  url: string,
  body: string,
  headers: seq[HttpHeader],
  cb: ResponseCallback,
  forceH2: bool,
  retryCount: int,
  delayMs: int
): bool

## Closes the client, releasing all pooled connections and native loop resources.
proc close*(client: var HttpClient)
## Closes and evicts every idle pooled connection that exceeded the idle timeout.
proc cleanupIdleConnections*(client: var HttpClient)

proc firePoolAcquire(hooks: HttpClientHooks, host: string, port: uint16, poolSize: int, idle: int, active: int) {.inline.} =
  if hooks.onPoolAcquire != nil:
    try: hooks.onPoolAcquire(host, port, poolSize, idle, active)
    except CatchableError: discard

proc firePoolRelease(hooks: HttpClientHooks, host: string, port: uint16, poolSize: int) {.inline.} =
  if hooks.onPoolRelease != nil:
    try: hooks.onPoolRelease(host, port, poolSize)
    except CatchableError: discard

proc firePoolEvict(hooks: HttpClientHooks, host: string, port: uint16, reason: string) {.inline.} =
  if hooks.onPoolEvict != nil:
    try: hooks.onPoolEvict(host, port, reason)
    except CatchableError: discard

type
  SseEventCallback = proc(event: SseEvent) {.gcsafe.}
  SseOpenCallback = proc() {.gcsafe.}
  SseErrorCallback = proc(err: string) {.gcsafe.}

  H1PendingMeta = object
    requestStartTime: float
    requestMethod: string
    requestUrl: string
    noBodyExpected: bool
    request: HttpRequest
    isSse: bool
    sseOpened: bool
    sseParser: SseParser
    sseOnEvent: SseEventCallback
    sseOnOpen: SseOpenCallback
    sseOnError: SseErrorCallback

  ClientConnData = object
    magic: uint32
    conn: ptr PooledConnection
    client: ptr HttpClient
    sslFlag: cint
    h1Parser: Http1Parser
    h1Pending: Deque[H1PendingMeta]
    h2Conn: H2ClientConnection
    h2Active: bool
    h2PendingQueue: seq[PendingH2Request]
    wsConn: WsConnection
    connectStartTime: float
    requestStartTime: float
    requestMethod: string
    requestUrl: string

const ClientSocketExtSize = cint(sizeof(pointer))
const ClientContextExtSize = cint(sizeof(pointer))

proc drainH2Queue(cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr)

proc storeInExt(ext: pointer, val: pointer) {.inline.} =
  cast[ptr pointer](ext)[] = val

proc loadFromExt(ext: pointer): pointer {.inline.} =
  cast[ptr pointer](ext)[]

proc isValidConnData(p: pointer): bool {.inline.} =
  if p == nil: return false
  let cd = cast[ptr ClientConnData](p)
  cd.magic == ConnDataMagic

proc getConnData(ssl: cint, s: UsSocketPtr): ptr ClientConnData {.inline.} =
  let ext = us_socket_ext(ssl, s)
  if ext == nil: return nil
  let p = loadFromExt(ext)
  if isValidConnData(p):
    cast[ptr ClientConnData](p)
  else:
    nil

proc getWsConnection(ssl: cint, s: UsSocketPtr): WsConnection {.inline.} =
  let ext = us_socket_ext(ssl, s)
  if ext == nil: return nil
  let p = loadFromExt(ext)
  if p == nil:
    return nil
  let ws = cast[WsConnection](p)
  if isValidWsConnection(ws): ws else: nil

const MaxClientSendBufSize = 16 * 1024 * 1024
const MaxClientRecvBufSize = 64 * 1024 * 1024

proc canQueueSocketWrite(conn: ptr PooledConnection, dataLen: int): bool {.inline.} =
  if conn == nil or dataLen < 0 or dataLen > MaxClientSendBufSize:
    return false
  conn.sendBuf.len <= MaxClientSendBufSize - dataLen

proc failSocketWriteBackpressure(ssl: cint, s: UsSocketPtr, conn: ptr PooledConnection) {.inline.} =
  if conn != nil:
    conn.state = csClosing
  if s != nil:
    discard us_socket_close(ssl, s, 0, nil)

proc queueSocketWrite(ssl: cint, s: UsSocketPtr, data: string, conn: ptr PooledConnection): bool {.inline.} =
  if data.len == 0:
    return true
  if not canQueueSocketWrite(conn, data.len):
    failSocketWriteBackpressure(ssl, s, conn)
    return false
  conn.sendBuf.add data
  true

when defined(nimFastHttpClientTest):
  ## Test helper exposing canQueueSocketWrite for a pooled connection.
  proc clientCanQueueSocketWriteForTest*(conn: ptr PooledConnection, dataLen: int): bool =
    canQueueSocketWrite(conn, dataLen)

proc socketWrite(ssl: cint, s: UsSocketPtr, data: string, conn: ptr PooledConnection) {.inline.} =
  if data.len == 0: return
  if data.len > MaxClientSendBufSize:
    failSocketWriteBackpressure(ssl, s, conn)
    return
  if s == nil:
    if conn != nil:
      discard queueSocketWrite(ssl, s, data, conn)
    return
  if conn.sendBuf.len > conn.sendBufPos:
    if not queueSocketWrite(ssl, s, data, conn):
      return
    return
  let written = us_socket_write(ssl, s, cstring(data), cint(data.len), 0)
  if written < cint(data.len):
    let start = if written > 0: int(written) else: 0
    let remaining = data.len - start
    conn.sendBuf.setLen(remaining)
    conn.sendBufPos = 0
    if remaining > 0:
      copyMem(addr conn.sendBuf[0], unsafeAddr data[start], remaining)

proc drainSendBuf(ssl: cint, s: UsSocketPtr, conn: ptr PooledConnection) {.inline.} =
  let toWrite = conn.sendBuf.len - conn.sendBufPos
  if toWrite <= 0:
    conn.sendBuf.setLen(0)
    conn.sendBufPos = 0
    return
  let written = us_socket_write(ssl, s, cast[cstring](unsafeAddr conn.sendBuf[conn.sendBufPos]), cint(toWrite), 0)
  if written >= cint(toWrite):
    conn.sendBuf.setLen(0)
    conn.sendBufPos = 0
  elif written > 0:
    conn.sendBufPos += int(written)

proc appendSocketData(buf: var string, data: cstring, length: cint): bool {.inline.} =
  if data == nil or length <= 0:
    return true
  let oldLen = buf.len
  if oldLen + int(length) > MaxClientRecvBufSize:
    return false
  buf.setLen(oldLen + int(length))
  copyMem(addr buf[oldLen], data, int(length))
  true

proc hasHttp1HeaderTerminatorWithinCap(buf: string, data: cstring, length: cint): bool {.inline.} =
  if data == nil or length <= 0:
    return buf.find("\r\n\r\n") >= 0
  let oldLen = buf.len
  let totalLen = oldLen + int(length)
  let scanLen = min(totalLen, MaxHttp1HeaderBytes + 4)
  if scanLen < 4:
    return false
  var i = 0
  while i + 3 < scanLen:
    let c0 = if i < oldLen: buf[i] else: data[i - oldLen]
    if c0 == '\r':
      let i1 = i + 1
      let i2 = i + 2
      let i3 = i + 3
      let c1 = if i1 < oldLen: buf[i1] else: data[i1 - oldLen]
      let c2 = if i2 < oldLen: buf[i2] else: data[i2 - oldLen]
      let c3 = if i3 < oldLen: buf[i3] else: data[i3 - oldLen]
      if c1 == '\n' and c2 == '\r' and c3 == '\n':
        return true
    inc i
  false

proc openWsConnection(client: var HttpClient, ws: WsConnection): bool
proc scheduleWsReconnect(ws: WsConnection)

proc wsSsl(ws: WsConnection): cint {.inline.} =
  if ws != nil and ws.useSsl: 1.cint else: 0.cint

proc bindTimerWs(timer: UsTimerPtr, ws: WsConnection) {.inline.} =
  if timer == nil:
    return
  let ext = us_timer_ext(timer)
  if ext != nil:
    storeInExt(ext, cast[pointer](ws))

proc wsFromTimer(timer: UsTimerPtr): WsConnection {.inline.} =
  if timer == nil:
    return nil
  let ext = us_timer_ext(timer)
  if ext == nil:
    return nil
  let p = loadFromExt(ext)
  if p == nil:
    return nil
  let ws = cast[WsConnection](p)
  if isValidWsConnection(ws): ws else: nil

proc bindTimerClient(timer: UsTimerPtr, client: ptr HttpClient) {.inline.} =
  if timer == nil:
    return
  let ext = us_timer_ext(timer)
  if ext != nil:
    storeInExt(ext, cast[pointer](client))

proc clientFromTimer(timer: UsTimerPtr): ptr HttpClient {.inline.} =
  if timer == nil:
    return nil
  let ext = us_timer_ext(timer)
  if ext == nil:
    return nil
  cast[ptr HttpClient](loadFromExt(ext))

proc stopWsTimer(timer: var UsTimerPtr) =
  if timer != nil:
    us_timer_close(timer)
    timer = nil

proc stopWsActiveTimers(ws: WsConnection) =
  if ws == nil:
    return
  stopWsTimer(ws.heartbeatTimer)
  stopWsTimer(ws.closeTimer)
  stopWsTimer(ws.reconnectTimer)

proc trackActiveWs(client: ptr HttpClient, ws: WsConnection) =
  if client == nil or ws == nil:
    return
  let ix = ws.activeWsIndex
  if ix >= 0 and ix < client[].activeWs.len and client[].activeWs[ix] == ws:
    return
  client[].activeWs.add ws
  ws.activeWsIndex = client[].activeWs.len - 1

proc untrackActiveWs(client: ptr HttpClient, ws: WsConnection) =
  if client == nil or ws == nil or client[].activeWs.len == 0:
    return
  let ix = ws.activeWsIndex
  if ix >= 0 and ix < client[].activeWs.len and client[].activeWs[ix] == ws:
    let last = client[].activeWs.len - 1
    if ix != last:
      let moved = client[].activeWs[last]
      client[].activeWs[ix] = moved
      if moved != nil:
        moved.activeWsIndex = ix
    client[].activeWs.setLen(last)
    ws.activeWsIndex = -1
    return
  var i = 0
  while i < client[].activeWs.len:
    if client[].activeWs[i] == ws:
      if i < client[].activeWs.len - 1:
        let moved = client[].activeWs[^1]
        client[].activeWs[i] = moved
        if moved != nil:
          moved.activeWsIndex = i
      client[].activeWs.setLen(client[].activeWs.len - 1)
      ws.activeWsIndex = -1
      return
    inc i

proc untrackWsOwner(ws: WsConnection) =
  if ws == nil or ws.owner == nil:
    return
  untrackActiveWs(cast[ptr HttpClient](ws.owner), ws)

proc notifyWsError(ws: WsConnection, err: string) =
  if ws != nil and ws.onError != nil:
    try: ws.onError(err)
    except CatchableError: discard

proc notifyWsCloseOnce(ws: WsConnection, code: uint16, reason: string) =
  if ws == nil or ws.closeNotified:
    return
  ws.closeNotified = true
  ws.closeCode = code
  ws.closeReason = reason
  if ws.onClose != nil:
    try: ws.onClose(code, reason)
    except CatchableError: discard

proc sendWsRaw(ws: WsConnection, data: string) =
  if ws == nil or ws.socket == nil or data.len == 0:
    return
  if data.len > MaxClientSendBufSize:
    notifyWsError(ws, "websocket send buffer limit exceeded")
    discard us_socket_close(wsSsl(ws), ws.socket, 0, nil)
    return
  if ws.sendBuf.len > ws.sendBufPos:
    if ws.sendBuf.len + data.len > MaxClientSendBufSize:
      notifyWsError(ws, "websocket send buffer limit exceeded")
      discard us_socket_close(wsSsl(ws), ws.socket, 0, nil)
      return
    ws.sendBuf.add data
    return
  let written = us_socket_write(wsSsl(ws), ws.socket, data.cstring, data.len.cint, 0)
  if written < cint(data.len):
    let start = if written > 0: int(written) else: 0
    let remaining = data.len - start
    ws.sendBuf.setLen(remaining)
    ws.sendBufPos = 0
    if remaining > 0:
      copyMem(addr ws.sendBuf[0], unsafeAddr data[start], remaining)

proc drainWsSendBuf(ws: WsConnection, ssl: cint, s: UsSocketPtr) {.inline.} =
  if ws == nil:
    return
  let toWrite = ws.sendBuf.len - ws.sendBufPos
  if toWrite <= 0:
    ws.sendBuf.setLen(0)
    ws.sendBufPos = 0
    return
  let written = us_socket_write(ssl, s, cast[cstring](unsafeAddr ws.sendBuf[ws.sendBufPos]), cint(toWrite), 0)
  if written >= cint(toWrite):
    ws.sendBuf.setLen(0)
    ws.sendBufPos = 0
  elif written > 0:
    ws.sendBufPos += int(written)

proc onWsCloseTimer(timer: UsTimerPtr) {.cdecl.} =
  let ws = wsFromTimer(timer)
  if ws != nil and ws.closeTimer == timer:
    ws.closeTimer = nil
  us_timer_close(timer)
  if ws != nil and ws.socket != nil and ws.state == csClosing:
    discard us_socket_close(wsSsl(ws), ws.socket, 0, nil)

proc startWsCloseTimer(ws: WsConnection) =
  if ws == nil or ws.loop == nil or ws.closeTimeoutMs <= 0 or ws.closeTimer != nil:
    return
  ws.closeTimer = us_create_timer(ws.loop, 0, cuint(sizeof(pointer)))
  if ws.closeTimer != nil:
    bindTimerWs(ws.closeTimer, ws)
    us_timer_set(ws.closeTimer, onWsCloseTimer, ws.closeTimeoutMs.cint, 0)

proc initiateWsClose(ws: WsConnection, code: uint16 = 1000'u16, reason: string = "",
                     manual: bool = true): UsSocketPtr =
  if ws == nil:
    return nil
  if ws.state == csClosed:
    return ws.socket
  if manual:
    ws.manualClose = true
  let closeCode = sanitizeOutgoingCloseCode(code)
  if closeCode != code:
    notifyWsError(ws, "invalid websocket close code")
  ws.closeCode = closeCode
  ws.closeReason = reason
  ws.state = csClosing
  if not ws.closeFrameSent and ws.socket != nil:
    let frame = encodeCloseFrame(closeCode, reason, masked = true)
    sendWsRaw(ws, frame)
    ws.closeFrameSent = true
  if ws.peerCloseReceived and ws.socket != nil:
    return us_socket_close(wsSsl(ws), ws.socket, 0, nil)
  startWsCloseTimer(ws)
  ws.socket

proc protocolClose(ws: WsConnection, code: uint16, reason: string, manual: bool = true): UsSocketPtr =
  notifyWsError(ws, reason)
  initiateWsClose(ws, code, reason, manual = manual)

proc onWsHeartbeatTimer(timer: UsTimerPtr) {.cdecl.} =
  let ws = wsFromTimer(timer)
  if ws == nil or ws.heartbeatTimer != timer:
    return
  if ws.state != csOpen or ws.socket == nil:
    return
  let nowMs = nowWsMs()
  if shouldFailPongTimeout(ws, nowMs):
    discard protocolClose(ws, 1011'u16, "websocket pong timeout", manual = false)
    return
  if ws.pingIntervalMs > 0 and nowMs - ws.lastPingAtMs >= int64(ws.pingIntervalMs) and not ws.awaitingPong:
    sendWsRaw(ws, buildWsPing(ws, nowMs))

proc startWsHeartbeat(ws: WsConnection) =
  if ws == nil or ws.loop == nil or ws.pingIntervalMs <= 0 or ws.heartbeatTimer != nil:
    return
  ws.heartbeatTimer = us_create_timer(ws.loop, 0, cuint(sizeof(pointer)))
  if ws.heartbeatTimer != nil:
    bindTimerWs(ws.heartbeatTimer, ws)
    us_timer_set(ws.heartbeatTimer, onWsHeartbeatTimer, 1000, 1000)

proc onWsReconnectTimer(timer: UsTimerPtr) {.cdecl.} =
  let ws = wsFromTimer(timer)
  if ws != nil and ws.reconnectTimer == timer:
    ws.reconnectTimer = nil
  us_timer_close(timer)
  if ws == nil or ws.owner == nil or ws.manualClose:
    return
  let client = cast[ptr HttpClient](ws.owner)
  if not client[].initialized:
    return
  if not openWsConnection(client[], ws):
    scheduleWsReconnect(ws)

proc scheduleWsReconnect(ws: WsConnection) =
  if not shouldScheduleWsReconnect(ws):
    if ws != nil and ws.reconnectTimer == nil and
       (ws.manualClose or not ws.autoReconnect or
        ws.reconnectAttempts >= ws.maxReconnectAttempts):
      untrackWsOwner(ws)
    return
  if ws.owner == nil or not cast[ptr HttpClient](ws.owner)[].initialized:
    untrackWsOwner(ws)
    return
  inc ws.reconnectAttempts
  trackActiveWs(cast[ptr HttpClient](ws.owner), ws)
  let delayMs = nextWsReconnectDelayMs(ws)
  ws.state = csConnecting
  ws.reconnectTimer = us_create_timer(ws.loop, 0, cuint(sizeof(pointer)))
  if ws.reconnectTimer != nil:
    bindTimerWs(ws.reconnectTimer, ws)
    us_timer_set(ws.reconnectTimer, onWsReconnectTimer, delayMs.cint, 0)

proc processWsFrames(ws: WsConnection, ssl: cint, s: UsSocketPtr): UsSocketPtr =
  if ws.state != csOpen and ws.state != csClosing:
    return s

  var pos = 0
  while pos < ws.recvBuf.len:
    let read = readWsFrame(ws.recvBuf, pos, ws.maxMessageSize, requireUnmasked = true)
    if read.status == wfrNeedMore:
      break
    if read.status == wfrMessageTooLarge:
      return protocolClose(ws, read.closeCode, read.error)
    if read.status == wfrProtocolError:
      return protocolClose(ws, read.closeCode, read.error)
    let frame = read.frame
    case frame.opcode
    of woText, woBinary:
      if ws.fragmented:
        return protocolClose(ws, 1002'u16, "new websocket data frame before continuation")
      if frame.payload.len > ws.maxMessageSize:
        return protocolClose(ws, 1009'u16, "websocket message too large")
      if frame.fin:
        if frame.opcode == woText:
          resetWsUtf8(ws)
          if not feedWsUtf8(ws, frame.payload, final = true):
            return protocolClose(ws, 1007'u16, "invalid websocket text UTF-8")
        if ws.onMessage != nil:
          try: ws.onMessage(frame.payload, frame.opcode)
          except CatchableError: discard
          if ws.state != csOpen:
            ws.recvBuf.setLen(0)
            return s
      else:
        ws.fragmented = true
        ws.fragmentedOpcode = frame.opcode
        ws.fragmentBuf = frame.payload
        if frame.opcode == woText:
          resetWsUtf8(ws)
          if not feedWsUtf8(ws, frame.payload, final = false):
            return protocolClose(ws, 1007'u16, "invalid websocket text UTF-8")
    of woClose:
      let parsed = parseWsClosePayload(frame.payload)
      if not parsed.valid:
        return protocolClose(ws, parsed.closeCode, "invalid websocket close frame")
      ws.peerCloseReceived = true
      ws.state = csClosing
      if not ws.closeFrameSent:
        sendWsRaw(ws, encodeWsFrame(woClose, frame.payload, masked = true))
        ws.closeFrameSent = true
      notifyWsCloseOnce(ws, parsed.code, parsed.reason)
      stopWsTimer(ws.closeTimer)
      return us_socket_close(ssl, s, 0, nil)
    of woPing:
      let pong = buildWsPongResponse(frame.payload)
      if pong.len == 0:
        return protocolClose(ws, 1002'u16, "invalid websocket ping payload")
      sendWsRaw(ws, pong)
    of woPong:
      noteWsPong(ws, frame.payload)
    of woContinuation:
      if not ws.fragmented:
        return protocolClose(ws, 1002'u16, "unexpected websocket continuation frame")
      if ws.fragmentBuf.len + frame.payload.len > ws.maxMessageSize:
        return protocolClose(ws, 1009'u16, "websocket message too large")
      ws.fragmentBuf.add frame.payload
      if ws.fragmentedOpcode == woText:
        if not feedWsUtf8(ws, frame.payload, final = frame.fin):
          return protocolClose(ws, 1007'u16, "invalid websocket text UTF-8")
      if frame.fin:
        let opcode = ws.fragmentedOpcode
        let payload = move ws.fragmentBuf
        ws.fragmented = false
        ws.fragmentBuf = ""
        resetWsUtf8(ws)
        if ws.onMessage != nil:
          try: ws.onMessage(payload, opcode)
          except CatchableError: discard
          if ws.state != csOpen:
            ws.recvBuf.setLen(0)
            return s

  if pos > 0:
    if pos < ws.recvBuf.len:
      ws.recvBuf = ws.recvBuf[pos ..< ws.recvBuf.len]
    else:
      ws.recvBuf.setLen(0)
  s

when defined(nimFastHttpClientTest):
  ## Test helper checking that a WebSocket close stops delivery of buffered frames.
  proc clientWsCloseStopsBufferedDeliveryForTest*(): tuple[delivered: int, state: ConnectionState, remaining: int] =
    let ws {.cursor.} = newWsConnection()
    initWsClientDefaults(ws)
    markWsOpen(ws, 0)
    ws.recvBuf = encodeWsFrame(woText, "first", masked = false) &
      encodeWsFrame(woText, "second", masked = false)
    var delivered = 0
    ws.onMessage = proc(payload: string, opcode: WsOpcode) =
      inc delivered
      if delivered == 1:
        discard initiateWsClose(ws, 1000'u16, "stop", manual = true)

    discard processWsFrames(ws, 0, nil)
    result.delivered = delivered
    result.state = ws.state
    result.remaining = ws.recvBuf.len

proc handleWsConnectionData(ws: WsConnection, ssl: cint, s: UsSocketPtr,
                            data: cstring, length: cint): UsSocketPtr =
  if not appendSocketData(ws.recvBuf, data, length):
    return protocolClose(ws, 1009'u16, "websocket frame buffer too large")
  processWsFrames(ws, ssl, s)

proc detachWsConnection(client: var HttpClient, conn: ptr PooledConnection,
                        cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr,
                        ws: WsConnection) =
  client.pool.removeConnection(conn)
  let ext = us_socket_ext(ssl, s)
  if ext != nil:
    storeInExt(ext, cast[pointer](ws))
  trackActiveWs(addr client, ws)
  conn.socket = nil
  `=destroy`(cd[])
  dealloc(cd)
  `=destroy`(conn[])
  dealloc(conn)

## Checks whether the negotiated WebSocket subprotocol was offered by the client.
proc wsSubprotocolAllowed*(selected: string, offered: openArray[string]): bool {.inline.} =
  if selected.len == 0:
    return true
  for item in offered:
    if item == selected:
      return true
  false

proc handleWsUpgradeData(client: var HttpClient, conn: ptr PooledConnection,
                         cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr,
                         data: cstring, length: cint): UsSocketPtr =
  let ws = cd.wsConn
  if ws == nil:
    return s
  if not appendSocketData(ws.recvBuf, data, length):
    ws.manualClose = true
    ws.state = csClosing
    notifyWsError(ws, "websocket handshake response too large")
    return us_socket_close(ssl, s, 0, nil)

  let headerEnd = ws.recvBuf.find("\r\n\r\n")
  if headerEnd < 0:
    return s

  let headers = ws.recvBuf[0 .. headerEnd + 3]
  if not validateUpgradeResponse(headers, ws.wsKey):
    ws.manualClose = true
    ws.state = csClosing
    notifyWsError(ws, "invalid websocket upgrade response")
    return us_socket_close(ssl, s, 0, nil)

  let selectedProtocol = selectedSubprotocol(headers)
  if not wsSubprotocolAllowed(selectedProtocol, ws.reconnectSubprotocols):
    ws.manualClose = true
    ws.state = csClosing
    notifyWsError(ws, "websocket server selected unoffered subprotocol")
    return us_socket_close(ssl, s, 0, nil)

  let remainingStart = headerEnd + 4
  if remainingStart < ws.recvBuf.len:
    ws.recvBuf = ws.recvBuf[remainingStart ..< ws.recvBuf.len]
  else:
    ws.recvBuf.setLen(0)
  ws.socket = s
  markWsOpen(ws)
  ws.subprotocol = selectedProtocol
  detachWsConnection(client, conn, cd, ssl, s, ws)
  startWsHeartbeat(ws)
  if ws.onOpen != nil:
    try: ws.onOpen()
    except CatchableError: discard
  processWsFrames(ws, ssl, s)

when not defined(macosx):
  proc drainPoolForAutoStop(client: ptr HttpClient) =
    var toClose: seq[UsSocketPtr]
    for key in client.pool.connections.keys:
      let conns = addr client.pool.connections[key]
      for i in 0 ..< conns[].len:
        let conn = conns[][i]
        if conn.socket != nil:
          toClose.add(conn.socket)
    for sock in toClose:
      discard us_socket_close(client.ssl, sock, 0, nil)

proc maybeAutoStop(client: ptr HttpClient) {.inline.} =
  if client.autoStop and client.pendingRequests <= 0 and
      client.retryTimers.len == 0 and client.activeWs.len == 0:
    when defined(macosx):
      CFRunLoopStop(CFRunLoopGetCurrent())
    else:
      drainPoolForAutoStop(client)

proc fireErrorCallbacks(conn: ptr PooledConnection, errMsg: string) =
  while conn.pendingCallbacks.len > 0:
    let cb = conn.pendingCallbacks.popFirst()
    let resp = HttpResponse(statusCode: 0, statusText: "connection error")
    try:
      cb(resp, errMsg)
    except CatchableError:
      discard
    except Defect:
      discard

proc decPending(client: ptr HttpClient, n: int) {.inline.} =
  if client == nil or n <= 0:
    return
  client.pendingRequests = max(0, client.pendingRequests - n)

proc requestExpired(startTime: float, timeoutMs: int, now: float): bool {.inline.} =
  timeoutMs > 0 and startTime > 0.0 and (now - startTime) * 1000.0 >= float(timeoutMs)

proc connHasExpiredRequest(client: ptr HttpClient, conn: ptr PooledConnection,
                           cd: ptr ClientConnData, now: float): bool =
  if client == nil or conn == nil:
    return false
  if conn.state == csConnecting and client.connectTimeoutMs > 0 and cd != nil:
    if requestExpired(cd.connectStartTime, client.connectTimeoutMs, now):
      return true
  if cd == nil:
    return false
  if cd.wsConn != nil and cd.wsConn.state == csConnecting and client.connectTimeoutMs > 0:
    if requestExpired(cd.connectStartTime, client.connectTimeoutMs, now):
      return true
  for meta in cd.h1Pending:
    if requestExpired(meta.requestStartTime, meta.request.timeoutMs, now):
      return true
  false

proc failTimedOutH2Streams(client: ptr HttpClient, conn: ptr PooledConnection,
                           cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr,
                           now: float): seq[ResponseCallback] =
  result = @[]
  if client == nil or conn == nil or cd == nil:
    return
  var expiredIds: seq[uint32] = @[]
  if cd.h2Active:
    for sid, stream in cd.h2Conn.streams:
      if requestExpired(stream.requestStartTime, stream.request.timeoutMs, now):
        expiredIds.add sid

  var rstBuf = newStringOfCap(expiredIds.len * 13)
  for sid in expiredIds:
    if sid notin cd.h2Conn.streams:
      continue
    let stream = cd.h2Conn.streams[sid]
    let durationMs =
      if stream.requestStartTime > 0.0:
        (now - stream.requestStartTime) * 1000.0
      else:
        0.0
    fireRequestError(
      client.hooks,
      MethodStrings[stream.request.`method`],
      stream.request.url,
      "request timeout",
      durationMs
    )
    cd.h2Conn.sendRstStream(sid, 0x8'u32, rstBuf)
    cd.h2Conn.streams.del(sid)
    conn.h2Streams.del(sid)
    decPending(client, 1)
    if stream.callback != nil:
      result.add stream.callback

  if rstBuf.len > 0 and s != nil and conn.state notin {csClosed, csClosing}:
    socketWrite(ssl, s, rstBuf, conn)

  if cd.h2PendingQueue.len > 0:
    var stillPending = newSeqOfCap[PendingH2Request](cd.h2PendingQueue.len)
    for pr in cd.h2PendingQueue:
      let started = if pr.requestStartTime > 0.0: pr.requestStartTime else: cd.requestStartTime
      if requestExpired(started, pr.req.timeoutMs, now):
        let durationMs =
          if started > 0.0:
            (now - started) * 1000.0
          else:
            0.0
        fireRequestError(
          client.hooks,
          MethodStrings[pr.req.`method`],
          pr.req.url,
          "request timeout",
          durationMs
        )
        decPending(client, 1)
        if pr.cb != nil:
          result.add pr.cb
      else:
        stillPending.add pr
    cd.h2PendingQueue = stillPending

proc failTimedOutCallbacks(client: ptr HttpClient, conn: ptr PooledConnection,
                           cd: ptr ClientConnData, errMsg: string): seq[ResponseCallback] =
  result = @[]
  if cd != nil:
    for _, stream in cd.h2Conn.streams:
      if stream.callback != nil:
        result.add stream.callback
    decPending(client, result.len)
    cd.h2Conn.streams.clear()
    if conn != nil:
      conn.h2Streams.clear()

    let h2QueuedStart = result.len
    for pr in cd.h2PendingQueue:
      if pr.cb != nil:
        result.add pr.cb
    decPending(client, result.len - h2QueuedStart)
    cd.h2PendingQueue.setLen(0)

    while cd.h1Pending.len > 0:
      discard cd.h1Pending.popFirst()

  if conn != nil:
    let h1Start = result.len
    while conn.pendingCallbacks.len > 0:
      result.add conn.pendingCallbacks.popFirst()
    decPending(client, result.len - h1Start)

## Walks pending requests and fails any that exceeded their connect or response timeout.
proc checkRequestTimeouts*(client: var HttpClient) =
  if not client.initialized:
    return
  let now = epochTime()
  var expired: seq[tuple[conn: ptr PooledConnection, cd: ptr ClientConnData]]
  for key in client.pool.connections.keys:
    let conns = addr client.pool.connections[key]
    for conn in conns[]:
      if conn == nil or conn.state == csClosed or conn.state == csClosing:
        continue
      var cd: ptr ClientConnData = nil
      if conn.socket != nil:
        cd = getConnData(client.ssl, conn.socket)
      if cd != nil and conn.state == csOpen:
        let callbacks = failTimedOutH2Streams(addr client, conn, cd, client.ssl, conn.socket, now)
        if cd.h2Active and conn.state == csOpen:
          drainH2Queue(cd, client.ssl, conn.socket)
        let resp = HttpResponse(statusCode: 0, statusText: "request timeout")
        for cb in callbacks:
          try:
            cb(resp, "request timeout")
          except CatchableError:
            discard
          except Defect:
            discard
      if connHasExpiredRequest(addr client, conn, cd, now):
        expired.add((conn: conn, cd: cd))

  for item in expired:
    let conn = item.conn
    if conn == nil or conn.state == csClosed or conn.state == csClosing:
      continue
    let errMsg =
      if conn.state == csConnecting:
        "connect timeout"
      else:
        "request timeout"
    if item.cd != nil and item.cd.wsConn != nil:
      item.cd.wsConn.state = csClosing
      notifyWsError(item.cd.wsConn, if errMsg == "connect timeout": "websocket connect timeout" else: "websocket handshake timeout")
    fireConnectionClose(client.hooks, conn.host, conn.port, errMsg)
    let callbacks = failTimedOutCallbacks(addr client, conn, item.cd, errMsg)
    conn.state = csClosing
    client.pool.removeConnection(conn)
    if conn.socket != nil:
      discard us_socket_close(client.ssl, conn.socket, 0, nil)
    else:
      `=destroy`(conn[])
      dealloc(conn)
    let resp = HttpResponse(statusCode: 0, statusText: errMsg)
    for cb in callbacks:
      try:
        cb(resp, errMsg)
      except CatchableError:
        discard
      except Defect:
        discard

when defined(nimFastHttpClientTest):
  ## Test helper verifying that a pipelined HTTP/1 tail request expires after timeout.
  proc clientH1PipelinedTailTimeoutForTest*(): bool =
    var client = HttpClient(connectTimeoutMs: 5_000)
    var conn = PooledConnection(state: csOpen)
    var cd = ClientConnData(
      h1Pending: initDeque[H1PendingMeta](2),
    )
    let now = epochTime()
    cd.h1Pending.addLast H1PendingMeta(
      requestStartTime: now,
      request: HttpRequest(`method`: hmGet, url: "http://example.test/slow-head", timeoutMs: 60_000)
    )
    cd.h1Pending.addLast H1PendingMeta(
      requestStartTime: now - 1.0,
      request: HttpRequest(`method`: hmGet, url: "http://example.test/short-tail", timeoutMs: 10)
    )
    connHasExpiredRequest(addr client, addr conn, addr cd, now)

  ## Test helper checking that an HTTP/2 timeout retires only the timed-out stream.
  proc clientH2TimeoutIsolationForTest*(): tuple[pendingRequests: int, remainingStreams: int, connState: ConnectionState] =
    var client = HttpClient(pendingRequests: 2)
    var conn = PooledConnection(
      state: csOpen,
      isHttp2: true,
      h2Streams: initTable[uint32, H2Stream](),
    )
    var cd = ClientConnData(
      conn: addr conn,
      client: addr client,
      h2Conn: initH2ClientConnection(),
      h2Active: true,
    )
    let now = epochTime()
    let expiredReq = HttpRequest(`method`: hmGet, url: "https://example.test/slow", timeoutMs: 10)
    let activeReq = HttpRequest(`method`: hmGet, url: "https://example.test/fast", timeoutMs: 10_000)
    cd.h2Conn.streams[1'u32] = H2Stream(
      id: 1'u32,
      state: ssOpen,
      request: expiredReq,
      requestStartTime: now - 1.0,
    )
    cd.h2Conn.streams[3'u32] = H2Stream(
      id: 3'u32,
      state: ssOpen,
      request: activeReq,
      requestStartTime: now,
    )
    conn.h2Streams[1'u32] = cd.h2Conn.streams[1'u32]
    conn.h2Streams[3'u32] = cd.h2Conn.streams[3'u32]
    discard failTimedOutH2Streams(addr client, addr conn, addr cd, 0, nil, now)
    (client.pendingRequests, cd.h2Conn.streams.len, conn.state)

  ## Test helper verifying that an HTTP/2 timeout drains the queued stream buffer.
  proc clientH2TimeoutDrainsQueueForTest*(): tuple[
    pendingRequests: int,
    remainingStreams: int,
    queuedStreams: int,
    sendBufLen: int,
    connState: ConnectionState
  ] =
    var client = HttpClient(pendingRequests: 2)
    var conn = PooledConnection(
      state: csOpen,
      isHttp2: true,
      h2Streams: initTable[uint32, H2Stream](),
    )
    var cd = ClientConnData(
      conn: addr conn,
      client: addr client,
      h2Conn: initH2ClientConnection(),
      h2Active: true,
    )
    cd.h2Conn.state = h2csActive
    cd.h2Conn.remoteSettings.maxConcurrentStreams = 1
    let now = epochTime()
    let expiredReq = HttpRequest(
      `method`: hmGet,
      url: "https://example.test/slow",
      host: "example.test",
      path: "/slow",
      useSsl: true,
      port: 443'u16,
      timeoutMs: 10
    )
    let queuedReq = HttpRequest(
      `method`: hmGet,
      url: "https://example.test/queued",
      host: "example.test",
      path: "/queued",
      useSsl: true,
      port: 443'u16,
      timeoutMs: 10_000
    )
    cd.h2Conn.streams[1'u32] = H2Stream(
      id: 1'u32,
      state: ssOpen,
      request: expiredReq,
      requestStartTime: now - 1.0,
    )
    conn.h2Streams[1'u32] = cd.h2Conn.streams[1'u32]
    cd.h2Conn.nextStreamId = 3'u32
    cd.h2PendingQueue.add PendingH2Request(
      req: queuedReq,
      cb: nil,
      requestStartTime: now
    )
    discard failTimedOutH2Streams(addr client, addr conn, addr cd, 0, nil, now)
    drainH2Queue(addr cd, 0, nil)
    (
      pendingRequests: client.pendingRequests,
      remainingStreams: cd.h2Conn.streams.len,
      queuedStreams: cd.h2PendingQueue.len,
      sendBufLen: conn.sendBuf.len,
      connState: conn.state
    )

proc onClientTimeoutTimer(timer: UsTimerPtr) {.cdecl.} =
  let client = clientFromTimer(timer)
  if client != nil:
    checkRequestTimeouts(client[])
    cleanupIdleConnections(client[])
    maybeAutoStop(client)

proc ensureClientTimeoutTimer(client: ptr HttpClient) =
  if client == nil or client[].loop == nil or client[].timeoutTimer != nil:
    return
  client[].timeoutTimer = us_create_timer(client[].loop, 0, cuint(sizeof(pointer)))
  if client[].timeoutTimer != nil:
    bindTimerClient(client[].timeoutTimer, client)
    us_timer_set(client[].timeoutTimer, onClientTimeoutTimer, 100, 100)

proc primeH1Parser(cd: ptr ClientConnData) {.inline.} =
  if cd.h1Parser.state == psStatusLine and cd.h1Pending.len > 0:
    cd.h1Parser.noBodyExpected = cd.h1Pending[0].noBodyExpected

proc popH1Meta(cd: ptr ClientConnData): H1PendingMeta {.inline.} =
  if cd.h1Pending.len > 0:
    return cd.h1Pending.popFirst()
  H1PendingMeta(
    requestStartTime: cd.requestStartTime,
    requestMethod: cd.requestMethod,
    requestUrl: cd.requestUrl,
    noBodyExpected: false,
  )

proc parseUrl(urlStr: string): tuple[scheme: string, host: string, port: uint16, path: string, valid: bool] {.inline.} =
  result.valid = false
  var pos = 0
  let schemeEnd = urlStr.find("://")
  if schemeEnd >= 0:
    var rawScheme = urlStr[0 ..< schemeEnd]
    for i in 0 ..< rawScheme.len:
      let c = rawScheme[i]
      if c >= 'A' and c <= 'Z':
        rawScheme[i] = chr(ord(c) + 32)
    result.scheme = rawScheme
    pos = schemeEnd + 3
  else:
    result.scheme = "http"

  if not isValidUrlScheme(result.scheme):
    return

  let hostStart = pos
  var hostEnd = hostStart
  var portStart = -1
  while hostEnd < urlStr.len:
    let c = urlStr[hostEnd]
    if c == ':':
      portStart = hostEnd + 1
      hostEnd += 1
      break
    elif c == '/' or c == '?' or c == '#':
      break
    hostEnd += 1
  result.host = urlStr[hostStart ..< hostEnd - (if portStart >= 0: 1 else: 0)]

  if not isValidHost(result.host):
    return

  if portStart >= 0:
    var portEnd = portStart
    var portVal: uint32 = 0
    while portEnd < urlStr.len and urlStr[portEnd] >= '0' and urlStr[portEnd] <= '9':
      portVal = portVal * 10 + uint32(ord(urlStr[portEnd]) - ord('0'))
      if portVal > 65535:
        return
      portEnd += 1
    if not isValidPort(uint16(portVal)):
      return
    result.port = uint16(portVal)
    pos = portEnd
  else:
    pos = hostEnd
    if result.scheme == "https":
      result.port = 443
    else:
      result.port = 80

  if pos < urlStr.len:
    let fragmentStart = urlStr.find('#', pos)
    let pathEnd = if fragmentStart >= 0: fragmentStart else: urlStr.len
    let rawPath =
      if pathEnd > pos:
        urlStr[pos ..< pathEnd]
      else:
        ""
    let pathStr =
      if rawPath.len == 0:
        "/"
      elif rawPath[0] == '?':
        "/" & rawPath
      else:
        rawPath
    if containsCRLF(pathStr) or not isValidPath(pathStr):
      return
    result.path = pathStr
  else:
    result.path = "/"

  result.valid = true

proc isH2ForbiddenHeader(name: string): bool {.inline.} =
  name == "connection" or name == "keep-alive" or name == "proxy-connection" or
    name == "transfer-encoding" or name == "upgrade" or name == "host"

proc validateRequestInputs(req: HttpRequest): bool {.inline.} =
  if not isValidHost(req.host) or not isValidPath(req.path) or not isValidBodySize(req.body.len):
    return false
  for h in req.headers:
    if not isValidHeaderName(h.name) or not isValidHeaderValue(h.value):
      return false
  true

proc h2PeerConcurrencySaturated(conn: H2ClientConnection): bool {.inline.} =
  conn.state != h2csGoaway and conn.state != h2csClosed and
    conn.nextStreamId <= 2147483645'u32 and
    uint32(conn.streams.len) >= conn.remoteSettings.maxConcurrentStreams

proc h2StreamExhausted(conn: H2ClientConnection): bool {.inline.} =
  conn.state == h2csGoaway or conn.state == h2csClosed or
    conn.nextStreamId > 2147483645'u32

proc failPendingH2Request(cd: ptr ClientConnData, pr: PendingH2Request, errMsg: string) =
  cd.client.pendingRequests = max(0, cd.client.pendingRequests - 1)
  fireRequestError(cd.client.hooks, MethodStrings[pr.req.`method`], pr.req.url, errMsg, 0.0)
  if pr.cb != nil:
    var resp: HttpResponse
    try: pr.cb(resp, errMsg)
    except CatchableError: discard
    except Defect: discard

proc startH2Stream(cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr,
                   req: HttpRequest, cb: ResponseCallback, reqStartTime: float): bool =
  let conn = cd.conn
  let streamId = cd.h2Conn.allocateStream()
  if streamId == 0:
    return false
  cd.h2Conn.streams[streamId].callback = cb
  cd.h2Conn.streams[streamId].request = req
  cd.h2Conn.streams[streamId].requestStartTime = reqStartTime
  conn.h2Streams[streamId] = cd.h2Conn.streams[streamId]

  var headers = @[
    (":method", MethodStrings[req.`method`]),
    (":path", req.path),
    (":scheme", if req.useSsl: "https" else: "http"),
    (":authority", authorityForRequest(req.host, req.port, req.useSsl)),
  ]
  for h in req.headers:
    let lowerName = h.name.toLowerAscii()
    if not isH2ForbiddenHeader(lowerName):
      headers.add((lowerName, h.value))

  let endStream = req.body.len == 0
  var buf = newStringOfCap(256)
  cd.h2Conn.sendHeaders(streamId, headers, endStream, buf)
  fireRequestHeadersSent(cd.client.hooks, MethodStrings[req.`method`], req.url, buf.len)
  if req.body.len > 0:
    cd.h2Conn.sendData(streamId, req.body, endStream = true, buf)
  socketWrite(ssl, s, buf, conn)
  true

proc drainH2QueueAsH1(cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr) =
  if cd.h2PendingQueue.len == 0:
    return
  let conn = cd.conn
  let pending = cd.h2PendingQueue
  cd.h2PendingQueue = @[]
  for pr in pending:
    var req = pr.req
    req.version = Http11
    let serialized = serializeRequest(req)
    if serialized.len == 0:
      failPendingH2Request(cd, pr, "request serialization failed")
      continue
    let reqStartTime = epochTime()
    cd.h1Pending.addLast H1PendingMeta(
      requestStartTime: reqStartTime,
      requestMethod: MethodStrings[req.`method`],
      requestUrl: req.url,
      noBodyExpected: req.`method` == hmHead,
      request: req,
    )
    conn.pendingCallbacks.addLast(pr.cb)
    primeH1Parser(cd)
    fireRequestHeadersSent(cd.client.hooks, MethodStrings[req.`method`], req.url, serialized.len)
    socketWrite(ssl, s, serialized, conn)

proc drainH2Queue(cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr) =
  if cd.h2PendingQueue.len == 0: return
  let pending = cd.h2PendingQueue
  cd.h2PendingQueue = @[]
  for pr in pending:
    if h2PeerConcurrencySaturated(cd.h2Conn):
      cd.h2PendingQueue.add pr
      continue
    if h2StreamExhausted(cd.h2Conn):
      failPendingH2Request(cd, pr, "stream ID exhausted")
      continue
    if not startH2Stream(cd, ssl, s, pr.req, pr.cb, pr.requestStartTime):
      if h2PeerConcurrencySaturated(cd.h2Conn):
        cd.h2PendingQueue.add pr
      else:
        failPendingH2Request(cd, pr, "stream ID exhausted")

proc convertQueuedH1ToH2(cd: ptr ClientConnData) =
  if cd == nil or cd.conn == nil:
    return
  while cd.conn.pendingCallbacks.len > 0 and cd.h1Pending.len > 0:
    let cb = cd.conn.pendingCallbacks.popFirst()
    let meta = cd.h1Pending.popFirst()
    cd.h2PendingQueue.add PendingH2Request(req: meta.request, cb: cb, requestStartTime: meta.requestStartTime)
  cd.conn.sendBuf.setLen(0)
  cd.conn.sendBufPos = 0
  cd.h1Parser = initHttp1Parser()

proc failQueuedH2ForAlpn(cd: ptr ClientConnData) =
  let pending = cd.h2PendingQueue
  cd.h2PendingQueue = @[]
  for pr in pending:
    failPendingH2Request(cd, pr, "HTTP/2 was not negotiated by ALPN")

proc retirePooledConnectionBeforeCallback(client: ptr HttpClient, conn: ptr PooledConnection,
                                          errMsg: string) =
  if client == nil or conn == nil:
    return
  if conn.state != csClosing and conn.state != csClosed:
    fireConnectionClose(client[].hooks, conn.host, conn.port, errMsg)
  conn.state = csClosing
  client[].pool.removeConnection(conn)

proc failH2Connection(client: ptr HttpClient, conn: ptr PooledConnection,
                      cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr,
                      errMsg: string): seq[ResponseCallback] =
  result = @[]
  if client == nil or conn == nil or cd == nil:
    return
  for _, stream in cd.h2Conn.streams:
    if stream.callback != nil:
      result.add stream.callback
  decPending(client, result.len)
  cd.h2Conn.streams.clear()
  conn.h2Streams.clear()

  let queuedStart = result.len
  for pr in cd.h2PendingQueue:
    if pr.cb != nil:
      result.add pr.cb
  decPending(client, result.len - queuedStart)
  cd.h2PendingQueue.setLen(0)
  retirePooledConnectionBeforeCallback(client, conn, errMsg)
  if s != nil:
    discard us_socket_close(ssl, s, 0, nil)

proc deliverH2CompletedStreams(client: ptr HttpClient, conn: ptr PooledConnection,
                               cd: ptr ClientConnData,
                               completed: openArray[(uint32, H2Stream)]) =
  if client == nil or conn == nil or cd == nil:
    return
  for (sid, stream) in completed:
    if sid notin cd.h2Conn.streams:
      continue
    let streamStart = if stream.requestStartTime > 0.0: stream.requestStartTime else: cd.requestStartTime
    cd.h2Conn.streams.del(sid)
    conn.h2Streams.del(sid)
    decPending(client, 1)
    if stream.callback != nil:
      let resp = HttpResponse(
        statusCode: stream.responseStatus,
        statusText: "",
        headers: stream.responseHeaders,
        body: stream.responseBody,
        version: Http20,
      )
      let totalDuration = (epochTime() - streamStart) * 1000.0
      fireResponseHeaders(client.hooks, resp.statusCode, resp.headers, totalDuration)
      fireResponseBody(client.hooks, resp.body.len, totalDuration)
      try:
        stream.callback(resp, if resp.statusCode == 0: "HTTP/2 stream closed" else: "")
      except CatchableError:
        discard
      except Defect:
        discard

proc failH1ParseError(client: ptr HttpClient, conn: ptr PooledConnection,
                      cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr): UsSocketPtr =
  if client == nil or conn == nil or cd == nil:
    return s
  let meta = popH1Meta(cd)
  decPending(client, 1)
  let started = if meta.requestStartTime > 0.0: meta.requestStartTime else: cd.requestStartTime
  let errDuration = (epochTime() - started) * 1000.0
  let errMethod = if meta.requestMethod.len > 0: meta.requestMethod else: cd.requestMethod
  let errUrl = if meta.requestUrl.len > 0: meta.requestUrl else: cd.requestUrl
  fireRequestError(client[].hooks, errMethod, errUrl, "HTTP parse error", errDuration)
  var cb: ResponseCallback = nil
  if conn.pendingCallbacks.len > 0:
    cb = conn.pendingCallbacks.popFirst()
  retirePooledConnectionBeforeCallback(client, conn, "HTTP parse error")
  if cb != nil:
    let resp = HttpResponse(statusCode: 0, statusText: "parse error")
    try:
      cb(resp, "HTTP parse error")
    except CatchableError:
      discard
    except Defect:
      discard
  maybeAutoStop(client)
  if s != nil:
    return us_socket_close(ssl, s, 0, nil)
  s

proc handleH2ClientBytes(client: ptr HttpClient, conn: ptr PooledConnection,
                         cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr,
                         dataBytes: openArray[byte]) =
  if client == nil or conn == nil or cd == nil or dataBytes.len == 0:
    return
  let wasClientInitialized = client[].initialized
  var responseBuf = newStringOfCap(128)
  let completed = cd.h2Conn.feedData(dataBytes, responseBuf)
  if responseBuf.len > 0 and s != nil:
    socketWrite(ssl, s, responseBuf, conn)

  if cd.h2Conn.localConnectionError:
    retirePooledConnectionBeforeCallback(client, conn, "HTTP/2 connection error")
  elif cd.h2Conn.state == h2csGoaway:
    retirePooledConnectionBeforeCallback(client, conn, "HTTP/2 GOAWAY")

  deliverH2CompletedStreams(client, conn, cd, completed)
  if wasClientInitialized and not client[].initialized:
    return

  if cd.h2Conn.localConnectionError:
    let callbacks = failH2Connection(client, conn, cd, ssl, s, "HTTP/2 connection error")
    let resp = HttpResponse(statusCode: 0, statusText: "HTTP/2 connection error")
    for cb in callbacks:
      try:
        cb(resp, "HTTP/2 connection error")
      except CatchableError:
        discard
      except Defect:
        discard
    maybeAutoStop(client)
    return

  drainH2Queue(cd, ssl, s)
  if cd.h2Conn.state == h2csGoaway and
     cd.h2Conn.streams.len == 0 and cd.h2PendingQueue.len == 0:
    if s != nil:
      discard us_socket_close(ssl, s, 0, nil)
    else:
      conn.state = csClosed
  maybeAutoStop(client)

when defined(nimFastHttpClientTest):
  ## Test helper checking that a GOAWAY retires the pooled HTTP/2 connection.
  proc clientH2GoawayRetiresPoolConnectionForTest*(): tuple[
    poolCount: int,
    connState: ConnectionState,
    h2State: H2ConnectionState,
    pendingRequests: int,
  ] =
    var client = HttpClient(
      pendingRequests: 0,
      pool: initConnectionPool(),
    )
    var conn = PooledConnection(
      host: "example.test",
      port: 443'u16,
      useSsl: true,
      state: csOpen,
      isHttp2: true,
      h2Streams: initTable[uint32, H2Stream](),
      pendingCallbacks: initDeque[ResponseCallback](),
    )
    client.pool.addConnection(addr conn)
    var cd = ClientConnData(
      conn: addr conn,
      client: addr client,
      h2Conn: initH2ClientConnection(),
      h2Active: true,
    )
    cd.h2Conn.state = h2csActive

    var goawayFrame = newSeq[byte](17)
    goawayFrame[2] = 8
    goawayFrame[3] = 0x07
    handleH2ClientBytes(addr client, addr conn, addr cd, 0, nil, goawayFrame)
    (
      poolCount: client.pool.countForHost("example.test", 443'u16, true),
      connState: conn.state,
      h2State: cd.h2Conn.state,
      pendingRequests: client.pendingRequests,
    )

proc responseHeaderValue(headers: seq[HttpHeader], name: string): string {.inline.} =
  for h in headers:
    if h.name.toLowerAscii() == name:
      return h.value
  ""

proc isEventStreamContentType(value: string): bool {.inline.} =
  if value.len == 0:
    return false
  let semicolon = value.find(';')
  let mediaType =
    if semicolon >= 0:
      value[0 ..< semicolon].strip()
    else:
      value.strip()
  mediaType.cmpIgnoreCase("text/event-stream") == 0

proc notifySseError(meta: H1PendingMeta, err: string) {.inline.} =
  if meta.sseOnError != nil:
    try: meta.sseOnError(err)
    except CatchableError: discard

proc notifySseDisconnect(meta: H1PendingMeta, err: string = "SSE connection closed") {.inline.} =
  if meta.isSse:
    notifySseError(meta, err)

proc notifyPendingSseDisconnects(cd: ptr ClientConnData, err: string = "SSE connection closed") =
  if cd == nil:
    return
  for meta in cd.h1Pending:
    notifySseDisconnect(meta, err)

proc processActiveSseBody(client: ptr HttpClient, cd: ptr ClientConnData): tuple[active: bool, closeNow: bool, err: string] =
  result = (active: false, closeNow: false, err: "")
  if client == nil or cd == nil or cd.h1Pending.len == 0:
    return
  let wasClientInitialized = client[].initialized
  if not cd.h1Pending[0].isSse:
    return
  result.active = true
  if cd.h1Parser.state notin {psBody, psChunkedBody, psChunkedTrailers, psDone}:
    return

  var meta = cd.h1Pending[0]
  if not meta.sseOpened:
    if cd.h1Parser.response.statusCode < 200 or cd.h1Parser.response.statusCode >= 300:
      result.closeNow = true
      result.err = "SSE response status " & $cd.h1Parser.response.statusCode
      notifySseError(meta, result.err)
      cd.h1Pending[0] = meta
      return
    let contentType = responseHeaderValue(cd.h1Parser.response.headers, "content-type")
    if not isEventStreamContentType(contentType):
      result.closeNow = true
      result.err = "SSE response is not text/event-stream"
      notifySseError(meta, result.err)
      cd.h1Pending[0] = meta
      return
    meta.sseOpened = true
    let started = if meta.requestStartTime > 0.0: meta.requestStartTime else: cd.requestStartTime
    let durationMs = (epochTime() - started) * 1000.0
    fireResponseHeaders(client.hooks, cd.h1Parser.response.statusCode, cd.h1Parser.response.headers, durationMs)
    if meta.sseOnOpen != nil:
      try: meta.sseOnOpen()
      except CatchableError: discard
      if wasClientInitialized and not client[].initialized:
        return

  if cd.h1Parser.response.body.len > 0:
    let chunkLen = cd.h1Parser.response.body.len
    let chunk = move cd.h1Parser.response.body
    cd.h1Parser.response.body = ""
    let events = meta.sseParser.feedData(chunk)
    let started = if meta.requestStartTime > 0.0: meta.requestStartTime else: cd.requestStartTime
    let durationMs = (epochTime() - started) * 1000.0
    fireResponseBody(client.hooks, chunkLen, durationMs)
    if meta.sseOnEvent != nil:
      for event in events:
        try: meta.sseOnEvent(event)
        except CatchableError: discard
        if wasClientInitialized and not client[].initialized:
          return

  if cd.h1Pending.len > 0:
    cd.h1Pending[0] = meta

proc failActiveSseStream(client: ptr HttpClient, conn: ptr PooledConnection,
                         cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr,
                         err: string): UsSocketPtr =
  if client != nil and cd != nil and cd.h1Pending.len > 0:
    let meta = cd.h1Pending[0]
    let started = if meta.requestStartTime > 0.0: meta.requestStartTime else: cd.requestStartTime
    let durationMs = (epochTime() - started) * 1000.0
    fireRequestError(client.hooks, meta.requestMethod, meta.requestUrl, err, durationMs)
  if conn != nil:
    conn.state = csClosing
  if s != nil:
    return us_socket_close(ssl, s, 0, nil)
  s

proc hasPendingSse(cd: ptr ClientConnData): bool {.inline.} =
  if cd == nil:
    return false
  for meta in cd.h1Pending:
    if meta.isSse:
      return true
  false

proc rejectWsOnH2Alpn(client: ptr HttpClient, conn: ptr PooledConnection,
                      cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr): UsSocketPtr =
  let errMsg = "WebSocket over HTTP/2 ALPN is not supported"
  if cd != nil and cd.wsConn != nil:
    cd.wsConn.manualClose = true
    cd.wsConn.state = csClosing
  retirePooledConnectionBeforeCallback(client, conn, errMsg)
  if cd != nil and cd.wsConn != nil:
    notifyWsError(cd.wsConn, errMsg)
  maybeAutoStop(client)
  if s != nil:
    return us_socket_close(ssl, s, 0, nil)
  s

proc rejectSseOnH2Alpn(client: ptr HttpClient, conn: ptr PooledConnection,
                       cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr): UsSocketPtr =
  let errMsg = "SSE over HTTP/2 is not supported"
  retirePooledConnectionBeforeCallback(client, conn, errMsg)
  if client != nil and cd != nil:
    for meta in cd.h1Pending:
      if meta.isSse:
        let started = if meta.requestStartTime > 0.0: meta.requestStartTime else: cd.requestStartTime
        fireRequestError(client[].hooks, meta.requestMethod, meta.requestUrl, errMsg, (epochTime() - started) * 1000.0)
        notifySseError(meta, errMsg)
  let callbacks = failTimedOutCallbacks(client, conn, cd, errMsg)
  let resp = HttpResponse(statusCode: 0, statusText: errMsg)
  for cb in callbacks:
    try:
      cb(resp, errMsg)
    except CatchableError:
      discard
    except Defect:
      discard
  maybeAutoStop(client)
  if s != nil:
    return us_socket_close(ssl, s, 0, nil)
  s

proc finishH1Response(client: ptr HttpClient, conn: ptr PooledConnection,
                      cd: ptr ClientConnData, ssl: cint, s: UsSocketPtr,
                      response: HttpResponse, shouldClose: var bool): tuple[stop: bool, socketResult: UsSocketPtr] =
  result = (stop: false, socketResult: s)
  let meta = popH1Meta(cd)
  client.pendingRequests -= 1
  let started = if meta.requestStartTime > 0.0: meta.requestStartTime else: cd.requestStartTime
  let totalDuration = (epochTime() - started) * 1000.0
  if not meta.isSse:
    fireResponseHeaders(client.hooks, response.statusCode, response.headers, totalDuration)
    fireResponseBody(client.hooks, response.body.len, totalDuration)
  var cb: ResponseCallback = nil
  if conn.pendingCallbacks.len > 0:
    cb = conn.pendingCallbacks.popFirst()
  if conn.recvBuf.len > 0 and cd.h1Pending.len == 0 and conn.pendingCallbacks.len == 0:
    shouldClose = true
  if shouldClose:
    conn.state = csClosing
  elif conn.pendingCallbacks.len == 0:
    client.pool.releaseConnection(conn)
    firePoolRelease(client.hooks, conn.host, conn.port, client.pool.countForHost(conn.host, conn.port, conn.useSsl))
  if cb != nil:
    let wasClientInitialized = client[].initialized
    try:
      cb(response, "")
    except CatchableError:
      discard
    except Defect:
      discard
    if wasClientInitialized and not client[].initialized:
      result.stop = true
      return
  if shouldClose:
    maybeAutoStop(client)
    result.stop = true
    result.socketResult = us_socket_close(ssl, s, 0, nil)
    return
  if conn.state == csClosed:
    maybeAutoStop(client)
    result.stop = true

proc onClientOpenKnown(ssl: cint, s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr =
  let cd = getConnData(ssl, s)
  if cd == nil: return s
  let conn = cd.conn
  let client = cd.client
  conn.socket = s
  conn.state = csOpen
  let now = epochTime()
  conn.lastUsed = now

  let connectDuration = (now - cd.connectStartTime) * 1000.0
  fireConnectEnd(client.hooks, conn.host, conn.port, connectDuration, "")

  var alpnChecked = false
  var alpnIsH2 = false
  when not defined(LIBUS_USE_IO_URING) and not defined(useIoUring):
    if client.ssl != 0:
      alpnChecked = true
      var alpnLen: cuint = 0
      let alpnProto = us_socket_get_alpn_protocol(client.ssl, s, addr alpnLen)
      if alpnProto != nil and alpnLen == 2:
        let p0 = cast[ptr UncheckedArray[char]](alpnProto)
        if p0[0] == 'h' and p0[1] == '2':
          alpnIsH2 = true

  if cd.wsConn != nil:
    if alpnIsH2:
      return rejectWsOnH2Alpn(client, conn, cd, ssl, s)
    drainSendBuf(ssl, s, conn)
    return s

  if alpnIsH2:
    if hasPendingSse(cd):
      return rejectSseOnH2Alpn(client, conn, cd, ssl, s)
    if not conn.isHttp2 and cd.h2PendingQueue.len == 0 and
       conn.pendingCallbacks.len > 0:
      cd.convertQueuedH1ToH2()
    conn.isHttp2 = true

  if alpnChecked and conn.isHttp2 and not alpnIsH2:
    if conn.h2Required:
      failQueuedH2ForAlpn(cd)
      conn.state = csClosing
      maybeAutoStop(client)
      return us_socket_close(ssl, s, 0, nil)
    conn.isHttp2 = false
    cd.h2Active = false
    drainH2QueueAsH1(cd, ssl, s)
    return s

  if conn.isHttp2:
    cd.h2Conn = initH2ClientConnection()
    cd.h2Active = true
    var buf = newStringOfCap(256)
    cd.h2Conn.writeConnectionPreface(buf)
    socketWrite(ssl, s, buf, conn)
    drainH2Queue(cd, ssl, s)
  else:
    drainSendBuf(ssl, s, conn)
  s

proc onClientOpen(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr {.cdecl.} =
  onClientOpenKnown(0, s, isClient, ip, ipLength)

proc onClientOpenSsl(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr {.cdecl.} =
  onClientOpenKnown(1, s, isClient, ip, ipLength)

proc onClientDataKnown(ssl: cint, s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr =
  if data == nil or length <= 0:
    return s
  let cd = getConnData(ssl, s)
  if cd == nil:
    let ws = getWsConnection(ssl, s)
    if ws != nil:
      return handleWsConnectionData(ws, ssl, s, data, length)
    return s
  let conn = cd.conn
  let client = cd.client

  if cd.wsConn != nil:
    return handleWsUpgradeData(client[], conn, cd, ssl, s, data, length)

  if cd.h2Active:
    if length <= 0:
      return s
    let dataBytes = cast[ptr UncheckedArray[byte]](data)
    handleH2ClientBytes(client, conn, cd, ssl, s, dataBytes.toOpenArray(0, int(length) - 1))
  else:
    if conn.pendingCallbacks.len == 0 and cd.h1Pending.len == 0:
      fireConnectionClose(client.hooks, conn.host, conn.port, "unsolicited HTTP/1 data")
      conn.state = csClosing
      return us_socket_close(ssl, s, 0, nil)
    let oldLen = conn.recvBuf.len
    if cd.h1Parser.state in {psStatusLine, psHeaders} and
        oldLen + int(length) > MaxHttp1HeaderBytes and
        not hasHttp1HeaderTerminatorWithinCap(conn.recvBuf, data, length):
      return failH1ParseError(client, conn, cd, ssl, s)
    if oldLen + int(length) > MaxClientRecvBufSize:
      let errCount = conn.pendingCallbacks.len
      var errCallbacks = newSeqOfCap[ResponseCallback](errCount)
      while conn.pendingCallbacks.len > 0:
        errCallbacks.add(conn.pendingCallbacks.popFirst())
      client.pendingRequests -= errCount
      let errDuration = (epochTime() - cd.requestStartTime) * 1000.0
      fireRequestError(client.hooks, cd.requestMethod, cd.requestUrl, "response too large", errDuration)
      conn.state = csClosed
      let closedSocket = us_socket_close(ssl, s, 0, nil)
      for ecb in errCallbacks:
        let resp = HttpResponse(statusCode: 0, statusText: "response too large")
        try:
          ecb(resp, "response too large")
        except CatchableError:
          discard
        except Defect:
          discard
      maybeAutoStop(client)
      return closedSocket
    conn.recvBuf.setLen(oldLen + int(length))
    if length > 0:
      copyMem(addr conn.recvBuf[oldLen], data, int(length))

    while conn.recvBuf.len > 0:
      primeH1Parser(cd)
      var consumed = 0
      let done = cd.h1Parser.feedData(conn.recvBuf, consumed)
      if not done:
        if consumed > 0:
          if consumed < conn.recvBuf.len:
            let remaining = conn.recvBuf.len - consumed
            moveMem(addr conn.recvBuf[0], unsafeAddr conn.recvBuf[consumed], remaining)
            conn.recvBuf.setLen(remaining)
          else:
            conn.recvBuf.setLen(0)
        let ssePump = processActiveSseBody(client, cd)
        if ssePump.closeNow:
          return failActiveSseStream(client, conn, cd, ssl, s, ssePump.err)
        break

      if consumed > 0 and consumed < conn.recvBuf.len:
        let remaining = conn.recvBuf.len - consumed
        moveMem(addr conn.recvBuf[0], unsafeAddr conn.recvBuf[consumed], remaining)
        conn.recvBuf.setLen(remaining)
      else:
        conn.recvBuf.setLen(0)

      var shouldClose = not cd.h1Parser.keepAlive
      let parserState = cd.h1Parser.state
      if parserState == psDone:
        let ssePump = processActiveSseBody(client, cd)
        if ssePump.closeNow:
          return failActiveSseStream(client, conn, cd, ssl, s, ssePump.err)
      var response: HttpResponse
      if parserState == psDone:
        response = move cd.h1Parser.response
      cd.h1Parser = initHttp1Parser()

      if parserState == psDone:
        let done = finishH1Response(client, conn, cd, ssl, s, response, shouldClose)
        if done.stop:
          return done.socketResult
      elif parserState == psError:
        return failH1ParseError(client, conn, cd, ssl, s)

    maybeAutoStop(client)
  s

proc onClientData(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} =
  onClientDataKnown(0, s, data, length)

proc onClientDataSsl(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} =
  onClientDataKnown(1, s, data, length)

when defined(nimFastHttpClientTest):
  var h1ParseErrorCbCalls {.threadvar.}: int
  var h1ParseErrorStatusAtCb {.threadvar.}: ConnectionState
  var h1ParseErrorPoolAtCb {.threadvar.}: int
  var h1ParseErrorErrLen {.threadvar.}: int
  var h1ParseErrorConnPtr {.threadvar.}: ptr PooledConnection
  var h1ParseErrorClientPtr {.threadvar.}: ptr HttpClient
  var h1ReentrantCloseClientPtr {.threadvar.}: ptr HttpClient
  var h1ReentrantCloseCalls {.threadvar.}: int

  proc resetH1ParseErrorOrderingForTest() =
    h1ParseErrorCbCalls = 0
    h1ParseErrorStatusAtCb = csOpen
    h1ParseErrorPoolAtCb = -1
    h1ParseErrorErrLen = -1
    h1ParseErrorConnPtr = nil
    h1ParseErrorClientPtr = nil
    h1ReentrantCloseClientPtr = nil
    h1ReentrantCloseCalls = 0

  proc h1ParseErrorOrderingCb(resp: HttpResponse, err: string) {.gcsafe.} =
    discard resp
    inc h1ParseErrorCbCalls
    h1ParseErrorErrLen = err.len
    if h1ParseErrorConnPtr != nil:
      h1ParseErrorStatusAtCb = h1ParseErrorConnPtr[].state
    if h1ParseErrorClientPtr != nil:
      h1ParseErrorPoolAtCb = h1ParseErrorClientPtr[].pool.countForHost("example.test", 80'u16, false)

  proc h1ReentrantCloseCb(resp: HttpResponse, err: string) {.gcsafe.} =
    discard resp
    discard err
    inc h1ReentrantCloseCalls
    if h1ReentrantCloseClientPtr != nil:
      h1ReentrantCloseClientPtr[].initialized = false

  ## Test helper verifying that an HTTP/1 parse error retires the connection before the callback.
  proc clientH1ParseErrorRetiresBeforeCallbackForTest*(): tuple[
    parserState: Http1ParseState,
    connState: ConnectionState,
    poolCount: int,
    pendingRequests: int,
    cbCalls: int,
    cbState: ConnectionState,
    cbPoolCount: int,
    cbErrLen: int,
  ] =
    resetH1ParseErrorOrderingForTest()
    var client = HttpClient(
      pendingRequests: 1,
      pool: initConnectionPool(),
    )
    var conn = PooledConnection(
      host: "example.test",
      port: 80'u16,
      useSsl: false,
      state: csOpen,
      cachedPoolKey: poolKey("example.test", 80'u16, false),
      pendingCallbacks: initDeque[ResponseCallback](1),
    )
    client.pool.addConnection(addr conn)
    var cd = ClientConnData(
      conn: addr conn,
      client: addr client,
      h1Parser: initHttp1Parser(),
      h1Pending: initDeque[H1PendingMeta](1),
      requestStartTime: epochTime(),
      requestMethod: "GET",
      requestUrl: "http://example.test/",
    )
    conn.pendingCallbacks.addLast(h1ParseErrorOrderingCb)
    cd.h1Pending.addLast H1PendingMeta(
      requestStartTime: cd.requestStartTime,
      requestMethod: "GET",
      requestUrl: cd.requestUrl,
      request: HttpRequest(`method`: hmGet, url: cd.requestUrl, timeoutMs: 30_000),
    )
    h1ParseErrorConnPtr = addr conn
    h1ParseErrorClientPtr = addr client
    var consumed = 0
    discard cd.h1Parser.feedData(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n",
      consumed
    )
    result.parserState = cd.h1Parser.state
    if cd.h1Parser.state == psError:
      discard failH1ParseError(addr client, addr conn, addr cd, 0, nil)
    result.connState = conn.state
    result.poolCount = client.pool.countForHost("example.test", 80'u16, false)
    result.pendingRequests = client.pendingRequests
    result.cbCalls = h1ParseErrorCbCalls
    result.cbState = h1ParseErrorStatusAtCb
    result.cbPoolCount = h1ParseErrorPoolAtCb
    result.cbErrLen = h1ParseErrorErrLen

  ## Test helper checking that a close inside an HTTP/1 callback stops further access.
  proc clientH1CallbackCloseStopsPostCallbackAccessForTest*(): tuple[
    calls: int,
    initialized: bool,
    stopped: bool,
    pendingRequests: int,
    poolCount: int,
  ] =
    resetH1ParseErrorOrderingForTest()
    var client = HttpClient(
      initialized: true,
      pendingRequests: 1,
      pool: initConnectionPool(),
    )
    h1ReentrantCloseClientPtr = addr client
    var conn = PooledConnection(
      host: "example.test",
      port: 80'u16,
      useSsl: false,
      state: csOpen,
      cachedPoolKey: poolKey("example.test", 80'u16, false),
      pendingCallbacks: initDeque[ResponseCallback](1),
    )
    client.pool.addConnection(addr conn)
    var cd = ClientConnData(
      conn: addr conn,
      client: addr client,
      h1Parser: initHttp1Parser(),
      h1Pending: initDeque[H1PendingMeta](1),
      requestStartTime: epochTime(),
      requestMethod: "GET",
      requestUrl: "http://example.test/",
    )
    conn.pendingCallbacks.addLast(h1ReentrantCloseCb)
    cd.h1Pending.addLast H1PendingMeta(
      requestStartTime: cd.requestStartTime,
      requestMethod: "GET",
      requestUrl: cd.requestUrl,
      request: HttpRequest(`method`: hmGet, url: cd.requestUrl, timeoutMs: 30_000),
    )
    var shouldClose = false
    let done = finishH1Response(
      addr client,
      addr conn,
      addr cd,
      0,
      nil,
      HttpResponse(statusCode: 200, statusText: "OK", body: "ok", version: Http11),
      shouldClose
    )
    result.calls = h1ReentrantCloseCalls
    result.initialized = client.initialized
    result.stopped = done.stop
    result.pendingRequests = client.pendingRequests
    result.poolCount = client.pool.countForHost("example.test", 80'u16, false)

  var h2OrderingStep {.threadvar.}: int
  var h2OrderingCompletedCalls {.threadvar.}: int
  var h2OrderingFailedCalls {.threadvar.}: int
  var h2OrderingCompletedOrder {.threadvar.}: int
  var h2OrderingFailedOrder {.threadvar.}: int
  var h2OrderingCompletedStatus {.threadvar.}: int
  var h2OrderingCompletedErrLen {.threadvar.}: int
  var h2OrderingCompletedVersion {.threadvar.}: int
  var h2OrderingFailedStatus {.threadvar.}: int
  var h2OrderingFailedErrLen {.threadvar.}: int
  var h2OrderingConnStateAtCompleted {.threadvar.}: ConnectionState
  var h2OrderingPoolAtCompleted {.threadvar.}: int
  var h2OrderingConnPtr {.threadvar.}: ptr PooledConnection
  var h2OrderingClientPtr {.threadvar.}: ptr HttpClient
  var h2ReentrantCloseClientPtr {.threadvar.}: ptr HttpClient
  var h2ReentrantCloseCalls {.threadvar.}: int

  proc resetH2OrderingForTest() =
    h2OrderingStep = 0
    h2OrderingCompletedCalls = 0
    h2OrderingFailedCalls = 0
    h2OrderingCompletedOrder = 0
    h2OrderingFailedOrder = 0
    h2OrderingCompletedStatus = 0
    h2OrderingCompletedErrLen = -1
    h2OrderingCompletedVersion = -1
    h2OrderingFailedStatus = -1
    h2OrderingFailedErrLen = -1
    h2OrderingConnStateAtCompleted = csOpen
    h2OrderingPoolAtCompleted = -1
    h2OrderingConnPtr = nil
    h2OrderingClientPtr = nil
    h2ReentrantCloseClientPtr = nil
    h2ReentrantCloseCalls = 0

  proc h2OrderingCompletedCb(resp: HttpResponse, err: string) {.gcsafe.} =
    inc h2OrderingStep
    inc h2OrderingCompletedCalls
    h2OrderingCompletedOrder = h2OrderingStep
    h2OrderingCompletedStatus = resp.statusCode
    h2OrderingCompletedErrLen = err.len
    h2OrderingCompletedVersion = ord(resp.version)
    if h2OrderingConnPtr != nil:
      h2OrderingConnStateAtCompleted = h2OrderingConnPtr[].state
    if h2OrderingClientPtr != nil:
      h2OrderingPoolAtCompleted = h2OrderingClientPtr[].pool.countForHost("example.test", 443'u16, true)

  proc h2OrderingFailedCb(resp: HttpResponse, err: string) {.gcsafe.} =
    inc h2OrderingStep
    inc h2OrderingFailedCalls
    h2OrderingFailedOrder = h2OrderingStep
    h2OrderingFailedStatus = resp.statusCode
    h2OrderingFailedErrLen = err.len

  proc h2ReentrantCloseCb(resp: HttpResponse, err: string) {.gcsafe.} =
    discard resp
    discard err
    inc h2ReentrantCloseCalls
    if h2ReentrantCloseClientPtr != nil:
      h2ReentrantCloseClientPtr[].initialized = false

  proc appendH2TestFrame(buf: var string, frameType: byte, flags: byte,
                         streamId: uint32, payload: string) =
    let length = payload.len
    let sid = streamId and 0x7FFFFFFF'u32
    buf.add chr((length shr 16) and 0xFF)
    buf.add chr((length shr 8) and 0xFF)
    buf.add chr(length and 0xFF)
    buf.add chr(int(frameType))
    buf.add chr(int(flags))
    buf.add chr(int((sid shr 24) and 0xFF'u32))
    buf.add chr(int((sid shr 16) and 0xFF'u32))
    buf.add chr(int((sid shr 8) and 0xFF'u32))
    buf.add chr(int(sid and 0xFF'u32))
    buf.add payload

  ## Test helper verifying the callback order of completed and failed HTTP/2 streams on error.
  proc clientH2ConnectionErrorCallbackOrderingForTest*(): tuple[
    completedCalls: int,
    failedCalls: int,
    completedOrder: int,
    failedOrder: int,
    completedStatus: int,
    completedErrLen: int,
    completedVersion: int,
    failedStatus: int,
    failedErrLen: int,
    pendingRequests: int,
    remainingStreams: int,
    connStreams: int,
    connState: ConnectionState,
    localConnectionError: bool,
    completedCbConnState: ConnectionState,
    completedCbPoolCount: int,
  ] =
    resetH2OrderingForTest()
    var client = HttpClient(
      pendingRequests: 2,
      pool: initConnectionPool(),
    )
    var conn = PooledConnection(
      host: "example.test",
      port: 443'u16,
      useSsl: true,
      state: csOpen,
      isHttp2: true,
      h2Streams: initTable[uint32, H2Stream](),
    )
    client.pool.addConnection(addr conn)
    h2OrderingConnPtr = addr conn
    h2OrderingClientPtr = addr client

    var cd = ClientConnData(
      conn: addr conn,
      client: addr client,
      h2Conn: initH2ClientConnection(),
      h2Active: true,
      requestStartTime: epochTime(),
    )
    cd.h2Conn.state = h2csActive

    let sid1 = cd.h2Conn.allocateStream()
    let sid3 = cd.h2Conn.allocateStream()
    cd.h2Conn.streams[sid1].request = HttpRequest(`method`: hmGet, url: "https://example.test/one", timeoutMs: 30_000)
    cd.h2Conn.streams[sid1].requestStartTime = epochTime()
    cd.h2Conn.streams[sid1].callback = h2OrderingCompletedCb
    cd.h2Conn.streams[sid3].request = HttpRequest(`method`: hmGet, url: "https://example.test/two", timeoutMs: 30_000)
    cd.h2Conn.streams[sid3].requestStartTime = epochTime()
    cd.h2Conn.streams[sid3].callback = h2OrderingFailedCb
    conn.h2Streams[sid1] = cd.h2Conn.streams[sid1]
    conn.h2Streams[sid3] = cd.h2Conn.streams[sid3]

    var frames = ""
    var okHeaders = ""
    okHeaders.add chr(0x88)
    appendH2TestFrame(frames, 0x1'u8, 0x5'u8, sid1, okHeaders)
    appendH2TestFrame(frames, 0x6'u8, 0x0'u8, 0'u32, "bad!")

    handleH2ClientBytes(addr client, addr conn, addr cd, 0, nil, cast[seq[byte]](frames))

    result.completedCalls = h2OrderingCompletedCalls
    result.failedCalls = h2OrderingFailedCalls
    result.completedOrder = h2OrderingCompletedOrder
    result.failedOrder = h2OrderingFailedOrder
    result.completedStatus = h2OrderingCompletedStatus
    result.completedErrLen = h2OrderingCompletedErrLen
    result.completedVersion = h2OrderingCompletedVersion
    result.failedStatus = h2OrderingFailedStatus
    result.failedErrLen = h2OrderingFailedErrLen
    result.pendingRequests = client.pendingRequests
    result.remainingStreams = cd.h2Conn.streams.len
    result.connStreams = conn.h2Streams.len
    result.connState = conn.state
    result.localConnectionError = cd.h2Conn.localConnectionError
    result.completedCbConnState = h2OrderingConnStateAtCompleted
    result.completedCbPoolCount = h2OrderingPoolAtCompleted

  ## Test helper checking that a close inside an HTTP/2 callback stops queue drain.
  proc clientH2CallbackCloseStopsQueueDrainForTest*(): tuple[
    calls: int,
    initialized: bool,
    queuedStreams: int,
    activeStreams: int,
    sendBufLen: int,
  ] =
    resetH2OrderingForTest()
    var client = HttpClient(
      initialized: true,
      pendingRequests: 2,
      pool: initConnectionPool(),
    )
    h2ReentrantCloseClientPtr = addr client
    var conn = PooledConnection(
      host: "example.test",
      port: 443'u16,
      useSsl: true,
      state: csOpen,
      isHttp2: true,
      h2Streams: initTable[uint32, H2Stream](),
      sendBuf: newStringOfCap(256),
    )
    var cd = ClientConnData(
      conn: addr conn,
      client: addr client,
      h2Conn: initH2ClientConnection(),
      h2Active: true,
      requestStartTime: epochTime(),
    )
    cd.h2Conn.state = h2csActive
    let completedSid = cd.h2Conn.allocateStream()
    cd.h2Conn.streams[completedSid].request = HttpRequest(`method`: hmGet, url: "https://example.test/one", timeoutMs: 30_000)
    cd.h2Conn.streams[completedSid].requestStartTime = epochTime()
    cd.h2Conn.streams[completedSid].callback = h2ReentrantCloseCb
    conn.h2Streams[completedSid] = cd.h2Conn.streams[completedSid]
    cd.h2PendingQueue.add PendingH2Request(
      req: HttpRequest(`method`: hmGet, url: "https://example.test/two", host: "example.test", path: "/two", useSsl: true, timeoutMs: 30_000),
      cb: h2OrderingFailedCb,
      requestStartTime: epochTime()
    )

    var frames = ""
    var okHeaders = ""
    okHeaders.add chr(0x88)
    appendH2TestFrame(frames, 0x1'u8, 0x5'u8, completedSid, okHeaders)
    handleH2ClientBytes(addr client, addr conn, addr cd, 0, nil, cast[seq[byte]](frames))

    result.calls = h2ReentrantCloseCalls
    result.initialized = client.initialized
    result.queuedStreams = cd.h2PendingQueue.len
    result.activeStreams = cd.h2Conn.streams.len
    result.sendBufLen = conn.sendBuf.len

  var alpnWsErrorCount {.threadvar.}: int
  var alpnSseErrorCount {.threadvar.}: int
  var alpnSseDoneCount {.threadvar.}: int

  proc resetAlpnIncompatibleForTest() =
    alpnWsErrorCount = 0
    alpnSseErrorCount = 0
    alpnSseDoneCount = 0

  proc alpnWsErrorCb(err: string) {.gcsafe.} =
    discard err
    inc alpnWsErrorCount

  proc alpnSseErrorCb(err: string) {.gcsafe.} =
    discard err
    inc alpnSseErrorCount

  proc alpnSseDoneCb(resp: HttpResponse, err: string) {.gcsafe.} =
    discard resp
    discard err
    inc alpnSseDoneCount

  ## Test helper verifying that ALPN rejects incompatible HTTP/2 protocol offers.
  proc clientAlpnH2RejectsIncompatibleForTest*(): tuple[
    wsConnState: ConnectionState,
    wsPoolCount: int,
    wsErrorCount: int,
    wsManualClose: bool,
    sseConnState: ConnectionState,
    ssePoolCount: int,
    sseErrorCount: int,
    sseDoneCount: int,
    ssePendingRequests: int,
  ] =
    resetAlpnIncompatibleForTest()
    var wsClient = HttpClient(pool: initConnectionPool())
    var wsConn = PooledConnection(
      host: "example.test",
      port: 443'u16,
      useSsl: true,
      state: csOpen,
      cachedPoolKey: poolKey("example.test", 443'u16, true),
      pendingCallbacks: initDeque[ResponseCallback](1),
    )
    wsClient.pool.addConnection(addr wsConn)
    let ws = newWsConnection()
    initWsClientDefaults(ws)
    ws.onError = alpnWsErrorCb
    var wsCd = ClientConnData(
      conn: addr wsConn,
      client: addr wsClient,
      wsConn: ws,
      h1Pending: initDeque[H1PendingMeta](1),
    )
    discard rejectWsOnH2Alpn(addr wsClient, addr wsConn, addr wsCd, 1, nil)
    result.wsConnState = wsConn.state
    result.wsPoolCount = wsClient.pool.countForHost("example.test", 443'u16, true)
    result.wsErrorCount = alpnWsErrorCount
    result.wsManualClose = ws.manualClose

    var sseClient = HttpClient(
      pendingRequests: 1,
      pool: initConnectionPool(),
    )
    var sseConn = PooledConnection(
      host: "example.test",
      port: 443'u16,
      useSsl: true,
      state: csOpen,
      cachedPoolKey: poolKey("example.test", 443'u16, true),
      pendingCallbacks: initDeque[ResponseCallback](1),
    )
    sseClient.pool.addConnection(addr sseConn)
    sseConn.pendingCallbacks.addLast(alpnSseDoneCb)
    var sseCd = ClientConnData(
      conn: addr sseConn,
      client: addr sseClient,
      h1Pending: initDeque[H1PendingMeta](1),
      requestStartTime: epochTime(),
      requestMethod: "GET",
      requestUrl: "https://example.test/events",
    )
    sseCd.h1Pending.addLast H1PendingMeta(
      requestStartTime: sseCd.requestStartTime,
      requestMethod: "GET",
      requestUrl: sseCd.requestUrl,
      request: HttpRequest(`method`: hmGet, url: sseCd.requestUrl, timeoutMs: 0),
      isSse: true,
      sseOnError: alpnSseErrorCb,
    )
    discard rejectSseOnH2Alpn(addr sseClient, addr sseConn, addr sseCd, 1, nil)
    result.sseConnState = sseConn.state
    result.ssePoolCount = sseClient.pool.countForHost("example.test", 443'u16, true)
    result.sseErrorCount = alpnSseErrorCount
    result.sseDoneCount = alpnSseDoneCount
    result.ssePendingRequests = sseClient.pendingRequests

  var sseStreamingEventCount {.threadvar.}: int
  var sseStreamingFirstData {.threadvar.}: string
  var sseStreamingSecondData {.threadvar.}: string
  var sseDisconnectErrorCount {.threadvar.}: int
  var sseDisconnectLastError {.threadvar.}: string
  var sseReentrantCloseClientPtr {.threadvar.}: ptr HttpClient
  var sseReentrantCloseEventCount {.threadvar.}: int

  proc resetSseStreamingForTest() =
    sseStreamingEventCount = 0
    sseStreamingFirstData = ""
    sseStreamingSecondData = ""
    sseDisconnectErrorCount = 0
    sseDisconnectLastError = ""
    sseReentrantCloseClientPtr = nil
    sseReentrantCloseEventCount = 0

  proc sseStreamingEventCb(event: SseEvent) {.gcsafe.} =
    inc sseStreamingEventCount
    if sseStreamingEventCount == 1:
      sseStreamingFirstData = event.data
    elif sseStreamingEventCount == 2:
      sseStreamingSecondData = event.data

  proc sseDisconnectErrorCb(err: string) {.gcsafe.} =
    inc sseDisconnectErrorCount
    sseDisconnectLastError = err

  proc sseReentrantCloseEventCb(event: SseEvent) {.gcsafe.} =
    discard event
    inc sseReentrantCloseEventCount
    if sseReentrantCloseClientPtr != nil:
      sseReentrantCloseClientPtr[].initialized = false

  ## Test helper checking that SSE disconnects notify direct and pending error callbacks.
  proc clientSseDisconnectNotifiesForTest*(): tuple[directCount: int, pendingCount: int, lastError: string] =
    resetSseStreamingForTest()
    let meta = H1PendingMeta(
      isSse: true,
      sseOnError: sseDisconnectErrorCb,
    )
    notifySseDisconnect(meta)
    result.directCount = sseDisconnectErrorCount

    var cd = ClientConnData(
      h1Pending: initDeque[H1PendingMeta](1),
    )
    cd.h1Pending.addLast H1PendingMeta(
      isSse: true,
      sseOnError: sseDisconnectErrorCb,
    )
    notifyPendingSseDisconnects(addr cd)
    result.pendingCount = sseDisconnectErrorCount
    result.lastError = sseDisconnectLastError

  ## Test helper verifying incremental SSE event delivery while the stream is open.
  proc clientSseStreamingIncrementalForTest*(): tuple[
    doneAfterFirst: bool,
    openedAfterFirst: bool,
    eventCountAfterFirst: int,
    bodyAfterFirst: int,
    eventCountAfterSecond: int,
    firstData: string,
    secondData: string,
    lastEventId: string,
    retryMs: int,
    parserBufLen: int,
    responseBodyLen: int,
  ] =
    resetSseStreamingForTest()
    var client = HttpClient(pendingRequests: 1)
    var conn = PooledConnection(
      state: csOpen,
      pendingCallbacks: initDeque[ResponseCallback](1),
    )
    let req = HttpRequest(
      `method`: hmGet,
      url: "http://example.test/events",
      timeoutMs: 0,
    )
    var cd = ClientConnData(
      conn: addr conn,
      client: addr client,
      h1Parser: initHttp1Parser(),
      h1Pending: initDeque[H1PendingMeta](1),
      requestStartTime: epochTime(),
      requestMethod: "GET",
      requestUrl: req.url,
    )
    let cb = proc(resp: HttpResponse, err: string) {.gcsafe.} =
      discard resp
      discard err
    conn.pendingCallbacks.addLast(cb)
    cd.h1Pending.addLast H1PendingMeta(
      requestStartTime: cd.requestStartTime,
      requestMethod: "GET",
      requestUrl: req.url,
      request: req,
      isSse: true,
      sseParser: initSseParser(),
      sseOnEvent: sseStreamingEventCb,
    )

    var consumed = 0
    let first = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" &
      ": keepalive\n\n" &
      "data: one\nid: 1\n\n"
    result.doneAfterFirst = cd.h1Parser.feedData(first, consumed)
    discard processActiveSseBody(addr client, addr cd)
    result.openedAfterFirst = cd.h1Pending[0].sseOpened
    result.eventCountAfterFirst = sseStreamingEventCount
    result.bodyAfterFirst = cd.h1Parser.response.body.len

    consumed = 0
    discard cd.h1Parser.feedData("retry: 25\ndata: two\n\n", consumed)
    discard processActiveSseBody(addr client, addr cd)
    result.eventCountAfterSecond = sseStreamingEventCount
    result.firstData = sseStreamingFirstData
    result.secondData = sseStreamingSecondData
    result.lastEventId = cd.h1Pending[0].sseParser.lastEventId
    result.retryMs = cd.h1Pending[0].sseParser.retryMs
    result.parserBufLen = cd.h1Pending[0].sseParser.buf.len
    result.responseBodyLen = cd.h1Parser.response.body.len

  ## Test helper checking that a close inside an SSE callback stops metadata writes.
  proc clientSseCallbackCloseStopsMetadataWriteForTest*(): tuple[
    eventCount: int,
    initialized: bool,
    openedStored: bool,
    lastEventId: string,
    parserBufLen: int,
  ] =
    resetSseStreamingForTest()
    var client = HttpClient(initialized: true, pendingRequests: 1)
    sseReentrantCloseClientPtr = addr client
    var conn = PooledConnection(
      state: csOpen,
      pendingCallbacks: initDeque[ResponseCallback](1),
    )
    var cd = ClientConnData(
      conn: addr conn,
      client: addr client,
      h1Parser: initHttp1Parser(),
      h1Pending: initDeque[H1PendingMeta](1),
      requestStartTime: epochTime(),
      requestMethod: "GET",
      requestUrl: "http://example.test/events",
    )
    cd.h1Pending.addLast H1PendingMeta(
      requestStartTime: cd.requestStartTime,
      requestMethod: "GET",
      requestUrl: cd.requestUrl,
      request: HttpRequest(`method`: hmGet, url: cd.requestUrl, timeoutMs: 30_000),
      isSse: true,
      sseParser: initSseParser(),
      sseOnEvent: sseReentrantCloseEventCb,
    )

    var consumed = 0
    discard cd.h1Parser.feedData(
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" &
      "data: one\nid: 1\n\n",
      consumed
    )
    discard processActiveSseBody(addr client, addr cd)
    result.eventCount = sseReentrantCloseEventCount
    result.initialized = client.initialized
    result.openedStored = cd.h1Pending[0].sseOpened
    result.lastEventId = cd.h1Pending[0].sseParser.lastEventId
    result.parserBufLen = cd.h1Pending[0].sseParser.buf.len

proc onClientWritableKnown(ssl: cint, s: UsSocketPtr): UsSocketPtr =
  let cd = getConnData(ssl, s)
  if cd == nil:
    let ws = getWsConnection(ssl, s)
    if ws != nil:
      drainWsSendBuf(ws, ssl, s)
    return s
  drainSendBuf(ssl, s, cd.conn)
  s

proc onClientWritable(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  onClientWritableKnown(0, s)

proc onClientWritableSsl(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  onClientWritableKnown(1, s)

proc onClientCloseKnown(ssl: cint, s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr =
  let cd = getConnData(ssl, s)
  if cd == nil:
    let ws = getWsConnection(ssl, s)
    if ws != nil:
      if ws.owner != nil:
        untrackActiveWs(cast[ptr HttpClient](ws.owner), ws)
      let wasClosing = ws.state == csClosing or ws.state == csClosed
      stopWsActiveTimers(ws)
      ws.state = csClosed
      ws.socket = nil
      let ext = us_socket_ext(ssl, s)
      if ext != nil:
        storeInExt(ext, nil)
      if not ws.closeNotified:
        let closeCode =
          if ws.closeCode != 1005'u16: ws.closeCode
          elif wasClosing and ws.closeFrameSent: 1000'u16
          else: 1006'u16
        let closeReason =
          if ws.closeReason.len > 0: ws.closeReason
          elif closeCode == 1006'u16: "Socket closed"
          else: ""
        notifyWsCloseOnce(ws, closeCode, closeReason)
      scheduleWsReconnect(ws)
      return s
    return s
  let conn = cd.conn
  let client = cd.client

  if cd.wsConn != nil:
    let ws = cd.wsConn
    fireConnectionClose(client.hooks, conn.host, conn.port, "websocket closed before upgrade (code " & $code & ")")
    conn.state = csClosed
    client.pool.removeConnection(conn)
    let ext = us_socket_ext(ssl, s)
    if ext != nil:
      storeInExt(ext, nil)
    `=destroy`(cd[])
    dealloc(cd)
    `=destroy`(conn[])
    dealloc(conn)
    ws.socket = nil
    ws.state = csClosed
    if not ws.manualClose:
      notifyWsError(ws, "websocket connection closed before upgrade")
    scheduleWsReconnect(ws)
    maybeAutoStop(client)
    return s

  fireConnectionClose(client.hooks, conn.host, conn.port, "closed (code " & $code & ")")

  conn.state = csClosed
  client.pool.removeConnection(conn)

  var h2Callbacks: seq[ResponseCallback]
  if cd.h2Active:
    h2Callbacks = newSeqOfCap[ResponseCallback](cd.h2Conn.streams.len)
    for streamId, stream in cd.h2Conn.streams:
      if stream.callback != nil:
        h2Callbacks.add(stream.callback)
      client.pendingRequests -= 1
    cd.h2Conn.streams.clear()
    for pr in cd.h2PendingQueue:
      if pr.cb != nil:
        h2Callbacks.add(pr.cb)
      client.pendingRequests -= 1
    cd.h2PendingQueue.setLen(0)

  var h1Callbacks: seq[ResponseCallback]
  var closeDelimited: seq[tuple[cb: ResponseCallback, resp: HttpResponse]]
  if not cd.h2Active and cd.h1Parser.state == psBody and
     cd.h1Parser.contentLength < 0 and cd.h1Parser.response.statusCode > 0 and
     conn.pendingCallbacks.len > 0:
    discard processActiveSseBody(client, cd)
    let completed = move cd.h1Parser.response
    let meta = popH1Meta(cd)
    let started = if meta.requestStartTime > 0.0: meta.requestStartTime else: cd.requestStartTime
    let totalDuration = (epochTime() - started) * 1000.0
    if not meta.isSse:
      fireResponseHeaders(client.hooks, completed.statusCode, completed.headers, totalDuration)
      fireResponseBody(client.hooks, completed.body.len, totalDuration)
    else:
      notifySseDisconnect(meta)
    let cb = conn.pendingCallbacks.popFirst()
    client.pendingRequests -= 1
    closeDelimited.add((cb: cb, resp: completed))
  notifyPendingSseDisconnects(cd)
  let h1Count = conn.pendingCallbacks.len
  if h1Count > 0:
    h1Callbacks = newSeqOfCap[ResponseCallback](h1Count)
    while conn.pendingCallbacks.len > 0:
      h1Callbacks.add(conn.pendingCallbacks.popFirst())
    client.pendingRequests -= h1Count

  let ext = us_socket_ext(ssl, s)
  if ext != nil:
    storeInExt(ext, nil)

  `=destroy`(cd[])
  dealloc(cd)
  `=destroy`(conn[])
  dealloc(conn)

  for cb in h2Callbacks:
    let resp = HttpResponse(statusCode: 0, statusText: "connection closed")
    try:
      cb(resp, "connection closed")
    except CatchableError:
      discard
    except Defect:
      discard
  for item in closeDelimited:
    try:
      item.cb(item.resp, "")
    except CatchableError:
      discard
    except Defect:
      discard
  for cb in h1Callbacks:
    let resp = HttpResponse(statusCode: 0, statusText: "connection closed")
    try:
      cb(resp, "connection closed")
    except CatchableError:
      discard
    except Defect:
      discard

  maybeAutoStop(client)
  s

proc onClientClose(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.} =
  onClientCloseKnown(0, s, code, reason)

proc onClientCloseSsl(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.} =
  onClientCloseKnown(1, s, code, reason)

proc onClientEndKnown(ssl: cint, s: UsSocketPtr): UsSocketPtr =
  discard us_socket_close(ssl, s, 0, nil)
  s

proc onClientEnd(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  onClientEndKnown(0, s)

proc onClientEndSsl(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  onClientEndKnown(1, s)

proc onClientConnectErrorKnown(ssl: cint, s: UsSocketPtr, code: cint): UsSocketPtr =
  let cd = getConnData(ssl, s)
  if cd == nil: return s
  let client = cd.client
  let conn = cd.conn

  let connectDuration = (epochTime() - cd.connectStartTime) * 1000.0
  let errMsg = "connect error (code " & $code & ")"
  fireConnectEnd(client.hooks, conn.host, conn.port, connectDuration, errMsg)
  fireConnectionClose(client.hooks, conn.host, conn.port, errMsg)

  if cd.wsConn != nil:
    let ws = cd.wsConn
    conn.state = csClosed
    client.pool.removeConnection(conn)
    let ext = us_socket_ext(ssl, s)
    if ext != nil:
      storeInExt(ext, nil)
    `=destroy`(cd[])
    dealloc(cd)
    `=destroy`(conn[])
    dealloc(conn)
    ws.socket = nil
    ws.state = csClosed
    notifyWsError(ws, errMsg)
    scheduleWsReconnect(ws)
    maybeAutoStop(client)
    return s

  conn.state = csClosed
  client.pool.removeConnection(conn)

  var h2Pending = move cd.h2PendingQueue
  cd.h2PendingQueue = @[]
  client.pendingRequests -= h2Pending.len

  var h1Callbacks: seq[ResponseCallback]
  let h1Count = conn.pendingCallbacks.len
  if h1Count > 0:
    h1Callbacks = newSeqOfCap[ResponseCallback](h1Count)
    while conn.pendingCallbacks.len > 0:
      h1Callbacks.add(conn.pendingCallbacks.popFirst())
    client.pendingRequests -= h1Count

  let ext = us_socket_ext(ssl, s)
  if ext != nil:
    storeInExt(ext, nil)

  `=destroy`(cd[])
  dealloc(cd)
  `=destroy`(conn[])
  dealloc(conn)

  for pr in h2Pending:
    if pr.cb != nil:
      let resp = HttpResponse(statusCode: 0, statusText: "connect error")
      try:
        pr.cb(resp, errMsg)
      except CatchableError:
        discard
      except Defect:
        discard
  for cb in h1Callbacks:
    let resp = HttpResponse(statusCode: 0, statusText: "connect error")
    try:
      cb(resp, errMsg)
    except CatchableError:
      discard
    except Defect:
      discard

  maybeAutoStop(client)
  s

proc onClientConnectError(s: UsSocketPtr, code: cint): UsSocketPtr {.cdecl.} =
  onClientConnectErrorKnown(0, s, code)

proc onClientConnectErrorSsl(s: UsSocketPtr, code: cint): UsSocketPtr {.cdecl.} =
  onClientConnectErrorKnown(1, s, code)

proc loopWakeup(loop: UsLoopPtr) {.cdecl.} = discard
proc loopPre(loop: UsLoopPtr) {.cdecl.} = discard
proc loopPost(loop: UsLoopPtr) {.cdecl.} = discard

proc bindClientOwner(client: var HttpClient) {.inline.} =
  client.ownerAddress = cast[pointer](addr client)

proc ensureClientOwner(client: var HttpClient, operation: string) {.inline.} =
  if client.initialized and
      client.ownerAddress != nil and
      client.ownerAddress != cast[pointer](addr client):
    raise newException(ValueError, "HttpClient was moved after initialization; " & operation & " refused to avoid unsafe native resource ownership")

## Initializes the native uSockets loop and TLS context for this client.
proc initClient*(client: var HttpClient, ssl: bool = false) =
  ensureClientOwner(client, "initClient")
  if client.initialized: return
  bindClientOwner(client)
  let sslFlag: cint = if ssl: 1 else: 0
  client.ssl = sslFlag

  client.loop = us_create_loop(nil, loopWakeup, loopPre, loopPost, cuint(sizeof(pointer)))
  if client.loop == nil:
    return
  client.ownsLoop = true
  let loopExt = us_loop_ext(client.loop)
  storeInExt(loopExt, addr client)

  let options = client.tlsOptions
  client.ctx = us_create_socket_context(sslFlag, client.loop, ClientContextExtSize, options)
  if client.ctx == nil:
    if client.ownsLoop and client.loop != nil:
      us_loop_free(client.loop)
    client.loop = nil
    client.ownsLoop = false
    return
  let ctxExt = us_socket_context_ext(sslFlag, client.ctx)
  storeInExt(ctxExt, addr client)

  if sslFlag != 0:
    us_socket_context_on_open(sslFlag, client.ctx, onClientOpenSsl)
    us_socket_context_on_data(sslFlag, client.ctx, onClientDataSsl)
    us_socket_context_on_writable(sslFlag, client.ctx, onClientWritableSsl)
    us_socket_context_on_close(sslFlag, client.ctx, onClientCloseSsl)
    us_socket_context_on_end(sslFlag, client.ctx, onClientEndSsl)
    us_socket_context_on_connect_error(sslFlag, client.ctx, onClientConnectErrorSsl)
  else:
    us_socket_context_on_open(sslFlag, client.ctx, onClientOpen)
    us_socket_context_on_data(sslFlag, client.ctx, onClientData)
    us_socket_context_on_writable(sslFlag, client.ctx, onClientWritable)
    us_socket_context_on_close(sslFlag, client.ctx, onClientClose)
    us_socket_context_on_end(sslFlag, client.ctx, onClientEnd)
    us_socket_context_on_connect_error(sslFlag, client.ctx, onClientConnectError)
  ensureClientTimeoutTimer(addr client)

  client.initialized = true

## Initializes the client on an existing uSockets loop instead of creating a new one.
proc initClientWithLoop*(client: var HttpClient, loop: UsLoopPtr, ssl: bool = false) =
  ensureClientOwner(client, "initClientWithLoop")
  if client.initialized: return
  if loop == nil: return
  bindClientOwner(client)
  let sslFlag: cint = if ssl: 1 else: 0
  client.ssl = sslFlag
  client.loop = loop
  client.ownsLoop = false

  let options = client.tlsOptions
  client.ctx = us_create_socket_context(sslFlag, client.loop, ClientContextExtSize, options)
  if client.ctx == nil:
    client.loop = nil
    client.ownsLoop = false
    return
  let ctxExt = us_socket_context_ext(sslFlag, client.ctx)
  storeInExt(ctxExt, addr client)

  if sslFlag != 0:
    us_socket_context_on_open(sslFlag, client.ctx, onClientOpenSsl)
    us_socket_context_on_data(sslFlag, client.ctx, onClientDataSsl)
    us_socket_context_on_writable(sslFlag, client.ctx, onClientWritableSsl)
    us_socket_context_on_close(sslFlag, client.ctx, onClientCloseSsl)
    us_socket_context_on_end(sslFlag, client.ctx, onClientEndSsl)
    us_socket_context_on_connect_error(sslFlag, client.ctx, onClientConnectErrorSsl)
  else:
    us_socket_context_on_open(sslFlag, client.ctx, onClientOpen)
    us_socket_context_on_data(sslFlag, client.ctx, onClientData)
    us_socket_context_on_writable(sslFlag, client.ctx, onClientWritable)
    us_socket_context_on_close(sslFlag, client.ctx, onClientClose)
    us_socket_context_on_end(sslFlag, client.ctx, onClientEnd)
    us_socket_context_on_connect_error(sslFlag, client.ctx, onClientConnectError)
  ensureClientTimeoutTimer(addr client)

  client.initialized = true

## Creates an unconfigured client with pool and timeout defaults; call `initClient` before use.
proc newHttpClient*(maxConnsPerHost: int = 6, defaultTimeoutMs: int = 30000,
                    preferH2: bool = false,
                    tlsOptions: UsSocketContextOptions = defaultSocketContextOptions()): HttpClient =
  result.pool = initConnectionPool(maxConnsPerHost)
  result.defaultTimeoutMs = defaultTimeoutMs
  result.connectTimeoutMs = 5000
  result.defaultFollowRedirects = true
  result.defaultMaxRedirects = 10
  result.preferH2 = preferH2
  result.tlsOptions = tlsOptions

## Creates a client from a configured `HttpClientConfig` value.
proc newHttpClientFromConfig*(config: HttpClientConfig): HttpClient =
  result = newHttpClient(
    maxConnsPerHost = config.maxConnsPerHost,
    defaultTimeoutMs = config.requestTimeoutMs,
    preferH2 = config.preferH2,
    tlsOptions = config.tlsOptions,
  )
  result.defaultHeaders = config.defaultHeaders
  result.pool.idleTimeoutSec = config.keepAliveTimeoutMs.float / 1000.0
  result.maxRetries = config.maxRetries
  result.retryDelayMs = config.retryDelayMs
  result.retryOnStatusCodes = config.retryOnStatusCodes
  result.connectTimeoutMs = config.connectTimeoutMs
  result.keepAliveTimeoutMs = config.keepAliveTimeoutMs
  result.hooks = config.hooks

proc buildRequest(client: HttpClient, httpMethod: HttpMethod, urlStr: string, body: string = "", headers: seq[HttpHeader] = @[]): tuple[req: HttpRequest, valid: bool] {.inline.} =
  let (scheme, host, port, path, valid) = parseUrl(urlStr)
  result.valid = valid
  if not valid or not isValidBodySize(body.len):
    result.valid = false
    return
  result.req.`method` = httpMethod
  result.req.url = urlStr
  result.req.host = host
  result.req.port = port
  result.req.path = path
  result.req.useSsl = scheme == "https"
  result.req.body = body
  result.req.version = Http11
  if client.defaultHeaders.len > 0 and headers.len > 0:
    result.req.headers = newSeqOfCap[HttpHeader](client.defaultHeaders.len + headers.len)
    for h in client.defaultHeaders: result.req.headers.add h
    for h in headers: result.req.headers.add h
  elif client.defaultHeaders.len > 0:
    result.req.headers = client.defaultHeaders
  else:
    result.req.headers = headers
  for h in result.req.headers:
    if not isValidHeaderName(h.name) or not isValidHeaderValue(h.value):
      result.valid = false
      return
  result.req.followRedirects = client.defaultFollowRedirects
  result.req.maxRedirects = client.defaultMaxRedirects
  result.req.timeoutMs = client.defaultTimeoutMs

proc openNewConnection(client: var HttpClient, host: string, port: uint16, useSsl: bool,
                       isHttp2: bool, h2Required: bool = false,
                       sourceHost: string = ""): ptr PooledConnection =
  fireConnectStart(client.hooks, host, port, useSsl)

  let conn = cast[ptr PooledConnection](alloc0(sizeof(PooledConnection)))
  conn[] = PooledConnection(
    host: host,
    port: port,
    useSsl: useSsl,
    state: csConnecting,
    isHttp2: isHttp2,
    h2Required: h2Required,
    cachedPoolKey: poolKey(host, port, useSsl),
    h2Streams: initTable[uint32, H2Stream](16),
    pendingCallbacks: initDeque[ResponseCallback](16),
    sendBuf: newStringOfCap(4096),
    recvBuf: newStringOfCap(4096),
  )
  client.pool.addConnection(conn)
  if conn.state == csClosed:
    fireConnectEnd(client.hooks, host, port, 0.0, "connection limit reached")
    `=destroy`(conn[])
    dealloc(conn)
    return nil

  let cd = cast[ptr ClientConnData](alloc0(sizeof(ClientConnData)))
  cd.magic = ConnDataMagic
  cd.conn = conn
  cd.client = addr client
  cd.sslFlag = client.ssl
  cd.h1Parser = initHttp1Parser()
  cd.h1Pending = initDeque[H1PendingMeta](16)
  cd.connectStartTime = epochTime()

  let sourceHostPtr = if sourceHost.len > 0: cstring(sourceHost) else: nil
  let s = us_socket_context_connect(client.ssl, client.ctx, cstring(host), cint(port), sourceHostPtr, 0, ClientSocketExtSize)
  if s == nil:
    let connectDuration = (epochTime() - cd.connectStartTime) * 1000.0
    fireConnectEnd(client.hooks, host, port, connectDuration, "connect returned nil")
    conn.state = csClosed
    client.pool.removeConnection(conn)
    `=destroy`(cd[])
    dealloc(cd)
    `=destroy`(conn[])
    dealloc(conn)
    return nil

  conn.socket = s
  let ext = us_socket_ext(client.ssl, s)
  storeInExt(ext, cd)
  conn

proc countIdleAndActive(pool: var ConnectionPool, key: string): tuple[idle: int, active: int, total: int] {.inline.} =
  if key in pool.connections:
    let conns = addr pool.connections[key]
    for i in 0 ..< conns[].len:
      let conn = conns[][i]
      if conn.state == csClosed or conn.state == csClosing:
        continue
      result.total += 1
      if conn.state == csOpen and conn.pendingCallbacks.len == 0:
        result.idle += 1
      else:
        result.active += 1

proc getOrConnectH1(client: var HttpClient, host: string, port: uint16, useSsl: bool): ptr PooledConnection =
  let key = poolKey(host, port, useSsl)
  if key in client.pool.connections:
    let conns = addr client.pool.connections[key]
    var bestIdx = -1
    var bestPending = high(int)
    var activeCount = 0
    for i in 0 ..< conns[].len:
      let conn = conns[][i]
      if conn.isHttp2 or conn.state == csClosed or conn.state == csClosing:
        continue
      activeCount += 1
      var connCd: ptr ClientConnData = nil
      if conn.socket != nil:
        connCd = getConnData(client.ssl, conn.socket)
      if hasPendingSse(connCd):
        continue
      if conn.state == csOpen and conn.pendingCallbacks.len == 0:
        let counts = countIdleAndActive(client.pool, key)
        firePoolAcquire(client.hooks, host, port, counts.total, counts.idle, counts.active)
        fireConnectionReuse(client.hooks, host, port)
        return conn
      let pending = conn.pendingCallbacks.len
      if pending < bestPending:
        bestPending = pending
        bestIdx = i
    if activeCount < client.pool.maxPerHost:
      return openNewConnection(client, host, port, useSsl, isHttp2 = false)
    if bestIdx >= 0:
      let counts = countIdleAndActive(client.pool, key)
      firePoolAcquire(client.hooks, host, port, counts.total, counts.idle, counts.active)
      fireConnectionReuse(client.hooks, host, port)
      return conns[][bestIdx]
    return nil
  openNewConnection(client, host, port, useSsl, isHttp2 = false)

proc getOrConnectH2(client: var HttpClient, host: string, port: uint16, useSsl: bool, h2Required: bool): ptr PooledConnection =
  let existing = client.pool.acquireH2(host, port, useSsl)
  if existing != nil:
    if h2Required:
      existing.h2Required = true
    let key = poolKey(host, port, useSsl)
    let counts = countIdleAndActive(client.pool, key)
    firePoolAcquire(client.hooks, host, port, counts.total, counts.idle, counts.active)
    fireConnectionReuse(client.hooks, host, port)
    return existing
  openNewConnection(client, host, port, useSsl, isHttp2 = true, h2Required = h2Required)

proc sendH1Request(client: var HttpClient, conn: ptr PooledConnection, req: HttpRequest, cb: ResponseCallback,
                   isSse: bool = false, sseOnEvent: SseEventCallback = nil,
                   sseOnOpen: SseOpenCallback = nil, sseOnError: SseErrorCallback = nil) =
  if conn.state == csClosed or conn.state == csClosing:
    fireRequestError(client.hooks, MethodStrings[req.`method`], req.url, "connection is closing", 0.0)
    let resp = HttpResponse(statusCode: 0, statusText: "connection unavailable")
    try: cb(resp, "connection is closing")
    except CatchableError: discard
    except Defect: discard
    return
  if not validateRequestInputs(req):
    fireRequestError(client.hooks, MethodStrings[req.`method`], req.url, "invalid request input", 0.0)
    let resp = HttpResponse(statusCode: 0, statusText: "invalid request")
    try: cb(resp, "invalid request input")
    except CatchableError: discard
    except Defect: discard
    return
  fireRequestStart(client.hooks, MethodStrings[req.`method`], req.url, req.headers)
  let serialized = serializeRequest(req)
  if serialized.len == 0:
    fireRequestError(client.hooks, MethodStrings[req.`method`], req.url, "request serialization failed", 0.0)
    let resp = HttpResponse(statusCode: 0, statusText: "invalid request")
    try: cb(resp, "request serialization failed")
    except CatchableError: discard
    except Defect: discard
    return
  var cd: ptr ClientConnData = nil
  if conn.socket != nil:
    cd = getConnData(client.ssl, conn.socket)
  if cd == nil:
    fireRequestError(client.hooks, MethodStrings[req.`method`], req.url, "no connection data", 0.0)
    let resp = HttpResponse(statusCode: 0, statusText: "no connection data")
    try: cb(resp, "no connection data")
    except CatchableError: discard
    except Defect: discard
    return
  if conn.state != csOpen and not canQueueSocketWrite(conn, serialized.len):
    fireRequestError(client.hooks, MethodStrings[req.`method`], req.url, "send buffer limit exceeded", 0.0)
    failSocketWriteBackpressure(client.ssl, conn.socket, conn)
    let resp = HttpResponse(statusCode: 0, statusText: "send buffer limit exceeded")
    try: cb(resp, "send buffer limit exceeded")
    except CatchableError: discard
    except Defect: discard
    return
  fireRequestHeadersSent(client.hooks, MethodStrings[req.`method`], req.url, serialized.len)
  conn.pendingCallbacks.addLast(cb)
  client.pendingRequests += 1
  let reqStartTime = epochTime()
  cd.requestStartTime = reqStartTime
  cd.requestMethod = MethodStrings[req.`method`]
  cd.requestUrl = req.url
  cd.h1Pending.addLast H1PendingMeta(
    requestStartTime: reqStartTime,
    requestMethod: MethodStrings[req.`method`],
    requestUrl: req.url,
    noBodyExpected: req.`method` == hmHead,
    request: req,
    isSse: isSse,
    sseParser: initSseParser(),
    sseOnEvent: sseOnEvent,
    sseOnOpen: sseOnOpen,
    sseOnError: sseOnError,
  )
  primeH1Parser(cd)
  if conn.state == csOpen:
    socketWrite(client.ssl, conn.socket, serialized, conn)
  else:
    discard queueSocketWrite(client.ssl, conn.socket, serialized, conn)

proc sendH2Request(client: var HttpClient, conn: ptr PooledConnection, req: HttpRequest, cb: ResponseCallback) =
  if not validateRequestInputs(req):
    fireRequestError(client.hooks, MethodStrings[req.`method`], req.url, "invalid request input", 0.0)
    if cb != nil:
      let resp = HttpResponse(statusCode: 0, statusText: "invalid request")
      try: cb(resp, "invalid request input")
      except CatchableError: discard
      except Defect: discard
    return
  if conn.socket == nil:
    fireRequestError(client.hooks, MethodStrings[req.`method`], req.url, "no socket available", 0.0)
    if cb != nil:
      let resp = HttpResponse(statusCode: 0, statusText: "no socket")
      try: cb(resp, "no socket available")
      except CatchableError: discard
      except Defect: discard
    return
  let cd = getConnData(client.ssl, conn.socket)
  if cd == nil:
    fireRequestError(client.hooks, MethodStrings[req.`method`], req.url, "no connection data", 0.0)
    if cb != nil:
      let resp = HttpResponse(statusCode: 0, statusText: "no connection data")
      try: cb(resp, "no connection data")
      except CatchableError: discard
      except Defect: discard
    return

  fireRequestStart(client.hooks, MethodStrings[req.`method`], req.url, req.headers)
  client.pendingRequests += 1
  let reqStartTime = epochTime()
  cd.requestStartTime = reqStartTime
  cd.requestMethod = MethodStrings[req.`method`]
  cd.requestUrl = req.url

  if not cd.h2Active:
    cd.h2PendingQueue.add PendingH2Request(req: req, cb: cb, requestStartTime: reqStartTime)
    return

  if h2PeerConcurrencySaturated(cd.h2Conn):
    cd.h2PendingQueue.add PendingH2Request(req: req, cb: cb, requestStartTime: reqStartTime)
    return
  if h2StreamExhausted(cd.h2Conn) or not startH2Stream(cd, client.ssl, conn.socket, req, cb, reqStartTime):
    client.pendingRequests -= 1
    fireRequestError(client.hooks, MethodStrings[req.`method`], req.url, "stream ID exhausted", 0.0)
    if cb != nil:
      var resp: HttpResponse
      try: cb(resp, "stream ID exhausted")
      except CatchableError: discard
      except Defect: discard

proc headerValue(headers: seq[HttpHeader], name: string): string {.inline.} =
  for h in headers:
    if h.name.toLowerAscii() == name:
      return h.value
  ""

proc isRedirectStatus(code: int): bool {.inline.} =
  code == 301 or code == 302 or code == 303 or code == 307 or code == 308

## Maps a redirect status code to the HTTP method and body the redirected request must use.
proc redirectMethodAndBody*(statusCode: int, originalMethod: HttpMethod,
                            originalBody: string): tuple[`method`: HttpMethod, body: string] =
  result.`method` = originalMethod
  result.body = originalBody
  if originalMethod == hmHead:
    result.body = ""
    return
  case statusCode
  of 307, 308:
    discard
  of 303:
    result.`method` = hmGet
    result.body = ""
  of 301, 302:
    if originalMethod == hmPost:
      result.`method` = hmGet
      result.body = ""
  else:
    discard

## Returns whether a header name carries credentials that must not follow a redirect.
proc isSensitiveRedirectHeader*(name: string): bool {.inline.} =
  let lower = name.toLowerAscii()
  lower == "authorization" or lower == "cookie" or lower == "proxy-authorization"

## Returns the header list with credential-bearing headers removed for cross-origin redirects.
proc stripSensitiveRedirectHeaders*(headers: seq[HttpHeader]): seq[HttpHeader] =
  result = newSeqOfCap[HttpHeader](headers.len)
  for h in headers:
    if not isSensitiveRedirectHeader(h.name):
      result.add h

proc resolveRedirectUrl(req: HttpRequest, location: string): string =
  if location.len == 0 or containsCRLF(location):
    return ""
  let lower = location.toLowerAscii()
  if lower.startsWith("http://") or lower.startsWith("https://"):
    return location
  let scheme = if req.useSsl: "https" else: "http"
  result = scheme & "://" & req.host
  if not isDefaultPortForScheme(req.port, req.useSsl):
    result.add ":" & $req.port
  if location[0] == '/':
    result.add location
  else:
    let slashPos = req.path.rfind('/')
    if slashPos >= 0:
      result.add req.path[0 .. slashPos]
    else:
      result.add "/"
    result.add location

proc sameRedirectOrigin(req: HttpRequest, nextUrl: string): bool =
  let (scheme, host, port, path, valid) = parseUrl(nextUrl)
  discard path
  if not valid:
    return false
  let currentScheme = if req.useSsl: "https" else: "http"
  currentScheme == scheme and req.host.cmpIgnoreCase(host) == 0 and req.port == port

proc requestInternal(client: var HttpClient, httpMethod: HttpMethod, url: string, body: string,
                     headers: seq[HttpHeader], cb: ResponseCallback, forceH2: bool,
                     redirectsLeft: int, stripDefaultSensitiveHeaders: bool)

proc requestInternal(client: var HttpClient, httpMethod: HttpMethod, url: string, body: string,
                     headers: seq[HttpHeader], cb: ResponseCallback, forceH2: bool,
                     redirectsLeft: int, stripDefaultSensitiveHeaders: bool) =
  let (reqParsed, urlValid) = buildRequest(client, httpMethod, url, body, headers)
  var req = reqParsed
  if not urlValid:
    fireRequestError(client.hooks, MethodStrings[httpMethod], url, "invalid URL", 0.0)
    let resp = HttpResponse(statusCode: 0, statusText: "invalid URL")
    try: cb(resp, "invalid URL: " & url)
    except CatchableError: discard
    except Defect: discard
    return
  if stripDefaultSensitiveHeaders:
    req.headers = stripSensitiveRedirectHeaders(req.headers)
  if not client.initialized:
    initClient(client, req.useSsl)
    if not client.initialized:
      fireRequestError(client.hooks, MethodStrings[httpMethod], url, "client initialization failed", 0.0)
      let resp = HttpResponse(statusCode: 0, statusText: "client initialization failed")
      try: cb(resp, "client initialization failed")
      except CatchableError: discard
      except Defect: discard
      return
  elif client.ssl != (if req.useSsl: 1 else: 0):
    fireRequestError(client.hooks, MethodStrings[httpMethod], url, "URL scheme does not match initialized client TLS mode", 0.0)
    let resp = HttpResponse(statusCode: 0, statusText: "scheme mismatch")
    try: cb(resp, "URL scheme does not match initialized client TLS mode")
    except CatchableError: discard
    except Defect: discard
    return

  let clientPtr = addr client
  let finalCb =
    if req.followRedirects and redirectsLeft > 0:
      proc(resp: HttpResponse, err: string) {.gcsafe.} =
        if err.len == 0 and isRedirectStatus(resp.statusCode):
          let loc = headerValue(resp.headers, "location")
          let nextUrl = resolveRedirectUrl(req, loc)
          if nextUrl.len > 0:
            let redirected = redirectMethodAndBody(resp.statusCode, httpMethod, body)
            let crossOrigin = not req.sameRedirectOrigin(nextUrl)
            let nextStripSensitive = stripDefaultSensitiveHeaders or crossOrigin
            let nextHeaders =
              if nextStripSensitive:
                stripSensitiveRedirectHeaders(headers)
              else:
                headers
            {.cast(gcsafe).}:
              requestInternal(clientPtr[], redirected.`method`, nextUrl, redirected.body, nextHeaders, cb, forceH2, redirectsLeft - 1, nextStripSensitive)
            return
        try: cb(resp, err)
        except CatchableError: discard
        except Defect: discard
    else:
      cb

  let h2Required = forceH2 or req.version == Http20
  let useH2 = h2Required or client.preferH2
  if useH2:
    req.version = Http20

  if useH2:
    let conn = getOrConnectH2(client, req.host, req.port, req.useSsl, h2Required)
    if conn == nil:
      fireRequestError(client.hooks, MethodStrings[httpMethod], url, "connection failed", 0.0)
      let resp = HttpResponse(statusCode: 0, statusText: "connection failed")
      try: finalCb(resp, "failed to connect to " & req.host & ":" & $req.port)
      except CatchableError: discard
      except Defect: discard
      return
    sendH2Request(client, conn, req, finalCb)
  else:
    let conn = getOrConnectH1(client, req.host, req.port, req.useSsl)
    if conn == nil:
      fireRequestError(client.hooks, MethodStrings[httpMethod], url, "connection failed", 0.0)
      let resp = HttpResponse(statusCode: 0, statusText: "connection failed")
      try: finalCb(resp, "failed to connect to " & req.host & ":" & $req.port)
      except CatchableError: discard
      except Defect: discard
      return
    sendH1Request(client, conn, req, finalCb)

## Issues an HTTP request with the given method, URL and body, delivering the result through the callback.
proc request*(client: var HttpClient, httpMethod: HttpMethod, url: string, body: string = "", headers: seq[HttpHeader] = @[], cb: ResponseCallback, forceH2: bool = false) =
  ensureClientOwner(client, "request")
  requestInternal(client, httpMethod, url, body, headers, cb, forceH2, client.defaultMaxRedirects, false)

## Opens an SSE stream resuming from lastEventId and delivers events through the onEvent callback.
proc sse*(client: var HttpClient, url: string, lastEventId: string,
          onEvent: proc(event: SseEvent) {.gcsafe.},
          onOpen: proc() {.gcsafe.} = nil,
          onError: proc(err: string) {.gcsafe.} = nil) =
  ensureClientOwner(client, "sse")
  template failSseSetup(message: string) =
    fireRequestError(client.hooks, MethodStrings[hmGet], url, message, 0.0)
    if onError != nil:
      try:
        onError(message)
      except CatchableError:
        discard
      except Defect:
        discard
    return

  var headers = @[
    HttpHeader(name: "Accept", value: "text/event-stream"),
    HttpHeader(name: "Cache-Control", value: "no-cache"),
  ]
  if lastEventId.len > 0 and isValidHeaderValue(lastEventId):
    headers.add HttpHeader(name: "Last-Event-ID", value: lastEventId)

  let (reqParsed, urlValid) = buildRequest(client, hmGet, url, "", headers)
  var req = reqParsed
  if not urlValid:
    failSseSetup("invalid URL")
  req.timeoutMs = 0

  if not client.initialized:
    initClient(client, req.useSsl)
    if not client.initialized:
      failSseSetup("client initialization failed")
  elif client.ssl != (if req.useSsl: 1 else: 0):
    failSseSetup("URL scheme does not match initialized client TLS mode")

  let conn = getOrConnectH1(client, req.host, req.port, req.useSsl)
  if conn == nil:
    failSseSetup("connection failed")

  let doneCb = proc(resp: HttpResponse, err: string) {.gcsafe.} =
    discard resp
    discard err
  sendH1Request(client, conn, req, doneCb, isSse = true, sseOnEvent = onEvent,
    sseOnOpen = onOpen, sseOnError = onError)

## Opens an SSE stream and delivers events through the onEvent callback.
proc sse*(client: var HttpClient, url: string,
          onEvent: proc(event: SseEvent) {.gcsafe.},
          onOpen: proc() {.gcsafe.} = nil,
          onError: proc(err: string) {.gcsafe.} = nil) =
  sse(client, url, "", onEvent, onOpen, onError)

## Issues an HTTP request and transparently retries failed requests up to the client retry limit.
proc requestWithRetry*(client: var HttpClient, httpMethod: HttpMethod, url: string, body: string = "", headers: seq[HttpHeader] = @[], cb: ResponseCallback, forceH2: bool = false, retryCount: int = 0) =
  ensureClientOwner(client, "requestWithRetry")
  if client.maxRetries <= 0 or retryCount >= client.maxRetries:
    request(client, httpMethod, url, body, headers, cb, forceH2)
    return
  let clientPtr = addr client
  let maxRetries = client.maxRetries
  let retryStatusCodes = client.retryOnStatusCodes
  let retryDelayMs = client.retryDelayMs
  let hooks = client.hooks
  let nextRetry = retryCount + 1
  let wrappedCb = proc(resp: HttpResponse, err: string) {.gcsafe.} =
    if nextRetry <= maxRetries and
       (err.len > 0 or resp.statusCode in retryStatusCodes):
      let reason = if err.len > 0: err else: "status " & $resp.statusCode
      fireRetry(hooks, MethodStrings[httpMethod], url, nextRetry, maxRetries, reason)
      {.cast(gcsafe).}:
        if retryDelayMs > 0 and scheduleRequestRetry(clientPtr, httpMethod, url, body, headers, cb, forceH2, nextRetry, retryDelayMs):
          return
        requestWithRetry(clientPtr[], httpMethod, url, body, headers, cb, forceH2, nextRetry)
    else:
      try: cb(resp, err)
      except CatchableError: discard
      except Defect: discard
  request(client, httpMethod, url, body, headers, wrappedCb, forceH2)

type
  RetryTimerContext = object
    client: ptr HttpClient
    httpMethod: HttpMethod
    url: string
    body: string
    headers: seq[HttpHeader]
    cb: ResponseCallback
    forceH2: bool
    retryCount: int

proc freeRetryTimerContext(ctx: ptr RetryTimerContext) =
  if ctx == nil:
    return
  `=destroy`(ctx[])
  dealloc(ctx)

proc takeRetryTimerContext(timer: UsTimerPtr): ptr RetryTimerContext =
  if timer == nil:
    return
  let ext = us_timer_ext(timer)
  if ext == nil:
    return
  let ctxSlot = cast[ptr pointer](ext)
  result = cast[ptr RetryTimerContext](ctxSlot[])
  ctxSlot[] = nil

proc clearRetryTimerContext(timer: UsTimerPtr) =
  freeRetryTimerContext(takeRetryTimerContext(timer))

proc removeRetryTimer(client: ptr HttpClient, timer: UsTimerPtr) =
  if client == nil or timer == nil:
    return
  var writeIdx = 0
  for i in 0 ..< client[].retryTimers.len:
    if client[].retryTimers[i] != timer:
      client[].retryTimers[writeIdx] = client[].retryTimers[i]
      inc writeIdx
  client[].retryTimers.setLen(writeIdx)

proc cancelRetryTimers(client: var HttpClient) =
  for timer in client.retryTimers:
    clearRetryTimerContext(timer)
    us_timer_close(timer)
  client.retryTimers.setLen(0)

proc onRetryDelayTimer(timer: UsTimerPtr) {.cdecl.} =
  if timer == nil:
    return
  let ext = us_timer_ext(timer)
  if ext == nil:
    us_timer_close(timer)
    return
  let ctx = takeRetryTimerContext(timer)
  us_timer_close(timer)
  if ctx == nil:
    return

  let clientPtr = ctx.client
  removeRetryTimer(clientPtr, timer)
  let httpMethod = ctx.httpMethod
  var url = move(ctx.url)
  var body = move(ctx.body)
  var headers = move(ctx.headers)
  var cb = move(ctx.cb)
  let forceH2 = ctx.forceH2
  let retryCount = ctx.retryCount
  freeRetryTimerContext(ctx)

  if clientPtr != nil:
    requestWithRetry(clientPtr[], httpMethod, url, body, headers, cb, forceH2, retryCount)

proc scheduleRequestRetry(
  client: ptr HttpClient,
  httpMethod: HttpMethod,
  url: string,
  body: string,
  headers: seq[HttpHeader],
  cb: ResponseCallback,
  forceH2: bool,
  retryCount: int,
  delayMs: int
): bool =
  if client == nil or client[].loop == nil or not client[].initialized:
    return false
  let timer = us_create_timer(client[].loop, 0, cuint(sizeof(pointer)))
  if timer == nil:
    return false
  let ctx = cast[ptr RetryTimerContext](alloc0(sizeof(RetryTimerContext)))
  if ctx == nil:
    us_timer_close(timer)
    return false
  ctx[] = RetryTimerContext(
    client: client,
    httpMethod: httpMethod,
    url: url,
    body: body,
    headers: headers,
    cb: cb,
    forceH2: forceH2,
    retryCount: retryCount
  )
  cast[ptr pointer](us_timer_ext(timer))[] = cast[pointer](ctx)
  client[].retryTimers.add(timer)
  let clampedDelay = min(delayMs, int(high(cint)))
  us_timer_set(timer, onRetryDelayTimer, cint(max(1, clampedDelay)), 0)
  true

when defined(nimFastHttpClientTest):
  ## Test helper verifying that a retry delay timer is scheduled and cleared on close.
  proc clientRetryDelaySchedulesForTest*(delayMs: int): tuple[scheduled: bool, timersBeforeClose: int, timersAfterClose: int] =
    var client = newHttpClient()
    initClient(client, ssl = false)
    if not client.initialized:
      return
    if client.timeoutTimer != nil:
      us_timer_close(client.timeoutTimer)
      client.timeoutTimer = nil

    let cb = proc(resp: HttpResponse, err: string) {.gcsafe.} =
      discard

    result.scheduled = scheduleRequestRetry(
      addr client,
      hmGet,
      "not-a-valid-url",
      "",
      @[],
      cb,
      false,
      1,
      delayMs
    )
    result.timersBeforeClose = client.retryTimers.len
    close(client)
    result.timersAfterClose = client.retryTimers.len

  ## Test helper checking that a WebSocket reconnect timer is cancelled on close.
  proc clientWsReconnectTimerCancelledForTest*(): tuple[scheduled: bool, activeBeforeClose: int, activeAfterClose: int, timerAfterClose: bool, manualClose: bool] =
    var client = newHttpClient()
    initClient(client, ssl = false)
    if not client.initialized:
      return
    if client.timeoutTimer != nil:
      us_timer_close(client.timeoutTimer)
      client.timeoutTimer = nil

    let ws = newWsConnection()
    initWsClientDefaults(ws)
    ws.owner = addr client
    ws.loop = client.loop
    ws.autoReconnect = true
    ws.maxReconnectAttempts = 3
    trackActiveWs(addr client, ws)
    scheduleWsReconnect(ws)

    result.scheduled = ws.reconnectTimer != nil
    result.activeBeforeClose = client.activeWs.len
    close(client)
    result.activeAfterClose = client.activeWs.len
    result.timerAfterClose = ws.reconnectTimer != nil
    result.manualClose = ws.manualClose

## Convenience wrapper around `request` for an HTTP GET without body.
proc get*(client: var HttpClient, url: string, cb: ResponseCallback, forceH2: bool = false) =
  ensureClientOwner(client, "get")
  request(client, hmGet, url, "", @[], cb, forceH2)

## Convenience wrapper around `request` for an HTTP POST with body.
proc post*(client: var HttpClient, url: string, body: string, cb: ResponseCallback, forceH2: bool = false) =
  ensureClientOwner(client, "post")
  request(client, hmPost, url, body, @[], cb, forceH2)

## Convenience wrapper around `request` for an HTTP PUT with body.
proc put*(client: var HttpClient, url: string, body: string, cb: ResponseCallback, forceH2: bool = false) =
  ensureClientOwner(client, "put")
  request(client, hmPut, url, body, @[], cb, forceH2)

## Convenience wrapper around `request` for an HTTP DELETE without body.
proc delete*(client: var HttpClient, url: string, cb: ResponseCallback, forceH2: bool = false) =
  ensureClientOwner(client, "delete")
  request(client, hmDelete, url, "", @[], cb, forceH2)

## Convenience wrapper around `request` for an HTTP HEAD without body.
proc head*(client: var HttpClient, url: string, cb: ResponseCallback, forceH2: bool = false) =
  ensureClientOwner(client, "head")
  request(client, hmHead, url, "", @[], cb, forceH2)

proc collectWsHeaders(client: HttpClient, headers: openArray[(string, string)]): seq[(string, string)] =
  result = newSeqOfCap[(string, string)](client.defaultHeaders.len + headers.len)
  for h in client.defaultHeaders:
    result.add((h.name, h.value))
  for h in headers:
    result.add h

proc openWsConnection(client: var HttpClient, ws: WsConnection): bool =
  if ws == nil:
    return false
  ws.owner = addr client
  ws.loop = client.loop
  ws.ctx = client.ctx
  ws.socket = nil
  ws.recvBuf.setLen(0)
  ws.wsKey = generateWebSocketKey()
  ws.state = csConnecting
  ws.closeFrameSent = false
  ws.closeNotified = false
  ws.peerCloseReceived = false
  ws.closeCode = 1005'u16
  ws.closeReason.setLen(0)
  ws.awaitingPong = false
  ws.fragmented = false
  ws.fragmentBuf.setLen(0)
  resetWsUtf8(ws)

  let wsHeaders = collectWsHeaders(client, ws.reconnectHeaders)
  let handshake = buildUpgradeRequest(
    ws.host,
    ws.path,
    ws.port,
    ws.wsKey,
    ws.reconnectSubprotocols,
    wsHeaders,
    useSsl = ws.useSsl
  )
  if handshake.len == 0:
    ws.state = csClosed
    notifyWsError(ws, "invalid websocket upgrade request")
    return false

  if not client.initialized:
    initClient(client, ws.useSsl)
    if not client.initialized:
      ws.state = csClosed
      notifyWsError(ws, "client initialization failed")
      return false
    ws.loop = client.loop
    ws.ctx = client.ctx
  elif client.ssl != (if ws.useSsl: 1 else: 0):
    ws.state = csClosed
    notifyWsError(ws, "websocket SSL mode does not match client context")
    return false

  let conn = openNewConnection(client, ws.host, ws.port, ws.useSsl, isHttp2 = false, sourceHost = ws.bindHost)
  if conn == nil:
    ws.state = csClosed
    notifyWsError(ws, "failed to open websocket connection")
    return false
  ws.socket = conn.socket

  var cd: ptr ClientConnData = nil
  if conn.socket != nil:
    cd = getConnData(client.ssl, conn.socket)
  if cd == nil:
    ws.state = csClosed
    conn.state = csClosing
    if conn.socket != nil:
      discard us_socket_close(client.ssl, conn.socket, 0, nil)
    notifyWsError(ws, "websocket connection data missing")
    return false
  cd.wsConn = ws
  if conn.state == csOpen:
    socketWrite(client.ssl, conn.socket, handshake, conn)
  else:
    if not queueSocketWrite(client.ssl, conn.socket, handshake, conn):
      ws.state = csClosed
      notifyWsError(ws, "send buffer limit exceeded")
      return false
  true

proc startWsUpgrade(client: var HttpClient, url: string, host: string, port: uint16,
                    path: string, useSsl: bool, subprotocols: openArray[string],
                    headers: openArray[(string, string)],
                    bindHost: string = ""): WsConnection =
  result = newWsConnection()
  initWsClientDefaults(result)
  result.url = url
  result.host = host
  result.port = port
  result.path = path
  result.useSsl = useSsl
  result.bindHost = bindHost
  result.owner = addr client
  trackActiveWs(addr client, result)
  result.reconnectSubprotocols = @[]
  for protocol in subprotocols:
    result.reconnectSubprotocols.add protocol
  result.reconnectHeaders = @[]
  for h in headers:
    result.reconnectHeaders.add h
  if not openWsConnection(client, result):
    untrackActiveWs(addr client, result)

## Starts a WebSocket upgrade against the parsed URL and returns the new `WsConnection`.
proc ws*(client: var HttpClient, url: string,
         subprotocols: openArray[string] = [],
         headers: openArray[(string, string)] = [],
         bindHost: string = ""): WsConnection =
  ensureClientOwner(client, "ws")
  let (scheme, host, port, path, valid) = parseWsUrl(url)
  if not valid:
    result = newWsConnection()
    initWsClientDefaults(result)
    result.url = url
    return
  startWsUpgrade(client, url, host, port, path, scheme == "wss", subprotocols, headers, bindHost)

## Starts a WebSocket upgrade against an explicit host, port and path.
proc ws*(client: var HttpClient, host: string, port: uint16, path: string = "/",
         useSsl: bool = false, subprotocols: openArray[string] = [],
         headers: openArray[(string, string)] = [],
         bindHost: string = ""): WsConnection =
  ensureClientOwner(client, "ws")
  let wsPath = if path.len == 0: "/" else: path
  var url = if useSsl: "wss://" else: "ws://"
  url.add host
  if (useSsl and port != 443) or ((not useSsl) and port != 80):
    url.add ":"
    url.addInt int(port)
  url.add wsPath
  startWsUpgrade(client, url, host, port, wsPath, useSsl, subprotocols, headers, bindHost)

when defined(nimFastHttpClientTest):
  ## Test helper checking that a failed WebSocket open untracks the connection from the client.
  proc clientWsFailedOpenUntracksForTest*(): tuple[activeWs: int, wsState: ConnectionState, initialized: bool] =
    var client = newHttpClient()
    let ws = client.ws(
      "ws://example.test/",
      headers = @[("Sec-WebSocket-Key", "forbidden")]
    )
    result.activeWs = client.activeWs.len
    result.wsState = ws.state
    result.initialized = client.initialized
    close(client)

## Sends a masked text or binary frame over an open WebSocket connection.
proc send*(ws: WsConnection, data: string, opcode: WsOpcode = woText) =
  if ws != nil and ws.state == csOpen and ws.socket != nil and
      (opcode == woText or opcode == woBinary):
    let frame = encodeWsFrame(opcode, data, masked = true)
    sendWsRaw(ws, frame)

## Initiates the WebSocket close handshake with the given status code and reason.
proc close*(ws: WsConnection, code: uint16 = 1000, reason: string = "") =
  if ws == nil:
    return
  if ws.state == csConnecting:
    ws.manualClose = true
    ws.state = csClosing
    if ws.socket != nil:
      discard us_socket_close(if ws.useSsl: 1 else: 0, ws.socket, 0, nil)
    return
  if ws.state == csOpen or ws.state == csClosing:
    discard initiateWsClose(ws, code, reason, manual = true)

## Runs the client uSockets event loop, optionally auto-stopping when no connections remain.
proc run*(client: var HttpClient, autoStop: bool = false) =
  ensureClientOwner(client, "run")
  if not client.initialized: return
  client.autoStop = autoStop
  ensureClientTimeoutTimer(addr client)
  us_loop_run(client.loop)

## Stops the client event loop, closing the timeout timer and draining idle pool connections.
proc stopLoop*(client: var HttpClient) =
  ensureClientOwner(client, "stopLoop")
  if client.loop == nil:
    return
  if client.timeoutTimer != nil:
    us_timer_close(client.timeoutTimer)
    client.timeoutTimer = nil
  when defined(LIBUS_USE_IO_URING) or defined(useIoUring):
    drainPoolForAutoStop(addr client)
    us_loop_stop(client.loop)
  elif defined(macosx):
    us_loop_stop(client.loop)
  else:
    drainPoolForAutoStop(addr client)

## Deprecated no-argument stopLoop kept for the macOS CoreFoundation run loop.
proc stopLoop*() {.deprecated: "use stopLoop(client); no-arg stopLoop only supports the macOS CoreFoundation run loop".} =
  when defined(macosx):
    CFRunLoopStop(CFRunLoopGetCurrent())
  else:
    raise newException(ValueError, "stopLoop() without a client is unsupported on this platform; use stopLoop(client)")

## Evicts and closes every idle pooled connection, firing pool evict and close hooks.
proc cleanupIdleConnections*(client: var HttpClient) =
  ensureClientOwner(client, "cleanupIdleConnections")
  let evicted = client.pool.cleanup()
  for conn in evicted:
    firePoolEvict(client.hooks, conn.host, conn.port, "idle timeout")
    fireConnectionClose(client.hooks, conn.host, conn.port, "idle timeout")
    if conn.socket != nil:
      discard us_socket_close(client.ssl, conn.socket, 0, nil)
    else:
      fireErrorCallbacks(conn, "idle timeout")
      `=destroy`(conn[])
      dealloc(conn)

## Closes the client, drains pending requests with an error callback and releases native resources.
proc close*(client: var HttpClient) =
  ensureClientOwner(client, "close")
  if not client.initialized: return
  client.initialized = false
  client.ownerAddress = nil
  var closingCallbacks: seq[ResponseCallback]
  if client.timeoutTimer != nil:
    us_timer_close(client.timeoutTimer)
    client.timeoutTimer = nil
  cancelRetryTimers(client)
  if client.activeWs.len > 0:
    let sockets = client.activeWs
    client.activeWs.setLen(0)
    for ws in sockets:
      if ws == nil:
        continue
      ws.activeWsIndex = -1
      ws.manualClose = true
      stopWsActiveTimers(ws)
      if ws.socket != nil:
        let sockSsl = wsSsl(ws)
        let cd = getConnData(sockSsl, ws.socket)
        if cd != nil and cd.wsConn == ws:
          ws.state = csClosing
        else:
          let sock = ws.socket
          ws.socket = nil
          ws.state = csClosing
          discard us_socket_close(wsSsl(ws), sock, 0, nil)
      else:
        ws.state = csClosed
  var toClose: seq[tuple[sock: UsSocketPtr, conn: ptr PooledConnection]]
  for key in client.pool.connections.keys:
    let conns = addr client.pool.connections[key]
    for i in 0 ..< conns[].len:
      let conn = conns[][i]
      firePoolEvict(client.hooks, conn.host, conn.port, "client closing")
      fireConnectionClose(client.hooks, conn.host, conn.port, "client closing")
      if conn.socket != nil:
        let cd = getConnData(client.ssl, conn.socket)
        if cd != nil:
          if cd.wsConn != nil:
            cd.wsConn.manualClose = true
            stopWsActiveTimers(cd.wsConn)
            cd.wsConn.state = csClosing
          closingCallbacks.add failTimedOutCallbacks(addr client, conn, cd, "client closing")
      else:
        fireErrorCallbacks(conn, "client closing")
      if conn.socket != nil:
        toClose.add((sock: conn.socket, conn: conn))
      else:
        `=destroy`(conn[])
        dealloc(conn)
  client.pool.connections.clear()
  client.pool.totalConnections = 0
  client.pendingRequests = 0
  if closingCallbacks.len > 0:
    let resp = HttpResponse(statusCode: 0, statusText: "client closing")
    for cb in closingCallbacks:
      try:
        cb(resp, "client closing")
      except CatchableError:
        discard
      except Defect:
        discard
  for item in toClose:
    discard us_socket_close(client.ssl, item.sock, 0, nil)
  if client.ctx != nil:
    us_socket_context_free(client.ssl, client.ctx)
    client.ctx = nil
  if client.loop != nil and client.ownsLoop:
    us_loop_free(client.loop)
  client.loop = nil

type
  MetricsData* = ref object
    when compileOption("threads"):
      connectCount*: Atomic[int]
      connectErrorCount*: Atomic[int]
      connectTotalMsRaw: Atomic[int64]
      requestCount*: Atomic[int]
      requestErrorCount*: Atomic[int]
      responseCount*: Atomic[int]
      responseTotalMsRaw: Atomic[int64]
      responseTotalBytes*: Atomic[int]
      retryCount*: Atomic[int]
      connectionReuseCount*: Atomic[int]
      connectionCloseCount*: Atomic[int]
      poolAcquireCount*: Atomic[int]
      poolReleaseCount*: Atomic[int]
      poolEvictCount*: Atomic[int]
    else:
      connectCount*: int
      connectErrorCount*: int
      connectTotalMs*: float
      requestCount*: int
      requestErrorCount*: int
      responseCount*: int
      responseTotalMs*: float
      responseTotalBytes*: int
      retryCount*: int
      connectionReuseCount*: int
      connectionCloseCount*: int
      poolAcquireCount*: int
      poolReleaseCount*: int
      poolEvictCount*: int

when compileOption("threads"):
  ## Total connection time in milliseconds accumulated across all connections.
  proc connectTotalMs*(m: MetricsData): float =
    float(m.connectTotalMsRaw.load(moRelaxed)) / 1000.0
  ## Total response time in milliseconds accumulated across all requests.
  proc responseTotalMs*(m: MetricsData): float =
    float(m.responseTotalMsRaw.load(moRelaxed)) / 1000.0
  proc atomicAddFloat(a: var Atomic[int64], v: float) =
    a.atomicInc(int64(v * 1000.0))

## Builds a full set of `HttpClientHooks` that collect `MetricsData` counters for the client.
proc newMetricsHooks*(): tuple[hooks: HttpClientHooks, metrics: MetricsData] =
  let m = MetricsData()
  var hooks: HttpClientHooks
  hooks.onConnectStart = proc(host: string, port: uint16, isTls: bool) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.connectCount.atomicInc(1)
      else:
        m.connectCount += 1
  hooks.onConnectEnd = proc(host: string, port: uint16, durationMs: float, error: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        atomicAddFloat(m.connectTotalMsRaw, durationMs)
        if error.len > 0:
          m.connectErrorCount.atomicInc(1)
      else:
        m.connectTotalMs += durationMs
        if error.len > 0:
          m.connectErrorCount += 1
  hooks.onConnectionReuse = proc(host: string, port: uint16) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.connectionReuseCount.atomicInc(1)
      else:
        m.connectionReuseCount += 1
  hooks.onConnectionClose = proc(host: string, port: uint16, reason: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.connectionCloseCount.atomicInc(1)
      else:
        m.connectionCloseCount += 1
  hooks.onRequestStart = proc(httpMethod: string, url: string, headers: seq[HttpHeader]) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.requestCount.atomicInc(1)
      else:
        m.requestCount += 1
  hooks.onRequestError = proc(httpMethod: string, url: string, error: string, durationMs: float) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.requestErrorCount.atomicInc(1)
      else:
        m.requestErrorCount += 1
  hooks.onResponseBody = proc(bodyBytes: int, totalDurationMs: float) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.responseCount.atomicInc(1)
        atomicAddFloat(m.responseTotalMsRaw, totalDurationMs)
        m.responseTotalBytes.atomicInc(bodyBytes)
      else:
        m.responseCount += 1
        m.responseTotalMs += totalDurationMs
        m.responseTotalBytes += bodyBytes
  hooks.onRetry = proc(httpMethod: string, url: string, attempt: int, maxRetries: int, reason: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.retryCount.atomicInc(1)
      else:
        m.retryCount += 1
  hooks.onPoolAcquire = proc(host: string, port: uint16, poolSize: int, idle: int, active: int) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.poolAcquireCount.atomicInc(1)
      else:
        m.poolAcquireCount += 1
  hooks.onPoolRelease = proc(host: string, port: uint16, poolSize: int) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.poolReleaseCount.atomicInc(1)
      else:
        m.poolReleaseCount += 1
  hooks.onPoolEvict = proc(host: string, port: uint16, reason: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      when compileOption("threads"):
        m.poolEvictCount.atomicInc(1)
      else:
        m.poolEvictCount += 1
  result = (hooks: hooks, metrics: m)

## Serializes the collected `MetricsData` counters into a JSON object string.
proc metricsJson*(metrics: MetricsData): string =
  when compileOption("threads"):
    let j = %*{
      "connectCount": metrics.connectCount.load(moRelaxed),
      "connectErrorCount": metrics.connectErrorCount.load(moRelaxed),
      "connectTotalMs": metrics.connectTotalMs,
      "requestCount": metrics.requestCount.load(moRelaxed),
      "requestErrorCount": metrics.requestErrorCount.load(moRelaxed),
      "responseCount": metrics.responseCount.load(moRelaxed),
      "responseTotalMs": metrics.responseTotalMs,
      "responseTotalBytes": metrics.responseTotalBytes.load(moRelaxed),
      "retryCount": metrics.retryCount.load(moRelaxed),
      "connectionReuseCount": metrics.connectionReuseCount.load(moRelaxed),
      "connectionCloseCount": metrics.connectionCloseCount.load(moRelaxed),
      "poolAcquireCount": metrics.poolAcquireCount.load(moRelaxed),
      "poolReleaseCount": metrics.poolReleaseCount.load(moRelaxed),
      "poolEvictCount": metrics.poolEvictCount.load(moRelaxed),
    }
  else:
    let j = %*{
      "connectCount": metrics.connectCount,
      "connectErrorCount": metrics.connectErrorCount,
      "connectTotalMs": metrics.connectTotalMs,
      "requestCount": metrics.requestCount,
      "requestErrorCount": metrics.requestErrorCount,
      "responseCount": metrics.responseCount,
      "responseTotalMs": metrics.responseTotalMs,
      "responseTotalBytes": metrics.responseTotalBytes,
      "retryCount": metrics.retryCount,
      "connectionReuseCount": metrics.connectionReuseCount,
      "connectionCloseCount": metrics.connectionCloseCount,
      "poolAcquireCount": metrics.poolAcquireCount,
      "poolReleaseCount": metrics.poolReleaseCount,
      "poolEvictCount": metrics.poolEvictCount,
    }
  $j
