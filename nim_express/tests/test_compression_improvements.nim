import std/[unittest, asyncdispatch, json, strutils]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/app
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/compression

proc newMockHttpRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[]
): HttpRequest =
  new(result)
  result.path = pathVal
  result.queryStringRaw = ""
  result.httpVersion = "1.1"
  result.httpMajor = 1
  result.httpMinor = 1
  result.body = bodyStr
  result.remoteIp = remoteIpStr
  result.methodKind = methodKind
  result.connectionClose = false
  result.headersDeferred = false
  result.bodyInFile = false
  result.bodyFilePath = ""
  result.bodyFileRoot = ""
  result.headers = newFastMap[string]()
  discard result.headers.reserve(16)
  result.query = newFastMap[string]()
  discard result.query.reserve(8)
  for (k, v) in headerMap:
    result.headers[k] = v

proc newMockRequest(
  pathVal: string = "/", methodKind: HttpMethod = hmGet, bodyStr: string = "",
  remoteIpStr: string = "127.0.0.1", headerMap: seq[(string, string)] = @[]
): Request =
  let native = newMockHttpRequest(pathVal, methodKind, bodyStr, remoteIpStr, headerMap)
  result = newRequest(native)

proc newMockResponse(): Response =
  new(result)
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = hmGet
  nativeRes.connectionClose = false
  result.native = nativeRes
  result.request = nil
  result.app = nil
  result.viewsDir = "views"
  result.viewExt = ""
  result.requestMethodKind = hmGet
  result.statusCode = 200
  result.headersInited = true
  result.finished = false
  result.compress = false
  result.compressEncoding = ""
  result.headerBuf = newStringOfCap(256)
  result.droppedLateWrites = 0
  result.headers = newFastMap[string]()
  discard result.headers.reserve(16)
  result.locals = newFastMap[string]()
  discard result.locals.reserve(4)

proc startMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
): Future[void] =
  var idx = 0
  proc finalHandler(r: Request, s: Response): Future[void] {.async.} =
    if handler != nil: await handler(r, s)
    elif not s.finished: s.status(200)
  proc advance(): Future[void] {.async.} =
    if idx < middlewares.len:
      let current = middlewares[idx]
      inc idx
      await current(req, res, advance)
    else:
      await finalHandler(req, res)
  result = advance()

proc runMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
) =
  waitFor startMiddlewareChain(middlewares, req, res, handler)

proc sendHandler(bodyStr: string): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    if not res.finished:
      res.status(200)
    res.send(bodyStr)

proc seedHeaderMw(name, value: string): AsyncMiddleware =
  result = proc(req: Request, res: Response, next: NextProc): Future[void] {.async.} =
    res.setTrusted(name, value)
    await next()

proc capturedResponseBody(res: Response): string =
  let raw = res.native.capturedRaw
  let bodyStart = raw.find("\r\n\r\n")
  if bodyStart >= 0:
    raw[bodyStart + 4 ..^ 1]
  else:
    ""

const bigBody = repeat("hello world, this is a compressible payload. ", 40)

suite "compression unit":
  test "isAlreadyCompressed recognizes known encodings with and without ;param (ISSUE-9)":
    check isAlreadyCompressed("gzip")
    check isAlreadyCompressed("br")
    check isAlreadyCompressed("zstd")
    check isAlreadyCompressed("deflate")
    check isAlreadyCompressed("compress")
    check isAlreadyCompressed("GZIP")
    check isAlreadyCompressed("  br  ")
    check isAlreadyCompressed("gzip;q=1")
    check isAlreadyCompressed("br;q=0")
    check isAlreadyCompressed("zstd;level=1")
    check isAlreadyCompressed("gzip, deflate")
    check isAlreadyCompressed("identity, gzip")

  test "isAlreadyCompressed rejects empty, identity, and unknown values":
    check not isAlreadyCompressed("")
    check not isAlreadyCompressed("identity")
    check not isAlreadyCompressed("identity;q=1")
    check not isAlreadyCompressed("identity, identity")
    check not isAlreadyCompressed("foo")
    check not isAlreadyCompressed("x-compressed")

  test "isPrecompressedMime table":
    check isPrecompressedMime("image/png")
    check isPrecompressedMime("Image/PNG")
    check isPrecompressedMime("image/png; charset=binary")
    check isPrecompressedMime("image/jpeg")
    check isPrecompressedMime("video/mp4")
    check isPrecompressedMime("audio/mpeg")
    check isPrecompressedMime("application/zip")
    check isPrecompressedMime("application/x-gzip")
    check isPrecompressedMime("font/woff2")
    check not isPrecompressedMime("")
    check not isPrecompressedMime("text/html")
    check not isPrecompressedMime("application/json")
    check not isPrecompressedMime("text/plain; charset=utf-8")
    check not isPrecompressedMime("image/svg+xml")

  test "default options keep documented values":
    let opts = defaultCompressionOptions()
    check opts.enabled
    check opts.minBytes == 0
    check opts.skipPrecompressedMimes
    check hmGet in opts.enableOnMethods
    check hmDelete in opts.enableOnMethods
    let policy = defaultCompressionPolicyOptions()
    check policy.enabled
    check policy.minBytes == 860
    check policy.level == 6
    check policy.minSavingsRatio == 0.05
    check policy.backpressureThresholdBytes == 0
    check policy.offloadThresholdBytes == 16 * 1024

suite "compression integration":
  test "large gzip-acceptable response is compressed (200 regression)":
    let mw = compression()
    let req = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, sendHandler(bigBody))
    check res.statusCode == 200
    check res.finished
    check res.get("Content-Encoding") == "gzip"
    check res.get("Vary") == "Accept-Encoding"
    check res.compress
    check res.compressEncoding == "gzip"
    let rawBody = capturedResponseBody(res)
    check rawBody.len > 0
    check rawBody.len < bigBody.len
    check not rawBody.contains("hello world")
    check rawBody[0] == chr(0x1f)
    check rawBody[1] == chr(0x8b)

  test "Vary token merges with a pre-existing Vary value":
    let mw = compression()
    let req = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res = newMockResponse()
    runMiddlewareChain(@[seedHeaderMw("Vary", "Cache-Control"), mw], req, res,
      sendHandler(bigBody))
    check res.get("Vary") == "Cache-Control, Accept-Encoding"
    check res.get("Content-Encoding") == "gzip"

  test "Vary is not duplicated and a '*' Vary is left untouched":
    let mw = compression()
    let req = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res = newMockResponse()
    runMiddlewareChain(@[seedHeaderMw("Vary", "Accept-Encoding"), mw], req, res,
      sendHandler(bigBody))
    check res.get("Vary") == "Accept-Encoding"
    check res.get("Content-Encoding") == "gzip"

    # A pre-existing "*" Vary must not be extended by the middleware
    # (asserted with a sub-minBytes body so the response-layer merge,
    # which only runs for compressed bodies, stays out of the picture).
    let req2 = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res2 = newMockResponse()
    runMiddlewareChain(@[seedHeaderMw("Vary", "*"), mw], req2, res2,
      sendHandler("tiny"))
    check res2.get("Vary") == "*"
    check res2.get("Content-Encoding") == ""

  test "explicit app policy minBytes is honored over the middleware default (ISSUE-2)":
    let app = newExpressApp()
    installCompressionPolicy(app, CompressionPolicyOptions(enabled: true, minBytes: 256))
    let body = repeat("policy-min-bytes-", 40)
    check body.len >= 256 and body.len < 860
    let mw = compression()
    let req = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res = newMockResponse()
    res.app = app
    runMiddlewareChain(@[mw], req, res, sendHandler(body))
    check res.statusCode == 200
    check res.get("Content-Encoding") == "gzip"
    check capturedResponseBody(res).len < body.len

  test "tiny response below minBytes is not compressed":
    let mw = compression()
    let req = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, sendHandler("tiny"))
    check res.statusCode == 200
    check res.finished
    check res.get("Content-Encoding") == ""
    check res.get("Vary") == "Accept-Encoding"
    check capturedResponseBody(res) == "tiny"

  test "already-compressed gzip response passes through without double encoding":
    let mw = compression()
    let req = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res = newMockResponse()
    runMiddlewareChain(@[seedHeaderMw("Content-Encoding", "gzip"), mw], req, res,
      sendHandler(bigBody))
    check res.statusCode == 200
    check res.finished
    check res.get("Content-Encoding") == "gzip"
    check not res.compress
    check capturedResponseBody(res) == bigBody

  test "upstream 'gzip;q=1' content-encoding is recognized, no double encoding (ISSUE-9)":
    check isAlreadyCompressed("gzip;q=1")
    let mw = compression()
    let req = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res = newMockResponse()
    runMiddlewareChain(@[seedHeaderMw("Content-Encoding", "gzip;q=1"), mw], req, res,
      sendHandler(bigBody))
    check res.statusCode == 200
    check res.finished
    check res.get("Content-Encoding") == "gzip;q=1"
    check not res.compress
    check res.get("Vary") == "Accept-Encoding"
    check capturedResponseBody(res) == bigBody

  test "no Accept-Encoding header: no compression and no Vary (200 regression)":
    let mw = compression()
    let req = newMockRequest("/", hmGet)
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, sendHandler(bigBody))
    check res.statusCode == 200
    check res.finished
    check res.get("Content-Encoding") == ""
    check res.get("Vary") == ""
    check capturedResponseBody(res) == bigBody

  test "identity-only accept-encoding negotiates to no compression":
    let mw = compression()
    let req = newMockRequest("/", hmGet, "",
      headerMap = @[("accept-encoding", "identity;q=0")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res, sendHandler(bigBody))
    check res.statusCode == 200
    check res.finished
    check res.get("Content-Encoding") == ""
    check res.get("Vary") == ""
    check capturedResponseBody(res) == bigBody

  test "handler can opt out via res.compress = false (BREACH mitigation)":
    let mw = compression()
    let req = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res,
      proc(r: Request, s: Response): Future[void] {.async.} =
        s.status(200)
        s.compress = false
        s.send(bigBody))
    check res.statusCode == 200
    check res.finished
    check res.get("Content-Encoding") == ""
    check res.get("Vary") == "Accept-Encoding"
    check capturedResponseBody(res) == bigBody

  test "pre-compressed MIME response is not re-compressed":
    let mw = compression()
    let req = newMockRequest("/", hmGet, "", headerMap = @[("accept-encoding", "gzip")])
    let res = newMockResponse()
    runMiddlewareChain(@[mw], req, res,
      proc(r: Request, s: Response): Future[void] {.async.} =
        s.status(200)
        s.setTrusted("Content-Type", "image/png")
        s.send(bigBody))
    check res.statusCode == 200
    check res.finished
    check res.get("Content-Encoding") == ""
    check capturedResponseBody(res) == bigBody
