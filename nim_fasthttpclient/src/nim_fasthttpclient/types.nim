import std/[tables, deques]
import ../../../nim_usockets/src/nim_usockets/usockets
import ../../../nim_usockets/src/nim_usockets/hpack as hpackTypes
import ../../../nim_usockets/src/nim_usockets/h2_protocol as h2Types

export hpackTypes.HpackEntry, hpackTypes.HpackDynamicTable, hpackTypes.HpackEncoder,
       hpackTypes.HpackDecoder, hpackTypes.initHpackDynamicTable,
       hpackTypes.initHpackEncoder, hpackTypes.initHpackDecoder

export h2Types.H2FrameType, h2Types.H2ErrorCode, h2Types.H2Settings,
       h2Types.H2Frame, h2Types.defaultH2Settings,
       h2Types.H2ConnectionPreface, h2Types.H2FrameHeaderSize,
       h2Types.DefaultWindowSize, h2Types.DefaultH2Settings,
       h2Types.FlagEndStream, h2Types.FlagAck,
       h2Types.FlagEndHeaders, h2Types.FlagPadded, h2Types.FlagPriority

type
  HttpMethod* = enum
    hmGet = "GET"
    hmHead = "HEAD"
    hmPost = "POST"
    hmPut = "PUT"
    hmDelete = "DELETE"
    hmPatch = "PATCH"
    hmOptions = "OPTIONS"

  HttpVersion* = enum
    Http10 = "HTTP/1.0"
    Http11 = "HTTP/1.1"
    Http20 = "HTTP/2.0"

  ConnectionState* = enum
    csConnecting
    csOpen
    csClosing
    csClosed

  H2StreamState* = enum
    ssIdle
    ssReservedLocal
    ssReservedRemote
    ssOpen
    ssHalfClosedLocal
    ssHalfClosedRemote
    ssClosed

  H2SettingsId* = enum
    siHeaderTableSize = 0x1
    siEnablePush = 0x2
    siMaxConcurrentStreams = 0x3
    siInitialWindowSize = 0x4
    siMaxFrameSize = 0x5
    siMaxHeaderListSize = 0x6

  WsOpcode* = enum
    woContinuation = 0x0
    woText = 0x1
    woBinary = 0x2
    woClose = 0x8
    woPing = 0x9
    woPong = 0xA

  SseEventField* = enum
    sfEvent
    sfData
    sfId
    sfRetry

  HttpHeader* = object
    name*: string
    value*: string

  HttpRequest* = object
    `method`*: HttpMethod
    url*: string
    path*: string
    host*: string
    port*: uint16
    headers*: seq[HttpHeader]
    body*: string
    version*: HttpVersion
    useSsl*: bool
    followRedirects*: bool
    maxRedirects*: int
    timeoutMs*: int

  HttpResponse* = object
    statusCode*: int
    statusText*: string
    headers*: seq[HttpHeader]
    body*: string
    version*: HttpVersion

  ResponseCallback* = proc(resp: HttpResponse, err: string) {.gcsafe.}

  H2Stream* = object
    id*: uint32
    state*: H2StreamState
    sendWindow*: int32
    recvWindow*: int32
    headerBuf*: string
    dataBuf*: string
    dataEndStreamPending*: bool
    request*: HttpRequest
    callback*: ResponseCallback
    responseHeaders*: seq[HttpHeader]
    responseStatus*: int
    responseBody*: string
    requestStartTime*: float

  WsFrame* = object
    fin*: bool
    opcode*: WsOpcode
    masked*: bool
    maskKey*: array[4, byte]
    payload*: string

  SseEvent* = object
    eventType*: string
    data*: string
    id*: string
    retry*: int

  PooledConnection* = object
    socket*: UsSocketPtr
    host*: string
    port*: uint16
    useSsl*: bool
    state*: ConnectionState
    isHttp2*: bool
    h2Required*: bool
    lastUsed*: float
    cachedPoolKey*: string
    h2Streams*: Table[uint32, H2Stream]
    h2NextStreamId*: uint32
    h2LocalSettings*: H2Settings
    h2RemoteSettings*: H2Settings
    h2LocalWindow*: int32
    h2RemoteWindow*: int32
    hpackEncoder*: HpackEncoder
    hpackDecoder*: HpackDecoder
    recvBuf*: string
    recvPos*: int
    pendingCallbacks*: Deque[ResponseCallback]
    sendBuf*: string
    sendBufPos*: int

  ConnectionPool* = object
    connections*: Table[string, seq[ptr PooledConnection]]
    maxPerHost*: int
    idleTimeoutSec*: float
    totalConnections*: int

  WsClientState* = object
    socket*: UsSocketPtr
    state*: ConnectionState
    loop*: UsLoopPtr
    ctx*: UsSocketContextPtr
    ssl*: cint
    url*: string
    host*: string
    port*: uint16
    path*: string
    useSsl*: bool
    wsKey*: string
    ## If set, outbound TCP socket is ``bind`` to this address before ``connect`` (Linux client scale).
    bindHost*: string
    recvBuf*: string
    onMessage*: proc(data: string, opcode: WsOpcode) {.gcsafe.}
    onOpen*: proc() {.gcsafe.}
    onClose*: proc(code: uint16, reason: string) {.gcsafe.}
    onError*: proc(err: string) {.gcsafe.}
    pingIntervalMs*: int
    pongTimeoutMs*: int
    closeTimeoutMs*: int
    maxMessageSize*: int
    autoReconnect*: bool
    reconnectAttempts*: int
    maxReconnectAttempts*: int
    baseDelayMs*: int
    maxDelayMs*: int
    maxReconnectDelay*: int
    heartbeatTimer*: UsTimerPtr
    reconnectTimer*: UsTimerPtr
    closeTimer*: UsTimerPtr
    lastPingAtMs*: int64
    pingSentAtMs*: int64
    lastPongAtMs*: int64
    awaitingPong*: bool
    lastPingPayload*: string
    closeFrameSent*: bool
    closeNotified*: bool
    manualClose*: bool
    peerCloseReceived*: bool
    closeCode*: uint16
    closeReason*: string
    fragmented*: bool
    fragmentedOpcode*: WsOpcode
    fragmentBuf*: string

  WsConnection* = ref object
    magic: uint32
    socket*: UsSocketPtr
    state*: ConnectionState
    loop*: UsLoopPtr
    ctx*: UsSocketContextPtr
    owner*: pointer
    activeWsIndex*: int
    url*: string
    host*: string
    port*: uint16
    path*: string
    useSsl*: bool
    ## If set, outbound TCP socket is ``bind`` to this address before ``connect`` (Linux client scale).
    bindHost*: string
    wsKey*: string
    subprotocol*: string
    reconnectSubprotocols*: seq[string]
    reconnectHeaders*: seq[(string, string)]
    recvBuf*: string
    sendBuf*: string
    sendBufPos*: int
    onOpen*: proc() {.gcsafe.}
    onMessage*: proc(data: string, opcode: WsOpcode) {.gcsafe.}
    onClose*: proc(code: uint16, reason: string) {.gcsafe.}
    onError*: proc(err: string) {.gcsafe.}
    pingIntervalMs*: int
    pongTimeoutMs*: int
    closeTimeoutMs*: int
    maxMessageSize*: int
    autoReconnect*: bool
    reconnectAttempts*: int
    maxReconnectAttempts*: int
    baseDelayMs*: int
    maxDelayMs*: int
    heartbeatTimer*: UsTimerPtr
    reconnectTimer*: UsTimerPtr
    closeTimer*: UsTimerPtr
    lastPingAtMs*: int64
    pingSentAtMs*: int64
    lastPongAtMs*: int64
    awaitingPong*: bool
    lastPingPayload*: string
    closeFrameSent*: bool
    closeNotified*: bool
    manualClose*: bool
    peerCloseReceived*: bool
    closeCode*: uint16
    closeReason*: string
    fragmented*: bool
    fragmentedOpcode*: WsOpcode
    fragmentBuf*: string
    utf8Needed*: int
    utf8Code*: int
    utf8Min*: int
    utf8Invalid*: bool

  SseClientState* = object
    socket*: UsSocketPtr
    state*: ConnectionState
    url*: string
    host*: string
    port*: uint16
    path*: string
    useSsl*: bool
    lastEventId*: string
    recvBuf*: string
    onEvent*: proc(event: SseEvent) {.gcsafe.}
    onOpen*: proc() {.gcsafe.}
    onError*: proc(err: string) {.gcsafe.}
    autoReconnect*: bool
    retryMs*: int

  PendingH2Request* = object
    req*: HttpRequest
    cb*: ResponseCallback
    requestStartTime*: float

  OnConnectStartCb* = proc(host: string, port: uint16, isTls: bool) {.gcsafe.}
  OnConnectEndCb* = proc(host: string, port: uint16, durationMs: float, error: string) {.gcsafe.}
  OnConnectionReuseCb* = proc(host: string, port: uint16) {.gcsafe.}
  OnConnectionCloseCb* = proc(host: string, port: uint16, reason: string) {.gcsafe.}

  OnRequestStartCb* = proc(httpMethod: string, url: string, headers: seq[HttpHeader]) {.gcsafe.}
  OnRequestHeadersSentCb* = proc(httpMethod: string, url: string, headerBytes: int) {.gcsafe.}
  OnResponseHeadersCb* = proc(statusCode: int, headers: seq[HttpHeader], durationMs: float) {.gcsafe.}
  OnResponseBodyCb* = proc(bodyBytes: int, totalDurationMs: float) {.gcsafe.}
  OnRequestErrorCb* = proc(httpMethod: string, url: string, error: string, durationMs: float) {.gcsafe.}

  OnRetryCb* = proc(httpMethod: string, url: string, attempt: int, maxRetries: int, reason: string) {.gcsafe.}

  OnPoolAcquireCb* = proc(host: string, port: uint16, poolSize: int, idle: int, active: int) {.gcsafe.}
  OnPoolReleaseCb* = proc(host: string, port: uint16, poolSize: int) {.gcsafe.}
  OnPoolEvictCb* = proc(host: string, port: uint16, reason: string) {.gcsafe.}

  HttpClientHooks* = object
    onConnectStart*: OnConnectStartCb
    onConnectEnd*: OnConnectEndCb
    onConnectionReuse*: OnConnectionReuseCb
    onConnectionClose*: OnConnectionCloseCb
    onRequestStart*: OnRequestStartCb
    onRequestHeadersSent*: OnRequestHeadersSentCb
    onResponseHeaders*: OnResponseHeadersCb
    onResponseBody*: OnResponseBodyCb
    onRequestError*: OnRequestErrorCb
    onRetry*: OnRetryCb
    onPoolAcquire*: OnPoolAcquireCb
    onPoolRelease*: OnPoolReleaseCb
    onPoolEvict*: OnPoolEvictCb

  HttpClientConfig* = object
    maxConnsPerHost*: int
    requestTimeoutMs*: int
    connectTimeoutMs*: int
    keepAliveTimeoutMs*: int
    maxRetries*: int
    retryDelayMs*: int
    retryOnStatusCodes*: seq[int]
    preferH2*: bool
    tlsOptions*: UsSocketContextOptions
    defaultHeaders*: seq[HttpHeader]
    hooks*: HttpClientHooks

  HttpClient* = object
    loop*: UsLoopPtr
    ctx*: UsSocketContextPtr
    pool*: ConnectionPool
    ssl*: cint
    defaultTimeoutMs*: int
    defaultFollowRedirects*: bool
    defaultMaxRedirects*: int
    defaultHeaders*: seq[HttpHeader]
    initialized*: bool
    ownsLoop*: bool
    pendingRequests*: int
    autoStop*: bool
    preferH2*: bool
    tlsOptions*: UsSocketContextOptions
    maxRetries*: int
    retryDelayMs*: int
    retryOnStatusCodes*: seq[int]
    connectTimeoutMs*: int
    keepAliveTimeoutMs*: int
    timeoutTimer*: UsTimerPtr
    retryTimers*: seq[UsTimerPtr]
    activeWs*: seq[WsConnection]
    hooks*: HttpClientHooks
    ownerAddress*: pointer

proc `=copy`*(dest: var HttpClient, src: HttpClient) {.error: "HttpClient owns native uSockets resources and cannot be copied; pass it by var/ref or create a separate client".}

## Check whether the port matches the default port for the scheme
proc isDefaultPortForScheme*(port: uint16, useSsl: bool): bool {.inline.} =
  (useSsl and port == 443'u16) or ((not useSsl) and port == 80'u16)

## Build the Host authority string, omitting the port when it is the scheme default
proc authorityForRequest*(host: string, port: uint16, useSsl: bool): string {.inline.} =
  if isDefaultPortForScheme(port, useSsl):
    host
  else:
    host & ":" & $port

const WsConnectionMagic = 0x5753_434E'u32

## Allocate and initialize a new websocket client connection handle
proc newWsConnection*(): WsConnection =
  new(result)
  result.magic = WsConnectionMagic
  result.state = csClosed
  result.activeWsIndex = -1
  result.recvBuf = newStringOfCap(4096)

## Verify that the websocket connection handle is valid and intact
proc isValidWsConnection*(conn: WsConnection): bool {.inline.} =
  conn != nil and conn.magic == WsConnectionMagic

## Return the default HTTP client configuration with tuned values
proc defaultHttpClientConfig*(): HttpClientConfig =
  HttpClientConfig(
    maxConnsPerHost: 6,
    requestTimeoutMs: 30000,
    connectTimeoutMs: 5000,
    keepAliveTimeoutMs: 60000,
    maxRetries: 0,
    retryDelayMs: 100,
    retryOnStatusCodes: @[502, 503, 504],
    preferH2: false,
    tlsOptions: defaultSocketContextOptions(),
  )
