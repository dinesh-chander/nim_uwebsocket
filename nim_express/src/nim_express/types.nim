## Core types for nim_express framework
## uWebSockets for server I/O, async for other I/O operations
## Optimized with route grouping and sync handler support

import std/[asyncdispatch, tables, strutils, json, times, atomics, os]
import nim_utils/nim_fastjson/direct_engine
import ../../../nim_usockets/src/nim_usockets
import nim_utils/helpers/fast_map
import fast_hash

export nim_usockets
export asyncdispatch, tables, json, direct_engine, times
export fast_hash

const
  ## Number of prefix buckets for dynamic route indexing.
  RoutePrefixBucketCount* = 256
  ## Default max parsed query pairs.
  DefaultMaxQueryPairs* = 128
  ## Default max query key size in bytes.
  DefaultMaxQueryKeyBytes* = 256
  ## Default max query value size in bytes.
  DefaultMaxQueryValueBytes* = 4096
  ## Default max parsed cookie pairs.
  DefaultMaxCookiePairs* = 64
  ## Default max cookie key size in bytes.
  DefaultMaxCookieKeyBytes* = 128
  ## Default max cookie value size in bytes.
  DefaultMaxCookieValueBytes* = 2048
  ## Default max JSON body size in bytes.
  DefaultMaxJsonBodyBytes* = 8 * 1024 * 1024
  ## MIME types treated as JSON.
  JsonMimeTypes* = ["application/json", "application/*+json"]
  ## Locals key set when cookie parsing is rejected.
  CookieParseRejectedKey* = "_cookie_parse_rejected"

var emptyRequestPath = ""

## Extract the MIME type token from a Content-Type value, dropping parameters.
proc contentTypeToken*(contentType: string): string {.inline.} =
  let semicolon = contentType.find(';')
  if semicolon >= 0:
    return contentType[0..<semicolon].strip().toLowerAscii()
  contentType.strip().toLowerAscii()

## Check whether an actual MIME type matches an expected glob-style pattern.
proc mimeMatches*(actual: string, expected: string): bool {.inline.} =
  if expected == "*/*":
    return true
  if actual == expected:
    return true
  let slash = expected.find('/')
  if slash <= 0 or slash + 1 >= expected.len:
    return false
  if expected.startsWith("application/*+"):
    if not actual.startsWith("application/"):
      return false
    let plus = actual.rfind('+')
    if plus < 0 or plus + 1 >= actual.len:
      return false
    let suffix = expected[14..^1]
    return actual[plus + 1..^1] == suffix
  if expected[slash + 1] == '*':
    return slash + 2 == expected.len and actual.startsWith(expected[0..slash])
  false

## Return true when contentType matches any allowed MIME pattern.
proc matchesAnyMime*(contentType: string, allowed: openArray[string]): bool =
  if contentType.len == 0:
    return false
  if allowed.len == 0:
    return true
  for candidate in allowed:
    let trimmed = candidate.strip()
    if trimmed.len == 0:
      continue
    var needsLower = false
    var i = 0
    while i < trimmed.len:
      if trimmed[i] in 'A'..'Z':
        needsLower = true
        break
      inc i
    let normalized = if needsLower: trimmed.toLowerAscii() else: trimmed
    if mimeMatches(contentType, normalized):
      return true
  false

## Return true when the Content-Type string denotes JSON.
proc isJsonContentType*(contentType: string): bool {.inline.} =
  matchesAnyMime(contentTypeToken(contentType), JsonMimeTypes)

## Return true when the borrowed Content-Type view denotes JSON.
proc isJsonContentType*(contentType: fast_map.FastStringView): bool {.inline.} =
  if contentType.len == 0 or contentType.data == nil:
    return false
  let data = cast[ptr UncheckedArray[char]](contentType.data)
  var tokenLen = contentType.len
  var i = 0
  while i < contentType.len:
    if data[i] == ';':
      tokenLen = i
      break
    inc i
  var startPos = 0
  while startPos < tokenLen and (data[startPos] == ' ' or data[startPos] == '\t'):
    inc startPos
  while tokenLen > startPos and (data[tokenLen - 1] == ' ' or data[tokenLen - 1] == '\t'):
    dec tokenLen
  let valueLen = tokenLen - startPos
  if valueLen <= 0:
    return false
  let trimmed = fast_map.FastStringView(
    data: cast[pointer](unsafeAddr data[startPos]),
    len: valueLen
  )
  if trimmed.equalsIgnoreCaseAscii("application/json"):
    return true
  if valueLen < 18:
    return false
  const prefix = "application/"
  const suffix = "+json"
  if valueLen < prefix.len + suffix.len + 1:
    return false
  for i in 0..<prefix.len:
    var a = data[startPos + i]
    var b = prefix[i]
    if a in 'A'..'Z':
      a = chr(ord(a) + 32)
    if a != b:
      return false
  let suffixStart = startPos + valueLen - suffix.len
  for i in 0..<suffix.len:
    var a = data[suffixStart + i]
    var b = suffix[i]
    if a in 'A'..'Z':
      a = chr(ord(a) + 32)
    if a != b:
      return false
  true

type
  ## Lifecycle state of a `Request` wrapper.
  RequestLifecycleState* = enum
    rlsActive
    rlsCancelled
    rlsReleased

  ## Reason a request was cancelled.
  RequestCancelReason* = enum
    rcrNone
    rcrTimeout
    rcrDisconnect
    rcrShutdown

  # Request wrapper with Express.js-like API
  ## Express.js-like request wrapper around a native uSockets request.
  Request* = ref object
    ## Raw uSockets request handle.
    native*: HttpRequest
    ## Lazily bound request body.
    body*: string
    ## Cached parsed JSON body.
    jsonBody*: JsonNode
    ## Request headers map.
    headers*: FastMap[string]
    ## Route path parameters.
    params*: FastMap[string]
    ## Parsed query-string parameters.
    query*: FastMap[string]
    ## Parsed cookies map.
    cookies*: FastMap[string]
    ## Per-request local storage map.
    locals*: FastMap[string]
    ## HTTP method of the request.
    methodKind*: nim_usockets.HttpMethod
    # Lazy parsing flags
    headersBound: bool
    queryBound: bool
    bodyBound: bool
    bodyReadFailed: bool
    jsonParsed: bool
    cookiesParsed: bool
    ## Whether proxy headers are trusted.
    trustProxyEnabled*: bool
    ## Number of trusted proxy hops.
    trustedProxyHopCount*: int16
    ## Comma-separated trusted proxy allowlist.
    trustedProxyAllowlist*: string
    ## Current `RequestLifecycleState`.
    lifecycleState*: RequestLifecycleState
    ## Why the request was cancelled.
    cancelReason*: RequestCancelReason
    ## Hook invoked when the request is cancelled.
    cancelHook*: proc(req: Request, reason: RequestCancelReason) {.closure.}
    ## Whether the cancel hook already fired.
    cancelNotified*: bool
    ## Monotonic correlation sequence number.
    correlationSeq*: uint64
    ## Cached hex correlation id.
    correlationIdCached*: string
    ## Whether the correlation id was generated.
    correlationIdGenerated*: bool
    ## Monotonic request sequence number.
    requestSeq*: uint64
    ## Request timeout budget in milliseconds.
    timeoutBudgetMs*: int
    ## Epoch ms when the timeout budget started.
    timeoutStartedAtMs*: int64
    ownsNativeRequestCleanup: bool

  # Response wrapper with Express.js-like API
  ## Express.js-like response wrapper around a native uSockets response.
  Response* = ref object
    ## Raw uSockets response handle.
    native*: HttpResponse
    ## The `Request` this response belongs to.
    request*: Request
    ## The owning `ExpressApp`.
    app*: ExpressApp
    ## Response headers map.
    headers*: FastMap[string]
    ## Accumulated Set-Cookie headers.
    setCookies*: seq[string]
    ## Per-response local storage map.
    locals*: FastMap[string]
    ## Directory for view templates.
    viewsDir*: string
    ## View template file extension.
    viewExt*: string
    ## HTTP method of the originating request.
    requestMethodKind*: nim_usockets.HttpMethod
    ## HTTP status code to send.
    statusCode*: int
    ## Enable response compression for this response.
    compress*: bool  # Enable response compression for this response
    ## Selected content-encoding token (zstd/br/gzip).
    compressEncoding*: string # Selected content-encoding token (zstd/br/gzip)
    ## Whether headers were initialized.
    headersInited*: bool
    ## Whether the response has been finalized.
    finished*: bool
    ## Scratch buffer for serialized headers.
    headerBuf*: string
    ## Count of writes dropped after finalize.
    droppedLateWrites*: int
    ## Hooks run before the response is finalized.
    beforeFinalizeHooks*: seq[proc() {.closure.}]
    ## Token invalidating stale async writes.
    lifecycleToken*: uint64

  ## Immutable snapshot of request data for deferred inspection.
  RequestSnapshot* = object
    ## Captured HTTP method.
    methodKind*: nim_usockets.HttpMethod
    ## Captured request path.
    path*: string
    ## Captured raw query string.
    queryStringRaw*: string
    ## Captured request body.
    body*: string
    ## Captured headers map.
    headers*: FastMap[string]
    ## Captured route params.
    params*: FastMap[string]
    ## Captured query params.
    query*: FastMap[string]
    ## Captured cookies.
    cookies*: FastMap[string]
    ## Captured locals map.
    locals*: FastMap[string]
    ## Captured correlation id.
    correlationId*: string
    ## Captured request sequence number.
    requestSeq*: uint64
    ## Captured cancel reason.
    cancelReason*: RequestCancelReason

  # Handler types - SYNC (fast path) and ASYNC (for I/O)
  ## Synchronous request handler (fast path).
  SyncHandler* = proc(req: Request, res: Response) {.closure.}
  ## Asynchronous request handler for I/O-bound work.
  AsyncHandler* = proc(req: Request, res: Response): Future[void]

  # Middleware types
  ## Continuation that advances the middleware chain.
  NextProc* = proc(): Future[void]
  ## Asynchronous middleware receiving a `next` continuation.
  AsyncMiddleware* = proc(req: Request, res: Response, next: NextProc): Future[void]
  ## Asynchronous error handler invoked on raised exceptions.
  AsyncErrorHandler* = proc(err: ref Exception, req: Request, res: Response): Future[void]
  ## Synchronous middleware receiving a `next` continuation.
  SyncNextMiddleware* = proc(req: Request, res: Response, next: proc() {.closure.}) {.closure.}

  # Lifecycle and policy hooks
  ## Hook run during startup warmup.
  StartupWarmupHook* = proc(app: ExpressApp) {.closure.}
  ## Hook fired when a connection opens.
  ConnectionOpenHook* = proc(remoteIp: string) {.closure.}
  ## Hook fired when a connection closes.
  ConnectionCloseHook* = proc(remoteIp: string, wasWebSocket: bool) {.closure.}
  ## Hook fired at the start of request processing.
  RequestStartHook* = proc(req: Request) {.closure.}
  ## Hook fired at the end of request processing.
  RequestEndHook* = proc(req: Request, res: Response, durationMicros: int64) {.closure.}
  ## Hook fired when a route matches a request.
  RouteMatchedHook* = proc(routePattern: string, req: Request) {.closure.}
  ## Hook fired when a timeout occurs.
  TimeoutHook* = proc(kind: string, remoteIp: string) {.closure.}
  ## Hook fired on timeout with detailed metadata.
  TimeoutMetadataHook* = proc(
    kind: string,
    phase: string,
    remoteIp: string,
    requestSeq: uint64,
    isWebSocket: bool
  ) {.closure.}
  ## Hook to customize protocol-error responses.
  ProtocolErrorHook* = proc(
    statusCode: int,
    remoteIp: string
  ): tuple[statusCode: int, body: string, closeConnection: bool] {.closure.}
  ## Hook fired on generic errors.
  ErrorHook* = proc(message: string) {.closure.}
  ## Hook fired on panics.
  PanicHook* = proc(message: string) {.closure.}
  ## Hook run just before response headers are written.
  BeforeHeadersHook* = proc(req: Request, res: Response) {.closure.}
  ## Hook run before a body write.
  BeforeWriteHook* = proc(bytes: int, isWebSocket: bool) {.closure.}
  ## Hook run after a body write.
  AfterWriteHook* = proc(bytes: int, ok: bool, isWebSocket: bool) {.closure.}
  ## Hook fired on socket backpressure.
  BackpressureHook* = proc(bufferedBytes: int64, isWebSocket: bool) {.closure.}

  ## Hook deciding whether a body should be compressed.
  ShouldCompressHook* = proc(req: Request, contentType: string, bodyBytes: int): bool {.closure.}
  ## Hook selecting a compression profile name.
  SelectCompressionProfileHook* = proc(req: Request, contentType: string, bodyBytes: int): string {.closure.}
  ## Hook reporting the result of a compression pass.
  CompressionResultHook* = proc(req: Request, inBytes: int, outBytes: int, cpuMicros: int64, ratio: float) {.closure.}
  ## Hook reporting why compression was bypassed.
  CompressionBypassHook* = proc(req: Request, reason: string) {.closure.}

  ## Advice run before route matching; return false to skip.
  BeforeRouteMatchAdviceHook* = proc(req: Request, res: Response): bool {.closure.}
  ## Advice run before a route handler; return false to skip.
  BeforeHandlerAdviceHook* = proc(req: Request, res: Response, routePattern: string): bool {.closure.}
  ## Advice run after a route handler.
  AfterHandlerAdviceHook* = proc(req: Request, res: Response) {.closure.}
  ## Advice run when an error occurs in a phase.
  ErrorAdviceHook* = proc(req: Request, res: Response, phase: string, message: string) {.closure.}

  ## Category of an inspector diagnostic event.
  InspectorEventKind* = enum
    iekParseError
    iekProtocolError
    iekHandlerError
    iekBackpressureStall
    iekTimeout

  ## Diagnostic event emitted to the `InspectorHook`.
  InspectorEvent* = object
    ## Event category.
    kind*: InspectorEventKind
    ## Phase where the event occurred.
    phase*: string
    ## Request path when the event fired.
    path*: string
    ## Human-readable event message.
    message*: string
    ## Associated HTTP status code.
    statusCode*: int
    ## Correlation id of the affected request.
    correlationId*: string
    ## Remote client IP.
    remoteIp*: string

  ## Hook receiving `InspectorEvent` diagnostics.
  InspectorHook* = proc(event: InspectorEvent) {.closure.}

  ## Hook run to initialize a plugin; return false on failure.
  PluginInitHook* = proc(): bool {.closure.}
  ## Hook run to shut down a plugin.
  PluginShutdownHook* = proc() {.closure.}

  ## Declarative definition of a framework plugin.
  PluginDefinition* = object
    ## Unique plugin identifier.
    id*: string
    ## Ids of plugins this one depends on.
    dependsOn*: seq[string]
    ## Plugin configuration JSON.
    config*: JsonNode
    ## Initialization hook.
    initHook*: PluginInitHook
    ## Shutdown hook.
    shutdownHook*: PluginShutdownHook

  ## One entry in the route manifest dumped at startup.
  RouteManifestEntry* = object
    ## Route HTTP method.
    httpMethod*: string
    ## Route path pattern.
    pattern*: string
    ## Handler kind (sync/async).
    handlerKind*: string
    ## Whether the route is dynamic.
    dynamic*: bool
    ## Number of compiled middlewares.
    middlewareCount*: int
    ## Whether the route is shadowed by another.
    shadowed*: bool
    ## Manifest warning, if any.
    warning*: string

  ## Tuning knobs for response/WebSocket compression.
  CompressionPolicyConfig* = object
    ## Whether compression is enabled.
    enabled*: bool
    ## Minimum body size to compress.
    minBytes*: int
    ## Minimum savings ratio to keep compression.
    minSavingsRatio*: float
    ## Compression level.
    level*: int
    ## Compression memory level.
    memLevel*: int
    ## Compression window size bits.
    windowBits*: int
    ## Disable server context takeover (permessage-deflate).
    serverNoContextTakeover*: bool
    ## Disable client context takeover (permessage-deflate).
    clientNoContextTakeover*: bool
    ## Reset compression context every N messages.
    resetContextEveryNMessages*: int
    ## Max compression CPU microseconds per second.
    maxCompressMicrosPerSecond*: int
    ## Disable compression above this backpressure.
    disableWhenBackpressureAboveBytes*: int
    ## Disable compression for binary payloads.
    disableForBinary*: bool
    ## Disable compression for text payloads.
    disableForText*: bool
    ## Body size above which compression is offloaded.
    offloadThresholdBytes*: int

  ## Origin of a request field during coercion.
  RequestFieldSource* = enum
    rfsQuery
    rfsParam
    rfsHeader
    rfsCookie
    rfsLocal
    rfsBody

  ## Describes a failed request-field coercion.
  RequestCoercionError* = object
    ## Source the field came from.
    source*: RequestFieldSource
    ## Field name that failed coercion.
    field*: string
    ## Raw string value that failed.
    rawValue*: string
    ## Why the coercion failed.
    reason*: string

  ## Result of coercing a request field to type `T`.
  CoercionResult*[T] = object
    ## Whether coercion succeeded.
    ok*: bool
    ## Coerced value when `ok`.
    value*: T
    ## Error detail when coercion failed.
    error*: RequestCoercionError

  ## Outcome category of an offloaded operation.
  OffloadOutcomeKind* = enum
    ookOk
    ookOffloadTimeout
    ookOffloadError

  ## Result of an offloaded operation of type `T`.
  OffloadOutcome*[T] = object
    ## Outcome category.
    kind*: OffloadOutcomeKind
    ## Operation result value on success.
    value*: T
    ## Error class on failure.
    errorClass*: string
    ## Error message on failure.
    errorMessage*: string
    ## Name of the offloaded operation.
    operation*: string
    ## Correlation id of the request.
    correlationId*: string

  # WebSocket handler types
  ## WebSocket message handler.
  WsHandler* = proc(ws: nim_usockets.WebSocket, message: string, isBinary: bool) {.closure.}
  ## Raw-pointer WebSocket message handler.
  WsRawHandler* = proc(ws: nim_usockets.WebSocket, data: pointer, dataLen: int, isBinary: bool) {.closure.}
  ## Validator deciding whether to accept a WebSocket upgrade.
  WsUpgradeValidator* = proc(req: nim_usockets.HttpRequest): bool {.closure.}
  ## Handler fired when a WebSocket opens.
  WsOpenHandler* = proc(ws: nim_usockets.WebSocket) {.closure.}
  ## Handler fired when a WebSocket closes.
  WsCloseHandler* = proc(ws: nim_usockets.WebSocket) {.closure.}
  ## Handler fired when WebSocket backpressure drains.
  WsDrainHandler* = proc(ws: nim_usockets.WebSocket, bufferedBytes: int64) {.closure.}
  ## Handler fired when a WebSocket message is dropped.
  WsDroppedHandler* = proc(ws: nim_usockets.WebSocket, payloadBytes: int, isBinary: bool) {.closure.}
  ## Handler fired when WebSocket buffer hits the high-water mark.
  WsHighWaterHandler* = proc(
    ws: nim_usockets.WebSocket,
    bufferedBytes: int64,
    action: nim_usockets.BackpressureHighWaterAction
  ) {.closure.}

  # Route can be sync or async
  ## Whether a route dispatches to a sync or async handler.
  RouteKind* = enum
    rkSync
    rkAsync

  ## A registered route with its pattern, middlewares, and handler.
  Route* = object
    ## Route path pattern.
    pattern*: string
    ## Ordered path parameter names.
    paramNames*: seq[string]
    ## Compiled async middleware chain.
    compiledMiddlewares*: seq[AsyncMiddleware]
    ## Compiled sync middleware chain.
    compiledSyncMiddlewares*: seq[SyncNextMiddleware]
    ## Whether all middlewares are synchronous.
    allMiddlewaresSync*: bool
    ## Registered async middlewares.
    middlewares*: seq[AsyncMiddleware]
    ## Registered sync middlewares.
    syncMiddlewares*: seq[SyncNextMiddleware]
    ## Whether the route contains wildcards/params.
    isDynamic*: bool
    ## Index into the method's route list.
    routeListIdx*: int32
    ## Static leading path prefix.
    staticPrefix*: string
    ## Prefix bucket key for lookup.
    prefixBucketKey*: int16
    ## First literal path segment.
    firstLiteralSegment*: string
    ## Minimum matching segment count.
    minSegmentCount*: int16
    ## Maximum matching segment count.
    maxSegmentCount*: int16
    ## Sync/async discriminator selecting the handler.
    case kind*: RouteKind
    of rkSync:
      ## Synchronous handler when `rkSync`.
      syncHandler*: SyncHandler
    of rkAsync:
      ## Asynchronous handler when `rkAsync`.
      asyncHandler*: AsyncHandler

  ## Prefix-bucketed index of dynamic routes for a method.
  DynamicRouteBuckets* = object
    anyPrefix*: seq[int32]
    byPrefix*: array[RoutePrefixBucketCount, seq[int32]]
    fallbackOrder*: seq[int32]

  # Router with method-grouped routes for O(1) method lookup
  ## Router holding method-grouped routes for O(1) method lookup.
  Router* = ref object
    ## Base path prefix for all routes.
    basePath*: string
    # Routes grouped by HTTP method for fast lookup
    ## GET routes.
    getRoutes*: seq[Route]
    ## POST routes.
    postRoutes*: seq[Route]
    ## PUT routes.
    putRoutes*: seq[Route]
    ## DELETE routes.
    deleteRoutes*: seq[Route]
    ## PATCH routes.
    patchRoutes*: seq[Route]
    ## HEAD routes.
    headRoutes*: seq[Route]
    ## OPTIONS routes.
    optionsRoutes*: seq[Route]
    # Exact static route index per method (pattern -> index in method route seq)
    ## Exact-match GET route index.
    getExactRoutes*: FastMap[int64]
    ## Exact-match POST route index.
    postExactRoutes*: FastMap[int64]
    ## Exact-match PUT route index.
    putExactRoutes*: FastMap[int64]
    ## Exact-match DELETE route index.
    deleteExactRoutes*: FastMap[int64]
    ## Exact-match PATCH route index.
    patchExactRoutes*: FastMap[int64]
    ## Exact-match HEAD route index.
    headExactRoutes*: FastMap[int64]
    ## Exact-match OPTIONS route index.
    optionsExactRoutes*: FastMap[int64]
    # First dynamic route index per method (-1 when no dynamic routes)
    ## Index of first dynamic GET route (-1 if none).
    firstDynamicGet*: int
    ## Index of first dynamic POST route (-1 if none).
    firstDynamicPost*: int
    ## Index of first dynamic PUT route (-1 if none).
    firstDynamicPut*: int
    ## Index of first dynamic DELETE route (-1 if none).
    firstDynamicDelete*: int
    ## Index of first dynamic PATCH route (-1 if none).
    firstDynamicPatch*: int
    ## Index of first dynamic HEAD route (-1 if none).
    firstDynamicHead*: int
    ## Index of first dynamic OPTIONS route (-1 if none).
    firstDynamicOptions*: int
    ## Bucketed dynamic GET routes.
    getDynamicBuckets*: DynamicRouteBuckets
    ## Bucketed dynamic POST routes.
    postDynamicBuckets*: DynamicRouteBuckets
    ## Bucketed dynamic PUT routes.
    putDynamicBuckets*: DynamicRouteBuckets
    ## Bucketed dynamic DELETE routes.
    deleteDynamicBuckets*: DynamicRouteBuckets
    ## Bucketed dynamic PATCH routes.
    patchDynamicBuckets*: DynamicRouteBuckets
    ## Bucketed dynamic HEAD routes.
    headDynamicBuckets*: DynamicRouteBuckets
    ## Bucketed dynamic OPTIONS routes.
    optionsDynamicBuckets*: DynamicRouteBuckets
    ## Whether route artifacts are compiled.
    artifactsCompiled*: bool
    ## Router-level middlewares.
    middlewares*: seq[AsyncMiddleware]
    ## Whether route mutation is locked.
    locked*: bool
    ## Reason the router was locked.
    lockReason*: string
    ## Route match cache keys.
    routeCacheKeys*: array[128, uint64]
    ## Route match cache method kinds.
    routeCacheMethodKinds*: array[128, uint8]
    ## Route match cache route indices.
    routeCacheRouteIdxs*: array[128, int32]
    ## Route match cache validity flags.
    routeCacheValid*: array[128, bool]

  # Log format
  ## Access-log output format.
  LogFormat* = enum
    lfDev       # Colored dev format
    lfCombined  # Apache combined format
    lfCommon    # Apache common format
    lfShort     # Minimal format
    lfTiny      # Ultra minimal

  ## Application log severity level.
  LogLevel* = enum
    llDebug
    llInfo
    llWarn
    llError

  ## Resolved application configuration.
  AppEnvConfig* = object
    ## Config profile name.
    profile*: string
    ## Bind host.
    host*: string
    ## Bind port.
    port*: int
    ## Trust reverse-proxy headers.
    trustProxy*: bool
    ## Number of trusted proxy hops.
    trustedProxyHops*: int
    ## Trusted proxy allowlist.
    trustedProxyAllowlist*: string
    ## Async pump interval in ms.
    asyncPumpIntervalMs*: int
    ## Max in-flight async requests.
    maxInflightAsyncRequests*: int
    ## Context pool prewarm count.
    contextPoolPrewarm*: int
    ## Enable request/response object pooling.
    requestResponsePoolingEnabled*: bool
    ## Max pending bytes per socket.
    maxPendingBytesPerSocket*: int
    ## Max request body size.
    maxBodySize*: int
    ## Connection timeout in seconds.
    connectionTimeoutSeconds*: int
    ## Max concurrent connections.
    maxConnections*: int
    ## Use minimal header parsing.
    minimalHeaderParsing*: bool
    ## Enable graceful shutdown.
    gracefulShutdown*: bool
    ## Use high QoS on macOS.
    macosHighQos*: bool
    ## TLS write-flatten threshold.
    tlsFlattenThreshold*: int
    ## Enable TCP_NODELAY.
    socketNoDelay*: bool
    ## Enable SO_KEEPALIVE.
    socketKeepAlive*: bool
    ## Keep-alive interval in seconds.
    socketKeepAliveSeconds*: int
    ## Enable TCP_FASTOPEN.
    socketFastOpen*: bool
    ## Socket send buffer size.
    socketSendBufferBytes*: int
    ## Socket receive buffer size.
    socketRecvBufferBytes*: int
    ## Low-water mark for unsent data.
    socketNotSentLowWaterBytes*: int
    ## TCP_DEFER_ACCEPT in seconds.
    socketDeferAcceptSeconds*: int
    ## Incoming socket CPU affinity.
    socketIncomingCpu*: int
    ## Enable SO_REUSEPORT exclusive mode.
    listenExclusivePort*: bool
    ## Enable epoll exclusive mode.
    listenEpollExclusive*: bool
    ## Enable epoll edge-triggered mode.
    listenEpollEdgeTrigger*: bool
    ## Response write coalescing mode.
    writeCoalesceMode*: WriteCoalesceMode
    ## Max bytes per coalesced write.
    writeCoalesceMaxBytes*: int
    ## Max responses per coalesced write.
    writeCoalesceMaxResponses*: int
    ## Throughput-mode coalesce max bytes.
    writeCoalesceThroughputMaxBytes*: int
    ## Throughput-mode coalesce max responses.
    writeCoalesceThroughputMaxResponses*: int
    ## Parse budget: requests per read.
    parseBudgetRequestsPerRead*: int
    ## Parse budget: bytes per read.
    parseBudgetBytesPerRead*: int
    ## Loop dispatch budget: requests.
    loopDispatchBudgetRequests*: int
    ## Loop dispatch budget: bytes.
    loopDispatchBudgetBytes*: int
    ## Write budget: iterations per flush.
    writeBudgetIterationsPerFlush*: int
    ## Write budget: bytes per flush.
    writeBudgetBytesPerFlush*: int
    ## Loop write budget bytes.
    loopWriteBudgetBytes*: int
    ## Overload guard: max loop backlog bytes.
    overloadMaxLoopBacklogBytes*: int
    ## Overload guard: max pending responses.
    overloadMaxPendingResponses*: int
    ## Close connection on overload reject.
    overloadCloseOnReject*: bool
    ## Enable adaptive overload control.
    overloadAdaptiveEnabled*: bool
    ## Adaptive min backlog bytes.
    overloadAdaptiveMinBacklogBytes*: int
    ## Adaptive max backlog bytes.
    overloadAdaptiveMaxBacklogBytes*: int
    ## Adaptive min pending responses.
    overloadAdaptiveMinPendingResponses*: int
    ## Adaptive max pending responses.
    overloadAdaptiveMaxPendingResponses*: int
    ## Adaptive tighten step percent.
    overloadAdaptiveTightenStepPercent*: int
    ## Adaptive relax step percent.
    overloadAdaptiveRelaxStepPercent*: int
    ## Adaptive cooldown in requests.
    overloadAdaptiveCooldownRequests*: int
    ## WebSocket keepalive interval in ms.
    wsKeepaliveIntervalMs*: int
    ## WebSocket idle timeout in seconds.
    wsIdleTimeoutSeconds*: int
    ## WebSocket max backpressure bytes.
    wsMaxBackpressureBytes*: int
    ## WebSocket backpressure high-water bytes.
    wsBackpressureHighWaterBytes*: int
    ## Action at WebSocket high-water mark.
    wsBackpressureHighWaterAction*: BackpressureHighWaterAction
    ## Enable dynamic WebSocket backpressure.
    wsDynamicBackpressureEnabled*: bool
    ## Expected WebSocket connection count.
    wsExpectedConnections*: int
    ## Expected WebSocket message size.
    wsMessageBytes*: int
    ## WebSocket queue budget bytes.
    wsQueueBudgetBytes*: int
    ## Close socket at backpressure limit.
    wsCloseOnBackpressureLimit*: bool
    ## Reset idle timeout on send.
    wsResetIdleTimeoutOnSend*: bool
    ## Enable WebSocket compression.
    wsCompressionEnabled*: bool
    ## WebSocket compression threshold bytes.
    wsCompressionThresholdBytes*: int
    ## WebSocket compression min savings bytes.
    wsCompressionMinSavingsBytes*: int
    ## Disable WebSocket compression for binary.
    wsCompressionDisableForBinary*: bool
    ## Disable WebSocket compression for text.
    wsCompressionDisableForText*: bool
    ## Bypass compression above this backpressure.
    wsCompressionBackpressureBypassBytes*: int
    ## WebSocket coalesce max bytes.
    wsWriteCoalesceMaxBytes*: int
    ## WebSocket coalesce max frames.
    wsWriteCoalesceMaxFrames*: int
    ## WebSocket receive buffer size.
    wsSocketRecvBufferBytes*: int
    ## WebSocket send buffer size.
    wsSocketSendBufferBytes*: int
    ## WebSocket unsent low-water bytes.
    wsSocketNotSentLowWaterBytes*: int
    ## Body size above which to spill to disk.
    bodySpillThresholdBytes*: int
    ## Directory for spilled bodies.
    bodySpillDir*: string
    strictConfig*: bool  ## Only gates JSON parse errors; env var overrides are applied unconditionally.
    ## Collected configuration warnings.
    configWarnings*: seq[string]

  # Express App
  ## The Express application: server, router, middlewares, and hooks.
  ExpressApp* = ref object
    ## Underlying uSockets HTTP server.
    server*: HttpServer
    ## Application router.
    router*: Router
    ## Registered async middlewares.
    middlewares*: seq[AsyncMiddleware]
    ## Registered sync middlewares.
    syncMiddlewares*: seq[SyncNextMiddleware]
    ## Middlewares in registration order.
    orderedMiddlewares*: seq[AsyncMiddleware]
    ## Compiled base async middleware chain.
    compiledBaseMiddlewares*: seq[AsyncMiddleware]
    ## Compiled base sync middleware chain.
    compiledBaseSyncMiddlewares*: seq[SyncNextMiddleware]
    ## Whether all base middlewares are sync.
    allBaseSyncMiddlewares*: bool
    ## App settings map.
    settings*: FastMap[string]
    ## Global async error handler.
    errorHandler*: AsyncErrorHandler
    ## WebSocket message handler.
    wsHandler*: WsHandler
    ## Raw WebSocket message handler.
    wsRawHandler*: WsRawHandler
    ## WebSocket upgrade validator.
    wsUpgradeValidator*: WsUpgradeValidator
    ## WebSocket open handler.
    wsOpenHandler*: WsOpenHandler
    ## WebSocket close handler.
    wsCloseHandler*: WsCloseHandler
    ## WebSocket drain handler.
    wsDrainHandler*: WsDrainHandler
    ## WebSocket dropped-message handler.
    wsDroppedHandler*: WsDroppedHandler
    ## WebSocket high-water handler.
    wsHighWaterHandler*: WsHighWaterHandler
    ## Allowed WebSocket origins.
    wsAllowedOrigins*: seq[string]
    ## Allowed WebSocket paths.
    wsAllowedPaths*: seq[string]
    ## Count of in-flight async requests.
    inflightAsyncRequests*: Atomic[int64]
    ## Async pump interval in ms.
    asyncPumpIntervalMs*: int
    ## Whether the async pump is installed.
    asyncPumpInstalled*: bool
    ## Max in-flight async requests.
    maxInflightAsyncRequests*: int
    ## Context pool prewarm count.
    contextPoolPrewarm*: int
    ## Registered startup warmup hooks.
    startupWarmupHooks*: seq[StartupWarmupHook]
    ## Index of next warmup hook to run.
    startupWarmupCursor*: int
    ## Whether warmup completed.
    startupWarmupDone*: bool
    ## Registered plugin definitions.
    plugins*: seq[PluginDefinition]
    ## Resolved plugin initialization order.
    pluginInitOrder*: seq[int]
    ## Whether plugins were initialized.
    pluginsInitialized*: bool
    ## Reason plugin init failed, if any.
    pluginInitFailedReason*: string
    ## Connection-open hook.
    connectionOpenHook*: ConnectionOpenHook
    ## Connection-close hook.
    connectionCloseHook*: ConnectionCloseHook
    ## Request-start hook.
    requestStartHook*: RequestStartHook
    ## Request-end hook.
    requestEndHook*: RequestEndHook
    ## Route-matched hook.
    routeMatchedHook*: RouteMatchedHook
    ## Before-route-match advices.
    beforeRouteMatchAdvices*: seq[BeforeRouteMatchAdviceHook]
    ## Before-handler advices.
    beforeHandlerAdvices*: seq[BeforeHandlerAdviceHook]
    ## After-handler advices.
    afterHandlerAdvices*: seq[AfterHandlerAdviceHook]
    ## Error advices.
    errorAdvices*: seq[ErrorAdviceHook]
    ## Timeout hook.
    timeoutHook*: TimeoutHook
    ## Timeout metadata hook.
    timeoutMetadataHook*: TimeoutMetadataHook
    ## Protocol-error hook.
    protocolErrorHook*: ProtocolErrorHook
    ## Error hook.
    errorHook*: ErrorHook
    ## Panic hook.
    panicHook*: PanicHook
    ## Inspector diagnostic hook.
    inspectorHook*: InspectorHook
    ## Before-headers hook.
    beforeHeadersHook*: BeforeHeadersHook
    ## Before-write hook.
    beforeWriteHook*: BeforeWriteHook
    ## After-write hook.
    afterWriteHook*: AfterWriteHook
    ## Backpressure hook.
    backpressureHook*: BackpressureHook
    ## Should-compress hook.
    shouldCompressHook*: ShouldCompressHook
    ## Compression-profile selection hook.
    selectCompressionProfileHook*: SelectCompressionProfileHook
    ## Compression-result hook.
    compressionResultHook*: CompressionResultHook
    ## Compression-bypass hook.
    compressionBypassHook*: CompressionBypassHook
    ## Compression policy configuration.
    compressionPolicy*: CompressionPolicyConfig
    ## Fast-path flag: has before-route-match advice.
    hasBeforeRouteMatchAdvice*: bool
    ## Fast-path flag: has before-handler advice.
    hasBeforeHandlerAdvice*: bool
    ## Fast-path flag: has after-handler advice.
    hasAfterHandlerAdvice*: bool
    ## Fast-path flag: has error advices.
    hasErrorAdvices*: bool
    ## Fast-path flag: has request-start hook.
    hasRequestStartHook*: bool
    ## Fast-path flag: has request-end hook.
    hasRequestEndHook*: bool
    ## Fast-path flag: has route-matched hook.
    hasRouteMatchedHook*: bool
    ## Fast-path flag: has connection-close hook.
    hasConnectionCloseHook*: bool
    ## Trust reverse-proxy headers.
    trustProxy*: bool
    ## Allowed Host header values.
    allowedHosts*: seq[string]
    ## Auto-generate correlation ids.
    generateCorrelationIds*: bool
    ## Whether the server has started listening.
    listenStarted*: bool
    ## Dump route manifest at startup.
    routeManifestOnStartup*: bool
    ## Embedded view templates.
    embeddedViews*: FastMap[string]
    ## Compiled embedded view plans.
    embeddedViewPlans*: FastMap[pointer]
    ## Pointer to the HTTP client registry.
    httpClientRegistryPtr*: pointer
    when defined(macosx) and compileOption("threads"):
      ## macOS async-pump wake thread.
      asyncPumpWakeThread*: Thread[pointer]
      ## Whether the wake thread is running.
      asyncPumpWakeThreadRunning*: Atomic[bool]
      ## Whether the wake thread started.
      asyncPumpWakeThreadStarted*: bool

  ## A group of routes sharing a path prefix.
  RouteGroup* = ref object
    ## The owning `ExpressApp`.
    app*: ExpressApp
    ## Shared path prefix.
    prefix*: string

# HTTP Methods as convenience constants
const
  ## GET method constant.
  GET* = hmGet
  ## POST method constant.
  POST* = hmPost
  ## PUT method constant.
  PUT* = hmPut
  ## DELETE method constant.
  DELETE* = hmDelete
  ## PATCH method constant.
  PATCH* = hmPatch
  ## HEAD method constant.
  HEAD* = hmHead
  ## OPTIONS method constant.
  OPTIONS* = hmOptions

## Create a new `Router` with an optional base path.
proc newRouter*(basePath: string = ""): Router =
  new(result)
  result.basePath = basePath
  result.getRoutes = @[]
  result.postRoutes = @[]
  result.putRoutes = @[]
  result.deleteRoutes = @[]
  result.patchRoutes = @[]
  result.headRoutes = @[]
  result.optionsRoutes = @[]
  result.getExactRoutes = newFastMap[int64]()
  result.postExactRoutes = newFastMap[int64]()
  result.putExactRoutes = newFastMap[int64]()
  result.deleteExactRoutes = newFastMap[int64]()
  result.patchExactRoutes = newFastMap[int64]()
  result.headExactRoutes = newFastMap[int64]()
  result.optionsExactRoutes = newFastMap[int64]()
  discard result.getExactRoutes.reserve(16)
  discard result.postExactRoutes.reserve(8)
  discard result.putExactRoutes.reserve(4)
  discard result.deleteExactRoutes.reserve(4)
  discard result.patchExactRoutes.reserve(4)
  discard result.headExactRoutes.reserve(4)
  discard result.optionsExactRoutes.reserve(4)
  result.firstDynamicGet = -1
  result.firstDynamicPost = -1
  result.firstDynamicPut = -1
  result.firstDynamicDelete = -1
  result.firstDynamicPatch = -1
  result.firstDynamicHead = -1
  result.firstDynamicOptions = -1
  result.artifactsCompiled = false
  result.middlewares = @[]
  result.locked = false
  result.lockReason = ""

# Get routes for a specific method - O(1) lookup
## Return the route list for a method, or nil. O(1) lookup.
proc routesForMethod*(router: Router, m: nim_usockets.HttpMethod): ptr seq[Route] {.inline.} =
  case m
  of hmGet: addr router.getRoutes
  of hmPost: addr router.postRoutes
  of hmPut: addr router.putRoutes
  of hmDelete: addr router.deleteRoutes
  of hmPatch: addr router.patchRoutes
  of hmHead: addr router.headRoutes
  of hmOptions: addr router.optionsRoutes
  else: nil

## Borrow request path from native metadata without wrapper duplication.
proc path*(req: Request): lent string {.inline.} =
  ## Borrow request path from native metadata without wrapper duplication.
  if req == nil or req.native == nil:
    return emptyRequestPath
  req.native.pathView()

## Allocate a new `Request` wrapping a native request.
proc newRequest*(native: HttpRequest): Request =
  new(result)
  result.native = native
  result.methodKind = native.methodKind
  result.headersBound = false
  result.queryBound = false
  result.bodyBound = false
  result.bodyReadFailed = false
  result.params = newFastMap[string]()
  result.cookies = newFastMap[string]()
  result.locals = newFastMap[string]()
  discard result.params.reserve(4)
  discard result.cookies.reserve(8)
  discard result.locals.reserve(4)
  # Tables remain zero-initialized and allocate only on first write.
  # Keep tables lazily zero-initialized on the hot path.
  result.jsonParsed = false
  result.cookiesParsed = false
  result.trustProxyEnabled = false
  result.lifecycleState = rlsActive
  result.cancelReason = rcrNone
  result.cancelHook = nil
  result.cancelNotified = false
  result.correlationSeq = 0'u64
  result.correlationIdCached = ""
  result.correlationIdGenerated = false
  result.requestSeq = 0'u64
  result.timeoutBudgetMs = 0
  result.timeoutStartedAtMs = 0'i64
  result.ownsNativeRequestCleanup = true

## Register a cancellation hook on the request.
proc onCancel*(req: Request, hook: proc(req: Request, reason: RequestCancelReason) {.closure.}) {.inline.} =
  if req != nil:
    req.cancelHook = hook

## Mark a request cancelled and fire its hook once.
proc markRequestCancelled*(req: Request, reason: RequestCancelReason): bool =
  if req == nil:
    return false
  if req.lifecycleState != rlsActive:
    return false
  req.lifecycleState = rlsCancelled
  req.cancelReason = reason
  if not req.cancelNotified and req.cancelHook != nil:
    req.cancelNotified = true
    req.cancelHook(req, reason)
  true

## Mark a request released and clear its cancel hook.
proc markRequestReleased*(req: Request) {.inline.} =
  if req == nil:
    return
  req.lifecycleState = rlsReleased
  req.cancelHook = nil
  req.cancelNotified = false

const HexPairTable: array[256, array[2, char]] = block:
  var t: array[256, array[2, char]]
  const HexChars = "0123456789abcdef"
  for i in 0..255:
    t[i] = [HexChars[i shr 4], HexChars[i and 0x0F]]
  t

proc uint64ToHex(val: uint64): string {.inline.} =
  result = newString(16)
  var v = val
  for i in countdown(7, 0):
    let b = int(v and 0xFF)
    result[i * 2] = HexPairTable[b][0]
    result[i * 2 + 1] = HexPairTable[b][1]
    v = v shr 8

## Return the request's hex correlation id, generating it lazily.
proc correlationId*(req: Request): lent string {.inline.} =
  if not req.correlationIdGenerated:
    req.correlationIdCached = uint64ToHex(req.correlationSeq)
    req.correlationIdGenerated = true
  req.correlationIdCached

## Set the request's correlation id directly.
proc `correlationId=`*(req: Request, value: string) {.inline.} =
  req.correlationIdCached = value
  req.correlationIdGenerated = true

proc currentEpochMsForTimeout(): int64 {.inline.} =
  let cached = getCachedEpochMs()
  if cached > 0:
    cached
  else:
    int64(epochTime() * 1000.0)

## Set the request timeout budget in milliseconds.
proc setRequestTimeoutBudget*(req: Request, budgetMs: int) {.inline.} =
  if req == nil:
    return
  req.timeoutBudgetMs = max(1, budgetMs)
  req.timeoutStartedAtMs = currentEpochMsForTimeout()

## Clear the request timeout budget.
proc clearRequestTimeoutBudget*(req: Request) {.inline.} =
  if req == nil:
    return
  req.timeoutBudgetMs = 0
  req.timeoutStartedAtMs = 0'i64

## Remaining timeout budget in ms, or -1 if unset.
proc requestTimeoutRemainingMs*(req: Request): int {.inline.} =
  if req == nil or req.timeoutBudgetMs <= 0:
    return -1
  if req.timeoutStartedAtMs <= 0:
    return 0
  let elapsedMs = max(0'i64, currentEpochMsForTimeout() - req.timeoutStartedAtMs)
  max(0, req.timeoutBudgetMs - int(elapsedMs))

## Cancel the request due to timeout.
proc notifyRequestTimeout*(req: Request): bool {.inline.} =
  req.markRequestCancelled(rcrTimeout)

## Cancel the request due to client disconnect.
proc notifyRequestDisconnect*(req: Request): bool {.inline.} =
  ## Cancel the request due to client disconnect.
  req.markRequestCancelled(rcrDisconnect)

## Cancel the request due to shutdown.
proc notifyRequestShutdown*(req: Request): bool {.inline.} =
  ## Cancel the request due to shutdown.
  req.markRequestCancelled(rcrShutdown)

## Whether the request has been cancelled.
proc requestCancelled*(req: Request): bool {.inline.} =
  ## Whether the request has been cancelled.
  req != nil and req.lifecycleState == rlsCancelled

## Whether the request has been released.
proc requestReleased*(req: Request): bool {.inline.} =
  ## Whether the request has been released.
  req == nil or req.lifecycleState == rlsReleased

## Lock the router against further mutations.
proc lockRouterMutations*(router: Router, reason: string = "listen_started") {.inline.} =
  if router == nil:
    return
  router.locked = true
  router.lockReason = reason

## Raise if the router is locked against mutations.
proc ensureRouterMutable*(router: Router) {.inline.} =
  if router != nil and router.locked:
    let reason = if router.lockReason.len > 0: router.lockReason else: "locked"
    raise newException(ValueError, "router mutation denied: " & reason)

## Bind the request headers map from native metadata.
proc bindHeaders*(req: Request) {.inline.} =
  if req == nil:
    return
  if not req.headersBound:
    if req.native == nil:
      if req.headers == nil:
        req.headers = newFastMap[string]()
        discard req.headers.reserve(8)
      req.headersBound = true
      return
    req.native.ensureHeadersPopulated()
    req.headers = req.native.headers
    if req.headers == nil:
      req.headers = newFastMap[string]()
      discard req.headers.reserve(8)
    req.headersBound = true

proc hasNullByte(s: string, startPos, endPos: int): bool {.inline.} =
  var i = startPos
  while i < endPos:
    if s[i] == '\0':
      return true
    inc i
  false

## Bind and parse the request query map.
proc bindQuery*(req: Request) {.inline.} =
  if req == nil:
    return
  if not req.queryBound:
    if req.native == nil:
      if req.query == nil:
        req.query = newFastMap[string]()
        discard req.query.reserve(8)
      req.queryBound = true
      return
    req.query = req.native.query
    if req.query == nil:
      req.query = newFastMap[string]()
      discard req.query.reserve(8)
    let rawQuery = req.native.queryStringRawView()
    if req.query.len == 0 and rawQuery.len > 0:
      var parsedPairs = 0
      var i = 0
      let q = rawQuery
      while i < q.len and parsedPairs < DefaultMaxQueryPairs:
        var keyStart = i
        var keyEnd = i
        var valStart = -1
        while i < q.len and q[i] != '&':
          if q[i] == '=' and valStart < 0:
            keyEnd = i
            valStart = i + 1
          inc i
        if valStart < 0:
          keyEnd = i
        let valueEnd = i
        if keyEnd > keyStart:
          let keyLen = keyEnd - keyStart
          let valueLen =
            if valStart >= 0 and valueEnd >= valStart:
              valueEnd - valStart
            else:
              0
          if keyLen > 0 and keyLen <= DefaultMaxQueryKeyBytes and valueLen <= DefaultMaxQueryValueBytes:
            if not hasNullByte(q, keyStart, keyEnd) and
               not (valStart >= 0 and hasNullByte(q, valStart, valueEnd)):
              let key = q[keyStart..<keyEnd]
              let value =
                if valStart >= 0 and valueEnd >= valStart:
                  q[valStart..<valueEnd]
                else:
                  ""
              req.query[key] = value
              inc parsedPairs
        inc i
    req.queryBound = true

## Bind the request body from native metadata or spill file.
proc bindBody*(req: Request) {.inline.} =
  if req == nil:
    return
  if not req.bodyBound:
    if req.native == nil:
      req.body.setLen(0)
    elif req.native.bodyInFile and req.native.bodyFilePath.len > 0:
      try:
        req.body = readFile(req.native.bodyFilePath)
      except CatchableError:
        req.body = ""
        req.bodyReadFailed = true
    else:
      req.body = req.native.body
    req.bodyBound = true

## Whether reading the spilled body file failed.
proc bodyReadFailed*(req: Request): bool {.inline.} =
  if req == nil:
    return false
  req.bodyReadFailed

## Estimated raw body size in bytes, or -1 if unknown.
proc rawBodySizeHint*(req: Request): int {.inline.} =
  if req == nil or req.native == nil:
    return -1
  if req.bodyBound:
    return req.body.len
  if req.native.bodyInFile and req.native.bodyFilePath.len > 0:
    try:
      let size = getFileSize(req.native.bodyFilePath)
      if size > BiggestInt(high(int)):
        return high(int)
      return int(size)
    except CatchableError:
      return -1
  req.native.body.len

## Return the raw request body, binding it if needed.
proc rawBody*(req: Request): lent string {.inline.} =
  req.bindBody()
  req.body

## Cache a pre-parsed JSON body on the request.
proc cacheJsonBody*(req: Request, node: JsonNode) {.inline.} =
  req.jsonBody = node
  req.jsonParsed = true

## Parse and cache the JSON body, respecting a max size.
proc getJsonBody*(req: Request, maxBytes: int = DefaultMaxJsonBodyBytes): JsonNode =
  if not req.jsonParsed:
    req.jsonParsed = true
    req.bindHeaders()
    req.bindBody()
    let contentType = req.headers.getOrDefault("content-type", "")
    if isJsonContentType(contentType) and req.body.len > 0:
      if maxBytes > 0 and req.body.len > maxBytes:
        req.jsonBody = nil
      else:
        try:
          req.jsonBody = parseJson(req.body)
        except CatchableError:
          req.jsonBody = nil
  return req.jsonBody

## Deserialize the request body directly into type `T`.
proc parseBody*[T](req: Request): T =
  req.bindBody()
  deserializeDirect(req.body, T)

## Try to deserialize the body into `T`, returning ok/value.
proc tryParseBody*[T](req: Request): tuple[ok: bool, value: T] =
  try:
    req.bindBody()
    result.value = deserializeDirect(req.body, T)
    result.ok = true
  except CatchableError:
    result.ok = false

# Lazy cookie parsing
proc cookieViewChar(view: fast_map.FastStringView, i: int): char {.inline.} =
  cast[ptr UncheckedArray[char]](view.data)[i]

proc cookieViewSlice(view: fast_map.FastStringView, startPos, endPos: int): string {.inline.} =
  let sliceLen = endPos - startPos
  if view.data == nil or sliceLen <= 0:
    return ""
  let chars = cast[ptr UncheckedArray[char]](view.data)
  result = newStringUninit(sliceLen)
  copyMem(addr result[0], unsafeAddr chars[startPos], sliceLen)

proc cookieViewHasControl(view: fast_map.FastStringView, startPos, endPos: int): bool {.inline.} =
  var i = startPos
  while i < endPos:
    let b = ord(cookieViewChar(view, i))
    if b < 0x20 or b == 0x7F:
      return true
    inc i
  false

## Parse a Cookie header borrowed as a view without copying, returning false if pair or byte caps are exceeded or a control byte appears.
proc parseCookieHeaderBounded*(
  cookieHeader: fast_map.FastStringView,
  cookies: var FastMap[string],
  maxPairs: int = DefaultMaxCookiePairs,
  maxKeyBytes: int = DefaultMaxCookieKeyBytes,
  maxValueBytes: int = DefaultMaxCookieValueBytes
): bool =
  ## Parse a Cookie header borrowed as a view without copying the whole header.
  ## Returns false (rejecting the header) when a pair exceeds the byte caps, the
  ## pair count is exceeded, or a name/value carries a control byte
  ## (header-injection defense-in-depth).
  var parsedPairs = 0
  var i = 0
  let total = cookieHeader.len
  let pairCap = max(1, maxPairs)
  let keyCap = max(1, maxKeyBytes)
  let valueCap = max(0, maxValueBytes)

  while i < total:
    while i < total and (cookieViewChar(cookieHeader, i) == ';' or cookieViewChar(cookieHeader, i) == ' ' or cookieViewChar(cookieHeader, i) == '\t'):
      inc i
    if i >= total:
      break

    let nameStart = i
    while i < total and cookieViewChar(cookieHeader, i) != '=' and cookieViewChar(cookieHeader, i) != ';':
      inc i
    if i >= total or cookieViewChar(cookieHeader, i) != '=':
      while i < total and cookieViewChar(cookieHeader, i) != ';':
        inc i
      continue

    var nameEnd = i
    while nameEnd > nameStart and (cookieViewChar(cookieHeader, nameEnd - 1) == ' ' or cookieViewChar(cookieHeader, nameEnd - 1) == '\t'):
      dec nameEnd
    inc i

    while i < total and (cookieViewChar(cookieHeader, i) == ' ' or cookieViewChar(cookieHeader, i) == '\t'):
      inc i
    let valueStart = i
    while i < total and cookieViewChar(cookieHeader, i) != ';':
      inc i
    var valueEnd = i
    while valueEnd > valueStart and (cookieViewChar(cookieHeader, valueEnd - 1) == ' ' or cookieViewChar(cookieHeader, valueEnd - 1) == '\t'):
      dec valueEnd

    if nameEnd <= nameStart:
      continue

    let keyLen = nameEnd - nameStart
    let valueLen = max(0, valueEnd - valueStart)
    if keyLen > keyCap or valueLen > valueCap:
      return false
    if parsedPairs >= pairCap:
      return false
    if cookieViewHasControl(cookieHeader, nameStart, nameEnd) or cookieViewHasControl(cookieHeader, valueStart, valueEnd):
      return false

    let cookieName = cookieViewSlice(cookieHeader, nameStart, nameEnd)
    let cookieValue = cookieViewSlice(cookieHeader, valueStart, valueEnd)
    cookies[cookieName] = cookieValue
    inc parsedPairs
  true

## String overload of `parseCookieHeaderBounded`.
proc parseCookieHeaderBounded*(
  cookieHeader: string,
  cookies: var FastMap[string],
  maxPairs: int = DefaultMaxCookiePairs,
  maxKeyBytes: int = DefaultMaxCookieKeyBytes,
  maxValueBytes: int = DefaultMaxCookieValueBytes
): bool =
  parseCookieHeaderBounded(fast_map.toFastStringView(cookieHeader), cookies, maxPairs, maxKeyBytes, maxValueBytes)

## Mark the request's cookies as parsed.
proc markCookiesParsed*(req: Request) {.inline.} =
  if req != nil:
    req.cookiesParsed = true

## Whether cookie parsing was rejected for this request.
proc cookieParseRejected*(req: Request): bool {.inline.} =
  req != nil and req.locals.getOrDefault(CookieParseRejectedKey, "") == "1"

proc parseCookiesLazy(req: Request) {.inline.} =
  if not req.cookiesParsed:
    req.cookiesParsed = true
    if req.cookies.len > 0:
      return
    req.bindHeaders()
    let cookieHeaderView = req.headers.getView("cookie")
    if cookieHeaderView.len > 0:
      if not parseCookieHeaderBounded(cookieHeaderView, req.cookies):
        req.cookies.clear()
        req.locals[CookieParseRejectedKey] = "1"

## Get a cookie value by name, parsing cookies lazily.
proc getCookie*(req: Request, name: string): string {.inline.} =
  req.parseCookiesLazy()
  return req.cookies.getOrDefault(name, "")

## Allocate a new `Response` wrapping a native response.
proc newResponse*(native: HttpResponse, viewsDir: string = "views", viewExt: string = ""): Response =
  new(result)
  result.native = native
  result.request = nil
  result.app = nil
  result.headers = newFastMap[string]()
  discard result.headers.reserve(8)
  result.viewsDir = viewsDir
  result.viewExt = viewExt
  result.requestMethodKind = if native != nil: native.requestMethodKind() else: hmGet
  result.statusCode = 200
  result.locals = newFastMap[string]()
  discard result.locals.reserve(4)
  result.headersInited = false
  result.finished = false
  # Lazily initialize on first write.
  result.compress = false
  result.compressEncoding = ""
  result.headerBuf = newStringOfCap(256)
  result.droppedLateWrites = 0
  result.lifecycleToken = 1'u64

proc bumpResponseLifecycleToken(res: Response) {.inline.} =
  if res == nil:
    return
  if res.lifecycleToken == high(uint64):
    res.lifecycleToken = 1'u64
  else:
    inc res.lifecycleToken

## Return the response's current lifecycle token.
proc responseLifecycleToken*(res: Response): uint64 {.inline.} =
  if res == nil: 0'u64 else: res.lifecycleToken

## Whether a token matches the response's current lifecycle token.
proc responseLifecycleTokenMatches*(res: Response, token: uint64): bool {.inline.} =
  res != nil and token != 0'u64 and res.lifecycleToken == token

const
  ## Default maximum pooled context objects.
  DefaultContextPoolMax* = 4096

var
  ## Current maximum pooled context objects.
  contextPoolMax* = DefaultContextPoolMax
  ## Whether request/response pooling is enabled.
  requestResponsePoolingEnabled* = false
when defined(singleThread) or defined(contextpool_single_thread):
  var
    skippedBodyFileDeleteCounter: int64
    requestPool: seq[Request]
    responsePool: seq[Response]
else:
  var
    skippedBodyFileDeleteCounter {.threadvar.}: int64
    requestPool {.threadvar.}: seq[Request]
    responsePool {.threadvar.}: seq[Response]

proc pathWithinTrustedRoot(path: string, root: string): bool =
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
    return absPath[absRoot.len] in {'\\', '/'}
  else:
    return absPath[absRoot.len] == '/'

proc deleteBodyFileIfTrusted(native: HttpRequest): bool {.inline.} =
  if native == nil or not native.bodyInFile:
    return false
  if native.bodyFilePath.len == 0:
    return false
  if native.bodyFileRoot.len == 0 or not pathWithinTrustedRoot(native.bodyFilePath, native.bodyFileRoot):
    inc skippedBodyFileDeleteCounter
    return false
  try:
    if fileExists(native.bodyFilePath):
      removeFile(native.bodyFilePath)
      return true
  except CatchableError:
    discard
  false

## Count of body-file deletes skipped as untrusted.
proc skippedBodyFileDeleteCount*(): int64 {.inline.} =
  skippedBodyFileDeleteCounter

## Reset the skipped body-file delete counter.
proc resetSkippedBodyFileDeleteCount*() {.inline.} =
  skippedBodyFileDeleteCounter = 0'i64

## Set the maximum pooled context objects.
proc setContextPoolMax*(maxEntries: int) {.inline.} =
  contextPoolMax = max(1, maxEntries)

## Get the maximum pooled context objects.
proc getContextPoolMax*(): int {.inline.} =
  contextPoolMax

## Enable or disable request/response pooling.
proc setRequestResponsePoolingEnabled*(enabled: bool) {.inline.} =
  requestResponsePoolingEnabled = enabled
  if not enabled:
    requestPool.setLen(0)
    responsePool.setLen(0)

## Whether request/response pooling is enabled.
proc getRequestResponsePoolingEnabled*(): bool {.inline.} =
  requestResponsePoolingEnabled

## Current number of pooled request objects.
proc requestPoolSize*(): int {.inline.} =
  requestPool.len

## Current number of pooled response objects.
proc responsePoolSize*(): int {.inline.} =
  ## Current number of pooled response objects.
  responsePool.len

## Pre-fill the request/response pools to the given sizes.
proc prewarmContextPools*(requestCount: int = 256, responseCount: int = 256) =
  if not requestResponsePoolingEnabled:
    return
  let reqTarget = min(max(0, requestCount), contextPoolMax)
  let resTarget = min(max(0, responseCount), contextPoolMax)
  let reqPool = addr requestPool
  let resPool = addr responsePool

  while reqPool[].len < reqTarget:
    var req: Request
    new(req)
    req.params = newFastMap[string]()
    req.cookies = newFastMap[string]()
    req.locals = newFastMap[string]()
    discard req.params.reserve(4)
    discard req.cookies.reserve(8)
    discard req.locals.reserve(4)
    reqPool[].add(req)

  while resPool[].len < resTarget:
    var res: Response
    new(res)
    res.locals = newFastMap[string]()
    discard res.locals.reserve(4)
    res.headerBuf = newStringOfCap(256)
    resPool[].add(res)

proc resetRequestForReuse(
  req: Request,
  native: HttpRequest,
  ownsNativeRequestCleanup: bool = true
) {.inline.} =
  let oldNative = req.native
  if req.ownsNativeRequestCleanup:
    discard deleteBodyFileIfTrusted(oldNative)
  let hadHeaders = req.headersBound
  if hadHeaders:
    req.headers.clear()
  if req.query != nil and req.query != native.query:
    req.query.clear()
  req.query = native.query
  if req.params.len > 0:
    req.params.clear()
  if req.cookies != nil and req.cookies.len > 0:
    req.cookies.clear()
  if req.locals.len > 0:
    req.locals.clear()

  req.native = native
  req.methodKind = native.methodKind
  req.headersBound = false
  req.queryBound = false
  req.bodyBound = false
  req.jsonParsed = false
  req.cookiesParsed = false
  req.trustProxyEnabled = false
  req.trustedProxyHopCount = 0'i16
  req.trustedProxyAllowlist.setLen(0)
  req.lifecycleState = rlsActive
  req.cancelReason = rcrNone
  req.cancelHook = nil
  req.cancelNotified = false
  req.correlationSeq = 0'u64
  req.correlationIdGenerated = false
  req.correlationIdCached.setLen(0)
  req.requestSeq = 0'u64
  req.timeoutBudgetMs = 0
  req.timeoutStartedAtMs = 0'i64
  req.ownsNativeRequestCleanup = ownsNativeRequestCleanup
  req.body.setLen(0)
  req.jsonBody = nil

## Rebind a pooled request to a new native request.
proc rebindRequest*(req: Request, native: HttpRequest) {.inline.} =
  if req != nil:
    req.resetRequestForReuse(native)

proc acquireRequestInternal(native: HttpRequest, ownsNativeRequestCleanup: bool): Request =
  if not requestResponsePoolingEnabled:
    new(result)
    result.params = newFastMap[string]()
    result.cookies = newFastMap[string]()
    result.locals = newFastMap[string]()
    discard result.params.reserve(4)
    discard result.cookies.reserve(8)
    discard result.locals.reserve(4)
    result.ownsNativeRequestCleanup = true
    result.resetRequestForReuse(native, ownsNativeRequestCleanup)
    return

  let reqPool = addr requestPool
  if reqPool[].len > 0:
    result = reqPool[][^1]
    reqPool[].setLen(reqPool[].len - 1)
  else:
    new(result)
    result.params = newFastMap[string]()
    result.cookies = newFastMap[string]()
    result.locals = newFastMap[string]()
    discard result.params.reserve(4)
    discard result.cookies.reserve(8)
    discard result.locals.reserve(4)
    result.ownsNativeRequestCleanup = true

  result.resetRequestForReuse(native, ownsNativeRequestCleanup)

## Acquire a request wrapper owning native cleanup.
proc acquireRequest*(native: HttpRequest): Request =
  acquireRequestInternal(native, true)

## Acquire a request wrapper that does not own native cleanup.
proc acquireBorrowedRequest*(native: HttpRequest): Request =
  ## Borrow native request metadata for response-time hooks. Releasing the
  ## wrapper must not delete a spilled body owned by the active request.
  acquireRequestInternal(native, false)

## Release a request wrapper back to the pool.
proc releaseRequest*(req: Request) =
  if req == nil:
    return
  let recyclable = req.cancelReason == rcrNone
  if req.ownsNativeRequestCleanup:
    discard deleteBodyFileIfTrusted(req.native)
  req.native = nil
  req.body.setLen(0)
  req.jsonBody = nil
  if req.query != nil:
    req.query.clear()
    req.query = nil
  if req.cookies != nil and req.cookies.len > 0:
    req.cookies.clear()
  req.headersBound = false
  req.queryBound = false
  req.bodyBound = false
  req.jsonParsed = false
  req.cookiesParsed = false
  req.trustProxyEnabled = false
  req.trustedProxyHopCount = 0'i16
  req.trustedProxyAllowlist.setLen(0)
  req.lifecycleState = rlsReleased
  req.cancelReason = rcrNone
  req.cancelHook = nil
  req.cancelNotified = false
  req.correlationSeq = 0'u64
  req.correlationIdGenerated = false
  req.correlationIdCached.setLen(0)
  req.requestSeq = 0'u64
  req.timeoutBudgetMs = 0
  req.timeoutStartedAtMs = 0'i64
  req.ownsNativeRequestCleanup = true
  let reqPool = addr requestPool
  if requestResponsePoolingEnabled and recyclable and reqPool[].len < contextPoolMax:
    reqPool[].add(req)

proc resetResponseForReuse(res: Response, native: HttpResponse, app: ExpressApp, viewsDir: string, viewExt: string) {.inline.} =
  res.bumpResponseLifecycleToken()
  if res.headersInited:
    if res.headers.len > 0:
      res.headers.clear()
  if res.setCookies.len > 0:
    res.setCookies.setLen(0)
  if res.locals.len > 0:
    res.locals.clear()

  res.native = native
  res.request = nil
  res.app = app
  res.viewsDir = viewsDir
  res.viewExt = viewExt
  res.requestMethodKind = if native != nil: native.requestMethodKind() else: hmGet
  res.statusCode = 200
  res.finished = false
  res.compress = false
  res.compressEncoding.setLen(0)
  res.headerBuf.setLen(0)
  res.droppedLateWrites = 0
  if res.beforeFinalizeHooks.len > 0:
    res.beforeFinalizeHooks.setLen(0)

## Rebind a pooled response to a new native response.
proc rebindResponse*(
  res: Response,
  native: HttpResponse,
  app: ExpressApp,
  viewsDir: string,
  viewExt: string
) {.inline.} =
  if res != nil:
    res.resetResponseForReuse(native, app, viewsDir, viewExt)

## Acquire a response wrapper from the pool or allocate one.
proc acquireResponse*(
  native: HttpResponse,
  app: ExpressApp = nil,
  viewsDir: string = "views",
  viewExt: string = ""
): Response =
  if not requestResponsePoolingEnabled:
    new(result)
    result.locals = newFastMap[string]()
    discard result.locals.reserve(4)
    result.headerBuf = newStringOfCap(256)
    result.resetResponseForReuse(native, app, viewsDir, viewExt)
    return

  let resPool = addr responsePool
  if resPool[].len > 0:
    result = resPool[][^1]
    resPool[].setLen(resPool[].len - 1)
  else:
    new(result)
    result.locals = newFastMap[string]()
    discard result.locals.reserve(4)
    result.headerBuf = newStringOfCap(256)

  result.resetResponseForReuse(native, app, viewsDir, viewExt)

## Release a response wrapper back to the pool.
proc releaseResponse*(res: Response) =
  if res == nil:
    return
  res.bumpResponseLifecycleToken()
  let recyclable = res.request == nil or res.request.cancelReason == rcrNone
  res.native = nil
  res.request = nil
  res.app = nil
  res.finished = false
  res.headersInited = false
  res.requestMethodKind = hmGet
  res.statusCode = 200
  res.setCookies.setLen(0)
  res.droppedLateWrites = 0
  if res.beforeFinalizeHooks.len > 0:
    res.beforeFinalizeHooks.setLen(0)
  let resPool = addr responsePool
  if requestResponsePoolingEnabled and recyclable and resPool[].len < contextPoolMax:
    resPool[].add(res)
