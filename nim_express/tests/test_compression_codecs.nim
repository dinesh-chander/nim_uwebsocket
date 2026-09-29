import std/[unittest, asyncdispatch, strutils]
import zippy
import brotli
import zstd/decompress as zstdd
import ../src/nim_express/[types, app, response, compression_codec]
import ../src/nim_express/middlewares/[compression, cors]

proc stringToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc makeReq(
  acceptEncoding: string,
  extraHeaders: openArray[(string, string)] = []
): Request =
  var nativeReq: HttpRequest
  new(nativeReq)
  nativeReq.methodKind = hmGet
  nativeReq.headers = newFastMap[string]()
  if acceptEncoding.len > 0:
    nativeReq.headers["accept-encoding"] = acceptEncoding
  for (key, value) in extraHeaders:
    nativeReq.headers[key] = value
  result = newRequest(nativeReq)

proc makeRes(app: ExpressApp = nil): Response =
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = hmGet
  nativeRes.connectionClose = false
  result = newResponse(nativeRes)
  result.app = app

proc varyContains(varyValue: string, token: string): bool =
  for part in varyValue.split(','):
    if part.strip().cmpIgnoreCase(token) == 0:
      return true
  false

suite "Compression codec coverage":
  test "accept-encoding preference picks zstd then br then gzip":
    check chooseCompressionEncoding("gzip, br, zstd") == ceZstd
    check chooseCompressionEncoding("br, gzip") == ceBrotli
    check chooseCompressionEncoding("gzip") == ceGzip
    check chooseCompressionEncoding("gzip;Q=0, br;q=0.5") == ceBrotli
    check chooseCompressionEncoding("identity") == ceNone

  test "middleware marks response compression and selected encoding":
    let req = makeReq("gzip, br, zstd")
    let res = makeRes()
    let mw = compression(CompressionOptions(enabled: true, minBytes: 0, enableOnMethods: {hmGet}))
    waitFor mw(req, res, proc(): Future[void] {.async.} =
      discard
    )
    check res.compress
    check res.compressEncoding == "zstd"

  test "middleware preserves CORS app vary while adding accept-encoding":
    let req = makeReq("gzip", [("origin", "https://app.example")])
    let res = makeRes()
    let corsMw = cors(CorsOptions(origin: "reflect"))
    let compressionMw = compression(CompressionOptions(
      enabled: true,
      minBytes: 0,
      enableOnMethods: {hmGet},
      skipPrecompressedMimes: true
    ))

    waitFor corsMw(req, res, proc(): Future[void] {.async.} =
      await compressionMw(req, res, proc(): Future[void] {.async.} =
        discard
      )
    )

    let vary = res.get("vary")
    check vary.varyContains("Origin")
    check vary.varyContains("Accept-Encoding")
    check not vary.varyContains("Content-Encoding")

  test "middleware minBytes is enforced at send time":
    let req = makeReq("gzip")
    let res = makeRes()
    let mw = compression(CompressionOptions(
      enabled: true,
      minBytes: 999999,
      enableOnMethods: {hmGet},
      skipPrecompressedMimes: true
    ))
    waitFor mw(req, res, proc(): Future[void] {.async.} =
      res.set("Content-Type", "text/plain; charset=utf-8")
      res.send("small-but-compressible-" & "x".repeat(4096))
    )
    check res.get("content-encoding") == ""

  test "middleware does not recompress existing content-encoding":
    let req = makeReq("gzip")
    let res = makeRes()
    let mw = compression(CompressionOptions(
      enabled: true,
      minBytes: 0,
      enableOnMethods: {hmGet},
      skipPrecompressedMimes: true
    ))
    waitFor mw(req, res, proc(): Future[void] {.async.} =
      res.set("Content-Type", "text/plain; charset=utf-8")
      res.set("Content-Encoding", "br")
      res.send("already-compressed-" & "x".repeat(4096))
    )
    check res.get("content-encoding") == "br"

  test "middleware skips precompressed MIME types before send":
    let req = makeReq("gzip")
    let res = makeRes()
    let mw = compression(CompressionOptions(
      enabled: true,
      minBytes: 0,
      enableOnMethods: {hmGet},
      skipPrecompressedMimes: true
    ))
    waitFor mw(req, res, proc(): Future[void] {.async.} =
      res.set("Content-Type", "image/png")
      res.send("png-like-compressible-" & "x".repeat(4096))
    )
    check res.get("content-encoding") == ""

  test "gzip payload roundtrips":
    let payload = "hello-gzip-" & "x".repeat(4096)
    let compressed = compressPayload(payload, ceGzip, 6, "text/plain")
    let decoded = zippy.uncompress(compressed, dfGzip)
    check decoded == payload

  test "brotli payload roundtrips":
    let payload = "hello-br-" & "y".repeat(4096)
    let compressed = compressPayload(payload, ceBrotli, 6, "text/plain")
    let decoded = decompressBrotli(compressed)
    check decoded == payload

  test "zstd payload roundtrips":
    let payload = "hello-zstd-" & "z".repeat(4096)
    let compressed = compressPayload(payload, ceZstd, 6, "application/json")
    let decoded = zstdd.decompress(stringToBytes(compressed))
    check bytesToString(decoded) == payload

  test "response path sets selected content-encoding":
    let app = newExpressApp()
    let payload = "response-encoding-" & "w".repeat(4096)

    let resGzip = makeRes(app)
    resGzip.compress = true
    resGzip.compressEncoding = "gzip"
    resGzip.send(payload)
    check resGzip.headers.getOrDefault("content-encoding", "") == "gzip"

    let resBr = makeRes(app)
    resBr.compress = true
    resBr.compressEncoding = "br"
    resBr.send(payload)
    check resBr.headers.getOrDefault("content-encoding", "") == "br"

    let resZstd = makeRes(app)
    resZstd.compress = true
    resZstd.compressEncoding = "zstd"
    resZstd.send(payload)
    check resZstd.headers.getOrDefault("content-encoding", "") == "zstd"

  test "response path skips compression when HTTP semantics forbid transformation":
    let app = newExpressApp()
    let payload = "range-response-" & "r".repeat(4096)

    let partial = makeRes(app)
    partial.compress = true
    partial.compressEncoding = "gzip"
    partial.status(206)
    partial.send(payload)
    check partial.headers.getOrDefault("content-encoding", "") == ""

    let contentRange = makeRes(app)
    contentRange.compress = true
    contentRange.compressEncoding = "gzip"
    contentRange.set("Content-Range", "bytes 0-99/200")
    contentRange.send(payload)
    check contentRange.headers.getOrDefault("content-encoding", "") == ""

    let noTransform = makeRes(app)
    noTransform.compress = true
    noTransform.compressEncoding = "gzip"
    noTransform.set("Cache-Control", "public, no-transform")
    noTransform.send(payload)
    check noTransform.headers.getOrDefault("content-encoding", "") == ""
