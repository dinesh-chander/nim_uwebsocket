## High-level HTTP server built on uSockets
##
## This module provides a simple HTTP server implementation using the raw
## uSockets bindings. It handles HTTP parsing and provides a clean callback API.
##
## Optimized for performance with:
## - Inline pragmas for hot paths
## - Pre-allocated buffers
## - Minimal string copies
## - Efficient parsing

import std/[strutils, options, base64, times, unicode, os, atomics, tables]
import ws_simd
when compileOption("threads"):
  import std/locks
import zippy
import zippy/inflate as zippy_inflate
import libdeflate_gzip

when defined(windows):
  import std/winlean
else:
  import std/posix
import usockets
import fast_hash
import nim_utils/helpers/fast_map
import sha1_compat
import hpack as hpackMod
import h2_protocol as h2p
export usockets
export fast_hash

when defined(nimUwebsocketsTest):
  proc appendWsTestLog(line: string) {.inline.} =
    let path = getEnv("NIM_EXPRESS_WS_LOG", "")
    if path.len == 0:
      return
    try:
      writeFile(path, (if fileExists(path): readFile(path) else: "") & line & "\n")
    except CatchableError:
      discard

const MacosGcdServerMainThreadError* =
  "macOS LIBUS_USE_GCD requires listen/run on the process main thread; start app.run/listen/runAuto from main or run separate processes behind nginx/haproxy"

when not defined(windows):
  type
    IOVec {.importc: "struct iovec", header: "<sys/uio.h>".} = object
      iov_base: pointer
      iov_len: csize_t

  proc us_socket_writev_n(
    ssl: cint,
    s: UsSocketPtr,
    iov: ptr IOVec,
    iovcnt: cint,
    totalLength: cint
  ): cint {.cdecl, importc.}

when defined(macosx):
  proc CFRunLoopGetCurrent(): pointer {.importc, header: "<CoreFoundation/CoreFoundation.h>".}
  proc CFRunLoopStop(rl: pointer) {.importc, header: "<CoreFoundation/CoreFoundation.h>".}
  proc pthread_main_np(): cint {.importc, header: "<pthread.h>".}

  type
    SfHdtr {.importc: "struct sf_hdtr", header: "<sys/socket.h>".} = object
      headers: ptr IOVec
      hdr_cnt: cint
      trailers: ptr IOVec
      trl_cnt: cint

  proc osxSendfile(
    fd: cint,
    s: cint,
    offset: Off,
    len: ptr Off,
    hdtr: ptr SfHdtr,
    flags: cint
  ): cint {.importc: "sendfile", header: "<sys/socket.h>".}

  type
    QosClassT = cint

  const
    QOS_CLASS_USER_INITIATED = 0x19

  proc pthread_set_qos_class_self_np(qosClass: QosClassT, relativePriority: cint): cint
    {.importc, header: "<pthread.h>".}
elif defined(linux):
  proc linuxSendfile(
    outFd: cint,
    inFd: cint,
    offset: ptr Off,
    count: csize_t
  ): clong {.importc: "sendfile", header: "<sys/sendfile.h>".}

  when not declared(TCP_NOTSENT_LOWAT):
    const TCP_NOTSENT_LOWAT = 25.cint
  when not declared(TCP_DEFER_ACCEPT):
    const TCP_DEFER_ACCEPT = 9.cint
  when not declared(TCP_KEEPIDLE):
    const TCP_KEEPIDLE = 4.cint
  when not declared(SO_INCOMING_CPU):
    const SO_INCOMING_CPU = 49.cint

when defined(perfModeThroughput):
  const
    SmallFrameStackLimit = 2048
    WsPreparedDirectThreshold = 8 * 1024
    InputCompactThreshold = 128 * 1024
    WsInputCompactThreshold = 128 * 1024
    DefaultParseBudgetRequestsPerRead = 64
    DefaultParseBudgetBytesPerRead = 1024 * 1024
elif defined(perfModeLatency):
  const
    SmallFrameStackLimit = 256
    WsPreparedDirectThreshold = 1024
    InputCompactThreshold = 16 * 1024
    WsInputCompactThreshold = 16 * 1024
    DefaultParseBudgetRequestsPerRead = 4
    DefaultParseBudgetBytesPerRead = 64 * 1024
else:
  const
    SmallFrameStackLimit = 1024
    WsPreparedDirectThreshold = 4 * 1024
    InputCompactThreshold = 64 * 1024
    WsInputCompactThreshold = 64 * 1024
    DefaultParseBudgetRequestsPerRead = 32
    DefaultParseBudgetBytesPerRead = 512 * 1024

when defined(posix):
  var sigpipeInstalled {.global.} = false

  ## Ignore SIGPIPE on POSIX builds so writes to dead peers do not kill the process
  proc installSignalHandlers*() =
    if sigpipeInstalled:
      return
    sigpipeInstalled = true
    var sa: Sigaction
    sa.sa_handler = SIG_IGN
    sa.sa_flags = 0
    discard sigemptyset(sa.sa_mask)
    discard sigaction(SIGPIPE, sa, nil)

const
  WebSocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  HttpVersion10 = "HTTP/1.0"
  HttpVersion11 = "HTTP/1.1"
  InitialBufferSize = 1024
  PendingCompactThreshold = 64
  MaxCoalescedWriteBytes = 64 * 1024
  MaxCoalescedResponses = 16
  DefaultWriteCoalesceLatencyMaxBytes = 16 * 1024
  DefaultWriteCoalesceLatencyMaxResponses = 4
  DefaultWriteCoalesceThroughputMaxBytes = 128 * 1024
  DefaultWriteCoalesceThroughputMaxResponses = 32
  DefaultWriteCoalesceSmallPayloadBytes = 4 * 1024
  DefaultWriteCoalesceLargePayloadBytes = 32 * 1024
  DefaultWriteCoalesceP99GuardPendingBytes = 96 * 1024
  DefaultWriteCoalesceP99GuardPendingResponses = 8
  DefaultTlsFlattenThreshold = 16 * 1024
  DefaultLoopDispatchBudgetRequests = 256
  DefaultLoopDispatchBudgetBytes = 4 * 1024 * 1024
  DefaultWriteBudgetIterationsPerFlush = 32
  DefaultWriteBudgetBytesPerFlush = 512 * 1024
  DefaultLoopWriteBudgetBytes = 4 * 1024 * 1024
  DefaultWritevIovMax = 1024
  MinimumWritevIovMax = 16
  DefaultReadBufferMinCapacity = InitialBufferSize
  DefaultReadBufferMaxCapacity = 64 * 1024
  DefaultReadBufferShrinkPercent = 25
  DefaultMaxBodySize = 10 * 1024 * 1024
  DefaultMaxHeaderBytes = 16 * 1024
  DefaultMaxHeaderCount = 100
  DefaultMaxHeaderLineBytes = 8 * 1024
  DefaultMaxRequestUriBytes = 8192
  DefaultWsMaxFragmentCount = 1024
  # Security: Connection timeout bounds overall connection lifespan as a final
  # backstop against resource exhaustion. HTTP keep-alive typically uses 60s,
  # but 120s provides headroom for legitimate slow connections while still
  # limiting exposure. Set to 0 to explicitly disable if required.
  DefaultConnectionTimeout = 120
  DefaultMaxConnections = 100000
  DefaultWsKeepaliveInterval = 30000
  # Security: WebSocket idle timeout prevents abandoned connections from
  # consuming server resources indefinitely. 60s balances responsiveness
  # with protection. Set to 0 to explicitly disable if required.
  DefaultWsIdleTimeoutSeconds = 60
  # uSockets socket timeout wheel: 240 slots x 4s sweep granularity.
  WsIdleTimeoutWheelHorizonSeconds = 960
  DefaultWsCompressionMinBytes = 1024
  DefaultWsCompressionMinSavingsBytes = 24
  DefaultWsWriteCoalesceMaxBytes = 64 * 1024
  DefaultWsWriteCoalesceMaxFrames = 1
  DefaultMaxPendingBytesPerSocket = 64 * 1024
  DefaultWsMaxBackpressure = 128 * 1024
  DefaultBodySpillOffloadQueueLimit = 256
  DefaultBodySpillOffloadQueueBytesLimit = 8 * 1024 * 1024
  DefaultSpillPressureRejectThreshold = 8
  DefaultSpillPressureRecoverThreshold = 2
  DefaultOverloadAdaptiveMinBacklogBytes = 256 * 1024
  DefaultOverloadAdaptiveMinPendingResponses = 64
  DefaultOverloadAdaptiveTightenStepPercent = 20
  DefaultOverloadAdaptiveRelaxStepPercent = 10
  DefaultOverloadAdaptiveCooldownRequests = 64
  DefaultOverloadRetryAfterSeconds = 1
  DefaultGracefulShutdownDrainMs = 3000
  H2ControlFrameRateLimit = 1000
  H2ControlFrameRateWindowMs = 10_000.0
  H2MaxContinuationFrames = 64
  H2MaxRequestBodyBytes {.used.} = 10 * 1024 * 1024
  # Security: Non-zero defaults mitigate slowloris-style attacks where attackers
  # open connections and send data very slowly to exhaust server resources.
  # Set to 0 to explicitly disable if required for specific use cases.
  DefaultHeaderReadTimeoutMs = 30_000  # 30s - time to receive complete request headers
  DefaultBodyReadTimeoutMs = 30_000    # 30s - time to receive complete request body
  DefaultHandlerExecTimeoutMs = 0      # Disabled by default - handler duration varies by application
  DefaultWriteDrainTimeoutMs = 0       # Disabled by default - write drain depends on client speed
  DefaultCrossThreadDeferQueueLimit = 4096
  DefaultRequestMemoryBudget* = 32 * 1024 * 1024
  LibusListenOptionDefault = 0
  LibusListenOptionExclusivePort = 2
  LibusListenOptionEpollExclusive = 4
  LibusListenOptionEpollEdgeTrigger = 8
  LibusListenOptionTcpFastOpen = 16
  SegmentCoalesceCopyEnabled = not defined(uws_disable_segment_coalesce_copy)
  WsPerMessageDeflateExtension = "permessage-deflate"
  WsPerMessageDeflateTail {.used.} = "\x00\x00\xff\xff"
  WsClose1002 = "\x03\xEA"
  WsClose1007 = "\x03\xEF"
  WsClose1009 = "\x03\xF1"
  WsClose1011 = "\x03\xF3"
  BadRequestResponse {.used.} = "HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  RequestHeaderFieldsTooLargeResponse {.used.} = "HTTP/1.1 431 Request Header Fields Too Large\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  UriTooLongResponse {.used.} = "HTTP/1.1 414 URI Too Long\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  NotImplementedResponse = "HTTP/1.1 501 Not Implemented\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  HttpVersionNotSupportedResponse {.used.} = "HTTP/1.1 505 HTTP Version Not Supported\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  ExpectationFailedResponse {.used.} = "HTTP/1.1 417 Expectation Failed\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  HeaderContentLength = "content-length"
  HeaderConnection = "connection"
  HeaderContentType = "content-type"
  HeaderUpgrade = "upgrade"
  HeaderSecWebSocketKey = "sec-websocket-key"
  HeaderSecWebSocketVersion = "sec-websocket-version"
  HeaderSecWebSocketExtensions = "sec-websocket-extensions"
  HeaderCookie = "cookie"
  HeaderHost = "host"
  HeaderExpect = "expect"
  HeaderTransferEncoding = "transfer-encoding"
  HeaderSetCookie = "set-cookie"
  HeaderDate = "date"
  HfContentLength = 1'u32 shl 0
  HfTransferEncoding = 1'u32 shl 1
  HfConnection = 1'u32 shl 2
  HfHost = 1'u32 shl 3
  HfExpect = 1'u32 shl 4
  HfUpgrade = 1'u32 shl 5
  HfSecWebSocketKey = 1'u32 shl 6
  HfSecWebSocketVersion = 1'u32 shl 7
  HfContentType = 1'u32 shl 8
  HfCookie = 1'u32 shl 9
  HfSecWebSocketExtensions = 1'u32 shl 10
  HeaderLineTextContentType = "content-type: text/plain; charset=utf-8\r\n"
  HeaderLineConnectionClose = "connection: close\r\n"
  HeaderLineConnectionKeepAlive = "connection: keep-alive\r\n"
  HeaderLineContentLengthPrefix = "content-length: "
  TokenCharTable: array[256, bool] = block:
    var arr: array[256, bool]
    for c in byte('0')..byte('9'):
      arr[c] = true
    for c in byte('A')..byte('Z'):
      arr[c] = true
    for c in byte('a')..byte('z'):
      arr[c] = true
    for ch in "!#$%&'*+-.^_`|~":
      arr[byte(ch)] = true
    arr

  ValidHeaderValueByteTable: array[256, bool] = block:
    var t: array[256, bool]
    t[0x09] = true
    for i in 0x20..0x7E: t[i] = true
    for i in 0x80..0xFF: t[i] = true
    t

  ToLowerTable: array[256, byte] = block:
    var t: array[256, byte]
    for i in 0..255: t[i] = byte(i)
    for i in byte('A')..byte('Z'):
      t[i] = i or 0x20'u8
    t

let
  hashContentLength = hashKey(HeaderContentLength)
  hashConnection = hashKey(HeaderConnection)
  hashContentType = hashKey(HeaderContentType)
  hashUpgrade = hashKey(HeaderUpgrade)
  hashSecWebSocketKey = hashKey(HeaderSecWebSocketKey)
  hashSecWebSocketVersion = hashKey(HeaderSecWebSocketVersion)
  hashSecWebSocketExtensions = hashKey(HeaderSecWebSocketExtensions)
  hashCookie = hashKey(HeaderCookie)
  hashHost = hashKey(HeaderHost)
  hashExpect = hashKey(HeaderExpect)
  hashTransferEncoding = hashKey(HeaderTransferEncoding)
  hashSetCookie {.used.} = hashKey(HeaderSetCookie)
  hashDate {.used.} = hashKey(HeaderDate)

when compileOption("threads"):
  type
    SpillTask = object
      body: string
      spillDir: string

    SpillWorkerState = ref object
      lock: Lock
      cond: Cond
      queue: seq[SpillTask]
      head: int
      count: int
      maxQueued: int
      queuedBytes: int
      maxQueuedBytes: int
      stopping: bool

type
  RequestMemoryBudget* = object
    used*: int
    limit*: int

  ExpectContinueMode* = enum
    ecmStrictReject
    ecmAllow100Continue

  WriteCoalesceMode* = enum
    wcmAdaptive
    wcmLatency
    wcmBalanced
    wcmThroughput

  HttpMethod* = enum
    hmGet = "GET"
    hmPost = "POST"
    hmPut = "PUT"
    hmDelete = "DELETE"
    hmPatch = "PATCH"
    hmHead = "HEAD"
    hmOptions = "OPTIONS"
    hmConnect = "CONNECT"
    hmTrace = "TRACE"

  HttpStatus* = enum
    Http100 = "100 Continue"
    Http101 = "101 Switching Protocols"
    Http200 = "200 OK"
    Http201 = "201 Created"
    Http204 = "204 No Content"
    Http205 = "205 Reset Content"
    Http301 = "301 Moved Permanently"
    Http302 = "302 Found"
    Http304 = "304 Not Modified"
    Http400 = "400 Bad Request"
    Http401 = "401 Unauthorized"
    Http403 = "403 Forbidden"
    Http404 = "404 Not Found"
    Http405 = "405 Method Not Allowed"
    Http500 = "500 Internal Server Error"
    Http502 = "502 Bad Gateway"
    Http503 = "503 Service Unavailable"

  ParsedHeaderKind* = enum
    hkNone
    hkContentLength
    hkTransferEncoding
    hkConnection
    hkHost
    hkExpect
    hkUpgrade
    hkSecWebSocketKey
    hkSecWebSocketVersion
    hkSecWebSocketExtensions
    hkContentType
    hkCookie

  ByteSlice* = object
    startPos*: int32
    endPos*: int32

  RawHeaderSlice* = object
    keyStart*: int32
    keyEnd*: int32
    valStart*: int32
    valEnd*: int32
    kind*: ParsedHeaderKind

  HttpRequest* = ref object
    pathStr: string
    queryStr: string
    httpVersionStr: string
    httpMajor*: int
    httpMinor*: int
    body*: string
    bodyFilePath*: string
    bodyFileRoot*: string
    bodyInFile*: bool
    remoteIp*: string
    headers*: FastMap[string]
    query*: FastMap[string]
    headerFlags*: uint32
    methodKind*: HttpMethod
    connectionClose*: bool
    connectionHasUpgrade: bool
    upgradeStr: string
    wsKeyStr: string
    wsVersionStr: string
    wsExtensionsStr: string
    contentTypeStr: string
    cookieStr: string
    headersDeferred*: bool
    pathSlice: ByteSlice
    querySlice: ByteSlice
    upgradeSlice: ByteSlice
    wsKeySlice: ByteSlice
    wsVersionSlice: ByteSlice
    wsExtensionsSlice: ByteSlice
    contentTypeSlice: ByteSlice
    cookieSlice: ByteSlice
    bufferPtr: pointer
    bufferLen: int32
    sliceMask: uint16
    knownHeaders: array[ParsedHeaderKind, ByteSlice]
    knownHeaderPresent: set[ParsedHeaderKind]
    rawHeaders: array[64, RawHeaderSlice]
    rawHeaderCount: int16
    rawHeadersClassified: bool
    cachedHostStr: string

const
  smPath = 1'u16 shl 0
  smQuery = 1'u16 shl 1
  smUpgrade = 1'u16 shl 2
  smWsKey = 1'u16 shl 3
  smWsVersion = 1'u16 shl 4
  smWsExtensions = 1'u16 shl 5
  smContentType = 1'u16 shl 6
  smCookie = 1'u16 shl 7

## Attempt to charge bytes against the request memory budget and report whether the charge fit
proc chargeMemory*(budget: var RequestMemoryBudget, bytes: int): bool {.inline.} =
  if budget.limit > 0 and budget.used + bytes > budget.limit:
    return false
  budget.used += bytes
  true

## Create a request memory budget starting empty with the given byte limit
proc initRequestMemoryBudget*(limit: int = DefaultRequestMemoryBudget): RequestMemoryBudget {.inline.} =
  RequestMemoryBudget(used: 0, limit: limit)

proc materializeSlice(bufPtr: pointer, sl: ByteSlice): string {.inline.} =
  let n = int(sl.endPos - sl.startPos)
  if n <= 0 or bufPtr == nil:
    return ""
  result = newStringUninit(n)
  copyMem(addr result[0], cast[pointer](cast[uint](bufPtr) + uint(sl.startPos)), n)

## Return the request path, materializing the zero-copy slice from the socket buffer when needed
proc path*(req: HttpRequest): lent string {.inline.} =
  if (req.sliceMask and smPath) != 0 and req.pathStr.len == 0:
    req.pathStr = materializeSlice(req.bufferPtr, req.pathSlice)
    req.sliceMask = req.sliceMask and not smPath
  req.pathStr

proc `path=`*(req: HttpRequest, value: string) {.inline.} =
  req.pathStr = value
  req.sliceMask = req.sliceMask and not smPath

## Return the raw query string, materializing the zero-copy slice from the socket buffer when needed
proc queryStringRaw*(req: HttpRequest): lent string {.inline.} =
  if (req.sliceMask and smQuery) != 0 and req.queryStr.len == 0:
    req.queryStr = materializeSlice(req.bufferPtr, req.querySlice)
    req.sliceMask = req.sliceMask and not smQuery
  req.queryStr

proc `queryStringRaw=`*(req: HttpRequest, value: string) {.inline.} =
  req.queryStr = value
  req.sliceMask = req.sliceMask and not smQuery

## Return the HTTP version string parsed for this request
proc httpVersion*(req: HttpRequest): lent string {.inline.} =
  req.httpVersionStr

proc `httpVersion=`*(req: HttpRequest, value: string) {.inline.} =
  req.httpVersionStr = value

## Return the Upgrade header value, materializing the zero-copy slice when needed
proc upgradeHeader*(req: HttpRequest): lent string {.inline.} =
  if (req.sliceMask and smUpgrade) != 0 and req.upgradeStr.len == 0:
    req.upgradeStr = materializeSlice(req.bufferPtr, req.upgradeSlice)
    req.sliceMask = req.sliceMask and not smUpgrade
  req.upgradeStr

proc `upgradeHeader=`*(req: HttpRequest, value: string) {.inline.} =
  req.upgradeStr = value
  req.sliceMask = req.sliceMask and not smUpgrade

## Return the Sec-WebSocket-Key header value, materializing the zero-copy slice when needed
proc secWebSocketKeyHeader*(req: HttpRequest): lent string {.inline.} =
  if (req.sliceMask and smWsKey) != 0 and req.wsKeyStr.len == 0:
    req.wsKeyStr = materializeSlice(req.bufferPtr, req.wsKeySlice)
    req.sliceMask = req.sliceMask and not smWsKey
  req.wsKeyStr

proc `secWebSocketKeyHeader=`*(req: HttpRequest, value: string) {.inline.} =
  req.wsKeyStr = value
  req.sliceMask = req.sliceMask and not smWsKey

## Return the Sec-WebSocket-Version header value, materializing the zero-copy slice when needed
proc secWebSocketVersionHeader*(req: HttpRequest): lent string {.inline.} =
  if (req.sliceMask and smWsVersion) != 0 and req.wsVersionStr.len == 0:
    req.wsVersionStr = materializeSlice(req.bufferPtr, req.wsVersionSlice)
    req.sliceMask = req.sliceMask and not smWsVersion
  req.wsVersionStr

proc `secWebSocketVersionHeader=`*(req: HttpRequest, value: string) {.inline.} =
  req.wsVersionStr = value
  req.sliceMask = req.sliceMask and not smWsVersion

## Return the Sec-WebSocket-Extensions header value, materializing the zero-copy slice when needed
proc secWebSocketExtensionsHeader*(req: HttpRequest): lent string {.inline.} =
  if (req.sliceMask and smWsExtensions) != 0 and req.wsExtensionsStr.len == 0:
    req.wsExtensionsStr = materializeSlice(req.bufferPtr, req.wsExtensionsSlice)
    req.sliceMask = req.sliceMask and not smWsExtensions
  req.wsExtensionsStr

proc `secWebSocketExtensionsHeader=`*(req: HttpRequest, value: string) {.inline.} =
  req.wsExtensionsStr = value
  req.sliceMask = req.sliceMask and not smWsExtensions

## Return the Content-Type header value, materializing the zero-copy slice when needed
proc contentTypeHeader*(req: HttpRequest): lent string {.inline.} =
  if (req.sliceMask and smContentType) != 0 and req.contentTypeStr.len == 0:
    req.contentTypeStr = materializeSlice(req.bufferPtr, req.contentTypeSlice)
    req.sliceMask = req.sliceMask and not smContentType
  req.contentTypeStr

proc `contentTypeHeader=`*(req: HttpRequest, value: string) {.inline.} =
  req.contentTypeStr = value
  req.sliceMask = req.sliceMask and not smContentType

## Return the Cookie header value, materializing the zero-copy slice when needed
proc cookieHeader*(req: HttpRequest): lent string {.inline.} =
  if (req.sliceMask and smCookie) != 0 and req.cookieStr.len == 0:
    req.cookieStr = materializeSlice(req.bufferPtr, req.cookieSlice)
    req.sliceMask = req.sliceMask and not smCookie
  req.cookieStr

proc `cookieHeader=`*(req: HttpRequest, value: string) {.inline.} =
  req.cookieStr = value
  req.sliceMask = req.sliceMask and not smCookie

proc putMergedCookieHeader(req: HttpRequest, value: string) {.inline.} =
  let prev = req.headers.getViewHashed(HeaderCookie, hashCookie)
  if prev.len > 0:
    discard req.headers.putHashed(HeaderCookie, hashCookie, $prev & "; " & value)
  else:
    discard req.headers.putHashed(HeaderCookie, hashCookie, value)

type
  HttpWritableHandler* = proc(writeOffset: uint64): bool {.closure.}
  ConnectionOpenHandler* = proc(remoteIp: string) {.closure.}
  ConnectionCloseHandler* = proc(
    remoteIp: string,
    wasWebSocket: bool,
    requestSeq: uint64,
    socketKey: uint64
  ) {.closure.}
  RequestStartHandler* = proc(req: HttpRequest) {.closure.}
  RequestEndHandler* = proc(req: HttpRequest, statusCode: int, durationMicros: int64) {.closure.}
  BeforeHeadersHandler* = proc(req: HttpRequest, res: HttpResponse) {.closure.}
  BeforeWriteHandler* = proc(bytes: int, isWebSocket: bool) {.closure.}
  AfterWriteHandler* = proc(bytes: int, ok: bool, isWebSocket: bool) {.closure.}
  BackpressureHandler* = proc(bufferedBytes: int64, isWebSocket: bool) {.closure.}
  BackpressureHighWaterAction* = enum
    bhwDropNewest
    bhwDropOldest
    bhwClose
  BackpressureHighWaterDecision* = object
    triggered*: bool
    projectedBytes*: int64
    action*: BackpressureHighWaterAction
  TimeoutHandler* = proc(kind: string, remoteIp: string) {.closure.}
  TimeoutMetadataHandler* = proc(
    kind: string,
    phase: string,
    remoteIp: string,
    requestSeq: uint64,
    isWebSocket: bool
  ) {.closure.}
  ProtocolErrorTransformHandler* = proc(
    statusCode: int,
    remoteIp: string
  ): tuple[statusCode: int, body: string, closeConnection: bool] {.closure.}
  ErrorHandler* = proc(message: string) {.closure.}
  PanicHandler* = proc(message: string) {.closure.}

  OverloadRejectReason = enum
    orrNone
    orrBacklog
    orrPending

  TimeoutPhase = enum
    tpNone
    tpHeaderRead
    tpBodyRead
    tpHandlerExec
    tpWriteDrain
    tpWebSocketIdle

  HttpResponse* = ref object
    socket*: UsSocketPtr
    headers*: FastMap[string]
    setCookieHeaders: seq[string]
    requestRef*: HttpRequest
    requestSeq*: uint64
    ssl*: cint
    statusCode*: HttpStatus
    statusCodeInt*: int
    requestMethod*: HttpMethod
    requestIsHttp11*: bool
    autoEnd*: bool
    connectionClose*: bool
    headersInited*: bool
    bodySent*: bool
    headersSent*: bool
    chunkedStarted*: bool
    chunkedFinished*: bool
    tryEndOffset*: uint64
    tryEndQueued*: uint64
    tryEndTotal*: uint64
    tryEndActive*: bool
    capturedHeader*: string
    capturedBody*: string
    capturedRaw*: string
    captureForward*: HttpResponse
    captureBypassCache*: bool
    writableHandler*: HttpWritableHandler
    retainCount: int
    h2StreamId*: uint32
    h2Conn*: H2ServerConnection

  HttpHandler* = proc(req: HttpRequest, res: HttpResponse) {.closure.}

  # WebSocket types
  WebSocketOpcode* = enum
    wsText = 0x1
    wsBinary = 0x2
    wsClose = 0x8
    wsPing = 0x9
    wsPong = 0xA

  WebSocket* = ref object
    socket*: UsSocketPtr
    ssl*: cint
    isOpen*: bool
    server*: HttpServer
    subscriptions*: FastSet
    compressionEnabled*: bool

  PreparedWsMessage* = ref object
    frame*: string
    payloadBytes*: int
    isBinary*: bool
  WsQueuedFrame = object
    paletteIdx: int
    frameOffset: int
    payloadBytes: int
    isBinary: bool
    isControl: bool

  WebSocketHandler* = proc(ws: WebSocket, message: string, isBinary: bool) {.closure.}
  WebSocketRawHandler* = proc(ws: WebSocket, data: pointer, dataLen: int, isBinary: bool) {.closure.}
  WebSocketUpgradeValidateHandler* = proc(req: HttpRequest): bool {.closure.}
  WebSocketOpenHandler* = proc(ws: WebSocket) {.closure.}
  WebSocketCloseHandler* = proc(ws: WebSocket) {.closure.}
  WebSocketDrainHandler* = proc(ws: WebSocket, bufferedBytes: int64) {.closure.}
  WebSocketDroppedHandler* = proc(ws: WebSocket, payloadBytes: int, isBinary: bool) {.closure.}
  WebSocketHighWaterHandler* = proc(ws: WebSocket, bufferedBytes: int64, action: BackpressureHighWaterAction) {.closure.}

  TimerCallback* = proc() {.closure.}
  ShutdownCallback* = proc() {.closure.}

  ServerOptions* = object
    maxBodySize*: int           # Max request body size in bytes (default: 10MB)
    maxHeaderBytes*: int        # Max request-line+header bytes (0 = unlimited)
    maxHeaderCount*: int        # Max number of header fields (0 = unlimited)
    maxHeaderLineBytes*: int    # Max bytes per header line excluding CRLF (0 = unlimited)
    maxRequestUriBytes*: int    # Max request-target bytes (0 = unlimited, default: 8192)
    wsMaxFragmentCount*: int    # Max continuation fragments before forcing close (0 = unlimited, default: 1024)
    expectContinueMode*: ExpectContinueMode # Default strict reject; optional 100-continue acceptance
    connectionTimeout*: int     # Overall connection timeout in seconds (default: 120, 0 = disabled)
                                # Security: Final backstop against resource exhaustion from long-lived connections
    maxConnections*: int        # Max concurrent connections (default: 10000)
    maxPendingBytesPerSocket*: int  # Max queued unsent bytes per socket
    wsKeepaliveInterval*: int   # WebSocket keepalive ping interval in ms (default: 30000)
    wsIdleTimeoutSeconds*: int  # WebSocket idle timeout in seconds (default: 60, 0 = disabled)
                                # Security: Prevents abandoned websocket connections from exhausting resources
    wsMaxBackpressure*: int     # Max queued outgoing websocket bytes per socket (0 = unlimited)
    wsBackpressureHighWaterBytes*: int # High-water threshold for websocket backpressure queue (0 = disabled)
    wsBackpressureHighWaterAction*: BackpressureHighWaterAction # Deterministic action on high-water overflow
    wsDynamicBackpressureEnabled*: bool # Derive ws high-water from expected load and queue memory budget
    wsExpectedConnections*: int # Expected concurrent websockets for dynamic backpressure sizing
    wsMessageBytes*: int # Typical websocket message bytes for dynamic backpressure sizing
    wsQueueBudgetBytes*: int # Total outgoing ws queue budget for dynamic backpressure sizing
    wsCloseOnBackpressureLimit*: bool  # Close websocket when backpressure limit is hit
    wsResetIdleTimeoutOnSend*: bool # Refresh ws idle timeout after successful send/drain writes
    wsCompressionEnabled*: bool # Negotiate/use permessage-deflate when supported
    wsCompressionMinBytes*: int # Minimum payload bytes before considering compression
    wsCompressionServerNoContextTakeover*: bool # Require no server compression context takeover
    wsCompressionClientNoContextTakeover*: bool # Require no client compression context takeover
    wsCompressionDisableForBinary*: bool # Bypass compression for binary frames
    wsCompressionDisableForText*: bool # Bypass compression for text frames
    wsCompressionBackpressureBypassBytes*: int # Bypass compression when pending bytes exceed this threshold
    wsCompressionMinSavingsBytes*: int # Require at least this many bytes saved to use compressed payload
    wsWriteCoalesceMaxBytes*: int # Max websocket queued bytes coalesced into one flush write
    wsWriteCoalesceMaxFrames*: int # Max websocket queued frames coalesced into one flush write
    minimalHeaderParsing*: bool # Parse only hot/required headers for lower overhead
    gracefulShutdown*: bool     # Enable graceful shutdown on SIGINT/SIGTERM (default: true)
    macosHighQos*: bool         # Apply USER_INITIATED QoS to loop threads on macOS
    tlsFlattenThreshold*: int   # For TLS writes: merge header+body up to this size
    writeCoalesceMode*: WriteCoalesceMode # Adaptive/latency/balanced/throughput mode selector
    writeCoalesceMaxBytes*: int # Max bytes to coalesce in queued HTTP flush
    writeCoalesceMaxResponses*: int # Max responses to coalesce in queued HTTP flush
    writeCoalesceLatencyMaxBytes*: int # Low-latency coalescing cap (bytes)
    writeCoalesceLatencyMaxResponses*: int # Low-latency coalescing cap (responses)
    writeCoalesceThroughputMaxBytes*: int # Throughput coalescing cap (bytes)
    writeCoalesceThroughputMaxResponses*: int # Throughput coalescing cap (responses)
    writeCoalesceSmallPayloadBytes*: int # Payload <= threshold prefers latency profile
    writeCoalesceLargePayloadBytes*: int # Payload >= threshold prefers throughput profile
    writeCoalesceP99GuardPendingBytes*: int # Low-backlog guard to avoid p99 regressions
    writeCoalesceP99GuardPendingResponses*: int # Low-backlog guard for pending response count
    loopWriteBatching*: bool # Defer response writes until end of event-loop tick (throughput vs latency tradeoff)
    readBufferMinCapacity*: int # Adaptive input buffer lower bound
    readBufferMaxCapacity*: int # Adaptive input buffer upper bound
    readBufferShrinkPercent*: int # Shrink threshold in percent of current target
    parseBudgetRequestsPerRead*: int # Max requests parsed per read callback
    parseBudgetBytesPerRead*: int # Max bytes consumed per read callback
    loopDispatchBudgetRequests*: int # Max dispatched requests/frames per loop iteration
    loopDispatchBudgetBytes*: int # Max dispatched bytes per loop iteration
    writeBudgetIterationsPerFlush*: int # Max queued write iterations drained per socket flush
    writeBudgetBytesPerFlush*: int # Max queued write bytes drained per socket flush
    loopWriteBudgetBytes*: int # Max queued write bytes drained per loop iteration
    bodySpillThreshold*: int     # Spill request body to disk when content-length >= threshold (0 = disabled)
    bodySpillDir*: string        # Temp directory used for spilled request bodies
    bodySpillOffloadEnabled*: bool # Offload spill writes to background thread when threads are enabled
    bodySpillOffloadQueueLimit*: int # Max queued offload spill jobs (bounded)
    bodySpillOffloadQueueBytesLimit*: int # Max queued offload spill bytes (bounded)
    spillPressureRejectThreshold*: int # Spill drop pressure score that triggers overload rejection
    spillPressureRecoverThreshold*: int # Spill pressure score that clears overload rejection
    overloadMaxLoopBacklogBytes*: int # Reject when queued response bytes exceed this
    overloadMaxPendingResponses*: int # Reject when pending response slots exceed this
    overloadCloseOnReject*: bool # Close connection immediately after overload response
    overloadAdaptiveEnabled*: bool # Enable bounded closed-loop overload tuning
    overloadAdaptiveMinBacklogBytes*: int # Lower clamp for adaptive backlog limit
    overloadAdaptiveMaxBacklogBytes*: int # Upper clamp for adaptive backlog limit (0 = static max)
    overloadAdaptiveMinPendingResponses*: int # Lower clamp for adaptive pending-response limit
    overloadAdaptiveMaxPendingResponses*: int # Upper clamp for adaptive pending-response limit (0 = static max)
    overloadAdaptiveTightenStepPercent*: int # Percent decrement when sustained overload is detected
    overloadAdaptiveRelaxStepPercent*: int # Percent increment when pressure clears
    overloadAdaptiveCooldownRequests*: int # Min accepted/rejected samples before applying one adjustment
    overloadRetryAfterSeconds*: int # Optional Retry-After header value for overload responses (0 disables)
    socketNoDelay*: bool         # Apply TCP_NODELAY on accepted sockets
    socketKeepAlive*: bool       # Enable SO_KEEPALIVE
    socketKeepAliveSeconds*: int # Keepalive idle (best-effort per platform)
    socketFastOpen*: bool        # Enable TCP Fast Open where supported (best-effort)
    socketSendBufferBytes*: int  # SO_SNDBUF on accepted sockets (0 disables)
    socketRecvBufferBytes*: int  # SO_RCVBUF on accepted sockets (0 disables)
    socketNotSentLowWaterBytes*: int # TCP_NOTSENT_LOWAT on accepted sockets where supported
    socketDeferAcceptSeconds*: int # TCP_DEFER_ACCEPT on listen socket where supported (0 disables)
    socketIncomingCpu*: int      # SO_INCOMING_CPU on accepted sockets where supported (-1 disables)
    listenExclusivePort*: bool   # Use uSockets exclusive-port listen option; disables SO_REUSEPORT in bundled uSockets
    listenEpollExclusive*: bool  # Opt-in EPOLLEXCLUSIVE for listen poll registration on Linux
    listenEpollEdgeTrigger*: bool # Opt-in EPOLLET listen registration policy on Linux
    gracefulShutdownDrainMs*: int # Graceful drain period before forced close
    headerReadTimeoutMs*: int # Header-read timeout in ms (default: 30000, 0 = disabled)
                              # Security: Mitigates slowloris attacks where clients send headers very slowly
    bodyReadTimeoutMs*: int   # Body-read timeout in ms (default: 30000, 0 = disabled)
                              # Security: Mitigates slow body attacks where clients send body data very slowly
    handlerExecTimeoutMs*: int # Handler execution timeout in milliseconds (default: 0 = disabled)
    writeDrainTimeoutMs*: int # Write-drain timeout in milliseconds (default: 0 = disabled)
    crossThreadDeferEnabled*: bool # Explicit cross-thread defer gateway enablement
    crossThreadDeferQueueLimit*: int # Max callbacks queued via deferFromAnyThread before drops
    wsSocketRecvBufferBytes*: int
    wsSocketSendBufferBytes*: int
    wsSocketNotSentLowWaterBytes*: int
    maxRequestMemory*: int

  # GC reference type used to root a SocketData object in
  # HttpServer.socketDataRoots while its socket is open.
  SocketDataRef = ref SocketData

  HttpServer* = ref object
    # Keep pointer/proc references grouped first to minimize padding on 64-bit.
    loop*: UsLoopPtr
    context*: UsSocketContextPtr
    listenSocket*: UsListenSocketPtr
    handler*: HttpHandler
    rawHandler*: HttpHandler
    wsHandler*: WebSocketHandler
    wsRawHandler*: WebSocketRawHandler
    wsUpgradeValidateHandler*: WebSocketUpgradeValidateHandler
    wsOpenHandler*: WebSocketOpenHandler
    wsCloseHandler*: WebSocketCloseHandler
    wsDrainHandler*: WebSocketDrainHandler
    wsDroppedHandler*: WebSocketDroppedHandler
    wsHighWaterHandler*: WebSocketHighWaterHandler
    startCallback*: TimerCallback
    timerCallback*: TimerCallback
    loopPreCallback*: TimerCallback
    loopPostCallback*: TimerCallback
    connectionOpenHandler*: ConnectionOpenHandler
    connectionCloseHandler*: ConnectionCloseHandler
    requestStartHandler*: RequestStartHandler
    requestEndHandler*: RequestEndHandler
    beforeHeadersHandler*: BeforeHeadersHandler
    beforeWriteHandler*: BeforeWriteHandler
    afterWriteHandler*: AfterWriteHandler
    backpressureHandler*: BackpressureHandler
    timeoutHandler*: TimeoutHandler
    timeoutMetadataHandler*: TimeoutMetadataHandler
    errorHandler*: ErrorHandler
    protocolErrorHandler*: ProtocolErrorTransformHandler
    panicHandler*: PanicHandler
    timer*: UsTimerPtr
    timerIntervalMs*: int
    internalTimerCallback*: TimerCallback
    internalTimer*: UsTimerPtr
    internalTimerIntervalMs*: int
    dateHeaderTimer*: UsTimerPtr
    wsKeepaliveTimer*: UsTimerPtr
    shutdownPollTimer*: UsTimerPtr
    cachedDateHeaderLine*: string
    cachedDateEpochSec*: int64
    stopCallback*: ShutdownCallback
    shutdownCallback*: ShutdownCallback
    host*: string
    options*: ServerOptions
    when compileOption("threads"):
      spillWorkerState: SpillWorkerState
      spillWorker: Thread[SpillWorkerState]
      spillWorkerRunning: bool
    websocketIndex*: FastMap[int64]
    websocketSet*: FastSet
    websockets*: seq[WebSocket]
    wsKeepaliveCursor*: int
    h2Connections: seq[H2ConnEntry]
    topicIndex*: FastMap[int64]
    topicNames*: seq[string]
    topicSubscribers*: seq[seq[WebSocket]]
    wsDrainQueue*: seq[WebSocket]
    wsDrainQueued*: FastSet
    socketTunableWarnings*: FastSet
    deferredPreCallbacks*: seq[TimerCallback]
    deferredCallbacks*: seq[TimerCallback]
    wsDrainFlushScheduled*: bool
    metricsParserErrors*: int64
    metricsOverloadRejects*: int64
    metricsOverloadRejectBacklog*: int64
    metricsOverloadRejectPending*: int64
    metricsWriteRetries*: int64
    metricsBackpressureDrops*: int64
    metricsBackpressureHighWaterEvents*: int64
    metricsSpillOffloadEnqueued*: int64
    metricsSpillOffloadDropped*: int64
    metricsCrossThreadDeferRerouted*: int64
    metricsCrossThreadDeferViolations*: int64
    metricsCrossThreadDeferDropped*: int64
    metricsSocketCloseAttempts*: int64
    metricsSocketCloseFailures*: int64
    metricsShutdownDrainedConnections*: int64
    metricsShutdownForcedConnections*: int64
    metricsSocketTunablesApplied*: int64
    metricsSocketTunablesUnsupported*: int64
    metricsSocketTunablesFailed*: int64
    overloadControlEnabled*: bool
    overloadAdaptiveBacklogLimit: int
    overloadAdaptivePendingLimit: int
    overloadAdaptiveRejectStreak: int
    overloadAdaptiveAcceptStreak: int
    spillPressureScore: int
    spillPressureRejecting: bool
    closeOutcomeCounts*: FastMap[int64]
    closeOutcomeWarnings*: FastSet
    fairnessEnabled*: bool
    loopWriteBatchDepth: int
    pendingFlushSockets: seq[PendingFlushEntry]
    closedSocketKeys: Table[uint64, uint64]
    socketDataRoots: Table[uint64, SocketDataRef]
    loopMaintenanceEpoch: uint64
    nextSocketGeneration: uint64
    loopDispatchRequestsRemaining: int
    loopDispatchBytesRemaining: int
    loopWriteBytesRemaining: int64
    when defined(macosx):
      macosMaintenanceDepth: int
      macosMaintenanceEpochMs: int64
      macosMaintenanceCounter*: uint64
      macosUserTimerLastMs: int64
      macosInternalTimerLastMs: int64
      macosWsKeepaliveLastMs: int64
    port*: int
    connectionCount*: int
    ssl*: SslMode
    isShuttingDown*: bool
    cleanupCompleted: bool
    shutdownStartedAtMs: int64
    shutdownForceCloseAtMs: int64
    shutdownConnectionSnapshot: int
    loopOwnerBound: bool
    loopOwnerThreadId: uint64
    when compileOption("threads"):
      crossThreadDeferLock: Lock
      crossThreadDeferQueue: seq[TimerCallback]
      crossThreadDeferPreQueue: seq[TimerCallback]
      crossThreadDeferWakePending: bool
      crossThreadDeferViolationWarned: bool
      crossThreadDeferOverflowWarned: bool
      crossThreadDeferAccepting: bool
      crossThreadDeferWakeClosing: bool
      crossThreadDeferWakeRefs: int

  QueuedResponse = object
    header: string
    body: string
    streamChunks: seq[string]
    fileOffset: Off
    fileRemaining: Off
    headerPos: int
    bodyPos: int
    streamChunkHead: int
    streamChunkPos: int
    fileFd: cint
    isFileBody: bool
    closeAfterWrite: bool
    isStreamBody: bool
    streamOpen: bool
    hasTryEnd: bool
    tryEndOffset: uint64
    tryEndTotal: uint64
    writableHandler: HttpWritableHandler
    hardFailure: bool

  PendingFlushEntry = tuple[
    sockData: ptr SocketData,
    socket: UsSocketPtr,
    socketKey: uint64,
    generation: uint64,
    ssl: cint
  ]

  H2ServerStream = object
    id: uint32
    state: h2p.H2StreamState
    sendWindow: int32
    recvWindow: int32
    headerBuf: string
    requestHeaders: seq[(string, string)]
    requestBody: string
    endStreamRecv: bool
    endStreamSent: bool
    headersReceived: bool
    pendingSendData: string
    pendingSendPos: int
    pendingSendEndStream: bool
    pendingSendSocket: UsSocketPtr
    pendingSendSsl: int

  H2ServerConnection = ref object
    active: bool
    sentGoaway: bool
    receivedGoaway: bool
    localSettings: h2p.H2Settings
    remoteSettings: h2p.H2Settings
    localWindow: int32
    remoteWindow: int32
    encoder: hpackMod.HpackEncoder
    decoder: hpackMod.HpackDecoder
    streams: Table[uint32, H2ServerStream]
    lastStreamId: uint32
    highestClientStreamId: uint32
    gotPreface: bool
    continuationStreamId: uint32
    continuationFrameCount: int
    headerBlockBuf: string
    h2SendBuf: string
    h2SendBufPos: int
    rstStreams: Table[uint32, bool]
    closedStreams: Table[uint32, bool]
    nextPushStreamId: uint32
    gotClientSettings: bool
    controlFrameCount: int
    controlFrameWindowStart: float

  H2ConnEntry = object
    conn: H2ServerConnection
    socket: UsSocketPtr
    ssl: cint

  SocketData = object
    magic: uint32
    server: HttpServer
    ws: WebSocket
    buffer: seq[byte]
    bufferStart: int
    flags: uint16
    wsOutQueue: seq[WsQueuedFrame]
    wsPendingBytes: int64
    wsFragmentOpcode: int
    wsFragmentCount: int
    pendingSlots: seq[QueuedResponse]
    pendingUsed: seq[bool]
    coalesceBuffer: string
    sendBuffer: string
    sendBufferPos: int
    pendingBytes: int64
    generation: uint64
    writeBatchDepth: int
    pendingStart: int
    pendingActiveCount: int
    readBufferTarget: int
    wsOutHead: int
    wsOutPos: int
    wsOutPalette: seq[string]
    wsOutPaletteRefs: seq[int]
    wsOutPaletteFree: seq[int]
    wsCoalesceBuffer: string
    wsFragmentPayload: string
    nextRequestSeq: uint64
    nextWriteSeq: uint64
    connectedAt: int64
    timeoutPhase: TimeoutPhase
    activeRequestSeq: uint64
    phaseStartedAtMs: int64
    timeoutPhaseSeconds: cuint
    cachedHostValue: string
    remoteIpData: array[46, byte]
    remoteIpLen: uint8
    h2conn: H2ServerConnection
    memoryBudget: RequestMemoryBudget

const
  SocketDataMagic = 0xAC_E5_DA_7A'u32
  SDF_PENDING_CLOSE = 0x0001'u16
  SDF_WS_HAD_BACKPRESSURE = 0x0002'u16
  SDF_WS_COMPRESSION_ACTIVE = 0x0004'u16
  SDF_READ_PAUSED = 0x0008'u16
  SDF_RESUME_SCHEDULED = 0x0010'u16
  SDF_HTTP_FLUSH_SCHEDULED = 0x0020'u16
  SDF_WS_FLUSH_SCHEDULED = 0x0040'u16
  SDF_IS_WEBSOCKET = 0x0080'u16
  SDF_WS_FRAGMENT_COMPRESSED = 0x0100'u16
  SDF_KEEP_ALIVE_HEADERS_CACHED = 0x0200'u16
  SDF_IS_HTTP2 = 0x0400'u16
  SDF_PENDING_LOOP_FLUSH = 0x0800'u16

template hasFlag(sd: ptr SocketData, flag: uint16): bool =
  (sd.flags and flag) != 0
template setFlag(sd: ptr SocketData, flag: uint16) =
  sd.flags = sd.flags or flag
template clearFlag(sd: ptr SocketData, flag: uint16) =
  sd.flags = sd.flags and not flag
template setFlagTo(sd: ptr SocketData, flag: uint16, value: bool) =
  if value: sd.setFlag(flag)
  else: sd.clearFlag(flag)

## Return the remote peer IP stored on the socket data as a fresh string
proc remoteIp*(sd: ptr SocketData): string {.inline.} =
  if sd.remoteIpLen == 0: return ""
  result = newString(int(sd.remoteIpLen))
  copyMem(addr result[0], addr sd.remoteIpData[0], int(sd.remoteIpLen))

## Return the remote peer IP stored on the passed socket data value
proc remoteIp*(sd: SocketData): string {.inline.} =
  if sd.remoteIpLen == 0: return ""
  result = newString(int(sd.remoteIpLen))
  copyMem(addr result[0], unsafeAddr sd.remoteIpData[0], int(sd.remoteIpLen))

## Store the remote peer IP on the socket data for later retrieval
proc setRemoteIp*(sd: ptr SocketData, ip: string) {.inline.} =
  let len = min(ip.len, sd.remoteIpData.len)
  sd.remoteIpLen = uint8(len)
  if len > 0:
    copyMem(addr sd.remoteIpData[0], unsafeAddr ip[0], len)

proc `remoteIp=`*(sd: var SocketData, ip: string) {.inline.} =
  setRemoteIp(addr sd, ip)

## Report whether the socket data currently represents an upgraded WebSocket connection
proc isWebSocket*(sd: SocketData): bool {.inline.} =
  (sd.flags and SDF_IS_WEBSOCKET) != 0

proc `isWebSocket=`*(sd: var SocketData, value: bool) {.inline.} =
  if value:
    sd.flags = sd.flags or SDF_IS_WEBSOCKET
  else:
    sd.flags = sd.flags and not SDF_IS_WEBSOCKET

# Pre-computed status strings for common cases
const StatusStrings: array[HttpStatus, string] = [
  "HTTP/1.1 100 Continue\r\n",
  "HTTP/1.1 101 Switching Protocols\r\n",
  "HTTP/1.1 200 OK\r\n",
  "HTTP/1.1 201 Created\r\n",
  "HTTP/1.1 204 No Content\r\n",
  "HTTP/1.1 205 Reset Content\r\n",
  "HTTP/1.1 301 Moved Permanently\r\n",
  "HTTP/1.1 302 Found\r\n",
  "HTTP/1.1 304 Not Modified\r\n",
  "HTTP/1.1 400 Bad Request\r\n",
  "HTTP/1.1 401 Unauthorized\r\n",
  "HTTP/1.1 403 Forbidden\r\n",
  "HTTP/1.1 404 Not Found\r\n",
  "HTTP/1.1 405 Method Not Allowed\r\n",
  "HTTP/1.1 500 Internal Server Error\r\n",
  "HTTP/1.1 502 Bad Gateway\r\n",
  "HTTP/1.1 503 Service Unavailable\r\n"
]

const DigitPairs: array[200, char] = block:
  var arr: array[200, char]
  for i in 0..99:
    arr[i * 2] = char(ord('0') + i div 10)
    arr[i * 2 + 1] = char(ord('0') + i mod 10)
  arr

proc fastIntToStr(n: int, buf: var string) {.inline.} =
  if n == 0:
    buf.add('0')
    return
  var num = n.int64
  if num < 0:
    buf.add('-')
    if num == low(int64):
      buf.add("9223372036854775808")
      return
    num = -num
  var tmp: array[24, char]
  var p = 24
  while num >= 100:
    let idx = int(num mod 100) * 2
    num = num div 100
    dec p; tmp[p] = DigitPairs[idx + 1]
    dec p; tmp[p] = DigitPairs[idx]
  if num >= 10:
    let idx = int(num) * 2
    dec p; tmp[p] = DigitPairs[idx + 1]
    dec p; tmp[p] = DigitPairs[idx]
  else:
    dec p; tmp[p] = char(ord('0') + int(num))
  let count = 24 - p
  let at = buf.len
  buf.setLen(at + count)
  copyMem(addr buf[at], addr tmp[p], count)

proc statusCodeValue(status: HttpStatus): int {.inline.} =
  case status
  of Http100: 100
  of Http101: 101
  of Http200: 200
  of Http201: 201
  of Http204: 204
  of Http205: 205
  of Http301: 301
  of Http302: 302
  of Http304: 304
  of Http400: 400
  of Http401: 401
  of Http403: 403
  of Http404: 404
  of Http405: 405
  of Http500: 500
  of Http502: 502
  of Http503: 503

proc statusForbidsContentLength(code: int): bool {.inline.} =
  (code >= 100 and code < 200) or code == 204

proc isConnectSuccess(res: HttpResponse): bool {.inline.} =
  if res == nil:
    return false
  let code = if res.statusCodeInt > 0: res.statusCodeInt else: res.statusCode.statusCodeValue
  res.requestMethod == hmConnect and code >= 200 and code < 300

const
  DayAbbrevs = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  MonAbbrevs = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

proc formatDateHeaderLine(epochSec: int64): string =
  let dt = fromUnix(epochSec).utc
  result = newStringOfCap(44)
  result.add("date: ")
  result.add(DayAbbrevs[ord(dt.weekday)])
  result.add(", ")
  let d = dt.monthday
  result.add(char(ord('0') + d div 10))
  result.add(char(ord('0') + d mod 10))
  result.add(' ')
  result.add(MonAbbrevs[ord(dt.month) - 1])
  result.add(' ')
  let y = dt.year
  result.add(char(ord('0') + y div 1000))
  result.add(char(ord('0') + (y div 100) mod 10))
  result.add(char(ord('0') + (y div 10) mod 10))
  result.add(char(ord('0') + y mod 10))
  result.add(' ')
  let h = dt.hour
  result.add(char(ord('0') + h div 10))
  result.add(char(ord('0') + h mod 10))
  result.add(':')
  let m = dt.minute
  result.add(char(ord('0') + m div 10))
  result.add(char(ord('0') + m mod 10))
  result.add(':')
  let sec = dt.second
  result.add(char(ord('0') + sec div 10))
  result.add(char(ord('0') + sec mod 10))
  result.add(" GMT\r\n")

proc refreshCachedDateHeader(server: HttpServer, nowSecArg: int64 = -1) {.inline.} =
  if server == nil:
    return
  var nowSec = nowSecArg
  if nowSec < 0:
    nowSec = getTime().toUnix
  if server.cachedDateEpochSec != nowSec or server.cachedDateHeaderLine.len == 0:
    server.cachedDateEpochSec = nowSec
    server.cachedDateHeaderLine = formatDateHeaderLine(nowSec)

proc currentDateHeaderLine(server: HttpServer): string =
  if server == nil:
    return formatDateHeaderLine(getTime().toUnix)
  when defined(macosx):
    # macOS/GCD path can run without native timer arming; refresh lazily per second.
    let nowSec = getTime().toUnix
    if server.cachedDateHeaderLine.len == 0 or server.cachedDateEpochSec != nowSec:
      refreshCachedDateHeader(server, nowSec)
  else:
    if server.cachedDateHeaderLine.len == 0:
      refreshCachedDateHeader(server)
  server.cachedDateHeaderLine

proc statusLineFor(res: HttpResponse): string {.inline.} =
  if res.statusCodeInt <= 0 or res.statusCodeInt == res.statusCode.statusCodeValue:
    return StatusStrings[res.statusCode]
  let code = res.statusCodeInt
  let reason = case code
    of 205: "Reset Content"
    of 422: "Unprocessable Content"
    of 426: "Upgrade Required"
    of 429: "Too Many Requests"
    of 501: "Not Implemented"
    of 505: "HTTP Version Not Supported"
    else: "Unknown"
  var line = newStringOfCap(32 + reason.len)
  line.add("HTTP/1.1 ")
  fastIntToStr(code, line)
  line.add(' ')
  line.add(reason)
  line.add("\r\n")
  line

proc isSetCookieHeader(key: string): bool {.inline.} =
  key.len == HeaderSetCookie.len and key.cmpIgnoreCase(HeaderSetCookie) == 0

proc isHeaderTokenChar(c: char): bool {.inline, used.} =
  TokenCharTable[byte(c)]

proc hasValidHeaderName(key: string): bool {.inline.} =
  if key.len == 0:
    return false
  var i = 0
  while i < key.len:
    if not TokenCharTable[byte(key[i])]:
      return false
    inc i
  true

proc hasUnsafeHeaderValueBytes(value: string): bool {.inline.} =
  var i = 0
  while i < value.len:
    if not ValidHeaderValueByteTable[byte(value[i])]:
      return true
    inc i
  false

proc hasValidHeaderValueBytes(data: openArray[byte], startPos: int, endPos: int): bool {.inline.} =
  var i = startPos
  while i < endPos:
    if not ValidHeaderValueByteTable[data[i]]:
      return false
    inc i
  true

proc wsKey(ws: WebSocket): string {.inline.} =
  if ws == nil or ws.socket == nil:
    return ""
  $cast[uint](ws.socket)

proc socketKey(s: UsSocketPtr): uint64 {.inline.} =
  cast[uint64](cast[uint](s))

proc socketKeyWasClosed(server: HttpServer, key: uint64): bool {.inline.} =
  server != nil and key != 0'u64 and server.closedSocketKeys.hasKey(key)

proc markSocketClosed(server: HttpServer, key: uint64) {.inline.} =
  if server == nil or key == 0'u64:
    return
  server.closedSocketKeys[key] = server.loopMaintenanceEpoch

proc clearSocketClosed(server: HttpServer, key: uint64) {.inline.} =
  if server == nil or key == 0'u64 or server.closedSocketKeys.len == 0:
    return
  server.closedSocketKeys.del(key)

proc clearClosedSocketTombstones(server: HttpServer) {.inline.} =
  if server != nil and server.closedSocketKeys.len > 0:
    var staleKeys: seq[uint64] = @[]
    for key, closedEpoch in server.closedSocketKeys.pairs:
      if closedEpoch + 1'u64 <= server.loopMaintenanceEpoch:
        staleKeys.add(key)
    for key in staleKeys:
      server.closedSocketKeys.del(key)

proc removeTrackedWebSocket(server: HttpServer, ws: WebSocket) {.inline.} =
  if server == nil or ws == nil:
    return
  let key = ws.wsKey()
  if key.len == 0:
    return

  var idx64: int64
  if server.websocketIndex != nil and server.websocketIndex.tryGet(key, idx64):
    let idx = int(idx64)
    let last = server.websockets.len - 1
    if idx >= 0 and idx <= last:
      if idx != last:
        let moved = server.websockets[last]
        server.websockets[idx] = moved
        let movedKey = moved.wsKey()
        if movedKey.len > 0:
          discard server.websocketIndex.put(movedKey, idx.int64)
      server.websockets.setLen(last)
      discard server.websocketIndex.del(key)
      if server.websocketSet != nil:
        discard server.websocketSet.excl(key)
      return

  # Fallback path for safety when index map misses.
  let idx = server.websockets.find(ws)
  if idx >= 0:
    let last = server.websockets.len - 1
    if idx != last:
      let moved = server.websockets[last]
      server.websockets[idx] = moved
      let movedKey = moved.wsKey()
      if movedKey.len > 0 and server.websocketIndex != nil:
        discard server.websocketIndex.put(movedKey, idx.int64)
    server.websockets.setLen(last)
  if server.websocketSet != nil:
    discard server.websocketSet.excl(key)
  if server.websocketIndex != nil:
    discard server.websocketIndex.del(key)

## Subscribe an open websocket to a topic for pub/sub fanout, forward declaration for internal loop use
proc subscribe*(ws: WebSocket, topic: string): bool
## Unsubscribe a websocket from a topic, forward declaration for internal loop use
proc unsubscribe*(ws: WebSocket, topic: string): bool
proc socketDataFor(ssl: cint, s: UsSocketPtr): ptr SocketData {.inline.}
proc flushQueuedWsDrainHandlers(server: HttpServer)
proc onSocketData(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.}
proc acquireWebSocket(socket: UsSocketPtr, ssl: cint, compressionEnabled: bool): WebSocket {.inline.}
proc releaseWebSocket(ws: WebSocket) {.inline.}
proc flushPendingResponses(sockData: ptr SocketData, s: UsSocketPtr)
proc closeSocketIfPending(sockData: ptr SocketData, s: UsSocketPtr)
proc flushWsQueuedFrames(sockData: ptr SocketData, s: UsSocketPtr)
proc emitServerPanic(server: HttpServer, source, message: string) {.inline.}
proc emitServerError(server: HttpServer, message: string) {.inline.}
## Schedule a callback for the next loop pre phase, forward declaration for internal use
proc deferPre*(server: HttpServer, callback: TimerCallback)
proc `defer`*(server: HttpServer, callback: TimerCallback)
proc beginShutdown(server: HttpServer)
proc loadShutdownRequested(): bool {.inline.}
proc readBufferMinFor(server: HttpServer): int {.inline.}
proc readBufferMaxFor(server: HttpServer): int {.inline.}
proc updateReadBufferTargetOnAppend(sockData: ptr SocketData, requiredBytes: int) {.inline.}
proc maybeShrinkReadBuffer(sockData: ptr SocketData) {.inline.}
proc shouldRejectForOverload(sockData: ptr SocketData): bool {.inline, used.}
proc rejectOverloadedSocket(sockData: ptr SocketData, s: UsSocketPtr) {.inline, used.}
proc rejectOverloadedSocket(sockData: ptr SocketData, s: UsSocketPtr, reason: OverloadRejectReason) {.inline.}
proc maxPendingBytesFor(sockData: ptr SocketData): int64 {.inline.}

proc appendPreparedNativeHeaders(header: var string, res: HttpResponse) =
  if res == nil:
    return
  var extra = ""
  if res.headersInited and res.headers.len > 0:
    for key, value in res.headers:
      if key == HeaderTransferEncoding or key == HeaderContentLength:
        continue
      extra.add(key)
      extra.add(": ")
      extra.add(value)
      extra.add("\r\n")
  if res.setCookieHeaders.len > 0:
    for cookie in res.setCookieHeaders:
      extra.add(HeaderSetCookie)
      extra.add(": ")
      extra.add(cookie)
      extra.add("\r\n")
  if extra.len == 0:
    return
  let insertAt =
    if header.len >= 2 and header[^2] == '\r' and header[^1] == '\n':
      header.len - 2
    else:
      header.len
  header.insert(extra, insertAt)

proc currentThreadIdValue(): uint64 {.inline.} =
  when defined(windows):
    GetCurrentThreadId().uint64
  else:
    cast[uint64](pthread_self())

proc bindLoopOwner(server: HttpServer) {.inline.} =
  if server == nil:
    return
  if not server.loopOwnerBound:
    server.loopOwnerThreadId = currentThreadIdValue()
    server.loopOwnerBound = true

proc assertLoopAffinity(server: HttpServer, operation: string) {.inline.} =
  when not defined(release):
    if server == nil:
      return
    server.bindLoopOwner()
    let currentId = currentThreadIdValue()
    if server.loopOwnerThreadId != currentId:
      let message = "loop affinity violation in " & operation
      server.emitServerError(message)
      raise newException(Defect, message)

proc assertResponseLoopAffinity(res: HttpResponse, operation: string) {.inline.} =
  when not defined(release):
    if res == nil or res.socket == nil:
      return
    let sockData = socketDataFor(res.ssl, res.socket)
    if sockData != nil and sockData.server != nil:
      sockData.server.assertLoopAffinity(operation)

proc assertWebSocketLoopAffinity(ws: WebSocket, operation: string) {.inline.} =
  when not defined(release):
    if ws == nil or ws.socket == nil:
      return
    if ws.server != nil:
      ws.server.assertLoopAffinity(operation)

proc isLoopOwnerThread(server: HttpServer): bool {.inline.} =
  if server == nil:
    return false
  if not server.loopOwnerBound:
    return false
  server.loopOwnerThreadId == currentThreadIdValue()

proc queueCrossThreadServerError(server: HttpServer, message: string) {.inline.}

proc emitCrossThreadDeferViolationOnce(server: HttpServer) {.inline.} =
  when compileOption("threads"):
    if server == nil:
      return
    var shouldEmit = false
    withLock(server.crossThreadDeferLock):
      if not server.crossThreadDeferViolationWarned:
        server.crossThreadDeferViolationWarned = true
        shouldEmit = true
    if shouldEmit:
      server.queueCrossThreadServerError(
        "cross-thread defer rerouted: gateway disabled, direct scheduling denied"
      )

proc crossThreadDeferQueueLimitFor(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultCrossThreadDeferQueueLimit
  let configured = server.options.crossThreadDeferQueueLimit
  if configured <= 0:
    return DefaultCrossThreadDeferQueueLimit
  max(1, configured)

proc releaseCrossThreadWakeRef(server: HttpServer) {.inline.} =
  when compileOption("threads"):
    if server == nil:
      return
    withLock(server.crossThreadDeferLock):
      if server.crossThreadDeferWakeRefs > 0:
        dec server.crossThreadDeferWakeRefs
  else:
    discard server

proc wakeCrossThreadLoop(server: HttpServer, loop: UsLoopPtr) {.inline.} =
  when compileOption("threads"):
    if server == nil or loop == nil:
      return
    try:
      us_wakeup_loop(loop)
    finally:
      server.releaseCrossThreadWakeRef()
  else:
    discard server
    discard loop

proc waitForCrossThreadWakeRefs(server: HttpServer) =
  when compileOption("threads"):
    if server == nil:
      return
    while true:
      var refs = 0
      withLock(server.crossThreadDeferLock):
        refs = server.crossThreadDeferWakeRefs
      if refs <= 0:
        break
      sleep(1)
  else:
    discard server

proc queueCrossThreadServerError(server: HttpServer, message: string) {.inline.} =
  when compileOption("threads"):
    if server == nil or message.len == 0:
      return
    var wakeLoop: UsLoopPtr = nil
    withLock(server.crossThreadDeferLock):
      if not server.crossThreadDeferAccepting:
        return
      let queueLimit = server.crossThreadDeferQueueLimitFor()
      let queuedCount = server.crossThreadDeferQueue.len + server.crossThreadDeferPreQueue.len
      if queueLimit > 0 and queuedCount >= queueLimit:
        return
      let wasEmpty = queuedCount == 0
      server.crossThreadDeferPreQueue.add(proc() =
        server.emitServerError(message)
      )
      if wasEmpty and not server.crossThreadDeferWakePending:
        server.crossThreadDeferWakePending = true
        if server.loop != nil and not server.crossThreadDeferWakeClosing:
          inc server.crossThreadDeferWakeRefs
          wakeLoop = server.loop
    if wakeLoop != nil:
      server.wakeCrossThreadLoop(wakeLoop)
  else:
    discard server
    discard message

proc enqueueCrossThreadDeferred(
  server: HttpServer,
  callback: TimerCallback,
  prePhase: bool
): bool {.inline.} =
  when compileOption("threads"):
    if server == nil or callback == nil:
      return false
    var wakeLoop: UsLoopPtr = nil
    var shouldWarnOverflow = false
    withLock(server.crossThreadDeferLock):
      if not server.crossThreadDeferAccepting:
        inc server.metricsCrossThreadDeferDropped
        return false
      let queueLimit = server.crossThreadDeferQueueLimitFor()
      let queuedCount = server.crossThreadDeferQueue.len + server.crossThreadDeferPreQueue.len
      if queueLimit > 0 and queuedCount >= queueLimit:
        inc server.metricsCrossThreadDeferDropped
        if not server.crossThreadDeferOverflowWarned:
          server.crossThreadDeferOverflowWarned = true
          shouldWarnOverflow = true
        return false
      let wasEmpty = queuedCount == 0
      if prePhase:
        server.crossThreadDeferPreQueue.add(callback)
      else:
        server.crossThreadDeferQueue.add(callback)
      if wasEmpty and not server.crossThreadDeferWakePending:
        server.crossThreadDeferWakePending = true
        if server.loop != nil and not server.crossThreadDeferWakeClosing:
          inc server.crossThreadDeferWakeRefs
          wakeLoop = server.loop
    if shouldWarnOverflow:
      server.queueCrossThreadServerError("cross-thread defer queue limit reached; dropping callback")
    if wakeLoop != nil:
      server.wakeCrossThreadLoop(wakeLoop)
    return true
  else:
    discard server
    discard callback
    false

proc enqueueCrossThreadDeferred(server: HttpServer, callback: TimerCallback): bool {.inline.} =
  enqueueCrossThreadDeferred(server, callback, false)

## Cross-thread deferred enqueue entry point, forward declaration for the threaded implementation
proc tryQueueDeferredFromAnyThread*(server: HttpServer, callback: TimerCallback): bool {.gcsafe.}
## Cross-thread pre-phase enqueue entry point, forward declaration for the threaded implementation
proc tryQueueDeferredPreFromAnyThread*(server: HttpServer, callback: TimerCallback): bool {.gcsafe.}

## Queue a callback to run on the server event loop from any thread, ignoring admission failures
proc queueDeferredFromAnyThread*(server: HttpServer, callback: TimerCallback) {.gcsafe.} =
  ## Minimal cross-thread loop wake helper intended for framework/runtime use.
  ## It avoids thread-side user callback/error-hook invocation.
  discard server.tryQueueDeferredFromAnyThread(callback)

## Queue a callback for the server event loop from any thread and report whether it was admitted
proc tryQueueDeferredFromAnyThread*(server: HttpServer, callback: TimerCallback): bool {.gcsafe.} =
  ## Minimal cross-thread loop wake helper intended for framework/runtime use.
  ## Returns false when the callback cannot be admitted because the server is
  ## shutting down or the cross-thread queue is full.
  when compileOption("threads"):
    if server == nil or callback == nil:
      return false
    return server.enqueueCrossThreadDeferred(callback)
  else:
    if server == nil or callback == nil:
      return false
    server.`defer`(callback)
    return true

## Queue a callback for the next loop pre phase from any thread, ignoring admission failures
proc queueDeferredPreFromAnyThread*(server: HttpServer, callback: TimerCallback) {.gcsafe.} =
  ## Cross-thread helper for work that must run in the next loop pre phase.
  discard server.tryQueueDeferredPreFromAnyThread(callback)

## Queue a callback for the next loop pre phase from any thread and report whether it was admitted
proc tryQueueDeferredPreFromAnyThread*(server: HttpServer, callback: TimerCallback): bool {.gcsafe.} =
  ## Cross-thread helper for work that must run in the next loop pre phase.
  ## Returns false when the callback cannot be admitted because the server is
  ## shutting down or the cross-thread queue is full.
  when compileOption("threads"):
    if server == nil or callback == nil:
      return false
    return server.enqueueCrossThreadDeferred(callback, true)
  else:
    if server == nil or callback == nil:
      return false
    server.deferPre(callback)
    return true

proc flushCrossThreadDeferQueue(server: HttpServer) {.inline.} =
  when compileOption("threads"):
    if server == nil:
      return
    var queuedPre: seq[TimerCallback] = @[]
    var queued: seq[TimerCallback] = @[]
    withLock(server.crossThreadDeferLock):
      if server.crossThreadDeferQueue.len == 0 and server.crossThreadDeferPreQueue.len == 0:
        server.crossThreadDeferWakePending = false
        return
      queuedPre = move(server.crossThreadDeferPreQueue)
      queued = move(server.crossThreadDeferQueue)
      server.crossThreadDeferWakePending = false
    if queuedPre.len > 0:
      for cb in queuedPre:
        if cb != nil:
          server.deferredPreCallbacks.add(cb)
    if queued.len > 0:
      for cb in queued:
        if cb != nil:
          server.deferredCallbacks.add(cb)

## Explicit gateway for scheduling loop-owned work from non-owner threads with violation accounting
proc deferFromAnyThread*(server: HttpServer, callback: TimerCallback) =
  ## Explicit gateway for scheduling loop-owned work from non-owner threads.
  if server == nil or callback == nil:
    return
  when compileOption("threads"):
    if not server.options.crossThreadDeferEnabled:
      if server.isLoopOwnerThread():
        server.`defer`(callback)
      else:
        inc server.metricsCrossThreadDeferViolations
        inc server.metricsCrossThreadDeferRerouted
        server.emitCrossThreadDeferViolationOnce()
        discard server.enqueueCrossThreadDeferred(callback)
      return
    discard server.enqueueCrossThreadDeferred(callback)
  else:
    server.`defer`(callback)

proc scheduleShutdownOnOwnerLoop(server: HttpServer): bool {.inline.} =
  when compileOption("threads"):
    if server == nil:
      return false
    if server.loop != nil and server.loopOwnerBound and not server.isLoopOwnerThread():
      return server.tryQueueDeferredPreFromAnyThread(proc() =
        beginShutdown(server)
      )
    false
  else:
    false

## Schedule a callback to run at the next loop pre-callback boundary on the owning thread
proc deferPre*(server: HttpServer, callback: TimerCallback) =
  ## Schedule lightweight deferred work to run at the next loop pre-callback boundary.
  if server == nil or callback == nil:
    return
  server.assertLoopAffinity("deferPre")
  server.deferredPreCallbacks.add(callback)

proc `defer`*(server: HttpServer, callback: TimerCallback) =
  ## Schedule lightweight deferred work to run at the next loop post-callback boundary.
  if server == nil or callback == nil:
    return
  server.assertLoopAffinity("defer")
  server.deferredCallbacks.add(callback)

proc flushDeferredCallbacks(server: HttpServer, callbacks: var seq[TimerCallback], source: string) {.inline.} =
  if callbacks.len == 0:
    return
  # Move out first so callback execution can safely enqueue more work without
  # aliasing the active iteration buffer under ARC/ORC.
  var queued = move(callbacks)
  for cb in queued:
    if cb != nil:
      try:
        cb()
      except CatchableError as err:
        if server != nil:
          server.emitServerPanic(source, err.msg)
      except Defect as defect:
        if server != nil:
          server.emitServerPanic(source & "_defect", defect.msg)

proc flushDeferredPreCallbacks(server: HttpServer) {.inline.} =
  if server == nil:
    return
  flushDeferredCallbacks(server, server.deferredPreCallbacks, "deferPre")

proc flushDeferredPostCallbacks(server: HttpServer) {.inline.} =
  if server == nil:
    return
  flushDeferredCallbacks(server, server.deferredCallbacks, "defer")

proc enqueueWsDrain(server: HttpServer, ws: WebSocket) {.inline.} =
  if server == nil or ws == nil or server.wsDrainQueued == nil:
    return
  let key = ws.wsKey()
  if key.len == 0 or server.wsDrainQueued.contains(key):
    return
  discard server.wsDrainQueued.incl(key)
  server.wsDrainQueue.add(ws)
  if not server.wsDrainFlushScheduled:
    server.wsDrainFlushScheduled = true
    server.`defer`(proc() =
      if server != nil:
        server.wsDrainFlushScheduled = false
        server.flushQueuedWsDrainHandlers()
    )

proc flushQueuedWsDrainHandlers(server: HttpServer) =
  if server == nil or server.wsDrainQueue.len == 0:
    return
  let queued = server.wsDrainQueue
  server.wsDrainQueue.setLen(0)
  if server.wsDrainQueued != nil:
    server.wsDrainQueued.clear()
  if server.wsDrainHandler == nil:
    return
  for ws in queued:
    if ws == nil or not ws.isOpen or ws.socket == nil:
      continue
    let sockData = socketDataFor(ws.ssl, ws.socket)
    let bufferedBytes = if sockData != nil: sockData.wsPendingBytes else: 0'i64
    try:
      server.wsDrainHandler(ws, bufferedBytes)
    except CatchableError as err:
      server.emitServerPanic("wsDrainHandler", err.msg)
    except Defect as defect:
      server.emitServerPanic("wsDrainHandler_defect", defect.msg)

proc wsTopicIndex(server: HttpServer, topic: string): int {.inline.} =
  if server == nil or topic.len == 0 or server.topicIndex == nil:
    return -1
  var idx64: int64
  if server.topicIndex.tryGet(topic, idx64):
    let idx = int(idx64)
    if idx >= 0 and idx < server.topicNames.len and idx < server.topicSubscribers.len:
      return idx
  -1

proc unsubscribeAllTopics(ws: WebSocket) =
  if ws == nil or ws.subscriptions == nil:
    return
  let topics = ws.subscriptions.itemsSeq()
  for topic in topics:
    discard ws.unsubscribe(topic)
  ws.subscriptions.clear()

## Subscribe an open websocket to a topic for pub/sub fanout, returns false when the socket is unusable
proc subscribe*(ws: WebSocket, topic: string): bool =
  ## Subscribe a websocket to a topic for pub/sub fanout.
  ws.assertWebSocketLoopAffinity("subscribe")
  if ws == nil or ws.server == nil or ws.socket == nil or not ws.isOpen or topic.len == 0:
    return false
  if ws.subscriptions == nil:
    ws.subscriptions = newFastSet()
    discard ws.subscriptions.reserve(8)
  if ws.subscriptions.contains(topic):
    return true

  let server = ws.server
  let idx = server.wsTopicIndex(topic)
  if idx >= 0:
    server.topicSubscribers[idx].add(ws)
  else:
    discard server.topicIndex.put(topic, server.topicNames.len.int64)
    server.topicNames.add(topic)
    server.topicSubscribers.add(@[ws])

  discard ws.subscriptions.incl(topic)
  true

## Remove a websocket subscription from a topic, returns false when it was not active
proc unsubscribe*(ws: WebSocket, topic: string): bool =
  ## Remove a websocket subscription from a topic.
  ws.assertWebSocketLoopAffinity("unsubscribe")
  if ws == nil or ws.server == nil or topic.len == 0:
    return false
  if ws.subscriptions == nil or not ws.subscriptions.contains(topic):
    return false

  let server = ws.server
  let idx = server.wsTopicIndex(topic)
  if idx >= 0:
    var removed = false
    var subs = addr server.topicSubscribers[idx]
    var i = 0
    while i < subs[].len:
      if subs[][i] == ws:
        let last = subs[].len - 1
        if i != last:
          subs[][i] = subs[][last]
        subs[].setLen(last)
        removed = true
        break
      inc i

    if removed and subs[].len == 0:
      let lastTopicIdx = server.topicNames.len - 1
      if idx != lastTopicIdx:
        let movedTopic = server.topicNames[lastTopicIdx]
        server.topicNames[idx] = movedTopic
        server.topicSubscribers[idx] = server.topicSubscribers[lastTopicIdx]
        discard server.topicIndex.put(movedTopic, idx.int64)
      server.topicNames.setLen(lastTopicIdx)
      server.topicSubscribers.setLen(lastTopicIdx)
      discard server.topicIndex.del(topic)

  discard ws.subscriptions.excl(topic)
  true

proc socketDataFor(ssl: cint, s: UsSocketPtr): ptr SocketData {.inline.} =
  if s == nil:
    return nil
  let ext = us_socket_ext(ssl, s)
  if ext == nil:
    return nil
  # The C-owned ext slot carries only a raw pointer; the SocketData object
  # itself lives on the Nim heap and is rooted in HttpServer.socketDataRoots.
  let p = cast[ptr pointer](ext)[]
  if p == nil:
    return nil
  let sd = cast[ptr SocketData](p)
  if sd.magic != SocketDataMagic:
    return nil
  sd

proc emitServerPanic(server: HttpServer, source, message: string) {.inline.} =
  if server == nil:
    return
  let payload =
    if source.len > 0:
      source & ": " & message
    else:
      message
  if server.panicHandler != nil:
    try:
      server.panicHandler(payload)
    except CatchableError:
      discard
    return
  if server.errorHandler != nil:
    try:
      server.errorHandler(payload)
    except CatchableError:
      discard

proc emitServerError(server: HttpServer, message: string) {.inline.} =
  if server != nil and server.errorHandler != nil:
    try:
      server.errorHandler(message)
    except CatchableError as err:
      server.emitServerPanic("errorHandler", err.msg)

proc emitBeforeHeaders(server: HttpServer, req: HttpRequest, res: HttpResponse) {.inline.} =
  if server != nil and server.beforeHeadersHandler != nil:
    try:
      server.beforeHeadersHandler(req, res)
    except CatchableError as err:
      server.emitServerPanic("beforeHeadersHandler", err.msg)

proc emitBeforeWrite(server: HttpServer, bytes: int, isWebSocket: bool) {.inline.} =
  if server != nil and server.beforeWriteHandler != nil and bytes > 0:
    try:
      server.beforeWriteHandler(bytes, isWebSocket)
    except CatchableError as err:
      server.emitServerPanic("beforeWriteHandler", err.msg)

proc emitAfterWrite(server: HttpServer, bytes: int, ok: bool, isWebSocket: bool) {.inline.} =
  if server != nil and server.afterWriteHandler != nil:
    try:
      server.afterWriteHandler(max(0, bytes), ok, isWebSocket)
    except CatchableError as err:
      server.emitServerPanic("afterWriteHandler", err.msg)

proc emitBackpressure(server: HttpServer, bufferedBytes: int64, isWebSocket: bool) {.inline.} =
  if server != nil and server.backpressureHandler != nil:
    try:
      server.backpressureHandler(max(0'i64, bufferedBytes), isWebSocket)
    except CatchableError as err:
      server.emitServerPanic("backpressureHandler", err.msg)

proc tlsFlattenThresholdFor(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultTlsFlattenThreshold
  let configured = server.options.tlsFlattenThreshold
  if configured <= 0:
    return DefaultTlsFlattenThreshold
  configured

proc normalizeCoalesceBytes(value: int, fallback: int): int {.inline.} =
  if value <= 0:
    return max(1024, fallback)
  max(1024, value)

proc normalizeCoalesceResponses(value: int, fallback: int): int {.inline.} =
  if value <= 0:
    return max(1, fallback)
  max(1, value)

proc normalizePayloadThreshold(value: int, fallback: int): int {.inline.} =
  if value <= 0:
    return max(256, fallback)
  max(256, value)

proc normalizePendingGuard(value: int, fallback: int): int {.inline.} =
  if value <= 0:
    return max(1, fallback)
  max(1, value)

## Resolve effective write coalescing byte and response limits for the server mode and current backlog
proc resolveWriteCoalesceLimits*(
  server: HttpServer,
  pendingBytes: int64,
  pendingResponses: int,
  payloadBytes: int,
  inWriteBatch: bool
): tuple[maxBytes: int, maxResponses: int] {.inline.} =
  var mode = wcmAdaptive
  var balancedBytes = MaxCoalescedWriteBytes
  var balancedResponses = MaxCoalescedResponses
  var latencyBytes = DefaultWriteCoalesceLatencyMaxBytes
  var latencyResponses = DefaultWriteCoalesceLatencyMaxResponses
  var throughputBytes = DefaultWriteCoalesceThroughputMaxBytes
  var throughputResponses = DefaultWriteCoalesceThroughputMaxResponses
  var smallPayload = DefaultWriteCoalesceSmallPayloadBytes
  var largePayload = DefaultWriteCoalesceLargePayloadBytes
  var guardPendingBytes = DefaultWriteCoalesceP99GuardPendingBytes
  var guardPendingResponses = DefaultWriteCoalesceP99GuardPendingResponses

  if server != nil:
    mode = server.options.writeCoalesceMode
    balancedBytes = server.options.writeCoalesceMaxBytes
    balancedResponses = server.options.writeCoalesceMaxResponses
    latencyBytes = server.options.writeCoalesceLatencyMaxBytes
    latencyResponses = server.options.writeCoalesceLatencyMaxResponses
    throughputBytes = server.options.writeCoalesceThroughputMaxBytes
    throughputResponses = server.options.writeCoalesceThroughputMaxResponses
    smallPayload = server.options.writeCoalesceSmallPayloadBytes
    largePayload = server.options.writeCoalesceLargePayloadBytes
    guardPendingBytes = server.options.writeCoalesceP99GuardPendingBytes
    guardPendingResponses = server.options.writeCoalesceP99GuardPendingResponses

  let safeBalancedBytes = normalizeCoalesceBytes(balancedBytes, MaxCoalescedWriteBytes)
  let safeBalancedResponses = normalizeCoalesceResponses(balancedResponses, MaxCoalescedResponses)
  let safeLatencyBytes = normalizeCoalesceBytes(latencyBytes, DefaultWriteCoalesceLatencyMaxBytes)
  let safeLatencyResponses = normalizeCoalesceResponses(latencyResponses, DefaultWriteCoalesceLatencyMaxResponses)
  let safeThroughputBytes = normalizeCoalesceBytes(throughputBytes, DefaultWriteCoalesceThroughputMaxBytes)
  let safeThroughputResponses = normalizeCoalesceResponses(throughputResponses, DefaultWriteCoalesceThroughputMaxResponses)
  let safeSmallPayload = normalizePayloadThreshold(smallPayload, DefaultWriteCoalesceSmallPayloadBytes)
  let safeLargePayload = max(
    safeSmallPayload,
    normalizePayloadThreshold(largePayload, DefaultWriteCoalesceLargePayloadBytes)
  )
  let safeGuardPendingBytes = normalizeCoalesceBytes(
    guardPendingBytes,
    DefaultWriteCoalesceP99GuardPendingBytes
  )
  let safeGuardPendingResponses = normalizePendingGuard(
    guardPendingResponses,
    DefaultWriteCoalesceP99GuardPendingResponses
  )

  if mode == wcmAdaptive:
    let clampedPayload = max(0, payloadBytes)
    if clampedPayload <= safeSmallPayload:
      mode = wcmLatency
    elif clampedPayload >= safeLargePayload:
      mode = wcmThroughput
    elif inWriteBatch and max(0, pendingResponses) >= max(3, safeBalancedResponses div 2):
      mode = wcmThroughput
    else:
      mode = wcmBalanced

  case mode
  of wcmLatency:
    result = (safeLatencyBytes, safeLatencyResponses)
  of wcmThroughput:
    result = (safeThroughputBytes, safeThroughputResponses)
  of wcmBalanced, wcmAdaptive:
    result = (safeBalancedBytes, safeBalancedResponses)

  # Low-backlog guard keeps coalescing conservative outside explicit cork batches.
  if not inWriteBatch and
     pendingBytes >= 0 and pendingBytes <= int64(safeGuardPendingBytes) and
     max(0, pendingResponses) <= safeGuardPendingResponses:
    result.maxBytes = min(result.maxBytes, safeLatencyBytes)
    result.maxResponses = min(result.maxResponses, safeLatencyResponses)

proc dispatchLoopBudgetRequestsFor(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultLoopDispatchBudgetRequests
  let configured = server.options.loopDispatchBudgetRequests
  if configured <= 0:
    return DefaultLoopDispatchBudgetRequests
  configured

proc dispatchLoopBudgetBytesFor(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultLoopDispatchBudgetBytes
  let configured = server.options.loopDispatchBudgetBytes
  if configured <= 0:
    return DefaultLoopDispatchBudgetBytes
  configured

proc writeBudgetIterationsFor(sockData: ptr SocketData): int {.inline.} =
  if sockData == nil or sockData.server == nil:
    return DefaultWriteBudgetIterationsPerFlush
  let configured = sockData.server.options.writeBudgetIterationsPerFlush
  if configured <= 0:
    return DefaultWriteBudgetIterationsPerFlush
  configured

proc writeBudgetBytesFor(sockData: ptr SocketData): int64 {.inline.} =
  if sockData == nil or sockData.server == nil:
    return int64(DefaultWriteBudgetBytesPerFlush)
  let configured = sockData.server.options.writeBudgetBytesPerFlush
  if configured <= 0:
    return int64(DefaultWriteBudgetBytesPerFlush)
  int64(configured)

proc writeLoopBudgetBytesFor(server: HttpServer): int64 {.inline.} =
  if server == nil:
    return int64(DefaultLoopWriteBudgetBytes)
  let configured = server.options.loopWriteBudgetBytes
  if configured <= 0:
    return int64(DefaultLoopWriteBudgetBytes)
  int64(configured)

proc resetLoopFairnessBudgets(server: HttpServer) {.inline.} =
  if server == nil:
    return
  server.loopDispatchRequestsRemaining = server.dispatchLoopBudgetRequestsFor()
  server.loopDispatchBytesRemaining = server.dispatchLoopBudgetBytesFor()
  server.loopWriteBytesRemaining = server.writeLoopBudgetBytesFor()

proc dispatchLoopBudgetExhausted(server: HttpServer): bool {.inline.} =
  server != nil and (
    server.loopDispatchRequestsRemaining <= 0 or
    server.loopDispatchBytesRemaining <= 0
  )

proc consumeLoopDispatchBudget(server: HttpServer, requestCount: int, bytes: int) {.inline.} =
  if server == nil:
    return
  if requestCount > 0:
    server.loopDispatchRequestsRemaining -= requestCount
  if bytes > 0:
    server.loopDispatchBytesRemaining -= bytes

proc writeLoopBudgetExhausted(server: HttpServer): bool {.inline.} =
  server != nil and server.loopWriteBytesRemaining <= 0

proc consumeLoopWriteBudget(server: HttpServer, bytes: int64) {.inline.} =
  if server == nil or bytes <= 0:
    return
  server.loopWriteBytesRemaining -= bytes

proc writeDirect(server: HttpServer, ssl: cint, s: UsSocketPtr, header, body: string): int {.inline.}

proc recordSocketCloseOutcome(server: HttpServer, reason: string, ok: bool) {.inline.} =
  if server == nil:
    return
  inc server.metricsSocketCloseAttempts
  let statusKey = (if ok: "ok:" else: "fail:") & reason
  if server.closeOutcomeCounts != nil:
    let current = server.closeOutcomeCounts.getOrDefault(statusKey, 0'i64)
    discard server.closeOutcomeCounts.put(statusKey, current + 1)
  if ok:
    return
  inc server.metricsSocketCloseFailures
  let warnKey = "warn:" & reason
  var shouldWarn = true
  if server.closeOutcomeWarnings != nil:
    if server.closeOutcomeWarnings.contains(warnKey):
      shouldWarn = false
    else:
      discard server.closeOutcomeWarnings.incl(warnKey)
  if shouldWarn:
    server.emitServerError("socket close returned nil for path: " & reason)

## Force deferred header parsing to populate the request header map, forward declaration for early use
proc ensureHeadersPopulated*(req: HttpRequest) {.inline.}

when defined(nimUwebsocketsTest):
  type TestWritevCall* = tuple[iovcnt: int, totalLength: int]

  var testInjectedWriteResults*: seq[int] = @[]
  var testInjectedWriteHead*: int = 0
  var testInjectCloseSocketFailure*: bool = false
  var testInjectTlsMergeAllocFailure*: bool = false
  var testMockWritevEnabled*: bool = false
  var testWritevIovMax*: int = 0
  var testWritevCalls*: seq[TestWritevCall] = @[]

  ## Reset all socket write fault-injection test state to defaults
  proc resetSocketFaultInjectionForTest*() =
    testInjectedWriteResults.setLen(0)
    testInjectedWriteHead = 0
    testInjectCloseSocketFailure = false
    testInjectTlsMergeAllocFailure = false
    testMockWritevEnabled = false
    testWritevIovMax = 0
    testWritevCalls.setLen(0)

  ## Arm a queue of injected socket write results for upcoming low-level write attempts
  proc setInjectedWriteResultsForTest*(values: openArray[int]) =
    testInjectedWriteResults = @[]
    testInjectedWriteResults.setLen(values.len)
    for i in 0 ..< values.len:
      testInjectedWriteResults[i] = values[i]
    testInjectedWriteHead = 0

  ## Enable or disable simulated socket close failures for fault-injection tests
  proc setCloseSocketFailureForTest*(enabled: bool) =
    testInjectCloseSocketFailure = enabled

  ## Enable or disable simulated TLS merge allocation failures for fault-injection tests
  proc setTlsMergeAllocFailureForTest*(enabled: bool) =
    testInjectTlsMergeAllocFailure = enabled

  ## Enable or disable the mocked writev path used to record scatter-gather write calls
  proc setMockWritevForTest*(enabled: bool) =
    testMockWritevEnabled = enabled
    testWritevCalls.setLen(0)

  ## Override the maximum iovec count accepted by the mocked writev path
  proc setWritevIovMaxForTest*(value: int) =
    testWritevIovMax = value

  ## Return the recorded scatter-gather writev calls captured by the writev mock
  proc writevCallsForTest*(): seq[TestWritevCall] =
    testWritevCalls

  proc popInjectedWriteResultForTest(value: var int): bool {.inline.} =
    if testInjectedWriteHead >= testInjectedWriteResults.len:
      return false
    value = testInjectedWriteResults[testInjectedWriteHead]
    inc testInjectedWriteHead
    if testInjectedWriteHead >= testInjectedWriteResults.len:
      testInjectedWriteResults.setLen(0)
      testInjectedWriteHead = 0
    true

proc closeSocketTracked(
  server: HttpServer,
  ssl: cint,
  s: UsSocketPtr,
  reason: string
): bool {.inline.} =
  if s == nil:
    return false
  when defined(nimUwebsocketsTest):
    if testInjectCloseSocketFailure:
      recordSocketCloseOutcome(server, reason, false)
      return false
  let closed = us_socket_close(ssl, s, 0, nil) != nil
  recordSocketCloseOutcome(server, reason, closed)
  closed

proc clampedWriteLen(length: int): int {.inline.} =
  if length <= 0:
    return 0
  min(length, int(high(cint)))

when not defined(windows):
  var cachedWritevIovMax {.threadvar.}: int

  proc writevIovMax(): int {.inline.} =
    when defined(nimUwebsocketsTest):
      if testWritevIovMax > 0:
        return max(1, testWritevIovMax)
    if cachedWritevIovMax > 0:
      return cachedWritevIovMax
    var limit = DefaultWritevIovMax
    when declared(SC_IOV_MAX) and declared(sysconf):
      let observed = sysconf(SC_IOV_MAX)
      if observed > 0:
        if observed > clong(DefaultWritevIovMax):
          limit = DefaultWritevIovMax
        else:
          limit = int(observed)
      else:
        limit = MinimumWritevIovMax
    cachedWritevIovMax = max(1, limit)
    cachedWritevIovMax

  proc pointerOffset(base: pointer, offset: int): pointer {.inline.} =
    if offset <= 0:
      return base
    cast[pointer](cast[uint](base) + uint(offset))

  proc iovLenToInt(length: csize_t): int {.inline.} =
    if length > csize_t(high(int)):
      high(int)
    else:
      int(length)

  template iovItem(iov: ptr IOVec, index: int): untyped =
    cast[ptr UncheckedArray[IOVec]](iov)[index]

  proc advanceIovCursor(iov: ptr IOVec, iovcnt: int, index: var int, offset: var int, bytes: int) {.inline.} =
    var remaining = bytes
    while remaining > 0 and index < iovcnt:
      let currentLen = iovLenToInt(iovItem(iov, index).iov_len)
      if currentLen <= offset:
        inc index
        offset = 0
        continue
      let available = currentLen - offset
      if remaining < available:
        offset += remaining
        return
      remaining -= available
      inc index
      offset = 0

  proc callSocketWritevN(
    ssl: cint,
    s: UsSocketPtr,
    iov: ptr IOVec,
    iovcnt: int,
    totalLength: int
  ): int {.inline.} =
    when defined(nimUwebsocketsTest):
      if testMockWritevEnabled:
        testWritevCalls.add((iovcnt: iovcnt, totalLength: totalLength))
        var injected = 0
        if popInjectedWriteResultForTest(injected):
          return injected
        return totalLength
    if iovcnt <= 0 or totalLength <= 0:
      return 0
    us_socket_writev_n(ssl, s, iov, iovcnt.cint, totalLength.cint).int

proc writeSocketChecked(ssl: cint, s: UsSocketPtr, payload: cstring, length: int): int {.inline.} =
  when defined(nimUwebsocketsTest):
    var injected = 0
    if popInjectedWriteResultForTest(injected):
      return injected
  if s == nil:
    return 0
  let len = clampedWriteLen(length)
  if len <= 0:
    return 0
  int(us_socket_write(ssl, s, payload, len.cint, 0))

proc writeSocketChecked2(
  ssl: cint,
  s: UsSocketPtr,
  first: cstring,
  firstLen: int,
  second: cstring,
  secondLen: int
): int {.inline.} =
  when defined(nimUwebsocketsTest):
    var injected = 0
    if popInjectedWriteResultForTest(injected):
      return injected
  if s == nil:
    return 0
  let len1 = clampedWriteLen(firstLen)
  let len2 = clampedWriteLen(secondLen)
  if len1 <= 0 and len2 <= 0:
    return 0
  if len1 <= 0:
    return writeSocketChecked(ssl, s, second, len2)
  if len2 <= 0:
    return writeSocketChecked(ssl, s, first, len1)
  int(us_socket_write2(ssl, s, first, len1.cint, second, len2.cint))

when not defined(windows):
  proc writeSocketCheckedN(
    ssl: cint,
    s: UsSocketPtr,
    iov: ptr IOVec,
    iovcnt: int,
    totalLength: int
  ): int {.inline.} =
    if s == nil or iov == nil or iovcnt <= 0 or totalLength <= 0:
      return 0
    let maxIovs = writevIovMax()
    let maxBatchBytes = int(high(cint))
    if iovcnt <= maxIovs and totalLength <= maxBatchBytes:
      return callSocketWritevN(ssl, s, iov, iovcnt, totalLength)

    var totalWritten = 0
    var remainingTotal = totalLength
    var index = 0
    var offset = 0
    var batch = newSeqOfCap[IOVec](min(maxIovs, iovcnt))

    while remainingTotal > 0 and index < iovcnt:
      batch.setLen(0)
      var batchLen = 0
      var scanIndex = index
      var scanOffset = offset

      while scanIndex < iovcnt and batch.len < maxIovs and batchLen < maxBatchBytes and remainingTotal > batchLen:
        let entry = iovItem(iov, scanIndex)
        let entryLen = iovLenToInt(entry.iov_len)
        if entryLen <= scanOffset:
          inc scanIndex
          scanOffset = 0
          continue
        if entry.iov_base == nil:
          return totalWritten

        let available = entryLen - scanOffset
        let batchCapacity = min(maxBatchBytes - batchLen, remainingTotal - batchLen)
        if batchCapacity <= 0:
          break
        let take = min(available, batchCapacity)
        if take <= 0:
          break

        batch.add(IOVec(
          iov_base: pointerOffset(entry.iov_base, scanOffset),
          iov_len: csize_t(take)
        ))
        batchLen += take

        if take < available:
          scanOffset += take
          break
        inc scanIndex
        scanOffset = 0

      if batchLen <= 0 or batch.len <= 0:
        break

      let written = callSocketWritevN(ssl, s, addr batch[0], batch.len, batchLen)
      if written <= 0:
        if totalWritten > 0:
          return totalWritten
        return written

      let consumed = min(written, batchLen)
      totalWritten += consumed
      remainingTotal -= consumed
      advanceIovCursor(iov, iovcnt, index, offset, consumed)
      if consumed < batchLen:
        return totalWritten

    totalWritten

proc flattenFragments(fragments: openArray[string], totalBodyBytes: int): string {.inline.} =
  if totalBodyBytes <= 0:
    return ""
  result = newStringOfCap(totalBodyBytes)
  for fragment in fragments:
    if fragment.len > 0:
      result.add(fragment)

const SendBufferFlushThreshold = 65536

proc flushSendBuffer(sockData: ptr SocketData, ssl: cint, s: UsSocketPtr) {.inline.} =
  if sockData == nil or s == nil or sockData.sendBuffer.len == 0:
    return
  let toWrite = sockData.sendBuffer.len - sockData.sendBufferPos
  if toWrite <= 0:
    sockData.sendBuffer.setLen(0)
    sockData.sendBufferPos = 0
    return
  let written = writeSocketChecked(
    ssl, s,
    cast[cstring](unsafeAddr sockData.sendBuffer[sockData.sendBufferPos]),
    toWrite
  )
  if written >= toWrite:
    sockData.sendBuffer.setLen(0)
    sockData.sendBufferPos = 0
  elif written > 0:
    sockData.sendBufferPos += written
  # written <= 0: keep buffer intact, will retry on next writable event

proc sendBufferRemaining(sockData: ptr SocketData): int64 {.inline.} =
  if sockData == nil or sockData.sendBuffer.len <= sockData.sendBufferPos:
    return 0'i64
  int64(sockData.sendBuffer.len - sockData.sendBufferPos)

proc sendBufferCapacityRemaining(sockData: ptr SocketData): int {.inline.} =
  if sockData == nil:
    return 0
  let maxPending = sockData.maxPendingBytesFor()
  if maxPending <= 0:
    return high(int)
  let remaining = maxPending - sockData.sendBufferRemaining()
  if remaining <= 0:
    return 0
  if remaining > int64(high(int)):
    high(int)
  else:
    int(remaining)

proc bufferSocketWrite(sockData: ptr SocketData, ssl: cint, s: UsSocketPtr,
                       payload: cstring, length: int): int {.inline.} =
  if sockData == nil or payload == nil or length <= 0:
    return 0
  if sockData.sendBufferRemaining() > 0:
    flushSendBuffer(sockData, ssl, s)
  let accepted = min(length, sockData.sendBufferCapacityRemaining())
  if accepted <= 0:
    if sockData.server != nil:
      sockData.server.emitBackpressure(sockData.sendBufferRemaining() + int64(length), false)
    return 0
  let oldLen = sockData.sendBuffer.len
  sockData.sendBuffer.setLen(oldLen + accepted)
  copyMem(addr sockData.sendBuffer[oldLen], payload, accepted)
  if accepted < length and sockData.server != nil:
    sockData.server.emitBackpressure(sockData.sendBufferRemaining() + int64(length - accepted), false)
  if sockData.sendBuffer.len >= SendBufferFlushThreshold:
    flushSendBuffer(sockData, ssl, s)
  accepted

proc bufferSocketWrite2(sockData: ptr SocketData, ssl: cint, s: UsSocketPtr,
                        first: cstring, firstLen: int,
                        second: cstring, secondLen: int): int {.inline.} =
  if sockData == nil:
    return 0
  if firstLen <= 0 and secondLen <= 0:
    return 0
  if firstLen <= 0:
    return bufferSocketWrite(sockData, ssl, s, second, secondLen)
  if secondLen <= 0:
    return bufferSocketWrite(sockData, ssl, s, first, firstLen)
  let firstWritten = bufferSocketWrite(sockData, ssl, s, first, firstLen)
  if firstWritten < firstLen:
    return firstWritten
  firstWritten + bufferSocketWrite(sockData, ssl, s, second, secondLen)

proc writeFallbackPayloadAndMaybeClose(
  server: HttpServer,
  ssl: cint,
  s: UsSocketPtr,
  payload: string,
  closeReason: string
): int {.inline.} =
  if s == nil or payload.len == 0:
    return 0
  let written = writeSocketChecked(ssl, s, payload.cstring, payload.len)
  if written < payload.len:
    discard closeSocketTracked(server, ssl, s, closeReason)
  written

proc writeFallbackDirectAndMaybeClose(
  server: HttpServer,
  ssl: cint,
  s: UsSocketPtr,
  header: string,
  body: string,
  closeReason: string
): int {.inline.} =
  let written = writeDirect(server, ssl, s, header, body)
  let total = header.len + body.len
  if written < total:
    discard closeSocketTracked(server, ssl, s, closeReason)
  written

proc writeDirect(server: HttpServer, ssl: cint, s: UsSocketPtr, header, body: string): int {.inline.} =
  if s == nil:
    return 0
  if body.len > 0 and ssl == 0:
    return writeSocketChecked2(ssl, s, header.cstring, header.len, body.cstring, body.len)
  elif body.len > 0:
    when defined(nimUwebsocketsTest):
      if testInjectTlsMergeAllocFailure:
        let first = writeSocketChecked(ssl, s, header.cstring, header.len)
        if first < header.len:
          return first
        let second = writeSocketChecked(ssl, s, body.cstring, body.len)
        if second <= 0:
          return first
        return first + second
    let totalLen = header.len + body.len
    if totalLen <= server.tlsFlattenThresholdFor():
      if totalLen <= 4096:
        var stackBuf: array[4096, byte]
        if header.len > 0:
          copyMem(addr stackBuf[0], unsafeAddr header[0], header.len)
        if body.len > 0:
          copyMem(addr stackBuf[header.len], unsafeAddr body[0], body.len)
        return writeSocketChecked(ssl, s, cast[cstring](addr stackBuf[0]), totalLen)
      try:
        var merged = newStringOfCap(totalLen)
        merged.add(header)
        merged.add(body)
        return writeSocketChecked(ssl, s, merged.cstring, merged.len)
      except CatchableError:
        discard
    let first = writeSocketChecked(ssl, s, header.cstring, header.len)
    if first < header.len:
      return first
    let second = writeSocketChecked(ssl, s, body.cstring, body.len)
    if second <= 0:
      return first
    first + second
  else:
    return writeSocketChecked(ssl, s, header.cstring, header.len)

proc writeDirectFragments(
  server: HttpServer,
  ssl: cint,
  s: UsSocketPtr,
  header: string,
  fragments: openArray[string],
  totalBodyBytes: int
): int {.inline.} =
  if s == nil:
    return 0
  when not defined(windows):
    if ssl == 0:
      const StackIovLimit = 17
      let maxIovs = fragments.len + 1
      if maxIovs <= StackIovLimit:
        var stackIov: array[StackIovLimit, IOVec]
        var cnt = 0
        if header.len > 0:
          stackIov[cnt] = IOVec(iov_base: cast[pointer](unsafeAddr header[0]), iov_len: csize_t(header.len))
          inc cnt
        for fragment in fragments:
          if fragment.len > 0:
            stackIov[cnt] = IOVec(iov_base: cast[pointer](unsafeAddr fragment[0]), iov_len: csize_t(fragment.len))
            inc cnt
        if cnt > 0:
          return writeSocketCheckedN(ssl, s, addr stackIov[0], cnt, header.len + totalBodyBytes)
      else:
        var iovecs = newSeqOfCap[IOVec](maxIovs)
        if header.len > 0:
          iovecs.add(IOVec(iov_base: cast[pointer](unsafeAddr header[0]), iov_len: csize_t(header.len)))
        for fragment in fragments:
          if fragment.len > 0:
            iovecs.add(IOVec(iov_base: cast[pointer](unsafeAddr fragment[0]), iov_len: csize_t(fragment.len)))
        if iovecs.len > 0:
          return writeSocketCheckedN(ssl, s, addr iovecs[0], iovecs.len, header.len + totalBodyBytes)
  let mergedBody = flattenFragments(fragments, totalBodyBytes)
  writeDirect(server, ssl, s, header, mergedBody)

proc writeDirect(ssl: cint, s: UsSocketPtr, header, body: string): int {.inline, used.} =
  writeDirect(nil, ssl, s, header, body)

proc advanceWriteProgress(resp: var QueuedResponse, written: int) {.inline.} =
  var remaining = written
  if remaining <= 0:
    return

  let headerRemaining = resp.header.len - resp.headerPos
  if headerRemaining > 0:
    if remaining < headerRemaining:
      resp.headerPos += remaining
      return
    resp.headerPos = resp.header.len
    remaining -= headerRemaining

  if remaining > 0 and resp.bodyPos < resp.body.len:
    let bodyRemaining = resp.body.len - resp.bodyPos
    if remaining < bodyRemaining:
      resp.bodyPos += remaining
    else:
      resp.bodyPos = resp.body.len

proc updateTryEndProgress(resp: var QueuedResponse, written: int64) {.inline.}

proc payloadBytesFromFixedWrite(headerRemainingBeforeWrite, written: int): int {.inline.} =
  if written <= 0:
    return 0
  if headerRemainingBeforeWrite <= 0:
    return written
  if written <= headerRemainingBeforeWrite:
    return 0
  written - headerRemainingBeforeWrite

proc applyFixedWriteProgress(
  resp: var QueuedResponse,
  written: int,
  headerRemainingBeforeWrite: int
) {.inline.} =
  if written <= 0:
    return
  let payloadWritten = payloadBytesFromFixedWrite(headerRemainingBeforeWrite, written)
  if payloadWritten > 0:
    resp.updateTryEndProgress(int64(payloadWritten))
  resp.advanceWriteProgress(written)

proc queuedRemainingBytes(resp: QueuedResponse): int64 {.inline.} =
  var remaining = 0'i64
  if resp.headerPos < resp.header.len:
    remaining += int64(resp.header.len - resp.headerPos)
  if resp.bodyPos < resp.body.len:
    remaining += int64(resp.body.len - resp.bodyPos)
  if resp.streamChunkHead < resp.streamChunks.len:
    var i = resp.streamChunkHead
    while i < resp.streamChunks.len:
      if i == resp.streamChunkHead:
        let chunkRemaining = resp.streamChunks[i].len - resp.streamChunkPos
        if chunkRemaining > 0:
          remaining += int64(chunkRemaining)
      else:
        remaining += int64(resp.streamChunks[i].len)
      inc i
  if resp.isFileBody and resp.fileRemaining > 0:
    remaining += int64(resp.fileRemaining)
  remaining

proc queuedRemainingBytesFast(resp: QueuedResponse): int64 {.inline.} =
  ## Fast path for fixed (header+body) responses.
  if not resp.isFileBody and not resp.isStreamBody and resp.streamChunkHead >= resp.streamChunks.len:
    var remaining = 0'i64
    if resp.headerPos < resp.header.len:
      remaining += int64(resp.header.len - resp.headerPos)
    if resp.bodyPos < resp.body.len:
      remaining += int64(resp.body.len - resp.bodyPos)
    return remaining
  queuedRemainingBytes(resp)

proc isFullyWritten(resp: QueuedResponse): bool {.inline.} =
  let stringDone = resp.headerPos >= resp.header.len and resp.bodyPos >= resp.body.len
  if not stringDone:
    return false
  if resp.streamChunkHead < resp.streamChunks.len:
    return false
  if resp.isStreamBody and resp.streamOpen:
    return false
  if resp.isFileBody:
    return resp.fileRemaining <= 0
  true

proc canCoalesceQueuedResponse(resp: QueuedResponse): bool {.inline.} =
  not resp.isFileBody and
  not resp.isStreamBody and
  resp.headerPos == 0 and
  resp.bodyPos == 0

proc maxPendingBytesFor(sockData: ptr SocketData): int64 {.inline.} =
  if sockData == nil or sockData.server == nil:
    return int64(DefaultMaxPendingBytesPerSocket)
  let configured = sockData.server.options.maxPendingBytesPerSocket
  if configured <= 0:
    return int64(DefaultMaxPendingBytesPerSocket)
  int64(configured)

proc shouldAutoFlush(sockData: ptr SocketData): bool {.inline.} =
  if sockData == nil:
    return true
  if sockData.writeBatchDepth > 0:
    return false
  if sockData.server != nil and sockData.server.loopWriteBatchDepth > 0:
    return false
  true

proc registerPendingFlush(sockData: ptr SocketData, s: UsSocketPtr) {.inline.} =
  if sockData == nil or sockData.server == nil or s == nil or
     sockData.hasFlag(SDF_PENDING_LOOP_FLUSH):
    return
  let server = sockData.server
  if server.loopWriteBatchDepth <= 0:
    return
  let key = socketKey(s)
  if server.socketKeyWasClosed(key):
    return
  sockData.setFlag(SDF_PENDING_LOOP_FLUSH)
  server.pendingFlushSockets.add((
    sockData: sockData,
    socket: s,
    socketKey: key,
    generation: sockData.generation,
    ssl: server.ssl.toInt
  ))

proc invalidatePendingFlushForSocket(server: HttpServer, s: UsSocketPtr, key: uint64) {.inline.} =
  if server == nil or server.pendingFlushSockets.len == 0:
    return
  for i in 0..<server.pendingFlushSockets.len:
    if server.pendingFlushSockets[i].socket == s or
       (key != 0'u64 and server.pendingFlushSockets[i].socketKey == key):
      server.pendingFlushSockets[i].sockData = nil
      server.pendingFlushSockets[i].socket = nil
      server.pendingFlushSockets[i].socketKey = 0'u64
      server.pendingFlushSockets[i].generation = 0'u64

proc flushAllPendingSockets(server: HttpServer) =
  if server == nil or server.pendingFlushSockets.len == 0:
    return
  let entries = server.pendingFlushSockets
  server.pendingFlushSockets.setLen(0)
  for entry in entries:
    if entry.socket == nil or entry.socketKey == 0'u64:
      continue
    if server.socketKeyWasClosed(entry.socketKey):
      continue
    if us_socket_is_closed(entry.ssl, entry.socket) != 0 or us_socket_is_shut_down(entry.ssl, entry.socket) != 0:
      continue
    let sd = socketDataFor(entry.ssl, entry.socket)
    if sd == nil or sd != entry.sockData or sd.magic != SocketDataMagic or
       sd.generation != entry.generation:
      continue
    sd.clearFlag(SDF_PENDING_LOOP_FLUSH)
    let needsCork = sd.pendingActiveCount > 1 or sd.sendBuffer.len > 0
    if needsCork:
      us_socket_cork(entry.ssl, entry.socket)
    if sd.hasFlag(SDF_IS_WEBSOCKET):
      sd.flushWsQueuedFrames(entry.socket)
    else:
      flushSendBuffer(sd, entry.ssl, entry.socket)
      flushPendingResponses(sd, entry.socket)
      flushSendBuffer(sd, entry.ssl, entry.socket)
    if needsCork:
      us_socket_uncork(entry.ssl, entry.socket)
    closeSocketIfPending(sd, entry.socket)

## Flush all pending socket writes registered for the server now
proc flushPendingWrites*(server: HttpServer) {.inline.} =
  if server == nil:
    return
  flushAllPendingSockets(server)

proc spillPressureRejectThresholdFor(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultSpillPressureRejectThreshold
  max(1, server.options.spillPressureRejectThreshold)

proc spillPressureRecoverThresholdFor(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultSpillPressureRecoverThreshold
  let rejectThreshold = spillPressureRejectThresholdFor(server)
  max(0, min(rejectThreshold, server.options.spillPressureRecoverThreshold))

proc noteSpillPressureDrop(server: HttpServer) {.inline.} =
  if server == nil:
    return
  let rejectThreshold = spillPressureRejectThresholdFor(server)
  let maxScore = max(rejectThreshold * 4, rejectThreshold + 4)
  if server.spillPressureScore < maxScore:
    inc server.spillPressureScore
  if server.spillPressureScore >= rejectThreshold:
    server.spillPressureRejecting = true

proc decaySpillPressure(server: HttpServer) {.inline.} =
  if server == nil:
    return
  if server.spillPressureScore > 0:
    dec server.spillPressureScore
  let recoverThreshold = spillPressureRecoverThresholdFor(server)
  if server.spillPressureScore <= recoverThreshold:
    server.spillPressureRejecting = false

proc overloadStepFor(limit, percent: int): int {.inline.} =
  if limit <= 0 or percent <= 0:
    return 0
  max(1, (limit * percent) div 100)

proc overloadConfiguredBacklogLimit(server: HttpServer): int {.inline.} =
  if server == nil:
    return 0
  max(0, server.options.overloadMaxLoopBacklogBytes)

proc overloadConfiguredPendingLimit(server: HttpServer): int {.inline.} =
  if server == nil:
    return 0
  max(0, server.options.overloadMaxPendingResponses)

proc overloadAdaptiveBacklogBounds(server: HttpServer, configuredLimit: int): tuple[minLimit: int, maxLimit: int] {.inline.} =
  if server == nil or configuredLimit <= 0:
    return (0, 0)
  var maxLimit = configuredLimit
  let configuredMax = max(0, server.options.overloadAdaptiveMaxBacklogBytes)
  if configuredMax > 0:
    maxLimit = min(maxLimit, configuredMax)
  var minLimit = max(1, server.options.overloadAdaptiveMinBacklogBytes)
  minLimit = min(minLimit, maxLimit)
  (minLimit, maxLimit)

proc overloadAdaptivePendingBounds(server: HttpServer, configuredLimit: int): tuple[minLimit: int, maxLimit: int] {.inline.} =
  if server == nil or configuredLimit <= 0:
    return (0, 0)
  var maxLimit = configuredLimit
  let configuredMax = max(0, server.options.overloadAdaptiveMaxPendingResponses)
  if configuredMax > 0:
    maxLimit = min(maxLimit, configuredMax)
  var minLimit = max(1, server.options.overloadAdaptiveMinPendingResponses)
  minLimit = min(minLimit, maxLimit)
  (minLimit, maxLimit)

proc overloadAdaptiveEnabledFor(server: HttpServer): bool {.inline.} =
  if server == nil or not server.options.overloadAdaptiveEnabled:
    return false
  overloadConfiguredBacklogLimit(server) > 0 or overloadConfiguredPendingLimit(server) > 0

proc refreshOverloadAdaptiveLimits(server: HttpServer) {.inline.} =
  if server == nil:
    return
  let configuredBacklog = overloadConfiguredBacklogLimit(server)
  let configuredPending = overloadConfiguredPendingLimit(server)

  if configuredBacklog > 0:
    let bounds = overloadAdaptiveBacklogBounds(server, configuredBacklog)
    if server.overloadAdaptiveBacklogLimit <= 0:
      server.overloadAdaptiveBacklogLimit = bounds.maxLimit
    else:
      server.overloadAdaptiveBacklogLimit = min(bounds.maxLimit, max(bounds.minLimit, server.overloadAdaptiveBacklogLimit))
  else:
    server.overloadAdaptiveBacklogLimit = 0

  if configuredPending > 0:
    let bounds = overloadAdaptivePendingBounds(server, configuredPending)
    if server.overloadAdaptivePendingLimit <= 0:
      server.overloadAdaptivePendingLimit = bounds.maxLimit
    else:
      server.overloadAdaptivePendingLimit = min(bounds.maxLimit, max(bounds.minLimit, server.overloadAdaptivePendingLimit))
  else:
    server.overloadAdaptivePendingLimit = 0

proc overloadLimitSnapshot(server: HttpServer): tuple[backlogLimit: int, pendingLimit: int] {.inline.} =
  result.backlogLimit = overloadConfiguredBacklogLimit(server)
  result.pendingLimit = overloadConfiguredPendingLimit(server)
  if not overloadAdaptiveEnabledFor(server):
    return
  refreshOverloadAdaptiveLimits(server)
  if result.backlogLimit > 0:
    result.backlogLimit = server.overloadAdaptiveBacklogLimit
  if result.pendingLimit > 0:
    result.pendingLimit = server.overloadAdaptivePendingLimit

proc updateOverloadAdaptiveFeedback(
  server: HttpServer,
  overloaded: bool,
  pendingBytes: int64,
  pendingResponses: int,
  spillPressure: bool = false
) {.inline.} =
  if not overloadAdaptiveEnabledFor(server):
    return
  refreshOverloadAdaptiveLimits(server)

  let cooldown = max(1, server.options.overloadAdaptiveCooldownRequests)
  let tightenStepPercent = max(1, min(90, server.options.overloadAdaptiveTightenStepPercent))
  let relaxStepPercent = max(1, min(90, server.options.overloadAdaptiveRelaxStepPercent))
  let configuredBacklog = overloadConfiguredBacklogLimit(server)
  let configuredPending = overloadConfiguredPendingLimit(server)

  if overloaded or spillPressure:
    inc server.overloadAdaptiveRejectStreak
    server.overloadAdaptiveAcceptStreak = 0
    if server.overloadAdaptiveRejectStreak < cooldown:
      return
    server.overloadAdaptiveRejectStreak = 0

    if configuredBacklog > 0:
      let bounds = overloadAdaptiveBacklogBounds(server, configuredBacklog)
      let step = overloadStepFor(server.overloadAdaptiveBacklogLimit, tightenStepPercent)
      server.overloadAdaptiveBacklogLimit = max(bounds.minLimit, server.overloadAdaptiveBacklogLimit - step)
    if configuredPending > 0:
      let bounds = overloadAdaptivePendingBounds(server, configuredPending)
      let step = overloadStepFor(server.overloadAdaptivePendingLimit, tightenStepPercent)
      server.overloadAdaptivePendingLimit = max(bounds.minLimit, server.overloadAdaptivePendingLimit - step)
    return

  server.overloadAdaptiveRejectStreak = 0
  if spillPressure:
    server.overloadAdaptiveAcceptStreak = 0
    return
  let backlogLowPressure =
    configuredBacklog <= 0 or
    pendingBytes <= int64(max(1024, server.overloadAdaptiveBacklogLimit div 2))
  let pendingLowPressure =
    configuredPending <= 0 or
    pendingResponses <= max(1, server.overloadAdaptivePendingLimit div 2)
  if not (backlogLowPressure and pendingLowPressure):
    server.overloadAdaptiveAcceptStreak = 0
    return

  inc server.overloadAdaptiveAcceptStreak
  if server.overloadAdaptiveAcceptStreak < cooldown:
    return
  server.overloadAdaptiveAcceptStreak = 0

  if configuredBacklog > 0:
    let bounds = overloadAdaptiveBacklogBounds(server, configuredBacklog)
    let step = overloadStepFor(server.overloadAdaptiveBacklogLimit, relaxStepPercent)
    server.overloadAdaptiveBacklogLimit = min(bounds.maxLimit, server.overloadAdaptiveBacklogLimit + step)
  if configuredPending > 0:
    let bounds = overloadAdaptivePendingBounds(server, configuredPending)
    let step = overloadStepFor(server.overloadAdaptivePendingLimit, relaxStepPercent)
    server.overloadAdaptivePendingLimit = min(bounds.maxLimit, server.overloadAdaptivePendingLimit + step)

proc wsMaxBackpressureFor(sockData: ptr SocketData): int64 {.inline.} =
  if sockData == nil or sockData.server == nil:
    return int64(DefaultWsMaxBackpressure)
  let configured = sockData.server.options.wsMaxBackpressure
  if configured < 0:
    return int64(DefaultWsMaxBackpressure)
  int64(configured)

proc wsHighWaterBackpressureFor(sockData: ptr SocketData): int64 {.inline.} =
  if sockData == nil or sockData.server == nil:
    return 0
  max(0, sockData.server.options.wsBackpressureHighWaterBytes).int64

## Compute the websocket high-water backpressure decision for a prospective queue append
proc decideWsBackpressureHighWater*(
  pendingBytes: int64,
  bytesToAdd: int64,
  highWaterBytes: int64,
  action: BackpressureHighWaterAction
): BackpressureHighWaterDecision {.inline.} =
  let current = max(0'i64, pendingBytes)
  let queued = max(0'i64, bytesToAdd)
  result.projectedBytes = current + queued
  result.triggered = highWaterBytes > 0 and result.projectedBytes > highWaterBytes
  result.action = action

proc wsCanQueueBytes(sockData: ptr SocketData, bytesToAdd: int64): bool {.inline.} =
  if sockData == nil:
    return false
  if bytesToAdd <= 0:
    return true
  let maxPending = wsMaxBackpressureFor(sockData)
  if maxPending == 0:
    return true
  sockData.wsPendingBytes + bytesToAdd <= maxPending

proc wsWriteCoalesceBytesFor(sockData: ptr SocketData): int {.inline.} =
  if sockData == nil or sockData.server == nil:
    return DefaultWsWriteCoalesceMaxBytes
  let configured = sockData.server.options.wsWriteCoalesceMaxBytes
  if configured <= 0:
    return 0
  max(1024, configured)

proc wsWriteCoalesceFramesFor(sockData: ptr SocketData): int {.inline.} =
  if sockData == nil or sockData.server == nil:
    return DefaultWsWriteCoalesceMaxFrames
  let configured = sockData.server.options.wsWriteCoalesceMaxFrames
  if configured <= 0:
    return 0
  max(1, configured)

# Cached coarse timestamps — updated once per event-loop tick via runLoopPreMaintenance.
when defined(singleThread):
  var cachedEpochMs: int64
  var cachedEpochMicros: int64
else:
  var cachedEpochMs {.threadvar.}: int64
  var cachedEpochMicros {.threadvar.}: int64

## Refresh the per-thread cached epoch timestamps updated once per event loop tick
proc refreshCachedTime*() {.inline.} =
  let t = epochTime()
  cachedEpochMs = int64(t * 1000.0)
  cachedEpochMicros = int64(t * 1_000_000.0)

## Return the current wall-clock time in epoch milliseconds
proc nowEpochMs*(): int64 {.inline.} =
  int64(epochTime() * 1000.0)

## Return the cached epoch milliseconds refreshed by the event loop
proc getCachedEpochMs*(): int64 {.inline.} =
  cachedEpochMs

## Return the cached epoch microseconds refreshed by the event loop
proc getCachedEpochMicros*(): int64 {.inline.} =
  cachedEpochMicros

proc timeoutPhaseFromLabel(label: string): TimeoutPhase {.inline.} =
  case label
  of "header_read":
    tpHeaderRead
  of "body_read":
    tpBodyRead
  of "handler_exec":
    tpHandlerExec
  of "write_drain":
    tpWriteDrain
  of "websocket_idle":
    tpWebSocketIdle
  else:
    tpNone

proc timeoutPhaseLabel(phase: TimeoutPhase): string {.inline.} =
  case phase
  of tpHeaderRead:
    "header_read"
  of tpBodyRead:
    "body_read"
  of tpHandlerExec:
    "handler_exec"
  of tpWriteDrain:
    "write_drain"
  of tpWebSocketIdle:
    "websocket_idle"
  else:
    "http_connection"

proc timeoutKindLabel(phase: TimeoutPhase): string {.inline.} =
  case phase
  of tpHeaderRead:
    "header_read"
  of tpBodyRead:
    "body_read"
  of tpHandlerExec:
    "handler_exec"
  of tpWriteDrain:
    "write_drain"
  else:
    "http_connection"

proc wsIdleTimeoutFor(sockData: ptr SocketData): cuint {.inline.} =
  if sockData == nil or sockData.server == nil:
    return 0
  let configured = sockData.server.options.wsIdleTimeoutSeconds
  if configured <= 0:
    return 0
  # uSockets keeps socket deadlines in a 240-slot wheel swept every 4s
  # (src/socket.c: s->timeout = (timestamp + seconds/4) % 240). Deadlines
  # beyond the horizon alias onto earlier slots and would fire early.
  min(configured, WsIdleTimeoutWheelHorizonSeconds).cuint

proc phaseTimeoutMillisFor(server: HttpServer, phase: TimeoutPhase): int {.inline.} =
  if server == nil:
    return 0
  case phase
  of tpHeaderRead:
    max(0, server.options.headerReadTimeoutMs)
  of tpBodyRead:
    max(0, server.options.bodyReadTimeoutMs)
  of tpHandlerExec:
    max(0, server.options.handlerExecTimeoutMs)
  of tpWriteDrain:
    max(0, server.options.writeDrainTimeoutMs)
  of tpWebSocketIdle:
    let wsTimeoutSec = max(0, server.options.wsIdleTimeoutSeconds)
    if wsTimeoutSec <= 0: 0 else: wsTimeoutSec * 1000
  else:
    0

proc phaseTimeoutMillisFor(server: HttpServer, phase: string): int {.inline, used.} =
  phaseTimeoutMillisFor(server, timeoutPhaseFromLabel(phase))

proc phaseTimeoutSecondsFor(sockData: ptr SocketData, phase: TimeoutPhase): cuint {.inline.} =
  if sockData == nil or sockData.server == nil:
    return 0
  if phase == tpWebSocketIdle:
    return sockData.wsIdleTimeoutFor()
  let phaseMillis = phaseTimeoutMillisFor(sockData.server, phase)
  if phaseMillis > 0:
    return cuint(max(1, (phaseMillis + 999) div 1000))
  let fallback = sockData.server.options.connectionTimeout
  if fallback <= 0:
    return 0
  fallback.cuint

proc phaseTimeoutSecondsFor(sockData: ptr SocketData, phase: string): cuint {.inline, used.} =
  phaseTimeoutSecondsFor(sockData, timeoutPhaseFromLabel(phase))

proc shouldUpdateSocketTimeoutPhase(
  sockData: ptr SocketData,
  phase: TimeoutPhase,
  requestSeq: uint64,
  timeoutSeconds: cuint
): bool {.inline.} =
  if sockData == nil:
    return false
  sockData.timeoutPhase != phase or
  sockData.activeRequestSeq != requestSeq or
  sockData.timeoutPhaseSeconds != timeoutSeconds

proc setSocketTimeoutPhase(
  sockData: ptr SocketData,
  s: UsSocketPtr,
  phase: TimeoutPhase,
  requestSeq: uint64 = 0'u64,
  nowMs: int64 = 0'i64,
  rearm: bool = false
) {.inline.} =
  if sockData == nil or sockData.server == nil or s == nil:
    return
  let timeoutSeconds = phaseTimeoutSecondsFor(sockData, phase)
  # The dedup guard skips redundant phase *transitions*. `rearm` marks a timer
  # *re-arm* (same phase/seq/seconds, later instant), which is never redundant:
  # the C deadline must be pushed forward even though nothing else changed.
  # us_socket_timeout is a single byte store into the loop's 4s-granularity
  # timeout wheel (uSockets src/socket.c), so per-activity re-arms are free.
  if not rearm and not shouldUpdateSocketTimeoutPhase(sockData, phase, requestSeq, timeoutSeconds):
    return
  let previousTimeoutSeconds = sockData.timeoutPhaseSeconds
  sockData.timeoutPhase = phase
  sockData.activeRequestSeq = requestSeq
  sockData.phaseStartedAtMs = if nowMs != 0: nowMs else: getCachedEpochMs()
  sockData.timeoutPhaseSeconds = timeoutSeconds
  if timeoutSeconds > 0 or previousTimeoutSeconds != 0:
    us_socket_timeout(sockData.server.ssl.toInt, s, timeoutSeconds)

proc setSocketTimeoutPhase(
  sockData: ptr SocketData,
  s: UsSocketPtr,
  phase: string,
  requestSeq: uint64 = 0'u64,
  nowMs: int64 = 0'i64
) {.inline, used.} =
  sockData.setSocketTimeoutPhase(s, timeoutPhaseFromLabel(phase), requestSeq, nowMs)

proc emitTimeoutCallbacks(sockData: ptr SocketData, kind: string, phase: string) {.inline.} =
  if sockData == nil or sockData.server == nil:
    return
  let server = sockData.server
  if server.timeoutHandler != nil:
    try:
      server.timeoutHandler(kind, sockData.remoteIp)
    except CatchableError as err:
      server.emitServerPanic("timeoutHandler", err.msg)
    except Defect as defect:
      server.emitServerPanic("timeoutHandler_defect", defect.msg)
  if server.timeoutMetadataHandler != nil:
    try:
      server.timeoutMetadataHandler(
        kind,
        phase,
        sockData.remoteIp,
        sockData.activeRequestSeq,
        sockData.hasFlag(SDF_IS_WEBSOCKET)
      )
    except CatchableError as err:
      server.emitServerPanic("timeoutMetadataHandler", err.msg)
    except Defect as defect:
      server.emitServerPanic("timeoutMetadataHandler_defect", defect.msg)

proc refreshWsIdleTimeout(sockData: ptr SocketData, s: UsSocketPtr, onSendPath: bool) {.inline.} =
  if sockData == nil or s == nil:
    return
  let timeout = sockData.wsIdleTimeoutFor()
  if timeout == 0:
    return
  if onSendPath and not sockData.server.options.wsResetIdleTimeoutOnSend:
    return
  sockData.setSocketTimeoutPhase(s, tpWebSocketIdle, sockData.activeRequestSeq, rearm = true)

proc wsQueueIsEmpty(sockData: ptr SocketData): bool {.inline.} =
  sockData == nil or sockData.wsOutHead >= sockData.wsOutQueue.len

const WsQueueShrinkThreshold = 64

proc wsQueueReset(sockData: ptr SocketData) {.inline.} =
  if sockData == nil:
    return
  if sockData.wsOutQueue.len > WsQueueShrinkThreshold:
    sockData.wsOutQueue = newSeqOfCap[WsQueuedFrame](WsQueueShrinkThreshold div 4)
  else:
    sockData.wsOutQueue.setLen(0)
  sockData.wsOutHead = 0
  sockData.wsOutPos = 0
  if sockData.wsOutPalette.len > WsQueueShrinkThreshold:
    sockData.wsOutPalette = newSeqOfCap[string](WsQueueShrinkThreshold div 4)
    sockData.wsOutPaletteRefs = newSeqOfCap[int](WsQueueShrinkThreshold div 4)
    sockData.wsOutPaletteFree = newSeqOfCap[int](WsQueueShrinkThreshold div 8)
  else:
    sockData.wsOutPalette.setLen(0)
    sockData.wsOutPaletteRefs.setLen(0)
    sockData.wsOutPaletteFree.setLen(0)
  if sockData.wsCoalesceBuffer.len > WsQueueShrinkThreshold * 4:
    sockData.wsCoalesceBuffer = newStringOfCap(256)
  else:
    sockData.wsCoalesceBuffer.setLen(0)

proc wsQueuePaletteAcquire(sockData: ptr SocketData, frame: string): int {.inline.} =
  if sockData == nil:
    return -1
  if sockData.wsOutPaletteFree.len > 0:
    let freeLast = sockData.wsOutPaletteFree.len - 1
    let freeIdx = sockData.wsOutPaletteFree[freeLast]
    sockData.wsOutPaletteFree.setLen(freeLast)
    if freeIdx >= 0 and freeIdx < sockData.wsOutPalette.len and freeIdx < sockData.wsOutPaletteRefs.len:
      sockData.wsOutPalette[freeIdx] = frame
      sockData.wsOutPaletteRefs[freeIdx] = 1
      return freeIdx
  result = sockData.wsOutPalette.len
  sockData.wsOutPalette.add(frame)
  sockData.wsOutPaletteRefs.add(1)

proc wsQueuePaletteCompact(sockData: ptr SocketData) {.inline.} =
  if sockData == nil:
    return
  let oldLen = sockData.wsOutPalette.len
  if oldLen <= WsQueueShrinkThreshold:
    return
  var usedCount = 0
  for i in 0..<oldLen:
    if i < sockData.wsOutPaletteRefs.len and sockData.wsOutPaletteRefs[i] > 0:
      inc usedCount
  if usedCount >= oldLen div 4:
    return
  var newPalette = newSeqOfCap[string](max(usedCount, 4))
  var newRefs = newSeqOfCap[int](max(usedCount, 4))
  var remap: seq[int] = newSeq[int](oldLen)
  for i in 0..<oldLen:
    if i < sockData.wsOutPaletteRefs.len and sockData.wsOutPaletteRefs[i] > 0:
      remap[i] = newPalette.len
      newPalette.add(sockData.wsOutPalette[i])
      newRefs.add(sockData.wsOutPaletteRefs[i])
    else:
      remap[i] = -1
  for i in sockData.wsOutHead..<sockData.wsOutQueue.len:
    let pi = sockData.wsOutQueue[i].paletteIdx
    if pi >= 0 and pi < oldLen:
      sockData.wsOutQueue[i].paletteIdx = remap[pi]
  sockData.wsOutPalette = newPalette
  sockData.wsOutPaletteRefs = newRefs
  sockData.wsOutPaletteFree.setLen(0)

proc wsQueuePaletteRelease(sockData: ptr SocketData, paletteIdx: int) {.inline.} =
  if sockData == nil:
    return
  if paletteIdx < 0 or paletteIdx >= sockData.wsOutPaletteRefs.len:
    return
  let currentRefs = sockData.wsOutPaletteRefs[paletteIdx]
  if currentRefs <= 0:
    return
  let nextRefs = currentRefs - 1
  sockData.wsOutPaletteRefs[paletteIdx] = nextRefs
  if nextRefs <= 0:
    if paletteIdx < sockData.wsOutPalette.len:
      sockData.wsOutPalette[paletteIdx] = ""
    sockData.wsOutPaletteFree.add(paletteIdx)
    if sockData.wsOutPaletteFree.len > sockData.wsOutPalette.len div 2:
      wsQueuePaletteCompact(sockData)

proc wsQueueEnqueue(
  sockData: ptr SocketData,
  frame: string,
  frameOffset: int = 0,
  isControl: bool = false
): int {.inline.} =
  if sockData == nil:
    return 0
  let boundedOffset = max(0, min(frame.len, frameOffset))
  if boundedOffset >= frame.len:
    return 0
  let paletteIdx = sockData.wsQueuePaletteAcquire(frame)
  if paletteIdx < 0:
    return 0
  sockData.wsOutQueue.add(WsQueuedFrame(
    paletteIdx: paletteIdx,
    frameOffset: boundedOffset,
    payloadBytes: 0,
    isBinary: false,
    isControl: isControl
  ))
  frame.len - boundedOffset

proc queueWsFrame(
  sockData: ptr SocketData,
  frame: string,
  payloadBytes: int,
  isBinary: bool,
  frameOffset: int = 0,
  isControl: bool = false
) {.inline.} =
  if sockData == nil:
    return
  let queuedBytes = sockData.wsQueueEnqueue(frame, frameOffset, isControl)
  if queuedBytes <= 0 or sockData.wsOutQueue.len == 0:
    return
  let queuedTail = sockData.wsOutQueue.len - 1
  sockData.wsOutQueue[queuedTail].payloadBytes = max(0, payloadBytes)
  sockData.wsOutQueue[queuedTail].isBinary = isBinary
  sockData.wsOutQueue[queuedTail].isControl = isControl

proc wsQueueReleaseHead(sockData: ptr SocketData) {.inline.} =
  if sockData == nil or sockData.wsOutHead < 0 or sockData.wsOutHead >= sockData.wsOutQueue.len:
    return
  let head = sockData.wsOutHead
  let entry = sockData.wsOutQueue[head]
  sockData.wsOutQueue[head] = WsQueuedFrame(paletteIdx: -1)
  inc sockData.wsOutHead
  sockData.wsOutPos = 0
  sockData.wsQueuePaletteRelease(entry.paletteIdx)

proc compactWsQueue(sockData: ptr SocketData) {.inline.} =
  if sockData == nil:
    return
  if sockData.wsOutHead <= 0:
    if sockData.wsOutHead >= sockData.wsOutQueue.len:
      sockData.wsQueueReset()
    return
  let remaining = sockData.wsOutQueue.len - sockData.wsOutHead
  if remaining <= 0:
    sockData.wsQueueReset()
    return
  if remaining > 0:
    moveMem(addr sockData.wsOutQueue[0],
            addr sockData.wsOutQueue[sockData.wsOutHead],
            remaining * sizeof(WsQueuedFrame))
  sockData.wsOutQueue.setLen(max(0, remaining))
  sockData.wsOutHead = 0

proc consumeWsQueueBytes(sockData: ptr SocketData, bytes: int): int {.inline.} =
  if sockData == nil or bytes <= 0:
    return 0
  var remaining = bytes
  while remaining > 0 and not sockData.wsQueueIsEmpty():
    if sockData.wsOutHead >= sockData.wsOutQueue.len:
      break
    let entry = sockData.wsOutQueue[sockData.wsOutHead]
    if entry.paletteIdx < 0 or entry.paletteIdx >= sockData.wsOutPalette.len:
      sockData.wsQueueReleaseHead()
      continue
    let frame = sockData.wsOutPalette[entry.paletteIdx]
    let pos = entry.frameOffset + sockData.wsOutPos
    if pos >= frame.len:
      sockData.wsQueueReleaseHead()
      continue
    let available = frame.len - pos
    let step = min(remaining, available)
    sockData.wsOutPos += step
    sockData.wsPendingBytes -= int64(step)
    if sockData.wsPendingBytes < 0:
      sockData.wsPendingBytes = 0
    remaining -= step
    result += step
    if step >= available:
      sockData.wsQueueReleaseHead()
  if sockData.wsQueueIsEmpty():
    sockData.wsQueueReset()

when defined(test) or defined(nimUwebsocketsTest):
  type
    WsQueueDebug* = ref object
      data: SocketData

    WsQueueDebugSnapshot* = object
      queueDepth*: int
      pendingBytes*: int64
      paletteSlots*: int
      paletteFree*: int
      headOffset*: int
      headIsControl*: bool
      headRemaining*: string

  ## Create a debug websocket out-queue handle mirroring the production frame queue state
  proc newWsQueueDebug*(): WsQueueDebug =
    new(result)
    result.data.wsOutQueue = @[]
    result.data.wsOutHead = 0
    result.data.wsOutPos = 0
    result.data.wsOutPalette = @[]
    result.data.wsOutPaletteRefs = @[]
    result.data.wsOutPaletteFree = @[]
    result.data.wsPendingBytes = 0

  ## Enqueue a websocket frame into the debug out-queue and return the queued byte count
  proc enqueueWsQueueDebug*(
    q: WsQueueDebug,
    frame: string,
    frameOffset: int = 0,
    isControl: bool = false
  ): int =
    if q == nil:
      return 0
    let queued = wsQueueEnqueue(addr q.data, frame, frameOffset, isControl)
    q.data.wsPendingBytes += int64(queued)
    queued

  ## Advance the debug websocket out-queue as if the given number of bytes were written
  proc consumeWsQueueDebug*(q: WsQueueDebug, bytes: int): int =
    if q == nil or bytes <= 0:
      return 0
    consumeWsQueueBytes(addr q.data, bytes)

  ## Compact the debug websocket out-queue to release consumed frame slots
  proc compactWsQueueDebug*(q: WsQueueDebug) =
    if q != nil:
      compactWsQueue(addr q.data)

  ## Capture a point-in-time snapshot of the debug websocket out-queue state
  proc snapshotWsQueueDebug*(q: WsQueueDebug): WsQueueDebugSnapshot =
    if q == nil:
      return
    let sockData = addr q.data
    result.queueDepth = max(0, sockData.wsOutQueue.len - sockData.wsOutHead)
    result.pendingBytes = sockData.wsPendingBytes
    result.paletteSlots = sockData.wsOutPalette.len
    result.paletteFree = sockData.wsOutPaletteFree.len
    if not wsQueueIsEmpty(sockData) and sockData.wsOutHead < sockData.wsOutQueue.len:
      let entry = sockData.wsOutQueue[sockData.wsOutHead]
      result.headIsControl = entry.isControl
      result.headOffset = entry.frameOffset + sockData.wsOutPos
      if entry.paletteIdx >= 0 and entry.paletteIdx < sockData.wsOutPalette.len:
        let frame = sockData.wsOutPalette[entry.paletteIdx]
        if result.headOffset >= 0 and result.headOffset < frame.len:
          result.headRemaining = frame[result.headOffset..^1]
        else:
          result.headRemaining = ""

proc canQueueMoreBytes(sockData: ptr SocketData, bytesToAdd: int64): bool {.inline.} =
  if sockData == nil:
    return false
  if bytesToAdd <= 0:
    return true
  let maxPending = sockData.maxPendingBytesFor()
  sockData.pendingBytes + sockData.sendBufferRemaining() + bytesToAdd <= maxPending

proc onQueuedBytesWritten(sockData: ptr SocketData, bytesWritten: int64) {.inline.} =
  if sockData == nil or bytesWritten <= 0:
    return
  sockData.pendingBytes -= bytesWritten
  if sockData.pendingBytes < 0:
    sockData.pendingBytes = 0

proc closeQueuedFile(resp: var QueuedResponse) {.inline.} =
  if not resp.isFileBody and resp.streamChunks.len == 0:
    return
  if resp.isFileBody and resp.fileFd >= 0:
    discard close(resp.fileFd)
    resp.fileFd = -1
  if resp.streamChunks.len > 0:
    resp.streamChunks.setLen(0)
  resp.streamChunkHead = 0
  resp.streamChunkPos = 0

proc initQueuedSendFileResponse(
  header: string,
  fileFd: cint,
  fileSize: int64,
  closeAfterWrite: bool,
  writableHandler: HttpWritableHandler
): QueuedResponse {.inline.} =
  let totalSize =
    if fileSize > 0:
      uint64(fileSize)
    else:
      0'u64
  QueuedResponse(
    header: header,
    body: "",
    headerPos: 0,
    bodyPos: 0,
    isFileBody: true,
    fileFd: fileFd,
    fileOffset: 0.Off,
    fileRemaining: fileSize.Off,
    closeAfterWrite: closeAfterWrite,
    isStreamBody: false,
    streamOpen: false,
    hasTryEnd: true,
    tryEndOffset: 0,
    tryEndTotal: totalSize,
    writableHandler: writableHandler
  )

proc updateTryEndProgress(resp: var QueuedResponse, written: int64) {.inline.} =
  if not resp.hasTryEnd or written <= 0:
    return
  let nextOffset = resp.tryEndOffset + uint64(written)
  if resp.tryEndTotal > 0 and nextOffset > resp.tryEndTotal:
    resp.tryEndOffset = resp.tryEndTotal
  else:
    resp.tryEndOffset = nextOffset

proc writeQueuedResponse(
  sockData: ptr SocketData,
  ssl: cint,
  s: UsSocketPtr,
  resp: var QueuedResponse,
  bytesWritten: var int64
): bool {.inline.} =
  bytesWritten = 0
  if s == nil:
    return true
  if us_socket_is_closed(ssl, s) != 0 or us_socket_is_shut_down(ssl, s) != 0:
    return true

  var written = 0
  var fixedWrite = false
  var headerRemainingBeforeWrite = 0
  if resp.headerPos < resp.header.len:
    when defined(macosx):
      if resp.isFileBody and resp.fileRemaining > 0 and ssl == 0 and resp.fileFd >= 0:
        let nativeHandle = us_socket_get_native_handle(ssl, s)
        if nativeHandle != nil:
          let outFd = cast[cint](cast[int](nativeHandle))
          let headerPtr = cast[pointer](unsafeAddr resp.header[resp.headerPos])
          let hdrLen = resp.header.len - resp.headerPos
          var hdrIov = IOVec(iov_base: headerPtr, iov_len: csize_t(hdrLen))
          var hdtr = SfHdtr(
            headers: addr hdrIov,
            hdr_cnt: 1,
            trailers: nil,
            trl_cnt: 0
          )
          var totalSent: Off = 0
          let rc = osxSendfile(resp.fileFd, outFd, resp.fileOffset, addr totalSent, addr hdtr, 0)
          if totalSent > 0:
            let hdrConsumed = min(hdrLen, int(totalSent))
            resp.headerPos += hdrConsumed
            let dataSent = totalSent - Off(hdrConsumed)
            if dataSent > 0:
              resp.fileOffset += dataSent
              resp.fileRemaining -= dataSent
            bytesWritten += int64(hdrConsumed) + int64(dataSent)
            resp.updateTryEndProgress(int64(dataSent))
          if rc == 0:
            return resp.headerPos >= resp.header.len and resp.fileRemaining <= 0
          let e = errno
          if e == EAGAIN or e == EWOULDBLOCK:
            return false
          resp.hardFailure = true
          resp.closeAfterWrite = true
          return false
    fixedWrite = true
    let headerPtr = cast[cstring](unsafeAddr resp.header[resp.headerPos])
    headerRemainingBeforeWrite = resp.header.len - resp.headerPos
    if not resp.isFileBody and resp.bodyPos == 0 and resp.body.len > 0 and ssl == 0:
      if sockData.sendBuffer.len == 0:
        written = int(us_socket_write2_unchecked(s,
          headerPtr, headerRemainingBeforeWrite.cint,
          cast[cstring](unsafeAddr resp.body[0]), resp.body.len.cint))
        if written < 0: written = 0
      else:
        written = bufferSocketWrite2(
          sockData, ssl, s,
          headerPtr,
          headerRemainingBeforeWrite,
          cast[cstring](unsafeAddr resp.body[0]),
          resp.body.len
        )
    else:
      written = bufferSocketWrite(sockData, ssl, s, headerPtr, headerRemainingBeforeWrite)
  elif resp.bodyPos < resp.body.len:
    fixedWrite = true
    headerRemainingBeforeWrite = 0
    let bodyPtr = cast[cstring](unsafeAddr resp.body[resp.bodyPos])
    let bodyRemaining = resp.body.len - resp.bodyPos
    written = bufferSocketWrite(sockData, ssl, s, bodyPtr, bodyRemaining)
  elif resp.streamChunkHead < resp.streamChunks.len:
    # Stream chunks are tracked separately to avoid repeatedly appending into one growable string.
    var idx = resp.streamChunkHead
    while idx < resp.streamChunks.len and resp.streamChunks[idx].len == 0:
      inc idx
    if idx >= resp.streamChunks.len:
      resp.streamChunks.setLen(0)
      resp.streamChunkHead = 0
      resp.streamChunkPos = 0
      if resp.isStreamBody and resp.streamOpen:
        return false
      return resp.isFullyWritten()

    if idx != resp.streamChunkHead:
      resp.streamChunkHead = idx
      resp.streamChunkPos = 0

    let chunkLen = resp.streamChunks[idx].len
    if resp.streamChunkPos >= chunkLen:
      resp.streamChunks[idx] = ""
      resp.streamChunkHead = idx + 1
      resp.streamChunkPos = 0
      if resp.streamChunkHead >= resp.streamChunks.len:
        resp.streamChunks.setLen(0)
        resp.streamChunkHead = 0
      if resp.isStreamBody and resp.streamOpen:
        return false
      return resp.isFullyWritten()

    let chunkPtr = cast[cstring](unsafeAddr resp.streamChunks[idx][resp.streamChunkPos])
    let chunkRemaining = chunkLen - resp.streamChunkPos

    if ssl == 0 and resp.streamChunkPos == 0:
      var nextIdx = idx + 1
      while nextIdx < resp.streamChunks.len and resp.streamChunks[nextIdx].len == 0:
        inc nextIdx
      if nextIdx < resp.streamChunks.len:
        let nextLen = resp.streamChunks[nextIdx].len
        if nextLen > 0:
          written = bufferSocketWrite2(
            sockData, ssl, s,
            chunkPtr,
            chunkRemaining,
            cast[cstring](unsafeAddr resp.streamChunks[nextIdx][0]),
            nextLen
          )
          bytesWritten += int64(written)
          resp.updateTryEndProgress(int64(written))

          resp.streamChunks[idx] = ""
          resp.streamChunks[nextIdx] = ""
          resp.streamChunkHead = nextIdx + 1
          resp.streamChunkPos = 0
          if resp.streamChunkHead >= resp.streamChunks.len:
            resp.streamChunks.setLen(0)
            resp.streamChunkHead = 0
          if resp.isStreamBody and resp.streamOpen:
            return false
          return resp.isFullyWritten()

    written = bufferSocketWrite(sockData, ssl, s, chunkPtr, chunkRemaining)
    bytesWritten += int64(written)
    resp.updateTryEndProgress(int64(written))

    resp.streamChunks[idx] = ""
    resp.streamChunkHead = idx + 1
    resp.streamChunkPos = 0
    if resp.streamChunkHead >= resp.streamChunks.len:
      resp.streamChunks.setLen(0)
      resp.streamChunkHead = 0
    if resp.isStreamBody and resp.streamOpen:
      return false
    return resp.isFullyWritten()
  elif resp.isFileBody and resp.fileRemaining > 0:
    when defined(macosx):
      if ssl != 0:
        return true
      if resp.fileFd < 0:
        resp.hardFailure = true
        resp.closeAfterWrite = true
        return false
      let nativeHandle = us_socket_get_native_handle(ssl, s)
      if nativeHandle == nil:
        resp.hardFailure = true
        resp.closeAfterWrite = true
        return false
      let outFd = cast[cint](cast[int](nativeHandle))
      var sent: Off = resp.fileRemaining
      let rc = osxSendfile(resp.fileFd, outFd, resp.fileOffset, addr sent, nil, 0)
      if sent > 0:
        resp.fileOffset += sent
        resp.fileRemaining -= sent
        bytesWritten += int64(sent)
        resp.updateTryEndProgress(int64(sent))
      if rc == 0:
        return resp.fileRemaining <= 0
      let e = errno
      if e == EAGAIN or e == EWOULDBLOCK:
        return false
      resp.hardFailure = true
      resp.closeAfterWrite = true
      return false
    elif defined(linux):
      if ssl != 0:
        return true
      if resp.fileFd < 0:
        resp.hardFailure = true
        resp.closeAfterWrite = true
        return false
      let nativeHandle = us_socket_get_native_handle(ssl, s)
      if nativeHandle == nil:
        resp.hardFailure = true
        resp.closeAfterWrite = true
        return false
      let outFd = cast[cint](cast[int](nativeHandle))
      if outFd < 0:
        resp.hardFailure = true
        resp.closeAfterWrite = true
        return false
      var offset = resp.fileOffset
      let maxCount = if resp.fileRemaining > Off(high(int32)): high(int32).Off else: resp.fileRemaining
      let sent = linuxSendfile(outFd, resp.fileFd, addr offset, csize_t(max(0.Off, maxCount)))
      if sent > 0:
        let wrote = sent.Off
        resp.fileOffset = offset
        resp.fileRemaining -= wrote
        bytesWritten += int64(sent)
        resp.updateTryEndProgress(int64(sent))
      elif sent == 0:
        resp.hardFailure = true
        resp.closeAfterWrite = true
        return false
      else:
        let e = errno
        if e == EAGAIN or e == EWOULDBLOCK:
          return false
        resp.hardFailure = true
        resp.closeAfterWrite = true
        return false
      return resp.fileRemaining <= 0
    else:
      return true
  else:
    # Stream responses may temporarily have no buffered bytes while remaining open.
    if resp.isStreamBody and resp.streamOpen:
      return false
    return true

  bytesWritten += int64(written)
  if fixedWrite:
    resp.applyFixedWriteProgress(written, headerRemainingBeforeWrite)
    if not resp.isFileBody and not resp.isStreamBody:
      return resp.headerPos >= resp.header.len and resp.bodyPos >= resp.body.len
    return resp.isFullyWritten()
  false

proc pendingCapacity(sockData: ptr SocketData): int {.inline.} =
  if sockData == nil:
    return 0
  sockData.pendingSlots.len

proc pendingPhysicalIndex(sockData: ptr SocketData, offset: int): int {.inline.} =
  let cap = sockData.pendingCapacity()
  if cap <= 0 or offset < 0 or offset >= cap:
    return -1
  result = sockData.pendingStart + offset
  if result >= cap:
    dec result, cap

proc clearPendingSlot(sockData: ptr SocketData, idx: int) {.inline.} =
  if sockData == nil or idx < 0 or idx >= sockData.pendingSlots.len:
    return
  sockData.pendingUsed[idx] = false
  sockData.pendingSlots[idx] = default(QueuedResponse)

proc ensurePendingCapacity(sockData: ptr SocketData, neededCapacity: int) =
  if sockData == nil or neededCapacity <= sockData.pendingCapacity():
    return

  let oldCap = sockData.pendingCapacity()
  var newCap = max(1, oldCap)
  while newCap < neededCapacity:
    newCap = max(newCap * 2, neededCapacity)

  var newSlots = newSeq[QueuedResponse](newCap)
  var newUsed = newSeq[bool](newCap)

  if oldCap > 0 and sockData.pendingActiveCount > 0:
    for offset in 0..<oldCap:
      let oldIdx = sockData.pendingPhysicalIndex(offset)
      if oldIdx >= 0 and sockData.pendingUsed[oldIdx]:
        newSlots[offset] = move(sockData.pendingSlots[oldIdx])
        newUsed[offset] = true

  sockData.pendingSlots = move(newSlots)
  sockData.pendingUsed = move(newUsed)
  sockData.pendingStart = 0

proc advancePendingHead(sockData: ptr SocketData) {.inline.} =
  if sockData == nil:
    return
  if sockData.pendingActiveCount <= 0 or sockData.pendingCapacity() <= 0:
    sockData.pendingStart = 0
    sockData.pendingActiveCount = 0
    return
  let cap = sockData.pendingCapacity()
  var advanced = 0
  while advanced < cap and not sockData.pendingUsed[sockData.pendingStart]:
    inc advanced
    inc sockData.pendingStart
    if sockData.pendingStart >= cap:
      sockData.pendingStart = 0

proc pendingIsEmpty(sockData: ptr SocketData): bool {.inline.} =
  sockData == nil or sockData.pendingActiveCount <= 0

proc pendingActiveCountForOverload(sockData: ptr SocketData): int {.inline.} =
  if sockData == nil:
    return 0
  if sockData.pendingActiveCount > 0:
    return sockData.pendingActiveCount
  for used in sockData.pendingUsed:
    if used:
      inc result

proc pendingIndexForSeq(sockData: ptr SocketData, seq: uint64, grow: bool): int {.inline.} =
  if sockData == nil:
    return -1
  if seq < sockData.nextWriteSeq:
    return -1
  let delta = seq - sockData.nextWriteSeq
  if delta > uint64(high(int)):
    return -1
  let offset = int(delta)
  if grow:
    sockData.ensurePendingCapacity(offset + 1)
  pendingPhysicalIndex(sockData, offset)

proc responseSlotForSeq(sockData: ptr SocketData, seq: uint64): int {.inline.} =
  pendingIndexForSeq(sockData, seq, false)

proc responseHasPendingDrain(sockData: ptr SocketData, seq: uint64): bool {.inline, used.} =
  let idx = responseSlotForSeq(sockData, seq)
  if idx < 0 or idx >= sockData.pendingUsed.len or not sockData.pendingUsed[idx]:
    return false
  queuedRemainingBytes(sockData.pendingSlots[idx]) > 0

proc responseIsDrained(sockData: ptr SocketData, seq: uint64): bool {.inline.} =
  sockData != nil and seq < sockData.nextWriteSeq

proc enqueuePendingResponse(sockData: ptr SocketData, seq: uint64, resp: sink QueuedResponse): bool {.inline.} =
  if sockData == nil:
    return false
  let newRemaining = queuedRemainingBytesFast(resp)
  var idx = pendingIndexForSeq(sockData, seq, false)
  if idx >= 0 and idx < sockData.pendingUsed.len and sockData.pendingUsed[idx]:
    let existingRemaining = queuedRemainingBytesFast(sockData.pendingSlots[idx])
    let projected = sockData.pendingBytes - existingRemaining + newRemaining
    if projected > sockData.maxPendingBytesFor():
      if sockData.server != nil:
        sockData.server.emitBackpressure(projected, false)
      return false
    sockData.pendingBytes = projected
    sockData.pendingSlots[idx].closeQueuedFile()
  else:
    if not sockData.canQueueMoreBytes(newRemaining):
      if sockData.server != nil:
        sockData.server.emitBackpressure(sockData.pendingBytes + newRemaining, false)
      return false
    idx = pendingIndexForSeq(sockData, seq, true)
    if idx < 0:
      return false
    sockData.pendingBytes += newRemaining
    inc sockData.pendingActiveCount
  sockData.pendingSlots[idx] = resp
  sockData.pendingUsed[idx] = true
  true

proc appendPendingStreamChunk(
  sockData: ptr SocketData,
  seq: uint64,
  encodedChunk: string,
  finishStream: bool,
  closeAfterWrite: bool
): bool =
  let idx = pendingIndexForSeq(sockData, seq, false)
  if idx < 0 or idx >= sockData.pendingUsed.len or not sockData.pendingUsed[idx]:
    return false
  if not sockData.pendingSlots[idx].isStreamBody or not sockData.pendingSlots[idx].streamOpen:
    return false

  let addBytes = int64(encodedChunk.len)
  if not sockData.canQueueMoreBytes(addBytes):
    return false

  if encodedChunk.len > 0:
    if sockData.pendingSlots[idx].streamChunks.len == 0:
      sockData.pendingSlots[idx].streamChunks = newSeqOfCap[string](8)
    sockData.pendingSlots[idx].streamChunks.add(encodedChunk)
    sockData.pendingBytes += addBytes
  if finishStream:
    sockData.pendingSlots[idx].streamOpen = false
    if closeAfterWrite:
      sockData.pendingSlots[idx].closeAfterWrite = true
  true

proc updatePendingWritableHandler(
  sockData: ptr SocketData,
  seq: uint64,
  handler: HttpWritableHandler
) {.inline.} =
  if sockData == nil:
    return
  let idx = responseSlotForSeq(sockData, seq)
  if idx < 0 or idx >= sockData.pendingUsed.len or not sockData.pendingUsed[idx]:
    return
  if sockData.pendingSlots[idx].hasTryEnd:
    sockData.pendingSlots[idx].writableHandler = handler

proc syncTryEndOffset(res: HttpResponse, sockData: ptr SocketData) {.inline.} =
  if res == nil or sockData == nil:
    return
  if res.requestSeq < sockData.nextWriteSeq:
    res.tryEndOffset = res.tryEndQueued
    return
  let idx = responseSlotForSeq(sockData, res.requestSeq)
  if idx >= 0 and idx < sockData.pendingUsed.len and sockData.pendingUsed[idx] and sockData.pendingSlots[idx].hasTryEnd:
    res.tryEndOffset = sockData.pendingSlots[idx].tryEndOffset

proc contiguousPendingReadyCount(sockData: ptr SocketData, cap: int): int {.inline.} =
  if sockData == nil or cap <= 0 or sockData.pendingCapacity() <= 0 or sockData.pendingIsEmpty():
    return 0
  let limit = min(cap, sockData.pendingCapacity())
  while result < limit:
    let idx = sockData.pendingPhysicalIndex(result)
    if idx < 0 or not sockData.pendingUsed[idx]:
      break
    inc result

proc buildCoalescedWriteBuffer(
  sockData: ptr SocketData
): int {.inline.} =
  if sockData == nil:
    return 0
  let headIdx = sockData.pendingStart
  if headIdx < 0 or headIdx >= sockData.pendingUsed.len or not sockData.pendingUsed[headIdx]:
    return 0
  if not sockData.pendingSlots[headIdx].canCoalesceQueuedResponse():
    return 0

  var includedCount = 0
  var totalCoalescedBytes = 0
  let serverRef = sockData.server
  let throughputProbe = normalizeCoalesceResponses(
    if serverRef != nil:
      serverRef.options.writeCoalesceThroughputMaxResponses
    else:
      DefaultWriteCoalesceThroughputMaxResponses,
    DefaultWriteCoalesceThroughputMaxResponses
  )
  let guardProbe = normalizePendingGuard(
    if serverRef != nil:
      serverRef.options.writeCoalesceP99GuardPendingResponses
    else:
      DefaultWriteCoalesceP99GuardPendingResponses,
    DefaultWriteCoalesceP99GuardPendingResponses
  )
  let probeLimit = max(2, max(throughputProbe, guardProbe))
  let readyResponses = sockData.contiguousPendingReadyCount(probeLimit)
  let headPayloadBytes = sockData.pendingSlots[headIdx].header.len +
                         sockData.pendingSlots[headIdx].body.len
  let limits = resolveWriteCoalesceLimits(
    serverRef,
    sockData.pendingBytes,
    readyResponses,
    headPayloadBytes,
    sockData.writeBatchDepth > 0
  )
  let maxCoalescedResponses = limits.maxResponses
  let maxCoalescedBytes = limits.maxBytes

  while includedCount < maxCoalescedResponses:
    let idx = sockData.pendingPhysicalIndex(includedCount)
    if idx < 0 or not sockData.pendingUsed[idx]:
      break
    if not sockData.pendingSlots[idx].canCoalesceQueuedResponse():
      break
    let candidateSize = sockData.pendingSlots[idx].header.len +
                        sockData.pendingSlots[idx].body.len
    if totalCoalescedBytes > 0 and
       totalCoalescedBytes + candidateSize > maxCoalescedBytes:
      break
    if totalCoalescedBytes == 0 and candidateSize > maxCoalescedBytes:
      break

    totalCoalescedBytes += candidateSize
    inc includedCount
    if sockData.pendingSlots[idx].closeAfterWrite:
      break

  if includedCount <= 0:
    sockData.coalesceBuffer.setLen(0)
    return 0

  when SegmentCoalesceCopyEnabled:
    sockData.coalesceBuffer.setLen(totalCoalescedBytes)
    if totalCoalescedBytes > 0:
      var writePos = 0
      var offset = 0
      while offset < includedCount:
        let copyIdx = sockData.pendingPhysicalIndex(offset)
        let headerLen = sockData.pendingSlots[copyIdx].header.len
        if headerLen > 0:
          copyMem(
            addr sockData.coalesceBuffer[writePos],
            unsafeAddr sockData.pendingSlots[copyIdx].header[0],
            headerLen
          )
          writePos += headerLen
        let bodyLen = sockData.pendingSlots[copyIdx].body.len
        if bodyLen > 0:
          copyMem(
            addr sockData.coalesceBuffer[writePos],
            unsafeAddr sockData.pendingSlots[copyIdx].body[0],
            bodyLen
          )
          writePos += bodyLen
        inc offset
  else:
    sockData.coalesceBuffer.setLen(0)
    var offset = 0
    while offset < includedCount:
      let copyIdx = sockData.pendingPhysicalIndex(offset)
      sockData.coalesceBuffer.add(sockData.pendingSlots[copyIdx].header)
      sockData.coalesceBuffer.add(sockData.pendingSlots[copyIdx].body)
      inc offset

  includedCount

proc buildCoalescedWriteBuffer(
  sockData: ptr SocketData,
  startOffset: int,
  scanEnd: var int
): int {.inline, used.} =
  scanEnd = startOffset
  if sockData == nil or startOffset < 0 or sockData.pendingCapacity() <= 0:
    if sockData != nil:
      sockData.coalesceBuffer.setLen(0)
    return 0

  var offset = startOffset
  while offset < sockData.pendingCapacity():
    let idx = sockData.pendingPhysicalIndex(offset)
    if idx < 0 or idx >= sockData.pendingUsed.len or not sockData.pendingUsed[idx]:
      break
    if not sockData.pendingSlots[idx].canCoalesceQueuedResponse():
      break

    inc result
    inc offset
    if sockData.pendingSlots[idx].closeAfterWrite:
      break

  if result <= 0:
    sockData.coalesceBuffer.setLen(0)
    return 0

  sockData.coalesceBuffer.setLen(0)
  var copyOffset = startOffset
  while copyOffset < startOffset + result:
    let copyIdx = sockData.pendingPhysicalIndex(copyOffset)
    sockData.coalesceBuffer.add(sockData.pendingSlots[copyIdx].header)
    sockData.coalesceBuffer.add(sockData.pendingSlots[copyIdx].body)
    inc copyOffset
  scanEnd = startOffset + result

proc scheduleSocketDataResume(sockData: ptr SocketData, s: UsSocketPtr) {.inline.} =
  if sockData == nil or sockData.server == nil or s == nil or sockData.hasFlag(SDF_RESUME_SCHEDULED):
    return
  sockData.setFlag(SDF_RESUME_SCHEDULED)
  let server = sockData.server
  let socket = s
  let key = socketKey(s)
  let generation = sockData.generation
  let ssl = server.ssl.toInt
  server.deferPre(proc() =
    if socket == nil:
      return
    if server.socketKeyWasClosed(key):
      return
    if us_socket_is_closed(ssl, socket) != 0 or us_socket_is_shut_down(ssl, socket) != 0:
      return
    let refSock = socketDataFor(ssl, socket)
    if refSock == nil or refSock.magic != SocketDataMagic or refSock.generation != generation:
      return
    refSock.clearFlag(SDF_RESUME_SCHEDULED)
    if refSock.hasFlag(SDF_READ_PAUSED) or refSock.buffer.len <= refSock.bufferStart:
      return
    discard onSocketData(socket, nil, 0)
  )

proc schedulePendingHttpFlush(sockData: ptr SocketData, s: UsSocketPtr) {.inline.} =
  if sockData == nil or sockData.server == nil or s == nil or sockData.hasFlag(SDF_HTTP_FLUSH_SCHEDULED):
    return
  sockData.setFlag(SDF_HTTP_FLUSH_SCHEDULED)
  let server = sockData.server
  let socket = s
  let key = socketKey(s)
  let generation = sockData.generation
  let ssl = server.ssl.toInt
  server.deferPre(proc() =
    if socket == nil:
      return
    if server.socketKeyWasClosed(key):
      return
    if us_socket_is_closed(ssl, socket) != 0 or us_socket_is_shut_down(ssl, socket) != 0:
      return
    let refSock = socketDataFor(ssl, socket)
    if refSock == nil or refSock.magic != SocketDataMagic or refSock.generation != generation:
      return
    refSock.clearFlag(SDF_HTTP_FLUSH_SCHEDULED)
    if refSock.hasFlag(SDF_IS_WEBSOCKET) or
       (refSock.pendingIsEmpty() and refSock.sendBufferRemaining() == 0):
      return
    flushSendBuffer(refSock, ssl, socket)
    flushPendingResponses(refSock, socket)
    flushSendBuffer(refSock, ssl, socket)
    closeSocketIfPending(refSock, socket)
  )

proc scheduleWsFlush(sockData: ptr SocketData, s: UsSocketPtr) {.inline.} =
  if sockData == nil or sockData.server == nil or s == nil or sockData.hasFlag(SDF_WS_FLUSH_SCHEDULED):
    return
  sockData.setFlag(SDF_WS_FLUSH_SCHEDULED)
  let server = sockData.server
  let socket = s
  let key = socketKey(s)
  let generation = sockData.generation
  let ssl = server.ssl.toInt
  server.deferPre(proc() =
    if socket == nil:
      return
    if server.socketKeyWasClosed(key):
      return
    if us_socket_is_closed(ssl, socket) != 0 or us_socket_is_shut_down(ssl, socket) != 0:
      return
    let refSock = socketDataFor(ssl, socket)
    if refSock == nil or refSock.magic != SocketDataMagic or refSock.generation != generation:
      return
    refSock.clearFlag(SDF_WS_FLUSH_SCHEDULED)
    if not refSock.hasFlag(SDF_IS_WEBSOCKET):
      return
    refSock.flushWsQueuedFrames(socket)
    closeSocketIfPending(refSock, socket)
  )

proc flushPendingResponses(sockData: ptr SocketData, s: UsSocketPtr) =
  if sockData == nil or s == nil or sockData.server == nil:
    return
  let server = sockData.server
  let ssl = server.ssl.toInt
  if us_socket_is_closed(ssl, s) != 0 or us_socket_is_shut_down(ssl, s) != 0:
    return
  let writeIterationsBudget = sockData.writeBudgetIterationsFor()
  let writeBytesBudget = sockData.writeBudgetBytesFor()
  var flushIterations = 0
  var flushBytes = 0'i64

  while true:
    if sockData.pendingIsEmpty():
      break
    if flushIterations >= writeIterationsBudget or
       flushBytes >= writeBytesBudget or
       server.writeLoopBudgetExhausted():
      sockData.schedulePendingHttpFlush(s)
      return

    let headIdx = sockData.pendingStart
    if headIdx >= sockData.pendingUsed.len or not sockData.pendingUsed[headIdx]:
      break

    if sockData.pendingSlots[headIdx].canCoalesceQueuedResponse() and
       sockData.contiguousPendingReadyCount(2) >= 2:
      let includedCount = buildCoalescedWriteBuffer(sockData)
      if includedCount > 1 and sockData.coalesceBuffer.len > 0:
        let written = bufferSocketWrite(
          sockData, ssl, s,
          sockData.coalesceBuffer.cstring,
          sockData.coalesceBuffer.len
        )
        server.emitAfterWrite(written, true, false)
        sockData.onQueuedBytesWritten(int64(written))
        server.consumeLoopWriteBudget(int64(written))
        inc flushIterations
        flushBytes += int64(written)

        var remaining = written
        var offset = 0
        while offset < includedCount:
          let idx = sockData.pendingPhysicalIndex(offset)
          let headerLen = sockData.pendingSlots[idx].header.len
          let currentSize = headerLen + sockData.pendingSlots[idx].body.len
          remaining -= currentSize
          sockData.pendingSlots[idx].applyFixedWriteProgress(currentSize, headerLen)
          let closeAfterWrite = sockData.pendingSlots[idx].closeAfterWrite
          dec sockData.pendingActiveCount
          sockData.pendingSlots[idx].closeQueuedFile()
          sockData.clearPendingSlot(idx)
          inc sockData.nextWriteSeq
          if closeAfterWrite:
            sockData.advancePendingHead()
            sockData.setFlag(SDF_PENDING_CLOSE)
            return
          inc offset

        sockData.advancePendingHead()
        continue

    var wrote = 0'i64
    let done = writeQueuedResponse(sockData, ssl, s, sockData.pendingSlots[headIdx], wrote)
    if wrote > 0:
      server.emitAfterWrite(int(wrote), true, false)
      sockData.onQueuedBytesWritten(wrote)
      server.consumeLoopWriteBudget(wrote)
      inc flushIterations
      flushBytes += wrote
    if done:
      let closeAfterWrite = sockData.pendingSlots[headIdx].closeAfterWrite
      if sockData.pendingActiveCount > 0:
        dec sockData.pendingActiveCount
      sockData.pendingSlots[headIdx].closeQueuedFile()
      sockData.clearPendingSlot(headIdx)
      inc sockData.nextWriteSeq
      sockData.advancePendingHead()
      if closeAfterWrite:
        sockData.setFlag(SDF_PENDING_CLOSE)
        return
    else:
      if sockData.pendingSlots[headIdx].hardFailure:
        sockData.setFlag(SDF_PENDING_CLOSE)
        return
      if wrote > 0 and sockData.pendingSlots[headIdx].isStreamBody:
        # Stream responses may write header/chunk progress without reaching a terminal
        # state. Keep draining buffered chunks in this flush pass to avoid stalling until
        # another writable edge that may never arrive.
        if queuedRemainingBytes(sockData.pendingSlots[headIdx]) > 0:
          continue
      return

## Write a fully prepared header and body response, preserving pipelined socket ordering
proc sendPreparedResponse*(res: HttpResponse, header, body: sink string, closeAfterWrite: bool = false) =
  res.assertResponseLoopAffinity("sendPreparedResponse")
  let preSockData =
    if res.socket != nil:
      socketDataFor(res.ssl, res.socket)
    else:
      nil
  if preSockData != nil and preSockData.server != nil:
    preSockData.server.emitBeforeHeaders(res.requestRef, res)
    appendPreparedNativeHeaders(header, res)
  if res.socket == nil:
    res.capturedHeader = header
    res.capturedBody = body
    res.capturedRaw = header & body
    res.headersSent = true
    res.bodySent = true
    return

  let sockData = preSockData
  let totalBytes = header.len + body.len
  let payloadTotal = uint64(body.len)
  res.tryEndActive = false
  res.tryEndTotal = payloadTotal
  res.tryEndQueued = payloadTotal
  res.tryEndOffset = 0
  if sockData != nil and sockData.server != nil:
    sockData.server.emitBeforeWrite(totalBytes, false)
  if sockData == nil or sockData.server == nil:
    let written = writeFallbackDirectAndMaybeClose(
      nil,
      res.ssl,
      res.socket,
      header,
      body,
      "send_prepared_raw_fallback_short_write"
    )
    if sockData != nil and sockData.server != nil:
      sockData.server.emitAfterWrite(written, written >= 0, false)
    if closeAfterWrite and written >= totalBytes:
      discard closeSocketTracked(nil, res.ssl, res.socket, "send_prepared_raw_fallback_close_after_write")
    return

  if res.requestSeq < sockData.nextWriteSeq:
    return

  # Fast path: no backlog and this response is next in order.
  if res.requestSeq == sockData.nextWriteSeq and sockData.pendingIsEmpty() and sockData.shouldAutoFlush():
    let wrote = writeDirect(sockData.server, res.ssl, res.socket, header, body)
    if wrote > 0:
      sockData.server.emitAfterWrite(wrote, true, false)
    else:
      sockData.server.emitAfterWrite(0, false, false)
    if wrote >= totalBytes:
      res.tryEndOffset = payloadTotal
      inc sockData.nextWriteSeq
      if closeAfterWrite:
        sockData.setFlag(SDF_PENDING_CLOSE)
      return
    var queued = QueuedResponse(
      header: header,
      body: body,
      headerPos: 0,
      bodyPos: 0,
      isFileBody: false,
      fileFd: -1,
      fileOffset: 0.Off,
      fileRemaining: 0.Off,
      closeAfterWrite: closeAfterWrite,
      isStreamBody: false,
      streamOpen: false,
      hasTryEnd: true,
      tryEndOffset: 0,
      tryEndTotal: payloadTotal,
      writableHandler: res.writableHandler
    )
    if wrote > 0:
      queued.applyFixedWriteProgress(wrote, header.len)
    res.tryEndOffset = queued.tryEndOffset
    if closeAfterWrite:
      sockData.setFlag(SDF_PENDING_CLOSE)
    if not sockData.enqueuePendingResponse(res.requestSeq, queued):
      sockData.server.emitServerError("enqueuePendingResponse failed in sendPreparedResponse")
      discard closeSocketTracked(sockData.server, res.ssl, res.socket, "send_prepared_enqueue_failure_fast_path")
      return
    if sockData.shouldAutoFlush():
      flushPendingResponses(sockData, res.socket)
    else:
      registerPendingFlush(sockData, res.socket)
    return

  var queued = QueuedResponse(
    header: header,
    body: body,
    headerPos: 0,
    bodyPos: 0,
    isFileBody: false,
    fileFd: -1,
    fileOffset: 0.Off,
    fileRemaining: 0.Off,
    closeAfterWrite: closeAfterWrite,
    isStreamBody: false,
    streamOpen: false,
    hasTryEnd: true,
    tryEndOffset: 0,
    tryEndTotal: payloadTotal,
    writableHandler: res.writableHandler
  )

  if not sockData.enqueuePendingResponse(res.requestSeq, queued):
    sockData.server.emitServerError("enqueuePendingResponse failed in sendPreparedResponse")
    discard closeSocketTracked(sockData.server, res.ssl, res.socket, "send_prepared_enqueue_failure")
    return
  if sockData.shouldAutoFlush():
    flushPendingResponses(sockData, res.socket)
  else:
    registerPendingFlush(sockData, res.socket)

## Write a prepared header with a multi-fragment body without an extra full-body copy
proc sendPreparedResponseFragments*(
  res: HttpResponse,
  header: sink string,
  fragments: openArray[string],
  totalBodyBytes: int,
  closeAfterWrite: bool = false
) =
  res.assertResponseLoopAffinity("sendPreparedResponseFragments")
  if totalBodyBytes <= 0 or fragments.len == 0:
    res.sendPreparedResponse(header, "", closeAfterWrite)
    return

  if res.socket == nil or res.ssl != 0:
    let body = flattenFragments(fragments, totalBodyBytes)
    res.sendPreparedResponse(header, body, closeAfterWrite)
    return

  let sockData = socketDataFor(res.ssl, res.socket)
  let totalBytes = header.len + totalBodyBytes
  let payloadTotal = uint64(totalBodyBytes)
  res.tryEndActive = false
  res.tryEndTotal = payloadTotal
  res.tryEndQueued = payloadTotal
  res.tryEndOffset = 0

  if sockData != nil and sockData.server != nil:
    sockData.server.emitBeforeHeaders(res.requestRef, res)
    sockData.server.emitBeforeWrite(totalBytes, false)

  if sockData == nil or sockData.server == nil:
    let wrote = writeDirectFragments(nil, res.ssl, res.socket, header, fragments, totalBodyBytes)
    if sockData != nil and sockData.server != nil:
      sockData.server.emitAfterWrite(wrote, wrote >= 0, false)
    if closeAfterWrite and wrote >= totalBytes:
      discard closeSocketTracked(nil, res.ssl, res.socket, "send_prepared_fragments_fallback_close_after_write")
    return

  if res.requestSeq < sockData.nextWriteSeq:
    return

  if res.requestSeq == sockData.nextWriteSeq and sockData.pendingIsEmpty() and sockData.shouldAutoFlush():
    let wrote = writeDirectFragments(sockData.server, res.ssl, res.socket, header, fragments, totalBodyBytes)
    if wrote > 0:
      sockData.server.emitAfterWrite(wrote, true, false)
    else:
      sockData.server.emitAfterWrite(0, false, false)
    if wrote >= totalBytes:
      res.tryEndOffset = payloadTotal
      inc sockData.nextWriteSeq
      if closeAfterWrite:
        sockData.setFlag(SDF_PENDING_CLOSE)
      return

    let body = flattenFragments(fragments, totalBodyBytes)
    var queued = QueuedResponse(
      header: header,
      body: body,
      headerPos: 0,
      bodyPos: 0,
      isFileBody: false,
      fileFd: -1,
      fileOffset: 0.Off,
      fileRemaining: 0.Off,
      closeAfterWrite: closeAfterWrite,
      isStreamBody: false,
      streamOpen: false,
      hasTryEnd: true,
      tryEndOffset: 0,
      tryEndTotal: payloadTotal,
      writableHandler: res.writableHandler
    )
    if wrote > 0:
      queued.applyFixedWriteProgress(wrote, header.len)
    res.tryEndOffset = queued.tryEndOffset
    if closeAfterWrite:
      sockData.setFlag(SDF_PENDING_CLOSE)
    if not sockData.enqueuePendingResponse(res.requestSeq, queued):
      sockData.server.emitServerError("enqueuePendingResponse failed in sendPreparedResponseFragments")
      discard closeSocketTracked(sockData.server, res.ssl, res.socket, "send_prepared_fragments_enqueue_failure_fast_path")
      return
    if sockData.shouldAutoFlush():
      flushPendingResponses(sockData, res.socket)
    else:
      registerPendingFlush(sockData, res.socket)
    return

  let body = flattenFragments(fragments, totalBodyBytes)
  var queued = QueuedResponse(
    header: header,
    body: body,
    headerPos: 0,
    bodyPos: 0,
    isFileBody: false,
    fileFd: -1,
    fileOffset: 0.Off,
    fileRemaining: 0.Off,
    closeAfterWrite: closeAfterWrite,
    isStreamBody: false,
    streamOpen: false,
    hasTryEnd: true,
    tryEndOffset: 0,
    tryEndTotal: payloadTotal,
    writableHandler: res.writableHandler
  )

  if not sockData.enqueuePendingResponse(res.requestSeq, queued):
    sockData.server.emitServerError("enqueuePendingResponse failed in sendPreparedResponseFragments")
    discard closeSocketTracked(sockData.server, res.ssl, res.socket, "send_prepared_fragments_enqueue_failure")
    return
  if sockData.shouldAutoFlush():
    flushPendingResponses(sockData, res.socket)
  else:
    registerPendingFlush(sockData, res.socket)

## Write a prepared header with a raw pointer body, copying only when the socket is unavailable
proc sendPreparedResponseRawBody*(
  res: HttpResponse,
  header: sink string,
  bodyPtr: pointer,
  bodyLen: int,
  closeAfterWrite: bool = false
) =
  res.assertResponseLoopAffinity("sendPreparedResponseRawBody")
  if bodyPtr == nil or bodyLen <= 0:
    res.sendPreparedResponse(header, "", closeAfterWrite)
    return

  if res.socket == nil:
    var bodyCopy = newString(bodyLen)
    copyMem(addr bodyCopy[0], bodyPtr, bodyLen)
    res.capturedHeader = header
    res.capturedBody = bodyCopy
    res.capturedRaw = header & bodyCopy
    res.headersSent = true
    res.bodySent = true
    return

  let sockData = socketDataFor(res.ssl, res.socket)
  let totalBytes = header.len + bodyLen
  let payloadTotal = uint64(bodyLen)
  res.tryEndActive = false
  res.tryEndTotal = payloadTotal
  res.tryEndQueued = payloadTotal
  res.tryEndOffset = 0
  if sockData != nil and sockData.server != nil:
    sockData.server.emitBeforeHeaders(res.requestRef, res)
    sockData.server.emitBeforeWrite(totalBytes, false)

  if sockData == nil or sockData.server == nil:
    var bodyCopy = newString(bodyLen)
    copyMem(addr bodyCopy[0], bodyPtr, bodyLen)
    let written = writeFallbackDirectAndMaybeClose(
      nil, res.ssl, res.socket, header, bodyCopy,
      "send_prepared_raw_body_fallback"
    )
    if sockData != nil and sockData.server != nil:
      sockData.server.emitAfterWrite(written, written >= 0, false)
    if closeAfterWrite and written >= totalBytes:
      discard closeSocketTracked(nil, res.ssl, res.socket, "send_prepared_raw_body_fallback_close")
    return

  if res.requestSeq < sockData.nextWriteSeq:
    return

  if res.requestSeq == sockData.nextWriteSeq and sockData.pendingIsEmpty() and sockData.shouldAutoFlush():
    let wrote = int(us_socket_write2(
      res.ssl, res.socket,
      cast[cstring](unsafeAddr header[0]), header.len.cint,
      cast[cstring](bodyPtr), bodyLen.cint
    ))
    if wrote > 0:
      sockData.server.emitAfterWrite(wrote, true, false)
    else:
      sockData.server.emitAfterWrite(0, false, false)
    if wrote >= totalBytes:
      res.tryEndOffset = payloadTotal
      inc sockData.nextWriteSeq
      if closeAfterWrite:
        sockData.setFlag(SDF_PENDING_CLOSE)
      return
    var bodyCopy = newString(bodyLen)
    copyMem(addr bodyCopy[0], bodyPtr, bodyLen)
    var queued = QueuedResponse(
      header: header,
      body: bodyCopy,
      headerPos: 0, bodyPos: 0,
      isFileBody: false, fileFd: -1,
      fileOffset: 0.Off, fileRemaining: 0.Off,
      closeAfterWrite: closeAfterWrite,
      isStreamBody: false, streamOpen: false,
      hasTryEnd: true,
      tryEndOffset: 0, tryEndTotal: payloadTotal,
      writableHandler: res.writableHandler
    )
    if wrote > 0:
      queued.applyFixedWriteProgress(wrote, header.len)
    res.tryEndOffset = queued.tryEndOffset
    if closeAfterWrite:
      sockData.setFlag(SDF_PENDING_CLOSE)
    if not sockData.enqueuePendingResponse(res.requestSeq, queued):
      sockData.server.emitServerError("enqueuePendingResponse failed in sendPreparedResponseRawBody")
      discard closeSocketTracked(sockData.server, res.ssl, res.socket, "send_prepared_raw_body_enqueue_failure_fast")
      return
    if sockData.shouldAutoFlush():
      flushPendingResponses(sockData, res.socket)
    else:
      registerPendingFlush(sockData, res.socket)
    return

  var bodyCopy = newString(bodyLen)
  copyMem(addr bodyCopy[0], bodyPtr, bodyLen)
  var queued = QueuedResponse(
    header: header,
    body: bodyCopy,
    headerPos: 0, bodyPos: 0,
    isFileBody: false, fileFd: -1,
    fileOffset: 0.Off, fileRemaining: 0.Off,
    closeAfterWrite: closeAfterWrite,
    isStreamBody: false, streamOpen: false,
    hasTryEnd: true,
    tryEndOffset: 0, tryEndTotal: payloadTotal,
    writableHandler: res.writableHandler
  )
  if not sockData.enqueuePendingResponse(res.requestSeq, queued):
    sockData.server.emitServerError("enqueuePendingResponse failed in sendPreparedResponseRawBody")
    discard closeSocketTracked(sockData.server, res.ssl, res.socket, "send_prepared_raw_body_enqueue_failure")
    return
  if sockData.shouldAutoFlush():
    flushPendingResponses(sockData, res.socket)
  else:
    registerPendingFlush(sockData, res.socket)

## Queue a prepared header plus a file-backed body and report whether the sendfile fast path was used
proc sendFilePreparedResponse*(
  res: HttpResponse,
  header: string,
  filePath: string,
  fileSize: int64,
  closeAfterWrite: bool = false
): bool =
  ## Queue or send header + file body while preserving pipelined ordering.
  when not (defined(macosx) or defined(linux)):
    return false
  if res.socket == nil or res.ssl != 0 or fileSize < 0:
    return false

  let fd = open(filePath.cstring, O_RDONLY)
  if fd < 0:
    return false

  let payloadTotal = uint64(fileSize)
  res.tryEndActive = false
  res.tryEndTotal = payloadTotal
  res.tryEndQueued = payloadTotal
  res.tryEndOffset = 0
  let sockData = socketDataFor(res.ssl, res.socket)
  if sockData != nil and sockData.server != nil:
    sockData.server.emitBeforeHeaders(res.requestRef, res)
    let totalBytes =
      if fileSize > int64(high(int) - header.len):
        high(int)
      else:
        header.len + int(fileSize)
    sockData.server.emitBeforeWrite(totalBytes, false)
  if sockData == nil or sockData.server == nil:
    # No queue context: best-effort direct header send then close fallback.
    let wrote = writeFallbackDirectAndMaybeClose(
      nil,
      res.ssl,
      res.socket,
      header,
      "",
      "sendfile_raw_fallback_header_short_write"
    )
    if sockData != nil and sockData.server != nil:
      sockData.server.emitAfterWrite(wrote, wrote >= 0, false)
    discard close(fd)
    if closeAfterWrite and wrote >= header.len:
      discard closeSocketTracked(nil, res.ssl, res.socket, "sendfile_raw_fallback_close_after_write")
    return false

  if res.requestSeq < sockData.nextWriteSeq:
    discard close(fd)
    return false

  let fileTotal =
    if fileSize > 0:
      uint64(fileSize)
    else:
      0'u64
  res.tryEndOffset = 0
  res.tryEndQueued = fileTotal
  res.tryEndTotal = fileTotal

  var queued = initQueuedSendFileResponse(
    header,
    fd,
    fileSize,
    closeAfterWrite,
    res.writableHandler
  )

  if res.requestSeq == sockData.nextWriteSeq and sockData.pendingIsEmpty() and sockData.shouldAutoFlush():
    var wrote = 0'i64
    let done = writeQueuedResponse(sockData, res.ssl, res.socket, queued, wrote)
    res.tryEndOffset = queued.tryEndOffset
    sockData.server.emitAfterWrite(int(wrote), done or wrote > 0, false)
    if done:
      queued.closeQueuedFile()
      inc sockData.nextWriteSeq
      if closeAfterWrite:
        sockData.setFlag(SDF_PENDING_CLOSE)
      return true
    if closeAfterWrite:
      sockData.setFlag(SDF_PENDING_CLOSE)
    if not sockData.enqueuePendingResponse(res.requestSeq, queued):
      sockData.server.emitServerError("enqueuePendingResponse failed in sendFilePreparedResponse")
      queued.closeQueuedFile()
      return false
    if sockData.shouldAutoFlush():
      flushPendingResponses(sockData, res.socket)
    else:
      registerPendingFlush(sockData, res.socket)
    return true

  if not sockData.enqueuePendingResponse(res.requestSeq, queued):
    sockData.server.emitServerError("enqueuePendingResponse failed in sendFilePreparedResponse")
    queued.closeQueuedFile()
    return false
  if sockData.shouldAutoFlush():
    flushPendingResponses(sockData, res.socket)
  else:
    registerPendingFlush(sockData, res.socket)
  true

proc sliceBytesToString(data: openArray[byte], startPos, endPos: int): string {.inline.} =
  let n = endPos - startPos
  if n <= 0:
    return ""
  result = newStringUninit(n)
  copyMem(addr result[0], unsafeAddr data[startPos], n)

proc isTokenCharByte(b: byte): bool {.inline.} =
  TokenCharTable[b]

proc loadU32(data: openArray[byte], pos: int): uint32 {.inline.} =
  copyMem(addr result, unsafeAddr data[pos], 4)

proc loadU64(data: openArray[byte], pos: int): uint64 {.inline.} =
  copyMem(addr result, unsafeAddr data[pos], 8)

const
  MethodGetU32  = 0x00544547'u32
  MethodPutU32  = 0x00545550'u32
  MethodPostU32 = 0x54534F50'u32
  MethodHeadU32 = 0x44414548'u32
  MethodPatchU64  = 0x0000004843544150'u64
  MethodTraceU64  = 0x0000004543415254'u64
  MethodDeleteU64 = 0x00004554454C4544'u64
  MethodOptionsU64 = 0x00534E4F4954504F'u64
  MethodConnectU64 = 0x005443454E4E4F43'u64
  Mask3ByteU32 = 0x00FFFFFF'u32
  Mask5ByteU64 = 0x000000FFFFFFFFFF'u64
  Mask6ByteU64 = 0x0000FFFFFFFFFFFF'u64
  Mask7ByteU64 = 0x00FFFFFFFFFFFFFF'u64
  HttpVersion11U64 = 0x312E312F50545448'u64
  HttpVersion10U64 = 0x302E312F50545448'u64

proc parseMethodToken(
  data: openArray[byte],
  startPos,
  endPos: int,
  methodOut: var HttpMethod,
  isKnownMethod: var bool
): bool {.inline.} =
  let tokenLen = endPos - startPos
  if tokenLen <= 0:
    return false
  isKnownMethod = true
  if tokenLen <= 4 and startPos + 4 <= data.len:
    let w = loadU32(data, startPos)
    case tokenLen
    of 3:
      let masked = w and Mask3ByteU32
      if masked == MethodGetU32:
        methodOut = hmGet
        return true
      if masked == MethodPutU32:
        methodOut = hmPut
        return true
    of 4:
      if w == MethodPostU32:
        methodOut = hmPost
        return true
      if w == MethodHeadU32:
        methodOut = hmHead
        return true
    else:
      discard
  elif tokenLen <= 8 and startPos + 8 <= data.len:
    let w = loadU64(data, startPos)
    case tokenLen
    of 5:
      let masked = w and Mask5ByteU64
      if masked == MethodPatchU64:
        methodOut = hmPatch
        return true
      if masked == MethodTraceU64:
        methodOut = hmTrace
        return true
    of 6:
      let masked = w and Mask6ByteU64
      if masked == MethodDeleteU64:
        methodOut = hmDelete
        return true
    of 7:
      let masked = w and Mask7ByteU64
      if masked == MethodOptionsU64:
        methodOut = hmOptions
        return true
      if masked == MethodConnectU64:
        methodOut = hmConnect
        return true
    else:
      discard
  for i in startPos..<endPos:
    if not isTokenCharByte(data[i]):
      return false
  isKnownMethod = false
  true

const
  AsciiLowerMask32 = 0x20202020'u32
  AsciiLowerMask64 = 0x2020202020202020'u64

proc equalsAsciiNoCase(data: openArray[byte], startPos, endPos: int, literal: string): bool {.inline.} =
  let n = endPos - startPos
  if n != literal.len:
    return false
  if n <= 0:
    return true

  var i = 0
  let dataBase = cast[uint](unsafeAddr data[startPos])
  let literalBase = cast[uint](unsafeAddr literal[0])

  while i + 8 <= n:
    var dataWord: uint64
    var literalWord: uint64
    copyMem(addr dataWord, cast[pointer](dataBase + uint(i)), 8)
    copyMem(addr literalWord, cast[pointer](literalBase + uint(i)), 8)
    if (dataWord or AsciiLowerMask64) != literalWord:
      return false
    i += 8

  if i + 4 <= n:
    var dataWord: uint32
    var literalWord: uint32
    copyMem(addr dataWord, cast[pointer](dataBase + uint(i)), 4)
    copyMem(addr literalWord, cast[pointer](literalBase + uint(i)), 4)
    if (dataWord or AsciiLowerMask32) != literalWord:
      return false
    i += 4

  while i < n:
    if char(ToLowerTable[data[startPos + i]]) != literal[i]:
      return false
    inc i
  true

proc swarHasZeroByte(v: uint64): bool {.inline.} =
  ((v - 0x0101010101010101'u64) and (not v) and 0x8080808080808080'u64) != 0

proc swarHasByte(v: uint64, needle: byte): bool {.inline.} =
  let broadcast = needle.uint64 * 0x0101010101010101'u64
  swarHasZeroByte(v xor broadcast)

when defined(aarch64) or defined(arm64):
  {.emit: """
  #include <arm_neon.h>
  
  static inline int neon_find_byte(const unsigned char* data, int startPos, int endPos, unsigned char needle) {
    int i = startPos;
    uint8x16_t vNeedle = vdupq_n_u8(needle);
    while (i + 16 <= endPos) {
      uint8x16_t chunk = vld1q_u8(data + i);
      uint8x16_t cmp = vceqq_u8(chunk, vNeedle);
      if (vmaxvq_u8(cmp) != 0) {
        for (int j = 0; j < 16; j++) {
          if (i + j < endPos && data[i + j] == needle) return i + j;
        }
      }
      i += 16;
    }
    while (i < endPos) {
      if (data[i] == needle) return i;
      i++;
    }
    return -1;
  }
  
  static inline int neon_find_crlf(const unsigned char* data, int startPos, int n) {
    int i = startPos;
    uint8x16_t vCr = vdupq_n_u8(0x0D);
    while (i + 16 <= n) {
      uint8x16_t chunk = vld1q_u8(data + i);
      uint8x16_t cmp = vceqq_u8(chunk, vCr);
      if (vmaxvq_u8(cmp) != 0) {
        for (int j = 0; j < 16; j++) {
          if (i + j < n && data[i + j] == 0x0D && data[i + j + 1] == 0x0A) return i + j;
        }
      }
      i += 16;
    }
    while (i < n) {
      if (data[i] == 0x0D && data[i + 1] == 0x0A) return i;
      i++;
    }
    return -1;
  }
  
  static inline int neon_find_header_terminator(const unsigned char* data, int startPos, int n) {
    int i = startPos;
    uint8x16_t vCr = vdupq_n_u8(0x0D);
    while (i + 16 <= n) {
      uint8x16_t chunk = vld1q_u8(data + i);
      uint8x16_t cmp = vceqq_u8(chunk, vCr);
      if (vmaxvq_u8(cmp) != 0) {
        for (int j = 0; j < 16; j++) {
          if (i + j < n &&
              data[i + j] == 0x0D && data[i + j + 1] == 0x0A &&
              data[i + j + 2] == 0x0D && data[i + j + 3] == 0x0A) return i + j;
        }
      }
      i += 16;
    }
    while (i < n) {
      if (data[i] == 0x0D && data[i + 1] == 0x0A &&
          data[i + 2] == 0x0D && data[i + 3] == 0x0A) return i;
      i++;
    }
    return -1;
  }
  """.}

  proc neonFindByte(data: ptr UncheckedArray[byte], startPos, endPos: int, needle: byte): int {.importc: "neon_find_byte", nodecl.}
  proc neonFindCrlf(data: ptr UncheckedArray[byte], startPos, n: int): int {.importc: "neon_find_crlf", nodecl.}
  proc neonFindHeaderTerminator(data: ptr UncheckedArray[byte], startPos, n: int): int {.importc: "neon_find_header_terminator", nodecl.}

when defined(amd64):
  {.emit: """
  #include <emmintrin.h>

  static inline int sse2_find_byte(const unsigned char* data, int startPos, int endPos, unsigned char needle) {
    int i = startPos;
    __m128i vNeedle = _mm_set1_epi8((char)needle);
    while (i + 16 <= endPos) {
      __m128i chunk = _mm_loadu_si128((const __m128i*)(data + i));
      __m128i cmp = _mm_cmpeq_epi8(chunk, vNeedle);
      int mask = _mm_movemask_epi8(cmp);
      if (mask != 0) {
        int offset = __builtin_ctz(mask);
        if (i + offset < endPos) return i + offset;
      }
      i += 16;
    }
    while (i < endPos) {
      if (data[i] == needle) return i;
      i++;
    }
    return -1;
  }

  static inline int sse2_find_crlf(const unsigned char* data, int startPos, int n) {
    int i = startPos;
    __m128i vCr = _mm_set1_epi8(0x0D);
    while (i + 16 <= n) {
      __m128i chunk = _mm_loadu_si128((const __m128i*)(data + i));
      __m128i cmp = _mm_cmpeq_epi8(chunk, vCr);
      int mask = _mm_movemask_epi8(cmp);
      while (mask != 0) {
        int offset = __builtin_ctz(mask);
        if (i + offset < n && data[i + offset + 1] == 0x0A) return i + offset;
        mask &= mask - 1;
      }
      i += 16;
    }
    while (i < n) {
      if (data[i] == 0x0D && data[i + 1] == 0x0A) return i;
      i++;
    }
    return -1;
  }

  static inline int sse2_find_header_terminator(const unsigned char* data, int startPos, int n) {
    int i = startPos;
    __m128i vCr = _mm_set1_epi8(0x0D);
    while (i + 16 <= n) {
      __m128i chunk = _mm_loadu_si128((const __m128i*)(data + i));
      __m128i cmp = _mm_cmpeq_epi8(chunk, vCr);
      int mask = _mm_movemask_epi8(cmp);
      while (mask != 0) {
        int offset = __builtin_ctz(mask);
        if (i + offset < n &&
            data[i + offset + 1] == 0x0A &&
            data[i + offset + 2] == 0x0D &&
            data[i + offset + 3] == 0x0A) return i + offset;
        mask &= mask - 1;
      }
      i += 16;
    }
    while (i < n) {
      if (data[i] == 0x0D && data[i + 1] == 0x0A &&
          data[i + 2] == 0x0D && data[i + 3] == 0x0A) return i;
      i++;
    }
    return -1;
  }
  """.}

  proc sse2FindByte(data: ptr UncheckedArray[byte], startPos, endPos: int, needle: byte): int {.importc: "sse2_find_byte", nodecl.}
  proc sse2FindCrlf(data: ptr UncheckedArray[byte], startPos, n: int): int {.importc: "sse2_find_crlf", nodecl.}
  proc sse2FindHeaderTerminator(data: ptr UncheckedArray[byte], startPos, n: int): int {.importc: "sse2_find_header_terminator", nodecl.}

proc swarFindByte(data: openArray[byte], startPos, endPos: int, needle: byte): int {.inline.} =
  when defined(aarch64) or defined(arm64):
    if endPos - startPos >= 16:
      return neonFindByte(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), startPos, endPos, needle)
  elif defined(amd64):
    if endPos - startPos >= 16:
      return sse2FindByte(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), startPos, endPos, needle)
  var i = startPos
  when sizeof(pointer) >= 8:
    let baseAddr = cast[uint](unsafeAddr data[0])
    while i + 8 <= endPos:
      var word: uint64
      copyMem(addr word, cast[pointer](baseAddr + uint(i)), 8)
      if swarHasByte(word, needle):
        for j in 0 .. 7:
          if i + j < endPos and data[i + j] == needle:
            return i + j
      i += 8
  while i < endPos:
    if data[i] == needle:
      return i
    inc i
  -1

proc findCrlfBounded(data: openArray[byte], startPos, endPos: int): int {.inline.} =
  var i = startPos
  var n = endPos
  if n > data.len:
    n = data.len
  n -= 1
  when defined(aarch64) or defined(arm64):
    if n - i >= 16:
      return neonFindCrlf(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), i, n)
  elif defined(amd64):
    if n - i >= 16:
      return sse2FindCrlf(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), i, n)
  when sizeof(pointer) >= 8:
    let baseAddr = cast[uint](unsafeAddr data[0])
    while i + 8 <= n:
      var word: uint64
      copyMem(addr word, cast[pointer](baseAddr + uint(i)), 8)
      if swarHasByte(word, byte('\r')):
        for j in 0 .. 7:
          if i + j < n and data[i + j] == byte('\r') and data[i + j + 1] == byte('\n'):
            return i + j
      i += 8
  while i < n:
    if data[i] == byte('\r') and data[i + 1] == byte('\n'):
      return i
    inc i
  -1

proc findCrlf(data: openArray[byte], startPos: int): int {.inline, used.} =
  findCrlfBounded(data, startPos, data.len)

proc findHeaderTerminator(data: openArray[byte], startPos, endPos: int): int {.inline.} =
  var i = startPos
  var n = endPos
  if n > data.len:
    n = data.len
  n -= 3
  if n <= i:
    return -1
  when defined(aarch64) or defined(arm64):
    if n - i >= 16:
      return neonFindHeaderTerminator(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), i, n)
  elif defined(amd64):
    if n - i >= 16:
      return sse2FindHeaderTerminator(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), i, n)
  when sizeof(pointer) >= 8:
    let baseAddr = cast[uint](unsafeAddr data[0])
    while i + 8 <= n:
      var word: uint64
      copyMem(addr word, cast[pointer](baseAddr + uint(i)), 8)
      if swarHasByte(word, byte('\r')):
        for j in 0 .. 7:
          if i + j < n and
             data[i + j] == byte('\r') and data[i + j + 1] == byte('\n') and
             data[i + j + 2] == byte('\r') and data[i + j + 3] == byte('\n'):
            return i + j
      i += 8
  while i < n:
    if data[i] == byte('\r') and data[i + 1] == byte('\n') and
       data[i + 2] == byte('\r') and data[i + 3] == byte('\n'):
      return i
    inc i
  -1

proc parseSingleContentLengthValue(data: openArray[byte], startPos, endPos: int, contentLength: var int): bool {.inline.} =
  var i = startPos
  while i < endPos and (data[i] == byte(' ') or data[i] == byte('\t')):
    inc i
  if i >= endPos:
    return false

  var last = endPos - 1
  while last >= i and (data[last] == byte(' ') or data[last] == byte('\t')):
    dec last
  if last < i:
    return false

  let digitCount = last - i + 1
  if digitCount > 18:
    return false

  if digitCount > 1 and data[i] == byte('0'):
    return false

  var parsed = 0
  var idx = i
  while idx <= last:
    let d = int(data[idx]) - ord('0')
    if d < 0 or d > 9:
      return false
    if parsed > (high(int) - d) div 10:
      return false
    parsed = parsed * 10 + d
    inc idx

  contentLength = parsed
  true

proc parseContentLengthBytes(data: openArray[byte], startPos, endPos: int, contentLength: var int): bool {.inline.} =
  var firstValue = -1
  var pos = startPos
  while pos < endPos:
    var elemEnd = pos
    while elemEnd < endPos and data[elemEnd] != byte(','):
      inc elemEnd
    var parsed = 0
    if not parseSingleContentLengthValue(data, pos, elemEnd, parsed):
      return false
    if firstValue < 0:
      firstValue = parsed
    elif parsed != firstValue:
      return false
    pos = elemEnd + 1
  if firstValue < 0:
    return false
  contentLength = firstValue
  true

proc mergeContentLengthBytes(
  data: openArray[byte],
  startPos,
  endPos: int,
  hasContentLength: var bool,
  contentLength: var int
): bool {.inline.} =
  var parsedLength = 0
  if not parseContentLengthBytes(data, startPos, endPos, parsedLength):
    return false
  if hasContentLength and parsedLength != contentLength:
    return false
  hasContentLength = true
  contentLength = parsedLength
  true

proc parseTransferEncodingBytes(
  data: openArray[byte],
  startPos,
  endPos: int,
  hasTransferEncoding: var bool,
  hasChunked: var bool,
  finalChunked: var bool,
  unsupportedCoding: var bool,
  malformedCoding: var bool
) {.inline.} =
  # RFC 9112 §6.1 and §6.3(4):
  # - chunked MUST NOT be applied more than once
  # - request TE must be reliably decodable (chunked final coding)
  hasTransferEncoding = true

  var i = startPos
  var sawAny = false
  while i < endPos:
    while i < endPos and (data[i] == byte(' ') or data[i] == byte('\t') or data[i] == byte(',')):
      inc i
    if i >= endPos:
      break
    let tokenStart = i
    while i < endPos and data[i] != byte(','):
      inc i
    var tokenEnd = i
    while tokenEnd > tokenStart and (data[tokenEnd - 1] == byte(' ') or data[tokenEnd - 1] == byte('\t')):
      dec tokenEnd
    if tokenEnd <= tokenStart:
      continue

    # strip optional transfer-coding parameters (e.g. ";q=...")
    var codingEnd = tokenStart
    while codingEnd < tokenEnd and data[codingEnd] != byte(';'):
      inc codingEnd
    var codingLast = codingEnd - 1
    while codingLast >= tokenStart and (data[codingLast] == byte(' ') or data[codingLast] == byte('\t')):
      dec codingLast
    if codingLast < tokenStart:
      malformedCoding = true
      continue

    sawAny = true
    var validToken = true
    for j in tokenStart..codingLast:
      if not isTokenCharByte(data[j]):
        validToken = false
        break
    if not validToken:
      malformedCoding = true
      finalChunked = false
      continue

    let codingLen = codingLast - tokenStart + 1
    let isChunked = codingLen == 7 and equalsAsciiNoCase(data, tokenStart, codingLast + 1, "chunked")
    if isChunked:
      if hasChunked:
        malformedCoding = true
        finalChunked = false
        continue
      hasChunked = true
      finalChunked = true
    else:
      unsupportedCoding = true
      finalChunked = false
  if not sawAny:
    malformedCoding = true
    finalChunked = false

proc parseExpectHeaderBytes(
  data: openArray[byte],
  startPos,
  endPos: int,
  has100Continue: var bool,
  unsupportedExpectation: var bool
) {.inline.} =
  # RFC 9110 §10.1.1: only standardized expectation is "100-continue".
  # Unsupported expectations are surfaced as 417 at request-parse caller.
  var i = startPos
  var sawAny = false
  while i < endPos:
    while i < endPos and (data[i] == byte(' ') or data[i] == byte('\t') or data[i] == byte(',')):
      inc i
    if i >= endPos:
      break
    let tokenStart = i
    while i < endPos and data[i] != byte(','):
      inc i
    var tokenEnd = i
    while tokenEnd > tokenStart and (data[tokenEnd - 1] == byte(' ') or data[tokenEnd - 1] == byte('\t')):
      dec tokenEnd
    if tokenEnd <= tokenStart:
      continue
    sawAny = true
    let tokenLen = tokenEnd - tokenStart
    if tokenLen == 12 and equalsAsciiNoCase(data, tokenStart, tokenEnd, "100-continue"):
      has100Continue = true
    else:
      unsupportedExpectation = true
  if not sawAny:
    unsupportedExpectation = true

proc validateHostRequirements(
  httpMajor,
  httpMinor,
  hostCount: int,
  hostHasValue: bool,
  parseStatusCode: var int
): bool {.inline.} =
  if httpMajor == 1 and httpMinor == 1:
    # RFC 9112 §3.2: HTTP/1.1 requires exactly one valid Host field.
    if hostCount != 1 or not hostHasValue:
      parseStatusCode = 400
      return false
  true

proc validateExpectRequirements(
  has100ContinueExpectation: bool,
  hasUnsupportedExpectation: bool,
  expectContinueMode: ExpectContinueMode,
  parseStatusCode: var int
): bool {.inline.} =
  if hasUnsupportedExpectation:
    parseStatusCode = 417
    return false
  if has100ContinueExpectation and expectContinueMode == ecmStrictReject:
    # RFC 9110 §10.1.1 + §15.5.18:
    # strict mode rejects expectation handling with 417.
    parseStatusCode = 417
    return false
  true

proc validateTransferFramingRequirements(
  httpMajor,
  httpMinor: int,
  hasContentLength: bool,
  hasTransferEncoding: bool,
  hasChunkedTransfer: bool,
  finalChunkedTransfer: bool,
  hasUnsupportedTransferCoding: bool,
  hasMalformedTransferCoding: bool,
  parseStatusCode: var int
): bool {.inline.} =
  if not hasTransferEncoding:
    return true

  # RFC 9112 §6.1 + §6.3:
  # - requests with TE are only accepted for HTTP/1.1
  # - malformed codings are invalid framing
  # - TE + CL ambiguity is rejected
  # - unsupported transfer-coding can be surfaced as 501
  # - chunked must be the final coding for request decoding
  if httpMajor != 1 or httpMinor == 0:
    parseStatusCode = 400
    return false
  if hasMalformedTransferCoding:
    parseStatusCode = 400
    return false
  if hasContentLength:
    parseStatusCode = 400
    return false
  if hasUnsupportedTransferCoding and not hasChunkedTransfer:
    parseStatusCode = 501
    return false
  if not hasChunkedTransfer or not finalChunkedTransfer:
    parseStatusCode = 400
    return false
  if hasUnsupportedTransferCoding:
    parseStatusCode = 501
    return false
  true

proc isChunkExtByte(b: byte): bool {.inline.} =
  ValidHeaderValueByteTable[b]

proc parseChunkSizeLine(data: openArray[byte], startPos, endPos: int, chunkSize: var int): bool {.inline.} =
  var i = startPos
  if i >= endPos:
    return false
  var hexEnd = i
  while hexEnd < endPos and data[hexEnd] != byte(';'):
    inc hexEnd
  var last = hexEnd - 1
  while last >= i and (data[last] == byte(' ') or data[last] == byte('\t')):
    dec last
  if last < i:
    return false

  let hexDigitCount = last - i + 1
  if hexDigitCount > 16:
    return false

  var parsed = 0
  var idx = i
  while idx <= last:
    let c = char(data[idx])
    var digit = -1
    if c >= '0' and c <= '9':
      digit = ord(c) - ord('0')
    elif c >= 'a' and c <= 'f':
      digit = ord(c) - ord('a') + 10
    elif c >= 'A' and c <= 'F':
      digit = ord(c) - ord('A') + 10
    else:
      return false
    if parsed > (high(int) - digit) div 16:
      return false
    parsed = parsed * 16 + digit
    inc idx

  if hexEnd < endPos:
    for j in (hexEnd + 1) ..< endPos:
      if not isChunkExtByte(data[j]):
        return false

  chunkSize = parsed
  true

proc decodeChunkedBody(
  data: openArray[byte],
  startPos: int,
  endPos: int,
  decodedBody: var string,
  consumed: var int,
  parseError: var bool,
  maxBodySize: int = DefaultMaxBodySize
): bool =
  parseError = false
  consumed = 0
  decodedBody.setLen(0)

  var pos = startPos
  while true:
    let sizeLineEnd = findCrlfBounded(data, pos, endPos)
    if sizeLineEnd < 0:
      return false

    var chunkSize = 0
    if not parseChunkSizeLine(data, pos, sizeLineEnd, chunkSize):
      parseError = true
      return false
    pos = sizeLineEnd + 2

    if chunkSize == 0:
      while true:
        let trailerLineEnd = findCrlfBounded(data, pos, endPos)
        if trailerLineEnd < 0:
          return false
        if trailerLineEnd == pos:
          consumed = trailerLineEnd + 2 - startPos
          return true

        var colonPos = swarFindByte(data, pos, trailerLineEnd, byte(':'))
        if colonPos <= pos or colonPos >= trailerLineEnd:
          parseError = true
          return false
        var trailerTokenValid = true
        for k in pos ..< colonPos:
          if not TokenCharTable[data[k]]:
            trailerTokenValid = false
            break
        if not trailerTokenValid:
          parseError = true
          return false
        var valStart = colonPos + 1
        while valStart < trailerLineEnd and (data[valStart] == byte(' ') or data[valStart] == byte('\t')):
          inc valStart
        for k in valStart ..< trailerLineEnd:
          if not ValidHeaderValueByteTable[data[k]]:
            parseError = true
            return false
        pos = trailerLineEnd + 2
    else:
      if pos > endPos:
        parseError = true
        return false
      let remaining = endPos - pos
      if remaining < 2:
        return false
      if chunkSize > remaining - 2:
        return false
      let oldLen = decodedBody.len
      if chunkSize > high(int) - oldLen:
        parseError = true
        return false
      if decodedBody.len + chunkSize > maxBodySize:
        parseError = true
        return false
      decodedBody.setLen(oldLen + chunkSize)
      if chunkSize > 0:
        copyMem(addr decodedBody[oldLen], unsafeAddr data[pos], chunkSize)
      pos += chunkSize
      if data[pos] != byte('\r') or data[pos + 1] != byte('\n'):
        parseError = true
        return false
      pos += 2

proc effectiveSpillDir(configuredDir: string): string {.inline.} =
  if configuredDir.len > 0:
    return configuredDir
  getTempDir()

proc writeAllFd(fd: cint, dataPtr: pointer, totalBytes: int): bool =
  var written = 0
  while written < totalBytes:
    let rc = write(fd, cast[pointer](cast[uint](dataPtr) + cast[uint](written)), totalBytes - written)
    if rc <= 0:
      return false
    written += int(rc)
  true

proc openSpillFile(spillDir: string, outPath: var string): cint =
  let dir = effectiveSpillDir(spillDir)
  try:
    if not dirExists(dir):
      createDir(dir)
  except CatchableError:
    discard

  var attempt = 0
  while attempt < 4:
    let stamp = getCachedEpochMicros()
    let nonce = cast[uint](addr attempt)
    let fileName = "nim_uws_body_" & $stamp & "_" & $nonce & "_" & $attempt & ".tmp"
    outPath = joinPath(dir, fileName)
    let fd = open(outPath.cstring, O_CREAT or O_TRUNC or O_WRONLY or O_EXCL, S_IRUSR or S_IWUSR)
    if fd >= 0:
      return fd
    inc attempt
  -1

proc spillBodySliceToFile(
  data: openArray[byte],
  startPos: int,
  endPos: int,
  spillDir: string,
  outPath: var string
): bool =
  let bytes = endPos - startPos
  if bytes <= 0:
    return false
  let fd = openSpillFile(spillDir, outPath)
  if fd < 0:
    return false
  defer:
    discard close(fd)
  writeAllFd(fd, unsafeAddr data[startPos], bytes)

proc spillStringToFile(body: string, spillDir: string, outPath: var string): bool =
  if body.len == 0:
    return false
  let fd = openSpillFile(spillDir, outPath)
  if fd < 0:
    return false
  defer:
    discard close(fd)
  writeAllFd(fd, unsafeAddr body[0], body.len)

proc pathWithinTrustedSpillRoot(path: string, root: string): bool {.inline.} =
  if path.len == 0 or root.len == 0:
    return false
  var absPath = path
  var absRoot = root
  try:
    absPath = absolutePath(path)
  except CatchableError:
    discard
  try:
    absRoot = absolutePath(root)
  except CatchableError:
    discard
  if absRoot.len == 0 or absPath.len <= absRoot.len:
    return false
  if not absPath.startsWith(absRoot):
    return false
  when defined(windows):
    absPath[absRoot.len] in {'\\', '/'}
  else:
    absPath[absRoot.len] == '/'

proc cleanupRequestSpillFile(req: HttpRequest) {.inline.} =
  ## Best-effort cleanup for request spill files.
  ## Called on request completion/error/abort paths from the low-level server loop.
  if req == nil or not req.bodyInFile or req.bodyFilePath.len == 0:
    return
  let filePath = req.bodyFilePath
  let fileRoot = req.bodyFileRoot
  req.bodyInFile = false
  req.bodyFilePath.setLen(0)
  req.bodyFileRoot.setLen(0)
  if fileRoot.len == 0 or not pathWithinTrustedSpillRoot(filePath, fileRoot):
    return
  try:
    if fileExists(filePath):
      removeFile(filePath)
  except CatchableError:
    discard

when compileOption("threads"):
  proc compactSpillQueue(state: SpillWorkerState) {.inline.} =
    if state == nil or state.head <= 0:
      return
    if state.count == 0:
      state.queue.setLen(0)
      state.head = 0
      return
    if state.head * 2 < state.queue.len:
      return
    var compacted = newSeq[SpillTask](state.count)
    var idx = 0
    var i = state.head
    while idx < state.count:
      compacted[idx] = move(state.queue[i])
      inc idx
      inc i
    state.queue = move(compacted)
    state.head = 0

  proc spillOffloadEnabled(server: HttpServer): bool {.inline.} =
    server != nil and
    server.options.bodySpillThreshold > 0 and
    server.options.bodySpillOffloadEnabled and
    server.spillWorkerRunning and
    server.spillWorkerState != nil

  proc enqueueSpillOffload(server: HttpServer, body: string): bool {.inline.} =
    if body.len == 0 or not spillOffloadEnabled(server):
      return false
    let state = server.spillWorkerState
    acquire(state.lock)
    try:
      if state.stopping:
        return false
      if state.count >= state.maxQueued:
        noteSpillPressureDrop(server)
        return false
      if body.len > state.maxQueuedBytes or state.queuedBytes > state.maxQueuedBytes - body.len:
        noteSpillPressureDrop(server)
        if server != nil:
          server.emitServerError("Spill offload queue bytes limit exceeded")
        return false
      compactSpillQueue(state)
      let tail = state.head + state.count
      if tail < state.queue.len:
        state.queue[tail] = SpillTask(body: body, spillDir: server.options.bodySpillDir)
      else:
        state.queue.add(SpillTask(body: body, spillDir: server.options.bodySpillDir))
      inc state.count
      state.queuedBytes += body.len
      decaySpillPressure(server)
      signal(state.cond)
      return true
    finally:
      release(state.lock)

  proc spillOffloadWorkerMain(state: SpillWorkerState) {.thread.} =
    if state == nil:
      return
    while true:
      var task: SpillTask
      var hasTask = false
      acquire(state.lock)
      try:
        while not state.stopping and state.count == 0:
          wait(state.cond, state.lock)
        if state.stopping and state.count == 0:
          break
        if state.count > 0:
          task = move(state.queue[state.head])
          inc state.head
          dec state.count
          if task.body.len > 0:
            state.queuedBytes = max(0, state.queuedBytes - task.body.len)
          compactSpillQueue(state)
          hasTask = true
      finally:
        release(state.lock)

      if not hasTask:
        continue

      var outPath = ""
      if spillStringToFile(task.body, task.spillDir, outPath):
        # Background spill is best-effort for loop responsiveness.
        # Request processing uses in-memory body for integrity.
        if outPath.len > 0:
          try:
            removeFile(outPath)
          except CatchableError:
            discard

  proc stopSpillOffloadWorker(server: HttpServer) =
    if server == nil or not server.spillWorkerRunning or server.spillWorkerState == nil:
      return
    let state = server.spillWorkerState
    acquire(state.lock)
    try:
      state.stopping = true
      signal(state.cond)
    finally:
      release(state.lock)
    joinThread(server.spillWorker)
    deinitCond(state.cond)
    deinitLock(state.lock)
    server.spillWorkerRunning = false
    server.spillWorkerState = nil

  proc startSpillOffloadWorker(server: HttpServer) =
    if server == nil:
      return
    if server.spillWorkerRunning:
      let state = server.spillWorkerState
      if state != nil:
        acquire(state.lock)
        try:
          state.maxQueued = max(1, server.options.bodySpillOffloadQueueLimit)
          state.maxQueuedBytes = max(1, server.options.bodySpillOffloadQueueBytesLimit)
          if state.queuedBytes > state.maxQueuedBytes:
            noteSpillPressureDrop(server)
        finally:
          release(state.lock)
      return
    if not server.options.bodySpillOffloadEnabled or server.options.bodySpillThreshold <= 0:
      return
    var state = SpillWorkerState(
      queue: @[],
      head: 0,
      count: 0,
      maxQueued: max(1, server.options.bodySpillOffloadQueueLimit),
      queuedBytes: 0,
      maxQueuedBytes: max(1, server.options.bodySpillOffloadQueueBytesLimit),
      stopping: false
    )
    initLock(state.lock)
    initCond(state.cond)
    server.spillWorkerState = state
    createThread(server.spillWorker, spillOffloadWorkerMain, state)
    server.spillWorkerRunning = true

proc containsHeaderTokenNoCaseBytes(data: openArray[byte], startPos, endPos: int, token: string): bool {.inline, used.} =
  if startPos >= endPos or token.len == 0:
    return false

  var i = startPos
  while i < endPos:
    while i < endPos and (data[i] == byte(' ') or data[i] == byte('\t') or data[i] == byte(',')):
      inc i
    if i >= endPos:
      break

    let start = i
    while i < endPos and data[i] != byte(','):
      inc i

    var last = i - 1
    while last >= start and (data[last] == byte(' ') or data[last] == byte('\t')):
      dec last
    if last >= start and (last - start + 1) == token.len:
      var matched = true
      for j in 0..<token.len:
        if char(ToLowerTable[data[start + j]]) != token[j]:
          matched = false
          break
      if matched:
        return true
  false

proc containsHeaderTokenNoCase(value, token: string): bool {.inline.} =
  if value.len == 0 or token.len == 0:
    return false
  var i = 0
  while i < value.len:
    while i < value.len and (value[i] == ' ' or value[i] == '\t' or value[i] == ','):
      inc i
    if i >= value.len:
      break

    let start = i
    while i < value.len and value[i] != ',':
      inc i
    var last = i - 1
    while last >= start and (value[last] == ' ' or value[last] == '\t'):
      dec last

    if last >= start and (last - start + 1) == token.len:
      var matched = true
      for j in 0..<token.len:
        if char(ToLowerTable[byte(value[start + j])]) != token[j]:
          matched = false
          break
      if matched:
        return true
  false

proc containsHeaderTokenNoCase(value: fast_map.FastStringView, token: string): bool {.inline.} =
  if value.len == 0 or token.len == 0 or value.data == nil:
    return false
  let chars = cast[ptr UncheckedArray[char]](value.data)
  var i = 0
  while i < value.len:
    while i < value.len and (chars[i] == ' ' or chars[i] == '\t' or chars[i] == ','):
      inc i
    if i >= value.len:
      break

    let start = i
    while i < value.len and chars[i] != ',':
      inc i
    var last = i - 1
    while last >= start and (chars[last] == ' ' or chars[last] == '\t'):
      dec last

    if last >= start and (last - start + 1) == token.len:
      var matched = true
      for j in 0..<token.len:
        if char(ToLowerTable[byte(chars[start + j])]) != token[j]:
          matched = false
          break
      if matched:
        return true
  false

proc parseConnectionTokensBytes(
  data: openArray[byte],
  startPos,
  endPos: int,
  hasClose: var bool,
  hasKeepAlive: var bool,
  hasUpgrade: var bool
) {.inline.} =
  var i = startPos
  while i < endPos:
    while i < endPos and (data[i] == byte(' ') or data[i] == byte('\t') or data[i] == byte(',')):
      inc i
    if i >= endPos:
      break

    let tokenStart = i
    while i < endPos and data[i] != byte(','):
      inc i
    var tokenEnd = i
    while tokenEnd > tokenStart and (data[tokenEnd - 1] == byte(' ') or data[tokenEnd - 1] == byte('\t')):
      dec tokenEnd

    let tokenLen = tokenEnd - tokenStart
    if tokenLen == 5 and equalsAsciiNoCase(data, tokenStart, tokenEnd, "close"):
      hasClose = true
    elif tokenLen == 10 and equalsAsciiNoCase(data, tokenStart, tokenEnd, "keep-alive"):
      hasKeepAlive = true
    elif tokenLen == 7 and equalsAsciiNoCase(data, tokenStart, tokenEnd, "upgrade"):
      hasUpgrade = true

    if hasClose and hasKeepAlive and hasUpgrade:
      break

proc classifyHeaderToken(data: openArray[byte], startPos, endPos: int): ParsedHeaderKind {.inline.} =
  let keyLen = endPos - startPos
  if keyLen <= 0:
    return hkNone

  let c0 = data[startPos] or 0x20'u8
  let c1 = data[startPos + 1] or 0x20'u8

  case keyLen
  of 4:
    if c0 == ord('h') and c1 == ord('o'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderHost): return hkHost
  of 6:
    if c0 == ord('c') and c1 == ord('o'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderCookie): return hkCookie
    elif c0 == ord('e') and c1 == ord('x'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderExpect): return hkExpect
  of 7:
    if c0 == ord('u') and c1 == ord('p'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderUpgrade): return hkUpgrade
  of 10:
    if c0 == ord('c') and c1 == ord('o'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderConnection): return hkConnection
  of 12:
    if c0 == ord('c') and c1 == ord('o'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderContentType): return hkContentType
  of 14:
    if c0 == ord('c') and c1 == ord('o'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderContentLength): return hkContentLength
  of 17:
    if c0 == ord('t') and c1 == ord('r'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderTransferEncoding): return hkTransferEncoding
    elif c0 == ord('s') and c1 == ord('e'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderSecWebSocketKey): return hkSecWebSocketKey
  of 21:
    if c0 == ord('s') and c1 == ord('e'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderSecWebSocketVersion): return hkSecWebSocketVersion
  of 24:
    if c0 == ord('s') and c1 == ord('e'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderSecWebSocketExtensions): return hkSecWebSocketExtensions
  else:
    discard

  hkNone

proc classifyFramingHeader(data: openArray[byte], startPos, endPos: int): ParsedHeaderKind {.inline.} =
  let keyLen = endPos - startPos
  if keyLen <= 0 or startPos + 1 >= data.len:
    return hkNone
  let c0 = data[startPos] or 0x20'u8
  let c1 = data[startPos + 1] or 0x20'u8
  case keyLen
  of 4:
    if c0 == ord('h') and c1 == ord('o'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderHost): return hkHost
  of 6:
    if c0 == ord('e') and c1 == ord('x'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderExpect): return hkExpect
  of 7:
    if c0 == ord('u') and c1 == ord('p'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderUpgrade): return hkUpgrade
  of 10:
    if c0 == ord('c') and c1 == ord('o'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderConnection): return hkConnection
  of 14:
    if c0 == ord('c') and c1 == ord('o'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderContentLength): return hkContentLength
  of 17:
    if c0 == ord('t') and c1 == ord('r'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderTransferEncoding): return hkTransferEncoding
    elif c0 == ord('s') and c1 == ord('e'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderSecWebSocketKey): return hkSecWebSocketKey
  of 21:
    if c0 == ord('s') and c1 == ord('e'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderSecWebSocketVersion): return hkSecWebSocketVersion
  of 24:
    if c0 == ord('s') and c1 == ord('e'):
      if equalsAsciiNoCase(data, startPos, endPos, HeaderSecWebSocketExtensions): return hkSecWebSocketExtensions
  else:
    discard
  hkNone

## Classify cached raw header slices into known header kinds and populate fast lookup state
proc classifyRawHeaders*(req: HttpRequest, data: openArray[byte]) =
  if req.rawHeadersClassified:
    return
  req.rawHeadersClassified = true
  for i in 0 ..< int(req.rawHeaderCount):
    let raw = addr req.rawHeaders[i]
    if raw.kind == hkNone:
      raw.kind = classifyHeaderToken(data, int(raw.keyStart), int(raw.keyEnd))
      if raw.kind != hkNone:
        let valSlice = ByteSlice(startPos: raw.valStart, endPos: raw.valEnd)
        req.knownHeaders[raw.kind] = valSlice
        req.knownHeaderPresent.incl(raw.kind)
        case raw.kind
        of hkUpgrade:
          req.headerFlags = req.headerFlags or HfUpgrade
          req.upgradeSlice = valSlice
          req.sliceMask = req.sliceMask or smUpgrade
        of hkSecWebSocketKey:
          req.headerFlags = req.headerFlags or HfSecWebSocketKey
          req.wsKeySlice = valSlice
          req.sliceMask = req.sliceMask or smWsKey
        of hkSecWebSocketVersion:
          req.headerFlags = req.headerFlags or HfSecWebSocketVersion
          req.wsVersionSlice = valSlice
          req.sliceMask = req.sliceMask or smWsVersion
        of hkSecWebSocketExtensions:
          req.headerFlags = req.headerFlags or HfSecWebSocketExtensions
          req.wsExtensionsSlice = valSlice
          req.sliceMask = req.sliceMask or smWsExtensions
        of hkContentType:
          req.headerFlags = req.headerFlags or HfContentType
          req.contentTypeSlice = valSlice
          req.sliceMask = req.sliceMask or smContentType
        of hkCookie:
          req.headerFlags = req.headerFlags or HfCookie
          req.cookieSlice = valSlice
          req.sliceMask = req.sliceMask or smCookie
        else:
          discard

when defined(singleThread):
  var httpRequestPool: seq[HttpRequest]
else:
  var httpRequestPool {.threadvar.}: seq[HttpRequest]
const HttpRequestPoolMax = 128

proc acquireHttpRequest(): HttpRequest {.inline.} =
  if httpRequestPool.len > 0:
    result = httpRequestPool.pop()
  else:
    new(result)

## Reset a parsed request object and return it to the request object pool
proc recycleHttpRequest*(req: HttpRequest) {.inline.} =
  if req == nil:
    return
  if httpRequestPool.len < HttpRequestPoolMax:
    req.pathStr.setLen(0)
    req.queryStr.setLen(0)
    if req.httpVersionStr.len > 0: req.httpVersionStr.setLen(0)
    req.httpMajor = 0
    req.httpMinor = 0
    if req.body.len > 0: req.body.setLen(0)
    if req.bodyFilePath.len > 0: req.bodyFilePath.setLen(0)
    if req.bodyFileRoot.len > 0: req.bodyFileRoot.setLen(0)
    req.bodyInFile = false
    if req.remoteIp.len > 0: req.remoteIp.setLen(0)
    if req.headers != nil:
      req.headers.clear()
    if req.query != nil:
      req.query.clear()
    req.headerFlags = 0
    req.methodKind = hmGet
    req.connectionClose = false
    req.connectionHasUpgrade = false
    if req.upgradeStr.len > 0: req.upgradeStr.setLen(0)
    if req.wsKeyStr.len > 0: req.wsKeyStr.setLen(0)
    if req.wsVersionStr.len > 0: req.wsVersionStr.setLen(0)
    if req.wsExtensionsStr.len > 0: req.wsExtensionsStr.setLen(0)
    if req.contentTypeStr.len > 0: req.contentTypeStr.setLen(0)
    if req.cookieStr.len > 0: req.cookieStr.setLen(0)
    req.headersDeferred = false
    req.sliceMask = 0
    req.bufferPtr = nil
    req.bufferLen = 0
    req.knownHeaderPresent = {}
    req.rawHeaderCount = 0
    req.rawHeadersClassified = false
    if req.cachedHostStr.len > 0: req.cachedHostStr.setLen(0)
    httpRequestPool.add(req)

proc incompleteHeaderExceedsLimit(
  data: openArray[byte],
  startPos: int,
  maxHeaderBytes: int
): bool {.inline.} =
  if maxHeaderBytes <= 0 or startPos < 0 or startPos >= data.len:
    return false
  if findHeaderTerminator(data, startPos, data.len) >= 0:
    return false
  data.len - startPos > maxHeaderBytes

proc parseHttpRequest(
  data: openArray[byte],
  startPos: int,
  totalRequestSize: var int,
  minimalHeaders: bool,
  bodySpillThreshold: int,
  bodySpillDir: string,
  parseError: var bool,
  parseStatusCode: var int,
  maxHeaderBytes: int = DefaultMaxHeaderBytes,
  maxHeaderCount: int = DefaultMaxHeaderCount,
  maxHeaderLineBytes: int = DefaultMaxHeaderLineBytes,
  maxRequestUriBytes: int = DefaultMaxRequestUriBytes,
  maxBodySize: int = DefaultMaxBodySize,
  expectContinueMode: ExpectContinueMode = ecmStrictReject
): Option[HttpRequest] =
  parseError = false
  parseStatusCode = 400
  let parseEnd = data.len
  let headerTerminator = findHeaderTerminator(data, startPos, parseEnd)
  if headerTerminator < 0:
    return none(HttpRequest)
  let headersEnd = headerTerminator
  let headerSectionBytes = (headersEnd + 4) - startPos
  if maxHeaderBytes > 0 and headerSectionBytes > maxHeaderBytes:
    parseError = true
    parseStatusCode = 431
    return none(HttpRequest)
  var req: HttpRequest
  req = acquireHttpRequest()
  req.bodyFileRoot = ""

  var pos = startPos
  var lineEnd = findCrlfBounded(data, pos, headersEnd + 2)
  if lineEnd < 0:
    return none(HttpRequest)
  if lineEnd > headersEnd:
    parseError = true
    return none(HttpRequest)

  var methodEnd = swarFindByte(data, pos, lineEnd, byte(' '))
  if methodEnd <= pos or methodEnd >= lineEnd:
    parseError = true
    return none(HttpRequest)

  var parsedMethod: HttpMethod
  var isKnownMethod = false
  if not parseMethodToken(data, pos, methodEnd, parsedMethod, isKnownMethod):
    parseError = true
    return none(HttpRequest)
  if not isKnownMethod:
    parseError = true
    parseStatusCode = 501
    return none(HttpRequest)
  req.methodKind = parsedMethod

  pos = methodEnd + 1
  var pathEnd = swarFindByte(data, pos, lineEnd, byte(' '))
  if pathEnd <= pos or pathEnd >= lineEnd:
    parseError = true
    return none(HttpRequest)

  if maxRequestUriBytes > 0 and (pathEnd - pos) > maxRequestUriBytes:
    parseError = true
    parseStatusCode = 414
    return none(HttpRequest)
  var queryPos = -1
  for i in pos ..< pathEnd:
    let b = data[i]
    if b == byte('?') and queryPos < 0:
      queryPos = i
    if b == 0x00'u8 or b == 0x09'u8 or b == 0x0A'u8 or b == 0x0D'u8:
      parseError = true
      return none(HttpRequest)

  req.bufferPtr = unsafeAddr data[0]
  req.bufferLen = int32(data.len)
  if queryPos >= 0:
    req.pathSlice = ByteSlice(startPos: int32(pos), endPos: int32(queryPos))
    req.querySlice = ByteSlice(startPos: int32(queryPos + 1), endPos: int32(pathEnd))
    req.sliceMask = req.sliceMask or smPath or smQuery
  else:
    req.pathSlice = ByteSlice(startPos: int32(pos), endPos: int32(pathEnd))
    req.sliceMask = req.sliceMask or smPath

  pos = pathEnd + 1
  let versionLen = lineEnd - pos
  if versionLen == 8 and pos + 8 <= data.len:
    let vw = loadU64(data, pos)
    if vw == HttpVersion11U64:
      req.httpVersionStr = HttpVersion11
      req.httpMajor = 1
      req.httpMinor = 1
    elif vw == HttpVersion10U64:
      req.httpVersionStr = HttpVersion10
      req.httpMajor = 1
      req.httpMinor = 0
    else:
      parseError = true
      parseStatusCode = 505
      return none(HttpRequest)
  else:
    parseError = true
    parseStatusCode = 505
    return none(HttpRequest)
  pos = lineEnd + 2

  # Parse headers
  var contentLength = 0
  var hasContentLength = false
  var hasTransferEncoding = false
  var hasChunkedTransfer = false
  var finalChunkedTransfer = false
  var hasUnsupportedTransferCoding = false
  var hasMalformedTransferCoding = false
  var has100ContinueExpectation = false
  var hasUnsupportedExpectation = false
  var connHasClose = false
  var connHasKeepAlive = false
  var connHasUpgrade = false
  var hostCount = 0
  var hostHasValue = false
  var headerCount = 0

  while pos < headersEnd:
    lineEnd = findCrlfBounded(data, pos, headersEnd + 2)
    if lineEnd < 0:
      return none(HttpRequest)
    if lineEnd > headersEnd:
      parseError = true
      return none(HttpRequest)
    if maxHeaderLineBytes > 0 and (lineEnd - pos) > maxHeaderLineBytes:
      parseError = true
      parseStatusCode = 431
      return none(HttpRequest)
    inc headerCount
    if maxHeaderCount > 0 and headerCount > maxHeaderCount:
      parseError = true
      parseStatusCode = 431
      return none(HttpRequest)

    if data[pos] == byte(' ') or data[pos] == byte('\t'):
      parseError = true
      return none(HttpRequest)

    var colonPos = pos
    var allValidTokenChars = true
    while colonPos < lineEnd:
      let b = data[colonPos]
      if b == byte(':'):
        break
      if not TokenCharTable[b]:
        allValidTokenChars = false
      inc colonPos
    if colonPos <= pos or colonPos >= lineEnd:
      parseError = true
      return none(HttpRequest)

    let keyEnd = colonPos

    var valStart = colonPos + 1
    while valStart < lineEnd and (data[valStart] == byte(' ') or data[valStart] == byte('\t')):
      inc valStart
    var valEnd = lineEnd
    while valEnd > valStart and (data[valEnd - 1] == byte(' ') or data[valEnd - 1] == byte('\t')):
      dec valEnd
    let valSlice = ByteSlice(startPos: int32(valStart), endPos: int32(valEnd))

    if (keyEnd - pos) > int(high(uint16)) or (valEnd - valStart) > int(high(uint16)):
      parseError = true
      parseStatusCode = 431
      return none(HttpRequest)

    if minimalHeaders:
      if not allValidTokenChars:
        parseError = true
        return none(HttpRequest)
      if not hasValidHeaderValueBytes(data, valStart, valEnd):
        parseError = true
        return none(HttpRequest)
      let framingKind = classifyFramingHeader(data, pos, keyEnd)
      case framingKind
      of hkContentLength:
        req.headerFlags = req.headerFlags or HfContentLength
        req.knownHeaders[hkContentLength] = valSlice
        req.knownHeaderPresent.incl(hkContentLength)
        if not mergeContentLengthBytes(data, valStart, valEnd, hasContentLength, contentLength):
          parseError = true
          return none(HttpRequest)
      of hkTransferEncoding:
        req.headerFlags = req.headerFlags or HfTransferEncoding
        req.knownHeaders[hkTransferEncoding] = valSlice
        req.knownHeaderPresent.incl(hkTransferEncoding)
        parseTransferEncodingBytes(
          data, valStart, valEnd,
          hasTransferEncoding,
          hasChunkedTransfer,
          finalChunkedTransfer,
          hasUnsupportedTransferCoding,
          hasMalformedTransferCoding
        )
      of hkConnection:
        req.headerFlags = req.headerFlags or HfConnection
        req.knownHeaders[hkConnection] = valSlice
        req.knownHeaderPresent.incl(hkConnection)
        parseConnectionTokensBytes(data, valStart, valEnd, connHasClose, connHasKeepAlive, connHasUpgrade)
      of hkHost:
        req.headerFlags = req.headerFlags or HfHost
        req.knownHeaders[hkHost] = valSlice
        req.knownHeaderPresent.incl(hkHost)
        inc hostCount
        hostHasValue = valEnd > valStart
      of hkExpect:
        req.headerFlags = req.headerFlags or HfExpect
        req.knownHeaders[hkExpect] = valSlice
        req.knownHeaderPresent.incl(hkExpect)
        parseExpectHeaderBytes(
          data, valStart, valEnd,
          has100ContinueExpectation,
          hasUnsupportedExpectation
        )
      of hkUpgrade:
        req.headerFlags = req.headerFlags or HfUpgrade
        req.knownHeaders[hkUpgrade] = valSlice
        req.knownHeaderPresent.incl(hkUpgrade)
        req.upgradeSlice = valSlice
        req.sliceMask = req.sliceMask or smUpgrade
      of hkSecWebSocketKey:
        req.headerFlags = req.headerFlags or HfSecWebSocketKey
        req.knownHeaders[hkSecWebSocketKey] = valSlice
        req.knownHeaderPresent.incl(hkSecWebSocketKey)
        req.wsKeySlice = valSlice
        req.sliceMask = req.sliceMask or smWsKey
      of hkSecWebSocketVersion:
        req.headerFlags = req.headerFlags or HfSecWebSocketVersion
        req.knownHeaders[hkSecWebSocketVersion] = valSlice
        req.knownHeaderPresent.incl(hkSecWebSocketVersion)
        req.wsVersionSlice = valSlice
        req.sliceMask = req.sliceMask or smWsVersion
      of hkSecWebSocketExtensions:
        req.headerFlags = req.headerFlags or HfSecWebSocketExtensions
        req.knownHeaders[hkSecWebSocketExtensions] = valSlice
        req.knownHeaderPresent.incl(hkSecWebSocketExtensions)
        req.wsExtensionsSlice = valSlice
        req.sliceMask = req.sliceMask or smWsExtensions
      else:
        if req.rawHeaderCount >= 64:
          parseError = true
          return none(HttpRequest)
        req.rawHeaders[int(req.rawHeaderCount)] = RawHeaderSlice(
          keyStart: int32(pos),
          keyEnd: int32(keyEnd),
          valStart: int32(valStart),
          valEnd: int32(valEnd),
          kind: hkNone
        )
        inc req.rawHeaderCount
    else:
      if not hasValidHeaderValueBytes(data, valStart, valEnd):
        parseError = true
        return none(HttpRequest)
      if not allValidTokenChars:
        parseError = true
        return none(HttpRequest)
      let headerKind = classifyHeaderToken(data, pos, keyEnd)
      if headerKind != hkNone:
        req.knownHeaders[headerKind] = valSlice
        req.knownHeaderPresent.incl(headerKind)
        let value = sliceBytesToString(data, valStart, valEnd)
        if req.headers == nil:
          req.headers = newFastMap[string]()
          discard req.headers.reserve(16)
        case headerKind
        of hkContentLength:
          discard req.headers.putHashed(HeaderContentLength, hashContentLength, value)
          req.headerFlags = req.headerFlags or HfContentLength
          if not mergeContentLengthBytes(data, valStart, valEnd, hasContentLength, contentLength):
            parseError = true
            return none(HttpRequest)
        of hkTransferEncoding:
          discard req.headers.putHashed(HeaderTransferEncoding, hashTransferEncoding, value)
          req.headerFlags = req.headerFlags or HfTransferEncoding
          parseTransferEncodingBytes(
            data, valStart, valEnd,
            hasTransferEncoding,
            hasChunkedTransfer,
            finalChunkedTransfer,
            hasUnsupportedTransferCoding,
            hasMalformedTransferCoding
          )
        of hkConnection:
          discard req.headers.putHashed(HeaderConnection, hashConnection, value)
          req.headerFlags = req.headerFlags or HfConnection
          parseConnectionTokensBytes(data, valStart, valEnd, connHasClose, connHasKeepAlive, connHasUpgrade)
        of hkHost:
          discard req.headers.putHashed(HeaderHost, hashHost, value)
          req.headerFlags = req.headerFlags or HfHost
          inc hostCount
          hostHasValue = value.len > 0
        of hkExpect:
          discard req.headers.putHashed(HeaderExpect, hashExpect, value)
          req.headerFlags = req.headerFlags or HfExpect
          parseExpectHeaderBytes(
            data, valStart, valEnd,
            has100ContinueExpectation,
            hasUnsupportedExpectation
          )
        of hkUpgrade:
          discard req.headers.putHashed(HeaderUpgrade, hashUpgrade, value)
          req.headerFlags = req.headerFlags or HfUpgrade
          req.upgradeHeader = value
        of hkSecWebSocketKey:
          discard req.headers.putHashed(HeaderSecWebSocketKey, hashSecWebSocketKey, value)
          req.headerFlags = req.headerFlags or HfSecWebSocketKey
          req.secWebSocketKeyHeader = value
        of hkSecWebSocketVersion:
          discard req.headers.putHashed(HeaderSecWebSocketVersion, hashSecWebSocketVersion, value)
          req.headerFlags = req.headerFlags or HfSecWebSocketVersion
          req.secWebSocketVersionHeader = value
        of hkSecWebSocketExtensions:
          discard req.headers.putHashed(HeaderSecWebSocketExtensions, hashSecWebSocketExtensions, value)
          req.headerFlags = req.headerFlags or HfSecWebSocketExtensions
          req.secWebSocketExtensionsHeader = value
        of hkContentType:
          discard req.headers.putHashed(HeaderContentType, hashContentType, value)
          req.headerFlags = req.headerFlags or HfContentType
        of hkCookie:
          putMergedCookieHeader(req, value)
          req.headerFlags = req.headerFlags or HfCookie
        of hkNone:
          discard
      else:
        let value = sliceBytesToString(data, valStart, valEnd)
        if req.headers == nil:
          req.headers = newFastMap[string]()
          discard req.headers.reserve(16)
        var key = newStringOfCap(keyEnd - pos)
        for i in pos..<keyEnd:
          key.add(char(ToLowerTable[data[i]]))
        req.headers[key] = value
    pos = lineEnd + 2

  if minimalHeaders:
    req.headersDeferred = true

  # Skip the terminating CRLFCRLF delimiter.
  pos = headersEnd + 4

  if not validateHostRequirements(req.httpMajor, req.httpMinor, hostCount, hostHasValue, parseStatusCode):
    parseError = true
    return none(HttpRequest)
  if not validateExpectRequirements(
    has100ContinueExpectation,
    hasUnsupportedExpectation,
    expectContinueMode,
    parseStatusCode
  ):
    parseError = true
    return none(HttpRequest)

  # Connection persistence defaults follow HTTP version rules.
  if req.httpMajor == 1 and req.httpMinor == 0:
    req.connectionClose = not connHasKeepAlive or connHasClose
  else:
    req.connectionClose = connHasClose
  req.connectionHasUpgrade = connHasUpgrade

  if not validateTransferFramingRequirements(
    req.httpMajor,
    req.httpMinor,
    hasContentLength,
    hasTransferEncoding,
    hasChunkedTransfer,
    finalChunkedTransfer,
    hasUnsupportedTransferCoding,
    hasMalformedTransferCoding,
    parseStatusCode
  ):
    parseError = true
    return none(HttpRequest)

  if req.methodKind == hmTrace and (hasContentLength or hasTransferEncoding):
    parseError = true
    return none(HttpRequest)

  if hasTransferEncoding:
    var decodedBody = ""
    var chunkConsumed = 0
    var chunkParseError = false
    if not decodeChunkedBody(data, pos, parseEnd, decodedBody, chunkConsumed, chunkParseError, maxBodySize = maxBodySize):
      if chunkParseError:
        parseError = true
      return none(HttpRequest)
    if bodySpillThreshold > 0 and decodedBody.len >= bodySpillThreshold:
      var filePath = ""
      if spillStringToFile(decodedBody, bodySpillDir, filePath):
        req.body = ""
        req.bodyInFile = true
        req.bodyFilePath = filePath
        req.bodyFileRoot = effectiveSpillDir(bodySpillDir)
      else:
        req.body = decodedBody
    else:
      req.body = decodedBody
    let requestEnd = pos + chunkConsumed
    totalRequestSize = requestEnd - startPos
    return some(req)

  let effectiveContentLength = if hasContentLength: contentLength else: 0
  if pos > parseEnd:
    parseError = true
    return none(HttpRequest)
  if effectiveContentLength > parseEnd - pos:
    return none(HttpRequest)
  let requestEnd = pos + effectiveContentLength
  totalRequestSize = requestEnd - startPos

  # Body is only the declared content-length. Avoid copying pipelined data.
  if effectiveContentLength > 0:
    if bodySpillThreshold > 0 and effectiveContentLength >= bodySpillThreshold:
      var filePath = ""
      if spillBodySliceToFile(data, pos, requestEnd, bodySpillDir, filePath):
        req.body = ""
        req.bodyInFile = true
        req.bodyFilePath = filePath
        req.bodyFileRoot = effectiveSpillDir(bodySpillDir)
      else:
        req.body = sliceBytesToString(data, pos, requestEnd)
    else:
      req.body = sliceBytesToString(data, pos, requestEnd)

  return some(req)

when defined(nimUwebsocketsTest):
  ## Test-only wrapper that runs the production request parser over a raw request string
  proc parseHttpRequestForTest*(
    rawRequest: string,
    minimalHeaders = false,
    maxHeaderBytes: int = DefaultMaxHeaderBytes,
    maxHeaderCount: int = DefaultMaxHeaderCount,
    maxHeaderLineBytes: int = DefaultMaxHeaderLineBytes,
    expectContinueMode: ExpectContinueMode = ecmStrictReject
  ): tuple[
    ok: bool,
    req: HttpRequest,
    parseError: bool,
    parseStatusCode: int,
    totalRequestSize: int
  ] =
    ## Test-only helper that exercises the same parser path as onSocketData.
    var data = newSeq[byte](rawRequest.len)
    for i in 0..<rawRequest.len:
      data[i] = byte(rawRequest[i])

    var totalSize = 0
    var parseErr = false
    var statusCode = 400
    let reqOpt = parseHttpRequest(
      data,
      0,
      totalSize,
      minimalHeaders,
      bodySpillThreshold = 0,
      bodySpillDir = "",
      parseError = parseErr,
      parseStatusCode = statusCode,
      maxHeaderBytes = maxHeaderBytes,
      maxHeaderCount = maxHeaderCount,
      maxHeaderLineBytes = maxHeaderLineBytes,
      maxBodySize = DefaultMaxBodySize,
      expectContinueMode = expectContinueMode
    )
    result.ok = reqOpt.isSome
    result.parseError = parseErr
    result.parseStatusCode = statusCode
    result.totalRequestSize = totalSize
    if result.ok:
      result.req = reqOpt.get()
      if minimalHeaders:
        result.req.ensureHeadersPopulated()

  ## Test-only helper reporting whether a partial header block already exceeds the byte limit
  proc incompleteHeaderExceedsLimitForTest*(rawRequest: string, maxHeaderBytes: int): bool =
    var data = newSeq[byte](rawRequest.len)
    for i in 0..<rawRequest.len:
      data[i] = byte(rawRequest[i])
    incompleteHeaderExceedsLimit(data, 0, maxHeaderBytes)

proc h2FindStream(conn: H2ServerConnection, id: uint32): ptr H2ServerStream {.inline.}
proc h2RemoveStream(conn: H2ServerConnection, id: uint32) {.inline.}
proc h2FlushSendBuf(conn: H2ServerConnection, ssl: cint, s: UsSocketPtr) {.inline.}
proc h2QueuePendingSendData(
  streamPtr: ptr H2ServerStream,
  socket: UsSocketPtr,
  ssl: int,
  data: string,
  startPos: int,
  endStream: bool
): bool
proc h2FlushPendingSendData(conn: H2ServerConnection, streamId: uint32)
proc untrackH2Connection(server: HttpServer, conn: H2ServerConnection) {.inline.}
proc h2SendData(res: HttpResponse, data: string)
proc h2SendHeaders(res: HttpResponse)
proc h2End(res: HttpResponse, body: string)
proc h2StartChunkedStream(res: HttpResponse, contentType: string): bool
proc h2WriteChunkedStream(res: HttpResponse, chunk: string): bool
proc h2FinishChunkedStream(res: HttpResponse): bool
proc h2ValidateTrailerHeaders(headers: seq[(string, string)]): bool {.inline.}

## Append raw data to the client response stream, bypassing normal response framing
proc send*(res: HttpResponse, data: string) {.inline.} =
  ## Send data to the client (raw)
  res.assertResponseLoopAffinity("send_raw")
  if res.h2StreamId > 0 and res.h2Conn != nil:
    h2SendData(res, data)
    return
  if res.socket == nil:
    res.capturedRaw.add(data)
    return
  let sockData = socketDataFor(res.ssl, res.socket)
  let server = if sockData != nil: sockData.server else: nil
  discard writeFallbackPayloadAndMaybeClose(
    server,
    res.ssl,
    res.socket,
    data,
    "send_raw_short_write"
  )

proc responseDisallowsBody(res: HttpResponse): bool {.inline.}

## Flush the response status line and headers to the client with sensible defaults
proc sendHeaders*(res: HttpResponse) {.inline.} =
  ## Send HTTP headers
  res.assertResponseLoopAffinity("sendHeaders")
  if res.h2StreamId > 0 and res.h2Conn != nil:
    h2SendHeaders(res)
    return
  if res.headersSent:
    return

  # Pre-allocate response buffer
  var headerStr = newStringOfCap(256)
  headerStr.add(res.statusLineFor())

  let statusCodeInt = if res.statusCodeInt > 0: res.statusCodeInt else: res.statusCode.statusCodeValue
  let forceZeroLen205 = statusCodeInt == 205
  let forbidContentLength = statusCodeInt.statusForbidsContentLength() or res.isConnectSuccess()
  var hasContentType = false
  var hasConnection = false
  var hasDate = false
  let cookieCount = res.setCookieHeaders.len
  if res.headersInited and res.headers.len > 0:
    for key, value in res.headers:
      if key == HeaderTransferEncoding:
        continue
      if (forceZeroLen205 or forbidContentLength) and key == HeaderContentLength:
        continue
      headerStr.add(key)
      headerStr.add(": ")
      headerStr.add(value)
      headerStr.add("\r\n")
      if key == HeaderContentType: hasContentType = true
      if key == HeaderConnection: hasConnection = true
      if key == HeaderDate: hasDate = true
  if cookieCount > 0:
    for cookie in res.setCookieHeaders:
      headerStr.add(HeaderSetCookie)
      headerStr.add(": ")
      headerStr.add(cookie)
      headerStr.add("\r\n")

  # Add default headers if not set
  if not hasContentType:
    headerStr.add(HeaderLineTextContentType)
  # Default to keep-alive for HTTP/1.1 performance
  if not hasConnection:
    if res.connectionClose:
      headerStr.add(HeaderLineConnectionClose)
    else:
      headerStr.add(HeaderLineConnectionKeepAlive)
  let sockData = socketDataFor(res.ssl, res.socket)
  let server = if sockData != nil: sockData.server else: nil
  if not hasDate:
    headerStr.add(currentDateHeaderLine(server))
  if forceZeroLen205:
    headerStr.add("content-length: 0\r\n")

  headerStr.add("\r\n")
  if server != nil:
    server.emitBeforeHeaders(res.requestRef, res)
    server.emitBeforeWrite(headerStr.len, false)
  res.send(headerStr)
  if server != nil:
    server.emitAfterWrite(headerStr.len, true, false)
  res.headersSent = true

## Set the response status from a known HttpStatus value
proc setStatus*(res: HttpResponse, status: HttpStatus) {.inline.} =
  ## Set the response status code
  res.statusCode = status
  res.statusCodeInt = status.statusCodeValue

proc mapStatusCode(code: int): HttpStatus {.inline.} =
  case code
  of 100: Http100
  of 101: Http101
  of 200: Http200
  of 201: Http201
  of 204: Http204
  of 205: Http205
  of 301: Http301
  of 302: Http302
  of 304: Http304
  of 400: Http400
  of 401: Http401
  of 403: Http403
  of 404: Http404
  of 405: Http405
  of 500: Http500
  of 502: Http502
  of 503: Http503
  else: Http200

## Set the response status from a raw integer code with engine-side normalization
proc applyStatusCode*(res: HttpResponse, code: int) {.inline.} =
  ## Apply status with engine-side normalization for mixed known/unknown codes.
  if res == nil:
    return
  res.statusCode = mapStatusCode(code)
  res.statusCodeInt = code

## Enable or disable automatic end of the response when the handler returns
proc setAutoEndEnabled*(res: HttpResponse, enabled: bool) {.inline.} =
  if res == nil:
    return
  res.autoEnd = enabled

## Report whether automatic response end is enabled for this response
proc autoEndEnabled*(res: HttpResponse): bool {.inline.} =
  res != nil and res.autoEnd

## Enable or disable the Connection close hint on this response
proc setConnectionCloseEnabled*(res: HttpResponse, enabled: bool) {.inline.} =
  if res == nil:
    return
  res.connectionClose = enabled

## Report whether the connection close hint is enabled on this response
proc connectionCloseEnabled*(res: HttpResponse): bool {.inline.} =
  res != nil and res.connectionClose

## Mark the response body as fully sent to prevent further body writes
proc markBodySent*(res: HttpResponse) {.inline.} =
  if res == nil:
    return
  res.bodySent = true

## Report whether the response body has already been sent
proc bodyWasSent*(res: HttpResponse): bool {.inline.} =
  res != nil and res.bodySent

## Return the HttpRequest associated with this response, or nil
proc requestHandle*(res: HttpResponse): HttpRequest {.inline.} =
  if res == nil:
    return nil
  res.requestRef

## Return the HTTP method of the request that produced this response
proc requestMethodKind*(res: HttpResponse): HttpMethod {.inline.} =
  if res == nil:
    return hmGet
  res.requestMethod

proc normalizeHeaderKeyIfNeeded(key: string): string {.inline.} =
  var needsLower = false
  for c in key:
    if c >= 'A' and c <= 'Z':
      needsLower = true
      break
  if not needsLower:
    return key
  result = newStringOfCap(key.len)
  for c in key:
    result.add(char(ToLowerTable[byte(c)]))

## Set a response header, lowercasing the key when needed
proc setHeader*(res: HttpResponse, key, value: string) {.inline.} =
  ## Set a response header
  res.assertResponseLoopAffinity("setHeader")
  if not key.hasValidHeaderName() or value.hasUnsafeHeaderValueBytes():
    return
  let normalizedKey = key.normalizeHeaderKeyIfNeeded()
  if normalizedKey == HeaderTransferEncoding:
    # RFC 9112 §6.1 / §6.2 framing guard:
    # non-streaming paths are Content-Length framed in end().
    # Normal responses are framed with Content-Length in end().
    # Use startChunkedStream/writeChunkedStream for chunked transfer.
    return
  if normalizedKey.isSetCookieHeader():
    res.setCookieHeaders.add(value)
    return
  if not res.headersInited:
    res.headers = newFastMap[string]()
    discard res.headers.reserve(8)
    res.headersInited = true
  res.headers[normalizedKey] = value

const
  H2Status200 = "200"
  H2Status204 = "204"
  H2Status304 = "304"
  H2Status400 = "400"
  H2Status404 = "404"
  H2Status500 = "500"

proc h2StatusString(code: int): string {.inline.} =
  case code
  of 200: H2Status200
  of 204: H2Status204
  of 304: H2Status304
  of 400: H2Status400
  of 404: H2Status404
  of 500: H2Status500
  else: $code

proc h2BuildResponseHeaders(res: HttpResponse, includeContentLength: bool = true): seq[(string, string)] =
  let statusCode = if res.statusCodeInt > 0: res.statusCodeInt
                   else: res.statusCode.statusCodeValue
  result = newSeqOfCap[(string, string)](8)
  result.add((":status", h2StatusString(statusCode)))
  var hasContentType = false
  if res.headersInited and res.headers.len > 0:
    for key, value in res.headers:
      if key == "transfer-encoding" or key == "connection" or
         key == "keep-alive" or key == "proxy-connection" or key == "upgrade" or
         (key == HeaderContentLength and not includeContentLength):
        continue
      result.add((key, value))
      if key == "content-type": hasContentType = true
  if res.setCookieHeaders.len > 0:
    for cookie in res.setCookieHeaders:
      result.add(("set-cookie", cookie))
  if not hasContentType:
    result.add(("content-type", "text/plain"))

proc h2SerializeHeadersFragmented(streamId: uint32, headerBlock: string, endStream: bool, maxFrameSize: uint32, buf: var string) =
  let maxPayload = int(maxFrameSize)
  if headerBlock.len <= maxPayload:
    h2p.serializeHeaders(streamId, headerBlock, endStream, endHeaders = true, buf)
  else:
    let firstChunk = headerBlock[0 ..< maxPayload]
    h2p.serializeHeaders(streamId, firstChunk, endStream, endHeaders = false, buf)
    var pos = maxPayload
    while pos < headerBlock.len:
      let remaining = headerBlock.len - pos
      let chunkLen = min(remaining, maxPayload)
      let isLast = pos + chunkLen >= headerBlock.len
      var flags: uint8 = 0
      if isLast: flags = flags or h2p.FlagEndHeaders
      h2p.serializeFrameHeader(buf, uint32(chunkLen), h2p.ftContinuation, flags, streamId)
      let bpos = buf.len
      buf.setLen(bpos + chunkLen)
      copyMem(addr buf[bpos], unsafeAddr headerBlock[pos], chunkLen)
      pos += chunkLen

proc h2SerializeTrailersFragmented(streamId: uint32, headerBlock: string, maxFrameSize: uint32, buf: var string) =
  let maxPayload = int(maxFrameSize)
  if headerBlock.len <= maxPayload:
    h2p.serializeTrailers(streamId, headerBlock, buf)
  else:
    var flags: uint8 = h2p.FlagEndStream
    h2p.serializeFrameHeader(buf, uint32(min(headerBlock.len, maxPayload)), h2p.ftHeaders, flags, streamId)
    let bpos = buf.len
    let firstChunk = min(headerBlock.len, maxPayload)
    buf.setLen(bpos + firstChunk)
    copyMem(addr buf[bpos], unsafeAddr headerBlock[0], firstChunk)
    var pos = firstChunk
    while pos < headerBlock.len:
      let remaining = headerBlock.len - pos
      let chunkLen = min(remaining, maxPayload)
      let isLast = pos + chunkLen >= headerBlock.len
      var cflags: uint8 = 0
      if isLast: cflags = cflags or h2p.FlagEndHeaders
      h2p.serializeFrameHeader(buf, uint32(chunkLen), h2p.ftContinuation, cflags, streamId)
      let cpos = buf.len
      buf.setLen(cpos + chunkLen)
      copyMem(addr buf[cpos], unsafeAddr headerBlock[pos], chunkLen)
      pos += chunkLen

proc h2FlushSendBuf(conn: H2ServerConnection, ssl: cint, s: UsSocketPtr) {.inline.} =
  if conn.h2SendBuf.len == 0 or conn.h2SendBufPos >= conn.h2SendBuf.len:
    conn.h2SendBuf.setLen(0)
    conn.h2SendBufPos = 0
    if conn.sentGoaway and not conn.active and s != nil:
      us_socket_shutdown(ssl, s)
    return
  let toWrite = conn.h2SendBuf.len - conn.h2SendBufPos
  let written = writeSocketChecked(ssl, s, cast[cstring](unsafeAddr conn.h2SendBuf[conn.h2SendBufPos]), toWrite)
  if written >= toWrite:
    conn.h2SendBuf.setLen(0)
    conn.h2SendBufPos = 0
    if conn.sentGoaway and not conn.active:
      us_socket_shutdown(ssl, s)
  elif written > 0:
    conn.h2SendBufPos += written

const MaxH2SendBufSize = 16 * 1024 * 1024

proc h2TryWriteFrameBuf(conn: H2ServerConnection, ssl: cint, s: UsSocketPtr, frameBuf: string): bool {.inline.} =
  if frameBuf.len == 0 or s == nil or conn == nil:
    when defined(h2debug): stderr.writeLine "[h2WriteFrameBuf] early return: len=" & $frameBuf.len & " socket=" & $(s != nil)
    return frameBuf.len == 0
  if conn.h2SendBuf.len > conn.h2SendBufPos:
    if conn.h2SendBuf.len + frameBuf.len > MaxH2SendBufSize:
      when defined(h2debug): stderr.writeLine "[h2WriteFrameBuf] sendBuf overflow"
      return false
    let pos = conn.h2SendBuf.len
    conn.h2SendBuf.setLen(pos + frameBuf.len)
    copyMem(addr conn.h2SendBuf[pos], unsafeAddr frameBuf[0], frameBuf.len)
    when defined(h2debug): stderr.writeLine "[h2WriteFrameBuf] appended to sendBuf: " & $frameBuf.len
    return true
  let written = writeSocketChecked(ssl, s, cast[cstring](unsafeAddr frameBuf[0]), frameBuf.len)
  when defined(h2debug): stderr.writeLine "[h2WriteFrameBuf] us_socket_write(" & $frameBuf.len & ")=" & $written
  if written < frameBuf.len:
    let start = if written > 0: written else: 0
    let remaining = frameBuf.len - start
    conn.h2SendBuf.setLen(0)
    conn.h2SendBufPos = 0
    conn.h2SendBuf.setLen(remaining)
    copyMem(addr conn.h2SendBuf[0], unsafeAddr frameBuf[start], remaining)
    when defined(h2debug): stderr.writeLine "[h2WriteFrameBuf] buffered " & $remaining
  true

proc h2WriteFrameBuf(conn: H2ServerConnection, ssl: cint, s: UsSocketPtr, frameBuf: string) {.inline.} =
  discard h2TryWriteFrameBuf(conn, ssl, s, frameBuf)

proc h2WriteFrameBuf(res: HttpResponse, frameBuf: string) {.inline.} =
  if res == nil:
    return
  h2WriteFrameBuf(res.h2Conn, res.ssl, res.socket, frameBuf)

proc h2SendData(res: HttpResponse, data: string) =
  if data.len == 0 or res.h2Conn == nil or not res.h2Conn.active:
    return
  let conn = res.h2Conn
  let maxFrame = int(conn.remoteSettings.maxFrameSize)
  let streamPtr = h2FindStream(conn, res.h2StreamId)
  var pos = 0
  while pos < data.len:
    let connWindow = max(int(conn.remoteWindow), 0)
    let streamWindow = if streamPtr != nil: max(int(streamPtr.sendWindow), 0) else: maxFrame
    let flowMax = min(connWindow, streamWindow)
    if flowMax <= 0:
      discard h2QueuePendingSendData(streamPtr, res.socket, res.ssl, data, pos, endStream = false)
      break
    let chunkLen = min(min(data.len - pos, maxFrame), flowMax)
    if chunkLen <= 0:
      break
    var frameBuf = newStringOfCap(chunkLen + h2p.H2FrameHeaderSize)
    h2p.serializeDataView(res.h2StreamId, data.toOpenArray(pos, pos + chunkLen - 1), endStream = false, frameBuf)
    if not h2TryWriteFrameBuf(conn, res.ssl, res.socket, frameBuf):
      discard h2QueuePendingSendData(streamPtr, res.socket, res.ssl, data, pos, endStream = false)
      break
    conn.remoteWindow -= int32(chunkLen)
    if streamPtr != nil:
      streamPtr.sendWindow -= int32(chunkLen)
    pos += chunkLen

proc h2SendHeaders(res: HttpResponse) =
  if res.headersSent:
    return
  if res.h2Conn == nil or not res.h2Conn.active:
    return
  res.headersSent = true
  var headers = h2BuildResponseHeaders(res)
  var headerBlock = newStringOfCap(128)
  hpackMod.hpackEncode(res.h2Conn.encoder, headers, headerBlock)
  var frameBuf = newStringOfCap(h2p.H2FrameHeaderSize + headerBlock.len)
  h2SerializeHeadersFragmented(res.h2StreamId, headerBlock, endStream = false, res.h2Conn.remoteSettings.maxFrameSize, frameBuf)
  h2WriteFrameBuf(res, frameBuf)

proc h2End(res: HttpResponse, body: string) =
  if res.bodySent:
    when defined(h2debug): stderr.writeLine "[h2End] bodySent=true, skip"
    return
  if res.h2Conn == nil or not res.h2Conn.active:
    when defined(h2debug): stderr.writeLine "[h2End] conn nil or inactive"
    return
  res.bodySent = true
  res.headersSent = true
  let conn = res.h2Conn
  let suppressBody = responseDisallowsBody(res)
  let actualBody = if suppressBody: "" else: body
  var headers = h2BuildResponseHeaders(res, includeContentLength = false)
  if not suppressBody:
    headers.add(("content-length", $actualBody.len))
  var headerBlock = newStringOfCap(128)
  hpackMod.hpackEncode(conn.encoder, headers, headerBlock)
  let endStreamOnHeaders = actualBody.len == 0
  let maxFrame = int(conn.remoteSettings.maxFrameSize)
  let estimatedSize = h2p.H2FrameHeaderSize + headerBlock.len +
    (if actualBody.len > 0: h2p.H2FrameHeaderSize + actualBody.len else: 0)
  var frameBuf = newStringOfCap(estimatedSize)
  h2SerializeHeadersFragmented(res.h2StreamId, headerBlock, endStreamOnHeaders, conn.remoteSettings.maxFrameSize, frameBuf)
  when defined(h2debug): stderr.writeLine "[h2End] stream=" & $res.h2StreamId & " headerBlock=" & $headerBlock.len & " body=" & $actualBody.len & " frameBuf=" & $frameBuf.len & " connWindow=" & $conn.remoteWindow
  var consumedWindow = 0
  if actualBody.len > 0:
    let streamPtr = h2FindStream(conn, res.h2StreamId)
    var pos = 0
    while pos < actualBody.len:
      let connWindow = max(int(conn.remoteWindow), 0)
      let streamWindow = if streamPtr != nil: max(int(streamPtr.sendWindow), 0) else: maxFrame
      let flowMax = min(connWindow, streamWindow)
      if flowMax <= 0:
        break
      let chunkLen = min(min(actualBody.len - pos, maxFrame), flowMax)
      if chunkLen <= 0:
        break
      let isLast = pos + chunkLen >= actualBody.len
      h2p.serializeDataView(res.h2StreamId, actualBody.toOpenArray(pos, pos + chunkLen - 1), endStream = isLast, frameBuf)
      conn.remoteWindow -= int32(chunkLen)
      if streamPtr != nil:
        streamPtr.sendWindow -= int32(chunkLen)
      consumedWindow += chunkLen
      pos += chunkLen
    if pos < actualBody.len and streamPtr != nil:
      if not h2QueuePendingSendData(streamPtr, res.socket, res.ssl, actualBody, pos, endStream = true):
        conn.remoteWindow += int32(consumedWindow)
        streamPtr.sendWindow += int32(consumedWindow)
        streamPtr.pendingSendData = ""
        streamPtr.pendingSendPos = 0
        streamPtr.pendingSendEndStream = false
        var rstBuf = ""
        h2p.serializeRstStream(res.h2StreamId, uint32(h2p.ecInternalError), rstBuf)
        discard h2TryWriteFrameBuf(conn, res.ssl, res.socket, rstBuf)
        h2RemoveStream(conn, res.h2StreamId)
        return
  when defined(h2debug): stderr.writeLine "[h2End] final frameBuf=" & $frameBuf.len & " socket=" & $(res.socket != nil)
  if frameBuf.len > 0 and res.socket != nil:
    if not h2TryWriteFrameBuf(conn, res.ssl, res.socket, frameBuf):
      conn.remoteWindow += int32(consumedWindow)
      let streamPtr = h2FindStream(conn, res.h2StreamId)
      if streamPtr != nil:
        streamPtr.sendWindow += int32(consumedWindow)
        streamPtr.pendingSendData = ""
        streamPtr.pendingSendPos = 0
        streamPtr.pendingSendEndStream = false
      return
  let streamCheck = h2FindStream(conn, res.h2StreamId)
  if streamCheck != nil and streamCheck.pendingSendData.len == 0:
    streamCheck.endStreamSent = true
  if streamCheck == nil or streamCheck.pendingSendData.len == 0:
    h2RemoveStream(conn, res.h2StreamId)

proc h2StartChunkedStream(res: HttpResponse, contentType: string): bool =
  if res.h2Conn == nil or not res.h2Conn.active:
    return false
  var headers = h2BuildResponseHeaders(res, includeContentLength = false)
  for i in 0 ..< headers.len:
    if headers[i][0] == "content-type":
      headers[i] = ("content-type", contentType)
      break
  var headerBlock = newStringOfCap(128)
  hpackMod.hpackEncode(res.h2Conn.encoder, headers, headerBlock)
  var frameBuf = newStringOfCap(h2p.H2FrameHeaderSize + headerBlock.len)
  h2SerializeHeadersFragmented(res.h2StreamId, headerBlock, endStream = false, res.h2Conn.remoteSettings.maxFrameSize, frameBuf)
  h2WriteFrameBuf(res, frameBuf)
  res.bodySent = true
  res.headersSent = true
  res.chunkedStarted = true
  res.chunkedFinished = false
  true

proc h2WriteChunkedStream(res: HttpResponse, chunk: string): bool =
  if res.h2Conn == nil or not res.h2Conn.active:
    return false
  if chunk.len == 0:
    return true
  let conn = res.h2Conn
  let maxFrame = int(conn.remoteSettings.maxFrameSize)
  let streamPtr = h2FindStream(conn, res.h2StreamId)
  var pos = 0
  while pos < chunk.len:
    let connWindow = max(int(conn.remoteWindow), 0)
    let streamWindow = if streamPtr != nil: max(int(streamPtr.sendWindow), 0) else: maxFrame
    let flowMax = min(connWindow, streamWindow)
    if flowMax <= 0:
      return h2QueuePendingSendData(streamPtr, res.socket, res.ssl, chunk, pos, endStream = false)
    let chunkLen = min(min(chunk.len - pos, maxFrame), flowMax)
    if chunkLen <= 0:
      break
    var frameBuf = newStringOfCap(chunkLen + h2p.H2FrameHeaderSize)
    h2p.serializeDataView(res.h2StreamId, chunk.toOpenArray(pos, pos + chunkLen - 1), endStream = false, frameBuf)
    if not h2TryWriteFrameBuf(conn, res.ssl, res.socket, frameBuf):
      return h2QueuePendingSendData(streamPtr, res.socket, res.ssl, chunk, pos, endStream = false)
    conn.remoteWindow -= int32(chunkLen)
    if streamPtr != nil:
      streamPtr.sendWindow -= int32(chunkLen)
    pos += chunkLen
  true

proc h2FinishChunkedStream(res: HttpResponse): bool =
  if res.h2Conn == nil or not res.h2Conn.active:
    return false
  let streamPtr = h2FindStream(res.h2Conn, res.h2StreamId)
  if streamPtr != nil and streamPtr.endStreamSent:
    res.chunkedFinished = true
    return true
  if streamPtr != nil and streamPtr.pendingSendData.len > streamPtr.pendingSendPos:
    streamPtr.pendingSendEndStream = true
    res.chunkedFinished = true
    return true
  var frameBuf = newStringOfCap(h2p.H2FrameHeaderSize)
  h2p.serializeData(res.h2StreamId, "", endStream = true, frameBuf)
  h2WriteFrameBuf(res, frameBuf)
  if streamPtr != nil:
    streamPtr.endStreamSent = true
  res.chunkedFinished = true
  h2RemoveStream(res.h2Conn, res.h2StreamId)
  true

## Send HTTP/2 trailers on the active stream, terminating the response
proc h2SendTrailers*(res: HttpResponse, trailers: seq[(string, string)]) =
  if res.h2Conn == nil or not res.h2Conn.active:
    return
  let streamPtr = h2FindStream(res.h2Conn, res.h2StreamId)
  if streamPtr != nil and streamPtr.endStreamSent:
    return
  var filtered = newSeqOfCap[(string, string)](trailers.len)
  for (n, v) in trailers:
    if n.len > 0 and n[0] == ':':
      return
    filtered.add((n, v))
  if not h2ValidateTrailerHeaders(filtered):
    return
  var headerBlock = newStringOfCap(64)
  hpackMod.hpackEncode(res.h2Conn.encoder, filtered, headerBlock)
  var frameBuf = newStringOfCap(h2p.H2FrameHeaderSize + headerBlock.len)
  h2SerializeTrailersFragmented(res.h2StreamId, headerBlock, res.h2Conn.remoteSettings.maxFrameSize, frameBuf)
  h2WriteFrameBuf(res, frameBuf)
  if streamPtr != nil:
    streamPtr.endStreamSent = true
  h2RemoveStream(res.h2Conn, res.h2StreamId)

## Emit an HTTP/2 PUSH_PROMISE for the given path when server push is enabled
proc h2PushPromise*(res: HttpResponse, path: string, pushHeaders: seq[(string, string)], pushBody: string = "") =
  if res.h2Conn == nil or not res.h2Conn.active:
    return
  if not res.h2Conn.remoteSettings.enablePush:
    return
  let conn = res.h2Conn
  let parentStream = h2FindStream(conn, res.h2StreamId)
  if parentStream == nil:
    return
  if parentStream.state notin {h2p.ssOpen, h2p.ssHalfClosedRemote}:
    return
  if conn.nextPushStreamId > 2147483646'u32:
    return
  let promisedId = conn.nextPushStreamId
  conn.nextPushStreamId += 2
  var authority = ""
  for (hn, hv) in pushHeaders:
    if hn == ":authority":
      authority = hv
      break
  if authority.len == 0:
    for (hn, hv) in parentStream.requestHeaders:
      if hn == ":authority":
        authority = hv
        break
  var promiseHeaders = newSeqOfCap[(string, string)](pushHeaders.len + 4)
  promiseHeaders.add((":method", "GET"))
  promiseHeaders.add((":path", path))
  promiseHeaders.add((":scheme", "https"))
  if authority.len > 0:
    promiseHeaders.add((":authority", authority))
  for h in pushHeaders:
    if h[0].len == 0 or h[0][0] != ':':
      promiseHeaders.add(h)
  var promiseBlock = newStringOfCap(128)
  hpackMod.hpackEncode(conn.encoder, promiseHeaders, promiseBlock)
  let maxPayload = int(conn.remoteSettings.maxFrameSize)
  let ppHeaderSpace = maxPayload - 4
  var ppBuf = newStringOfCap(h2p.H2FrameHeaderSize + 4 + promiseBlock.len)
  if promiseBlock.len <= ppHeaderSpace:
    h2p.serializePushPromise(res.h2StreamId, promisedId, promiseBlock, ppBuf)
  else:
    let firstChunk = promiseBlock[0 ..< ppHeaderSpace]
    let ppPayloadLen = uint32(4 + firstChunk.len)
    h2p.serializeFrameHeader(ppBuf, ppPayloadLen, h2p.ftPushPromise, 0, res.h2StreamId)
    h2p.writeU32BE(ppBuf, promisedId and 0x7FFFFFFF'u32)
    if firstChunk.len > 0:
      let bpos = ppBuf.len
      ppBuf.setLen(bpos + firstChunk.len)
      copyMem(addr ppBuf[bpos], unsafeAddr promiseBlock[0], firstChunk.len)
    var cpos = ppHeaderSpace
    while cpos < promiseBlock.len:
      let remaining = promiseBlock.len - cpos
      let chunkLen = min(remaining, maxPayload)
      let isLast = cpos + chunkLen >= promiseBlock.len
      var cflags: uint8 = 0
      if isLast: cflags = cflags or h2p.FlagEndHeaders
      h2p.serializeFrameHeader(ppBuf, uint32(chunkLen), h2p.ftContinuation, cflags, res.h2StreamId)
      let bp = ppBuf.len
      ppBuf.setLen(bp + chunkLen)
      copyMem(addr ppBuf[bp], unsafeAddr promiseBlock[cpos], chunkLen)
      cpos += chunkLen
  h2WriteFrameBuf(res, ppBuf)
  var pushStream = H2ServerStream(
    id: promisedId,
    state: h2p.ssReservedLocal,
    sendWindow: int32(conn.remoteSettings.initialWindowSize),
    recvWindow: h2p.DefaultWindowSize,
    headersReceived: true,
    endStreamRecv: true,
  )
  conn.streams[promisedId] = pushStream
  var respHeaders = newSeqOfCap[(string, string)](4)
  respHeaders.add((":status", "200"))
  if pushBody.len > 0:
    respHeaders.add(("content-length", $pushBody.len))
  var respBlock = newStringOfCap(64)
  hpackMod.hpackEncode(conn.encoder, respHeaders, respBlock)
  let endStreamOnHeaders = pushBody.len == 0
  var respBuf = newStringOfCap(h2p.H2FrameHeaderSize + respBlock.len)
  h2SerializeHeadersFragmented(promisedId, respBlock, endStreamOnHeaders, conn.remoteSettings.maxFrameSize, respBuf)
  h2WriteFrameBuf(res, respBuf)
  if pushBody.len > 0:
    let pushStreamPtr = h2FindStream(conn, promisedId)
    let maxFrame = int(conn.remoteSettings.maxFrameSize)
    var pos = 0
    while pos < pushBody.len:
      let connWindow = max(int(conn.remoteWindow), 0)
      let streamWindow = if pushStreamPtr != nil: max(int(pushStreamPtr.sendWindow), 0) else: maxFrame
      let flowMax = min(connWindow, streamWindow)
      if flowMax <= 0:
        break
      let chunkLen = min(min(pushBody.len - pos, maxFrame), flowMax)
      if chunkLen <= 0:
        break
      let isLast = pos + chunkLen >= pushBody.len
      var dataBuf = newStringOfCap(chunkLen + h2p.H2FrameHeaderSize)
      h2p.serializeDataView(promisedId, pushBody.toOpenArray(pos, pos + chunkLen - 1), endStream = isLast, dataBuf)
      h2WriteFrameBuf(res, dataBuf)
      conn.remoteWindow -= int32(chunkLen)
      if pushStreamPtr != nil:
        pushStreamPtr.sendWindow -= int32(chunkLen)
      pos += chunkLen
  h2RemoveStream(conn, promisedId)

proc responseDisallowsBody(res: HttpResponse): bool {.inline.} =
  if res == nil:
    return false
  # RFC 9112 §6.3 and RFC 9110 §6.4.1:
  # no body for HEAD, 1xx, 204, 205, 304, and 2xx CONNECT.
  let code = if res.statusCodeInt > 0: res.statusCodeInt else: res.statusCode.statusCodeValue
  res.requestMethod == hmHead or
    (code >= 100 and code < 200) or
    code == 204 or
    code == 205 or
    code == 304 or
    res.isConnectSuccess()

proc `end`*(res: HttpResponse, body: string = "") =
  ## End the response with optional body
  res.assertResponseLoopAffinity("end")
  if res.h2StreamId > 0 and res.h2Conn != nil:
    h2End(res, body)
    return
  if res.bodySent:
    return
  res.bodySent = true

  # Build headers first, then write header+body without concatenating on non-SSL sockets.
  var response = newStringOfCap(256)
  response.add(res.statusLineFor())

  # Add headers
  var hasContentType = false
  var hasConnection = false
  var hasDate = false
  var shouldClose = false
  let noBody = res.responseDisallowsBody()
  let statusCodeInt = if res.statusCodeInt > 0: res.statusCodeInt else: res.statusCode.statusCodeValue
  let forceZeroLen205 = statusCodeInt == 205
  let forbidCL = statusCodeInt.statusForbidsContentLength() or res.isConnectSuccess()
  var hasUserContentLength = false

  if res.headersInited and res.headers.len > 0:
    for key, value in res.headers:
      if key == HeaderTransferEncoding:
        continue
      if key == HeaderContentLength:
        if forbidCL or forceZeroLen205:
          continue
        hasUserContentLength = true
      response.add(key)
      response.add(": ")
      response.add(value)
      response.add("\r\n")
      if key == HeaderContentType: hasContentType = true
      if key == HeaderConnection:
        hasConnection = true
        shouldClose = containsHeaderTokenNoCase(value, "close")
      if key == HeaderDate:
        hasDate = true
  if res.setCookieHeaders.len > 0:
    for cookie in res.setCookieHeaders:
      response.add(HeaderSetCookie)
      response.add(": ")
      response.add(cookie)
      response.add("\r\n")

  if not hasContentType:
    response.add(HeaderLineTextContentType)
  if not hasConnection:
    if res.connectionClose:
      response.add(HeaderLineConnectionClose)
      shouldClose = true
    else:
      response.add(HeaderLineConnectionKeepAlive)
  elif res.connectionClose:
    shouldClose = true
  if not hasDate:
    let sockData = socketDataFor(res.ssl, res.socket)
    let server = if sockData != nil: sockData.server else: nil
    response.add(currentDateHeaderLine(server))

  let outBody =
    if noBody:
      ""
    else:
      body
  if noBody:
    if forceZeroLen205:
      response.add("content-length: 0\r\n")
    elif not hasUserContentLength:
      if res.requestMethod == hmHead and body.len > 0:
        response.add(HeaderLineContentLengthPrefix)
        fastIntToStr(body.len, response)
        response.add("\r\n")
  elif not hasUserContentLength:
    response.add(HeaderLineContentLengthPrefix)
    fastIntToStr(outBody.len, response)
    response.add("\r\n")

  response.add("\r\n")
  res.sendPreparedResponse(response, outBody, shouldClose)

## Register a writable-progress callback for progressive ``tryEnd`` responses and return the response
proc onWritable*(res: HttpResponse, handler: HttpWritableHandler): HttpResponse {.discardable.} =
  ## Register writable callback for tryEnd-style progressive responses.
  res.assertResponseLoopAffinity("onWritable")
  if res == nil:
    return nil
  res.writableHandler = handler
  let sockData = socketDataFor(res.ssl, res.socket)
  if sockData != nil:
    updatePendingWritableHandler(sockData, res.requestSeq, handler)
  res

## Return the current ``tryEnd`` write progress offset for this response
proc getWriteOffset*(res: HttpResponse): uint64 {.inline.} =
  ## Return current tryEnd write progress offset for this response.
  if res == nil:
    return 0'u64
  let sockData = socketDataFor(res.ssl, res.socket)
  if sockData != nil:
    syncTryEndOffset(res, sockData)
  res.tryEndOffset

## Pause request parsing on the response socket until ``resumeRead`` is called
proc pauseRead*(res: HttpResponse) {.inline.} =
  ## Pause HTTP request parsing for this socket.
  res.assertResponseLoopAffinity("pauseRead")
  if res == nil or res.socket == nil:
    return
  let sockData = socketDataFor(res.ssl, res.socket)
  if sockData != nil and not sockData.hasFlag(SDF_IS_WEBSOCKET):
    sockData.setFlag(SDF_READ_PAUSED)

## Resume request parsing for a socket paused via ``pauseRead`` and drain buffered bytes
proc resumeRead*(res: HttpResponse) {.inline.} =
  ## Resume HTTP request parsing and process any buffered bytes.
  res.assertResponseLoopAffinity("resumeRead")
  if res == nil or res.socket == nil:
    return
  let sockData = socketDataFor(res.ssl, res.socket)
  if sockData != nil and not sockData.hasFlag(SDF_IS_WEBSOCKET) and sockData.hasFlag(SDF_READ_PAUSED):
    sockData.clearFlag(SDF_READ_PAUSED)
    sockData.scheduleSocketDataResume(res.socket)

## Report whether request parsing is currently paused for this response socket
proc isReadPaused*(res: HttpResponse): bool {.inline.} =
  if res == nil or res.socket == nil:
    return false
  let sockData = socketDataFor(res.ssl, res.socket)
  sockData != nil and sockData.hasFlag(SDF_READ_PAUSED)

## Progressive response writer that starts or extends a ``tryEnd``-style body write and reports drain state
proc tryEnd*(
  res: HttpResponse,
  data: sink string,
  totalSize: uint64 = 0,
  closeAfterWrite: bool = false
): tuple[ok: bool, hasResponded: bool] =
  ## Progressive response API similar to uWS tryEnd.
  ## Returns:
  ##   ok = false when this response still has pending bytes to drain.
  ##   hasResponded = true when the full body is written/flushed.
  res.assertResponseLoopAffinity("tryEnd")
  if res.h2StreamId > 0 and res.h2Conn != nil:
    h2End(res, data)
    return (true, true)
  if res == nil or res.socket == nil:
    return (false, false)

  if res.chunkedStarted:
    return (false, false)

  if res.responseDisallowsBody():
    if not res.bodySent:
      res.`end`("")
    return (true, true)

  let sockData = socketDataFor(res.ssl, res.socket)
  if sockData == nil or sockData.server == nil:
    return (false, false)

  if res.bodySent and not res.tryEndActive:
    return (false, true)

  if not res.tryEndActive:
    if res.headersSent:
      return (false, res.bodySent)

    var response = newStringOfCap(256)
    response.add(res.statusLineFor())

    var hasContentType = false
    var hasConnection = false
    var hasDate = false
    var shouldClose = closeAfterWrite or res.connectionClose

    if res.headersInited and res.headers.len > 0:
      for key, value in res.headers:
        if key == HeaderTransferEncoding or key == HeaderContentLength:
          continue
        response.add(key)
        response.add(": ")
        response.add(value)
        response.add("\r\n")
        if key == HeaderContentType:
          hasContentType = true
        elif key == HeaderConnection:
          hasConnection = true
          shouldClose = shouldClose or containsHeaderTokenNoCase(value, "close")
        elif key == HeaderDate:
          hasDate = true
    if res.setCookieHeaders.len > 0:
      for cookie in res.setCookieHeaders:
        response.add(HeaderSetCookie)
        response.add(": ")
        response.add(cookie)
        response.add("\r\n")

    if not hasContentType:
      response.add(HeaderLineTextContentType)
    if not hasConnection:
      if shouldClose:
        response.add(HeaderLineConnectionClose)
      else:
        response.add(HeaderLineConnectionKeepAlive)
    if not hasDate:
      response.add(currentDateHeaderLine(sockData.server))
    res.connectionClose = shouldClose

    response.add(HeaderLineContentLengthPrefix)
    fastIntToStr(int(totalSize), response)
    response.add("\r\n")
    response.add("\r\n")

    var queued = QueuedResponse(
      header: response,
      body: "",
      headerPos: 0,
      bodyPos: 0,
      isFileBody: false,
      fileFd: -1,
      fileOffset: 0.Off,
      fileRemaining: 0.Off,
      closeAfterWrite: false,
      isStreamBody: true,
      streamOpen: true,
      hasTryEnd: true,
      tryEndOffset: 0,
      tryEndTotal: totalSize,
      writableHandler: res.writableHandler
    )

    if res.requestSeq == sockData.nextWriteSeq and sockData.pendingIsEmpty():
      var wrote = 0'i64
      discard writeQueuedResponse(sockData, res.ssl, res.socket, queued, wrote)
      if wrote > 0:
        sockData.onQueuedBytesWritten(wrote)
      if not sockData.enqueuePendingResponse(res.requestSeq, queued):
        discard closeSocketTracked(sockData.server, res.ssl, res.socket, "try_end_enqueue_failure_head")
        return (false, false)
    else:
      if not sockData.enqueuePendingResponse(res.requestSeq, queued):
        discard closeSocketTracked(sockData.server, res.ssl, res.socket, "try_end_enqueue_failure")
        return (false, false)

    res.tryEndActive = true
    res.tryEndTotal = totalSize
    res.tryEndOffset = 0
    res.tryEndQueued = 0
    res.headersSent = true
    if sockData.shouldAutoFlush():
      flushPendingResponses(sockData, res.socket)
    else:
      registerPendingFlush(sockData, res.socket)

  if totalSize != res.tryEndTotal:
    return (false, false)

  let chunkLen = uint64(data.len)
  if chunkLen > 0:
    if res.tryEndQueued + chunkLen > res.tryEndTotal:
      return (false, false)
    if not appendPendingStreamChunk(sockData, res.requestSeq, data, false, false):
      discard closeSocketTracked(sockData.server, res.ssl, res.socket, "try_end_append_chunk_failure")
      return (false, false)
    res.tryEndQueued += chunkLen

  let finishing = res.tryEndQueued >= res.tryEndTotal
  if finishing and res.tryEndActive:
    if not appendPendingStreamChunk(sockData, res.requestSeq, "", true, closeAfterWrite or res.connectionClose):
      discard closeSocketTracked(sockData.server, res.ssl, res.socket, "try_end_append_final_chunk_failure")
      return (false, false)
    res.tryEndActive = false
    res.bodySent = true

  updatePendingWritableHandler(sockData, res.requestSeq, res.writableHandler)
  if sockData.shouldAutoFlush():
    flushPendingResponses(sockData, res.socket)
  else:
    registerPendingFlush(sockData, res.socket)
  syncTryEndOffset(res, sockData)

  let hasResponded = res.bodySent and responseIsDrained(sockData, res.requestSeq)
  let ok = true
  if hasResponded:
    res.tryEndOffset = res.tryEndTotal
  (ok, hasResponded)

## Pointer and length variant of ``tryEnd`` with a direct-write fast path for the head slot
proc tryEndRaw*(
  res: HttpResponse,
  dataPtr: pointer,
  dataLen: int,
  totalSize: uint64 = 0,
  closeAfterWrite: bool = false
): tuple[ok: bool, hasResponded: bool] =
  ## Pointer+length variant of tryEnd.
  ## Fast path attempts direct socket write for currently-draining stream slot and
  ## falls back to queued copy only for unwritten tail bytes.
  res.assertResponseLoopAffinity("tryEndRaw")
  if dataPtr == nil or dataLen <= 0:
    return res.tryEnd("", totalSize, closeAfterWrite)
  if res == nil or res.socket == nil:
    return (false, false)
  if res.chunkedStarted:
    return (false, false)
  if res.responseDisallowsBody():
    if not res.bodySent:
      res.`end`("")
    return (true, true)

  let sockData = socketDataFor(res.ssl, res.socket)
  if sockData == nil or sockData.server == nil:
    return (false, false)
  if res.bodySent and not res.tryEndActive:
    return (false, true)

  if not res.tryEndActive:
    let started = res.tryEnd("", totalSize, false)
    if not started.ok:
      return started
    if totalSize == 0 and res.bodySent:
      return (true, true)
  if totalSize != res.tryEndTotal:
    return (false, false)

  let chunkLen = uint64(dataLen)
  if res.tryEndQueued + chunkLen > res.tryEndTotal:
    return (false, false)

  var acceptedLen = 0
  var remainingPtr = dataPtr
  var remainingLen = dataLen

  # Direct-write fast path:
  # only when this response is the active head slot and stream framing/header is already emitted.
  if res.ssl == 0 and res.requestSeq == sockData.nextWriteSeq:
    let idx = responseSlotForSeq(sockData, res.requestSeq)
    if idx >= 0 and idx == sockData.pendingStart and idx < sockData.pendingUsed.len and sockData.pendingUsed[idx]:
      var slot = addr sockData.pendingSlots[idx]
      if slot[].isStreamBody and
          slot[].streamOpen and
          slot[].headerPos >= slot[].header.len and
          slot[].bodyPos >= slot[].body.len and
          slot[].streamChunkHead >= slot[].streamChunks.len:
        let written = bufferSocketWrite(
          sockData, res.ssl, res.socket,
          cast[cstring](remainingPtr),
          remainingLen
        )
        if written > 0:
          acceptedLen += written
          slot[].updateTryEndProgress(int64(written))
          remainingLen = 0

  if remainingLen > 0:
    var queuedChunk = newString(remainingLen)
    copyMem(addr queuedChunk[0], remainingPtr, remainingLen)
    if not appendPendingStreamChunk(sockData, res.requestSeq, queuedChunk, false, false):
      discard closeSocketTracked(sockData.server, res.ssl, res.socket, "try_end_raw_append_chunk_failure")
      return (false, false)
    acceptedLen += remainingLen

  if acceptedLen > 0:
    res.tryEndQueued += uint64(acceptedLen)

  let finishing = res.tryEndQueued >= res.tryEndTotal
  if finishing and res.tryEndActive:
    if not appendPendingStreamChunk(sockData, res.requestSeq, "", true, closeAfterWrite or res.connectionClose):
      discard closeSocketTracked(sockData.server, res.ssl, res.socket, "try_end_raw_append_final_chunk_failure")
      return (false, false)
    res.tryEndActive = false
    res.bodySent = true

  updatePendingWritableHandler(sockData, res.requestSeq, res.writableHandler)
  if sockData.shouldAutoFlush():
    flushPendingResponses(sockData, res.socket)
  else:
    registerPendingFlush(sockData, res.socket)
  syncTryEndOffset(res, sockData)

  let hasResponded = res.bodySent and responseIsDrained(sockData, res.requestSeq)
  let ok = true
  if hasResponded:
    res.tryEndOffset = res.tryEndTotal
  (ok, hasResponded)

proc toHexNoPrefix(n: int): string {.inline.} =
  if n <= 0:
    return "0"
  const HexDigits = "0123456789abcdef"
  var value = n
  var tmp = newStringOfCap(16)
  while value > 0:
    let digit = value and 0xF
    tmp.add(HexDigits[digit])
    value = value shr 4
  result = newStringOfCap(tmp.len)
  var i = tmp.len - 1
  while i >= 0:
    result.add(tmp[i])
    dec i

proc syncCaptureForwardState(res: HttpResponse, target: HttpResponse) =
  if res == nil or target == nil:
    return
  target.requestMethod = res.requestMethod
  target.requestIsHttp11 = res.requestIsHttp11
  target.statusCode = res.statusCode
  target.statusCodeInt = res.statusCodeInt
  target.connectionClose = res.connectionClose
  if res.headersInited and res.headers.len > 0:
    for key, value in res.headers:
      target.setHeader(key, value)
  if res.setCookieHeaders.len > 0:
    for cookie in res.setCookieHeaders:
      target.setHeader(HeaderSetCookie, cookie)

## Begin a chunked transfer response with ordered queued writes and report success
proc startChunkedStream*(
  res: HttpResponse,
  contentType: string = "text/html; charset=utf-8"
): bool =
  ## Start a chunked-transfer response with ordered queued writes.
  res.assertResponseLoopAffinity("startChunkedStream")
  if res.socket == nil and res.captureForward != nil:
    res.captureBypassCache = true
    res.syncCaptureForwardState(res.captureForward)
    let started = res.captureForward.startChunkedStream(contentType)
    if started:
      res.bodySent = true
      res.headersSent = true
      res.chunkedStarted = true
      res.chunkedFinished = false
    return started
  if res.h2StreamId > 0 and res.h2Conn != nil:
    return h2StartChunkedStream(res, contentType)
  if res.bodySent:
    return false
  if res.responseDisallowsBody():
    return false
  if not res.requestIsHttp11:
    return false

  var header = newStringOfCap(256)
  header.add(res.statusLineFor())

  var hasContentType = false
  var hasConnection = false
  var hasDate = false
  var shouldClose = res.connectionClose

  if res.headersInited and res.headers.len > 0:
    for key, value in res.headers:
      if key == HeaderContentLength or key == HeaderTransferEncoding:
        # Chunked stream framing is generated below; drop conflicting user framing.
        continue
      header.add(key)
      header.add(": ")
      header.add(value)
      header.add("\r\n")
      if key == HeaderContentType:
        hasContentType = true
      elif key == HeaderConnection:
        hasConnection = true
        shouldClose = containsHeaderTokenNoCase(value, "close")
      elif key == HeaderDate:
        hasDate = true
  if res.setCookieHeaders.len > 0:
    for cookie in res.setCookieHeaders:
      header.add(HeaderSetCookie)
      header.add(": ")
      header.add(cookie)
      header.add("\r\n")

  if not hasContentType:
    header.add(HeaderContentType)
    header.add(": ")
    header.add(contentType)
    header.add("\r\n")
  header.add(HeaderTransferEncoding)
  header.add(": chunked\r\n")
  if not hasConnection:
    if shouldClose:
      header.add(HeaderLineConnectionClose)
    else:
      header.add(HeaderLineConnectionKeepAlive)
  if not hasDate:
    let sockData = socketDataFor(res.ssl, res.socket)
    let server = if sockData != nil: sockData.server else: nil
    header.add(currentDateHeaderLine(server))

  header.add("\r\n")

  res.bodySent = true
  res.headersSent = true
  res.chunkedStarted = true
  res.chunkedFinished = false
  res.tryEndActive = false
  res.tryEndOffset = 0
  res.tryEndQueued = 0
  res.tryEndTotal = 0

  let sockData = socketDataFor(res.ssl, res.socket)
  if res.socket == nil:
    res.capturedHeader = header
    res.capturedRaw = header
    return true
  if sockData == nil or sockData.server == nil:
    let wrote = writeFallbackPayloadAndMaybeClose(
      nil,
      res.ssl,
      res.socket,
      header,
      "start_chunked_header_short_write"
    )
    return wrote >= header.len

  if res.requestSeq < sockData.nextWriteSeq:
    return false

  var queued = QueuedResponse(
    header: header,
    body: "",
    headerPos: 0,
    bodyPos: 0,
    isFileBody: false,
    fileFd: -1,
    fileOffset: 0.Off,
    fileRemaining: 0.Off,
    closeAfterWrite: false,
    isStreamBody: true,
    streamOpen: true,
    hasTryEnd: true,
    tryEndOffset: 0,
    tryEndTotal: 0,
    writableHandler: res.writableHandler
  )

  if res.requestSeq == sockData.nextWriteSeq and sockData.pendingIsEmpty() and sockData.shouldAutoFlush():
    var wrote = 0'i64
    let done = writeQueuedResponse(sockData, res.ssl, res.socket, queued, wrote)
    if done:
      # Stream responses should remain open until finishChunkedStream.
      queued.streamOpen = true
    if not sockData.enqueuePendingResponse(res.requestSeq, queued):
      discard closeSocketTracked(sockData.server, res.ssl, res.socket, "start_chunked_enqueue_failure_head")
      return false
    if sockData.shouldAutoFlush():
      flushPendingResponses(sockData, res.socket)
    else:
      registerPendingFlush(sockData, res.socket)
    return true

  if not sockData.enqueuePendingResponse(res.requestSeq, queued):
    discard closeSocketTracked(sockData.server, res.ssl, res.socket, "start_chunked_enqueue_failure")
    return false
  if sockData.shouldAutoFlush():
    flushPendingResponses(sockData, res.socket)
  else:
    registerPendingFlush(sockData, res.socket)
  true

## Queue a framed chunk payload for an active chunked stream
proc writeChunkedStream*(res: HttpResponse, chunk: sink string): bool =
  ## Queue a chunk payload for an active chunked stream.
  res.assertResponseLoopAffinity("writeChunkedStream")
  if res.socket == nil and res.captureForward != nil:
    res.captureBypassCache = true
    return res.captureForward.writeChunkedStream(move(chunk))
  if res.h2StreamId > 0 and res.h2Conn != nil:
    return h2WriteChunkedStream(res, chunk)
  if not res.chunkedStarted or res.chunkedFinished:
    return false
  if res.requestMethod == hmHead:
    return true
  if chunk.len == 0:
    return true

  var frame = newStringOfCap(chunk.len + 16)
  frame.add(toHexNoPrefix(chunk.len))
  frame.add("\r\n")
  frame.add(chunk)
  frame.add("\r\n")

  let sockData = socketDataFor(res.ssl, res.socket)
  if res.socket == nil:
    res.capturedBody.add(frame)
    res.capturedRaw.add(frame)
    return true
  if sockData == nil or sockData.server == nil:
    discard writeFallbackPayloadAndMaybeClose(
      nil,
      res.ssl,
      res.socket,
      frame,
      "write_chunked_frame_short_write"
    )
    return true

  if not appendPendingStreamChunk(sockData, res.requestSeq, frame, false, false):
    discard closeSocketTracked(sockData.server, res.ssl, res.socket, "write_chunked_append_failure")
    return false
  if high(uint64) - res.tryEndQueued < uint64(frame.len):
    res.tryEndQueued = high(uint64)
  else:
    res.tryEndQueued += uint64(frame.len)
  if sockData.shouldAutoFlush():
    flushPendingResponses(sockData, res.socket)
  else:
    registerPendingFlush(sockData, res.socket)
  true

## Finalize a chunked stream by sending the terminating zero-length chunk
proc finishChunkedStream*(res: HttpResponse, closeAfterWrite: bool = false): bool =
  ## Finalize a chunked stream by sending terminating chunk.
  res.assertResponseLoopAffinity("finishChunkedStream")
  if res.socket == nil and res.captureForward != nil:
    res.captureBypassCache = true
    let finished = res.captureForward.finishChunkedStream(closeAfterWrite)
    if finished:
      res.chunkedFinished = true
    return finished
  if res.h2StreamId > 0 and res.h2Conn != nil:
    return h2FinishChunkedStream(res)
  if not res.chunkedStarted or res.chunkedFinished:
    return false

  let shouldClose = closeAfterWrite or res.connectionClose
  if res.requestMethod == hmHead:
    if shouldClose:
      let sockData = socketDataFor(res.ssl, res.socket)
      let server = if sockData != nil: sockData.server else: nil
      discard closeSocketTracked(server, res.ssl, res.socket, "finish_chunked_head_close")
    res.chunkedFinished = true
    return true

  let finalFrame = "0\r\n\r\n"

  let sockData = socketDataFor(res.ssl, res.socket)
  if res.socket == nil:
    res.capturedBody.add(finalFrame)
    res.capturedRaw.add(finalFrame)
    res.chunkedFinished = true
    return true
  if sockData == nil or sockData.server == nil:
    let wrote = writeFallbackPayloadAndMaybeClose(
      nil,
      res.ssl,
      res.socket,
      finalFrame,
      "finish_chunked_final_frame_short_write"
    )
    if shouldClose and wrote >= finalFrame.len:
      discard closeSocketTracked(nil, res.ssl, res.socket, "finish_chunked_final_frame_close_after_write")
    res.chunkedFinished = true
    return wrote >= finalFrame.len

  if not appendPendingStreamChunk(sockData, res.requestSeq, finalFrame, true, shouldClose):
    discard closeSocketTracked(sockData.server, res.ssl, res.socket, "finish_chunked_append_failure")
    return false
  if high(uint64) - res.tryEndQueued < uint64(finalFrame.len):
    res.tryEndQueued = high(uint64)
  else:
    res.tryEndQueued += uint64(finalFrame.len)
  if sockData.shouldAutoFlush():
    flushPendingResponses(sockData, res.socket)
  else:
    registerPendingFlush(sockData, res.socket)
  res.chunkedFinished = true
  true

## Send a JSON response with the JSON content type set
proc json*(res: HttpResponse, data: string) {.inline.} =
  ## Send JSON response
  res.setHeader(HeaderContentType, "application/json; charset=utf-8")
  res.`end`(data)

## Send an HTML response with the text/html content type set
proc html*(res: HttpResponse, data: string) {.inline.} =
  ## Send HTML response
  res.setHeader(HeaderContentType, "text/html; charset=utf-8")
  res.`end`(data)

# WebSocket functions
proc buildSimpleResponse(statusCode: int, reason: string, extraHeaders: string = ""): string {.inline.} =
  result = newStringOfCap(136 + extraHeaders.len)
  result.add("HTTP/1.1 ")
  fastIntToStr(statusCode, result)
  result.add(" ")
  result.add(reason)
  result.add("\r\n")
  if extraHeaders.len > 0:
    result.add(extraHeaders)
  result.add(formatDateHeaderLine(getTime().toUnix))
  result.add("content-length: 0\r\nconnection: close\r\n\r\n")

## Return the value of a classified known header kind, or an empty string when absent
proc knownHeaderValue*(req: HttpRequest, kind: ParsedHeaderKind): string {.inline.} =
  if kind == hkHost and req.cachedHostStr.len > 0:
    return req.cachedHostStr
  if kind in req.knownHeaderPresent:
    return materializeSlice(req.bufferPtr, req.knownHeaders[kind])
  ""

proc materializeRawHeaderKey(bufPtr: pointer, raw: RawHeaderSlice): string {.inline.} =
  let n = int(raw.keyEnd - raw.keyStart)
  if n <= 0 or bufPtr == nil:
    return ""
  result = newStringOfCap(n)
  let base = cast[ptr UncheckedArray[byte]](bufPtr)
  for i in 0 ..< n:
    result.add(char(ToLowerTable[base[int(raw.keyStart) + i]]))

## Populate the full request header map from the deferred raw header slices on demand
proc ensureHeadersPopulated*(req: HttpRequest) {.inline.} =
  if not req.headersDeferred:
    return
  req.headersDeferred = false
  if req.headers == nil:
    req.headers = newFastMap[string]()
    discard req.headers.reserve(16)
  if hkContentLength in req.knownHeaderPresent:
    discard req.headers.putHashed(HeaderContentLength, hashContentLength, req.knownHeaderValue(hkContentLength))
  if hkTransferEncoding in req.knownHeaderPresent:
    discard req.headers.putHashed(HeaderTransferEncoding, hashTransferEncoding, req.knownHeaderValue(hkTransferEncoding))
  if hkConnection in req.knownHeaderPresent:
    discard req.headers.putHashed(HeaderConnection, hashConnection, req.knownHeaderValue(hkConnection))
  if hkHost in req.knownHeaderPresent:
    discard req.headers.putHashed(HeaderHost, hashHost, req.knownHeaderValue(hkHost))
  if hkExpect in req.knownHeaderPresent:
    discard req.headers.putHashed(HeaderExpect, hashExpect, req.knownHeaderValue(hkExpect))
  if req.upgradeHeader.len > 0:
    discard req.headers.putHashed(HeaderUpgrade, hashUpgrade, req.upgradeHeader)
  if req.secWebSocketKeyHeader.len > 0:
    discard req.headers.putHashed(HeaderSecWebSocketKey, hashSecWebSocketKey, req.secWebSocketKeyHeader)
  if req.secWebSocketVersionHeader.len > 0:
    discard req.headers.putHashed(HeaderSecWebSocketVersion, hashSecWebSocketVersion, req.secWebSocketVersionHeader)
  if req.secWebSocketExtensionsHeader.len > 0:
    discard req.headers.putHashed(HeaderSecWebSocketExtensions, hashSecWebSocketExtensions, req.secWebSocketExtensionsHeader)
  if req.contentTypeHeader.len > 0:
    discard req.headers.putHashed(HeaderContentType, hashContentType, req.contentTypeHeader)
  if req.cookieHeader.len > 0:
    putMergedCookieHeader(req, req.cookieHeader)
  if req.rawHeaderCount > 0 and req.bufferPtr != nil:
    let bufData = cast[ptr UncheckedArray[byte]](req.bufferPtr)
    for i in 0 ..< int(req.rawHeaderCount):
      let raw = req.rawHeaders[i]
      if not req.rawHeadersClassified and raw.kind == hkNone:
        let kind = classifyHeaderToken(bufData.toOpenArray(0, int(req.bufferLen) - 1), int(raw.keyStart), int(raw.keyEnd))
        if kind != hkNone:
          let value = materializeSlice(req.bufferPtr, ByteSlice(startPos: raw.valStart, endPos: raw.valEnd))
          case kind
          of hkContentType:
            req.headerFlags = req.headerFlags or HfContentType
            if req.contentTypeStr.len == 0:
              req.contentTypeStr = value
            discard req.headers.putHashed(HeaderContentType, hashContentType, value)
          of hkCookie:
            req.headerFlags = req.headerFlags or HfCookie
            if req.cookieStr.len == 0:
              req.cookieStr = value
            putMergedCookieHeader(req, value)
          else:
            discard
          continue
      if raw.kind == hkCookie:
        putMergedCookieHeader(req, materializeSlice(req.bufferPtr, ByteSlice(startPos: raw.valStart, endPos: raw.valEnd)))
      else:
        let key = materializeRawHeaderKey(req.bufferPtr, raw)
        let value = materializeSlice(req.bufferPtr, ByteSlice(startPos: raw.valStart, endPos: raw.valEnd))
        req.headers[key] = value
    req.rawHeadersClassified = true

proc hasHeaderFlag(req: HttpRequest, flag: uint32): bool {.inline.} =
  req != nil and (req.headerFlags and flag) != 0'u32

## Zero-copy alias of the request path accessor
proc pathView*(req: HttpRequest): lent string {.inline.} =
  req.path

## Zero-copy alias of the raw query string accessor
proc queryStringRawView*(req: HttpRequest): lent string {.inline.} =
  req.queryStringRaw

proc requestWsUpgradeHeaderView(req: HttpRequest): fast_map.FastStringView {.inline.} =
  if req == nil:
    return default(fast_map.FastStringView)
  if req.upgradeHeader.len > 0:
    return fast_map.toFastStringView(req.upgradeHeader)
  if req.headers != nil:
    return req.headers.getViewHashed(HeaderUpgrade, hashUpgrade)
  default(fast_map.FastStringView)

proc requestWsUpgradeHeader(req: HttpRequest): string {.inline, used.} =
  $req.requestWsUpgradeHeaderView()

proc requestWsKeyHeaderView(req: HttpRequest): fast_map.FastStringView {.inline.} =
  if req == nil:
    return default(fast_map.FastStringView)
  if req.secWebSocketKeyHeader.len > 0:
    return fast_map.toFastStringView(req.secWebSocketKeyHeader)
  if req.headers != nil:
    return req.headers.getViewHashed(HeaderSecWebSocketKey, hashSecWebSocketKey)
  default(fast_map.FastStringView)

proc requestWsKeyHeader(req: HttpRequest): string {.inline.} =
  $req.requestWsKeyHeaderView()

proc requestWsVersionHeaderView(req: HttpRequest): fast_map.FastStringView {.inline.} =
  if req == nil:
    return default(fast_map.FastStringView)
  if req.secWebSocketVersionHeader.len > 0:
    return fast_map.toFastStringView(req.secWebSocketVersionHeader)
  if req.headers != nil:
    return req.headers.getViewHashed(HeaderSecWebSocketVersion, hashSecWebSocketVersion)
  default(fast_map.FastStringView)

proc requestWsVersionHeader(req: HttpRequest): string {.inline, used.} =
  $req.requestWsVersionHeaderView()

proc requestWsExtensionsHeaderView(req: HttpRequest): fast_map.FastStringView {.inline.} =
  if req == nil:
    return default(fast_map.FastStringView)
  if req.secWebSocketExtensionsHeader.len > 0:
    return fast_map.toFastStringView(req.secWebSocketExtensionsHeader)
  if req.headers != nil:
    return req.headers.getViewHashed(HeaderSecWebSocketExtensions, hashSecWebSocketExtensions)
  default(fast_map.FastStringView)

proc requestWsExtensionsHeader(req: HttpRequest): string {.inline.} =
  $req.requestWsExtensionsHeaderView()

type WsCompressionOffer = object
  present: bool
  serverNoContextTakeover: bool
  clientNoContextTakeover: bool

proc trimAsciiToken(value: string): string {.inline.} =
  if value.len == 0:
    return ""
  value.strip(chars = {' ', '\t'})

proc parseWsCompressionOffer(extensionsHeader: string): WsCompressionOffer =
  if extensionsHeader.len == 0:
    return
  for extToken in extensionsHeader.split(','):
    let trimmedExt = extToken.trimAsciiToken()
    if trimmedExt.len == 0:
      continue
    let segments = trimmedExt.split(';')
    if segments.len == 0:
      continue
    if segments[0].trimAsciiToken().toLowerAscii() != WsPerMessageDeflateExtension:
      continue
    result.present = true
    for i in 1..<segments.len:
      let param = segments[i].trimAsciiToken().toLowerAscii()
      if param == "server_no_context_takeover":
        result.serverNoContextTakeover = true
      elif param == "client_no_context_takeover":
        result.clientNoContextTakeover = true
    return

## Decide whether a websocket payload should be compressed given negotiated and backpressure state
proc wsCompressionDecision*(
  options: ServerOptions,
  negotiated: bool,
  payloadBytes: int,
  isBinary: bool,
  bypassCompression: bool,
  pendingBackpressureBytes: int64
): bool {.inline.} =
  if not negotiated or not options.wsCompressionEnabled:
    return false
  if bypassCompression or payloadBytes <= 0:
    return false
  if options.wsCompressionDisableForBinary and isBinary:
    return false
  if options.wsCompressionDisableForText and (not isBinary):
    return false
  let minBytes = if options.wsCompressionMinBytes > 0:
    options.wsCompressionMinBytes
  else:
    DefaultWsCompressionMinBytes
  if payloadBytes < minBytes:
    return false
  if options.wsCompressionBackpressureBypassBytes > 0 and
     pendingBackpressureBytes >= int64(options.wsCompressionBackpressureBypassBytes):
    return false
  true

## Build the permessage-deflate response extension header when compression can be negotiated
proc negotiateWsCompressionHeader*(extensionsHeader: string, options: ServerOptions): string =
  if not options.wsCompressionEnabled:
    return ""
  if not options.wsCompressionServerNoContextTakeover or
     not options.wsCompressionClientNoContextTakeover:
    return ""
  let offer = parseWsCompressionOffer(extensionsHeader)
  if not offer.present:
    return ""
  result = "Sec-WebSocket-Extensions: " & WsPerMessageDeflateExtension &
    "; server_no_context_takeover; client_no_context_takeover\r\n"

proc hasDeflateTail(payload: string): bool {.inline.} =
  let n = payload.len
  n >= 4 and
    payload[n - 4] == char(0x00) and
    payload[n - 3] == char(0x00) and
    payload[n - 2] == char(0xFF) and
    payload[n - 1] == char(0xFF)

var wsPerMessageDeflateCompressorReady {.threadvar.}: bool
var wsPerMessageDeflateCompressor {.threadvar.}: libdeflate_gzip.Compressor

proc ensureWsPerMessageDeflateCompressor() {.inline.} =
  if not wsPerMessageDeflateCompressorReady:
    wsPerMessageDeflateCompressor = libdeflate_gzip.newCompressor(1)
    wsPerMessageDeflateCompressorReady = true

proc compressWsPayload(payload: string): tuple[ok: bool, compressed: string] {.inline.} =
  if payload.len == 0:
    return (true, "")
  try:
    ensureWsPerMessageDeflateCompressor()
    let bound = wsPerMessageDeflateCompressor.compressDeflateBound(payload.len) + 8
    if bound <= 0:
      return (false, "")
    result.compressed = newString(bound)
    let written = wsPerMessageDeflateCompressor.compressDeflateSyncFlush(
      unsafeAddr payload[0],
      payload.len,
      addr result.compressed[0],
      bound
    )
    if written <= 4:
      return (false, "")
    result.compressed.setLen(written - 4)
    result.ok = true
  except CatchableError:
    result = (false, "")

proc wsCompressionInflateLimit(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultMaxBodySize
  if server.options.maxBodySize > 0:
    return server.options.maxBodySize
  DefaultMaxBodySize

const
  MaxWsCompressionRatio = 1024

proc decompressWsPayload(
  payload: string,
  maxOutputBytes: int
): tuple[ok: bool, plain: string, tooLarge: bool] {.inline.} =
  let limit = min(payload.len * MaxWsCompressionRatio, max(0, maxOutputBytes))
  if limit <= 0:
    return (false, "", true)
  if payload.len > limit:
    return (false, "", true)
  let needsTail = not payload.hasDeflateTail()
  let framedLen = if needsTail: payload.len + 4 else: payload.len
  if framedLen > limit:
    return (false, "", true)
  var framed: string
  if needsTail:
    framed = newStringUninit(framedLen)
    copyMem(addr framed[0], unsafeAddr payload[0], payload.len)
    framed[payload.len] = '\x00'
    framed[payload.len + 1] = '\x00'
    framed[payload.len + 2] = '\xFF'
    framed[payload.len + 3] = '\xFF'
  else:
    framed = payload
  try:
    var plain = ""
    zippy_inflate.inflate(
      plain,
      cast[ptr UncheckedArray[uint8]](unsafeAddr framed[0]),
      framed.len,
      0,
      limit,
      allowSyncFlushEof = true
    )
    if plain.len > limit:
      return (false, "", true)
    if payload.len > 0 and plain.len div payload.len > MaxWsCompressionRatio:
      return (false, "", true)
    result.ok = true
    result.plain = move(plain)
    result.tooLarge = false
  except CatchableError as err:
    result = (false, "", err.msg == zippy.InflateOutputLimitExceeded)

## Check whether the request is a valid WebSocket upgrade handshake request
proc isWebSocketUpgrade*(req: HttpRequest): bool {.inline.} =
  ## Check if request is a WebSocket upgrade
  if req == nil:
    return false
  if not req.hasHeaderFlag(HfUpgrade):
    return false
  let upgrade = req.requestWsUpgradeHeaderView()
  if upgrade.len == 0:
    return false
  let hasUpgradeConnection =
    req.connectionHasUpgrade or (
      req.hasHeaderFlag(HfConnection) and req.headers != nil and
      containsHeaderTokenNoCase(req.headers.getViewHashed(HeaderConnection, hashConnection), "upgrade")
    )
  result = hasUpgradeConnection and upgrade.equalsIgnoreCaseAscii("websocket")

proc isValidWebSocketKey(key: string): bool {.inline.} =
  if key.len == 0:
    return false
  try:
    let decoded = base64.decode(key)
    decoded.len == 16
  except CatchableError:
    false

proc validateWebSocketUpgrade(req: HttpRequest): tuple[ok: bool, statusCode: int, reason: string, extraHeaders: string] {.inline.} =
  if req == nil:
    return (false, 400, "Bad Request", "")
  if req.methodKind != hmGet:
    return (false, 400, "Bad Request", "")
  if req.httpMajor < 1 or (req.httpMajor == 1 and req.httpMinor < 1):
    return (false, 400, "Bad Request", "")
  if not req.hasHeaderFlag(HfHost):
    return (false, 400, "Bad Request", "")
  let upgrade = req.requestWsUpgradeHeaderView()
  if not upgrade.equalsIgnoreCaseAscii("websocket"):
    return (false, 400, "Bad Request", "")
  let hasUpgradeConnection =
    req.connectionHasUpgrade or (
      req.hasHeaderFlag(HfConnection) and req.headers != nil and
      containsHeaderTokenNoCase(req.headers.getViewHashed(HeaderConnection, hashConnection), "upgrade")
    )
  if not hasUpgradeConnection:
    return (false, 400, "Bad Request", "")
  if not req.requestWsVersionHeaderView().equalsAscii("13"):
    return (false, 426, "Upgrade Required", "Sec-WebSocket-Version: 13\r\n")
  let wsKey = $req.requestWsKeyHeaderView()
  if not wsKey.isValidWebSocketKey():
    return (false, 400, "Bad Request", "")
  (true, 101, "", "")

const
  WsUpgradeResponsePrefix {.used.} =
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
  WsUpgradeResponseSuffix {.used.} = "\r\n\r\n"
  WsAcceptKeyBufCap = 24 + 36

var wsAcceptKeyBuf {.threadvar.}: string

proc generateAcceptKey(key: string): string {.inline.} =
  if wsAcceptKeyBuf.len == 0:
    wsAcceptKeyBuf = newString(WsAcceptKeyBufCap)
  let keyLen = min(key.len, 24)
  let guid = WebSocketGuid
  if keyLen > 0:
    copyMem(addr wsAcceptKeyBuf[0], unsafeAddr key[0], keyLen)
  copyMem(addr wsAcceptKeyBuf[keyLen], unsafeAddr guid[0], 36)
  wsAcceptKeyBuf.setLen(keyLen + 36)
  let bytes = secureHashBytes(wsAcceptKeyBuf)
  result = base64.encode(bytes)

## Validate and complete the WebSocket upgrade handshake, returning the new websocket or nil
proc upgradeToWebSocket*(req: HttpRequest, res: HttpResponse): WebSocket =
  if req == nil or res == nil:
    return nil
  let validation = validateWebSocketUpgrade(req)
  if not validation.ok:
    return nil
  let wsKey = req.requestWsKeyHeader()
  if wsKey.len == 0:
    return nil

  let sockData = socketDataFor(res.ssl, res.socket)
  if sockData != nil and sockData.hasFlag(SDF_IS_WEBSOCKET):
    return nil
  var wsCompressionHeader = ""
  if sockData != nil and sockData.server != nil:
    wsCompressionHeader = negotiateWsCompressionHeader(req.requestWsExtensionsHeader(), sockData.server.options)
  let compressionEnabled = wsCompressionHeader.len > 0

  let acceptKey = generateAcceptKey(wsKey)

  var response: string
  if wsCompressionHeader.len == 0:
    response = newStringOfCap(WsUpgradeResponsePrefix.len + 28 + WsUpgradeResponseSuffix.len)
    response.add(WsUpgradeResponsePrefix)
    response.add(acceptKey)
    response.add(WsUpgradeResponseSuffix)
  else:
    response = newStringOfCap(128 + wsCompressionHeader.len)
    response.add("HTTP/1.1 101 Switching Protocols\r\n")
    response.add("Upgrade: websocket\r\n")
    response.add("Connection: Upgrade\r\n")
    response.add("Sec-WebSocket-Accept: ")
    response.add(acceptKey)
    response.add("\r\n")
    response.add(wsCompressionHeader)
    response.add("\r\n")

  res.sendPreparedResponse(response, "", false)
  res.headersSent = true
  res.bodySent = true

  result = acquireWebSocket(res.socket, res.ssl, compressionEnabled)
  if sockData != nil:
    sockData.setFlagTo(SDF_WS_COMPRESSION_ACTIVE, compressionEnabled)

proc wsFrameHeaderLen(payloadLen: int): int {.inline.} =
  if payloadLen < 126:
    return 2
  if payloadLen < 65536:
    return 4
  10

proc wsFrameTotalLen(payloadLen: int): int {.inline.} =
  wsFrameHeaderLen(payloadLen) + payloadLen

proc writeWsFrame(
  ssl: cint,
  s: UsSocketPtr,
  opcode: WebSocketOpcode,
  payload: string,
  rsv1: bool = false
): cint {.inline.} =
  if s == nil:
    return 0

  var header: array[10, char]
  var h = 0
  header[h] = char(0x80 or ord(opcode) or (if rsv1: 0x40 else: 0))
  inc h

  let length = payload.len
  if length < 126:
    header[h] = char(length)
    inc h
  elif length < 65536:
    header[h] = char(126)
    inc h
    header[h] = char((length shr 8) and 0xFF)
    inc h
    header[h] = char(length and 0xFF)
    inc h
  else:
    header[h] = char(127)
    inc h
    for i in countdown(7, 0):
      header[h] = char((length shr (i * 8)) and 0xFF)
      inc h

  if length == 0:
    return writeSocketChecked(ssl, s, cast[cstring](addr header[0]), h).cint

  if h + length <= SmallFrameStackLimit:
    var buf: array[SmallFrameStackLimit, char]
    copyMem(addr buf[0], addr header[0], h)
    copyMem(addr buf[h], unsafeAddr payload[0], length)
    return writeSocketChecked(ssl, s, cast[cstring](addr buf[0]), h + length).cint

  writeSocketChecked2(
    ssl,
    s,
    cast[cstring](addr header[0]),
    h,
    payload.cstring,
    length
  ).cint

proc writeWsFramePtr(
  ssl: cint,
  s: UsSocketPtr,
  opcode: WebSocketOpcode,
  payloadPtr: pointer,
  payloadLen: int,
  rsv1: bool = false
): cint {.inline.} =
  if s == nil:
    return 0

  var header: array[10, char]
  var h = 0
  header[h] = char(0x80 or ord(opcode) or (if rsv1: 0x40 else: 0))
  inc h

  let length = max(0, payloadLen)
  if length < 126:
    header[h] = char(length)
    inc h
  elif length < 65536:
    header[h] = char(126)
    inc h
    header[h] = char((length shr 8) and 0xFF)
    inc h
    header[h] = char(length and 0xFF)
    inc h
  else:
    header[h] = char(127)
    inc h
    for i in countdown(7, 0):
      header[h] = char((length shr (i * 8)) and 0xFF)
      inc h

  if length == 0 or payloadPtr == nil:
    return writeSocketChecked(ssl, s, cast[cstring](addr header[0]), h).cint

  if h + length <= SmallFrameStackLimit:
    var buf: array[SmallFrameStackLimit, char]
    copyMem(addr buf[0], addr header[0], h)
    copyMem(addr buf[h], payloadPtr, length)
    return writeSocketChecked(ssl, s, cast[cstring](addr buf[0]), h + length).cint

  writeSocketChecked2(
    ssl,
    s,
    cast[cstring](addr header[0]),
    h,
    cast[cstring](payloadPtr),
    length
  ).cint

proc buildWsFrame(opcode: WebSocketOpcode, payload: string, rsv1: bool = false): string {.inline.} =
  let length = payload.len
  let hdrLen = wsFrameHeaderLen(length)
  result = newStringUninit(hdrLen + length)
  result[0] = char(0x80 or ord(opcode) or (if rsv1: 0x40 else: 0))
  if length < 126:
    result[1] = char(length)
  elif length < 65536:
    result[1] = char(126)
    result[2] = char((length shr 8) and 0xFF)
    result[3] = char(length and 0xFF)
  else:
    result[1] = char(127)
    for i in 0..7:
      result[2 + i] = char((length shr ((7 - i) * 8)) and 0xFF)
  if length > 0:
    copyMem(addr result[hdrLen], unsafeAddr payload[0], length)

proc buildWsFrameFromPtr(
  opcode: WebSocketOpcode,
  payloadPtr: pointer,
  payloadLen: int,
  rsv1: bool = false
): string {.inline.} =
  let length = max(0, payloadLen)
  let hdrLen = wsFrameHeaderLen(length)
  result = newStringUninit(hdrLen + length)
  result[0] = char(0x80 or ord(opcode) or (if rsv1: 0x40 else: 0))
  if length < 126:
    result[1] = char(length)
  elif length < 65536:
    result[1] = char(126)
    result[2] = char((length shr 8) and 0xFF)
    result[3] = char(length and 0xFF)
  else:
    result[1] = char(127)
    for i in 0..7:
      result[2 + i] = char((length shr ((7 - i) * 8)) and 0xFF)
  if length > 0 and payloadPtr != nil:
    copyMem(addr result[hdrLen], payloadPtr, length)

when defined(singleThread) or not compileOption("threads"):
  var wsFrameReuseBuf: string
else:
  var wsFrameReuseBuf {.threadvar.}: string

proc buildWsFrameReuse(opcode: WebSocketOpcode, payload: string, rsv1: bool = false): string {.inline, used.} =
  let length = payload.len
  let hdrLen = wsFrameHeaderLen(length)
  let totalLen = hdrLen + length
  if wsFrameReuseBuf.len < totalLen:
    wsFrameReuseBuf = newStringOfCap(max(totalLen, 4096))
  wsFrameReuseBuf.setLen(totalLen)
  wsFrameReuseBuf[0] = char(0x80 or ord(opcode) or (if rsv1: 0x40 else: 0))
  if length < 126:
    wsFrameReuseBuf[1] = char(length)
  elif length < 65536:
    wsFrameReuseBuf[1] = char(126)
    wsFrameReuseBuf[2] = char((length shr 8) and 0xFF)
    wsFrameReuseBuf[3] = char(length and 0xFF)
  else:
    wsFrameReuseBuf[1] = char(127)
    for i in 0..7:
      wsFrameReuseBuf[2 + i] = char((length shr ((7 - i) * 8)) and 0xFF)
  if length > 0:
    copyMem(addr wsFrameReuseBuf[hdrLen], unsafeAddr payload[0], length)
  wsFrameReuseBuf

proc buildWsCoalescedChunk(
  sockData: ptr SocketData,
  maxBytes: int,
  maxFrames: int
): int {.inline.} =
  if sockData == nil or maxBytes <= 0 or maxFrames <= 0:
    return 0
  if sockData.wsQueueIsEmpty():
    return 0
  var idx = sockData.wsOutHead
  var framesAdded = 0
  var remainingBudget = maxBytes
  sockData.wsCoalesceBuffer.setLen(0)
  while idx < sockData.wsOutQueue.len and framesAdded < maxFrames and remainingBudget > 0:
    let entry = sockData.wsOutQueue[idx]
    if entry.paletteIdx < 0 or entry.paletteIdx >= sockData.wsOutPalette.len:
      break
    let frame = sockData.wsOutPalette[entry.paletteIdx]
    var pos = entry.frameOffset
    if idx == sockData.wsOutHead:
      pos += sockData.wsOutPos
    if pos >= frame.len:
      break
    let available = frame.len - pos
    let take = min(available, remainingBudget)
    if take <= 0:
      break
    let oldLen = sockData.wsCoalesceBuffer.len
    sockData.wsCoalesceBuffer.setLen(oldLen + take)
    copyMem(addr sockData.wsCoalesceBuffer[oldLen], unsafeAddr frame[pos], take)
    remainingBudget -= take
    if take >= available:
      inc framesAdded
      inc idx
    else:
      break
  sockData.wsCoalesceBuffer.len

proc flushWsQueuedFrames(sockData: ptr SocketData, s: UsSocketPtr) =
  if sockData == nil or s == nil or sockData.wsQueueIsEmpty():
    return
  let ssl = sockData.server.ssl.toInt
  if us_socket_is_closed(ssl, s) != 0 or us_socket_is_shut_down(ssl, s) != 0:
    return
  let writeIterationsBudget = sockData.writeBudgetIterationsFor()
  let writeBytesBudget = sockData.writeBudgetBytesFor()
  var flushIterations = 0
  var flushBytes = 0'i64
  var yieldedForBudget = false

  while not sockData.wsQueueIsEmpty():
    if flushIterations >= writeIterationsBudget or
       flushBytes >= writeBytesBudget or
       sockData.server.writeLoopBudgetExhausted():
      yieldedForBudget = true
      break
    if sockData.wsOutHead >= sockData.wsOutQueue.len:
      break
    let entry = sockData.wsOutQueue[sockData.wsOutHead]
    let paletteIdx = entry.paletteIdx
    if paletteIdx < 0 or paletteIdx >= sockData.wsOutPalette.len:
      sockData.wsQueueReleaseHead()
      continue
    let canCoalesce = sockData.wsOutPos == 0 and
      sockData.wsWriteCoalesceFramesFor() > 1 and
      (sockData.wsOutQueue.len - sockData.wsOutHead) > 1
    var targetBytes = 0
    var written = 0
    if canCoalesce:
      let maxCoalesceBytes = sockData.wsWriteCoalesceBytesFor()
      let maxCoalesceFrames = sockData.wsWriteCoalesceFramesFor()
      targetBytes = sockData.buildWsCoalescedChunk(maxCoalesceBytes, maxCoalesceFrames)
      if targetBytes > 0:
        written = writeSocketChecked(ssl, s, sockData.wsCoalesceBuffer.cstring, targetBytes)
    if written <= 0:
      let frame = sockData.wsOutPalette[paletteIdx]
      let basePos = entry.frameOffset + sockData.wsOutPos
      if basePos >= frame.len:
        sockData.wsQueueReleaseHead()
        continue
      let remaining = frame.len - basePos
      targetBytes = remaining
      written = writeSocketChecked(
        ssl,
        s,
        cast[cstring](unsafeAddr frame[basePos]),
        remaining
      )
    if written <= 0:
      break
    sockData.server.emitAfterWrite(written, true, true)
    sockData.refreshWsIdleTimeout(s, onSendPath = true)
    sockData.server.consumeLoopWriteBudget(int64(written))
    inc flushIterations
    let consumedBytes = sockData.consumeWsQueueBytes(written)
    flushBytes += int64(consumedBytes)
    if consumedBytes < targetBytes:
      break

  if sockData.wsQueueIsEmpty():
    sockData.wsQueueReset()
    if sockData.hasFlag(SDF_WS_HAD_BACKPRESSURE) and sockData.server != nil and sockData.ws != nil:
      sockData.server.enqueueWsDrain(sockData.ws)
    sockData.clearFlag(SDF_WS_HAD_BACKPRESSURE)
  elif sockData.wsOutHead >= PendingCompactThreshold and sockData.wsOutHead * 2 >= sockData.wsOutQueue.len:
    sockData.compactWsQueue()
  if yieldedForBudget and not sockData.wsQueueIsEmpty():
    sockData.scheduleWsFlush(s)

proc emitWsHighWaterPolicy(
  sockData: ptr SocketData,
  ws: WebSocket,
  bufferedBytes: int64,
  action: BackpressureHighWaterAction
) {.inline.} =
  if sockData == nil or sockData.server == nil:
    return
  inc sockData.server.metricsBackpressureHighWaterEvents
  if sockData.server.wsHighWaterHandler != nil:
    try:
      sockData.server.wsHighWaterHandler(ws, max(0'i64, bufferedBytes), action)
    except CatchableError as err:
      sockData.server.emitServerPanic("wsHighWaterHandler", err.msg)

proc recordWsDrop(sockData: ptr SocketData, ws: WebSocket, payloadBytes: int, isBinary: bool) {.inline.} =
  if sockData == nil or sockData.server == nil or ws == nil:
    return
  inc sockData.server.metricsBackpressureDrops
  if sockData.server.wsDroppedHandler != nil:
    try:
      sockData.server.wsDroppedHandler(ws, payloadBytes, isBinary)
    except CatchableError as err:
      sockData.server.emitServerPanic("wsDroppedHandler", err.msg)

proc reclaimWsQueuedBytesOldest(
  sockData: ptr SocketData,
  ws: WebSocket,
  targetBytes: int64,
  preserveControlFrames: bool = false
): int64 {.inline.} =
  if sockData == nil or targetBytes <= 0:
    return 0
  var i = sockData.wsOutHead
  if i < sockData.wsOutQueue.len and sockData.wsOutPos > 0:
    inc i
  while i < sockData.wsOutQueue.len and result < targetBytes:
    let entry = sockData.wsOutQueue[i]
    if preserveControlFrames and entry.isControl:
      inc i
      continue
    if entry.paletteIdx >= 0 and entry.paletteIdx < sockData.wsOutPalette.len:
      let frame = sockData.wsOutPalette[entry.paletteIdx]
      let queuedBytes = max(0, frame.len - entry.frameOffset)
      if queuedBytes > 0:
        result += int64(queuedBytes)
        if ws != nil:
          sockData.recordWsDrop(ws, entry.payloadBytes, entry.isBinary)
      sockData.wsOutQueue[i] = WsQueuedFrame(paletteIdx: -1)
      sockData.wsQueuePaletteRelease(entry.paletteIdx)
    inc i
  if result > 0:
    sockData.wsPendingBytes = max(0'i64, sockData.wsPendingBytes - result)
    while sockData.wsOutHead < sockData.wsOutQueue.len and
        sockData.wsOutQueue[sockData.wsOutHead].paletteIdx < 0:
      inc sockData.wsOutHead
      sockData.wsOutPos = 0
    if sockData.wsQueueIsEmpty():
      sockData.wsQueueReset()
    if sockData.wsOutHead >= PendingCompactThreshold and sockData.wsOutHead * 2 >= sockData.wsOutQueue.len:
      sockData.compactWsQueue()

proc enforceWsHighWaterPolicy(
  sockData: ptr SocketData,
  ws: WebSocket,
  payloadBytes: int,
  isBinary: bool,
  bytesToAdd: int64,
  preserveControlFrames: bool = false
): bool {.inline.} =
  if sockData == nil or sockData.server == nil or ws == nil:
    return true
  let decision = decideWsBackpressureHighWater(
    sockData.wsPendingBytes,
    bytesToAdd,
    sockData.wsHighWaterBackpressureFor(),
    sockData.server.options.wsBackpressureHighWaterAction
  )
  if not decision.triggered:
    return true
  sockData.emitWsHighWaterPolicy(ws, decision.projectedBytes, decision.action)
  case decision.action
  of bhwDropNewest:
    if preserveControlFrames:
      return true
    sockData.recordWsDrop(ws, payloadBytes, isBinary)
    return false
  of bhwClose:
    if preserveControlFrames:
      return true
    sockData.recordWsDrop(ws, payloadBytes, isBinary)
    ws.isOpen = false
    discard closeSocketTracked(sockData.server, ws.ssl, ws.socket, "ws_high_water_close")
    return false
  of bhwDropOldest:
    let needed = decision.projectedBytes - sockData.wsHighWaterBackpressureFor()
    let reclaimed = sockData.reclaimWsQueuedBytesOldest(
      ws,
      max(0'i64, needed),
      preserveControlFrames = preserveControlFrames
    )
    if decision.projectedBytes - reclaimed <= sockData.wsHighWaterBackpressureFor():
      return true
    sockData.recordWsDrop(ws, payloadBytes, isBinary)
    return false

proc handleWsDrop(sockData: ptr SocketData, ws: WebSocket, payloadBytes: int, isBinary: bool, forceClose: bool) {.inline.} =
  if sockData == nil or sockData.server == nil or ws == nil:
    return
  sockData.recordWsDrop(ws, payloadBytes, isBinary)
  if forceClose or sockData.server.options.wsCloseOnBackpressureLimit:
    ws.isOpen = false
    discard closeSocketTracked(sockData.server, ws.ssl, ws.socket, "ws_backpressure_limit_close")

proc sendWsFramedWithBackpressure(
  ws: WebSocket,
  frame: string,
  payloadBytes: int,
  isBinary: bool
): bool {.inline.} =
  if ws == nil or ws.socket == nil or not ws.isOpen:
    return false
  if frame.len == 0:
    return true
  let sockData = socketDataFor(ws.ssl, ws.socket)
  if sockData == nil or sockData.server == nil:
    let wrote = writeFallbackPayloadAndMaybeClose(nil, ws.ssl, ws.socket, frame, "ws_send_raw_fallback_short_write")
    return wrote >= frame.len

  sockData.server.emitBeforeWrite(frame.len, true)

  if not sockData.wsQueueIsEmpty():
    if not sockData.enforceWsHighWaterPolicy(ws, payloadBytes, isBinary, int64(frame.len)):
      sockData.server.emitBackpressure(sockData.wsPendingBytes + int64(frame.len), true)
      return false
    if not sockData.wsCanQueueBytes(int64(frame.len)):
      sockData.handleWsDrop(ws, payloadBytes, isBinary, false)
      sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
      return false
    sockData.queueWsFrame(frame, payloadBytes, isBinary)
    sockData.wsPendingBytes += int64(frame.len)
    sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
    sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
    sockData.scheduleWsFlush(ws.socket)
    return false

  let written = writeSocketChecked(ws.ssl, ws.socket, frame.cstring, frame.len)
  if written >= frame.len:
    sockData.refreshWsIdleTimeout(ws.socket, onSendPath = true)
    sockData.server.emitAfterWrite(written, true, true)
    return true

  let queuedTailLen = if written > 0: frame.len - written else: frame.len
  if not sockData.enforceWsHighWaterPolicy(ws, payloadBytes, isBinary, int64(queuedTailLen)):
    sockData.server.emitAfterWrite(max(0, written), false, true)
    sockData.server.emitBackpressure(sockData.wsPendingBytes + int64(queuedTailLen), true)
    return false
  if not sockData.wsCanQueueBytes(int64(queuedTailLen)):
    sockData.handleWsDrop(ws, payloadBytes, isBinary, written > 0)
    sockData.server.emitAfterWrite(max(0, written), false, true)
    sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
    return false

  if written > 0:
    sockData.refreshWsIdleTimeout(ws.socket, onSendPath = true)
    sockData.queueWsFrame(frame, payloadBytes, isBinary, written)
  else:
    sockData.queueWsFrame(frame, payloadBytes, isBinary)
  sockData.server.emitAfterWrite(max(0, written), written > 0, true)
  sockData.wsPendingBytes += int64(queuedTailLen)
  sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
  sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
  sockData.scheduleWsFlush(ws.socket)
  false

proc sendWsPtrWithBackpressure(
  ws: WebSocket,
  opcode: WebSocketOpcode,
  dataPtr: pointer,
  dataLen: int,
  isBinary: bool
): bool {.inline.} =
  if ws == nil or ws.socket == nil or not ws.isOpen:
    return false

  let payloadLen = max(0, dataLen)
  let frameTotalLen = wsFrameTotalLen(payloadLen)
  let sockData = socketDataFor(ws.ssl, ws.socket)
  if sockData == nil or sockData.server == nil:
    let written = int(writeWsFramePtr(ws.ssl, ws.socket, opcode, dataPtr, payloadLen, false))
    return written >= frameTotalLen

  sockData.server.emitBeforeWrite(frameTotalLen, true)

  if not sockData.wsQueueIsEmpty():
    if not sockData.enforceWsHighWaterPolicy(ws, payloadLen, isBinary, int64(frameTotalLen)):
      sockData.server.emitBackpressure(sockData.wsPendingBytes + int64(frameTotalLen), true)
      return false
    if not sockData.wsCanQueueBytes(int64(frameTotalLen)):
      sockData.handleWsDrop(ws, payloadLen, isBinary, false)
      sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
      return false
    let frame = buildWsFrameFromPtr(opcode, dataPtr, payloadLen, false)
    sockData.queueWsFrame(frame, payloadLen, isBinary)
    sockData.wsPendingBytes += int64(frame.len)
    sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
    sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
    sockData.scheduleWsFlush(ws.socket)
    return false

  let written = int(writeWsFramePtr(ws.ssl, ws.socket, opcode, dataPtr, payloadLen, false))
  if written >= frameTotalLen:
    sockData.refreshWsIdleTimeout(ws.socket, onSendPath = true)
    sockData.server.emitAfterWrite(written, true, true)
    return true

  let queuedTailLen = if written > 0: frameTotalLen - written else: frameTotalLen
  if not sockData.enforceWsHighWaterPolicy(ws, payloadLen, isBinary, int64(queuedTailLen)):
    sockData.server.emitAfterWrite(max(0, written), false, true)
    sockData.server.emitBackpressure(sockData.wsPendingBytes + int64(queuedTailLen), true)
    return false
  if not sockData.wsCanQueueBytes(int64(queuedTailLen)):
    sockData.handleWsDrop(ws, payloadLen, isBinary, written > 0)
    sockData.server.emitAfterWrite(max(0, written), false, true)
    sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
    return false

  let frame = buildWsFrameFromPtr(opcode, dataPtr, payloadLen, false)
  if written > 0:
    sockData.refreshWsIdleTimeout(ws.socket, onSendPath = true)
    sockData.queueWsFrame(frame, payloadLen, isBinary, written)
  else:
    sockData.queueWsFrame(frame, payloadLen, isBinary)
  sockData.server.emitAfterWrite(max(0, written), written > 0, true)
  sockData.wsPendingBytes += int64(queuedTailLen)
  sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
  sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
  sockData.scheduleWsFlush(ws.socket)
  false

proc queueWsFrameBehindExistingBackpressure(
  ws: WebSocket,
  sockData: ptr SocketData,
  opcode: WebSocketOpcode,
  payload: string,
  isBinary: bool,
  isControlFrame: bool
): bool {.inline.} =
  if sockData == nil or sockData.wsQueueIsEmpty():
    return false
  let frameTotalLen = wsFrameTotalLen(payload.len)
  if sockData.server != nil and not sockData.enforceWsHighWaterPolicy(
    ws,
    payload.len,
    isBinary,
    int64(frameTotalLen),
    preserveControlFrames = isControlFrame
  ):
    return false
  if not sockData.wsCanQueueBytes(int64(frameTotalLen)):
    sockData.handleWsDrop(ws, payload.len, isBinary, false)
    return false
  let frame = buildWsFrame(opcode, payload, false)
  sockData.queueWsFrame(frame, payload.len, isBinary, isControl = isControlFrame)
  sockData.wsPendingBytes += int64(frame.len)
  sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
  sockData.scheduleWsFlush(ws.socket)
  false

proc sendWsFrameWithBackpressure(
  ws: WebSocket,
  opcode: WebSocketOpcode,
  payload: string,
  isBinary: bool,
  bypassCompression: bool = false
): bool {.inline.} =
  if ws == nil or ws.socket == nil or not ws.isOpen:
    return false

  if not ws.compressionEnabled and
     ws.server != nil and
     ws.server.beforeWriteHandler == nil and
     ws.server.afterWriteHandler == nil and
     payload.len < WsPreparedDirectThreshold:
    let frameTotalLen = wsFrameTotalLen(payload.len)
    let sockData = socketDataFor(ws.ssl, ws.socket)
    let isControlFrame = opcode == wsPing or opcode == wsPong or opcode == wsClose
    if sockData != nil and not sockData.wsQueueIsEmpty():
      return queueWsFrameBehindExistingBackpressure(
        ws,
        sockData,
        opcode,
        payload,
        isBinary,
        isControlFrame
      )
    let written = int(writeWsFrame(ws.ssl, ws.socket, opcode, payload, false))
    if written >= frameTotalLen:
      if sockData != nil:
        sockData.refreshWsIdleTimeout(ws.socket, onSendPath = true)
      return true
    if sockData == nil:
      return written > 0
    let frame = buildWsFrame(opcode, payload, false)
    if written <= 0:
      if not sockData.wsCanQueueBytes(int64(frame.len)):
        sockData.handleWsDrop(ws, payload.len, isBinary, false)
        return false
      sockData.queueWsFrame(frame, payload.len, isBinary, isControl = isControlFrame)
      sockData.wsPendingBytes += int64(frame.len)
      sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
      sockData.scheduleWsFlush(ws.socket)
      return false
    let tailLen = frameTotalLen - written
    sockData.refreshWsIdleTimeout(ws.socket, onSendPath = true)
    if not sockData.wsCanQueueBytes(int64(tailLen)):
      sockData.handleWsDrop(ws, payload.len, isBinary, true)
      return false
    sockData.queueWsFrame(frame, payload.len, isBinary, written, isControl = isControlFrame)
    sockData.wsPendingBytes += int64(tailLen)
    sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
    sockData.scheduleWsFlush(ws.socket)
    return false

  let sockData = socketDataFor(ws.ssl, ws.socket)
  if sockData == nil or sockData.server == nil:
    discard writeWsFrame(ws.ssl, ws.socket, opcode, payload, false)
    return true

  let isControlFrame = opcode == wsPing or opcode == wsPong or opcode == wsClose

  var wirePayload = payload
  var compressed = false
  if opcode == wsText or opcode == wsBinary:
    let shouldCompress = wsCompressionDecision(
      sockData.server.options,
      sockData.hasFlag(SDF_WS_COMPRESSION_ACTIVE),
      payload.len,
      isBinary,
      bypassCompression,
      sockData.wsPendingBytes
    )
    if shouldCompress:
      let compressedPayload = compressWsPayload(payload)
      if compressedPayload.ok and compressedPayload.compressed.len > 0 and
         compressedPayload.compressed.len < payload.len:
        let savedBytes = payload.len - compressedPayload.compressed.len
        let minSavings = max(0, sockData.server.options.wsCompressionMinSavingsBytes)
        if savedBytes < minSavings:
          discard
        else:
          wirePayload = compressedPayload.compressed
          compressed = true

  let frameTotalLen = wsFrameTotalLen(wirePayload.len)

  if wirePayload.len >= WsPreparedDirectThreshold:
    let frame = buildWsFrame(opcode, wirePayload, compressed)
    return sendWsFramedWithBackpressure(ws, frame, payload.len, isBinary)

  sockData.server.emitBeforeWrite(frameTotalLen, true)

  if not sockData.wsQueueIsEmpty():
    if not sockData.enforceWsHighWaterPolicy(
      ws,
      payload.len,
      isBinary,
      int64(frameTotalLen),
      preserveControlFrames = isControlFrame
    ):
      sockData.server.emitBackpressure(sockData.wsPendingBytes + int64(frameTotalLen), true)
      return false
    if not sockData.wsCanQueueBytes(int64(frameTotalLen)):
      sockData.handleWsDrop(ws, payload.len, isBinary, false)
      sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
      return false
    let frame = buildWsFrame(opcode, wirePayload, compressed)
    sockData.queueWsFrame(frame, payload.len, isBinary, isControl = isControlFrame)
    sockData.wsPendingBytes += int64(frame.len)
    sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
    sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
    sockData.scheduleWsFlush(ws.socket)
    return false

  let written = int(writeWsFrame(ws.ssl, ws.socket, opcode, wirePayload, compressed))
  if written >= frameTotalLen:
    sockData.refreshWsIdleTimeout(ws.socket, onSendPath = true)
    sockData.server.emitAfterWrite(written, true, true)
    return true

  let queuedTailLen = if written > 0: frameTotalLen - written else: frameTotalLen
  if not sockData.enforceWsHighWaterPolicy(
    ws,
    payload.len,
    isBinary,
    int64(queuedTailLen),
    preserveControlFrames = isControlFrame
  ):
    sockData.server.emitAfterWrite(max(0, written), false, true)
    sockData.server.emitBackpressure(sockData.wsPendingBytes + int64(queuedTailLen), true)
    return false
  if not sockData.wsCanQueueBytes(int64(queuedTailLen)):
    sockData.handleWsDrop(ws, payload.len, isBinary, written > 0)
    sockData.server.emitAfterWrite(max(0, written), false, true)
    sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
    return false

  let frame = buildWsFrame(opcode, wirePayload, compressed)
  if written > 0:
    sockData.refreshWsIdleTimeout(ws.socket, onSendPath = true)
    sockData.queueWsFrame(frame, payload.len, isBinary, written, isControl = isControlFrame)
  else:
    sockData.queueWsFrame(frame, payload.len, isBinary, isControl = isControlFrame)
  sockData.server.emitAfterWrite(max(0, written), written > 0, true)
  sockData.wsPendingBytes += int64(queuedTailLen)
  sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
  sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
  sockData.scheduleWsFlush(ws.socket)
  false

when defined(nimUwebsocketsTest):
  ## Test-only probe of the backpressure queue path for small frames and control frames
  proc wsSmallFrameQueuesBehindBackpressureForTest*(): tuple[
    queued: int,
    pendingBytes: int64,
    firstPayload: int,
    secondPayload: int,
    secondIsControl: bool
  ] =
    var server: HttpServer
    new(server)
    var sockData: SocketData
    sockData.server = server
    sockData.wsOutQueue = @[]
    sockData.wsOutPalette = @[]
    sockData.wsOutPaletteRefs = @[]
    sockData.wsOutPaletteFree = @[]
    queueWsFrame(addr sockData, buildWsFrame(wsText, "first", false), 5, false)
    sockData.wsPendingBytes = int64(sockData.wsOutPalette[0].len)
    let ws = WebSocket(
      socket: cast[UsSocketPtr](cast[pointer](0x777)),
      ssl: 0,
      isOpen: true,
      server: server
    )
    discard queueWsFrameBehindExistingBackpressure(
      ws,
      addr sockData,
      wsPing,
      "p",
      false,
      true
    )
    let second =
      if sockData.wsOutQueue.len > 1:
        sockData.wsOutQueue[1]
      else:
        WsQueuedFrame(paletteIdx: -1)
    (
      queued: sockData.wsOutQueue.len - sockData.wsOutHead,
      pendingBytes: sockData.wsPendingBytes,
      firstPayload: sockData.wsOutQueue[0].payloadBytes,
      secondPayload: second.payloadBytes,
      secondIsControl: second.isControl
    )

## Send a websocket data frame with optional binary and compression-bypass flags
proc send*(
  ws: WebSocket,
  data: string,
  binary: bool = false,
  bypassCompression: bool = false
) {.inline.} =
  ## Send data over WebSocket
  ws.assertWebSocketLoopAffinity("ws.send")
  if ws != nil and ws.isOpen and ws.socket != nil:
    let opcode = if binary: wsBinary else: wsText
    discard sendWsFrameWithBackpressure(ws, opcode, data, binary, bypassCompression)

## Send multiple logical messages merged into one websocket frame with a delimiter
proc sendBatch*(
  ws: WebSocket,
  messages: openArray[string],
  binary: bool = false,
  delimiter: string = "\n",
  bypassCompression: bool = false
): bool =
  ## Send multiple logical messages as one websocket frame.
  ## This is opt-in and intended for high-frequency small-message workloads.
  ws.assertWebSocketLoopAffinity("ws.sendBatch")
  if ws == nil or ws.socket == nil or not ws.isOpen:
    return false
  if messages.len == 0:
    return true
  var totalBytes = 0
  for i in 0..<messages.len:
    totalBytes += messages[i].len
    if delimiter.len > 0 and i + 1 < messages.len:
      totalBytes += delimiter.len
  var merged = newStringOfCap(max(0, totalBytes))
  for i in 0..<messages.len:
    if messages[i].len > 0:
      merged.add(messages[i])
    if delimiter.len > 0 and i + 1 < messages.len:
      merged.add(delimiter)
  let opcode = if binary: wsBinary else: wsText
  sendWsFrameWithBackpressure(ws, opcode, merged, binary, bypassCompression)

type
  WebSocketCorkContext* = ref object
    frames*: seq[tuple[data: string, binary: bool, bypassCompression: bool]]

when defined(singleThread):
  var wsCorkDepth: int
else:
  var wsCorkDepth {.threadvar.}: int

## Buffer a websocket frame inside a ``cork`` context for batched flushing
proc send*(
  ctx: WebSocketCorkContext,
  data: string,
  binary: bool = false,
  bypassCompression: bool = false
) {.inline.} =
  if ctx == nil:
    return
  ctx.frames.add((data: data, binary: binary, bypassCompression: bypassCompression))

## Queue multiple websocket writes inside the callback and flush them as one in-order batch
proc cork*(ws: WebSocket, callback: proc(ctx: WebSocketCorkContext) {.closure.}): bool =
  ## Queue multiple websocket writes and flush in-order as a single explicit batch.
  ## Returns false for invalid usage (nil/closed socket, nested cork, or callback error).
  ws.assertWebSocketLoopAffinity("ws.cork")
  if ws == nil or ws.socket == nil or not ws.isOpen or callback == nil:
    return false
  if wsCorkDepth > 0:
    return false
  inc wsCorkDepth
  defer:
    dec wsCorkDepth
  var ctx: WebSocketCorkContext
  new(ctx)
  ctx.frames = @[]
  try:
    callback(ctx)
  except CatchableError:
    return false
  if ctx.frames.len == 0:
    return true
  var canBatch = ctx.frames.len > 1
  let firstBinary = ctx.frames[0].binary
  let firstBypass = ctx.frames[0].bypassCompression
  if canBatch:
    for i in 1 ..< ctx.frames.len:
      if ctx.frames[i].binary != firstBinary or ctx.frames[i].bypassCompression != firstBypass:
        canBatch = false
        break
  if canBatch and not firstBypass:
    var messages = newSeqOfCap[string](ctx.frames.len)
    for frame in ctx.frames:
      messages.add(frame.data)
    return ws.sendBatch(messages, binary = firstBinary, delimiter = "", bypassCompression = false)
  for frame in ctx.frames:
    ws.send(frame.data, binary = frame.binary, bypassCompression = frame.bypassCompression)
  true

## Send a text websocket frame
proc sendText*(ws: WebSocket, data: string) {.inline.} =
  ws.send(data, binary = false)

## Send a binary websocket frame
proc sendBinary*(ws: WebSocket, data: string) {.inline.} =
  ws.send(data, binary = true)

## Send a websocket frame with per-message compression bypassed
proc sendUncompressed*(ws: WebSocket, data: string, binary: bool = false) {.inline.} =
  ws.send(data, binary = binary, bypassCompression = true)

## Send a websocket frame from a raw pointer payload, avoiding a string copy
proc sendPtr*(ws: WebSocket, dataPtr: pointer, dataLen: int, binary: bool = false) {.inline.} =
  ws.assertWebSocketLoopAffinity("ws.sendPtr")
  if ws != nil and ws.isOpen and ws.socket != nil and (dataLen == 0 or dataPtr != nil):
    let opcode = if binary: wsBinary else: wsText
    discard sendWsPtrWithBackpressure(ws, opcode, dataPtr, dataLen, binary)

## Pre-frame a websocket message for reuse across many sends and broadcasts
proc prepareWsMessage*(data: string, binary: bool = false): PreparedWsMessage =
  ## Pre-frame a websocket message for reuse across many sends/broadcasts.
  let opcode = if binary: wsBinary else: wsText
  PreparedWsMessage(
    frame: buildWsFrame(opcode, data),
    payloadBytes: data.len,
    isBinary: binary
  )

## Pre-frame multiple logical messages as one reusable websocket frame with a delimiter
proc prepareWsBatchMessage*(
  messages: openArray[string],
  binary: bool = false,
  delimiter: string = "\n"
): PreparedWsMessage =
  ## Pre-frame a batch of logical messages as a single reusable websocket frame.
  if messages.len == 0:
    return nil
  var totalBytes = 0
  for i in 0..<messages.len:
    totalBytes += messages[i].len
    if delimiter.len > 0 and i + 1 < messages.len:
      totalBytes += delimiter.len
  var merged = newStringOfCap(max(0, totalBytes))
  for i in 0..<messages.len:
    if messages[i].len > 0:
      merged.add(messages[i])
    if delimiter.len > 0 and i + 1 < messages.len:
      merged.add(delimiter)
  prepareWsMessage(merged, binary)

## Send a previously prepared websocket frame with backpressure handling
proc sendPrepared*(ws: WebSocket, msg: PreparedWsMessage): bool {.inline.} =
  ## Send a previously prepared websocket frame with backpressure handling.
  ws.assertWebSocketLoopAffinity("ws.sendPrepared")
  if msg == nil:
    return false
  sendWsFramedWithBackpressure(ws, msg.frame, msg.payloadBytes, msg.isBinary)

## Broadcast a prepared websocket frame to all tracked open peers and return the send count
proc broadcastPrepared*(server: HttpServer, msg: PreparedWsMessage): int =
  ## Broadcast a prepared websocket frame to all currently tracked open peers.
  server.assertLoopAffinity("broadcastPrepared")
  if server == nil or msg == nil:
    return 0
  for ws in server.websockets:
    if ws != nil and ws.isOpen and ws.socket != nil:
      if ws.sendPrepared(msg):
        inc result

## Publish a prepared websocket frame to all subscribers of a topic and return the send count
proc publishPrepared*(server: HttpServer, topic: string, msg: PreparedWsMessage): int =
  ## Publish a prepared websocket frame to all subscribers of a topic.
  server.assertLoopAffinity("publishPrepared")
  if server == nil or msg == nil or topic.len == 0:
    return 0
  let idx = server.wsTopicIndex(topic)
  if idx < 0:
    return 0
  let subs = server.topicSubscribers[idx]
  for ws in subs:
    if ws != nil and ws.isOpen and ws.socket != nil:
      if ws.sendPrepared(msg):
        inc result

## Broadcast a batch of prepared websocket frames to all open peers in one pass
proc broadcastPreparedBatch*(server: HttpServer, messages: openArray[PreparedWsMessage]): int =
  ## Broadcast multiple prepared websocket frames in one websocket iteration pass.
  server.assertLoopAffinity("broadcastPreparedBatch")
  if server == nil or messages.len == 0:
    return 0
  for ws in server.websockets:
    if ws == nil or not ws.isOpen or ws.socket == nil:
      continue
    for msg in messages:
      if msg != nil and ws.sendPrepared(msg):
        inc result

## Publish a batch of prepared websocket frames to one topic subscribers with a single lookup
proc publishPreparedBatch*(server: HttpServer, topic: string, messages: openArray[PreparedWsMessage]): int =
  ## Publish multiple prepared websocket frames with a single topic lookup.
  server.assertLoopAffinity("publishPreparedBatch")
  if server == nil or topic.len == 0 or messages.len == 0:
    return 0
  let idx = server.wsTopicIndex(topic)
  if idx < 0:
    return 0
  let subs = server.topicSubscribers[idx]
  for ws in subs:
    if ws == nil or not ws.isOpen or ws.socket == nil:
      continue
    for msg in messages:
      if msg != nil and ws.sendPrepared(msg):
        inc result

## Prepare and publish data to all subscribers of a topic, returns the send count
proc publish*(server: HttpServer, topic: string, data: string, binary: bool = false): int =
  ## Publish data to all subscribers of a topic.
  server.assertLoopAffinity("publish")
  let msg = prepareWsMessage(data, binary)
  server.publishPrepared(topic, msg)

## Send a ping control frame, limited to payloads of 125 bytes or fewer
proc ping*(ws: WebSocket, data: string = "") {.inline.} =
  ## Send ping frame
  ws.assertWebSocketLoopAffinity("ws.ping")
  if ws != nil and ws.isOpen and ws.socket != nil:
    if data.len > 125:
      return
    discard sendWsFrameWithBackpressure(ws, wsPing, data, false)

proc isValidWsCloseCode(code: int): bool {.inline.}
proc wsClosePayload(code: int, reason: string = ""): string {.inline.}
proc isAsciiOnly(data: string): bool {.inline.}

proc validWsCloseReasonPrefixLen(reason: string, maxBytes: int = 123): int =
  if reason.len == 0 or maxBytes <= 0:
    return 0
  if reason.validateUtf8() != -1:
    return 0
  result = min(reason.len, maxBytes)
  if result == reason.len:
    return
  while result > 0 and reason[0 ..< result].validateUtf8() != -1:
    dec result

## Send a validated close frame and mark the websocket closed for teardown
proc close*(ws: WebSocket, code: int = 1000, reason: string = "") =
  ws.assertWebSocketLoopAffinity("ws.close")
  if ws != nil and ws.isOpen and ws.socket != nil:
    let closeCode = if code.isValidWsCloseCode(): code else: 1000
    var safeReason = reason
    if safeReason.len > 0 and safeReason.validateUtf8() != -1:
      safeReason = ""
    let payload = wsClosePayload(closeCode, safeReason)
    discard sendWsFrameWithBackpressure(ws, wsClose, payload, false)
    ws.isOpen = false
    let sockData = socketDataFor(ws.ssl, ws.socket)
    if sockData != nil:
      sockData.setFlag(SDF_PENDING_CLOSE)
      sockData.scheduleWsFlush(ws.socket)
      sockData.flushWsQueuedFrames(ws.socket)
      closeSocketIfPending(sockData, ws.socket)
    else:
      us_socket_shutdown(ws.ssl, ws.socket)

proc unmaskInPlace(
  data: var openArray[byte],
  payloadPos: int,
  payloadLen: int,
  k0, k1, k2, k3: byte
) {.inline.} =
  if payloadLen <= 0:
    return
  var i = 0
  let maskKeys = [k0, k1, k2, k3]
  when cpuEndian == littleEndian:
    let m32 = uint32(k0) or
              (uint32(k1) shl 8) or
              (uint32(k2) shl 16) or
              (uint32(k3) shl 24)
    let m64 = uint64(m32) or (uint64(m32) shl 32)
    let base = cast[uint](addr data[payloadPos])
    let misalign = int(base and 7'u)
    if misalign != 0:
      let headBytes = min(8 - misalign, payloadLen)
      while i < headBytes:
        data[payloadPos + i] = data[payloadPos + i] xor maskKeys[i and 3]
        inc i
    if i + 8 <= payloadLen:
      let rotAmount = i and 3
      var rm64 = m64
      if rotAmount != 0:
        let rm32 = (m32 shr uint32(rotAmount * 8)) or (m32 shl uint32((4 - rotAmount) * 8))
        rm64 = uint64(rm32) or (uint64(rm32) shl 32)
      let p64 = cast[ptr UncheckedArray[uint64]](addr data[payloadPos + i])
      var j = 0
      let count64 = (payloadLen - i) shr 3
      while j < count64:
        p64[j] = p64[j] xor rm64
        inc j
      i += count64 shl 3
    if i + 4 <= payloadLen:
      let rotAmount = i and 3
      var rm32 = m32
      if rotAmount != 0:
        rm32 = (m32 shr uint32(rotAmount * 8)) or (m32 shl uint32((4 - rotAmount) * 8))
      let p32 = cast[ptr UncheckedArray[uint32]](addr data[payloadPos + i])
      p32[0] = p32[0] xor rm32
      i += 4
  else:
    while i + 4 <= payloadLen:
      data[payloadPos + i] = data[payloadPos + i] xor k0
      data[payloadPos + i + 1] = data[payloadPos + i + 1] xor k1
      data[payloadPos + i + 2] = data[payloadPos + i + 2] xor k2
      data[payloadPos + i + 3] = data[payloadPos + i + 3] xor k3
      i += 4
  while i < payloadLen:
    data[payloadPos + i] = data[payloadPos + i] xor maskKeys[i and 3]
    inc i

proc unmaskWebSocketPayload(
  data: openArray[byte],
  payloadPos: int,
  payloadLen: int,
  k0, k1, k2, k3: byte
): string {.inline, used.} =
  result = newStringUninit(payloadLen)
  if payloadLen <= 0:
    return
  var i = 0
  let maskKeys = [k0, k1, k2, k3]
  when cpuEndian == littleEndian:
    let m32 = uint32(k0) or
              (uint32(k1) shl 8) or
              (uint32(k2) shl 16) or
              (uint32(k3) shl 24)
    let m64 = uint64(m32) or (uint64(m32) shl 32)
    let dstBase = cast[uint](addr result[0])
    let dstMisalign = int(dstBase and 7'u)
    if dstMisalign != 0 and payloadLen >= 8:
      let headBytes = min(8 - dstMisalign, payloadLen)
      while i < headBytes:
        result[i] = char(data[payloadPos + i] xor maskKeys[i and 3])
        inc i
    if i + 8 <= payloadLen:
      let rotAmount = i and 3
      var rm64 = m64
      if rotAmount != 0:
        let rm32 = (m32 shr uint32(rotAmount * 8)) or (m32 shl uint32((4 - rotAmount) * 8))
        rm64 = uint64(rm32) or (uint64(rm32) shl 32)
      let dst64 = cast[ptr UncheckedArray[uint64]](addr result[i])
      var j = 0
      let count64 = (payloadLen - i) shr 3
      let srcP = cast[uint](unsafeAddr data[payloadPos + i])
      let srcAligned = (srcP and 7'u) == 0'u
      if srcAligned:
        let src64 = cast[ptr UncheckedArray[uint64]](unsafeAddr data[payloadPos + i])
        while j < count64:
          dst64[j] = src64[j] xor rm64
          inc j
      else:
        var tmp64: uint64
        while j < count64:
          copyMem(addr tmp64, unsafeAddr data[payloadPos + i + j * 8], 8)
          dst64[j] = tmp64 xor rm64
          inc j
      i += count64 shl 3
    if i + 4 <= payloadLen:
      let rotAmount = i and 3
      var rm32 = m32
      if rotAmount != 0:
        rm32 = (m32 shr uint32(rotAmount * 8)) or (m32 shl uint32((4 - rotAmount) * 8))
      var tmp32: uint32
      copyMem(addr tmp32, unsafeAddr data[payloadPos + i], 4)
      tmp32 = tmp32 xor rm32
      copyMem(addr result[i], addr tmp32, 4)
      i += 4
  else:
    while i + 4 <= payloadLen:
      result[i] = char(data[payloadPos + i] xor k0)
      result[i + 1] = char(data[payloadPos + i + 1] xor k1)
      result[i + 2] = char(data[payloadPos + i + 2] xor k2)
      result[i + 3] = char(data[payloadPos + i + 3] xor k3)
      i += 4
  while i < payloadLen:
    result[i] = char(data[payloadPos + i] xor maskKeys[i and 3])
    inc i

proc unmaskWebSocketPayloadInPlace(
  data: var openArray[byte],
  payloadPos: int,
  payloadLen: int,
  k0, k1, k2, k3: byte,
  payload: var string
) {.inline.} =
  unmaskInPlace(data, payloadPos, payloadLen, k0, k1, k2, k3)
  payload = newStringUninit(payloadLen)
  if payloadLen > 0:
    copyMem(addr payload[0], addr data[payloadPos], payloadLen)

proc unmaskWebSocketPayloadZeroCopy(
  data: var openArray[byte],
  payloadPos: int,
  payloadLen: int,
  k0, k1, k2, k3: byte,
  payloadStart: var int,
  payloadLength: var int
) {.inline.} =
  unmaskInPlace(data, payloadPos, payloadLen, k0, k1, k2, k3)
  payloadStart = payloadPos
  payloadLength = payloadLen

proc isValidWebSocketOpcode(opcode: int): bool {.inline.} =
  opcode == 0x0 or opcode == 0x1 or opcode == 0x2 or
    opcode == 0x8 or opcode == 0x9 or opcode == 0xA

proc decodeWebSocketFrame(
  data: var openArray[byte],
  start: int,
  opcode: var int,
  payload: var string,
  consumed: var int,
  fin: var bool,
  compressed: var bool,
  allowCompressed: bool
): int {.inline.} =
  ## Decode one WebSocket frame.
  ## Returns:
  ##   1 = success
  ##   0 = need more data
  ##  -1 = protocol error
  ##  -2 = unmasked client frame
  # RFC 6455 §5.2 + §5.5:
  # control frames must be FIN and payload length <=125.
  let dataLen = data.len - start
  if dataLen < 2:
    return 0

  var pos = start
  let byte1 = int(data[pos])
  fin = (byte1 and 0x80) != 0
  let rsv1 = (byte1 and 0x40) != 0
  if (byte1 and 0x30) != 0:
    return -1
  opcode = byte1 and 0x0F
  if rsv1:
    if not allowCompressed or opcode == 0x0 or opcode >= 0x8:
      return -1
    compressed = true
  else:
    compressed = false
  if not isValidWebSocketOpcode(opcode):
    return -1
  inc pos

  let byte2 = int(data[pos])
  if (byte2 and 0x80) == 0:
    return -2
  var payloadLen = byte2 and 0x7F
  inc pos

  if payloadLen < 126:
    if opcode >= 0x8 and (not fin or compressed):
      return -1
    let frameBytes = 2 + 4 + payloadLen
    if dataLen < frameBytes:
      return 0
    let k0 = data[pos]
    let k1 = data[pos + 1]
    let k2 = data[pos + 2]
    let k3 = data[pos + 3]
    unmaskWebSocketPayloadInPlace(data, pos + 4, payloadLen, k0, k1, k2, k3, payload)
    consumed = frameBytes
    return 1

  if payloadLen == 126:
    if dataLen < pos - start + 2:
      return 0
    payloadLen = (int(data[pos]) shl 8) or int(data[pos + 1])
    if payloadLen < 126:
      return -1
    pos += 2
  elif payloadLen == 127:
    if dataLen < pos - start + 8:
      return 0
    if (data[pos] and 0x80'u8) != 0:
      return -1
    payloadLen = 0
    for i in 0..<8:
      # Reject oversized frames that do not fit in Nim int.
      if payloadLen > (high(int) shr 8):
        return -1
      payloadLen = (payloadLen shl 8) or int(data[pos + i])
    if payloadLen < 65536:
      return -1
    pos += 8

  if opcode >= 0x8:
    if not fin or payloadLen > 125 or compressed:
      return -1

  if dataLen < pos - start + 4:
    return 0
  let k0 = data[pos]
  let k1 = data[pos + 1]
  let k2 = data[pos + 2]
  let k3 = data[pos + 3]
  pos += 4

  let payloadHeaderBytes = pos - start
  if payloadHeaderBytes < 0 or payloadHeaderBytes > dataLen:
    return -1
  if payloadLen > dataLen - payloadHeaderBytes:
    return 0

  unmaskWebSocketPayloadInPlace(data, pos, payloadLen, k0, k1, k2, k3, payload)

  consumed = payloadHeaderBytes + payloadLen
  1

proc decodeWebSocketFrameZeroCopy(
  data: var openArray[byte],
  start: int,
  opcode: var int,
  payloadStart: var int,
  payloadLength: var int,
  consumed: var int,
  fin: var bool,
  compressed: var bool,
  allowCompressed: bool
): int {.inline.} =
  let dataLen = data.len - start
  if dataLen < 2:
    return 0

  var pos = start
  let byte1 = int(data[pos])
  fin = (byte1 and 0x80) != 0
  let rsv1 = (byte1 and 0x40) != 0
  if (byte1 and 0x30) != 0:
    return -1
  opcode = byte1 and 0x0F
  if rsv1:
    if not allowCompressed or opcode == 0x0 or opcode >= 0x8:
      return -1
    compressed = true
  else:
    compressed = false
  if not isValidWebSocketOpcode(opcode):
    return -1
  inc pos

  let byte2 = int(data[pos])
  if (byte2 and 0x80) == 0:
    return -2
  var payloadLen = byte2 and 0x7F
  inc pos

  if payloadLen < 126:
    if opcode >= 0x8 and (not fin or compressed):
      return -1
    let frameBytes = 2 + 4 + payloadLen
    if dataLen < frameBytes:
      return 0
    let k0 = data[pos]
    let k1 = data[pos + 1]
    let k2 = data[pos + 2]
    let k3 = data[pos + 3]
    unmaskWebSocketPayloadZeroCopy(data, pos + 4, payloadLen, k0, k1, k2, k3, payloadStart, payloadLength)
    consumed = frameBytes
    return 1

  if payloadLen == 126:
    if dataLen < pos - start + 2:
      return 0
    payloadLen = (int(data[pos]) shl 8) or int(data[pos + 1])
    if payloadLen < 126:
      return -1
    pos += 2
  elif payloadLen == 127:
    if dataLen < pos - start + 8:
      return 0
    if (data[pos] and 0x80'u8) != 0:
      return -1
    payloadLen = 0
    for i in 0..<8:
      if payloadLen > (high(int) shr 8):
        return -1
      payloadLen = (payloadLen shl 8) or int(data[pos + i])
    if payloadLen < 65536:
      return -1
    pos += 8

  if opcode >= 0x8:
    if not fin or payloadLen > 125 or compressed:
      return -1

  if dataLen < pos - start + 4:
    return 0
  let k0 = data[pos]
  let k1 = data[pos + 1]
  let k2 = data[pos + 2]
  let k3 = data[pos + 3]
  pos += 4

  let payloadHeaderBytes = pos - start
  if payloadHeaderBytes < 0 or payloadHeaderBytes > dataLen:
    return -1
  if payloadLen > dataLen - payloadHeaderBytes:
    return 0

  unmaskWebSocketPayloadZeroCopy(data, pos, payloadLen, k0, k1, k2, k3, payloadStart, payloadLength)

  consumed = payloadHeaderBytes + payloadLen
  1

proc wsClosePayload(code: int, reason: string = ""): string {.inline.} =
  let reasonLen = reason.validWsCloseReasonPrefixLen()
  result = newStringUninit(2 + reasonLen)
  result[0] = char((code shr 8) and 0xFF)
  result[1] = char(code and 0xFF)
  if reasonLen > 0:
    copyMem(addr result[2], unsafeAddr reason[0], reasonLen)

proc isValidWsCloseCode(code: int): bool {.inline.} =
  if code < 1000:
    return false
  if code >= 3000 and code <= 4999:
    return true
  case code
  of 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014:
    true
  else:
    false

proc sendWsCloseAndTerminate(sockData: ptr SocketData, s: UsSocketPtr, payload: string) {.inline.} =
  # RFC 6455 §5.5.1 + §7.1.7:
  # send Close (when possible) and close only after queued bytes drain.
  when defined(nimUwebsocketsTest):
    appendWsTestLog("close:" & toHex(payload))
  sockData.wsFragmentOpcode = 0
  sockData.wsFragmentCount = 0
  sockData.wsFragmentPayload.setLen(0)
  sockData.clearFlag(SDF_WS_FRAGMENT_COMPRESSED)

  var closeQueued = false
  if sockData.server != nil and s != nil:
    let ssl = sockData.server.ssl.toInt
    let frame = buildWsFrame(wsClose, payload, false)
    sockData.server.emitBeforeWrite(frame.len, true)
    if sockData.wsQueueIsEmpty():
      let written = writeSocketChecked(ssl, s, frame.cstring, frame.len)
      if written >= frame.len:
        sockData.refreshWsIdleTimeout(s, onSendPath = true)
        sockData.server.emitAfterWrite(written, true, true)
      else:
        sockData.server.emitAfterWrite(max(0, written), written > 0, true)
        let frameOffset = if written > 0: written else: 0
        let tailLen = frame.len - frameOffset
        if tailLen > 0 and sockData.wsCanQueueBytes(int64(tailLen)):
          sockData.queueWsFrame(frame, payload.len, false, frameOffset, isControl = true)
          sockData.wsPendingBytes += int64(tailLen)
          sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
          sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
          closeQueued = true
    elif sockData.wsCanQueueBytes(int64(frame.len)):
      sockData.queueWsFrame(frame, payload.len, false, isControl = true)
      sockData.wsPendingBytes += int64(frame.len)
      sockData.setFlag(SDF_WS_HAD_BACKPRESSURE)
      sockData.server.emitBackpressure(sockData.wsPendingBytes, true)
      closeQueued = true
  if sockData.ws != nil:
    sockData.ws.isOpen = false
  sockData.setFlag(SDF_PENDING_CLOSE)
  if s != nil and sockData.server != nil:
    if closeQueued:
      sockData.scheduleWsFlush(s)
    sockData.flushWsQueuedFrames(s)
    closeSocketIfPending(sockData, s)
  if s != nil and sockData.server != nil and sockData.hasFlag(SDF_PENDING_CLOSE) and sockData.wsQueueIsEmpty():
    us_socket_shutdown(sockData.server.ssl.toInt, s)

proc isAsciiOnly(data: string): bool {.inline.} =
  if data.len == 0:
    return true
  var i = 0
  when cpuEndian == littleEndian:
    let p = cast[uint](unsafeAddr data[0])
    while i + 8 <= data.len:
      var w: uint64
      copyMem(addr w, cast[pointer](p + uint(i)), 8)
      if (w and 0x8080808080808080'u64) != 0:
        return false
      i += 8
  while i < data.len:
    if ord(data[i]) > 127:
      return false
    inc i
  true

proc isAsciiOnlyBytes(data: openArray[byte], start: int, length: int): bool {.inline.} =
  if length == 0:
    return true
  var i = 0
  when cpuEndian == littleEndian:
    let p = cast[uint](unsafeAddr data[start])
    while i + 8 <= length:
      var w: uint64
      copyMem(addr w, cast[pointer](p + uint(i)), 8)
      if (w and 0x8080808080808080'u64) != 0:
        return false
      i += 8
  while i < length:
    if data[start + i] > 127:
      return false
    inc i
  true

proc validateUtf8Bytes(data: openArray[byte], start: int, length: int): int {.inline.} =
  if length == 0:
    return -1
  var i = 0
  while i < length:
    let b = data[start + i]
    if b <= 0x7F'u8:
      inc i
    elif (b and 0xE0'u8) == 0xC0'u8:
      if i + 1 >= length:
        return i
      if (data[start + i + 1] and 0xC0'u8) != 0x80'u8:
        return i
      let cp = (uint32(b and 0x1F'u8) shl 6) or uint32(data[start + i + 1] and 0x3F'u8)
      if cp < 0x80'u32:
        return i
      i += 2
    elif (b and 0xF0'u8) == 0xE0'u8:
      if i + 2 >= length:
        return i
      if (data[start + i + 1] and 0xC0'u8) != 0x80'u8:
        return i
      if (data[start + i + 2] and 0xC0'u8) != 0x80'u8:
        return i
      let cp = (uint32(b and 0x0F'u8) shl 12) or
               (uint32(data[start + i + 1] and 0x3F'u8) shl 6) or
               uint32(data[start + i + 2] and 0x3F'u8)
      if cp < 0x800'u32:
        return i
      if cp >= 0xD800'u32 and cp <= 0xDFFF'u32:
        return i
      i += 3
    elif (b and 0xF8'u8) == 0xF0'u8:
      if i + 3 >= length:
        return i
      if (data[start + i + 1] and 0xC0'u8) != 0x80'u8:
        return i
      if (data[start + i + 2] and 0xC0'u8) != 0x80'u8:
        return i
      if (data[start + i + 3] and 0xC0'u8) != 0x80'u8:
        return i
      let cp = (uint32(b and 0x07'u8) shl 18) or
               (uint32(data[start + i + 1] and 0x3F'u8) shl 12) or
               (uint32(data[start + i + 2] and 0x3F'u8) shl 6) or
               uint32(data[start + i + 3] and 0x3F'u8)
      if cp < 0x10000'u32 or cp > 0x10FFFF'u32:
        return i
      i += 4
    else:
      return i
  -1

proc bufferPayloadToString(data: openArray[byte], start: int, length: int): string {.inline.} =
  result = newStringUninit(length)
  if length > 0:
    copyMem(addr result[0], unsafeAddr data[start], length)

proc deliverWebSocketMessage(
  sockData: ptr SocketData,
  s: UsSocketPtr,
  opcode: int,
  payload: string,
  wsHandler: WebSocketHandler,
  wsRawHandler: WebSocketRawHandler,
  wsConn: WebSocket
): bool {.inline.} =
  # RFC 6455 §8.1 + §7.4.1(1007):
  # invalid UTF-8 in text messages triggers connection failure.
  if opcode == 0x1 and (not payload.isAsciiOnly()) and payload.validateUtf8() != -1:
    sendWsCloseAndTerminate(sockData, s, WsClose1007)
    return false
  if wsRawHandler != nil and wsConn != nil:
    try:
      let dataPtr =
        if payload.len > 0:
          cast[pointer](unsafeAddr payload[0])
        else:
          nil
      wsRawHandler(wsConn, dataPtr, payload.len, opcode == 0x2)
    except CatchableError as err:
      if sockData != nil and sockData.server != nil:
        sockData.server.emitServerPanic("wsRawHandler", err.msg)
      sendWsCloseAndTerminate(sockData, s, WsClose1011)
      return false
    except Defect as defect:
      if sockData != nil and sockData.server != nil:
        sockData.server.emitServerPanic("wsRawHandler_defect", defect.msg)
      sendWsCloseAndTerminate(sockData, s, WsClose1011)
      return false
    return true
  if wsHandler != nil and wsConn != nil:
    try:
      wsHandler(wsConn, payload, opcode == 0x2)
    except CatchableError as err:
      if sockData != nil and sockData.server != nil:
        sockData.server.emitServerPanic("wsHandler", err.msg)
      sendWsCloseAndTerminate(sockData, s, WsClose1011)
      return false
    except Defect as defect:
      if sockData != nil and sockData.server != nil:
        sockData.server.emitServerPanic("wsHandler_defect", defect.msg)
      sendWsCloseAndTerminate(sockData, s, WsClose1011)
      return false
  true

proc deliverWebSocketMessageFromBuffer(
  sockData: ptr SocketData,
  s: UsSocketPtr,
  opcode: int,
  bufferData: openArray[byte],
  payloadStart: int,
  payloadLength: int,
  wsHandler: WebSocketHandler,
  wsRawHandler: WebSocketRawHandler,
  wsConn: WebSocket
): bool {.inline.} =
  if opcode == 0x1:
    if not isAsciiOnlyBytes(bufferData, payloadStart, payloadLength):
      if validateUtf8Bytes(bufferData, payloadStart, payloadLength) != -1:
        sendWsCloseAndTerminate(sockData, s, WsClose1007)
        return false
  if wsRawHandler != nil and wsConn != nil:
    try:
      let dataPtr =
        if payloadLength > 0:
          cast[pointer](unsafeAddr bufferData[payloadStart])
        else:
          nil
      wsRawHandler(wsConn, dataPtr, payloadLength, opcode == 0x2)
    except CatchableError as err:
      if sockData != nil and sockData.server != nil:
        sockData.server.emitServerPanic("wsRawHandler", err.msg)
      sendWsCloseAndTerminate(sockData, s, WsClose1011)
      return false
    except Defect as defect:
      if sockData != nil and sockData.server != nil:
        sockData.server.emitServerPanic("wsRawHandler_defect", defect.msg)
      sendWsCloseAndTerminate(sockData, s, WsClose1011)
      return false
    return true
  if wsHandler != nil and wsConn != nil:
    let payload = bufferPayloadToString(bufferData, payloadStart, payloadLength)
    try:
      wsHandler(wsConn, payload, opcode == 0x2)
    except CatchableError as err:
      if sockData != nil and sockData.server != nil:
        sockData.server.emitServerPanic("wsHandler", err.msg)
      sendWsCloseAndTerminate(sockData, s, WsClose1011)
      return false
    except Defect as defect:
      if sockData != nil and sockData.server != nil:
        sockData.server.emitServerPanic("wsHandler_defect", defect.msg)
      sendWsCloseAndTerminate(sockData, s, WsClose1011)
      return false
  true

proc storeServerExt(ext: pointer, server: HttpServer) {.inline.} =
  if ext == nil:
    return
  cast[ptr pointer](ext)[] = cast[pointer](server)

proc loadServerExt(ext: pointer): HttpServer {.inline.} =
  if ext == nil:
    return nil
  cast[HttpServer](cast[ptr pointer](ext)[])

proc serverFromContextExt(ssl: cint, context: UsSocketContextPtr): HttpServer {.inline.} =
  if context == nil:
    return nil
  let ext = us_socket_context_ext(ssl, context)
  loadServerExt(ext)

proc resolveServerFromLoop(loop: UsLoopPtr): HttpServer {.inline.} =
  if loop != nil:
    let ext = us_loop_ext(loop)
    let server = loadServerExt(ext)
    if server != nil:
      return server
  nil

proc resolveServerFromTimer(timer: UsTimerPtr): HttpServer {.inline.} =
  if timer != nil:
    let ext = us_timer_ext(timer)
    let server = loadServerExt(ext)
    if server != nil:
      return server
    let loop = us_timer_loop(timer)
    let loopServer = resolveServerFromLoop(loop)
    if loopServer != nil:
      return loopServer
  nil

proc resolveServerFromSocketContext(s: UsSocketPtr): HttpServer {.inline.} =
  if s == nil:
    return nil
  let contextPlain = us_socket_context(0, s)
  let plainServer = serverFromContextExt(0, contextPlain)
  if plainServer != nil:
    return plainServer
  let contextTls = us_socket_context(1, s)
  let tlsServer = serverFromContextExt(1, contextTls)
  if tlsServer != nil:
    return tlsServer
  nil

proc resolveServerFromSocket(s: UsSocketPtr): HttpServer {.inline.} =
  if s == nil:
    return nil
  let sockDataPlain = socketDataFor(0, s)
  if sockDataPlain != nil and sockDataPlain.magic == SocketDataMagic and sockDataPlain.server != nil:
    return sockDataPlain.server
  let sockDataTls = socketDataFor(1, s)
  if sockDataTls != nil and sockDataTls.magic == SocketDataMagic and sockDataTls.server != nil:
    return sockDataTls.server
  resolveServerFromSocketContext(s)

# Callback handlers for uSockets
proc onLoopNoop(loop: UsLoopPtr) {.cdecl, used.} = discard

proc runLoopPreMaintenance(server: HttpServer) {.inline.}
proc runLoopPostMaintenance(server: HttpServer) {.inline.}

proc runLoopWakeMaintenance(server: HttpServer) {.inline.} =
  if server == nil:
    return
  when defined(macosx):
    if server.macosMaintenanceDepth > 0:
      return
    inc server.macosMaintenanceDepth
    try:
      server.runLoopPreMaintenance()
      server.runLoopPostMaintenance()
    finally:
      if server.macosMaintenanceDepth > 0:
        dec server.macosMaintenanceDepth
  else:
    server.runLoopPreMaintenance()
    server.runLoopPostMaintenance()

proc runLoopPreMaintenance(server: HttpServer) {.inline.} =
  if server == nil:
    return
  refreshCachedTime()
  when defined(macosx):
    if loadShutdownRequested() or server.isShuttingDown:
      beginShutdown(server)
  server.bindLoopOwner()
  inc server.loopMaintenanceEpoch
  if server.loopMaintenanceEpoch == 0'u64:
    inc server.loopMaintenanceEpoch
  server.flushCrossThreadDeferQueue()
  server.resetLoopFairnessBudgets()
  if server.options.loopWriteBatching:
    inc server.loopWriteBatchDepth
  server.flushDeferredPreCallbacks()
  if server.loopPreCallback != nil:
    try:
      server.loopPreCallback()
    except CatchableError as err:
      server.emitServerPanic("loopPreCallback", err.msg)
    except Defect as defect:
      server.emitServerPanic("loopPreCallback_defect", defect.msg)

proc runLoopPostMaintenance(server: HttpServer) {.inline.} =
  if server == nil:
    return
  if server.loopWriteBatchDepth > 0:
    dec server.loopWriteBatchDepth
  server.flushAllPendingSockets()
  server.flushQueuedWsDrainHandlers()
  server.flushDeferredPostCallbacks()
  if server.loopPostCallback != nil:
    try:
      server.loopPostCallback()
    except CatchableError as err:
      server.emitServerPanic("loopPostCallback", err.msg)
    except Defect as defect:
      server.emitServerPanic("loopPostCallback_defect", defect.msg)
  server.clearClosedSocketTombstones()

proc runMacosFallbackTimers(server: HttpServer) {.inline, used.} =
  when defined(macosx):
    if server == nil:
      return
    let nowMs = getCachedEpochMs()
    if server.timer == nil and server.timerCallback != nil:
      let intervalMs = if server.timerIntervalMs > 0: server.timerIntervalMs else: 1000
      if server.macosUserTimerLastMs == 0 or (nowMs - server.macosUserTimerLastMs) >= int64(intervalMs):
        server.macosUserTimerLastMs = nowMs
        try:
          server.timerCallback()
        except CatchableError as err:
          server.emitServerPanic("timerCallback", err.msg)
        except Defect as defect:
          server.emitServerPanic("timerCallback_defect", defect.msg)
    if server.internalTimer == nil and server.internalTimerCallback != nil:
      let intervalMs = if server.internalTimerIntervalMs > 0: server.internalTimerIntervalMs else: 1000
      if server.macosInternalTimerLastMs == 0 or (nowMs - server.macosInternalTimerLastMs) >= int64(intervalMs):
        server.macosInternalTimerLastMs = nowMs
        try:
          server.internalTimerCallback()
        except CatchableError as err:
          server.emitServerPanic("internalTimerCallback", err.msg)
        except Defect as defect:
          server.emitServerPanic("internalTimerCallback_defect", defect.msg)
    let wsInterval = server.options.wsKeepaliveInterval
    if server.wsKeepaliveTimer == nil and wsInterval > 0 and (server.macosWsKeepaliveLastMs == 0 or (nowMs - server.macosWsKeepaliveLastMs) >= int64(wsInterval)):
      server.macosWsKeepaliveLastMs = nowMs
      runWsKeepalive(server)
  else:
    discard server

proc beginMacosFallbackMaintenance(server: HttpServer): bool {.inline, used.} =
  when defined(macosx):
    if server == nil:
      return false
    if server.macosMaintenanceDepth > 0:
      return false
    inc server.macosMaintenanceCounter
    let eventTriggered = (server.macosMaintenanceCounter and 0x3FF'u64) == 0'u64
    refreshCachedTime()
    let nowForMaint = getCachedEpochMs()
    let elapsed = nowForMaint - server.macosMaintenanceEpochMs
    let minInterval = int64(min(
      if server.internalTimerIntervalMs > 0: server.internalTimerIntervalMs else: 1000,
      if server.timerIntervalMs > 0: server.timerIntervalMs else: 1000
    ))
    let timeTriggered = elapsed >= minInterval
    if not eventTriggered and not timeTriggered:
      return false
    server.macosMaintenanceEpochMs = nowForMaint
    inc server.macosMaintenanceDepth
    server.runLoopPreMaintenance()
    server.runMacosFallbackTimers()
    true
  else:
    discard server
    false

proc endMacosFallbackMaintenance(server: HttpServer, entered: bool) {.inline, used.} =
  when defined(macosx):
    if server == nil or not entered:
      return
    try:
      server.runLoopPostMaintenance()
    finally:
      if server.macosMaintenanceDepth > 0:
        dec server.macosMaintenanceDepth
  else:
    discard server
    discard entered

proc onLoopPre(loop: UsLoopPtr) {.cdecl.} =
  let server = resolveServerFromLoop(loop)
  if server == nil:
    return
  try:
    server.runLoopPreMaintenance()
  except CatchableError as err:
    server.emitServerPanic("loopPreCallback", err.msg)
  except Defect as defect:
    server.emitServerPanic("loopPreCallback_defect", defect.msg)

proc onLoopPost(loop: UsLoopPtr) {.cdecl.} =
  let server = resolveServerFromLoop(loop)
  if server == nil:
    return
  try:
    server.runLoopPostMaintenance()
  except CatchableError as err:
    server.emitServerPanic("loopPostCallback", err.msg)
  except Defect as defect:
    server.emitServerPanic("loopPostCallback_defect", defect.msg)

proc onLoopWake(loop: UsLoopPtr) {.cdecl, used.} =
  let server = resolveServerFromLoop(loop)
  if server == nil:
    return
  try:
    server.runLoopWakeMaintenance()
  except CatchableError as err:
    server.emitServerPanic("loopWakeCallback", err.msg)
  except Defect as defect:
    server.emitServerPanic("loopWakeCallback_defect", defect.msg)

proc rawIpToString(ip: cstring, ipLength: cint): string =
  if ip == nil or ipLength <= 0:
    return ""

  when not defined(windows):
    var family = 0
    if ipLength == 4:
      family = AF_INET
    elif ipLength == 16:
      family = AF_INET6

    if family != 0:
      var textBuf: array[64, char]
      let ok = inet_ntop(family.cint, cast[pointer](ip), cast[cstring](addr textBuf[0]), textBuf.len.int32)
      if ok != nil:
        return $cast[cstring](addr textBuf[0])

  # Fallback: preserve raw address bytes.
  let n = int(ipLength)
  result = newString(n)
  copyMem(addr result[0], ip, n)

proc isSocketTunableUnsupportedErr(errCode: cint): bool {.inline.} =
  when declared(ENOPROTOOPT):
    if errCode == ENOPROTOOPT:
      return true
  when declared(EOPNOTSUPP):
    if errCode == EOPNOTSUPP:
      return true
  when declared(ENOTSUP):
    if errCode == ENOTSUP:
      return true
  false

proc emitSocketTunableWarningOnce(server: HttpServer, optionLabel: string, errCode: cint, unsupported: bool) {.inline.} =
  if server == nil or optionLabel.len == 0:
    return
  let dedupeKey =
    if unsupported:
      "unsupported:" & optionLabel
    else:
      "failed:" & optionLabel
  if server.socketTunableWarnings != nil and server.socketTunableWarnings.contains(dedupeKey):
    return
  if server.socketTunableWarnings != nil:
    discard server.socketTunableWarnings.incl(dedupeKey)
  let detail =
    if unsupported:
      "unsupported (errno=" & $errCode & ")"
    else:
      "failed (errno=" & $errCode & ")"
  server.emitServerError("socket tunable " & optionLabel & " " & detail)

proc recordSocketTunableResult(server: HttpServer, optionLabel: string, errCode: cint) {.inline.} =
  if server == nil:
    return
  if errCode == 0:
    inc server.metricsSocketTunablesApplied
    return
  if isSocketTunableUnsupportedErr(errCode):
    inc server.metricsSocketTunablesUnsupported
    server.emitSocketTunableWarningOnce(optionLabel, errCode, unsupported = true)
    return
  inc server.metricsSocketTunablesFailed
  server.emitSocketTunableWarningOnce(optionLabel, errCode, unsupported = false)

proc recordNativeSocketTunablesUnavailable(server: HttpServer, optionLabel: string) {.inline.} =
  when defined(LIBUS_USE_IO_URING) or defined(useIoUring):
    when declared(ENOTSUP):
      server.recordSocketTunableResult(optionLabel, ENOTSUP)
    elif declared(EOPNOTSUPP):
      server.recordSocketTunableResult(optionLabel, EOPNOTSUPP)
    else:
      server.recordSocketTunableResult(optionLabel, 95.cint)

proc applySocketOpt(
  server: HttpServer,
  fd: SocketHandle,
  level: cint,
  optName: cint,
  optValue: pointer,
  optLen: SockLen,
  optionLabel: string
) {.inline.} =
  let rc = setsockopt(fd, level, optName, optValue, optLen)
  if rc == 0:
    server.recordSocketTunableResult(optionLabel, 0)
  else:
    server.recordSocketTunableResult(optionLabel, errno)

proc applySocketTunables(server: HttpServer, s: UsSocketPtr) {.inline.} =
  when not defined(windows):
    if server == nil or s == nil:
      return
    let nativeHandle = us_socket_get_native_handle(server.ssl.toInt, s)
    if nativeHandle == nil:
      server.recordNativeSocketTunablesUnavailable("io_uring accepted socket native handle")
      return
    let fd {.used.} = SocketHandle(cast[int](nativeHandle))
    let optLen {.used.} = SockLen(sizeof(cint))
    var enabled: cint = 1
    var disabled: cint = 0
    let noDelayPtr: pointer =
      if server.options.socketNoDelay:
        cast[pointer](addr enabled)
      else:
        cast[pointer](addr disabled)
    let keepAlivePtr: pointer =
      if server.options.socketKeepAlive:
        cast[pointer](addr enabled)
      else:
        cast[pointer](addr disabled)

    when declared(TCP_NODELAY):
      applySocketOpt(server, fd, IPPROTO_TCP, TCP_NODELAY, noDelayPtr, optLen, "TCP_NODELAY")

    applySocketOpt(server, fd, SOL_SOCKET, SO_KEEPALIVE, keepAlivePtr, optLen, "SO_KEEPALIVE")

    if server.options.socketKeepAlive and server.options.socketKeepAliveSeconds > 0:
      when defined(macosx):
        when declared(TCP_KEEPALIVE):
          var idleSeconds = server.options.socketKeepAliveSeconds.cint
          applySocketOpt(
            server,
            fd,
            IPPROTO_TCP,
            TCP_KEEPALIVE,
            cast[pointer](addr idleSeconds),
            optLen,
            "TCP_KEEPALIVE"
          )
      else:
        when declared(TCP_KEEPIDLE):
          var idleSeconds = server.options.socketKeepAliveSeconds.cint
          applySocketOpt(
            server,
            fd,
            IPPROTO_TCP,
            TCP_KEEPIDLE,
            cast[pointer](addr idleSeconds),
            optLen,
            "TCP_KEEPIDLE"
          )

    if server.options.socketSendBufferBytes > 0:
      var sndBuf = server.options.socketSendBufferBytes.cint
      applySocketOpt(server, fd, SOL_SOCKET, SO_SNDBUF, cast[pointer](addr sndBuf), optLen, "SO_SNDBUF")

    if server.options.socketRecvBufferBytes > 0:
      var rcvBuf = server.options.socketRecvBufferBytes.cint
      applySocketOpt(server, fd, SOL_SOCKET, SO_RCVBUF, cast[pointer](addr rcvBuf), optLen, "SO_RCVBUF")

    if server.options.socketNotSentLowWaterBytes > 0:
      when declared(TCP_NOTSENT_LOWAT):
        var lowat = server.options.socketNotSentLowWaterBytes.cint
        applySocketOpt(
          server,
          fd,
          IPPROTO_TCP,
          TCP_NOTSENT_LOWAT,
          cast[pointer](addr lowat),
          optLen,
          "TCP_NOTSENT_LOWAT"
        )

    when defined(linux):
      if server.options.socketIncomingCpu >= 0:
        when declared(SO_INCOMING_CPU):
          var cpu = server.options.socketIncomingCpu.cint
          applySocketOpt(server, fd, SOL_SOCKET, SO_INCOMING_CPU, cast[pointer](addr cpu), optLen, "SO_INCOMING_CPU")

proc applyWebSocketSocketTunables(server: HttpServer, s: UsSocketPtr) {.inline.} =
  when not defined(windows):
    if server == nil or s == nil:
      return
    let nativeHandle = us_socket_get_native_handle(server.ssl.toInt, s)
    if nativeHandle == nil:
      server.recordNativeSocketTunablesUnavailable("io_uring websocket socket native handle")
      return
    let fd = SocketHandle(cast[int](nativeHandle))
    let optLen = SockLen(sizeof(cint))
    if server.options.wsSocketSendBufferBytes > 0:
      var sndBuf = server.options.wsSocketSendBufferBytes.cint
      applySocketOpt(server, fd, SOL_SOCKET, SO_SNDBUF, cast[pointer](addr sndBuf), optLen, "WS_SO_SNDBUF")
    if server.options.wsSocketRecvBufferBytes > 0:
      var rcvBuf = server.options.wsSocketRecvBufferBytes.cint
      applySocketOpt(server, fd, SOL_SOCKET, SO_RCVBUF, cast[pointer](addr rcvBuf), optLen, "WS_SO_RCVBUF")
    if server.options.wsSocketNotSentLowWaterBytes > 0:
      when declared(TCP_NOTSENT_LOWAT):
        var lowat = server.options.wsSocketNotSentLowWaterBytes.cint
        applySocketOpt(
          server,
          fd,
          IPPROTO_TCP,
          TCP_NOTSENT_LOWAT,
          cast[pointer](addr lowat),
          optLen,
          "WS_TCP_NOTSENT_LOWAT"
        )

proc applyListenSocketTunables(server: HttpServer) {.inline.} =
  when not defined(windows):
    if server == nil or server.listenSocket == nil:
      return
    let nativeHandle = us_socket_get_native_handle(
      server.ssl.toInt,
      cast[UsSocketPtr](server.listenSocket)
    )
    if nativeHandle == nil:
      server.recordNativeSocketTunablesUnavailable("io_uring listen socket native handle")
      return
    let fd = SocketHandle(cast[int](nativeHandle))
    let optLen = SockLen(sizeof(cint))
    discard fd
    discard optLen

    when defined(linux):
      if server.options.socketDeferAcceptSeconds > 0:
        when declared(TCP_DEFER_ACCEPT):
          var deferAccept = server.options.socketDeferAcceptSeconds.cint
          applySocketOpt(
            server,
            fd,
            IPPROTO_TCP,
            TCP_DEFER_ACCEPT,
            cast[pointer](addr deferAccept),
            optLen,
            "TCP_DEFER_ACCEPT"
          )

proc releaseSocketDataRefs(sockData: ptr SocketData) {.inline.}

## A Defect (index out of range, integer overflow, out-of-memory, ...) that
## escapes a `.cdecl` uSockets callback leaves the runtime error flag set;
## every subsequent Nim function on the loop thread then silently no-ops,
## the C event loop keeps spinning but nothing executes, and the process
## hangs forever with no diagnostics (a "zombie" hang). Catching the Defect
## resets the error state so the loop keeps running. These helpers report
## the escape so the root cause can be found.
proc reportEscapedDefect*(source: string, defect: ref Defect, server: HttpServer = nil) {.inline.} =
  ## Report a Defect that escaped a uSockets callback
  let msg = defect.msg
  try:
    let hasHandler = server != nil and
      (server.panicHandler != nil or server.errorHandler != nil)
    if hasHandler:
      server.emitServerPanic(source & "_defect", msg)
    else:
      let diag = "[nim_usockets] DEFECT escaped from " & source & ": " & msg &
        " — runtime error state reset; server continues. Fix the root cause."
      writeLine(system.stderr, diag)
  except:
    discard

proc reportEscapedError*(source: string, err: ref CatchableError, server: HttpServer = nil) {.inline.} =
  ## Report a user exception that escaped a uSockets callback
  let msg = $(err.name) & ": " & err.msg
  try:
    let hasHandler = server != nil and
      (server.panicHandler != nil or server.errorHandler != nil)
    if hasHandler:
      server.emitServerPanic(source & "_unhandled", msg)
    else:
      let diag = "[nim_usockets] exception escaped from " & source & ": " & msg
      writeLine(system.stderr, diag)
  except:
    discard

proc onSocketOpenImpl(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr =
  let server = resolveServerFromSocketContext(s)
  if server == nil:
    return s
  when defined(macosx):
    # GCD backend does not emit loop pre/post callbacks.
    # Run maintenance at bounded cadence and avoid nested re-entry.
    let ranMaintenance = server.beginMacosFallbackMaintenance()
    defer:
      server.endMacosFallbackMaintenance(ranMaintenance)

  # Check max connections
  let maxConns = if server.options.maxConnections > 0:
    server.options.maxConnections
  else:
    DefaultMaxConnections

  if server.connectionCount >= maxConns:
    # Reject new connection - close immediately
    discard closeSocketTracked(server, server.ssl.toInt, s, "open_reject_max_connections")
    return s

  # Check if shutting down
  if server.isShuttingDown:
    discard closeSocketTracked(server, server.ssl.toInt, s, "open_reject_shutting_down")
    return s

  let ext = us_socket_ext(server.ssl.toInt, s)
  if ext == nil:
    discard closeSocketTracked(server, server.ssl.toInt, s, "open_reject_missing_socket_data")
    return s

  let openingSocketKey = socketKey(s)
  server.clearSocketClosed(openingSocketKey)
  inc server.nextSocketGeneration
  if server.nextSocketGeneration == 0'u64:
    inc server.nextSocketGeneration

  # GC-managed socket state must not live in the C-owned ext region:
  # collections run on the loop thread while handlers execute and could
  # reclaim it while C still references the ext. Allocate the object on the
  # Nim heap and root it in socketDataRoots; the C ext slot only carries the
  # raw pointer (same pattern as the HTTP client conn data).
  if server.socketDataRoots.hasKey(openingSocketKey):
    # An open re-fired without a close for this recycled socket address: the
    # previous incarnation is still rooted, so releasing it is safe.
    let oldRef = server.socketDataRoots[openingSocketKey]
    releaseSocketDataRefs(unsafeAddr oldRef[])
    server.socketDataRoots.del(openingSocketKey)

  let sdRef = new(SocketData)
  let sockData = unsafeAddr sdRef[]
  server.socketDataRoots[openingSocketKey] = sdRef
  cast[ptr pointer](ext)[] = cast[pointer](sockData)
  sockData.magic = SocketDataMagic
  sockData.server = server
  sockData.generation = server.nextSocketGeneration
  sockData.buffer = newSeqOfCap[byte](InitialBufferSize)
  sockData.readBufferTarget = max(
    readBufferMinFor(server),
    min(readBufferMaxFor(server), InitialBufferSize)
  )
  sockData.bufferStart = 0
  sockData.nextRequestSeq = 0'u64
  sockData.nextWriteSeq = 0'u64
  sockData.pendingSlots = newSeqOfCap[QueuedResponse](2)
  sockData.pendingUsed = newSeqOfCap[bool](2)
  sockData.pendingStart = 0
  sockData.pendingActiveCount = 0
  sockData.coalesceBuffer = ""
  sockData.flags = 0
  sockData.writeBatchDepth = 0
  sockData.pendingBytes = 0
  sockData.wsOutQueue = @[]
  sockData.wsOutHead = 0
  sockData.wsOutPos = 0
  sockData.wsOutPalette = @[]
  sockData.wsOutPaletteRefs = @[]
  sockData.wsOutPaletteFree = @[]
  sockData.wsCoalesceBuffer = ""
  sockData.wsPendingBytes = 0
  sockData.sendBuffer = newStringOfCap(512)
  sockData.sendBufferPos = 0
  sockData.connectedAt = getTime().toUnix
  sockData.setRemoteIp(rawIpToString(ip, ipLength))
  sockData.wsFragmentOpcode = 0
  sockData.wsFragmentCount = 0
  sockData.wsFragmentPayload = ""
  sockData.clearFlag(SDF_WS_FRAGMENT_COMPRESSED)
  sockData.timeoutPhase = tpHeaderRead
  sockData.activeRequestSeq = 0'u64
  sockData.phaseStartedAtMs = getCachedEpochMs()
  sockData.timeoutPhaseSeconds = 0
  let memBudgetLimit = if server.options.maxRequestMemory > 0: server.options.maxRequestMemory else: DefaultRequestMemoryBudget
  sockData.memoryBudget = initRequestMemoryBudget(memBudgetLimit)
  server.applySocketTunables(s)

  inc server.connectionCount

  # Set socket timeout for connection timeout
  sockData.setSocketTimeoutPhase(s, tpHeaderRead, 0'u64)
  if server.connectionOpenHandler != nil:
    try:
      server.connectionOpenHandler(sockData.remoteIp)
    except CatchableError as err:
      server.emitServerPanic("connectionOpenHandler", err.msg)
    except Defect as defect:
      server.emitServerPanic("connectionOpenHandler_defect", defect.msg)

  result = s

const WsReadBufferSize = 256

proc optimizeForWebSocket(sockData: ptr SocketData, s: UsSocketPtr) {.inline.} =
  if sockData == nil:
    return
  sockData.pendingSlots.setLen(0)
  sockData.pendingUsed.setLen(0)
  sockData.pendingStart = 0
  sockData.pendingActiveCount = 0
  sockData.coalesceBuffer.setLen(0)
  sockData.sendBuffer.setLen(0)
  sockData.sendBufferPos = 0
  sockData.cachedHostValue.setLen(0)
  sockData.clearFlag(SDF_KEEP_ALIVE_HEADERS_CACHED)
  let activeBytes = sockData.buffer.len - sockData.bufferStart
  let keep = activeBytes
  var shrunk = newSeqOfCap[byte](max(WsReadBufferSize, keep))
  if keep > 0:
    shrunk.setLen(keep)
    copyMem(addr shrunk[0], unsafeAddr sockData.buffer[sockData.bufferStart], keep)
  sockData.buffer = shrunk
  sockData.bufferStart = 0
  sockData.readBufferTarget = WsReadBufferSize
  if sockData.server != nil:
    sockData.server.applyWebSocketSocketTunables(s)

proc releaseSocketDataRefs(sockData: ptr SocketData) {.inline.} =
  if sockData == nil:
    return
  for i in 0..<sockData.pendingSlots.len:
    if i < sockData.pendingUsed.len and sockData.pendingUsed[i]:
      var queued = sockData.pendingSlots[i]
      queued.closeQueuedFile()
  sockData.buffer = @[]
  sockData.pendingSlots = @[]
  sockData.pendingUsed = @[]
  sockData.pendingStart = 0
  sockData.pendingActiveCount = 0
  sockData.coalesceBuffer = ""
  sockData.flags = 0
  sockData.writeBatchDepth = 0
  sockData.pendingBytes = 0
  sockData.wsQueueReset()
  sockData.wsCoalesceBuffer = ""
  sockData.wsPendingBytes = 0
  sockData.readBufferTarget = 0
  sockData.timeoutPhase = tpNone
  sockData.timeoutPhaseSeconds = 0
  sockData.remoteIpLen = 0
  sockData.wsFragmentOpcode = 0
  sockData.wsFragmentCount = 0
  sockData.wsFragmentPayload = ""
  sockData.sendBuffer = ""
  sockData.cachedHostValue = ""
  sockData.h2conn = nil
  sockData.generation = 0
  sockData.server = nil

proc onSocketOpen(s: UsSocketPtr, isClient: cint, ip: cstring, ipLength: cint): UsSocketPtr {.cdecl.} =
  try:
    discard onSocketOpenImpl(s, isClient, ip, ipLength)
  except Defect as defect:
    reportEscapedDefect("onSocketOpen", defect)
  except CatchableError as err:
    reportEscapedError("onSocketOpen", err)
  s

proc cleanupH2Connection(conn: H2ServerConnection) {.inline.} =
  if conn == nil:
    return
  conn.active = false
  conn.continuationStreamId = 0
  conn.continuationFrameCount = 0
  conn.headerBlockBuf = ""
  conn.h2SendBuf = ""
  conn.h2SendBufPos = 0
  conn.streams.clear()
  conn.rstStreams.clear()
  conn.closedStreams.clear()

proc onSocketCloseImpl(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr =
  let server = resolveServerFromSocket(s)
  if server == nil:
    return s

  let closingSocketKey = socketKey(s)
  server.markSocketClosed(closingSocketKey)
  server.invalidatePendingFlushForSocket(s, closingSocketKey)

  let sockData = socketDataFor(server.ssl.toInt, s)
  if sockData != nil:
    let closingIp = sockData.remoteIp
    let wasWebSocket = sockData.hasFlag(SDF_IS_WEBSOCKET)
    let closingRequestSeq = sockData.activeRequestSeq
    sockData.clearFlag(SDF_PENDING_LOOP_FLUSH)
    # Decrement connection count
    if sockData.server != nil and sockData.server.connectionCount > 0:
      dec sockData.server.connectionCount
    # Call WebSocket close handler if this was a WebSocket
    if sockData.hasFlag(SDF_IS_WEBSOCKET) and sockData.ws != nil:
      sockData.ws.isOpen = false
      sockData.ws.unsubscribeAllTopics()
      if sockData.server != nil:
        sockData.server.removeTrackedWebSocket(sockData.ws)
        if sockData.server.wsDrainQueued != nil:
          let drainKey = sockData.ws.wsKey()
          if drainKey.len > 0:
            discard sockData.server.wsDrainQueued.excl(drainKey)
      if sockData.server != nil and sockData.server.wsCloseHandler != nil:
        try:
          sockData.server.wsCloseHandler(sockData.ws)
        except CatchableError as err:
          sockData.server.emitServerPanic("wsCloseHandler", err.msg)
        except Defect as defect:
          sockData.server.emitServerPanic("wsCloseHandler_defect", defect.msg)
      sockData.ws.socket = nil
      releaseWebSocket(sockData.ws)
      sockData.ws = nil
    if sockData.hasFlag(SDF_IS_HTTP2) and sockData.h2conn != nil and sockData.server != nil:
      untrackH2Connection(sockData.server, sockData.h2conn)
      cleanupH2Connection(sockData.h2conn)
    let serverRef = sockData.server
    releaseSocketDataRefs(sockData)
    # Unroot after the refs are released so the GC may reclaim the object, and
    # nil the C ext slot so no later resolution can dereference the stale
    # pointer (a later open on the recycled address installs a fresh pointer
    # and a fresh root entry).
    server.socketDataRoots.del(closingSocketKey)
    let closingExt = us_socket_ext(server.ssl.toInt, s)
    if closingExt != nil:
      cast[ptr pointer](closingExt)[] = nil
    if serverRef != nil and serverRef.connectionCloseHandler != nil:
      try:
        serverRef.connectionCloseHandler(closingIp, wasWebSocket, closingRequestSeq, closingSocketKey)
      except CatchableError as err:
        serverRef.emitServerPanic("connectionCloseHandler", err.msg)
      except Defect as defect:
        serverRef.emitServerPanic("connectionCloseHandler_defect", defect.msg)
    if serverRef != nil and serverRef.isShuttingDown and serverRef.connectionCount <= 0:
      beginShutdown(serverRef)
  result = s

proc onSocketClose(s: UsSocketPtr, code: cint, reason: pointer): UsSocketPtr {.cdecl.} =
  try:
    discard onSocketCloseImpl(s, code, reason)
  except Defect as defect:
    reportEscapedDefect("onSocketClose", defect)
  except CatchableError as err:
    reportEscapedError("onSocketClose", err)
  s

proc handleWebSocketData(sockData: ptr SocketData, s: UsSocketPtr) {.inline.} =
  ## Handle incoming WebSocket frames
  # RFC 6455 §5.3:
  # client->server frames must be masked.
  var consumed = sockData.bufferStart
  let initialConsumed = consumed
  let dispatchBudgetFrames = max(1, if sockData.server.options.parseBudgetRequestsPerRead > 0:
    sockData.server.options.parseBudgetRequestsPerRead
  else:
    DefaultParseBudgetRequestsPerRead)
  let dispatchBudgetBytes = max(1, if sockData.server.options.parseBudgetBytesPerRead > 0:
    sockData.server.options.parseBudgetBytesPerRead
  else:
    DefaultParseBudgetBytesPerRead)
  var framesProcessed = 0
  var consumedBytesThisBatch = 0
  var scheduleResume = false
  let wsMaxPayload = if sockData.server.options.maxBodySize > 0: sockData.server.options.maxBodySize else: DefaultMaxBodySize
  let wsHandler = sockData.server.wsHandler
  let wsRawHandler = sockData.server.wsRawHandler
  let wsConn = sockData.ws
  let canDispatchWs = (wsHandler != nil or wsRawHandler != nil) and wsConn != nil
  let fairnessEnabled = sockData.server.fairnessEnabled
  let compressionActive = sockData.hasFlag(SDF_WS_COMPRESSION_ACTIVE)
  var opcode = 0
  var payload = ""
  var payloadStart = 0
  var payloadLength = 0
  var frameLen = 0
  var fin = true
  var compressed = false
  while consumed < sockData.buffer.len:
    if framesProcessed >= dispatchBudgetFrames or
       consumedBytesThisBatch >= dispatchBudgetBytes or
       (fairnessEnabled and sockData.server.dispatchLoopBudgetExhausted()):
      scheduleResume = true
      break

    if not compressionActive and sockData.wsFragmentOpcode == 0:
      let decodeStatus = decodeWebSocketFrameZeroCopy(
        sockData.buffer,
        consumed,
        opcode,
        payloadStart,
        payloadLength,
        frameLen,
        fin,
        compressed,
        false
      )
      if decodeStatus == 0:
        break
      if decodeStatus == -2:
        sendWsCloseAndTerminate(sockData, s, WsClose1002)
        return
      if decodeStatus < 0:
        sendWsCloseAndTerminate(sockData, s, WsClose1002)
        return

      consumed += frameLen
      inc framesProcessed
      consumedBytesThisBatch += frameLen
      sockData.server.consumeLoopDispatchBudget(1, frameLen)

      case opcode
      of 0x1, 0x2:
        if payloadLength > wsMaxPayload:
          sendWsCloseAndTerminate(sockData, s, WsClose1009)
          return
        if fin:
          if not deliverWebSocketMessageFromBuffer(
            sockData,
            s,
            opcode,
            sockData.buffer,
            payloadStart,
            payloadLength,
            wsHandler,
            wsRawHandler,
            wsConn
          ):
            return
        else:
          sockData.wsFragmentOpcode = opcode
          sockData.wsFragmentCount = 1
          sockData.wsFragmentPayload = bufferPayloadToString(sockData.buffer, payloadStart, payloadLength)
          sockData.setFlagTo(SDF_WS_FRAGMENT_COMPRESSED, false)
      of 0x8:
        let closePayload = bufferPayloadToString(sockData.buffer, payloadStart, payloadLength)
        var replyPayload = closePayload
        if closePayload.len == 1:
          replyPayload = WsClose1002
        elif closePayload.len > 125:
          replyPayload = WsClose1002
        elif closePayload.len >= 2:
          let closeCode = (ord(closePayload[0]) shl 8) or ord(closePayload[1])
          if not closeCode.isValidWsCloseCode():
            replyPayload = WsClose1002
          elif closePayload.len > 2 and closePayload[2..^1].validateUtf8() != -1:
            replyPayload = WsClose1007
        sendWsCloseAndTerminate(sockData, s, replyPayload)
        return
      of 0x9:
        if sockData.ws != nil:
          if payloadLength == 0:
            discard sendWsFrameWithBackpressure(sockData.ws, wsPong, "", false)
          else:
            let pingPayload = bufferPayloadToString(sockData.buffer, payloadStart, payloadLength)
            discard sendWsFrameWithBackpressure(sockData.ws, wsPong, pingPayload, false)
      of 0xA:
        discard
      of 0x0:
        if sockData.wsFragmentOpcode == 0:
          sendWsCloseAndTerminate(sockData, s, WsClose1002)
          return
      else:
        sendWsCloseAndTerminate(sockData, s, WsClose1002)
        return
    else:
      let decodeStatus = decodeWebSocketFrame(
        sockData.buffer,
        consumed,
        opcode,
        payload,
        frameLen,
        fin,
        compressed,
        compressionActive
      )
      if decodeStatus == 0:
        break
      if decodeStatus == -2:
        sendWsCloseAndTerminate(sockData, s, WsClose1002)
        return
      if decodeStatus < 0:
        sendWsCloseAndTerminate(sockData, s, WsClose1002)
        return

      consumed += frameLen
      inc framesProcessed
      consumedBytesThisBatch += frameLen
      sockData.server.consumeLoopDispatchBudget(1, frameLen)

      case opcode
      of 0x1, 0x2:
        if (not compressed) and payload.len > wsMaxPayload:
          sendWsCloseAndTerminate(sockData, s, WsClose1009)
          return
        if sockData.wsFragmentOpcode != 0:
          sendWsCloseAndTerminate(sockData, s, WsClose1002)
          return
        if fin:
          var messagePayload = move(payload)
          if compressed:
            let inflateResult = decompressWsPayload(
              messagePayload,
              sockData.server.wsCompressionInflateLimit()
            )
            if not inflateResult.ok:
              sendWsCloseAndTerminate(
                sockData,
                s,
                (if inflateResult.tooLarge: WsClose1009 else: WsClose1002)
              )
              return
            messagePayload = inflateResult.plain
          if messagePayload.len > wsMaxPayload:
            sendWsCloseAndTerminate(sockData, s, WsClose1009)
            return
          if not deliverWebSocketMessage(sockData, s, opcode, messagePayload, wsHandler, wsRawHandler, wsConn):
            return
        else:
          sockData.wsFragmentOpcode = opcode
          sockData.wsFragmentCount = 1
          sockData.wsFragmentPayload = move(payload)
          sockData.setFlagTo(SDF_WS_FRAGMENT_COMPRESSED, compressed)
      of 0x0:
        if sockData.wsFragmentOpcode == 0:
          sendWsCloseAndTerminate(sockData, s, WsClose1002)
          return
        if compressed:
          sendWsCloseAndTerminate(sockData, s, WsClose1002)
          return
        inc sockData.wsFragmentCount
        let maxFrags = sockData.server.options.wsMaxFragmentCount
        if maxFrags > 0 and sockData.wsFragmentCount > maxFrags:
          sendWsCloseAndTerminate(sockData, s, WsClose1009)
          return
        if payload.len > wsMaxPayload or sockData.wsFragmentPayload.len > wsMaxPayload - payload.len:
          sendWsCloseAndTerminate(sockData, s, WsClose1009)
          return
        if payload.len > 0:
          sockData.wsFragmentPayload.add(payload)
        if fin:
          let msgOpcode = sockData.wsFragmentOpcode
          var msgPayload = move(sockData.wsFragmentPayload)
          let msgCompressed = sockData.hasFlag(SDF_WS_FRAGMENT_COMPRESSED)
          sockData.wsFragmentOpcode = 0
          sockData.wsFragmentCount = 0
          sockData.wsFragmentPayload.setLen(0)
          sockData.clearFlag(SDF_WS_FRAGMENT_COMPRESSED)
          if msgCompressed:
            let inflateResult = decompressWsPayload(
              msgPayload,
              sockData.server.wsCompressionInflateLimit()
            )
            if not inflateResult.ok:
              sendWsCloseAndTerminate(
                sockData,
                s,
                (if inflateResult.tooLarge: WsClose1009 else: WsClose1002)
              )
              return
            msgPayload = inflateResult.plain
          if msgPayload.len > wsMaxPayload:
            sendWsCloseAndTerminate(sockData, s, WsClose1009)
            return
          if msgOpcode == 0x2:
            if canDispatchWs:
              if not deliverWebSocketMessage(sockData, s, msgOpcode, msgPayload, wsHandler, wsRawHandler, wsConn):
                return
          else:
            if not deliverWebSocketMessage(sockData, s, msgOpcode, msgPayload, wsHandler, wsRawHandler, wsConn):
              return
      of 0x8:
        var replyPayload = payload
        if payload.len == 1:
          replyPayload = WsClose1002
        elif payload.len > 125:
          replyPayload = WsClose1002
        elif payload.len >= 2:
          let closeCode = (ord(payload[0]) shl 8) or ord(payload[1])
          if not closeCode.isValidWsCloseCode():
            replyPayload = WsClose1002
          elif payload.len > 2 and payload[2..^1].validateUtf8() != -1:
            replyPayload = WsClose1007
        sendWsCloseAndTerminate(sockData, s, replyPayload)
        return
      of 0x9:
        if sockData.ws != nil:
          discard sendWsFrameWithBackpressure(sockData.ws, wsPong, payload, false)
      of 0xA:
        discard
      else:
        sendWsCloseAndTerminate(sockData, s, WsClose1002)
        return

  # Advance read window and compact only when beneficial.
  if consumed > initialConsumed:
    sockData.bufferStart = consumed
    if sockData.bufferStart >= sockData.buffer.len:
      sockData.buffer.setLen(0)
      sockData.bufferStart = 0
    elif sockData.bufferStart >= WsInputCompactThreshold and
         (sockData.bufferStart * 2 >= sockData.buffer.len):
      let remaining = sockData.buffer.len - sockData.bufferStart
      moveMem(addr sockData.buffer[0], unsafeAddr sockData.buffer[sockData.bufferStart], remaining)
      sockData.buffer.setLen(remaining)
      sockData.bufferStart = 0
  if scheduleResume and sockData.buffer.len > sockData.bufferStart and not sockData.hasFlag(SDF_READ_PAUSED):
    sockData.scheduleSocketDataResume(s)

proc compactSocketBuffer(sockData: ptr SocketData) {.inline.} =
  if sockData == nil or sockData.bufferStart <= 0:
    return
  if sockData.bufferStart >= sockData.buffer.len:
    sockData.buffer.setLen(0)
    sockData.bufferStart = 0
    maybeShrinkReadBuffer(sockData)
    return
  let remaining = sockData.buffer.len - sockData.bufferStart
  moveMem(addr sockData.buffer[0], unsafeAddr sockData.buffer[sockData.bufferStart], remaining)
  sockData.buffer.setLen(remaining)
  sockData.bufferStart = 0
  maybeShrinkReadBuffer(sockData)

proc compactH2ReadBuffer(sockData: ptr SocketData) {.inline.} =
  if sockData == nil or sockData.bufferStart <= 0:
    return
  if sockData.bufferStart >= sockData.buffer.len:
    sockData.buffer.setLen(0)
    sockData.bufferStart = 0
    maybeShrinkReadBuffer(sockData)
  elif sockData.bufferStart >= InputCompactThreshold and
      (sockData.bufferStart * 2 >= sockData.buffer.len):
    sockData.compactSocketBuffer()

proc closeSocketIfPending(sockData: ptr SocketData, s: UsSocketPtr) =
  if sockData == nil or s == nil or not sockData.hasFlag(SDF_PENDING_CLOSE):
    return
  if not sockData.pendingIsEmpty():
    return
  if sockData.hasFlag(SDF_IS_WEBSOCKET) and not sockData.wsQueueIsEmpty():
    return
  if sockData.sendBufferRemaining() > 0:
    return
  let ssl = sockData.server.ssl.toInt
  if us_socket_is_closed(ssl, s) != 0 or us_socket_is_shut_down(ssl, s) != 0:
    sockData.clearFlag(SDF_PENDING_CLOSE)
    return
  sockData.clearFlag(SDF_PENDING_CLOSE)
  discard closeSocketTracked(sockData.server, ssl, s, "pending_close")

proc invokeHeadWritableHandler(sockData: ptr SocketData, s: UsSocketPtr): bool {.inline.} =
  if sockData == nil or s == nil or sockData.pendingIsEmpty():
    return true
  let headIdx = sockData.pendingStart
  if headIdx < 0 or headIdx >= sockData.pendingUsed.len or not sockData.pendingUsed[headIdx]:
    return true
  let queued = sockData.pendingSlots[headIdx]
  if not queued.hasTryEnd or queued.writableHandler == nil:
    return true
  let keepOpen = queued.writableHandler(queued.tryEndOffset)
  if not keepOpen:
    discard closeSocketTracked(sockData.server, sockData.server.ssl.toInt, s, "writable_handler_requested_close")
    return false
  true

proc statusReasonFor(statusCode: int): string {.inline.} =
  case statusCode
  of 200: "OK"
  of 400: "Bad Request"
  of 413: "Payload Too Large"
  of 414: "URI Too Long"
  of 417: "Expectation Failed"
  of 422: "Unprocessable Content"
  of 429: "Too Many Requests"
  of 431: "Request Header Fields Too Large"
  of 500: "Internal Server Error"
  of 501: "Not Implemented"
  of 503: "Service Unavailable"
  of 505: "HTTP Version Not Supported"
  else: "Error"

proc buildProtocolErrorResponse(statusCode: int, body: string, closeConnection: bool): string {.inline.} =
  let safeStatus =
    if statusCode >= 100 and statusCode <= 999:
      statusCode
    else:
      400
  result = newStringOfCap(200 + body.len)
  result.add("HTTP/1.1 ")
  fastIntToStr(safeStatus, result)
  result.add(" ")
  result.add(statusReasonFor(safeStatus))
  result.add("\r\n")
  result.add(formatDateHeaderLine(getTime().toUnix))
  let bodyForbidden = safeStatus == 204 or safeStatus == 304
  if not safeStatus.statusForbidsContentLength():
    if safeStatus == 205 or bodyForbidden:
      result.add("content-length: 0\r\n")
    else:
      result.add("content-length: ")
      fastIntToStr(body.len, result)
      result.add("\r\n")
  if closeConnection:
    result.add("connection: close\r\n")
  else:
    result.add("connection: keep-alive\r\n")
  result.add("\r\n")
  if body.len > 0 and safeStatus >= 200 and not bodyForbidden and safeStatus != 205:
    result.add(body)

proc parseErrorResponseFor(statusCode: int): string {.inline.} =
  buildProtocolErrorResponse(statusCode, "", true)

proc nextPow2(v: int): int {.inline.} =
  if v <= 1:
    return 1
  result = 1
  while result < v and result < (high(int) shr 1):
    result = result shl 1
  if result < v:
    result = v

proc readBufferMinFor(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultReadBufferMinCapacity
  max(InitialBufferSize, server.options.readBufferMinCapacity)

proc readBufferMaxFor(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultReadBufferMaxCapacity
  let configured = server.options.readBufferMaxCapacity
  if configured <= 0:
    return DefaultReadBufferMaxCapacity
  max(readBufferMinFor(server), configured)

proc readBufferShrinkPercentFor(server: HttpServer): int {.inline, used.} =
  if server == nil:
    return DefaultReadBufferShrinkPercent
  let configured = server.options.readBufferShrinkPercent
  if configured <= 0:
    return DefaultReadBufferShrinkPercent
  min(95, configured)

proc updateReadBufferTargetOnAppend(sockData: ptr SocketData, requiredBytes: int) {.inline.} =
  if sockData == nil:
    return
  let minCap = readBufferMinFor(sockData.server)
  let maxCap = readBufferMaxFor(sockData.server)
  let needed = max(minCap, requiredBytes)
  if needed > sockData.readBufferTarget:
    var target = sockData.readBufferTarget
    if target < minCap:
      target = minCap
    while target < needed and target < maxCap:
      target = target + target div 2
    sockData.readBufferTarget = min(maxCap, max(target, needed))
  elif sockData.readBufferTarget < minCap:
    sockData.readBufferTarget = minCap

proc maybeShrinkReadBuffer(sockData: ptr SocketData) {.inline.} =
  if sockData == nil:
    return
  let activeBytes = sockData.buffer.len - sockData.bufferStart
  let minCap = readBufferMinFor(sockData.server)
  let maxCap = readBufferMaxFor(sockData.server)
  var target = sockData.readBufferTarget
  if target <= 0:
    target = minCap
  if target > maxCap:
    target = maxCap
  if activeBytes > target div 4:
    return
  let nextTarget = max(minCap, nextPow2(max(activeBytes, minCap)))
  if nextTarget >= target:
    return
  sockData.readBufferTarget = nextTarget
  if activeBytes <= 0:
    sockData.buffer.setLen(0)
    sockData.bufferStart = 0
    return
  var compacted = newSeq[byte](activeBytes)
  moveMem(addr compacted[0], unsafeAddr sockData.buffer[sockData.bufferStart], activeBytes)
  sockData.buffer = compacted
  sockData.bufferStart = 0

proc overloadRejectReasonFor(sockData: ptr SocketData): OverloadRejectReason {.inline.} =
  if sockData == nil or sockData.server == nil:
    return orrNone
  let pendingResponses = pendingActiveCountForOverload(sockData)
  var backlogLimit = overloadConfiguredBacklogLimit(sockData.server)
  var pendingLimit = overloadConfiguredPendingLimit(sockData.server)
  let adaptiveEnabled = overloadAdaptiveEnabledFor(sockData.server)
  if adaptiveEnabled:
    let limits = overloadLimitSnapshot(sockData.server)
    backlogLimit = limits.backlogLimit
    pendingLimit = limits.pendingLimit
  decaySpillPressure(sockData.server)
  let overloadByBacklog = backlogLimit > 0 and sockData.pendingBytes > int64(backlogLimit)
  let overloadByPending = pendingLimit > 0 and pendingResponses > pendingLimit
  let overloadControllerEnabled = backlogLimit > 0 or pendingLimit > 0
  let overloadBySpillPressure = overloadControllerEnabled and sockData.server.spillPressureRejecting
  let overloaded = overloadByBacklog or overloadByPending or overloadBySpillPressure
  if adaptiveEnabled:
    updateOverloadAdaptiveFeedback(
      sockData.server,
      overloaded,
      sockData.pendingBytes,
      pendingResponses,
      overloadBySpillPressure
    )
  if not overloaded:
    return orrNone
  if overloadByBacklog or overloadBySpillPressure:
    return orrBacklog
  orrPending

proc shouldRejectForOverload(sockData: ptr SocketData): bool {.inline, used.} =
  overloadRejectReasonFor(sockData) != orrNone

proc shouldCloseAfterOverloadWrite(closeRequested: bool, wroteBytes: int, responseLen: int): bool {.inline, used.} =
  closeRequested or responseLen <= 0 or wroteBytes < responseLen

proc rejectOverloadedSocket(sockData: ptr SocketData, s: UsSocketPtr) {.inline, used.} =
  rejectOverloadedSocket(sockData, s, overloadRejectReasonFor(sockData))

proc rejectOverloadedSocket(sockData: ptr SocketData, s: UsSocketPtr, reason: OverloadRejectReason) {.inline.} =
  if sockData == nil or sockData.server == nil or s == nil:
    return
  if reason == orrNone:
    return
  inc sockData.server.metricsOverloadRejects
  case reason
  of orrBacklog:
    inc sockData.server.metricsOverloadRejectBacklog
  of orrPending:
    inc sockData.server.metricsOverloadRejectPending
  else:
    discard
  let closeConn = sockData.server.options.overloadCloseOnReject
  var response = newStringOfCap(200)
  response.add("HTTP/1.1 503 Service Unavailable\r\n")
  response.add(formatDateHeaderLine(getTime().toUnix))
  response.add("content-length: 0\r\n")
  let retryAfterSeconds = max(0, sockData.server.options.overloadRetryAfterSeconds)
  if retryAfterSeconds > 0:
    response.add("retry-after: ")
    fastIntToStr(retryAfterSeconds, response)
    response.add("\r\n")
  if closeConn:
    response.add("connection: close\r\n\r\n")
  else:
    response.add("connection: keep-alive\r\n\r\n")
  let wrote = writeFallbackPayloadAndMaybeClose(
    sockData.server,
    sockData.server.ssl.toInt,
    s,
    response,
    "overload_reject_short_write"
  )
  if closeConn and wrote >= response.len:
    discard closeSocketTracked(sockData.server, sockData.server.ssl.toInt, s, "overload_reject_close_policy")

proc parseErrorQuarantineBytes(totalRequestSize: int, unreadBytes: int): int {.inline.} =
  ## On keep-alive parse errors, consume at least one byte so malformed
  ## bytes cannot be parsed repeatedly forever on the same socket.
  if unreadBytes <= 0:
    return 0
  var toConsume = if totalRequestSize > 0: totalRequestSize else: 1
  if toConsume > unreadBytes:
    toConsume = unreadBytes
  toConsume

when defined(singleThread):
  var httpResponsePool: seq[HttpResponse]
  var wsPool: seq[WebSocket]
else:
  var httpResponsePool {.threadvar.}: seq[HttpResponse]
  var wsPool {.threadvar.}: seq[WebSocket]
const HttpResponsePoolMax = 4096
# WebSocket refs are public handles handed to user callbacks. Reusing a closed
# handle for a future socket can let stale application references affect a new peer.
const WsPoolMax = 0

proc acquireHttpResponse(): HttpResponse {.inline.} =
  let pool = addr httpResponsePool
  if pool[].len > 0:
    result = pool[][^1]
    pool[].setLen(pool[].len - 1)
  else:
    new(result)
  result.retainCount = 1

proc cloneStringFastMap(src: FastMap[string]): FastMap[string] =
  if src == nil:
    return nil
  result = newFastMap[string]()
  discard result.reserve(max(8, src.len * 2))
  for key, value in src.pairs():
    result[key] = value

proc snapshotRequestForRetainedResponse(req: HttpRequest): HttpRequest =
  if req == nil:
    return nil

  let pathCopy = $req.path
  let queryCopy = $req.queryStringRaw
  let versionCopy = req.httpVersion
  let upgradeCopy = $req.upgradeHeader
  let wsKeyCopy = $req.secWebSocketKeyHeader
  let wsVersionCopy = $req.secWebSocketVersionHeader
  let wsExtensionsCopy = $req.secWebSocketExtensionsHeader
  let contentTypeCopy = $req.contentTypeHeader
  let cookieCopy = $req.cookieHeader
  req.ensureHeadersPopulated()

  new(result)
  result.pathStr = pathCopy
  result.queryStr = queryCopy
  result.httpVersionStr = versionCopy
  result.httpMajor = req.httpMajor
  result.httpMinor = req.httpMinor
  if req.bodyInFile and req.bodyFilePath.len > 0:
    try:
      if fileExists(req.bodyFilePath):
        result.body = readFile(req.bodyFilePath)
    except CatchableError:
      discard
  else:
    result.body = req.body
  result.bodyInFile = false
  result.remoteIp = req.remoteIp
  result.headers = cloneStringFastMap(req.headers)
  result.query = cloneStringFastMap(req.query)
  result.headerFlags = req.headerFlags
  result.methodKind = req.methodKind
  result.connectionClose = req.connectionClose
  result.connectionHasUpgrade = req.connectionHasUpgrade
  result.upgradeStr = upgradeCopy
  result.wsKeyStr = wsKeyCopy
  result.wsVersionStr = wsVersionCopy
  result.wsExtensionsStr = wsExtensionsCopy
  result.contentTypeStr = contentTypeCopy
  result.cookieStr = cookieCopy
  result.headersDeferred = false
  result.sliceMask = 0
  result.bufferPtr = nil
  result.bufferLen = 0
  result.knownHeaderPresent = {}
  result.rawHeaderCount = 0
  result.rawHeadersClassified = true
  if req.cachedHostStr.len > 0:
    result.cachedHostStr = req.cachedHostStr
  elif result.headers != nil:
    result.cachedHostStr = result.headers.getOrDefault(HeaderHost, "")

## Retain the response so it outlives the socket, snapshotting the request when needed
proc retainHttpResponse*(res: HttpResponse) {.inline.} =
  if res == nil:
    return
  if res.retainCount == 1 and res.requestRef != nil:
    res.requestRef = snapshotRequestForRetainedResponse(res.requestRef)
  inc res.retainCount

## Release a previously retained response and drop it when the last reference goes away
proc releaseHttpResponse*(res: HttpResponse) {.inline.} =
  if res == nil:
    return
  if res.retainCount > 1:
    dec res.retainCount
    return
  res.retainCount = 0
  let pool = addr httpResponsePool
  if pool[].len < HttpResponsePoolMax:
    res.headersInited = false
    res.bodySent = false
    res.headersSent = false
    res.autoEnd = true
    res.connectionClose = false
    res.chunkedStarted = false
    res.chunkedFinished = false
    res.tryEndActive = false
    res.tryEndOffset = 0'u64
    res.tryEndQueued = 0'u64
    res.tryEndTotal = 0'u64
    if res.capturedHeader.len > 0: res.capturedHeader.setLen(0)
    if res.capturedBody.len > 0: res.capturedBody.setLen(0)
    if res.capturedRaw.len > 0: res.capturedRaw.setLen(0)
    res.writableHandler = nil
    res.socket = nil
    res.requestRef = nil
    res.requestIsHttp11 = false
    res.h2StreamId = 0
    res.h2Conn = nil
    if res.setCookieHeaders.len > 0:
      res.setCookieHeaders.setLen(0)
    if res.headers != nil:
      res.headers.clear()
    res.statusCodeInt = 0
    pool[].add(res)

proc acquireWebSocket(socket: UsSocketPtr, ssl: cint, compressionEnabled: bool): WebSocket {.inline.} =
  let pool = addr wsPool
  if pool[].len > 0:
    result = pool[][^1]
    pool[].setLen(pool[].len - 1)
    result.socket = socket
    result.ssl = ssl
    result.isOpen = true
    result.compressionEnabled = compressionEnabled
    result.server = nil
  else:
    result = WebSocket(
      socket: socket,
      ssl: ssl,
      isOpen: true,
      compressionEnabled: compressionEnabled
    )

proc releaseWebSocket(ws: WebSocket) {.inline.} =
  if ws == nil:
    return
  ws.socket = nil
  ws.ssl = 0
  ws.isOpen = false
  ws.server = nil
  ws.compressionEnabled = false
  if ws.subscriptions != nil:
    ws.subscriptions.close()
    ws.subscriptions = nil
  let pool = addr wsPool
  if pool[].len < WsPoolMax:
    pool[].add(ws)

proc h2CheckControlFrameRate(conn: H2ServerConnection): bool {.inline.} =
  let now = epochTime() * 1000.0
  if now - conn.controlFrameWindowStart > H2ControlFrameRateWindowMs:
    conn.controlFrameCount = 0
    conn.controlFrameWindowStart = now
  inc conn.controlFrameCount
  conn.controlFrameCount <= H2ControlFrameRateLimit

proc h2FrameCountsTowardControlRate(frameType: h2p.H2FrameType): bool {.inline.} =
  frameType in {
    h2p.ftSettings,
    h2p.ftPing,
    h2p.ftRstStream,
    h2p.ftWindowUpdate,
    h2p.ftPriority,
  }

proc initH2ServerConnection(): H2ServerConnection =
  new(result)
  result.active = true
  result.localSettings = h2p.defaultH2Settings()
  result.remoteSettings = h2p.defaultH2Settings()
  result.remoteSettings.enablePush = true
  result.localWindow = h2p.DefaultWindowSize
  result.remoteWindow = h2p.DefaultWindowSize
  result.encoder = hpackMod.initHpackEncoder(huffman = true)
  result.decoder = hpackMod.initHpackDecoder()
  result.streams = initTable[uint32, H2ServerStream](16)
  result.rstStreams = initTable[uint32, bool](4)
  result.controlFrameWindowStart = epochTime() * 1000.0
  result.closedStreams = initTable[uint32, bool](4)
  result.nextPushStreamId = 2

proc trackH2Connection(server: HttpServer, conn: H2ServerConnection, s: UsSocketPtr, ssl: cint) {.inline.} =
  server.h2Connections.add(H2ConnEntry(conn: conn, socket: s, ssl: ssl))

proc untrackH2Connection(server: HttpServer, conn: H2ServerConnection) {.inline.} =
  for i in 0 ..< server.h2Connections.len:
    if server.h2Connections[i].conn == conn:
      server.h2Connections.del(i)
      return

proc h2FindStream(conn: H2ServerConnection, id: uint32): ptr H2ServerStream {.inline.} =
  conn.streams.withValue(id, val):
    return val
  return nil

proc h2QueuePendingSendData(
  streamPtr: ptr H2ServerStream,
  socket: UsSocketPtr,
  ssl: int,
  data: string,
  startPos: int,
  endStream: bool
): bool =
  if streamPtr == nil or startPos >= data.len:
    if streamPtr != nil and endStream:
      streamPtr.pendingSendEndStream = true
    return true
  let remaining = data.len - max(0, startPos)
  if remaining < 0:
    return false
  if streamPtr.pendingSendData.len > MaxH2SendBufSize - remaining:
    return false
  if streamPtr.pendingSendData.len == 0:
    streamPtr.pendingSendPos = 0
  streamPtr.pendingSendData.add(data[startPos ..< data.len])
  streamPtr.pendingSendSocket = socket
  streamPtr.pendingSendSsl = ssl
  streamPtr.pendingSendEndStream = streamPtr.pendingSendEndStream or endStream
  true

proc h2RemoveStream(conn: H2ServerConnection, id: uint32) {.inline.} =
  conn.streams.del(id)
  conn.closedStreams[id] = true
  if conn.closedStreams.len > 256:
    var oldest: uint32 = 0
    for k in conn.closedStreams.keys:
      oldest = k
      break
    conn.closedStreams.del(oldest)

proc h2FlushPendingSendData(conn: H2ServerConnection, streamId: uint32) =
  let streamPtr = h2FindStream(conn, streamId)
  if streamPtr == nil or streamPtr.pendingSendData.len == 0:
    return
  let maxFrame = int(conn.remoteSettings.maxFrameSize)
  var frameBuf = newStringOfCap(maxFrame + h2p.H2FrameHeaderSize)
  while streamPtr.pendingSendPos < streamPtr.pendingSendData.len:
    let connWindow = max(int(conn.remoteWindow), 0)
    let streamWindow = max(int(streamPtr.sendWindow), 0)
    let flowMax = min(connWindow, streamWindow)
    if flowMax <= 0:
      break
    let remaining = streamPtr.pendingSendData.len - streamPtr.pendingSendPos
    let chunkLen = min(min(remaining, maxFrame), flowMax)
    if chunkLen <= 0:
      break
    let isLast = streamPtr.pendingSendPos + chunkLen >= streamPtr.pendingSendData.len
    let endStream = streamPtr.pendingSendEndStream and isLast
    frameBuf.setLen(0)
    h2p.serializeDataView(streamId,
      streamPtr.pendingSendData.toOpenArray(streamPtr.pendingSendPos, streamPtr.pendingSendPos + chunkLen - 1),
      endStream = endStream, frameBuf)
    if not h2TryWriteFrameBuf(conn, cint(streamPtr.pendingSendSsl), streamPtr.pendingSendSocket, frameBuf):
      break
    conn.remoteWindow -= int32(chunkLen)
    streamPtr.sendWindow -= int32(chunkLen)
    streamPtr.pendingSendPos += chunkLen
  if streamPtr.pendingSendPos >= streamPtr.pendingSendData.len:
    streamPtr.pendingSendData = ""
    streamPtr.pendingSendPos = 0
    if streamPtr.pendingSendEndStream:
      streamPtr.pendingSendEndStream = false
      streamPtr.endStreamSent = true
      h2RemoveStream(conn, streamId)

proc h2SendGoaway(conn: H2ServerConnection, errorCode: h2p.H2ErrorCode, ssl: cint, s: UsSocketPtr) {.inline.} =
  conn.active = false
  conn.sentGoaway = true
  var goawayBuf = newStringOfCap(h2p.H2FrameHeaderSize + 8)
  h2p.serializeGoaway(conn.lastStreamId, uint32(errorCode), goawayBuf)
  h2WriteFrameBuf(conn, ssl, s, goawayBuf)
  if conn.h2SendBuf.len <= conn.h2SendBufPos:
    us_socket_shutdown(ssl, s)

proc eqIgnoreCaseAscii(a, b: string): bool {.inline.} =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    let ca = if a[i] >= 'A' and a[i] <= 'Z': char(ord(a[i]) + 32) else: a[i]
    let cb = if b[i] >= 'A' and b[i] <= 'Z': char(ord(b[i]) + 32) else: b[i]
    if ca != cb: return false
  true

proc h2StrictParseContentLength(hv: string): int {.inline.} =
  if hv.len == 0 or hv.len > 18:
    return -1
  if hv.len > 1 and hv[0] == '0':
    return -1
  var parsed = 0
  for i in 0 ..< hv.len:
    let d = ord(hv[i]) - ord('0')
    if d < 0 or d > 9:
      return -1
    if parsed > (high(int) - d) div 10:
      return -1
    parsed = parsed * 10 + d
  parsed

proc h2HeaderNameValid(name: string): bool {.inline.} =
  if name.len == 0:
    return false
  for c in name:
    let b = byte(c)
    if c >= 'A' and c <= 'Z':
      return false
    if not TokenCharTable[b]:
      return false
  true

proc h2HeaderValueValid(value: string): bool {.inline.} =
  for c in value:
    if c == '\r' or c == '\n' or c == '\0':
      return false
  true

proc h2ValidatePseudoHeaders(headers: seq[(string, string)]): bool {.inline.} =
  var methodCount, pathCount, schemeCount, authorityCount = 0
  var seenRegular = false
  var isConnect = false
  var contentLengthSeen = false
  var contentLengthValue = -1
  for (name, value) in headers:
    if name.len > 0 and name[0] == ':':
      if seenRegular:
        return false
      case name
      of ":method":
        inc methodCount
        case value
        of "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE":
          discard
        of "CONNECT":
          isConnect = true
        else:
          return false
      of ":path":
        if value.len == 0:
          return false
        inc pathCount
      of ":scheme": inc schemeCount
      of ":authority": inc authorityCount
      of ":status": return false
      else: return false
    else:
      seenRegular = true
      if not name.h2HeaderNameValid() or not value.h2HeaderValueValid():
        return false
      if name.eqIgnoreCaseAscii("connection") or name.eqIgnoreCaseAscii("keep-alive") or
         name.eqIgnoreCaseAscii("proxy-connection") or name.eqIgnoreCaseAscii("upgrade"):
        return false
      if name.eqIgnoreCaseAscii("transfer-encoding"):
        return false
      if name.eqIgnoreCaseAscii("te") and not value.eqIgnoreCaseAscii("trailers"):
        return false
      if name == "content-length":
        let parsedLength = h2StrictParseContentLength(value)
        if parsedLength < 0:
          return false
        if contentLengthSeen and parsedLength != contentLengthValue:
          return false
        contentLengthSeen = true
        contentLengthValue = parsedLength
  if methodCount != 1:
    return false
  if authorityCount > 1:
    return false
  if isConnect:
    return authorityCount == 1 and pathCount == 0 and schemeCount == 0
  pathCount == 1 and schemeCount == 1

proc h2ValidateTrailerHeaders(headers: seq[(string, string)]): bool {.inline.} =
  for (name, value) in headers:
    if name.len == 0 or name[0] == ':':
      return false
    if not name.h2HeaderNameValid() or not value.h2HeaderValueValid():
      return false
    if name.eqIgnoreCaseAscii("connection") or name.eqIgnoreCaseAscii("keep-alive") or
       name.eqIgnoreCaseAscii("proxy-connection") or name.eqIgnoreCaseAscii("upgrade"):
      return false
    if name.eqIgnoreCaseAscii("transfer-encoding"):
      return false
    if name.eqIgnoreCaseAscii("te") and not value.eqIgnoreCaseAscii("trailers"):
      return false
  true

type H2HeaderDecodeStatus = enum
  h2hdsOk
  h2hdsCompressionError
  h2hdsLimitExceeded

proc h2HeaderBlockLimitFor(server: HttpServer): int {.inline.} =
  if server == nil:
    return DefaultMaxHeaderBytes
  max(0, server.options.maxHeaderBytes)

proc h2HeaderBlockWouldExceed(server: HttpServer, currentLen, addedLen: int): bool {.inline.} =
  if currentLen < 0 or addedLen < 0:
    return true
  let limit = h2HeaderBlockLimitFor(server)
  if limit <= 0:
    return false
  currentLen > limit - addedLen

proc h2HeaderListWithinLimits(server: HttpServer, headers: seq[(string, string)]): bool {.inline.} =
  if server == nil:
    return true
  let maxHeaderCount = max(0, server.options.maxHeaderCount)
  if maxHeaderCount > 0 and headers.len > maxHeaderCount:
    return false
  let maxHeaderLineBytes = max(0, server.options.maxHeaderLineBytes)
  let maxHeaderBytes = max(0, server.options.maxHeaderBytes)
  var totalBytes = 0
  for (name, value) in headers:
    let fieldBytes = name.len + value.len + 2
    if maxHeaderLineBytes > 0 and fieldBytes > maxHeaderLineBytes:
      return false
    if maxHeaderBytes > 0:
      if totalBytes > maxHeaderBytes - fieldBytes:
        return false
      totalBytes += fieldBytes
  true

proc h2DecodeHeadersLimited(
  conn: H2ServerConnection,
  server: HttpServer,
  headerBlock: string,
  decodedHeaders: var seq[(string, string)]
): H2HeaderDecodeStatus {.inline.} =
  if conn == nil:
    return h2hdsCompressionError
  if h2HeaderBlockWouldExceed(server, 0, headerBlock.len):
    return h2hdsLimitExceeded
  try:
    decodedHeaders = hpackMod.hpackDecode(conn.decoder, cast[seq[byte]](headerBlock))
  except CatchableError:
    return h2hdsCompressionError
  if not h2HeaderListWithinLimits(server, decodedHeaders):
    return h2hdsLimitExceeded
  h2hdsOk

proc configureH2ConnectionLimits(conn: H2ServerConnection, server: HttpServer) {.inline.} =
  if conn == nil:
    return
  let maxHeaderBytes =
    if server != nil:
      max(0, server.options.maxHeaderBytes)
    else:
      DefaultMaxHeaderBytes
  conn.localSettings.maxHeaderListSize =
    if maxHeaderBytes > 0: uint32(maxHeaderBytes) else: high(uint32)

proc h2MethodKind(methodName: string): HttpMethod {.inline.} =
  case methodName
  of "GET": hmGet
  of "POST": hmPost
  of "PUT": hmPut
  of "DELETE": hmDelete
  of "PATCH": hmPatch
  of "HEAD": hmHead
  of "OPTIONS": hmOptions
  of "CONNECT": hmConnect
  of "TRACE": hmTrace
  else: hmGet

proc h2DispatchRequest(
  sockData: ptr SocketData,
  s: UsSocketPtr,
  server: HttpServer,
  conn: H2ServerConnection,
  streamId: uint32,
  requestHeaders: seq[(string, string)],
  requestBody: string,
  panicContext: string
) =
  if sockData == nil or server == nil or conn == nil:
    return
  var meth, path: string
  for (name, value) in requestHeaders:
    case name
    of ":method": meth = value
    of ":path": path = value
    else: discard
  if meth.len == 0:
    return
  if path.len == 0 and meth != "CONNECT":
    return

  let req = acquireHttpRequest()
  let queryPos = path.find('?')
  if queryPos >= 0:
    req.pathStr = path[0 ..< queryPos]
    req.queryStr = path[queryPos + 1 ..< path.len]
  else:
    req.pathStr = path
    req.queryStr.setLen(0)
  req.httpMajor = 2
  req.httpMinor = 0
  req.methodKind = h2MethodKind(meth)
  req.remoteIp = sockData.remoteIp
  req.body = requestBody
  if req.headers == nil:
    req.headers = newFastMap[string]()
  for (hn, hv) in requestHeaders:
    if hn.len > 0 and hn[0] != ':':
      req.headers[hn] = hv

  let res = acquireHttpResponse()
  res.socket = s
  res.ssl = server.ssl.toInt
  res.requestRef = req
  res.statusCode = Http200
  res.statusCodeInt = 200
  res.requestSeq = sockData.nextRequestSeq
  res.h2StreamId = streamId
  res.h2Conn = conn
  res.requestMethod = req.methodKind
  res.requestIsHttp11 = false
  res.autoEnd = true
  res.connectionClose = false
  inc sockData.nextRequestSeq

  let requestStartMicros =
    if server.requestEndHandler != nil:
      getCachedEpochMicros()
    else:
      0'i64
  if server.requestStartHandler != nil:
    try:
      server.requestStartHandler(req)
    except CatchableError as err:
      server.emitServerPanic("h2RequestStartHandler", err.msg)
    except Defect as defect:
      server.emitServerPanic("h2RequestStartHandler_defect", defect.msg)

  sockData.setSocketTimeoutPhase(s, tpHandlerExec, res.requestSeq)
  var handlerFailed = false
  if server.rawHandler != nil:
    try:
      server.rawHandler(req, res)
    except CatchableError as err:
      handlerFailed = true
      server.emitServerPanic(panicContext, err.msg)
    except Defect as defect:
      handlerFailed = true
      server.emitServerPanic(panicContext & "_defect", defect.msg)
  elif server.handler != nil:
    try:
      server.handler(req, res)
    except CatchableError as err:
      handlerFailed = true
      server.emitServerPanic(panicContext, err.msg)
    except Defect as defect:
      handlerFailed = true
      server.emitServerPanic(panicContext & "_defect", defect.msg)

  if handlerFailed and not res.bodySent:
    res.statusCode = Http500
    res.statusCodeInt = 500
    h2End(res, "")
  elif not res.bodySent and res.autoEnd:
    h2End(res, "")

  if conn.h2SendBuf.len > conn.h2SendBufPos:
    sockData.setSocketTimeoutPhase(s, tpWriteDrain, res.requestSeq)
  else:
    sockData.setSocketTimeoutPhase(s, tpHeaderRead, sockData.nextRequestSeq)

  if server.requestEndHandler != nil:
    let elapsedMicros = getCachedEpochMicros() - requestStartMicros
    let statusCode = if res.statusCodeInt > 0: res.statusCodeInt else: res.statusCode.statusCodeValue
    try:
      server.requestEndHandler(req, statusCode, max(0'i64, elapsedMicros))
    except CatchableError as err:
      server.emitServerPanic("h2RequestEndHandler", err.msg)
    except Defect as defect:
      server.emitServerPanic("h2RequestEndHandler_defect", defect.msg)

  cleanupRequestSpillFile(req)
  releaseHttpResponse(res)
  recycleHttpRequest(req)
  sockData.memoryBudget.used = 0

proc handleH2Data(sockData: ptr SocketData, s: UsSocketPtr, server: HttpServer) =
  let conn = sockData.h2conn
  if conn == nil or not conn.active:
    return

  template decodeHeadersOrGoaway(headerBlock: string, decodedHeaders: var seq[(string, string)]): bool =
    block:
      let decodeStatus = h2DecodeHeadersLimited(conn, server, headerBlock, decodedHeaders)
      case decodeStatus
      of h2hdsOk:
        true
      of h2hdsCompressionError:
        h2SendGoaway(conn, h2p.ecCompressionError, server.ssl.toInt.cint, s)
        false
      of h2hdsLimitExceeded:
        h2SendGoaway(conn, h2p.ecEnhanceYourCalm, server.ssl.toInt.cint, s)
        false

  if not conn.gotPreface:
    let bufLen = sockData.buffer.len - sockData.bufferStart
    if bufLen < 24:
      return
    let prefaceStart = sockData.bufferStart
    var prefaceValid = true
    let expected = h2p.H2ConnectionPreface
    for i in 0 ..< 24:
      if char(sockData.buffer[prefaceStart + i]) != expected[i]:
        prefaceValid = false
        break
    if not prefaceValid:
      var goawayBuf = ""
      h2p.serializeGoaway(0'u32, uint32(h2p.ecProtocolError), goawayBuf)
      us_socket_cork(server.ssl.toInt.cint, s)
      h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, goawayBuf)
      us_socket_uncork(server.ssl.toInt.cint, s)
      conn.active = false
      conn.sentGoaway = true
      if conn.h2SendBuf.len <= conn.h2SendBufPos:
        us_socket_shutdown(server.ssl.toInt, s)
      return
    conn.gotPreface = true
    sockData.bufferStart += 24
    var settingsBuf = newStringOfCap(h2p.H2FrameHeaderSize + 36)
    h2p.serializeSettings(conn.localSettings, settingsBuf)
    h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, settingsBuf)

  var pos = sockData.bufferStart
  while true:
    if sockData.buffer.len == 0:
      break
    let dataBytes = cast[ptr UncheckedArray[byte]](addr sockData.buffer[0])
    let remaining = sockData.buffer.len - pos
    if remaining < h2p.H2FrameHeaderSize:
      break
    let pendingFrameLen = h2p.readU24BE(dataBytes.toOpenArray(0, sockData.buffer.len - 1), pos)
    if pendingFrameLen > conn.localSettings.maxFrameSize:
      h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
      break
    var framePos = pos
    let frame = h2p.parseH2Frame(dataBytes.toOpenArray(0, sockData.buffer.len - 1), framePos)
    if frame.isNone:
      if framePos > pos:
        if not conn.gotClientSettings:
          h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
          break
        let unknownLen = h2p.readU24BE(dataBytes.toOpenArray(0, sockData.buffer.len - 1), pos)
        if unknownLen > conn.localSettings.maxFrameSize:
          h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
          break
        if conn.continuationStreamId != 0:
          h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
          break
        pos = framePos
        continue
      break
    let f = frame.get()
    pos = framePos

    if not conn.gotClientSettings:
      if f.frameType != h2p.ftSettings or h2p.hasFlag(f, h2p.FlagAck):
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      conn.gotClientSettings = true

    if f.frameType in {h2p.ftData, h2p.ftHeaders, h2p.ftPushPromise, h2p.ftContinuation} and
       f.length > conn.localSettings.maxFrameSize:
      h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
      break

    if f.frameType in {h2p.ftHeaders, h2p.ftPushPromise} and
       h2HeaderBlockWouldExceed(server, 0, int(f.length)):
      h2SendGoaway(conn, h2p.ecEnhanceYourCalm, server.ssl.toInt.cint, s)
      break

    if conn.continuationStreamId != 0 and f.frameType != h2p.ftContinuation:
      h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
      break

    if (conn.sentGoaway or conn.receivedGoaway) and f.frameType in {h2p.ftHeaders, h2p.ftPushPromise}:
      if f.frameType == h2p.ftHeaders:
        var drainBlock: string
        try:
          drainBlock = h2p.extractHeaderBlock(f)
        except CatchableError:
          h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
          break
        if h2p.hasFlag(f, h2p.FlagEndHeaders):
          var ignoredHeaders: seq[(string, string)]
          if not decodeHeadersOrGoaway(drainBlock, ignoredHeaders):
            break
        else:
          conn.continuationStreamId = f.streamId
          conn.continuationFrameCount = 0
          conn.headerBlockBuf = drainBlock
          var drainStream = H2ServerStream(
            id: f.streamId, state: h2p.ssClosed,
            sendWindow: 0, recvWindow: 0,
            endStreamRecv: true, endStreamSent: true,
          )
          conn.streams[f.streamId] = drainStream
      continue

    if h2FrameCountsTowardControlRate(f.frameType):
      if not h2CheckControlFrameRate(conn):
        h2SendGoaway(conn, h2p.ecEnhanceYourCalm, server.ssl.toInt.cint, s)
        break

    case f.frameType
    of h2p.ftSettings:
      if f.streamId != 0:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      if h2p.hasFlag(f, h2p.FlagAck):
        if f.length != 0:
          h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
          break
      else:
        if f.payload.len mod 6 != 0:
          h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
          break
        try:
          let oldWindowSize = int32(conn.remoteSettings.initialWindowSize)
          let oldHeaderTableSize = conn.remoteSettings.headerTableSize
          h2p.applySettings(conn.remoteSettings, f.payload)
          let delta = int32(conn.remoteSettings.initialWindowSize) - oldWindowSize
          if delta != 0:
            var sids: seq[uint32] = @[]
            for sid in conn.streams.keys:
              sids.add(sid)
            var flowOverflow = false
            for sid in sids:
              if sid in conn.streams:
                let newVal = int64(conn.streams[sid].sendWindow) + int64(delta)
                if newVal > 2147483647'i64 or newVal < -2147483648'i64:
                  flowOverflow = true
                  break
            if flowOverflow:
              h2SendGoaway(conn, h2p.ecFlowControlError, server.ssl.toInt.cint, s)
              break
            for sid in sids:
              if sid in conn.streams:
                conn.streams[sid].sendWindow += delta
            if delta > 0:
              for sid in sids:
                h2FlushPendingSendData(conn, sid)
          if conn.remoteSettings.headerTableSize != oldHeaderTableSize:
            hpackMod.updateEncoderMaxSize(conn.encoder, int(conn.remoteSettings.headerTableSize))
        except CatchableError as e:
          if e.msg.contains("INITIAL_WINDOW_SIZE"):
            h2SendGoaway(conn, h2p.ecFlowControlError, server.ssl.toInt.cint, s)
          else:
            h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
          break
        var ackBuf = newStringOfCap(h2p.H2FrameHeaderSize)
        h2p.serializeSettingsAck(ackBuf)
        h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, ackBuf)
    of h2p.ftHeaders:
      let sid = f.streamId
      if sid == 0 or (sid mod 2) == 0:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      if sid < conn.highestClientStreamId:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      if sid <= conn.lastStreamId:
        let existingStream = h2FindStream(conn, sid)
        if existingStream == nil:
          if sid in conn.closedStreams:
            if h2p.hasFlag(f, h2p.FlagEndHeaders):
              var headerBlock: string
              try:
                headerBlock = h2p.extractHeaderBlock(f)
              except CatchableError:
                h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
                break
              var ignoredHeaders: seq[(string, string)]
              if not decodeHeadersOrGoaway(headerBlock, ignoredHeaders):
                break
              h2SendGoaway(conn, h2p.ecStreamClosed, server.ssl.toInt.cint, s)
              break
            else:
              var drainBlock: string
              try:
                drainBlock = h2p.extractHeaderBlock(f)
              except CatchableError:
                h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
                break
              conn.continuationStreamId = sid
              conn.continuationFrameCount = 0
              conn.headerBlockBuf = drainBlock
              var drainStream = H2ServerStream(
                id: sid, state: h2p.ssClosed,
                sendWindow: 0, recvWindow: 0,
                endStreamRecv: true, endStreamSent: true,
              )
              conn.streams[sid] = drainStream
          else:
            if h2p.hasFlag(f, h2p.FlagEndHeaders):
              var headerBlock: string
              try:
                headerBlock = h2p.extractHeaderBlock(f)
              except CatchableError:
                h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
                break
              var ignoredHeaders: seq[(string, string)]
              if not decodeHeadersOrGoaway(headerBlock, ignoredHeaders):
                break
            else:
              var drainBlock: string
              try:
                drainBlock = h2p.extractHeaderBlock(f)
              except CatchableError:
                h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
                break
              conn.continuationStreamId = sid
              conn.continuationFrameCount = 0
              conn.headerBlockBuf = drainBlock
              var drainStream = H2ServerStream(
                id: sid, state: h2p.ssClosed,
                sendWindow: 0, recvWindow: 0,
                endStreamRecv: true, endStreamSent: true,
              )
              conn.streams[sid] = drainStream
            var rstBuf = ""
            h2p.serializeRstStream(sid, uint32(h2p.ecStreamClosed), rstBuf)
            h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
          continue
        if existingStream.endStreamRecv:
          if h2p.hasFlag(f, h2p.FlagEndHeaders):
            var headerBlock: string
            try:
              headerBlock = h2p.extractHeaderBlock(f)
            except CatchableError:
              h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
              break
            var ignoredHeaders: seq[(string, string)]
            if not decodeHeadersOrGoaway(headerBlock, ignoredHeaders):
              break
          else:
            var drainBlock: string
            try:
              drainBlock = h2p.extractHeaderBlock(f)
            except CatchableError:
              h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
              break
            conn.continuationStreamId = sid
            conn.continuationFrameCount = 0
            conn.headerBlockBuf = drainBlock
          var rstBuf = ""
          h2p.serializeRstStream(sid, uint32(h2p.ecStreamClosed), rstBuf)
          h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
          continue
        if existingStream.headersReceived and not h2p.hasFlag(f, h2p.FlagEndStream):
          if h2p.hasFlag(f, h2p.FlagEndHeaders):
            var headerBlock: string
            try:
              headerBlock = h2p.extractHeaderBlock(f)
            except CatchableError:
              h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
              break
            var ignoredHeaders: seq[(string, string)]
            if not decodeHeadersOrGoaway(headerBlock, ignoredHeaders):
              break
          else:
            var drainBlock: string
            try:
              drainBlock = h2p.extractHeaderBlock(f)
            except CatchableError:
              h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
              break
            conn.continuationStreamId = sid
            conn.continuationFrameCount = 0
            conn.headerBlockBuf = drainBlock
          var rstBuf = ""
          h2p.serializeRstStream(sid, uint32(h2p.ecProtocolError), rstBuf)
          h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
          h2RemoveStream(conn, sid)
          continue
        if h2p.hasFlag(f, h2p.FlagEndStream):
          if h2p.hasFlag(f, h2p.FlagEndHeaders):
            if f.payload.len > 0:
              var trailerValid = true
              var headerBlock: string
              try:
                headerBlock = h2p.extractHeaderBlock(f)
              except CatchableError:
                h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
                break
              var trailerHeaders: seq[(string, string)]
              if not decodeHeadersOrGoaway(headerBlock, trailerHeaders):
                break
              trailerValid = h2ValidateTrailerHeaders(trailerHeaders)
              if not trailerValid:
                var rstBuf = ""
                h2p.serializeRstStream(sid, uint32(h2p.ecProtocolError), rstBuf)
                h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
                h2RemoveStream(conn, sid)
                continue
          else:
            var drainBlock: string
            try:
              drainBlock = h2p.extractHeaderBlock(f)
            except CatchableError:
              h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
              break
            conn.continuationStreamId = sid
            conn.continuationFrameCount = 0
            conn.headerBlockBuf = drainBlock
            existingStream.endStreamRecv = true
            continue
          existingStream.endStreamRecv = true
          if existingStream.requestHeaders.len > 0:
            if not h2ValidatePseudoHeaders(existingStream.requestHeaders):
              var rstBuf = ""
              h2p.serializeRstStream(sid, uint32(h2p.ecProtocolError), rstBuf)
              h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
              h2RemoveStream(conn, sid)
              continue
            var contentLengthMismatch = false
            for (hn, hv) in existingStream.requestHeaders:
              if hn == "content-length":
                let declaredLen = h2StrictParseContentLength(hv)
                if declaredLen < 0 or declaredLen != existingStream.requestBody.len:
                  contentLengthMismatch = true
                break
            if contentLengthMismatch:
              var rstBuf = ""
              h2p.serializeRstStream(sid, uint32(h2p.ecProtocolError), rstBuf)
              h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
              h2RemoveStream(conn, sid)
              continue
            h2DispatchRequest(sockData, s, server, conn, sid,
              existingStream.requestHeaders, existingStream.requestBody, "h2TrailerHandler")
          continue
      if sid >= 2147483645'u32:
        h2SendGoaway(conn, h2p.ecNoError, server.ssl.toInt.cint, s)
        break
      if uint32(conn.streams.len) >= conn.localSettings.maxConcurrentStreams:
        var drainBlock: string
        try:
          drainBlock = h2p.extractHeaderBlock(f)
        except CatchableError:
          h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
          break
        if h2p.hasFlag(f, h2p.FlagEndHeaders):
          var ignoredHeaders: seq[(string, string)]
          if not decodeHeadersOrGoaway(drainBlock, ignoredHeaders):
            break
        else:
          conn.continuationStreamId = sid
          conn.continuationFrameCount = 0
          conn.headerBlockBuf = drainBlock
          var drainStream = H2ServerStream(
            id: sid, state: h2p.ssClosed,
            sendWindow: 0, recvWindow: 0,
            endStreamRecv: true, endStreamSent: true,
          )
          conn.streams[sid] = drainStream
        var rstBuf = ""
        h2p.serializeRstStream(sid, uint32(h2p.ecRefusedStream), rstBuf)
        h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
        conn.lastStreamId = sid
        if sid > conn.highestClientStreamId:
          conn.highestClientStreamId = sid
        continue
      if h2p.hasFlag(f, h2p.FlagPriority) and f.payload.len >= 5:
        let offset = if h2p.hasFlag(f, h2p.FlagPadded) and f.payload.len > 0: 1 else: 0
        if offset + 4 < f.payload.len:
          let depBytes = cast[ptr UncheckedArray[byte]](unsafeAddr f.payload[offset])
          let depStreamId = (uint32(depBytes[0] and 0x7F) shl 24) or (uint32(depBytes[1]) shl 16) or (uint32(depBytes[2]) shl 8) or uint32(depBytes[3])
          if depStreamId == sid:
            var drainBlock: string
            try:
              drainBlock = h2p.extractHeaderBlock(f)
            except CatchableError:
              h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
              break
            if h2p.hasFlag(f, h2p.FlagEndHeaders):
              var ignoredHeaders: seq[(string, string)]
              if not decodeHeadersOrGoaway(drainBlock, ignoredHeaders):
                break
            else:
              conn.continuationStreamId = sid
              conn.continuationFrameCount = 0
              conn.headerBlockBuf = drainBlock
              var drainStream = H2ServerStream(
                id: sid, state: h2p.ssClosed,
                sendWindow: 0, recvWindow: 0,
                endStreamRecv: true, endStreamSent: true,
              )
              conn.streams[sid] = drainStream
            var rstBuf = ""
            h2p.serializeRstStream(sid, uint32(h2p.ecProtocolError), rstBuf)
            h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
            conn.lastStreamId = sid
            if sid > conn.highestClientStreamId:
              conn.highestClientStreamId = sid
            continue
      var stream = H2ServerStream(
        id: sid, state: h2p.ssOpen,
        sendWindow: int32(conn.remoteSettings.initialWindowSize),
        recvWindow: h2p.DefaultWindowSize,
        headersReceived: false,
      )
      var headerBlock: string
      try:
        headerBlock = h2p.extractHeaderBlock(f)
      except CatchableError:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      if h2p.hasFlag(f, h2p.FlagEndHeaders):
        if not decodeHeadersOrGoaway(headerBlock, stream.requestHeaders):
          break
        stream.endStreamRecv = h2p.hasFlag(f, h2p.FlagEndStream)
        stream.headersReceived = true
        conn.streams[sid] = stream
        if sid > conn.lastStreamId:
          conn.lastStreamId = sid
        if sid > conn.highestClientStreamId:
          conn.highestClientStreamId = sid
        if stream.endStreamRecv:
          if not h2ValidatePseudoHeaders(stream.requestHeaders):
            var rstBuf = ""
            h2p.serializeRstStream(sid, uint32(h2p.ecProtocolError), rstBuf)
            h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
            h2RemoveStream(conn, sid)
            continue
          var contentLengthMismatch = false
          for (hn, hv) in stream.requestHeaders:
            if hn == "content-length":
              let declaredLen = h2StrictParseContentLength(hv)
              if declaredLen < 0 or declaredLen != stream.requestBody.len:
                contentLengthMismatch = true
              break
          if contentLengthMismatch:
            var rstBuf = ""
            h2p.serializeRstStream(sid, uint32(h2p.ecProtocolError), rstBuf)
            h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
            h2RemoveStream(conn, sid)
            continue
          h2DispatchRequest(sockData, s, server, conn, sid,
            stream.requestHeaders, stream.requestBody, "h2Handler")
      else:
        stream.endStreamRecv = h2p.hasFlag(f, h2p.FlagEndStream)
        conn.continuationStreamId = sid
        conn.continuationFrameCount = 0
        conn.headerBlockBuf = headerBlock
        conn.streams[sid] = stream
        if sid > conn.lastStreamId:
          conn.lastStreamId = sid
        if sid > conn.highestClientStreamId:
          conn.highestClientStreamId = sid
    of h2p.ftContinuation:
      if conn.continuationStreamId == 0:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      if conn.continuationStreamId != f.streamId:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      inc conn.continuationFrameCount
      if conn.continuationFrameCount > H2MaxContinuationFrames:
        conn.continuationStreamId = 0
        conn.headerBlockBuf = ""
        conn.continuationFrameCount = 0
        h2SendGoaway(conn, h2p.ecEnhanceYourCalm, server.ssl.toInt.cint, s)
        break
      if true:
        if h2HeaderBlockWouldExceed(server, conn.headerBlockBuf.len, f.payload.len):
          conn.continuationStreamId = 0
          conn.headerBlockBuf = ""
          h2SendGoaway(conn, h2p.ecEnhanceYourCalm, server.ssl.toInt.cint, s)
          break
        conn.headerBlockBuf.add f.payload
        if h2p.hasFlag(f, h2p.FlagEndHeaders):
          let streamPtr = h2FindStream(conn, f.streamId)
          var decodedHeaders: seq[(string, string)]
          if not decodeHeadersOrGoaway(conn.headerBlockBuf, decodedHeaders):
            conn.continuationStreamId = 0
            conn.headerBlockBuf = ""
            break
          if streamPtr != nil and streamPtr.state == h2p.ssClosed:
            h2RemoveStream(conn, f.streamId)
          elif streamPtr != nil:
            let continuationIsTrailers = streamPtr.headersReceived and streamPtr.endStreamRecv
            if continuationIsTrailers:
              if not h2ValidateTrailerHeaders(decodedHeaders):
                var rstBuf = ""
                h2p.serializeRstStream(f.streamId, uint32(h2p.ecProtocolError), rstBuf)
                h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
                conn.continuationStreamId = 0
                conn.headerBlockBuf = ""
                conn.continuationFrameCount = 0
                h2RemoveStream(conn, f.streamId)
                continue
              h2DispatchRequest(sockData, s, server, conn, f.streamId,
                streamPtr.requestHeaders, streamPtr.requestBody, "h2TrailerContinuationHandler")
              conn.continuationStreamId = 0
              conn.headerBlockBuf = ""
              conn.continuationFrameCount = 0
              continue
            streamPtr.requestHeaders = decodedHeaders
            streamPtr.headersReceived = true
            if streamPtr.endStreamRecv:
              if not h2ValidatePseudoHeaders(streamPtr.requestHeaders):
                var rstBuf = ""
                h2p.serializeRstStream(f.streamId, uint32(h2p.ecProtocolError), rstBuf)
                h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
                conn.continuationStreamId = 0
                conn.headerBlockBuf = ""
                h2RemoveStream(conn, f.streamId)
                continue
              var contentLengthMismatch = false
              for (hn, hv) in streamPtr.requestHeaders:
                if hn == "content-length":
                  let declaredLen = h2StrictParseContentLength(hv)
                  if declaredLen < 0 or declaredLen != streamPtr.requestBody.len:
                    contentLengthMismatch = true
                  break
              if contentLengthMismatch:
                var rstBuf = ""
                h2p.serializeRstStream(f.streamId, uint32(h2p.ecProtocolError), rstBuf)
                h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
                conn.continuationStreamId = 0
                conn.headerBlockBuf = ""
                h2RemoveStream(conn, f.streamId)
                continue
              h2DispatchRequest(sockData, s, server, conn, f.streamId,
                streamPtr.requestHeaders, streamPtr.requestBody, "h2ContinuationHandler")
          conn.continuationStreamId = 0
          conn.headerBlockBuf = ""
    of h2p.ftData:
      if f.streamId == 0:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      if f.streamId > conn.lastStreamId or (f.streamId mod 2) == 0:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      let dataLen = int32(f.length)
      let streamPtr = h2FindStream(conn, f.streamId)
      if streamPtr == nil:
        if dataLen > conn.localWindow:
          h2SendGoaway(conn, h2p.ecFlowControlError, server.ssl.toInt.cint, s)
          break
        conn.localWindow -= dataLen
        if conn.localWindow < h2p.DefaultWindowSize div 2:
          let wuInc = h2p.DefaultWindowSize - conn.localWindow
          var wuBuf = ""
          h2p.serializeWindowUpdate(0, uint32(wuInc), wuBuf)
          h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, wuBuf)
          conn.localWindow += wuInc
        var rstBuf = ""
        h2p.serializeRstStream(f.streamId, uint32(h2p.ecStreamClosed), rstBuf)
        h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
        continue
      if streamPtr.endStreamRecv:
        if dataLen > conn.localWindow:
          h2SendGoaway(conn, h2p.ecFlowControlError, server.ssl.toInt.cint, s)
          break
        conn.localWindow -= dataLen
        if conn.localWindow < h2p.DefaultWindowSize div 2:
          let wuInc = h2p.DefaultWindowSize - conn.localWindow
          var wuBuf = ""
          h2p.serializeWindowUpdate(0, uint32(wuInc), wuBuf)
          h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, wuBuf)
          conn.localWindow += wuInc
        var rstBuf = ""
        h2p.serializeRstStream(f.streamId, uint32(h2p.ecStreamClosed), rstBuf)
        h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
        h2RemoveStream(conn, f.streamId)
        continue
      if dataLen > conn.localWindow or dataLen > streamPtr.recvWindow:
        h2SendGoaway(conn, h2p.ecFlowControlError, server.ssl.toInt.cint, s)
        break
      let maxBody = if server.options.maxBodySize > 0: server.options.maxBodySize else: DefaultMaxBodySize
      try:
        let stripped = h2p.stripPadding(f)
        if streamPtr.requestBody.len + stripped.len > maxBody:
          var rstBuf = ""
          h2p.serializeRstStream(f.streamId, uint32(h2p.ecCancel), rstBuf)
          h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
          h2RemoveStream(conn, f.streamId)
          conn.localWindow -= dataLen
          if conn.localWindow < h2p.DefaultWindowSize div 2:
            let inc = h2p.DefaultWindowSize - conn.localWindow
            var wuBuf = ""
            h2p.serializeWindowUpdate(0, uint32(inc), wuBuf)
            h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, wuBuf)
            conn.localWindow += inc
          continue
        streamPtr.requestBody.add stripped
      except CatchableError:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      conn.localWindow -= dataLen
      streamPtr.recvWindow -= dataLen
      if conn.localWindow < h2p.DefaultWindowSize div 2:
        let inc = h2p.DefaultWindowSize - conn.localWindow
        var wuBuf = ""
        h2p.serializeWindowUpdate(0, uint32(inc), wuBuf)
        h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, wuBuf)
        conn.localWindow += inc
      if streamPtr.recvWindow < h2p.DefaultWindowSize div 2:
        let inc = h2p.DefaultWindowSize - streamPtr.recvWindow
        var wuBuf = ""
        h2p.serializeWindowUpdate(f.streamId, uint32(inc), wuBuf)
        h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, wuBuf)
        streamPtr.recvWindow += inc
      if h2p.hasFlag(f, h2p.FlagEndStream):
          streamPtr.endStreamRecv = true
          if streamPtr.requestHeaders.len > 0:
            if not h2ValidatePseudoHeaders(streamPtr.requestHeaders):
              var rstBuf = ""
              h2p.serializeRstStream(f.streamId, uint32(h2p.ecProtocolError), rstBuf)
              h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
              h2RemoveStream(conn, f.streamId)
              continue
            var contentLengthMismatch = false
            for (hn, hv) in streamPtr.requestHeaders:
              if hn == "content-length":
                let declaredLen = h2StrictParseContentLength(hv)
                if declaredLen < 0 or declaredLen != streamPtr.requestBody.len:
                  contentLengthMismatch = true
                break
            if contentLengthMismatch:
              var rstBuf = ""
              h2p.serializeRstStream(f.streamId, uint32(h2p.ecProtocolError), rstBuf)
              h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
              h2RemoveStream(conn, f.streamId)
              continue
            h2DispatchRequest(sockData, s, server, conn, f.streamId,
              streamPtr.requestHeaders, streamPtr.requestBody, "h2DataEndStreamHandler")
    of h2p.ftPing:
      if f.streamId != 0:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      if f.payload.len != 8:
        h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
        break
      if not h2p.hasFlag(f, h2p.FlagAck):
        var pingData: array[8, byte]
        copyMem(addr pingData[0], unsafeAddr f.payload[0], 8)
        var pongBuf = newStringOfCap(h2p.H2FrameHeaderSize + 8)
        h2p.serializePing(pingData, true, pongBuf)
        h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, pongBuf)
    of h2p.ftGoaway:
      if f.streamId != 0:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      if f.length < 8:
        h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
        break
      conn.receivedGoaway = true
      if not conn.sentGoaway:
        h2SendGoaway(conn, h2p.ecNoError, server.ssl.toInt.cint, s)
    of h2p.ftWindowUpdate:
      if f.payload.len != 4:
        h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
        break
      try:
        let increment = h2p.parseWindowUpdate(f.payload)
        if f.streamId == 0:
          if int64(conn.remoteWindow) + int64(increment) > 2147483647'i64:
            h2SendGoaway(conn, h2p.ecFlowControlError, server.ssl.toInt.cint, s)
            break
          conn.remoteWindow += int32(increment)
          var sids: seq[uint32] = @[]
          for sid in conn.streams.keys:
            sids.add(sid)
          for sid in sids:
            h2FlushPendingSendData(conn, sid)
        else:
          let isClientStream = (f.streamId mod 2) != 0
          let isServerPushStream = (f.streamId mod 2) == 0
          if isClientStream and f.streamId > conn.lastStreamId:
            h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
            break
          if isServerPushStream and f.streamId >= conn.nextPushStreamId:
            h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
            break
          let streamPtr = h2FindStream(conn, f.streamId)
          if streamPtr != nil:
            if int64(streamPtr.sendWindow) + int64(increment) > 2147483647'i64:
              var rstBuf = ""
              h2p.serializeRstStream(f.streamId, uint32(h2p.ecFlowControlError), rstBuf)
              h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
              h2RemoveStream(conn, f.streamId)
            else:
              streamPtr.sendWindow += int32(increment)
              h2FlushPendingSendData(conn, f.streamId)
      except CatchableError:
        if f.streamId == 0:
          h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
          break
        else:
          var rstBuf = ""
          h2p.serializeRstStream(f.streamId, uint32(h2p.ecProtocolError), rstBuf)
          h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
          h2RemoveStream(conn, f.streamId)
    of h2p.ftRstStream:
      if f.payload.len != 4:
        h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
        break
      if f.streamId == 0:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      let rstIsClientStream = (f.streamId mod 2) != 0
      let rstIsPushStream = (f.streamId mod 2) == 0
      if rstIsClientStream and f.streamId > conn.lastStreamId:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      if rstIsPushStream and f.streamId >= conn.nextPushStreamId:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      conn.rstStreams[f.streamId] = true
      if conn.rstStreams.len > 256:
        var oldest: uint32 = 0
        for k in conn.rstStreams.keys:
          oldest = k
          break
        conn.rstStreams.del(oldest)
      h2RemoveStream(conn, f.streamId)
    of h2p.ftPushPromise:
      h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
      break
    of h2p.ftPriority:
      if f.payload.len != 5:
        if f.streamId == 0:
          h2SendGoaway(conn, h2p.ecFrameSizeError, server.ssl.toInt.cint, s)
          break
        else:
          var rstBuf = ""
          h2p.serializeRstStream(f.streamId, uint32(h2p.ecFrameSizeError), rstBuf)
          h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
      elif f.streamId == 0:
        h2SendGoaway(conn, h2p.ecProtocolError, server.ssl.toInt.cint, s)
        break
      else:
        let depData = cast[ptr UncheckedArray[byte]](unsafeAddr f.payload[0])
        let depStreamId = (uint32(depData[0] and 0x7F) shl 24) or (uint32(depData[1]) shl 16) or (uint32(depData[2]) shl 8) or uint32(depData[3])
        if depStreamId == f.streamId:
          var rstBuf = ""
          h2p.serializeRstStream(f.streamId, uint32(h2p.ecProtocolError), rstBuf)
          h2WriteFrameBuf(conn, server.ssl.toInt.cint, s, rstBuf)
  sockData.bufferStart = pos

proc hasH2PriorKnowledgePrefix(buffer: openArray[byte], start: int): bool {.inline.} =
  if start < 0 or start + 4 > buffer.len:
    return false
  buffer[start] == byte(ord('P')) and
    buffer[start + 1] == byte(ord('R')) and
    buffer[start + 2] == byte(ord('I')) and
    buffer[start + 3] == byte(ord(' '))

proc onSocketDataImpl(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr =
  let server = resolveServerFromSocket(s)
  if server == nil:
    return s
  when defined(macosx):
    let ranMaintenance = server.beginMacosFallbackMaintenance()
    defer:
      server.endMacosFallbackMaintenance(ranMaintenance)

  let ssl = server.ssl.toInt
  let sockData = socketDataFor(ssl, s)
  if sockData == nil:
    return s

  if server.overloadControlEnabled:
    let overloadReason = overloadRejectReasonFor(sockData)
    if overloadReason != orrNone:
      rejectOverloadedSocket(sockData, s, overloadReason)
      return s

  let maxBodySize = if server.options.maxBodySize > 0:
    server.options.maxBodySize
  else:
    DefaultMaxBodySize

  if length < 0:
    discard closeSocketTracked(server, ssl, s, "invalid_negative_read_length")
    return s
  let chunkLen = int(length)

  let activeLen = sockData.buffer.len - sockData.bufferStart
  if chunkLen > maxBodySize or activeLen > maxBodySize - chunkLen:
    if sockData.hasFlag(SDF_IS_WEBSOCKET):
      sendWsCloseAndTerminate(sockData, s, WsClose1009)
      return s
    let response = buildProtocolErrorResponse(413, "", true)
    let wrote = writeFallbackPayloadAndMaybeClose(
      server,
      ssl,
      s,
      response,
      "payload_too_large_413_short_write"
    )
    if wrote >= response.len:
      discard closeSocketTracked(server, ssl, s, "payload_too_large_413_close")
    return s

  if not sockData.hasFlag(SDF_IS_WEBSOCKET) and sockData.memoryBudget.limit > 0:
    if not sockData.memoryBudget.chargeMemory(chunkLen):
      let response = buildProtocolErrorResponse(413, "", true)
      let wrote = writeFallbackPayloadAndMaybeClose(
        server,
        ssl,
        s,
        response,
        "memory_budget_exceeded_413_short_write"
      )
      if wrote >= response.len:
        discard closeSocketTracked(server, ssl, s, "memory_budget_exceeded_413_close")
      return s

  let compactThreshold = if sockData.hasFlag(SDF_IS_WEBSOCKET): high(int) else: InputCompactThreshold
  if sockData.bufferStart > 0 and sockData.bufferStart >= sockData.buffer.len:
    sockData.buffer.setLen(0)
    sockData.bufferStart = 0
  elif sockData.bufferStart >= compactThreshold and
       (sockData.bufferStart * 2 >= sockData.buffer.len):
    sockData.compactSocketBuffer()

  let oldLen = sockData.buffer.len
  if chunkLen > high(int) - oldLen:
    discard closeSocketTracked(server, ssl, s, "read_length_overflow")
    return s
  let requiredLen = oldLen + chunkLen
  updateReadBufferTargetOnAppend(sockData, requiredLen)
  sockData.buffer.setLen(requiredLen)
  if chunkLen > 0:
    copyMem(addr sockData.buffer[oldLen], data, chunkLen)

  if sockData.hasFlag(SDF_IS_WEBSOCKET):
    us_socket_cork(ssl.cint, s)
    handleWebSocketData(sockData, s)
    if sockData.wsIdleTimeoutFor() != 0:
      sockData.refreshWsIdleTimeout(s, onSendPath = false)
    if not sockData.wsQueueIsEmpty():
      flushWsQueuedFrames(sockData, s)
    us_socket_uncork(ssl.cint, s)
    return s

  if sockData.hasFlag(SDF_IS_HTTP2):
    handleH2Data(sockData, s, server)
    compactH2ReadBuffer(sockData)
    return s

  block h2Detection:
    let bufAvail = sockData.buffer.len - sockData.bufferStart
    if bufAvail >= 4 and sockData.nextRequestSeq == 0:
      if hasH2PriorKnowledgePrefix(sockData.buffer, sockData.bufferStart):
        sockData.setFlag(SDF_IS_HTTP2)
        sockData.h2conn = initH2ServerConnection()
        configureH2ConnectionLimits(sockData.h2conn, server)
        trackH2Connection(server, sockData.h2conn, s, ssl.cint)
        handleH2Data(sockData, s, server)
        compactH2ReadBuffer(sockData)
        return s

  if sockData.hasFlag(SDF_READ_PAUSED):
    return s

  let nowMs = getCachedEpochMs()
  sockData.setSocketTimeoutPhase(s, tpHeaderRead, sockData.nextRequestSeq, nowMs)

  var consumed = 0
  var requestsProcessed = 0
  var consumedBytesThisBatch = 0
  let parseBudgetRequests = max(1, if server.options.parseBudgetRequestsPerRead > 0:
    server.options.parseBudgetRequestsPerRead
  else:
    DefaultParseBudgetRequestsPerRead)
  let parseBudgetBytes = max(1, if server.options.parseBudgetBytesPerRead > 0:
    server.options.parseBudgetBytesPerRead
  else:
    DefaultParseBudgetBytesPerRead)
  let wantsRequestTiming = server.requestEndHandler != nil
  let hasRequestStartHandler = server.requestStartHandler != nil
  var scheduleResume = false
  inc sockData.writeBatchDepth
  try:
    while not sockData.hasFlag(SDF_READ_PAUSED):
      if server.fairnessEnabled and server.dispatchLoopBudgetExhausted():
        scheduleResume = true
        break
      var totalRequestSize = 0
      var parseError = false
      var parseStatusCode = 400
      var parserSpillThreshold = server.options.bodySpillThreshold
      when compileOption("threads"):
        if spillOffloadEnabled(server):
          # Keep parser path non-blocking; spill writes run in background.
          parserSpillThreshold = 0
      let reqOpt = parseHttpRequest(
        sockData.buffer,
        sockData.bufferStart + consumed,
        totalRequestSize,
        server.options.minimalHeaderParsing,
        parserSpillThreshold,
        server.options.bodySpillDir,
        parseError,
        parseStatusCode,
        max(0, server.options.maxHeaderBytes),
        max(0, server.options.maxHeaderCount),
        max(0, server.options.maxHeaderLineBytes),
        max(0, server.options.maxRequestUriBytes),
        if server.options.maxBodySize > 0: server.options.maxBodySize else: DefaultMaxBodySize,
        server.options.expectContinueMode
      )
      if reqOpt.isNone:
        if not parseError:
          let headerLimit = max(0, server.options.maxHeaderBytes)
          let pendingStart = sockData.bufferStart + consumed
          if incompleteHeaderExceedsLimit(sockData.buffer, pendingStart, headerLimit):
            parseError = true
            parseStatusCode = 431
            totalRequestSize = sockData.buffer.len - pendingStart
        if parseError:
          inc server.metricsParserErrors
          server.emitServerError("HTTP parse error: status " & $parseStatusCode)
          var finalStatus = parseStatusCode
          var responseBody = ""
          var closeConnection = true
          if server.protocolErrorHandler != nil:
            try:
              let transformed = server.protocolErrorHandler(parseStatusCode, sockData.remoteIp)
              if transformed.statusCode > 0:
                finalStatus = transformed.statusCode
              responseBody = transformed.body
              closeConnection = transformed.closeConnection
            except CatchableError as err:
              server.emitServerPanic("protocolErrorHandler", err.msg)
          var badRes: HttpResponse
          new(badRes)
          badRes.socket = s
          badRes.ssl = server.ssl.toInt
          badRes.requestSeq = sockData.nextRequestSeq
          let useDefault = responseBody.len == 0 and closeConnection and finalStatus in [400, 414, 417, 431, 501, 505]
          if useDefault:
            badRes.sendPreparedResponse(parseErrorResponseFor(finalStatus), "", true)
          else:
            badRes.sendPreparedResponse(
              buildProtocolErrorResponse(finalStatus, responseBody, closeConnection),
              "",
              closeConnection
            )
          if closeConnection:
            sockData.setFlag(SDF_PENDING_CLOSE)
          else:
            let unreadAtParsePos = sockData.buffer.len - (sockData.bufferStart + consumed)
            let quarantineBytes = parseErrorQuarantineBytes(totalRequestSize, unreadAtParsePos)
            if quarantineBytes > 0:
              consumed += quarantineBytes
            if sockData.buffer.len > sockData.bufferStart + consumed:
              scheduleResume = true
            sockData.setSocketTimeoutPhase(s, tpHeaderRead, sockData.nextRequestSeq, nowMs)
        break  # Need more data

      let req = reqOpt.get()
      defer:
        cleanupRequestSpillFile(req)
        recycleHttpRequest(req)
      req.remoteIp = sockData.remoteIp

      if sockData.hasFlag(SDF_KEEP_ALIVE_HEADERS_CACHED) and hkHost in req.knownHeaderPresent:
        let hostSlice = req.knownHeaders[hkHost]
        let hostLen = int(hostSlice.endPos - hostSlice.startPos)
        if hostLen == sockData.cachedHostValue.len and hostLen > 0 and req.bufferPtr != nil:
          if equalMem(
            cast[pointer](cast[uint](req.bufferPtr) + uint(hostSlice.startPos)),
            unsafeAddr sockData.cachedHostValue[0], hostLen):
            req.cachedHostStr = sockData.cachedHostValue
      elif not sockData.hasFlag(SDF_KEEP_ALIVE_HEADERS_CACHED):
        sockData.setFlag(SDF_KEEP_ALIVE_HEADERS_CACHED)
        if hkHost in req.knownHeaderPresent:
          let hostVal = materializeSlice(req.bufferPtr, req.knownHeaders[hkHost])
          sockData.cachedHostValue = hostVal
          req.cachedHostStr = hostVal

      when compileOption("threads"):
        if not req.bodyInFile and req.body.len > 0:
          let spillThreshold = server.options.bodySpillThreshold
          if spillThreshold > 0 and req.body.len >= spillThreshold:
            if enqueueSpillOffload(server, req.body):
              inc server.metricsSpillOffloadEnqueued
            else:
              inc server.metricsSpillOffloadDropped
      let requestStartMicros =
        if wantsRequestTiming:
          getCachedEpochMicros()
        else:
          0'i64
      if hasRequestStartHandler:
        try:
          server.requestStartHandler(req)
        except CatchableError as err:
          server.emitServerPanic("requestStartHandler", err.msg)

      let res = acquireHttpResponse()
      res.socket = s
      res.ssl = ssl
      res.requestRef = req
      res.statusCode = Http200
      res.statusCodeInt = 200
      res.requestMethod = req.methodKind
      res.requestIsHttp11 = req.httpMajor == 1 and req.httpMinor == 1
      res.headersInited = false
      res.bodySent = false
      res.headersSent = false
      res.requestSeq = sockData.nextRequestSeq
      res.autoEnd = true
      res.connectionClose = req.connectionClose
      res.chunkedStarted = false
      res.chunkedFinished = false
      inc sockData.nextRequestSeq
      sockData.setSocketTimeoutPhase(s, tpHandlerExec, res.requestSeq, nowMs)

      # Check for WebSocket upgrade (skip header work when WS is not enabled)
      if (server.wsHandler != nil or server.wsRawHandler != nil) and req.isWebSocketUpgrade:
        let wsValidation = validateWebSocketUpgrade(req)
        if not wsValidation.ok:
          let reject = buildSimpleResponse(wsValidation.statusCode, wsValidation.reason, wsValidation.extraHeaders)
          res.sendPreparedResponse(reject, "", true)
          break
        if server.wsUpgradeValidateHandler != nil:
          var allowed = false
          try:
            allowed = server.wsUpgradeValidateHandler(req)
          except CatchableError as err:
            server.emitServerPanic("wsUpgradeValidateHandler", err.msg)
            allowed = false
          if not allowed:
            let reject = buildSimpleResponse(403, "Forbidden")
            res.sendPreparedResponse(reject, "", true)
            break
        let ws = upgradeToWebSocket(req, res)
        if ws != nil:
          if sockData.writeBatchDepth > 0:
            dec sockData.writeBatchDepth
          flushSendBuffer(sockData, ssl, s)
          flushPendingResponses(sockData, s)
          flushSendBuffer(sockData, ssl, s)
          sockData.setFlag(SDF_IS_WEBSOCKET)
          sockData.ws = ws
          ws.server = server
          sockData.optimizeForWebSocket(s)
          sockData.setSocketTimeoutPhase(s, tpWebSocketIdle, res.requestSeq, nowMs)
          let requestEnd = sockData.bufferStart + consumed + totalRequestSize
          if requestEnd < sockData.buffer.len:
            let remaining = sockData.buffer.len - requestEnd
            moveMem(addr sockData.buffer[0], unsafeAddr sockData.buffer[requestEnd], remaining)
            sockData.buffer.setLen(remaining)
          else:
            sockData.buffer.setLen(0)
          sockData.bufferStart = 0
          let key = ws.wsKey()
          if key.len == 0:
            server.websockets.add(ws)
          elif server.websocketSet != nil and server.websocketSet.contains(key):
            discard
          else:
            let idx = server.websockets.len
            server.websockets.add(ws)
            if server.websocketSet != nil:
              discard server.websocketSet.incl(key)
            if server.websocketIndex != nil:
              discard server.websocketIndex.put(key, idx.int64)
          if server.wsOpenHandler != nil:
            try:
              server.wsOpenHandler(ws)
            except CatchableError as err:
              server.emitServerPanic("wsOpenHandler", err.msg)
            except Defect as defect:
              server.emitServerPanic("wsOpenHandler_defect", defect.msg)
          flushSendBuffer(sockData, ssl, s)
          flushPendingResponses(sockData, s)
          flushSendBuffer(sockData, ssl, s)
          if sockData.buffer.len > 0:
            handleWebSocketData(sockData, s)
          return s

      if req.hasHeaderFlag(HfUpgrade) and req.headers != nil:
        let upgradeVal = req.upgradeHeader
        if upgradeVal.len == 3 and
           (upgradeVal[0] == 'h' or upgradeVal[0] == 'H') and
           upgradeVal[1] == '2' and
           upgradeVal[2] == 'c':
          inc server.metricsParserErrors
          discard writeSocketChecked(ssl, s, NotImplementedResponse.cstring, NotImplementedResponse.len)
          sockData.setFlag(SDF_PENDING_CLOSE)
          return s

      if req.hasHeaderFlag(HfExpect) and server.options.expectContinueMode == ecmAllow100Continue:
        let continueResp = "HTTP/1.1 100 Continue\r\n\r\n"
        discard writeSocketChecked(ssl, s, continueResp.cstring, continueResp.len)

      if server.rawHandler != nil:
        try:
          server.rawHandler(req, res)
        except CatchableError as err:
          server.emitServerPanic("rawHandler", err.msg)
        except Defect as defect:
          server.emitServerPanic("rawHandler_defect", defect.msg)
          if not res.bodySent:
            res.statusCode = Http500
            res.statusCodeInt = 500
            res.sendPreparedResponse(
              buildProtocolErrorResponse(500, "", true),
              "",
              true
            )
          break
      elif server.handler != nil:
        try:
          server.handler(req, res)
        except CatchableError as err:
          server.emitServerPanic("httpHandler", err.msg)
          if not res.bodySent:
            res.statusCode = Http500
            res.statusCodeInt = 500
            res.sendPreparedResponse(
              buildProtocolErrorResponse(500, "", true),
              "",
              true
            )
          break
        except Defect as defect:
          server.emitServerPanic("httpHandler_defect", defect.msg)
          if not res.bodySent:
            res.statusCode = Http500
            res.statusCodeInt = 500
            res.sendPreparedResponse(
              buildProtocolErrorResponse(500, "", true),
              "",
              true
            )
          break

      # If response not ended, end it now (when autoEnd is enabled).
      if not res.bodySent and res.autoEnd:
        res.`end`()

      if sockData.pendingIsEmpty():
        sockData.setSocketTimeoutPhase(s, tpHeaderRead, sockData.nextRequestSeq, nowMs)
      else:
        sockData.setSocketTimeoutPhase(s, tpWriteDrain, res.requestSeq, nowMs)

      if wantsRequestTiming:
        let elapsedMicros = getCachedEpochMicros() - requestStartMicros
        let statusCode = if res.statusCodeInt > 0: res.statusCodeInt else: res.statusCode.statusCodeValue
        try:
          server.requestEndHandler(req, statusCode, max(0'i64, elapsedMicros))
        except CatchableError as err:
          server.emitServerPanic("requestEndHandler", err.msg)
        except Defect as defect:
          server.emitServerPanic("requestEndHandler_defect", defect.msg)

      releaseHttpResponse(res)

      consumed += totalRequestSize
      inc requestsProcessed
      consumedBytesThisBatch += totalRequestSize
      server.consumeLoopDispatchBudget(1, totalRequestSize)

      sockData.memoryBudget.used = 0

      if req.connectionClose:
        break
      if requestsProcessed >= parseBudgetRequests or
         consumedBytesThisBatch >= parseBudgetBytes or
         (server.fairnessEnabled and server.dispatchLoopBudgetExhausted()):
        scheduleResume = true
        break
  finally:
    if sockData.writeBatchDepth > 0:
      dec sockData.writeBatchDepth

  if consumed > 0:
    sockData.bufferStart += consumed
    if sockData.bufferStart >= sockData.buffer.len:
      sockData.buffer.setLen(0)
      sockData.bufferStart = 0
    elif sockData.bufferStart >= InputCompactThreshold and
         (sockData.bufferStart * 2 >= sockData.buffer.len):
      sockData.compactSocketBuffer()

  if scheduleResume and not sockData.hasFlag(SDF_READ_PAUSED) and sockData.buffer.len > sockData.bufferStart:
    sockData.scheduleSocketDataResume(s)

  if server.loopWriteBatchDepth > 0:
    registerPendingFlush(sockData, s)
  else:
    flushSendBuffer(sockData, ssl, s)
    flushPendingResponses(sockData, s)
    flushSendBuffer(sockData, ssl, s)
  if sockData.pendingIsEmpty():
    sockData.setSocketTimeoutPhase(s, tpHeaderRead, sockData.nextRequestSeq, nowMs)
  else:
    sockData.setSocketTimeoutPhase(s, tpWriteDrain, sockData.nextWriteSeq, nowMs)
  closeSocketIfPending(sockData, s)

  result = s

proc onSocketData(s: UsSocketPtr, data: cstring, length: cint): UsSocketPtr {.cdecl.} =
  try:
    discard onSocketDataImpl(s, data, length)
  except Defect as defect:
    reportEscapedDefect("onSocketData", defect)
  except CatchableError as err:
    reportEscapedError("onSocketData", err)
  s

proc onSocketWritableImpl(s: UsSocketPtr): UsSocketPtr =
  let server = resolveServerFromSocket(s)
  if server != nil:
    when defined(macosx):
      # GCD backend does not emit loop pre/post callbacks.
      # Run maintenance at bounded cadence and avoid nested re-entry.
      let ranMaintenance = server.beginMacosFallbackMaintenance()
      defer:
        server.endMacosFallbackMaintenance(ranMaintenance)
    let sockData = socketDataFor(server.ssl.toInt, s)
    if sockData != nil:
      if sockData.hasFlag(SDF_IS_HTTP2):
        if sockData.h2conn != nil:
          h2FlushSendBuf(sockData.h2conn, server.ssl.toInt.cint, s)
        return s
      if sockData.hasFlag(SDF_IS_WEBSOCKET):
        sockData.flushWsQueuedFrames(s)
        sockData.setSocketTimeoutPhase(s, tpWebSocketIdle, sockData.activeRequestSeq)
        closeSocketIfPending(sockData, s)
        return s
      if not invokeHeadWritableHandler(sockData, s):
        return s
      flushSendBuffer(sockData, server.ssl.toInt, s)
      flushPendingResponses(sockData, s)
      flushSendBuffer(sockData, server.ssl.toInt, s)
      if sockData.pendingIsEmpty():
        sockData.setSocketTimeoutPhase(s, tpHeaderRead, sockData.nextRequestSeq)
      else:
        sockData.setSocketTimeoutPhase(s, tpWriteDrain, sockData.nextWriteSeq)
      closeSocketIfPending(sockData, s)
  result = s

proc onSocketWritable(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  try:
    discard onSocketWritableImpl(s)
  except Defect as defect:
    reportEscapedDefect("onSocketWritable", defect)
  except CatchableError as err:
    reportEscapedError("onSocketWritable", err)
  s

proc onSocketTimeoutImpl(s: UsSocketPtr): UsSocketPtr =
  let server = resolveServerFromSocket(s)
  if server != nil:
    when defined(macosx):
      # GCD backend does not emit loop pre/post callbacks.
      # Run maintenance at bounded cadence and avoid nested re-entry.
      let ranMaintenance = server.beginMacosFallbackMaintenance()
      defer:
        server.endMacosFallbackMaintenance(ranMaintenance)
    let ssl = server.ssl.toInt
    let sockData = socketDataFor(ssl, s)
    if sockData != nil and sockData.hasFlag(SDF_IS_WEBSOCKET):
      # Optional WebSocket idle timeout is independent of HTTP timeout policy.
      if sockData.wsIdleTimeoutFor() == 0:
        return s
      let phaseLabel = timeoutPhaseLabel(tpWebSocketIdle)
      sockData.emitTimeoutCallbacks(phaseLabel, phaseLabel)
      discard closeSocketTracked(server, ssl, s, "timeout_websocket_idle")
      return s
    elif sockData != nil:
      let phase = sockData.timeoutPhase
      let phaseLabel = timeoutPhaseLabel(phase)
      let kind = timeoutKindLabel(phase)
      sockData.emitTimeoutCallbacks(kind, phaseLabel)
  # Close timed out HTTP connection.
  if server != nil:
    discard closeSocketTracked(server, server.ssl.toInt, s, "timeout_http")
  result = s

proc onSocketTimeout(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  try:
    discard onSocketTimeoutImpl(s)
  except Defect as defect:
    reportEscapedDefect("onSocketTimeout", defect)
  except CatchableError as err:
    reportEscapedError("onSocketTimeout", err)
  s

proc onSocketEndImpl(s: UsSocketPtr): UsSocketPtr =
  let server = resolveServerFromSocket(s)
  if server != nil:
    when defined(macosx):
      # GCD backend does not emit loop pre/post callbacks.
      let ranMaintenance = server.beginMacosFallbackMaintenance()
      defer:
        server.endMacosFallbackMaintenance(ranMaintenance)
    let sockData = socketDataFor(server.ssl.toInt, s)
    if sockData != nil:
      if sockData.pendingIsEmpty() and sockData.sendBufferRemaining() == 0:
        discard closeSocketTracked(server, server.ssl.toInt, s, "peer_end_idle")
      else:
        sockData.setFlag(SDF_PENDING_CLOSE)
  result = s

proc onSocketEnd(s: UsSocketPtr): UsSocketPtr {.cdecl.} =
  try:
    discard onSocketEndImpl(s)
  except Defect as defect:
    reportEscapedDefect("onSocketEnd", defect)
  except CatchableError as err:
    reportEscapedError("onSocketEnd", err)
  s

## Return the default ServerOptions with tuned production values
proc defaultServerOptions*(): ServerOptions =
  ## Return default server options
  ServerOptions(
    maxBodySize: DefaultMaxBodySize,
    maxHeaderBytes: DefaultMaxHeaderBytes,
    maxHeaderCount: DefaultMaxHeaderCount,
    maxHeaderLineBytes: DefaultMaxHeaderLineBytes,
    maxRequestUriBytes: DefaultMaxRequestUriBytes,
    wsMaxFragmentCount: DefaultWsMaxFragmentCount,
    expectContinueMode: ecmStrictReject,
    connectionTimeout: DefaultConnectionTimeout,
    maxConnections: DefaultMaxConnections,
    maxPendingBytesPerSocket: DefaultMaxPendingBytesPerSocket,
    wsKeepaliveInterval: DefaultWsKeepaliveInterval,
    wsIdleTimeoutSeconds: DefaultWsIdleTimeoutSeconds,
    wsMaxBackpressure: DefaultWsMaxBackpressure,
    wsBackpressureHighWaterBytes: 0,
    wsBackpressureHighWaterAction: bhwDropNewest,
    wsDynamicBackpressureEnabled: false,
    wsExpectedConnections: 0,
    wsMessageBytes: 0,
    wsQueueBudgetBytes: 0,
    wsCloseOnBackpressureLimit: false,
    wsResetIdleTimeoutOnSend: true,
    wsCompressionEnabled: false,
    wsCompressionMinBytes: DefaultWsCompressionMinBytes,
    wsCompressionMinSavingsBytes: DefaultWsCompressionMinSavingsBytes,
    wsCompressionServerNoContextTakeover: true,
    wsCompressionClientNoContextTakeover: true,
    wsCompressionDisableForBinary: false,
    wsCompressionDisableForText: false,
    wsCompressionBackpressureBypassBytes: 0,
    wsWriteCoalesceMaxBytes: DefaultWsWriteCoalesceMaxBytes,
    wsWriteCoalesceMaxFrames: DefaultWsWriteCoalesceMaxFrames,
    minimalHeaderParsing: false,
    gracefulShutdown: true,
    macosHighQos: true,
    tlsFlattenThreshold: DefaultTlsFlattenThreshold,
    writeCoalesceMode: wcmAdaptive,
    writeCoalesceMaxBytes: MaxCoalescedWriteBytes,
    writeCoalesceMaxResponses: MaxCoalescedResponses,
    writeCoalesceLatencyMaxBytes: DefaultWriteCoalesceLatencyMaxBytes,
    writeCoalesceLatencyMaxResponses: DefaultWriteCoalesceLatencyMaxResponses,
    writeCoalesceThroughputMaxBytes: DefaultWriteCoalesceThroughputMaxBytes,
    writeCoalesceThroughputMaxResponses: DefaultWriteCoalesceThroughputMaxResponses,
    writeCoalesceSmallPayloadBytes: DefaultWriteCoalesceSmallPayloadBytes,
    writeCoalesceLargePayloadBytes: DefaultWriteCoalesceLargePayloadBytes,
    writeCoalesceP99GuardPendingBytes: DefaultWriteCoalesceP99GuardPendingBytes,
    writeCoalesceP99GuardPendingResponses: DefaultWriteCoalesceP99GuardPendingResponses,
    loopWriteBatching: (when defined(linux): true else: false),
    readBufferMinCapacity: DefaultReadBufferMinCapacity,
    readBufferMaxCapacity: DefaultReadBufferMaxCapacity,
    readBufferShrinkPercent: DefaultReadBufferShrinkPercent,
    parseBudgetRequestsPerRead: DefaultParseBudgetRequestsPerRead,
    parseBudgetBytesPerRead: DefaultParseBudgetBytesPerRead,
    loopDispatchBudgetRequests: DefaultLoopDispatchBudgetRequests,
    loopDispatchBudgetBytes: DefaultLoopDispatchBudgetBytes,
    writeBudgetIterationsPerFlush: DefaultWriteBudgetIterationsPerFlush,
    writeBudgetBytesPerFlush: DefaultWriteBudgetBytesPerFlush,
    loopWriteBudgetBytes: DefaultLoopWriteBudgetBytes,
    bodySpillThreshold: 0,
    bodySpillDir: "",
    bodySpillOffloadEnabled: true,
    bodySpillOffloadQueueLimit: DefaultBodySpillOffloadQueueLimit,
    bodySpillOffloadQueueBytesLimit: DefaultBodySpillOffloadQueueBytesLimit,
    spillPressureRejectThreshold: DefaultSpillPressureRejectThreshold,
    spillPressureRecoverThreshold: DefaultSpillPressureRecoverThreshold,
    overloadMaxLoopBacklogBytes: 0,
    overloadMaxPendingResponses: 0,
    overloadCloseOnReject: false,
    overloadAdaptiveEnabled: false,
    overloadAdaptiveMinBacklogBytes: DefaultOverloadAdaptiveMinBacklogBytes,
    overloadAdaptiveMaxBacklogBytes: 0,
    overloadAdaptiveMinPendingResponses: DefaultOverloadAdaptiveMinPendingResponses,
    overloadAdaptiveMaxPendingResponses: 0,
    overloadAdaptiveTightenStepPercent: DefaultOverloadAdaptiveTightenStepPercent,
    overloadAdaptiveRelaxStepPercent: DefaultOverloadAdaptiveRelaxStepPercent,
    overloadAdaptiveCooldownRequests: DefaultOverloadAdaptiveCooldownRequests,
    overloadRetryAfterSeconds: DefaultOverloadRetryAfterSeconds,
    socketNoDelay: true,
    socketKeepAlive: true,
    socketKeepAliveSeconds: 60,
    socketFastOpen: false,
    socketSendBufferBytes: 524288,
    socketRecvBufferBytes: 524288,
    socketNotSentLowWaterBytes: 16384,
    socketDeferAcceptSeconds: 0,
    socketIncomingCpu: -1,
    listenExclusivePort: false,
    listenEpollExclusive: false,
    listenEpollEdgeTrigger: false,
    gracefulShutdownDrainMs: DefaultGracefulShutdownDrainMs,
    headerReadTimeoutMs: DefaultHeaderReadTimeoutMs,
    bodyReadTimeoutMs: DefaultBodyReadTimeoutMs,
    handlerExecTimeoutMs: DefaultHandlerExecTimeoutMs,
    writeDrainTimeoutMs: DefaultWriteDrainTimeoutMs,
    crossThreadDeferEnabled: false,
    crossThreadDeferQueueLimit: DefaultCrossThreadDeferQueueLimit,
    wsSocketRecvBufferBytes: 0,
    wsSocketSendBufferBytes: 0,
    wsSocketNotSentLowWaterBytes: 0,
    maxRequestMemory: DefaultRequestMemoryBudget
  )

## Create a new HTTP server with the given SSL mode and options
proc newHttpServer*(ssl: SslMode = NoSsl, options: ServerOptions = defaultServerOptions()): HttpServer =
  ## Create a new HTTP server
  new(result)
  result.ssl = ssl
  result.options = options
  result.handler = nil
  result.wsHandler = nil
  result.wsUpgradeValidateHandler = nil
  result.wsOpenHandler = nil
  result.wsCloseHandler = nil
  result.wsDrainHandler = nil
  result.wsDroppedHandler = nil
  result.wsHighWaterHandler = nil
  result.startCallback = nil
  result.timerCallback = nil
  result.loopPreCallback = nil
  result.loopPostCallback = nil
  result.connectionOpenHandler = nil
  result.connectionCloseHandler = nil
  result.requestStartHandler = nil
  result.requestEndHandler = nil
  result.beforeHeadersHandler = nil
  result.beforeWriteHandler = nil
  result.afterWriteHandler = nil
  result.backpressureHandler = nil
  result.timeoutHandler = nil
  result.timeoutMetadataHandler = nil
  result.protocolErrorHandler = nil
  result.errorHandler = nil
  result.panicHandler = nil
  result.timer = nil
  result.timerIntervalMs = 1000
  result.internalTimerCallback = nil
  result.internalTimer = nil
  result.internalTimerIntervalMs = 1000
  result.dateHeaderTimer = nil
  result.wsKeepaliveTimer = nil
  result.shutdownPollTimer = nil
  result.cachedDateHeaderLine = ""
  result.cachedDateEpochSec = -1
  when defined(macosx):
    result.macosUserTimerLastMs = 0
    result.macosInternalTimerLastMs = 0
    result.macosWsKeepaliveLastMs = 0
  when compileOption("threads"):
    result.spillWorkerState = nil
    result.spillWorkerRunning = false
    initLock(result.crossThreadDeferLock)
    result.crossThreadDeferQueue = @[]
    result.crossThreadDeferPreQueue = @[]
    result.crossThreadDeferWakePending = false
    result.crossThreadDeferViolationWarned = false
    result.crossThreadDeferOverflowWarned = false
    result.crossThreadDeferAccepting = true
    result.crossThreadDeferWakeClosing = false
    result.crossThreadDeferWakeRefs = 0
  result.connectionCount = 0
  result.isShuttingDown = false
  result.cleanupCompleted = false
  result.stopCallback = nil
  result.shutdownCallback = nil
  result.shutdownStartedAtMs = 0'i64
  result.shutdownForceCloseAtMs = 0'i64
  result.shutdownConnectionSnapshot = 0
  result.loopOwnerBound = false
  result.loopOwnerThreadId = 0'u64
  result.websocketIndex = newFastMap[int64]()
  result.websocketSet = newFastSet()
  discard result.websocketIndex.reserve(64)
  discard result.websocketSet.reserve(64)
  result.websockets = newSeqOfCap[WebSocket](64)
  result.wsKeepaliveCursor = 0
  result.topicIndex = newFastMap[int64]()
  discard result.topicIndex.reserve(128)
  result.topicNames = @[]
  result.topicSubscribers = @[]
  result.wsDrainQueue = @[]
  result.wsDrainQueued = newFastSet()
  result.socketTunableWarnings = newFastSet()
  result.deferredPreCallbacks = @[]
  result.deferredCallbacks = @[]
  result.metricsParserErrors = 0
  result.metricsOverloadRejects = 0
  result.metricsOverloadRejectBacklog = 0
  result.metricsOverloadRejectPending = 0
  result.metricsWriteRetries = 0
  result.metricsBackpressureDrops = 0
  result.metricsBackpressureHighWaterEvents = 0
  result.metricsSpillOffloadEnqueued = 0
  result.metricsSpillOffloadDropped = 0
  result.metricsShutdownDrainedConnections = 0
  result.metricsShutdownForcedConnections = 0
  result.metricsCrossThreadDeferRerouted = 0
  result.metricsCrossThreadDeferViolations = 0
  result.metricsCrossThreadDeferDropped = 0
  result.metricsSocketCloseAttempts = 0
  result.metricsSocketCloseFailures = 0
  result.overloadAdaptiveBacklogLimit = result.options.overloadMaxLoopBacklogBytes
  result.overloadAdaptivePendingLimit = result.options.overloadMaxPendingResponses
  result.overloadAdaptiveRejectStreak = 0
  result.overloadAdaptiveAcceptStreak = 0
  result.overloadControlEnabled = result.options.overloadMaxLoopBacklogBytes > 0 or
    result.options.overloadMaxPendingResponses > 0 or
    result.options.overloadAdaptiveEnabled or
    result.options.spillPressureRejectThreshold > 0
  result.spillPressureScore = 0
  result.spillPressureRejecting = false
  result.closeOutcomeCounts = newFastMap[int64]()
  result.closeOutcomeWarnings = newFastSet()
  result.metricsSocketTunablesApplied = 0
  result.metricsSocketTunablesUnsupported = 0
  result.metricsSocketTunablesFailed = 0
  when defined(macosx):
    result.macosMaintenanceDepth = 0
    result.macosMaintenanceEpochMs = -1
  result.fairnessEnabled = true
  result.loopWriteBatchDepth = 0
  result.pendingFlushSockets = @[]
  result.closedSocketKeys = initTable[uint64, uint64]()
  result.socketDataRoots = initTable[uint64, SocketDataRef]()
  result.loopMaintenanceEpoch = 0'u64
  result.nextSocketGeneration = 0'u64
  result.resetLoopFairnessBudgets()
  discard result.wsDrainQueued.reserve(64)
  discard result.socketTunableWarnings.reserve(32)
  discard result.closeOutcomeCounts.reserve(16)
  discard result.closeOutcomeWarnings.reserve(16)
  when compileOption("threads"):
    startSpillOffloadWorker(result)

## Set the request handler invoked for each parsed HTTP request
proc handle*(server: HttpServer, handler: HttpHandler) =
  ## Set the request handler
  server.handler = handler

## Set the callback fired after the server starts listening successfully
proc onStart*(server: HttpServer, callback: TimerCallback) =
  ## Set callback fired after server starts listening successfully.
  server.startCallback = callback

## Set the callback fired when a new client connection opens
proc onConnectionOpen*(server: HttpServer, handler: ConnectionOpenHandler) =
  server.connectionOpenHandler = handler

## Set the callback fired when a client connection closes
proc onConnectionClose*(server: HttpServer, handler: ConnectionCloseHandler) =
  server.connectionCloseHandler = handler

## Set the callback fired when a new request starts being parsed
proc onRequestStart*(server: HttpServer, handler: RequestStartHandler) =
  server.requestStartHandler = handler

## Set the callback fired when a request finishes and is dispatched
proc onRequestEnd*(server: HttpServer, handler: RequestEndHandler) =
  server.requestEndHandler = handler

## Set the callback fired just before response headers are written
proc onBeforeHeaders*(server: HttpServer, handler: BeforeHeadersHandler) =
  server.beforeHeadersHandler = handler

## Set the callback fired just before socket write bytes are emitted
proc onBeforeWrite*(server: HttpServer, handler: BeforeWriteHandler) =
  server.beforeWriteHandler = handler

## Set the callback fired after socket write bytes are emitted
proc onAfterWrite*(server: HttpServer, handler: AfterWriteHandler) =
  server.afterWriteHandler = handler

## Set the callback fired when a socket reports write backpressure
proc onBackpressure*(server: HttpServer, handler: BackpressureHandler) =
  server.backpressureHandler = handler

## Set the callback fired when a socket phase times out
proc onTimeout*(server: HttpServer, handler: TimeoutHandler) =
  server.timeoutHandler = handler

## Set the callback fired with timeout metadata for timed-out sockets
proc onTimeoutMetadata*(server: HttpServer, handler: TimeoutMetadataHandler) =
  server.timeoutMetadataHandler = handler

## Set the callback that can transform protocol errors before they are reported
proc onProtocolErrorTransform*(server: HttpServer, handler: ProtocolErrorTransformHandler) =
  server.protocolErrorHandler = handler

## Set the callback fired when a server-level error occurs
proc onError*(server: HttpServer, handler: ErrorHandler) =
  server.errorHandler = handler

## Set the callback fired when a handler panic is caught by the server
proc onPanic*(server: HttpServer, handler: PanicHandler) =
  server.panicHandler = handler

## Set the WebSocket message handler for text and binary frames
proc onWebSocket*(server: HttpServer, handler: WebSocketHandler) =
  ## Set the WebSocket message handler
  server.wsHandler = handler

## Set an opt-in zero-copy WebSocket message handler for complete uncompressed messages
proc onWebSocketRaw*(server: HttpServer, handler: WebSocketRawHandler) =
  ## Set an opt-in zero-copy WebSocket message handler for complete,
  ## uncompressed, unfragmented messages.
  ##
  ## The ``data`` pointer is valid only for the duration of the callback.
  ## Handlers that need to retain payload bytes must copy them before returning.
  server.wsRawHandler = handler

## Set the policy callback for WebSocket upgrade requests, return false to reject with 403
proc onWebSocketUpgradeValidate*(server: HttpServer, handler: WebSocketUpgradeValidateHandler) =
  ## Set policy callback for WebSocket upgrade requests.
  ## Return false to reject handshake with 403.
  server.wsUpgradeValidateHandler = handler

## Set the callback fired when a WebSocket connection is established
proc onWebSocketOpen*(server: HttpServer, handler: WebSocketOpenHandler) =
  ## Set the WebSocket open handler
  server.wsOpenHandler = handler

## Set the callback fired when a WebSocket connection closes
proc onWebSocketClose*(server: HttpServer, handler: WebSocketCloseHandler) =
  ## Set the WebSocket close handler
  server.wsCloseHandler = handler

## Set the callback fired when a websocket out-queue drains after backpressure
proc onWebSocketDrain*(server: HttpServer, handler: WebSocketDrainHandler) =
  ## Set the WebSocket backpressure-drained handler.
  server.wsDrainHandler = handler

## Set the callback fired when a WebSocket send is dropped by backpressure policy
proc onWebSocketDropped*(server: HttpServer, handler: WebSocketDroppedHandler) =
  ## Set callback invoked when a WebSocket send is dropped due to backpressure policy.
  server.wsDroppedHandler = handler

## Set the callback fired when a websocket out-queue crosses its high-water threshold
proc onWebSocketHighWater*(server: HttpServer, handler: WebSocketHighWaterHandler) =
  ## Set callback invoked when websocket queue exceeds high-water threshold.
  server.wsHighWaterHandler = handler

## Set a periodic timer callback with the given interval in milliseconds
proc setInterval*(server: HttpServer, callback: TimerCallback, intervalMs: int) =
  ## Set a timer that fires periodically
  server.timerCallback = callback
  server.timerIntervalMs = if intervalMs > 0: intervalMs else: 1000

## Set callbacks invoked before and after each event loop iteration
proc setLoopCallbacks*(server: HttpServer, preCallback: TimerCallback = nil, postCallback: TimerCallback = nil) =
  ## Set callbacks invoked before/after each event-loop iteration.
  server.loopPreCallback = preCallback
  server.loopPostCallback = postCallback

## Set an internal framework timer without overriding user-configured timers
proc setInternalInterval*(server: HttpServer, callback: TimerCallback, intervalMs: int) =
  ## Set internal framework timer without overriding user timers
  server.internalTimerCallback = callback
  server.internalTimerIntervalMs = if intervalMs > 0: intervalMs else: 1000

## Enable or disable the macOS USER_INITIATED QoS hint for the loop thread
proc setMacosHighQos*(server: HttpServer, enabled: bool) =
  ## Enable/disable USER_INITIATED QoS hint for the current loop thread on macOS.
  server.options.macosHighQos = enabled

## Configure the max queued unsent bytes per socket before forcing close
proc setMaxPendingBytesPerSocket*(server: HttpServer, bytes: int) =
  ## Configure max queued unsent bytes per socket before forcing close.
  server.options.maxPendingBytesPerSocket = max(0, bytes)

## Configure the graceful drain window before forced shutdown close
proc setGracefulShutdownDrainMs*(server: HttpServer, drainMs: int) =
  ## Configure graceful-drain window before forced shutdown close.
  server.options.gracefulShutdownDrainMs = max(0, drainMs)

## Configure the header read, body read, handler, and write drain timeout phases
proc setPhaseTimeouts*(
  server: HttpServer,
  headerReadMs: int = DefaultHeaderReadTimeoutMs,
  bodyReadMs: int = DefaultBodyReadTimeoutMs,
  handlerExecMs: int = DefaultHandlerExecTimeoutMs,
  writeDrainMs: int = DefaultWriteDrainTimeoutMs
) =
  ## Configure independent timeout phases (0 disables that phase timeout).
  server.options.headerReadTimeoutMs = max(0, headerReadMs)
  server.options.bodyReadTimeoutMs = max(0, bodyReadMs)
  server.options.handlerExecTimeoutMs = max(0, handlerExecMs)
  server.options.writeDrainTimeoutMs = max(0, writeDrainMs)

## Configure the per-connection request memory budget in bytes
proc setMaxRequestMemory*(server: HttpServer, bytes: int) =
  server.options.maxRequestMemory = max(0, bytes)

## Enable or disable the cross-thread defer queue for deferred callbacks
proc setCrossThreadDeferEnabled*(server: HttpServer, enabled: bool) =
  server.options.crossThreadDeferEnabled = enabled

## Configure the max queued callbacks for ``deferFromAnyThread``, values at or below zero reset to default
proc setCrossThreadDeferQueueLimit*(server: HttpServer, maxCallbacks: int) =
  ## Configure max queued callbacks for deferFromAnyThread (<=0 resets to default).
  if maxCallbacks <= 0:
    server.options.crossThreadDeferQueueLimit = DefaultCrossThreadDeferQueueLimit
  else:
    server.options.crossThreadDeferQueueLimit = max(1, maxCallbacks)

## Configure the Retry-After header seconds for overload responses, zero disables
proc setOverloadRetryAfter*(server: HttpServer, seconds: int) =
  ## Configure Retry-After header for overload responses (0 disables).
  server.options.overloadRetryAfterSeconds = max(0, seconds)

## Configure header size, header count, header line, and request URI byte limits
proc setHeaderLimits*(
  server: HttpServer,
  maxHeaderBytes: int = DefaultMaxHeaderBytes,
  maxHeaderCount: int = DefaultMaxHeaderCount,
  maxHeaderLineBytes: int = DefaultMaxHeaderLineBytes,
  maxRequestUriBytes: int = DefaultMaxRequestUriBytes
) =
  server.options.maxHeaderBytes = max(0, maxHeaderBytes)
  server.options.maxHeaderCount = max(0, maxHeaderCount)
  server.options.maxHeaderLineBytes = max(0, maxHeaderLineBytes)
  server.options.maxRequestUriBytes = max(0, maxRequestUriBytes)

## Configure the Expect 100-continue handling mode for incoming requests
proc setExpectContinueMode*(server: HttpServer, mode: ExpectContinueMode) =
  ## Configure Expect: 100-continue behavior (strict reject by default).
  server.options.expectContinueMode = mode

## Configure the max queued outgoing websocket bytes per socket, zero means unlimited
proc setWsMaxBackpressure*(server: HttpServer, bytes: int) =
  ## Configure max queued outgoing websocket bytes per socket (0 = unlimited).
  server.options.wsMaxBackpressure = max(0, bytes)

## Configure the websocket high-water threshold in bytes, zero disables the check
proc setWsBackpressureHighWater*(server: HttpServer, bytes: int) =
  ## Configure websocket high-water threshold in bytes (0 = disabled).
  server.options.wsBackpressureHighWaterBytes = max(0, bytes)

## Configure the deterministic action taken when the websocket high-water threshold is exceeded
proc setWsBackpressureHighWaterAction*(server: HttpServer, action: BackpressureHighWaterAction) =
  ## Configure deterministic action used when ws high-water threshold is exceeded.
  server.options.wsBackpressureHighWaterAction = action

## Derive a per-socket websocket high-water threshold from an overall queue budget
proc wsBackpressureHighWaterFromBudget*(
  expectedConnections: int,
  messageBytes: int,
  queueBudgetBytes: int,
  maxBackpressureBytes: int = DefaultWsMaxBackpressure
): int {.inline.} =
  ## Derive a per-socket WebSocket high-water threshold from an overall queue budget.
  ## This is intentionally conservative: each connection gets its fair share of
  ## the budget, but never less than a small multi-frame burst allowance.
  if expectedConnections <= 0 or queueBudgetBytes <= 0:
    return 0
  let perConnection = max(1, queueBudgetBytes div expectedConnections)
  let burstFloor =
    if messageBytes > 0:
      max(16 * 1024, 4 * (messageBytes + 32))
    else:
      16 * 1024
  result = max(burstFloor, perConnection)
  if maxBackpressureBytes > 0:
    result = min(result, maxBackpressureBytes)

## Enable dynamic websocket queue budgeting derived from connection and message size estimates
proc setWsDynamicBackpressure*(
  server: HttpServer,
  enabled: bool,
  expectedConnections: int,
  messageBytes: int,
  queueBudgetBytes: int,
  action: BackpressureHighWaterAction = bhwDropNewest,
  closeOnBackpressureLimit: bool = false
) =
  ## Enable/disable dynamic websocket queue budgeting.
  ## When enabled, the high-water threshold is recomputed from the supplied
  ## expected connection count, typical message size, total queue budget, and
  ## current wsMaxBackpressure cap.
  if server == nil:
    return
  server.options.wsDynamicBackpressureEnabled = enabled
  server.options.wsExpectedConnections = max(0, expectedConnections)
  server.options.wsMessageBytes = max(0, messageBytes)
  server.options.wsQueueBudgetBytes = max(0, queueBudgetBytes)
  server.options.wsBackpressureHighWaterAction = action
  server.options.wsCloseOnBackpressureLimit = closeOnBackpressureLimit
  if enabled:
    server.options.wsBackpressureHighWaterBytes = wsBackpressureHighWaterFromBudget(
      server.options.wsExpectedConnections,
      server.options.wsMessageBytes,
      server.options.wsQueueBudgetBytes,
      server.options.wsMaxBackpressure
    )

## Configure whether sockets are closed when the websocket backpressure limit is exceeded
proc setWsCloseOnBackpressureLimit*(server: HttpServer, enabled: bool) =
  ## Configure whether sockets are closed when ws backpressure limit is exceeded.
  server.options.wsCloseOnBackpressureLimit = enabled

## Configure the websocket idle timeout in seconds, zero disables the timeout
proc setWsIdleTimeout*(server: HttpServer, seconds: int) =
  ## Configure websocket idle timeout in seconds (0 = disabled).
  # Values above the uSockets wheel horizon are clamped (see wsIdleTimeoutFor).
  server.options.wsIdleTimeoutSeconds = min(max(0, seconds), WsIdleTimeoutWheelHorizonSeconds)

## Configure whether successful websocket sends refresh the idle timeout
proc setWsResetIdleTimeoutOnSend*(server: HttpServer, enabled: bool) =
  ## Configure whether successful ws sends/drains refresh idle timeout.
  server.options.wsResetIdleTimeoutOnSend = enabled

## Set send and receive buffer sizes on a live websocket socket, best effort
proc setWsSocketBufferSizes*(ws: WebSocket, sendSize: int, recvSize: int) =
  if ws != nil and ws.socket != nil:
    us_socket_set_buffer_sizes(ws.ssl, ws.socket, sendSize.cint, recvSize.cint)

## Enable or disable per-message websocket compression
proc setWsCompressionEnabled*(server: HttpServer, enabled: bool) =
  server.options.wsCompressionEnabled = enabled

## Configure the minimum payload bytes before websocket compression is considered
proc setWsCompressionThreshold*(server: HttpServer, bytes: int) =
  ## Configure minimum payload bytes before websocket compression is considered.
  server.options.wsCompressionMinBytes = max(0, bytes)

## Configure the minimum byte savings required to keep a compressed websocket payload
proc setWsCompressionMinSavings*(server: HttpServer, bytes: int) =
  ## Configure minimum byte savings required to keep compressed websocket payload.
  server.options.wsCompressionMinSavingsBytes = max(0, bytes)

## Configure the required no-context-takeover flags for websocket compression negotiation
proc setWsCompressionNoContextTakeover*(
  server: HttpServer,
  serverNoContextTakeover: bool = true,
  clientNoContextTakeover: bool = true
) =
  ## Configure required no-context-takeover negotiation flags.
  server.options.wsCompressionServerNoContextTakeover = serverNoContextTakeover
  server.options.wsCompressionClientNoContextTakeover = clientNoContextTakeover

## Configure payload-type bypass controls for websocket compression
proc setWsCompressionBypass*(
  server: HttpServer,
  disableForBinary: bool = false,
  disableForText: bool = false
) =
  ## Configure payload-type bypass controls for websocket compression.
  server.options.wsCompressionDisableForBinary = disableForBinary
  server.options.wsCompressionDisableForText = disableForText

## Disable websocket compression when pending backpressure exceeds the threshold, zero disables
proc setWsCompressionBackpressureBypass*(server: HttpServer, bytes: int) =
  ## Disable websocket compression when pending backpressure exceeds this threshold (0 = disabled).
  server.options.wsCompressionBackpressureBypassBytes = max(0, bytes)

## Configure websocket queued-write coalescing byte and frame bounds
proc setWsWriteCoalesceLimits*(server: HttpServer, maxBytes: int, maxFrames: int) =
  ## Configure websocket queued-write coalescing bounds.
  server.options.wsWriteCoalesceMaxBytes = max(0, maxBytes)
  server.options.wsWriteCoalesceMaxFrames = max(0, maxFrames)

## Configure the TLS header and body flatten threshold in bytes
proc setTlsFlattenThreshold*(server: HttpServer, bytes: int) =
  ## Configure TLS header+body flatten threshold.
  server.options.tlsFlattenThreshold = max(256, bytes)

## Configure queued HTTP response coalescing byte and response bounds
proc setWriteCoalesceLimits*(server: HttpServer, maxBytes: int, maxResponses: int) =
  ## Configure queued HTTP coalescing bounds.
  server.options.writeCoalesceMaxBytes = max(1024, maxBytes)
  server.options.writeCoalesceMaxResponses = max(1, maxResponses)

## Select the adaptive, latency, balanced, or throughput write coalescing mode
proc setWriteCoalesceMode*(server: HttpServer, mode: WriteCoalesceMode) =
  ## Select adaptive/latency/balanced/throughput write coalescing mode.
  server.options.writeCoalesceMode = mode

## Configure the low-latency write coalescing bounds
proc setWriteCoalesceLatencyLimits*(server: HttpServer, maxBytes: int, maxResponses: int) =
  ## Configure low-latency coalescing bounds.
  server.options.writeCoalesceLatencyMaxBytes = max(1024, maxBytes)
  server.options.writeCoalesceLatencyMaxResponses = max(1, maxResponses)

## Configure the throughput-oriented write coalescing bounds
proc setWriteCoalesceThroughputLimits*(server: HttpServer, maxBytes: int, maxResponses: int) =
  ## Configure throughput coalescing bounds.
  server.options.writeCoalesceThroughputMaxBytes = max(1024, maxBytes)
  server.options.writeCoalesceThroughputMaxResponses = max(1, maxResponses)

## Configure the small and large payload thresholds used by adaptive coalescing
proc setWriteCoalescePayloadThresholds*(server: HttpServer, smallPayloadBytes: int, largePayloadBytes: int) =
  ## Configure payload thresholds used by adaptive coalescing mode.
  let small = max(256, smallPayloadBytes)
  let large = max(small, largePayloadBytes)
  server.options.writeCoalesceSmallPayloadBytes = small
  server.options.writeCoalesceLargePayloadBytes = large

## Enable or disable loop-driven batching of socket writes
proc setLoopWriteBatching*(server: HttpServer, enabled: bool) =
  server.options.loopWriteBatching = enabled

## Configure the low-backlog guard that caps coalescing to protect tail latency
proc setWriteCoalesceP99Guard*(server: HttpServer, pendingBytes: int, pendingResponses: int) =
  ## Configure conservative low-backlog guard to avoid p99 latency regressions.
  server.options.writeCoalesceP99GuardPendingBytes = max(1024, pendingBytes)
  server.options.writeCoalesceP99GuardPendingResponses = max(1, pendingResponses)

## Configure adaptive read buffer capacity bounds and shrink hysteresis
proc setAdaptiveReadBuffer*(
  server: HttpServer,
  minCapacity: int,
  maxCapacity: int,
  shrinkPercent: int = DefaultReadBufferShrinkPercent
) =
  ## Configure adaptive read-buffer bounds and shrink hysteresis.
  let minCap = max(InitialBufferSize, minCapacity)
  let maxCap = max(minCap, maxCapacity)
  server.options.readBufferMinCapacity = minCap
  server.options.readBufferMaxCapacity = maxCap
  server.options.readBufferShrinkPercent = max(5, min(95, shrinkPercent))

## Configure the per-socket request dispatch fairness budget for each data callback
proc setParseFairnessBudget*(server: HttpServer, requestsPerRead: int, bytesPerRead: int) =
  ## Configure per-socket dispatch fairness budget in each data callback.
  server.options.parseBudgetRequestsPerRead = max(1, requestsPerRead)
  server.options.parseBudgetBytesPerRead = max(1024, bytesPerRead)

## Configure the per-loop dispatch budget shared across all sockets
proc setLoopDispatchFairnessBudget*(server: HttpServer, requestsPerLoop: int, bytesPerLoop: int) =
  ## Configure per-loop dispatch budget shared across sockets.
  server.options.loopDispatchBudgetRequests = max(1, requestsPerLoop)
  server.options.loopDispatchBudgetBytes = max(1024, bytesPerLoop)
  server.resetLoopFairnessBudgets()

## Configure the per-socket queued write budget for each drain call
proc setWriteFairnessBudget*(server: HttpServer, iterationsPerFlush: int, bytesPerFlush: int) =
  ## Configure per-socket queued write budget in each drain call.
  server.options.writeBudgetIterationsPerFlush = max(1, iterationsPerFlush)
  server.options.writeBudgetBytesPerFlush = max(1024, bytesPerFlush)

## Configure the per-loop queued write budget shared across all sockets
proc setLoopWriteFairnessBudget*(server: HttpServer, bytesPerLoop: int) =
  ## Configure per-loop queued write budget shared across sockets.
  server.options.loopWriteBudgetBytes = max(1024, bytesPerLoop)
  server.resetLoopFairnessBudgets()

## Configure the large request body spill-to-disk threshold and spill directory
proc setBodySpillToDisk*(server: HttpServer, thresholdBytes: int, spillDir: string = "") =
  ## Configure large request body spill-to-disk threshold (0 disables).
  server.options.bodySpillThreshold = max(0, thresholdBytes)
  server.options.bodySpillDir = spillDir
  when compileOption("threads"):
    if server.options.bodySpillOffloadEnabled and server.options.bodySpillThreshold > 0:
      startSpillOffloadWorker(server)
    else:
      stopSpillOffloadWorker(server)

## Configure background spill offload queue limits for threaded builds
proc setBodySpillOffload*(
  server: HttpServer,
  enabled: bool = true,
  queueLimit: int = DefaultBodySpillOffloadQueueLimit,
  queueBytesLimit: int = DefaultBodySpillOffloadQueueBytesLimit
) =
  ## Configure background spill offload behavior (threaded builds only).
  server.options.bodySpillOffloadEnabled = enabled
  server.options.bodySpillOffloadQueueLimit = max(1, queueLimit)
  server.options.bodySpillOffloadQueueBytesLimit = max(1, queueBytesLimit)
  when compileOption("threads"):
    if enabled and server.options.bodySpillThreshold > 0:
      startSpillOffloadWorker(server)
    else:
      stopSpillOffloadWorker(server)

## Configure the spill-pressure overload hysteresis reject and recover thresholds
proc setSpillPressureController*(
  server: HttpServer,
  rejectThreshold: int = DefaultSpillPressureRejectThreshold,
  recoverThreshold: int = DefaultSpillPressureRecoverThreshold
) =
  ## Configure spill-pressure overload hysteresis thresholds.
  let rejectCap = max(1, rejectThreshold)
  let recoverCap = max(0, min(rejectCap, recoverThreshold))
  server.options.spillPressureRejectThreshold = rejectCap
  server.options.spillPressureRecoverThreshold = recoverCap
  if server.spillPressureScore >= rejectCap:
    server.spillPressureRejecting = true
  elif server.spillPressureScore <= recoverCap:
    server.spillPressureRejecting = false

## Configure static overload admission limits for loop backlog bytes and pending responses
proc setOverloadController*(
  server: HttpServer,
  maxBacklogBytes: int = 0,
  maxPendingResponses: int = 0,
  closeOnReject: bool = false
) =
  ## Configure overload admission controller thresholds (0 disables each limit).
  server.options.overloadMaxLoopBacklogBytes = max(0, maxBacklogBytes)
  server.options.overloadMaxPendingResponses = max(0, maxPendingResponses)
  server.options.overloadCloseOnReject = closeOnReject
  server.overloadAdaptiveBacklogLimit = server.options.overloadMaxLoopBacklogBytes
  server.overloadAdaptivePendingLimit = server.options.overloadMaxPendingResponses
  server.overloadAdaptiveRejectStreak = 0
  server.overloadAdaptiveAcceptStreak = 0

## Configure bounded closed-loop adaptive overload tuning with bounded limits
proc setAdaptiveOverloadController*(
  server: HttpServer,
  enabled: bool = true,
  minBacklogBytes: int = DefaultOverloadAdaptiveMinBacklogBytes,
  maxBacklogBytes: int = 0,
  minPendingResponses: int = DefaultOverloadAdaptiveMinPendingResponses,
  maxPendingResponses: int = 0,
  tightenStepPercent: int = DefaultOverloadAdaptiveTightenStepPercent,
  relaxStepPercent: int = DefaultOverloadAdaptiveRelaxStepPercent,
  cooldownRequests: int = DefaultOverloadAdaptiveCooldownRequests
) =
  ## Configure bounded closed-loop overload tuning behavior.
  server.options.overloadAdaptiveEnabled = enabled
  server.options.overloadAdaptiveMinBacklogBytes = max(1, minBacklogBytes)
  server.options.overloadAdaptiveMaxBacklogBytes = max(0, maxBacklogBytes)
  server.options.overloadAdaptiveMinPendingResponses = max(1, minPendingResponses)
  server.options.overloadAdaptiveMaxPendingResponses = max(0, maxPendingResponses)
  server.options.overloadAdaptiveTightenStepPercent = max(1, min(90, tightenStepPercent))
  server.options.overloadAdaptiveRelaxStepPercent = max(1, min(90, relaxStepPercent))
  server.options.overloadAdaptiveCooldownRequests = max(1, cooldownRequests)
  server.overloadAdaptiveBacklogLimit = server.options.overloadMaxLoopBacklogBytes
  server.overloadAdaptivePendingLimit = server.options.overloadMaxPendingResponses
  server.overloadAdaptiveRejectStreak = 0
  server.overloadAdaptiveAcceptStreak = 0

## Configure the socket tuning policy applied to accepted sockets, best effort
proc setSocketTunables*(
  server: HttpServer,
  noDelay: bool = true,
  keepAlive: bool = true,
  keepAliveSeconds: int = 60,
  fastOpen: bool = false,
  sendBufferBytes: int = 0,
  recvBufferBytes: int = 0,
  notSentLowWaterBytes: int = 0,
  deferAcceptSeconds: int = 0,
  incomingCpu: int = -1,
  exclusivePort: bool = false,
  epollExclusive: bool = false,
  epollEdgeTrigger: bool = false
) =
  ## Configure socket tuning policy (best effort, platform-dependent).
  server.options.socketNoDelay = noDelay
  server.options.socketKeepAlive = keepAlive
  server.options.socketKeepAliveSeconds = max(1, keepAliveSeconds)
  server.options.socketFastOpen = fastOpen
  server.options.socketSendBufferBytes = max(0, sendBufferBytes)
  server.options.socketRecvBufferBytes = max(0, recvBufferBytes)
  server.options.socketNotSentLowWaterBytes = max(0, notSentLowWaterBytes)
  server.options.socketDeferAcceptSeconds = max(0, deferAcceptSeconds)
  server.options.socketIncomingCpu = incomingCpu
  server.options.listenExclusivePort = exclusivePort
  server.options.listenEpollExclusive = epollExclusive
  server.options.listenEpollEdgeTrigger = epollEdgeTrigger

## Configure websocket-specific socket buffer and not-sent low-water tunables
proc setWsSocketTunables*(
  server: HttpServer,
  recvBufferBytes: int = 0,
  sendBufferBytes: int = 0,
  notSentLowWaterBytes: int = 0
) =
  server.options.wsSocketRecvBufferBytes = max(0, recvBufferBytes)
  server.options.wsSocketSendBufferBytes = max(0, sendBufferBytes)
  server.options.wsSocketNotSentLowWaterBytes = max(0, notSentLowWaterBytes)

## Return the total number of request parse errors observed by the server
proc getParserErrorCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsParserErrors

## Return the total number of overload-rejected connections
proc getOverloadRejectCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsOverloadRejects

## Return the number of overload rejections caused by loop backlog limits
proc getOverloadRejectBacklogCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsOverloadRejectBacklog

## Return the number of overload rejections caused by pending response limits
proc getOverloadRejectPendingCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsOverloadRejectPending

## Return the total number of socket write retry attempts
proc getWriteRetryCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsWriteRetries

## Return the number of socket tunables successfully applied
proc getSocketTunableAppliedCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsSocketTunablesApplied

## Return the number of socket tunables unsupported on this platform
proc getSocketTunableUnsupportedCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsSocketTunablesUnsupported

## Return the number of socket tunables that failed to apply
proc getSocketTunableFailedCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsSocketTunablesFailed

## Return the total number of writes dropped due to socket backpressure
proc getBackpressureDropCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsBackpressureDrops

## Return the total number of websocket high-water threshold events
proc getBackpressureHighWaterEventCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsBackpressureHighWaterEvents

## Return the number of body spill tasks enqueued to the offload worker
proc getSpillOffloadEnqueuedCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsSpillOffloadEnqueued

## Return the number of body spill tasks dropped due to offload queue limits
proc getSpillOffloadDroppedCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsSpillOffloadDropped

## Return the number of cross-thread defer callbacks rerouted into the queue
proc getCrossThreadDeferReroutedCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsCrossThreadDeferRerouted

## Return the number of cross-thread defer policy violations observed
proc getCrossThreadDeferViolationCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsCrossThreadDeferViolations

## Return the number of cross-thread defer callbacks dropped for queue overflow
proc getCrossThreadDeferDroppedCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsCrossThreadDeferDropped

## Return the total number of socket close attempts
proc getSocketCloseAttemptCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsSocketCloseAttempts

## Return the number of socket close attempts that failed
proc getSocketCloseFailureCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsSocketCloseFailures

## Return a snapshot of the per-outcome socket close counters
proc socketCloseOutcomeSnapshot*(server: HttpServer): FastMap[int64] =
  if server == nil or server.closeOutcomeCounts == nil:
    result = newFastMap[int64]()
    discard result.reserve(8)
  else:
    result = server.closeOutcomeCounts

## Return the number of connections drained during graceful shutdown
proc getShutdownDrainedConnectionCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsShutdownDrainedConnections

## Return the number of connections force-closed during shutdown
proc getShutdownForcedConnectionCount*(server: HttpServer): int64 {.inline.} =
  if server == nil: return 0
  server.metricsShutdownForcedConnections

## Set the callback fired when graceful shutdown starts
proc onShutdown*(server: HttpServer, callback: ShutdownCallback) =
  ## Set the shutdown callback
  server.shutdownCallback = callback

## Set the callback fired after the event loop stops and cleanup is complete
proc onStop*(server: HttpServer, callback: ShutdownCallback) =
  ## Set callback fired after event loop stops and cleanup is complete.
  server.stopCallback = callback

## Return the current number of active connections
proc getConnectionCount*(server: HttpServer): int =
  ## Get current number of active connections
  server.connectionCount

## Return the current number of active WebSocket connections
proc getWebSocketCount*(server: HttpServer): int =
  ## Get current number of active WebSocket connections
  server.websockets.len

# Timer callback for uSockets
proc onTimerFire(timer: UsTimerPtr) {.cdecl, used.} =
  let server = resolveServerFromTimer(timer)
  if server != nil and server.timerCallback != nil:
    try:
      server.timerCallback()
    except CatchableError as err:
      server.emitServerPanic("timerCallback", err.msg)
    except Defect as defect:
      reportEscapedDefect("timerCallback", defect, server)

proc onInternalTimerFire(timer: UsTimerPtr) {.cdecl, used.} =
  let server = resolveServerFromTimer(timer)
  if server != nil and server.internalTimerCallback != nil:
    try:
      server.internalTimerCallback()
    except CatchableError as err:
      server.emitServerPanic("internalTimerCallback", err.msg)
    except Defect as defect:
      reportEscapedDefect("internalTimerCallback", defect, server)

proc onDateHeaderTimerFire(timer: UsTimerPtr) {.cdecl, used.} =
  try:
    let server = resolveServerFromTimer(timer)
    if server != nil:
      refreshCachedDateHeader(server)
  except Defect as defect:
    reportEscapedDefect("dateHeaderTimer", defect)
  except CatchableError as err:
    reportEscapedError("dateHeaderTimer", err)

proc runWsKeepalive(server: HttpServer) {.inline.} =
  if server == nil or server.websockets.len == 0:
    if server != nil:
      server.wsKeepaliveCursor = 0
    return

  if server.wsKeepaliveCursor < 0 or server.wsKeepaliveCursor >= server.websockets.len:
    server.wsKeepaliveCursor = 0

  let initialLen = server.websockets.len
  var processed = 0
  while processed < initialLen and server.websockets.len > 0:
    if server.wsKeepaliveCursor >= server.websockets.len:
      server.wsKeepaliveCursor = 0
    let idx = server.wsKeepaliveCursor
    let ws = server.websockets[idx]
    inc processed

    if ws != nil and ws.isOpen and ws.socket != nil:
      let key = ws.wsKey()
      if key.len == 0 or server.websocketSet == nil or server.websocketSet.contains(key):
        ws.ping()

    # removeTrackedWebSocket uses swap-delete. If ping/close handling removed
    # the current socket, keep the cursor at this index so the swapped-in socket
    # is not skipped; otherwise advance to the next entry without snapshotting.
    if idx < server.websockets.len and server.websockets[idx] == ws:
      inc server.wsKeepaliveCursor
    if server.wsKeepaliveCursor >= server.websockets.len:
      server.wsKeepaliveCursor = 0

# WebSocket keepalive timer callback
proc onWsKeepaliveFire(timer: UsTimerPtr) {.cdecl, used.} =
  try:
    runWsKeepalive(resolveServerFromTimer(timer))
  except Defect as defect:
    reportEscapedDefect("wsKeepaliveTimer", defect)
  except CatchableError as err:
    reportEscapedError("wsKeepaliveTimer", err)

# Signal handler state.
# First signal triggers graceful shutdown; repeated signal forces immediate exit.
var shutdownRequested: Atomic[bool]
var forceExitRequested: Atomic[bool]

proc loadShutdownRequested(): bool {.inline.} =
  shutdownRequested.load(moAcquire)

proc loadForceExitRequested(): bool {.inline.} =
  forceExitRequested.load(moAcquire)

proc setShutdownRequested(value: bool) {.inline.} =
  shutdownRequested.store(value, moRelease)

proc setForceExitRequested(value: bool) {.inline.} =
  forceExitRequested.store(value, moRelease)

proc resetShutdownSignalFlags() {.inline.} =
  setShutdownRequested(false)
  setForceExitRequested(false)

proc markShutdownSignalRequested() {.inline.} =
  setShutdownRequested(true)
  setForceExitRequested(true)

proc closeWebSockets(server: HttpServer, code: int) =
  if server == nil or server.websockets.len == 0:
    if server != nil:
      if server.websocketIndex != nil:
        server.websocketIndex.clear()
      if server.websocketSet != nil:
        server.websocketSet.clear()
      if server.topicIndex != nil:
        server.topicIndex.clear()
      server.topicNames.setLen(0)
      server.topicSubscribers.setLen(0)
      server.wsDrainQueue.setLen(0)
      server.wsKeepaliveCursor = 0
      if server.wsDrainQueued != nil:
        server.wsDrainQueued.clear()
    return
  let snapshot = server.websockets
  for ws in snapshot:
    if ws != nil and ws.isOpen:
      ws.close(code)
  server.websockets.setLen(0)
  server.wsKeepaliveCursor = 0
  if server.websocketIndex != nil:
    server.websocketIndex.clear()
  if server.websocketSet != nil:
    server.websocketSet.clear()
  if server.topicIndex != nil:
    server.topicIndex.clear()
  server.topicNames.setLen(0)
  server.topicSubscribers.setLen(0)
  server.wsDrainQueue.setLen(0)
  if server.wsDrainQueued != nil:
    server.wsDrainQueued.clear()

proc finalizeShutdownResources(server: HttpServer, forced: bool) =
  if server == nil:
    return
  if forced:
    let remaining = max(0, server.connectionCount)
    if remaining > 0:
      server.metricsShutdownForcedConnections = max(
        server.metricsShutdownForcedConnections,
        int64(remaining)
      )
  closeWebSockets(server, 1001)
  if forced and server.context != nil:
    us_socket_context_close(server.ssl.toInt, server.context)
    server.listenSocket = nil

  # Stop recurring timers so the loop can exit quickly.
  if server.timer != nil:
    us_timer_close(server.timer)
    server.timer = nil
  if server.internalTimer != nil:
    us_timer_close(server.internalTimer)
    server.internalTimer = nil
  if server.dateHeaderTimer != nil:
    us_timer_close(server.dateHeaderTimer)
    server.dateHeaderTimer = nil
  if server.wsKeepaliveTimer != nil:
    us_timer_close(server.wsKeepaliveTimer)
    server.wsKeepaliveTimer = nil
  if server.shutdownPollTimer != nil:
    us_timer_close(server.shutdownPollTimer)
    server.shutdownPollTimer = nil

  when compileOption("threads"):
    stopSpillOffloadWorker(server)

  # When the server owns a running loop, defer context destruction until
  # cleanupServer runs after us_loop_run returns. Freeing the context from a
  # socket/deferred callback can invalidate poll state still being unwound by
  # epoll/kqueue.
  if server.loopOwnerBound:
    return

  # Closing context closes tracked sockets and allows non-running loops to
  # quiesce immediately.
  if server.context != nil:
    us_socket_context_free(server.ssl.toInt, server.context)
    server.context = nil

proc beginShutdown(server: HttpServer) =
  if server == nil:
    return

  if not server.isShuttingDown:
    server.isShuttingDown = true
    let startedAtMs = getCachedEpochMs()
    server.shutdownStartedAtMs = if startedAtMs > 0: startedAtMs else: nowEpochMs()
    server.shutdownConnectionSnapshot = max(0, server.connectionCount)
    let drainWindowMs =
      if server.options.gracefulShutdownDrainMs > 0:
        server.options.gracefulShutdownDrainMs
      else:
        DefaultGracefulShutdownDrainMs
    server.shutdownForceCloseAtMs = server.shutdownStartedAtMs + int64(max(0, drainWindowMs))
    if server.shutdownCallback != nil:
      try:
        server.shutdownCallback()
      except CatchableError as err:
        server.emitServerPanic("shutdownCallback", err.msg)

  for entry in server.h2Connections:
    if entry.conn != nil and entry.conn.active and not entry.conn.sentGoaway:
      h2SendGoaway(entry.conn, h2p.ecNoError, entry.ssl, entry.socket)

  when compileOption("threads"):
    withLock(server.crossThreadDeferLock):
      server.crossThreadDeferAccepting = false

  if server.listenSocket != nil:
    us_listen_socket_close(server.ssl.toInt, server.listenSocket)
    server.listenSocket = nil

  let drainedNow = max(0, server.shutdownConnectionSnapshot - server.connectionCount)
  if int64(drainedNow) > server.metricsShutdownDrainedConnections:
    server.metricsShutdownDrainedConnections = int64(drainedNow)

  if server.connectionCount <= 0:
    server.metricsShutdownDrainedConnections = max(
      server.metricsShutdownDrainedConnections,
      int64(server.shutdownConnectionSnapshot)
    )
    finalizeShutdownResources(server, forced = false)
    when defined(macosx):
      if server.loopOwnerBound:
        CFRunLoopStop(CFRunLoopGetCurrent())
    return

  let cachedNowMs = getCachedEpochMs()
  let nowMs = if cachedNowMs > 0: cachedNowMs else: nowEpochMs()
  if nowMs >= server.shutdownForceCloseAtMs:
    finalizeShutdownResources(server, forced = true)

proc cleanupServer(server: HttpServer) =
  if server == nil:
    return
  if server.cleanupCompleted:
    return
  server.cleanupCompleted = true
  when compileOption("threads"):
    withLock(server.crossThreadDeferLock):
      server.crossThreadDeferAccepting = false
      server.crossThreadDeferWakeClosing = true
    server.waitForCrossThreadWakeRefs()
  if server.timer != nil:
    us_timer_close(server.timer)
    server.timer = nil
  if server.internalTimer != nil:
    us_timer_close(server.internalTimer)
    server.internalTimer = nil
  if server.dateHeaderTimer != nil:
    us_timer_close(server.dateHeaderTimer)
    server.dateHeaderTimer = nil
  if server.wsKeepaliveTimer != nil:
    us_timer_close(server.wsKeepaliveTimer)
    server.wsKeepaliveTimer = nil
  if server.shutdownPollTimer != nil:
    us_timer_close(server.shutdownPollTimer)
    server.shutdownPollTimer = nil
  when compileOption("threads"):
    stopSpillOffloadWorker(server)
    withLock(server.crossThreadDeferLock):
      server.crossThreadDeferAccepting = false
      server.crossThreadDeferWakeClosing = true
      server.crossThreadDeferQueue.setLen(0)
      server.crossThreadDeferPreQueue.setLen(0)
      server.crossThreadDeferWakePending = false
  if server.listenSocket != nil:
    us_listen_socket_close(server.ssl.toInt, server.listenSocket)
    server.listenSocket = nil
  if server.context != nil:
    us_socket_context_free(server.ssl.toInt, server.context)
    server.context = nil
  if server.loop != nil:
    us_loop_free(server.loop)
    server.loop = nil
  if server.websocketIndex != nil:
    server.websocketIndex.close()
    server.websocketIndex = nil
  if server.websocketSet != nil:
    server.websocketSet.close()
    server.websocketSet = nil
  if server.topicIndex != nil:
    server.topicIndex.close()
    server.topicIndex = nil
  if server.wsDrainQueued != nil:
    server.wsDrainQueued.close()
    server.wsDrainQueued = nil
  server.websockets.setLen(0)
  server.topicNames.setLen(0)
  server.topicSubscribers.setLen(0)
  server.wsDrainQueue.setLen(0)
  server.socketDataRoots.clear()

proc onShutdownPollFire(timer: UsTimerPtr) {.cdecl, used.} =
  try:
    let server = resolveServerFromTimer(timer)
    if server != nil and (loadShutdownRequested() or server.isShuttingDown):
      beginShutdown(server)
  except Defect as defect:
    reportEscapedDefect("shutdownPollTimer", defect)
  except CatchableError as err:
    reportEscapedError("shutdownPollTimer", err)

when defined(windows):
  type
    HandlerRoutine = proc(dwCtrlType: uint32): int32 {.stdcall.}

  proc setConsoleCtrlHandler(handlerRoutine: HandlerRoutine, add: int32): int32
    {.importc: "SetConsoleCtrlHandler", stdcall, dynlib: "kernel32".}

  const
    CTRL_C_EVENT = 0'u32
    CTRL_BREAK_EVENT = 1'u32
    CTRL_CLOSE_EVENT = 2'u32

  proc windowsSignalHandler(dwCtrlType: uint32): int32 {.stdcall.} =
    if dwCtrlType in [CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT]:
      if loadForceExitRequested():
        quit(130)
      markShutdownSignalRequested()
      return 1  # Handled
    return 0  # Not handled

else:
  proc handleSignal(sig: cint) {.noconv.} =
    if loadForceExitRequested():
      # Force process termination on repeated interrupt if graceful shutdown stalls.
      if sig == SIGTERM:
        exitnow(143)
      else:
        exitnow(130)
    markShutdownSignalRequested()

proc computeListenOptions(server: HttpServer): cint {.inline.} =
  if server == nil:
    return LibusListenOptionDefault.cint
  var options = LibusListenOptionDefault
  if server.options.listenExclusivePort:
    options = options or LibusListenOptionExclusivePort
  if server.options.listenEpollExclusive:
    options = options or LibusListenOptionEpollExclusive
  if server.options.listenEpollEdgeTrigger:
    options = options or LibusListenOptionEpollEdgeTrigger
  if server.options.socketFastOpen:
    options = options or LibusListenOptionTcpFastOpen
  options.cint

proc bindTimerServer(timer: UsTimerPtr, server: HttpServer) {.inline, used.} =
  if timer == nil or server == nil:
    return
  let ext = us_timer_ext(timer)
  storeServerExt(ext, server)

## Verify the GCD backend requirement that the server loop runs on the process main thread
proc assertMacosGcdServerMainThread*(operation: string) =
  ## The uSockets GCD backend dispatches timers and socket sources on the
  ## process main queue. Running the loop from a spawned thread strands events.
  when defined(macosx) and defined(LIBUS_USE_GCD):
    if pthread_main_np() == 0.cint:
      raise newException(ValueError, operation & ": " & MacosGcdServerMainThreadError)
  else:
    discard operation

## Create the event loop and listening socket, then start accepting connections
proc listen*(server: HttpServer, host: string, port: int, callback: proc(success: bool) = nil) =
  ## Start listening on the specified host and port
  template fireListenCallback(success: bool) =
    if callback != nil:
      try:
        callback(success)
      except CatchableError as err:
        server.emitServerPanic("listenCallback", err.msg)

  when defined(posix):
    installSignalHandlers()

  assertMacosGcdServerMainThread("HttpServer.listen")
  server.host = host
  server.port = port
  server.cleanupCompleted = false
  server.isShuttingDown = false
  resetShutdownSignalFlags()
  when compileOption("threads"):
    withLock(server.crossThreadDeferLock):
      server.crossThreadDeferAccepting = true
      server.crossThreadDeferWakeClosing = false
      server.crossThreadDeferWakeRefs = 0
      server.crossThreadDeferQueue.setLen(0)
      server.crossThreadDeferPreQueue.setLen(0)
      server.crossThreadDeferWakePending = false
      server.crossThreadDeferViolationWarned = false
      server.crossThreadDeferOverflowWarned = false

  # Create event loop
  # kqueue/epoll backend calls pre/post callbacks unconditionally.
  # Always bind shim callbacks so internal deferred/drain queues are flushed
  # even when user pre/post hooks are not configured.
  when defined(macosx):
    server.loop = us_create_loop(nil, onLoopWake, onLoopPre, onLoopPost, sizeof(pointer).cuint)
  else:
    server.loop = us_create_loop(nil, onLoopNoop, onLoopPre, onLoopPost, sizeof(pointer).cuint)
  if server.loop == nil:
    if callback != nil:
      try:
        callback(false)
      except CatchableError as err:
        server.emitServerPanic("listenCallback", err.msg)
    return
  let loopExt = us_loop_ext(server.loop)
  storeServerExt(loopExt, server)

  # Create socket context
  let options = defaultSocketContextOptions()
  server.context = us_create_socket_context(server.ssl.toInt, server.loop, sizeof(pointer).cint, options)
  if server.context == nil:
    us_loop_free(server.loop)
    server.loop = nil
    server.context = nil
    server.listenSocket = nil
    if callback != nil:
      try:
        callback(false)
      except CatchableError as err:
        server.emitServerPanic("listenCallback", err.msg)
    return

  # Set up callbacks
  us_socket_context_on_open(server.ssl.toInt, server.context, onSocketOpen)
  us_socket_context_on_close(server.ssl.toInt, server.context, onSocketClose)
  us_socket_context_on_data(server.ssl.toInt, server.context, onSocketData)
  us_socket_context_on_writable(server.ssl.toInt, server.context, onSocketWritable)
  us_socket_context_on_timeout(server.ssl.toInt, server.context, onSocketTimeout)
  us_socket_context_on_end(server.ssl.toInt, server.context, onSocketEnd)

  # Store server reference in context extension for callbacks
  let contextExt = us_socket_context_ext(server.ssl.toInt, server.context)
  storeServerExt(contextExt, server)

  # Start listening
  let listenOptions = computeListenOptions(server)
  server.listenSocket = us_socket_context_listen(
    server.ssl.toInt,
    server.context,
    host.cstring,
    port.cint,
    listenOptions,
    sizeof(pointer).cint
  )

  if server.listenSocket == nil:
    us_socket_context_free(server.ssl.toInt, server.context)
    server.context = nil
    us_loop_free(server.loop)
    server.loop = nil
    server.listenSocket = nil
    if callback != nil:
      try:
        callback(false)
      except CatchableError as err:
        server.emitServerPanic("listenCallback", err.msg)
    return

  applyListenSocketTunables(server)

  # Create timer if callback is set
  if server.timerCallback != nil:
    server.timer = us_create_timer(server.loop, 0, sizeof(pointer).cuint)
    if server.timer != nil:
      bindTimerServer(server.timer, server)
      let intervalMs = if server.timerIntervalMs > 0: server.timerIntervalMs else: 1000
      us_timer_set(server.timer, onTimerFire, intervalMs.cint, intervalMs.cint)
    else:
      server.timer = nil

  # Internal framework timer (separate channel from user timer)
  if server.internalTimerCallback != nil:
    server.internalTimer = us_create_timer(server.loop, 0, sizeof(pointer).cuint)
    if server.internalTimer != nil:
      bindTimerServer(server.internalTimer, server)
      let intervalMs = if server.internalTimerIntervalMs > 0: server.internalTimerIntervalMs else: 1000
      us_timer_set(server.internalTimer, onInternalTimerFire, intervalMs.cint, intervalMs.cint)
    else:
      server.internalTimer = nil

  # Keep RFC IMF-fixdate cached off the request hot path.
  refreshCachedDateHeader(server)
  server.dateHeaderTimer = us_create_timer(server.loop, 0, sizeof(pointer).cuint)
  if server.dateHeaderTimer != nil:
    bindTimerServer(server.dateHeaderTimer, server)
    us_timer_set(server.dateHeaderTimer, onDateHeaderTimerFire, 1000.cint, 1000.cint)

  let wsInterval = server.options.wsKeepaliveInterval

  if wsInterval > 0:
    server.wsKeepaliveTimer = us_create_timer(server.loop, 0, sizeof(pointer).cuint)
    if server.wsKeepaliveTimer != nil:
      bindTimerServer(server.wsKeepaliveTimer, server)
      us_timer_set(server.wsKeepaliveTimer, onWsKeepaliveFire, wsInterval.cint, wsInterval.cint)

  # Poll signal flag from inside the event loop to keep shutdown operations safe.
  if server.options.gracefulShutdown:
    server.shutdownPollTimer = us_create_timer(server.loop, 0, sizeof(pointer).cuint)
    if server.shutdownPollTimer != nil:
      bindTimerServer(server.shutdownPollTimer, server)
      us_timer_set(server.shutdownPollTimer, onShutdownPollFire, 25, 25)

  # Set up signal handlers for graceful shutdown
  if server.options.gracefulShutdown:
    when defined(windows):
      discard setConsoleCtrlHandler(windowsSignalHandler, 1)
    else:
      discard signal(SIGINT, handleSignal)
      discard signal(SIGTERM, handleSignal)

  if server.startCallback != nil:
    try:
      server.startCallback()
    except CatchableError as err:
      server.emitServerPanic("startCallback", err.msg)

  fireListenCallback(true)

  if server.timerCallback != nil and server.timer == nil:
    server.timer = us_create_timer(server.loop, 0, sizeof(pointer).cuint)
    if server.timer != nil:
      bindTimerServer(server.timer, server)
      let intervalMs = if server.timerIntervalMs > 0: server.timerIntervalMs else: 1000
      us_timer_set(server.timer, onTimerFire, intervalMs.cint, intervalMs.cint)

  if server.internalTimerCallback != nil and server.internalTimer == nil:
    server.internalTimer = us_create_timer(server.loop, 0, sizeof(pointer).cuint)
    if server.internalTimer != nil:
      bindTimerServer(server.internalTimer, server)
      let intervalMs = if server.internalTimerIntervalMs > 0: server.internalTimerIntervalMs else: 1000
      us_timer_set(server.internalTimer, onInternalTimerFire, intervalMs.cint, intervalMs.cint)

proc applyThreadSchedulingHints(server: HttpServer) =
  when defined(macosx):
    if server != nil and server.options.macosHighQos:
      discard pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)

## Run the event loop until shutdown, then run cleanup
proc run*(server: HttpServer) =
  ## Run the event loop (blocking)
  if server == nil:
    return
  assertMacosGcdServerMainThread("HttpServer.run")
  if server.loop == nil or server.context == nil:
    return
  applyThreadSchedulingHints(server)
  server.bindLoopOwner()
  us_loop_run(server.loop)
  if server.stopCallback != nil:
    try:
      server.stopCallback()
    except CatchableError as err:
      server.emitServerPanic("stopCallback", err.msg)
  cleanupServer(server)

## Initiate graceful shutdown of the server
proc shutdown*(server: HttpServer) =
  ## Initiate graceful shutdown
  setShutdownRequested(true)
  if server.scheduleShutdownOnOwnerLoop():
    return
  if server.loop == nil or server.shutdownPollTimer == nil:
    beginShutdown(server)

## Request server shutdown and force cleanup when no loop owner is running
proc close*(server: HttpServer) =
  ## Close the server and cleanup
  if server == nil:
    return
  setShutdownRequested(true)
  if server.scheduleShutdownOnOwnerLoop():
    return
  if server.loop != nil:
    us_wakeup_loop(server.loop)
  if server.loopOwnerBound and server.shutdownPollTimer != nil:
    return
  beginShutdown(server)
  if server.loop != nil:
    us_wakeup_loop(server.loop)
  if server.loop == nil or not server.loopOwnerBound:
    cleanupServer(server)
