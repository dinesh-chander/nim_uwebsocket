import std/[asyncdispatch, strutils, os, times, tempfiles, unittest]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/static_files
import ../src/nim_express/middlewares/file_helpers

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

proc newMockResponse(methodKind: HttpMethod = hmGet): Response =
  new(result)
  var nativeRes: HttpResponse
  new(nativeRes)
  nativeRes.requestMethod = methodKind
  nativeRes.connectionClose = false
  nativeRes.requestIsHttp11 = true
  result.native = nativeRes
  result.request = nil
  result.app = nil
  result.viewsDir = "views"
  result.viewExt = ""
  result.requestMethodKind = methodKind
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

proc runMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
): Future[void] =
  var idx = 0
  proc finalHandler(r: Request, s: Response): Future[void] {.async.} =
    if handler != nil:
      await handler(r, s)
    elif not s.finished:
      s.status(200)
  proc advance(): Future[void] {.async.} =
    if idx < middlewares.len:
      let current = middlewares[idx]
      inc idx
      await current(req, res, advance)
    else:
      await finalHandler(req, res)
  result = advance()

proc runStatic(
  root: string,
  pathVal: string,
  methodKind: HttpMethod = hmGet,
  headerMap: seq[(string, string)] = @[],
  prefix: string = "",
  nextFlag: ptr bool = nil,
  resPrep: proc(res: Response) = nil
): (Response, Request) =
  var mw = serveStatic(root, prefix = prefix)
  let req = newMockRequest(pathVal, methodKind, headerMap = headerMap)
  let res = newMockResponse(methodKind)
  if resPrep != nil:
    resPrep(res)
  proc handler(r: Request, s: Response): Future[void] {.async.} =
    if nextFlag != nil:
      nextFlag[] = true
    if not s.finished:
      s.status(200)
      s.send("app-handled")
  waitFor runMiddlewareChain(@[mw], req, res, handler)
  (res, req)

proc makeStaticRoot(): string =
  let dir = createTempDir("nim_express_static_", "")
  writeFile(dir / "hello.txt", "Hello, static world!\n")
  writeFile(dir / "page.html", "<html>ok</html>")
  writeFile(dir / "style.css", "body{color:red}")
  writeFile(dir / "my..backup.tar", "backup-data")
  createDir(dir / "sub")
  writeFile(dir / "sub" / "note.txt", "sub-note")
  writeFile(dir / "data.txt", "compress-me")
  writeFile(dir / "data.txt.gz", "GZDATA")
  result = dir

proc fileETag(path: string): string =
  let fi = getFileInfo(path)
  result = "W/\"" & $fi.size & "-" & $fi.lastWriteTime.toUnix() & "\""

suite "static_files content-type mapping":
  test "getMimeType maps known extensions (unit)":
    check getMimeType("a.css") == "text/css"
    check getMimeType("a.js") == "application/javascript"
    check getMimeType("a.html") == "text/html"
    check getMimeType("a.htm") == "text/html"
    check getMimeType("a.json") == "application/json"
    check getMimeType("a.png") == "image/png"
    check getMimeType("a.jpg") == "image/jpeg"
    check getMimeType("a.svg") == "image/svg+xml"
    check getMimeType("a.woff2") == "font/woff2"
    check getMimeType("a.ico") == "image/x-icon"

  test "getMimeType falls back to octet-stream and is case-insensitive (unit)":
    check getMimeType("a.xyz123") == "application/octet-stream"
    check getMimeType("a") == "application/octet-stream"
    check getMimeType("A.CSS") == "text/css"
    check getMimeType("B.HTML") == "text/html"

suite "static_files path traversal and rejection":
  test "encoded dot-dot segments are rejected with 403":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/%2e%2e/%2e%2e/etc/passwd")
      check res.statusCode == 403
      check res.finished
    finally:
      removeDir(root)

  test "dot-dot segment in the middle of an existing path is rejected with 403":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/sub/../hello.txt")
      check res.statusCode == 403
      check res.finished
    finally:
      removeDir(root)

  test "bare /.. request is rejected with 403":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/..")
      check res.statusCode == 403
      check res.finished
    finally:
      removeDir(root)

  test "null byte in path is rejected with 403":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/hello%00.txt")
      check res.statusCode == 403
      check res.finished
    finally:
      removeDir(root)

  test "backslash in decoded path is rejected with 403":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/..%5Chello.txt")
      check res.statusCode == 403
      check res.finished
    finally:
      removeDir(root)

suite "static_files double-dot filenames (ISSUE-4)":
  test "filename containing '..' as a substring is served, not 403":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/my..backup.tar")
      check res.statusCode == 200
      check res.finished
      check res.native.capturedRaw.contains("backup-data")
    finally:
      removeDir(root)

  test "traversal after a double-dot filename is still rejected with 403":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/my..backup.tar/../hello.txt")
      check res.statusCode == 403
      check res.finished
    finally:
      removeDir(root)

suite "static_files routing and passthrough":
  test "missing file falls through to next()":
    let root = makeStaticRoot()
    try:
      var nextCalled = false
      let (res, _) = runStatic(root, "/missing.txt", nextFlag = addr nextCalled)
      check nextCalled
      check res.statusCode == 200
      check res.native.capturedRaw.contains("app-handled")
    finally:
      removeDir(root)

  test "root path falls through to next()":
    let root = makeStaticRoot()
    try:
      var nextCalled = false
      discard runStatic(root, "/", nextFlag = addr nextCalled)
      check nextCalled
    finally:
      removeDir(root)

  test "non-GET method falls through to next()":
    let root = makeStaticRoot()
    try:
      var nextCalled = false
      discard runStatic(root, "/hello.txt", methodKind = hmPost, nextFlag = addr nextCalled)
      check nextCalled
    finally:
      removeDir(root)

  test "prefix match serves file, mismatch falls through":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/static/hello.txt", prefix = "/static")
      check res.statusCode == 200
      check res.native.capturedRaw.contains("Hello, static world!")

      var next1 = false
      discard runStatic(root, "/staticx/hello.txt", prefix = "/static", nextFlag = addr next1)
      check next1

      var next2 = false
      discard runStatic(root, "/other.txt", prefix = "/static", nextFlag = addr next2)
      check next2
    finally:
      removeDir(root)

  test "unavailable root directory always falls through to next()":
    var nextCalled = false
    let (res, _) = runStatic("/nonexistent_static_root_xyz", "/hello.txt", nextFlag = addr nextCalled)
    check nextCalled
    check res.native.capturedRaw.contains("app-handled")

suite "static_files headers and conditional requests":
  test "HEAD response carries content-type, length, etag, last-modified, ranges":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/page.html", methodKind = hmHead)
      check res.statusCode == 200
      check res.get("content-type") == "text/html"
      check res.get("content-length") == $"<html>ok</html>".len
      check res.get("etag") == fileETag(root / "page.html")
      check res.get("last-modified").len > 0
      check res.get("accept-ranges") == "bytes"
      check res.get("vary").contains("Accept-Encoding")
    finally:
      removeDir(root)

  test "html uses no-cache, css uses immutable cache-control":
    let root = makeStaticRoot()
    try:
      let (resHtml, _) = runStatic(root, "/page.html", methodKind = hmHead)
      check resHtml.get("cache-control") == "no-cache"

      let (resCss, _) = runStatic(root, "/style.css", methodKind = hmHead)
      check resCss.get("cache-control").contains("immutable")
      check resCss.get("cache-control").contains("max-age=31536000")

      let (resTxt, _) = runStatic(root, "/hello.txt", methodKind = hmHead)
      check resTxt.get("cache-control") == "public, max-age=300"
    finally:
      removeDir(root)

  test "pre-set upstream Cache-Control is preserved":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(
        root, "/page.html", methodKind = hmHead,
        resPrep = proc(s: Response) = discard s.set("Cache-Control", "no-store"))
      check res.get("cache-control") == "no-store"
    finally:
      removeDir(root)

  test "matching If-None-Match yields 304 without a body":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(
        root, "/page.html", headerMap = @[("if-none-match", fileETag(root / "page.html"))])
      check res.statusCode == 304
      check res.finished
      check res.native.capturedRaw.startsWith("HTTP/1.1 304 Not Modified")
      check res.native.capturedRaw.contains("<html>ok</html>") == false
    finally:
      removeDir(root)

suite "static_files full body serving":
  test "GET serves the file body (chunked fallback on mock response)":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/hello.txt")
      check res.statusCode == 200
      check res.finished
      check res.native.capturedRaw.contains("Hello, static world!\n")
      check res.native.capturedRaw.contains("transfer-encoding: chunked")
      check res.native.capturedRaw.endsWith("0\r\n\r\n")
    finally:
      removeDir(root)

  test "GET serves a file from a subdirectory":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/sub/note.txt")
      check res.statusCode == 200
      check res.native.capturedRaw.contains("sub-note")
    finally:
      removeDir(root)

suite "static_files range requests":
  test "explicit range returns 206 with the sliced body":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/hello.txt", headerMap = @[("range", "bytes=0-4")])
      check res.statusCode == 206
      check res.get("content-range") == "bytes 0-4/21"
      check res.get("content-length") == "5"
      check res.native.capturedRaw.startsWith("HTTP/1.1 206 Partial Content")
      check res.native.capturedRaw.endsWith("Hello")
    finally:
      removeDir(root)

  test "open-ended range returns 206 to the end of file":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/hello.txt", headerMap = @[("range", "bytes=10-")])
      check res.statusCode == 206
      check res.get("content-range") == "bytes 10-20/21"
      check res.native.capturedRaw.endsWith("tic world!\n")
    finally:
      removeDir(root)

  test "suffix range returns the last N bytes":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/hello.txt", headerMap = @[("range", "bytes=-5")])
      check res.statusCode == 206
      check res.get("content-range") == "bytes 16-20/21"
      check res.native.capturedRaw.endsWith("rld!\n")
    finally:
      removeDir(root)

  test "unsatisfiable start returns 416 with Content-Range */size":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/hello.txt", headerMap = @[("range", "bytes=999-")])
      check res.statusCode == 416
      check res.get("content-range") == "bytes */21"
      check res.native.capturedRaw.startsWith("HTTP/1.1 416 Range Not Satisfiable")
    finally:
      removeDir(root)

  test "malformed range values return 416":
    let root = makeStaticRoot()
    try:
      let (res1, _) = runStatic(root, "/hello.txt", headerMap = @[("range", "bytes=abc")])
      check res1.statusCode == 416
      check res1.get("content-range") == "bytes */21"

      let (res2, _) = runStatic(root, "/hello.txt", headerMap = @[("range", "bytes=5-2")])
      check res2.statusCode == 416

      let (res3, _) = runStatic(root, "/hello.txt", headerMap = @[("range", "bogus")])
      check res3.statusCode == 416
    finally:
      removeDir(root)

suite "static_files precompressed variants":
  test "gzip variant is selected when Accept-Encoding allows it":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(
        root, "/data.txt", headerMap = @[("accept-encoding", "gzip")])
      check res.statusCode == 200
      check res.get("content-encoding") == "gzip"
      check res.get("content-length") == "6"
      check res.native.capturedRaw.contains("GZDATA")
    finally:
      removeDir(root)

  test "original file is served without Accept-Encoding":
    let root = makeStaticRoot()
    try:
      let (res, _) = runStatic(root, "/data.txt")
      check res.statusCode == 200
      check res.get("content-encoding").len == 0
      check res.native.capturedRaw.contains("compress-me")
      check res.native.capturedRaw.contains("GZDATA") == false
    finally:
      removeDir(root)
