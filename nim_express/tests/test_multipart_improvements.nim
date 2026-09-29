import std/[unittest, asyncdispatch, strutils, os, random]
import ../src/nim_express/types
import ../src/nim_express/request
import ../src/nim_express/response
import ../src/nim_express/middlewares/common
import ../src/nim_express/middlewares/multipart

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

proc runMiddlewareChain(
  middlewares: seq[AsyncMiddleware],
  req: Request, res: Response,
  handler: proc(req: Request, res: Response): Future[void] = nil
) =
  waitFor startMiddlewareChain(middlewares, req, res, handler)

proc flagHandler(flag: ptr bool): proc(req: Request, res: Response): Future[void] =
  result = proc(req: Request, res: Response): Future[void] {.async.} =
    flag[] = true
    if not res.finished:
      res.status(200)
      res.send("ok")

proc textPart(name, value: string): tuple[headers, payload: string] =
  ("Content-Disposition: form-data; name=\"" & name & "\"", value)

proc filePart(name, fileName, value: string, lf: bool = false): tuple[headers, payload: string] =
  let nl = if lf: "\n" else: "\r\n"
  ("Content-Disposition: form-data; name=\"" & name & "\"; filename=\"" & fileName & "\"" &
    nl & "Content-Type: application/octet-stream", value)

proc buildBody(boundary: string, parts: openArray[tuple[headers, payload: string]],
               lf: bool = false): string =
  let nl = if lf: "\n" else: "\r\n"
  for p in parts:
    result &= "--" & boundary & nl
    result &= p.headers & nl & nl
    result &= p.payload & nl
  result &= "--" & boundary & "--" & nl

suite "multipart parsing":
  test "text fields parse into form_ locals":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("B1", @[textPart("title", "Hello"), textPart("body", "World")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=B1")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.form("title") == "Hello"
    check req.form("body") == "World"

  test "file part parses into file_ locals (in-memory mode)":
    let payload = "hello world"
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("B2", @[filePart("upload", "notes.txt", payload)]),
      headerMap = @[("content-type", "multipart/form-data; boundary=B2")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.local("file_upload_name") == "notes.txt"
    check req.local("file_upload_type") == "application/octet-stream"
    check req.local("file_upload_data") == payload
    check req.local("file_upload_size") == $payload.len
    let up = req.uploadFile("upload")
    check up.found
    check up.name == "notes.txt"
    check up.data == payload
    check up.size == payload.len

  test "LF-only line endings are accepted":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("B3", @[textPart("a", "1"), filePart("f", "x.bin", "Z", lf = true)],
                          lf = true),
      headerMap = @[("content-type", "multipart/form-data; boundary=B3")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.form("a") == "1"
    check req.local("file_f_data") == "Z"
    check req.local("file_f_name") == "x.bin"

  test "multi-file same field keeps indexed locals (ISSUE-2)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("B4", @[
        filePart("photos", "a.txt", "AAA"),
        filePart("photos", "b.txt", "BBB"),
        filePart("photos", "c.txt", "CCC"),
      ]),
      headerMap = @[("content-type", "multipart/form-data; boundary=B4")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.local("file_photos_count") == "3"
    check req.local("file_photos_0_name") == "a.txt"
    check req.local("file_photos_0_data") == "AAA"
    check req.local("file_photos_1_name") == "b.txt"
    check req.local("file_photos_1_data") == "BBB"
    check req.local("file_photos_2_name") == "c.txt"
    check req.local("file_photos_2_data") == "CCC"
    check req.local("file_photos_data") == "CCC"
    check req.uploadFile("photos").data == "CCC"

  test "single file uses legacy locals only, no index keys (regression)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("B5", @[filePart("upload", "only.bin", "ONLY")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=B5")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check req.local("file_upload_data") == "ONLY"
    check req.local("file_upload_0_data") == ""
    check req.local("file_upload_count") == ""
    check req.local("form_file_upload_data") == ""

  test "non-multipart requests pass through untouched":
    let req = newMockRequest(
      methodKind = hmPost, bodyStr = "{\"x\":1}",
      headerMap = @[("content-type", "application/json")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200

  test "empty multipart body passes through":
    let req = newMockRequest(
      methodKind = hmPost, bodyStr = "",
      headerMap = @[("content-type", "multipart/form-data; boundary=BE")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200

  test "quoted boundary after other params is honored (ISSUE-9)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("q7", @[textPart("k", "v")]),
      headerMap = @[("content-type",
        "multipart/form-data; charset=binary; boundary=\"q7\"")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.form("k") == "v"

  test "uppercase content-type and BOUNDARY param are honored (ISSUE-9)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("UP9", @[textPart("k", "v")]),
      headerMap = @[("content-type", "MULTIPART/FORM-DATA; BOUNDARY=UP9")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.form("k") == "v"

  test "uppercase disposition attributes are honored (ISSUE-10)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("B10", @[
        ("CONTENT-DISPOSITION: form-data; NAME=\"up\"; FILENAME=\"a.txt\"\r\n" &
         "Content-Type: text/plain", "DATA")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=B10")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.local("file_up_name") == "a.txt"
    check req.local("file_up_data") == "DATA"

suite "multipart validation":
  test "missing boundary yields 400":
    let req = newMockRequest(
      methodKind = hmPost, bodyStr = "whatever",
      headerMap = @[("content-type", "multipart/form-data")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 400

  test "oversized boundary yields 400":
    let big = repeat("x", 300)
    let req = newMockRequest(
      methodKind = hmPost, bodyStr = buildBody(big, @[textPart("k", "v")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=" & big)])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 400

  test "body without initial boundary yields 400":
    let req = newMockRequest(
      methodKind = hmPost, bodyStr = "this is not multipart at all",
      headerMap = @[("content-type", "multipart/form-data; boundary=ZZ")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 400

  test "part without header terminator yields 400":
    let req = newMockRequest(
      methodKind = hmPost, bodyStr = "--H\r\nno-headers-here\r\n--H--",
      headerMap = @[("content-type", "multipart/form-data; boundary=H")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 400

  test "oversized body yields 413 (size hint)":
    var options = defaultMultipartOptions()
    options.maxBodyBytes = 100
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BS", @[textPart("big", repeat("y", 300))]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BS")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart(options)], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 413

  test "oversized content-length yields 413 (pre-check)":
    var options = defaultMultipartOptions()
    options.maxBodyBytes = 100
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BL", @[textPart("k", "v")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BL"),
                    ("content-length", "5000")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart(options)], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 413

  test "malformed content-length yields 400":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BM", @[textPart("k", "v")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BM"),
                    ("content-length", "abc")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 400

  test "oversized file part yields 413":
    var options = defaultMultipartOptions()
    options.maxFileBytes = 8
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BF", @[filePart("f", "big.bin", "123456789")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BF")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart(options)], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 413

  test "oversized text field yields 413":
    var options = defaultMultipartOptions()
    options.maxFieldBytes = 4
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BT", @[textPart("f", "123456")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BT")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart(options)], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 413

  test "more fields than maxFields yields 413":
    var options = defaultMultipartOptions()
    options.maxFields = 1
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BC", @[textPart("a", "1"), textPart("b", "2")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BC")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart(options)], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 413

  test "more files than maxFiles yields 413":
    var options = defaultMultipartOptions()
    options.maxFiles = 1
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BD", @[filePart("f", "a.bin", "1"), filePart("f", "b.bin", "2")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BD")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart(options)], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 413

  test "part without content-disposition is skipped":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BN", @[
        ("Content-Type: text/plain", "zzz"),
        textPart("ok", "yes"),
      ]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BN")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.form("ok") == "yes"

  test "part with empty field name is skipped":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BE2", @[
        ("Content-Disposition: form-data; name=\"\"", "ghost"),
        textPart("real", "shown"),
      ]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BE2")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.form("real") == "shown"

  test "excessive boundary matches in part content yields 400 (ISSUE-6)":
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("B", @[textPart("f", repeat("x--B", 5000))]),
      headerMap = @[("content-type", "multipart/form-data; boundary=B")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart()], req, res, flagHandler(addr nextCalled))
    check not nextCalled
    check res.statusCode == 400

suite "multipart persistence":
  test "persisted upload writes file with owner-only permissions (ISSUE-4)":
    let uploadDir = getTempDir() / ("multipart_test_" & $rand(1_000_000_000))
    var options = defaultMultipartOptions()
    options.uploadDir = uploadDir
    let payload = "persisted content 123"
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BP", @[filePart("upload", "doc.txt", payload)]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BP")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart(options)], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    let path = req.local("file_upload_path")
    check path.len > 0
    check path.startsWith(uploadDir)
    check fileExists(path)
    check readFile(path) == payload
    check req.local("file_upload_name") == "doc.txt"
    check req.local("file_upload_data") == ""
    when defined(posix):
      let perms = getFilePermissions(path)
      check fpUserRead in perms
      check fpUserWrite in perms
      check fpGroupRead notin perms
      check fpOthersRead notin perms
    if fileExists(path):
      removeFile(path)
    if dirExists(uploadDir):
      removeDir(uploadDir)

  test "path traversal filename is neutralized into uploadDir":
    let uploadDir = getTempDir() / ("multipart_trav_" & $rand(1_000_000_000))
    var options = defaultMultipartOptions()
    options.uploadDir = uploadDir
    let req = newMockRequest(
      methodKind = hmPost,
      bodyStr = buildBody("BV", @[filePart("upload", "../../evil.txt", "EVIL")]),
      headerMap = @[("content-type", "multipart/form-data; boundary=BV")])
    let res = newMockResponse()
    var nextCalled = false
    runMiddlewareChain(@[multipart(options)], req, res, flagHandler(addr nextCalled))
    check nextCalled
    check res.statusCode == 200
    check req.local("file_upload_name") == "__evil.txt"
    let path = req.local("file_upload_path")
    check path.startsWith(uploadDir)
    check fileExists(path)
    check path.endsWith(".txt")
    check "/" notin splitFile(path).name
    if fileExists(path):
      removeFile(path)
    if dirExists(uploadDir):
      removeDir(uploadDir)
